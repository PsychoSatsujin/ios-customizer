import Foundation
import Combine
import SwiftUI
import UIKit

/// One custom Home Screen icon: the name shown under it, the link it opens
/// and the rendered PNG that is used as its artwork.
struct IconItem: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var launchURL: String
    /// File name of the rendered PNG inside the store's Images folder.
    var imageFileName: String?

    init(id: UUID = UUID(), label: String, launchURL: String, imageFileName: String? = nil) {
        self.id = id
        self.label = label
        self.launchURL = launchURL
        self.imageFileName = imageFileName
    }
}

enum IconStoreError: LocalizedError, Equatable {
    case itemNotFound
    case duplicateItem
    case emptyImage

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "That icon no longer exists."
        case .duplicateItem:
            return "That icon already exists."
        case .emptyImage:
            return "The icon image is empty."
        }
    }
}

/// Keeps the user's icons on disk: `items.json` for the list, one PNG per
/// icon in `Images/`, and `profile.json` for the profile UUID that is
/// created once so that reinstalling the profile replaces the old one.
@MainActor
final class IconStore: ObservableObject {
    @Published private(set) var items: [IconItem] = []
    @Published private(set) var lastError: String? = nil

    let baseDirectory: URL
    /// Top-level PayloadUUID of the generated profile. Created once per store folder.
    let profileUUID: UUID

    private var imageCache: [String: UIImage] = [:]
    /// True when items.json could not be read and could not be moved aside either.
    /// Saving is then refused so the unreadable list is never overwritten.
    private var savingBlocked = false

    /// - Parameter baseDirectory: Folder that holds the data. Defaults to
    ///   Application Support/CustomIcons. Tests pass a temporary folder.
    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? StoreLayout.defaultBaseDirectory()
        self.baseDirectory = base

        var problem: String? = nil
        do {
            try FileManager.default.createDirectory(
                at: StoreLayout.imagesDirectory(in: base),
                withIntermediateDirectories: true
            )
        } catch {
            problem = "Could not create the icons folder: \(error.localizedDescription)"
        }

        self.profileUUID = StoreLayout.loadOrCreateProfileUUID(in: base)

