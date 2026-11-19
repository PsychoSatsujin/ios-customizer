import XCTest
import UIKit
@testable import Customize

final class IconStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func samplePNG(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 64, height: 48)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return IconRenderer.renderPNG(from: image)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tests

    @MainActor
    func testNewStoreIsEmptyAndCreatesItsFolders() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let items = store.items
        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.baseDirectory, directory)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imagesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testItemsPersistAcrossStoreInstances() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let instagram = try store.add(IconItem(label: "Instagram", launchURL: "instagram://"), iconPNG: samplePNG(.systemPink))
        let notes = try store.add(IconItem(label: "Notes", launchURL: "mobilenotes://"), iconPNG: samplePNG(.systemYellow))

        var renamed = notes
        renamed.label = "My Notes"
        renamed.launchURL = "mobilenotes://new"
        try store.update(renamed)
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let saved = store.items
        XCTAssertEqual(saved.map(\.label), ["My Notes", "Instagram"])
        XCTAssertEqual(saved.map(\.id), [notes.id, instagram.id])
        XCTAssertEqual(saved[0].imageFileName, notes.imageFileName, "Updating without a new image keeps the old one")
        XCTAssertTrue(fileExists(directory.appendingPathComponent("items.json")))

        let reloaded = IconStore(baseDirectory: directory)
        let reloadedItems = reloaded.items
        XCTAssertEqual(reloadedItems, saved)
        XCTAssertNil(reloaded.lastError)
    }

    @MainActor
    func testSavingAnIconWritesThePNGAndLoadsItBack() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let png = samplePNG(.systemGreen)
        let item = try store.add(IconItem(label: "Maps", launchURL: "maps://"), iconPNG: png)

        let fileName = try XCTUnwrap(item.imageFileName)
        XCTAssertTrue(fileName.hasSuffix(".png"))
        XCTAssertTrue(fileName.hasPrefix(item.id.uuidString))
        let fileURL = store.imageURL(forFileName: fileName)
        XCTAssertEqual(fileURL.deletingLastPathComponent().path, store.imagesDirectory.path)
        XCTAssertTrue(fileExists(fileURL))
        XCTAssertEqual(try Data(contentsOf: fileURL), png)
        XCTAssertEqual(store.iconData(for: item), png)

        let image = try XCTUnwrap(store.image(for: item))
        XCTAssertEqual(image.cgImage?.width, IconRenderer.pixelSize)
        XCTAssertEqual(image.cgImage?.height, IconRenderer.pixelSize)

        let reloaded = IconStore(baseDirectory: directory)
        let reloadedItem = try XCTUnwrap(reloaded.items.first)
        XCTAssertEqual(reloaded.iconData(for: reloadedItem), png)
        XCTAssertNotNil(reloaded.image(for: reloadedItem))

        let looseName = try store.saveIconImage(png, for: UUID())
        XCTAssertTrue(fileExists(store.imageURL(forFileName: looseName)))
        XCTAssertThrowsError(try store.saveIconImage(Data(), for: UUID()))
    }

    @MainActor
    func testAddingWithoutImageLeavesNoFileName() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let item = try store.add(IconItem(label: "Draft", launchURL: "maps://", imageFileName: "ignored.png"), iconPNG: nil)
        XCTAssertNil(item.imageFileName)
        XCTAssertNil(store.image(for: item))
        XCTAssertNil(store.iconData(for: item))
    }

    @MainActor
    func testUpdatingTheImageReplacesTheOldFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let item = try store.add(IconItem(label: "Music", launchURL: "music://"), iconPNG: samplePNG(.systemRed))
        let oldName = try XCTUnwrap(item.imageFileName)

        let newPNG = samplePNG(.systemBlue)
        let updated = try store.update(item, iconPNG: newPNG)
        let newName = try XCTUnwrap(updated.imageFileName)

        XCTAssertNotEqual(oldName, newName)
        XCTAssertFalse(fileExists(store.imageURL(forFileName: oldName)))
        XCTAssertTrue(fileExists(store.imageURL(forFileName: newName)))
        XCTAssertEqual(store.iconData(for: updated), newPNG)
        XCTAssertEqual(store.items.first?.imageFileName, newName)
    }

    @MainActor
    func testDeletingRemovesItemsAndTheirFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        let first = try store.add(IconItem(label: "One", launchURL: "maps://"), iconPNG: samplePNG(.systemRed))
        let second = try store.add(IconItem(label: "Two", launchURL: "music://"), iconPNG: samplePNG(.systemBlue))
        let firstName = try XCTUnwrap(first.imageFileName)
        let secondName = try XCTUnwrap(second.imageFileName)
        let firstURL = store.imageURL(forFileName: firstName)
        let secondURL = store.imageURL(forFileName: secondName)

        store.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(store.items.map(\.id), [second.id])
        XCTAssertFalse(fileExists(firstURL))
        XCTAssertTrue(fileExists(secondURL))

        store.delete(id: second.id)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(fileExists(secondURL))

        // Out-of-range offsets and unknown ids are ignored.
        store.delete(at: IndexSet(integer: 5))
        store.delete(id: UUID())

        let reloaded = IconStore(baseDirectory: directory)
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    @MainActor
    func testUpdatingOrAddingTwiceIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        XCTAssertThrowsError(try store.update(IconItem(label: "Ghost", launchURL: "maps://"))) { error in
            XCTAssertEqual(error as? IconStoreError, .itemNotFound)
        }

        let item = try store.add(IconItem(label: "Once", launchURL: "maps://"), iconPNG: samplePNG(.systemRed))
        XCTAssertThrowsError(try store.add(item, iconPNG: nil)) { error in
            XCTAssertEqual(error as? IconStoreError, .duplicateItem)
        }
        XCTAssertEqual(store.items.count, 1)
    }

    @MainActor
    func testUnreadableListIsKeptAsideInsteadOfOverwritten() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let itemsURL = directory.appendingPathComponent("items.json")
        let garbage = Data("{ this is not a list of icons".utf8)
        try garbage.write(to: itemsURL)

        let store = IconStore(baseDirectory: directory)
        let items = store.items
        XCTAssertTrue(items.isEmpty)
        let problem = try XCTUnwrap(store.lastError)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backups = names.filter { $0.hasPrefix("items.unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
        let backupName = try XCTUnwrap(backups.first)
        XCTAssertTrue(problem.contains(backupName), problem)
        let backupURL = directory.appendingPathComponent(backupName)
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage)
        XCTAssertFalse(fileExists(itemsURL))

        // Saving a new list afterwards must not touch the backup.
        try store.add(IconItem(label: "New", launchURL: "maps://"), iconPNG: samplePNG(.systemRed))
        XCTAssertNil(store.lastError)
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage)

        let reloaded = IconStore(baseDirectory: directory)
        let reloadedItems = reloaded.items
        XCTAssertEqual(reloadedItems.map(\.label), ["New"])
        XCTAssertNil(reloaded.lastError)
    }

    @MainActor
    func testProfileUUIDIsStableAcrossStoreInstances() throws {
        let directory = try makeTemporaryDirectory()
        let otherDirectory = try makeTemporaryDirectory()
        defer {
            removeDirectory(directory)
            removeDirectory(otherDirectory)
        }

        let first = IconStore(baseDirectory: directory).profileUUID
        let second = IconStore(baseDirectory: directory).profileUUID
        XCTAssertEqual(first, second)
        XCTAssertTrue(fileExists(directory.appendingPathComponent("profile.json")))

        let other = IconStore(baseDirectory: otherDirectory).profileUUID
        XCTAssertNotEqual(first, other)
    }

    @MainActor
    func testBuildProfileUsesTheStoredProfileUUID() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = IconStore(baseDirectory: directory)
        XCTAssertThrowsError(try store.buildProfile()) { error in
            XCTAssertEqual(error as? WebClipProfileError, .noIcons)
        }

        try store.add(IconItem(label: "Weather", launchURL: "weather://"), iconPNG: samplePNG(.systemTeal))
        let data = try store.buildProfile()
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["PayloadUUID"] as? String, store.profileUUID.uuidString)
        XCTAssertEqual(plist["PayloadIdentifier"] as? String, WebClipProfile.profileIdentifier)
        let content = try XCTUnwrap(plist["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["Label"] as? String, "Weather")

        // A second store on the same folder builds a profile with the same identity.
        let again = try IconStore(baseDirectory: directory).buildProfile()
        let plistAgain = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: again, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plistAgain["PayloadUUID"] as? String, store.profileUUID.uuidString)
        let contentAgain = try XCTUnwrap(plistAgain["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(contentAgain.first?["PayloadUUID"] as? String, content.first?["PayloadUUID"] as? String)
    }
}
