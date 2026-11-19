import Photos
import PhotosUI
import SwiftUI

/// Live tab: pick a video, choose a part of it, turn it into a Live Photo and save it to Photos,
/// from where it can be set as a moving Lock Screen wallpaper.
@MainActor
struct LiveWallpaperView: View {
    @State private var pickedItem: PhotosPickerItem?
    @State private var movieURL: URL?
    @State private var movieDuration: Double = 0

    @State private var startTime: Double = 0
    @State private var clipLength: Double = LivePhotoMaker.clipDurationRange.lowerBound
    @State private var stillFraction: Double = 0.5
    @State private var includesWallpaperMetadata = true

    @State private var output: LivePhotoMaker.Output?
    /// Identifier of the output already saved to Photos, so it is not saved twice.
    @State private var savedAssetIdentifier: String?
    @State private var livePhoto: PHLivePhoto?
    @State private var progress: Double = 0
    @State private var status: String = ""
    @State private var showsWallpaperSteps = false

    @State private var isLoadingVideo = false
    @State private var isMaking = false
    @State private var isSaving = false
    @State private var isLoadingPreview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewArea

                    PhotosPicker(selection: $pickedItem, matching: .videos, preferredItemEncoding: .current) {
                        Label("Choose video", systemImage: "video.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                    if movieURL != nil {
                        clipControls
                    }

                    Button {
                        create()
                    } label: {
                        Label("Create Live Photo", systemImage: "livephoto")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(movieURL == nil || isBusy)

                    if isMaking {
                        ProgressView(value: progress)
                    }

                    Button {
                        save()
                    } label: {
                        Label(saveButtonTitle, systemImage: saveButtonIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(output == nil || isBusy || isSaved)

                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if showsWallpaperSteps {
                        wallpaperSteps
                    }
                }
                .padding()
            }
            .navigationTitle("Live Wallpaper")
            .onChange(of: pickedItem) { _, newItem in
                loadVideo(newItem)
            }
            .onChange(of: clipLength) { _, _ in
                clampStart()
            }
            .onChange(of: clipSettings) { _, _ in
                settingsChanged()
            }
        }
    }

    // MARK: Derived values

    private struct ClipSettings: Equatable {
        var start: Double
        var length: Double
        var still: Double
        var wallpaperMetadata: Bool
    }

    private var clipSettings: ClipSettings {
        ClipSettings(
            start: startTime,
            length: clipLength,
            still: stillFraction,
            wallpaperMetadata: includesWallpaperMetadata
        )
    }

    private var isBusy: Bool {
        isLoadingVideo || isMaking || isSaving
    }

    private var isSaved: Bool {
        guard let output else { return false }
        return savedAssetIdentifier == output.assetIdentifier
    }

    private var saveButtonTitle: String {
        isSaved ? "Saved to Photos" : "Save to Photos"
    }

    private var saveButtonIcon: String {
        isSaved ? "checkmark.circle" : "square.and.arrow.down"
    }

    /// Clip length actually used (a video shorter than 1 s is used whole).
    private var effectiveClipLength: Double {
        min(clipLength, movieDuration)
    }

    private var latestStart: Double {
        max(0, movieDuration - effectiveClipLength)
    }

    private var maxClipLength: Double {
        min(LivePhotoMaker.clipDurationRange.upperBound, movieDuration)
    }

    private var canChangeClipLength: Bool {
        maxClipLength > LivePhotoMaker.clipDurationRange.lowerBound + 0.05
    }

    private var keyPhotoTime: Double {
        startTime + stillFraction * effectiveClipLength
    }

    private var speedNote: String {
        let speed = effectiveClipLength / LivePhotoMaker.outputSeconds
        if speed > 1.01 {
            return String(format: "Plays %.1fx faster to fit the 1-second Live Photo.", speed)
        }
        if speed < 0.99 {
            return "The whole video is used and slowed down to fill 1 second."
        }
        return "Plays at normal speed as a 1-second Live Photo."
    }

    private var metadataNote: String {
        if includesWallpaperMetadata {
            return "Adds the extra metadata the Lock Screen needs to play the motion."
        }
        return "Basic Live Photo only. It plays in Photos, but the Lock Screen will likely say Motion not available."
    }

    private var placeholderText: String {
        if isLoadingVideo { return "Loading video…" }
        if isMaking { return "Creating Live Photo…" }
        if isLoadingPreview { return "Loading preview…" }
        if output != nil { return "Preview not available. You can still save it." }
        if movieURL != nil { return "Video ready (\(seconds(movieDuration))). Choose the part to use below." }
        return "No video selected"
    }

    // MARK: Subviews

