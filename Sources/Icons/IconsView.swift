import SwiftUI
import SafariServices
import UIKit

/// Icons tab: make custom Home Screen icons and install them as a
/// configuration profile with one web clip per icon.
struct IconsView: View {
    @StateObject private var store = IconStore()
    @StateObject private var installer = IconProfileInstaller()
    @State private var editorRoute: IconEditorRoute? = nil

    var body: some View {
        NavigationStack {
            List {
                iconsSection
                installSection
                stepsSection
                changesSection
                notesSection
            }
            .navigationTitle("Icons")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.items.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorRoute = .create
                    } label: {
                        Label("Add icon", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorRoute) { route in
                IconEditorView(store: store, item: route.item)
            }
            .onChange(of: store.items, initial: true) { _, _ in
                installer.refresh(from: store)
            }
        }
        .sheet(item: $installer.safariTarget, onDismiss: { installer.safariDismissed() }) { target in
            IconInstallSafariView(url: target.url, onFinish: { installer.safariTarget = nil })
                .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var iconsSection: some View {
        if store.items.isEmpty {
            Section {
                ContentUnavailableView(
                    "No icons yet",
                    systemImage: "square.grid.2x2",
                    description: Text("Tap + to pick an image and the app it should open.")
                )
            }
        } else {
            Section {
                ForEach(store.items) { item in
                    Button {
                        editorRoute = .edit(item)
                    } label: {
                        IconListRow(item: item, image: store.image(for: item))
                    }
                }
                .onDelete { offsets in
                    store.delete(at: offsets)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("Your icons")
            } footer: {
                Text("Tap an icon to edit it. Swipe left to delete it. Tap Edit to change the order.")
            }
        }
        if let error = store.lastError {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
        }
    }

    private var installSection: some View {
        Section {
            Button {
                installer.installInApp()
            } label: {
                Label("Install on Home Screen", systemImage: "plus.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!installer.canInstall)

            Button {
                installer.installViaSafariApp()
            } label: {
                Label("Open in Safari app instead", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!installer.canInstall)

            if let fileURL = installer.exportURL {
                ShareLink(item: fileURL) {
                    Label("Save profile file", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let problem = installer.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(store.items.isEmpty ? Color.secondary : Color.orange)
            }

            if !installer.status.isEmpty {
                Text(installer.status)
                    .font(.footnote)
                    .foregroundStyle(installer.statusIsError ? Color.red : Color.secondary)
            }
        } header: {
            Text("Install on Home Screen")
        } footer: {
            Text("If the main button doesn't work, tap Save profile file, choose Save to Files, then open the file in the Files app and continue from step 3.")
        }
    }

    private var stepsSection: some View {
        Section {
            ForEach(IconsView.installSteps.indices, id: \.self) { index in
                NumberedStep(number: index + 1, text: IconsView.installSteps[index])
            }
        } header: {
            Text("How to install")
        }
    }

    private var changesSection: some View {
        Section {
            ForEach(IconsView.changeNotes, id: \.self) { note in
                BulletNote(text: note)
            }
        } header: {
            Text("Changing or removing icons")
        }
    }

    private var notesSection: some View {
        Section {
            ForEach(IconsView.goodToKnow, id: \.self) { note in
                BulletNote(text: note)
            }
        } header: {
            Text("Good to know")
        }
    }

    // MARK: - Text

    private static let installSteps: [String] = [
        "Tap + and make an icon: choose an image, pick the app it should open (or type a link) and give it a label.",
        "Tap Install on Home Screen. When asked whether to allow downloading a configuration profile, tap Allow, then Close.",
        "Within about 8 minutes, open the Settings app and tap Profile Downloaded near the top. It is also under General > VPN & Device Management.",
        "Tap Install and enter your passcode. The profile shows as Not Verified because you made it yourself. That is expected: tap Install again, then Done.",
        "Your icons are now on the Home Screen. Tapping one opens its app.",
        "To see only your icons, long-press each original app icon and choose Remove App > Remove from Home Screen. The app stays installed in the App Library.",
    ]

    private static let changeNotes: [String] = [
        "To change your icons, edit them here and install again. The new Custom Icons profile replaces the old one.",
        "To remove one icon, long-press it on the Home Screen and delete it.",
        "To remove all of them, go to Settings > General > VPN & Device Management, open Custom Icons and tap Remove Profile.",
    ]

    private static let goodToKnow: [String] = [
        "The icons keep working after this app's 7-day signing expires, because they live in the profile, not in the app.",
        "Use Test link in the editor first. If no app opens the link, the app isn't installed or uses a different link.",
        "These icons don't show notification badges and may not follow dark or tinted icon styles.",
        "Some Apple apps, such as Camera, Calculator and Contacts, have no known link, so they can't get a custom icon this way.",
        "If Settings won't install the profile, Stolen Device Protection may require you to be at a familiar place, like home.",
    ]
}

// MARK: - Rows

private struct IconListRow: View {
    let item: IconItem
    let image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            IconTileView(image: image, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label.isEmpty ? "No label" : item.label)
                    .foregroundStyle(Color.primary)
                Text(item.launchURL)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if image == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .accessibilityLabel("Missing image")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.footnote)
        }
    }
}

private struct BulletNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            Text(text)
                .font(.footnote)
        }
    }
}

// MARK: - Navigation

enum IconEditorRoute: Identifiable {
    case create
    case edit(IconItem)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let item):
            return item.id.uuidString
        }
    }

    var item: IconItem? {
        switch self {
        case .create:
            return nil
        case .edit(let item):
            return item
        }
    }
}

