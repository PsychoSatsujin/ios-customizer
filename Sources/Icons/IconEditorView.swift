import SwiftUI
import PhotosUI
import UIKit

/// Add or edit one icon: image, the app (or link) it opens, and its label.
struct IconEditorView: View {
    let store: IconStore
    let existing: IconItem?

    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var launchURL: String
    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var sourceImage: UIImage? = nil
    @State private var renderedPNG: Data? = nil
    @State private var previewImage: UIImage? = nil
    @State private var imageChanged = false
    /// True while `sourceImage` is the saved icon PNG, which is already flattened
    /// onto its old background, so a new background color can't change it.
    @State private var sourceIsSavedIcon = false
    @State private var background: Color = .white
    @State private var isLoadingImage = false
    /// Increases with every pick, so a slow earlier load can't overwrite a newer one.
    @State private var loadGeneration = 0
    @State private var didLoadExisting = false
    @State private var message: String = ""
    @State private var messageIsError = false

    init(store: IconStore, item: IconItem?) {
        self.store = store
        self.existing = item
        _label = State(initialValue: item?.label ?? "")
        _launchURL = State(initialValue: item?.launchURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                imageSection
                linkSection
                labelSection
                if !message.isEmpty {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Icon" : "Edit Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadExistingImageIfNeeded() }
            .onChange(of: pickedItem) { _, newItem in
                guard let newItem else { return }
                loadPicked(newItem)
            }
            .onChange(of: background) { _, _ in
                guard sourceImage != nil, !sourceIsSavedIcon else { return }
                imageChanged = true
                rerender()
            }
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    IconTileView(image: previewImage, size: 96)
                    Text(trimmedLabel.isEmpty ? "Label" : trimmedLabel)
                        .font(.caption)
                        .foregroundStyle(trimmedLabel.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    if isLoadingImage {
                        ProgressView()
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        } footer: {
            Text("This is how the icon will look on your Home Screen.")
        }
    }

    private var imageSection: some View {
        Section {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label(sourceImage == nil ? "Choose image" : "Change image", systemImage: "photo.on.rectangle")
            }
            ColorPicker("Background", selection: $background, supportsOpacity: false)
                .disabled(sourceIsSavedIcon)
        } header: {
            Text("Image")
        } footer: {
            Text(imageFooter)
        }
    }

    private var imageFooter: String {
        if sourceIsSavedIcon {
            return "The image is cropped to a square from the center. To change the background color, choose the image again."
        }
        return "The image is cropped to a square from the center. The background color shows through transparent parts."
    }

    private var linkSection: some View {
        Section {
            NavigationLink {
                IconAppPickerView(onPick: { app in choose(app) })
            } label: {
                HStack {
                    Text("App")
                    Spacer()
                    Text(appSummary)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("instagram:// or https://…", text: $launchURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                testLink()
            } label: {
                Label("Test link", systemImage: "arrow.up.right.square")
            }
            .disabled(validURL == nil)
        } header: {
            Text("Opens")
        } footer: {
            Text(linkHint)
                .foregroundStyle(linkLooksWrong ? Color.red : Color.secondary)
        }
    }

    private var labelSection: some View {
        Section {
            TextField("Name under the icon", text: $label)
        } header: {
            Text("Label")
        }
    }

    // MARK: - State helpers

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        launchURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validURL: URL? {
        WebClipProfile.launchURL(from: launchURL)
    }

    private var matchedApp: CatalogApp? {
        AppCatalog.app(matching: launchURL)
    }

    private var linkLooksWrong: Bool {
        !trimmedURL.isEmpty && validURL == nil
    }

    private var appSummary: String {
        if let app = matchedApp { return app.name }
        return trimmedURL.isEmpty ? "Choose" : "Custom link"
    }

    private var linkHint: String {
        if trimmedURL.isEmpty {
            return "Pick an app, or type any link: an app's URL scheme like instagram:// or a web address."
        }
        if validURL == nil {
            if trimmedURL.contains(where: { $0.isNewline || $0 == "\t" }) {
                return "Links can't contain tabs or line breaks."
            }
            return "That link isn't valid. It needs a scheme, like instagram:// or https://example.com."
        }
        if trimmedURL.contains(" ") {
            return "Spaces are sent as %20. Tap Test link to check that it opens the right app before you install."
        }
        return "Tap Test link to check that it opens the right app before you install."
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && validURL != nil && renderedPNG != nil && !isLoadingImage
    }

    // MARK: - Actions

    private func choose(_ app: CatalogApp) {
        let previousName = matchedApp?.name
        launchURL = app.launchURL
        if trimmedLabel.isEmpty || trimmedLabel == previousName {
            label = app.name
        }
    }

    private func loadExistingImageIfNeeded() {
        guard !didLoadExisting else { return }
        didLoadExisting = true
        guard let item = existing, let image = store.image(for: item) else { return }
        sourceImage = image
        sourceIsSavedIcon = true
        previewImage = image
        renderedPNG = store.iconData(for: item)
    }

    private func loadPicked(_ item: PhotosPickerItem) {
        loadGeneration += 1
        let generation: Int = loadGeneration
        isLoadingImage = true
        message = ""
        Task {
            let result: Result<Data?, Error>
            do {
                let loaded: Data? = try await item.loadTransferable(type: Data.self)
                result = .success(loaded)
            } catch {
                result = .failure(error)
            }
            // A newer pick started while this one was loading: let that one win.
            guard generation == loadGeneration else { return }
            isLoadingImage = false
            // Clear the selection so picking the same photo again (to retry) triggers onChange.
            pickedItem = nil

            switch result {
            case .failure(let error):
                showMessage("Could not load that image: \(error.localizedDescription)", isError: true)
            case .success(let loaded):
                guard let imageData = loaded else {
                    showMessage("Could not load that image.", isError: true)
                    return
                }
                guard let image = IconRenderer.downsampledImage(from: imageData, maxPixelSize: 1024)
                        ?? UIImage(data: imageData) else {
                    showMessage("That image format isn't supported.", isError: true)
                    return
                }
                sourceImage = image
                sourceIsSavedIcon = false
                imageChanged = true
                rerender()
            }
        }
    }

    private func rerender() {
        guard let source = sourceImage else {
            renderedPNG = nil
            previewImage = nil
            return
        }
        let png = IconRenderer.renderPNG(from: source, background: UIColor(background))
        renderedPNG = png
        previewImage = UIImage(data: png)
    }

    private func testLink() {
        guard let url = validURL else { return }
        message = ""
        Task {
            let opened: Bool = await UIApplication.shared.open(url, options: [:])
            if opened {
                showMessage("The link opened an app. If it was the right one, you're all set.", isError: false)
            } else {
                showMessage("No installed app opens this link. Check that the app is installed, or try a different link.", isError: true)
            }
        }
    }

    private func save() {
        // Save the link exactly as it goes into the profile (spaces become %20).
        let link: String = validURL?.absoluteString ?? trimmedURL
        do {
            if var item = existing {
                item.label = trimmedLabel
                item.launchURL = link
                try store.update(item, iconPNG: imageChanged ? renderedPNG : nil)
            } else {
                guard let png = renderedPNG else { return }
                try store.add(IconItem(label: trimmedLabel, launchURL: link), iconPNG: png)
            }
            dismiss()
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

/// Searchable list of the curated apps.
struct IconAppPickerView: View {
    let onPick: (CatalogApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(onPick: @escaping (CatalogApp) -> Void) {
        self.onPick = onPick
    }

    var body: some View {
        List {
            ForEach(CatalogApp.Kind.allCases, id: \.self) { kind in
                section(for: kind)
            }
            if AppCatalog.search(query).isEmpty {
                Text("No app matches. Go back and type the app's link yourself.")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Search apps")
        .navigationTitle("Choose App")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(for kind: CatalogApp.Kind) -> some View {
        let apps = AppCatalog.search(query).filter { $0.kind == kind }
        if !apps.isEmpty {
            Section {
                ForEach(apps) { app in
                    row(for: app)
                }
            } header: {
                Text(kind.title)
            }
        }
    }

    private func row(for app: CatalogApp) -> some View {
        Button {
            onPick(app)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: app.displaySymbol)
                    .frame(width: 28)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .foregroundStyle(Color.primary)
                    Text(app.launchURL)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

/// An icon image clipped to the Home Screen's rounded-square shape.
struct IconTileView: View {
    let image: UIImage?
    var size: CGFloat = 60

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                shape
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
    }
}