    @ViewBuilder
    private var previewArea: some View {
        if let livePhoto {
            VStack(spacing: 6) {
                LivePhotoView(livePhoto: livePhoto)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "livephoto")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(10)
                    }
                Text("Press and hold the preview to play it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 420)
                .overlay {
                    VStack(spacing: 12) {
                        if isLoadingVideo || isMaking || isLoadingPreview {
                            ProgressView()
                        }
                        Text(placeholderText)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
        }
    }

    private var clipControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video length: \(seconds(movieDuration))")
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Start: \(seconds(startTime))")
                Slider(value: $startTime, in: 0...max(latestStart, 0.1))
                    .disabled(latestStart <= 0 || isBusy)
                    .accessibilityLabel("Start time")
            }

            VStack(alignment: .leading, spacing: 4) {
                if canChangeClipLength {
                    Text("Clip length: \(seconds(effectiveClipLength))")
                    Slider(
                        value: $clipLength,
                        in: LivePhotoMaker.clipDurationRange.lowerBound...maxClipLength,
                        step: 0.1
                    )
                    .disabled(isBusy)
                    .accessibilityLabel("Clip length")
                } else {
                    Text("Clip length: \(seconds(effectiveClipLength))")
                }
                Text(speedNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Key photo at \(preciseSeconds(keyPhotoTime))")
                    Spacer()
                    Button("Middle") {
                        stillFraction = 0.5
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || abs(stillFraction - 0.5) < 0.001)
                }
                Slider(value: $stillFraction, in: 0...1)
                    .disabled(isBusy)
                    .accessibilityLabel("Key photo position")
                Text("The still shown before the motion plays. The middle of the clip is the setting reported to work for Lock Screen motion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Lock Screen motion data", isOn: $includesWallpaperMetadata)
                .disabled(isBusy)
            Text(metadataNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wallpaperSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set it as your Lock Screen")
                .font(.headline)
            Text("1. Turn off Low Power Mode (Settings > Battery). It stops wallpaper motion. Reduce Motion (Settings > Accessibility > Motion) can stop it too.")
            Text("2. In Photos, open the new Live Photo and tap Share > Use as Wallpaper. Or go to Settings > Wallpaper > Add New Wallpaper, choose Live Photo (or Photos) and pick it.")
            Text("3. Make sure the Live button (circle in a circle) at the bottom is on, then tap Add > Set as Wallpaper Pair.")
            Text("4. Lock and wake the phone: the clip plays on the Lock Screen. The Home Screen stays still, and there is no sound.")
            Text("If it says Motion not available, tap Cancel and try again, or create it from a steadier part of the video.")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    private func loadVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isLoadingVideo = true
        status = ""
        showsWallpaperSteps = false
        discardOutput()
        // The previous clip goes right away, so Create can never use it for the new selection.
        discardMovie()
        Task {
            defer { isLoadingVideo = false }
            let movie: PickedMovie
            do {
                guard let loaded = try await item.loadTransferable(type: PickedMovie.self) else {
                    failLoading("Could not load that video.")
                    return
                }
                movie = loaded
            } catch {
                failLoading("Could not load that video: \(error.localizedDescription)")
                return
            }
            let duration: Double
            do {
                duration = try await LivePhotoMaker.videoDuration(of: movie.url)
            } catch {
                try? FileManager.default.removeItem(at: movie.url)
                failLoading("Could not load that video: \(error.localizedDescription)")
                return
            }
            guard duration.isFinite, duration >= LivePhotoMaker.minimumSourceDuration else {
                try? FileManager.default.removeItem(at: movie.url)
                let tooShort = LivePhotoError.videoTooShort(seconds: duration.isFinite ? duration : 0)
                failLoading(tooShort.localizedDescription)
                return
            }
            movieURL = movie.url
            movieDuration = duration
            clipLength = LivePhotoMaker.clipDurationRange.lowerBound
            startTime = 0
            stillFraction = 0.5
            status = "Choose the part to use, then tap Create Live Photo."
        }
    }

    /// Shows why the video could not be used and clears the picker, so the same video can be picked again.
    private func failLoading(_ message: String) {
        status = message
        pickedItem = nil
    }

    private func create() {
        guard let movieURL else { return }
        let length = effectiveClipLength
        let options = LivePhotoMaker.Options(
            startTime: startTime,
            clipDuration: length,
            stillTime: stillFraction * length,
            includesWallpaperMetadata: includesWallpaperMetadata
        )
        discardOutput()
        isMaking = true
        progress = 0
        showsWallpaperSteps = false
        status = "Creating Live Photo…"
        Task {
            do {
                let result = try await LivePhotoMaker().make(from: movieURL, options: options) { value in
                    Task { @MainActor in
                        self.progress = value
                    }
                }
                output = result
                isMaking = false
                status = "Live Photo ready: \(seconds(result.duration)) long, key photo at \(preciseSeconds(result.stillTime)). Tap Save to Photos to keep it."
                await loadPreview(for: result)
            } catch {
                isMaking = false
                status = "Could not create the Live Photo: \(error.localizedDescription)"
            }
        }
    }

    private func loadPreview(for result: LivePhotoMaker.Output) async {
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let photo = try await LivePhotoLoader.load(photoURL: result.photoURL, videoURL: result.videoURL)
            if output == result {
                livePhoto = photo
            }
        } catch {
            if output == result {
                status += " The preview could not load (\(error.localizedDescription)), but you can still save it."
            }
        }
    }

    private func save() {
        guard let output else { return }
        isSaving = true
        showsWallpaperSteps = false
        status = "Saving to Photos…"
        Task {
            defer { isSaving = false }
            do {
                try await LivePhotoLibrary.save(output)
                savedAssetIdentifier = output.assetIdentifier
                status = "Saved to Photos as a Live Photo. It keeps working after this app's signing expires."
                showsWallpaperSteps = true
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// A Live Photo made with other settings no longer matches the controls, so it is dropped.
    private func settingsChanged() {
        guard output != nil, !isBusy else { return }
        discardOutput()
        showsWallpaperSteps = false
        status = "Settings changed. Tap Create Live Photo again."
    }

    private func clampStart() {
        if startTime > latestStart {
            startTime = latestStart
        }
    }

    private func discardOutput() {
        output?.removeFiles()
        output = nil
        savedAssetIdentifier = nil
        livePhoto = nil
    }

    private func discardMovie() {
        if let movieURL {
            try? FileManager.default.removeItem(at: movieURL)
        }
        movieURL = nil
        movieDuration = 0
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }

    private func preciseSeconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }
}