struct IconInstallTarget: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Installer

/// Builds the profile from the store, serves it on 127.0.0.1 and hands the URL
/// to Safari (in-app sheet, or the Safari app with a background task), and
/// writes a copy for the share-sheet fallback.
@MainActor
final class IconProfileInstaller: ObservableObject {
    @Published private(set) var profileData: Data? = nil
    @Published private(set) var exportURL: URL? = nil
    /// Why installing is disabled right now, if it is.
    @Published private(set) var problem: String? = nil
    @Published private(set) var status: String = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var isStarting = false
    @Published var safariTarget: IconInstallTarget? = nil

    private var server: ProfileServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var canInstall: Bool {
        profileData != nil && !isStarting
    }

    /// Rebuilds the profile and the exported file after the icons changed.
    func refresh(from store: IconStore) {
        guard !store.items.isEmpty else {
            profileData = nil
            exportURL = nil
            problem = "Add at least one icon to install."
            return
        }
        do {
            let data = try store.buildProfile()
            profileData = data
            problem = nil
            exportURL = try? writeExportFile(data)
        } catch {
            profileData = nil
            exportURL = nil
            problem = error.localizedDescription
        }
    }

    /// Primary route: an in-app Safari sheet. The app stays in the foreground,
    /// so the server keeps running, and it works even if Safari isn't the default browser.
    func installInApp() {
        guard let profile = profileData, !isStarting else { return }
        isStarting = true
        setStatus("Starting the installer…")
        Task {
            let startedURL: URL? = await self.startServer(profile: profile)
            self.isStarting = false
            guard let url = startedURL else { return }
            self.safariTarget = IconInstallTarget(url: url)
            self.setStatus("In the page that opens, tap Allow, then Close. Then open Settings and tap Profile Downloaded.")
        }
    }

    /// Second route: open the profile URL in the Safari app. The app is
    /// backgrounded right away, so a background task keeps the server alive
    /// long enough for Safari to download the profile.
    func installViaSafariApp() {
        guard let profile = profileData, !isStarting else { return }
        isStarting = true
        setStatus("Starting the installer…")
        Task {
            guard let url = await self.startServer(profile: profile) else {
                self.isStarting = false
                return
            }
            self.beginBackgroundTask()
            let opened: Bool = await UIApplication.shared.open(url, options: [:])
            self.isStarting = false
            if opened {
                self.setStatus("Safari opened. Tap Allow, then Close, then open Settings > Profile Downloaded. If another browser opened instead, use Install on Home Screen.")
            } else {
                self.stopServer()
                self.setStatus("Safari could not be opened. Use Install on Home Screen or Save profile file instead.", isError: true)
            }
        }
    }

    func safariDismissed() {
        stopServer()
        if !statusIsError {
            setStatus("If you tapped Allow: open Settings, tap Profile Downloaded near the top, then Install. iOS discards the download after about 8 minutes.")
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        endBackgroundTask()
    }

    // MARK: - Private

    private func startServer(profile: Data) async -> URL? {
        stopServer()
        let newServer = ProfileServer(profile: profile, onProfileServed: { [weak self] in
            self?.profileWasServed()
        })
        server = newServer
        do {
            let url = try await newServer.start()
            guard server === newServer else { return nil }
            return url
        } catch {
            if server === newServer {
                server = nil
            }
            setStatus("Could not start the installer: \(error.localizedDescription)", isError: true)
            return nil
        }
    }

    private func profileWasServed() {
        setStatus("Safari received the profile. Tap Allow if asked, then open Settings > Profile Downloaded and tap Install.")
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        status = text
        statusIsError = isError
    }

    private func writeExportFile(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconProfileExport", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(WebClipProfile.fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Serve icon profile") { [weak self] in
            // iOS calls this on the main thread shortly before background time runs out.
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
        let token = backgroundTask
        Task { [weak self] in
            // Safari fetches the profile within seconds; don't hold the task longer than needed.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            self?.endBackgroundTask(ifCurrent: token)
        }
    }

    private func endBackgroundTask(ifCurrent token: UIBackgroundTaskIdentifier) {
        guard backgroundTask == token else { return }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Safari sheet

/// In-app Safari (always the Safari engine, which can hand profiles to Settings).
struct IconInstallSafariView: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