        let itemsURL = StoreLayout.itemsURL(in: base)
        if FileManager.default.fileExists(atPath: itemsURL.path) {
            do {
                let data = try Data(contentsOf: itemsURL)
                self.items = try JSONDecoder().decode([IconItem].self, from: data)
            } catch {
                // Never let the next save overwrite a list that can't be read: keep it
                // as a backup next to items.json (its images stay in Images/).
                if let backup = StoreLayout.moveAsideUnreadableItems(at: itemsURL, in: base) {
                    problem = "Your saved icons couldn't be read, so the list starts empty. The old list was kept as \(backup.lastPathComponent)."
                } else {
                    self.savingBlocked = true
                    problem = "Your saved icons couldn't be read. Changes won't be saved, so the old list isn't overwritten."
                }
            }
        }
        self.lastError = problem
    }

    // MARK: - Files

    var imagesDirectory: URL {
        StoreLayout.imagesDirectory(in: baseDirectory)
    }

    func imageURL(forFileName name: String) -> URL {
        // Only ever use the last path component so a stored name can't point outside the folder.
        let safeName = (name as NSString).lastPathComponent
        return imagesDirectory.appendingPathComponent(safeName, isDirectory: false)
    }

    /// Writes an icon PNG and returns its new file name. Every save gets a fresh
    /// name so cached images and the profile's per-icon UUID change with it.
    @discardableResult
    func saveIconImage(_ png: Data, for id: UUID) throws -> String {
        guard !png.isEmpty else { throw IconStoreError.emptyImage }
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let name = "\(id.uuidString)-\(UUID().uuidString.prefix(8)).png"
        try png.write(to: imageURL(forFileName: name), options: .atomic)
        return name
    }

    func image(for item: IconItem) -> UIImage? {
        guard let name = item.imageFileName else { return nil }
        if let cached = imageCache[name] { return cached }
        guard let data = try? Data(contentsOf: imageURL(forFileName: name)),
              let image = UIImage(data: data) else { return nil }
        imageCache[name] = image
        return image
    }

    func iconData(for item: IconItem) -> Data? {
        guard let name = item.imageFileName else { return nil }
        return try? Data(contentsOf: imageURL(forFileName: name))
    }

    // MARK: - Editing

    /// Adds an icon. When `iconPNG` is given it is saved and linked to the item.
    @discardableResult
    func add(_ item: IconItem, iconPNG: Data?) throws -> IconItem {
        guard !items.contains(where: { $0.id == item.id }) else {
            throw IconStoreError.duplicateItem
        }
        var newItem = item
        newItem.imageFileName = nil
        if let png = iconPNG {
            newItem.imageFileName = try saveIconImage(png, for: item.id)
        }
        items.append(newItem)
        persist()
        return newItem
    }

    /// Updates label and link. When `iconPNG` is given the image is replaced
    /// and the old file removed; otherwise the current image is kept.
    @discardableResult
    func update(_ item: IconItem, iconPNG: Data? = nil) throws -> IconItem {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw IconStoreError.itemNotFound
        }
        let oldFileName = items[index].imageFileName
        var updated = item
        updated.imageFileName = oldFileName
        if let png = iconPNG {
            updated.imageFileName = try saveIconImage(png, for: item.id)
            if let oldFileName {
                removeImageFile(named: oldFileName)
            }
        }
        items[index] = updated
        persist()
        return updated
    }

    func delete(at offsets: IndexSet) {
        let valid = IndexSet(offsets.filter { $0 >= 0 && $0 < items.count })
        guard !valid.isEmpty else { return }
        let removed = valid.map { items[$0] }
        items.remove(atOffsets: valid)
        for item in removed {
            if let name = item.imageFileName {
                removeImageFile(named: name)
            }
        }
        persist()
    }

    func delete(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        delete(at: IndexSet(integer: index))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Profile

    func profileEntries() -> [WebClipProfile.Entry] {
        items.map { WebClipProfile.Entry(item: $0, iconPNG: iconData(for: $0)) }
    }

    /// Builds the .mobileconfig for all icons, or throws the first problem found.
    func buildProfile() throws -> Data {
        try WebClipProfile.build(entries: profileEntries(), profileUUID: profileUUID)
    }

    // MARK: - Private

    private func removeImageFile(named name: String) {
        imageCache[name] = nil
        try? FileManager.default.removeItem(at: imageURL(forFileName: name))
    }

    private func persist() {
        guard !savingBlocked else {
            lastError = "Your saved icons couldn't be read, so changes aren't saved. The old list was left untouched."
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: StoreLayout.itemsURL(in: baseDirectory), options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save your icons: \(error.localizedDescription)"
        }
    }
}

private struct StoreMetadata: Codable {
    var profileUUID: UUID
}

private enum StoreLayout {
    static func defaultBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let root: URL
        if let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            root = support
        } else {
            root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        }
        return root.appendingPathComponent("CustomIcons", isDirectory: true)
    }

    static func itemsURL(in base: URL) -> URL {
        base.appendingPathComponent("items.json", isDirectory: false)
    }

    static func metadataURL(in base: URL) -> URL {
        base.appendingPathComponent("profile.json", isDirectory: false)
    }

    static func imagesDirectory(in base: URL) -> URL {
        base.appendingPathComponent("Images", isDirectory: true)
    }

    /// Renames an unreadable items.json to items.unreadable-<time>-<id>.json in
    /// the same folder. Returns the new URL, or nil if the file could not be moved.
    static func moveAsideUnreadableItems(at itemsURL: URL, in base: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(4)
        let backup = base.appendingPathComponent("items.unreadable-\(stamp)-\(suffix).json", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: itemsURL, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    static func loadOrCreateProfileUUID(in base: URL) -> UUID {
        let url = metadataURL(in: base)
        if let data = try? Data(contentsOf: url),
           let metadata = try? JSONDecoder().decode(StoreMetadata.self, from: data) {
            return metadata.profileUUID
        }
        let metadata = StoreMetadata(profileUUID: UUID())
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: url, options: .atomic)
        }
        return metadata.profileUUID
    }
}
