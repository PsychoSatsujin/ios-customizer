import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

// MARK: - Errors

/// Everything that can go wrong while making or saving a Live Photo, worded for the status line.
enum LivePhotoError: LocalizedError {
    case noVideoTrack
    case videoTooShort(seconds: Double)
    case unreadableVideo(String)
    case compositionFailed(String)
    case encoderUnavailable
    case templateUnavailable(String)
    case metadataFormatFailed(OSStatus)
    case readerFailed(String)
    case writerFailed(String)
    case stillFrameFailed(String)
    case imageWriteFailed
    case photosAccessDenied
    case filesMissing
    case saveFailed(String)
    case previewFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file has no video in it."
        case .videoTooShort(let seconds):
            return String(
                format: "The video is too short (%.2f s). Pick one that is at least %.2f s long.",
                seconds,
                LivePhotoMaker.minimumSourceDuration
            )
        case .unreadableVideo(let reason):
            return "Could not read the video: \(reason)"
        case .compositionFailed(let reason):
            return "Could not cut the clip: \(reason)"
        case .encoderUnavailable:
            return "This device cannot encode H.264 video at that size."
        case .templateUnavailable(let reason):
            return "Could not prepare the Lock Screen metadata: \(reason)"
        case .metadataFormatFailed(let status):
            return "Could not describe the Live Photo metadata (error \(status))."
        case .readerFailed(let reason):
            return "Could not read the video frames: \(reason)"
        case .writerFailed(let reason):
            return "Could not write the Live Photo movie: \(reason)"
        case .stillFrameFailed(let reason):
            return "Could not grab the key photo from the movie: \(reason)"
        case .imageWriteFailed:
            return "Could not write the key photo."
        case .photosAccessDenied:
            return "Photos access is off. Allow it in Settings > Privacy & Security > Photos > Customize."
        case .filesMissing:
            return "The Live Photo files are gone. Create it again."
        case .saveFailed(let reason):
            return "Could not save to Photos: \(reason)"
        case .previewFailed(let reason):
            return "Could not show the preview: \(reason)"
        }
    }
}

// MARK: - Maker

/// Turns a video into a Live Photo resource pair (still image + QuickTime movie) that Photos
/// accepts and that the Lock Screen can play as a moving wallpaper.
///
/// The output always follows the only format reported to work for Lock Screen motion:
/// 1080x1920 portrait, 60 fps, exactly 1 second (longer source clips are sped up to fit),
/// H.264, no audio, plus the two "neutral" timed-metadata tracks of `TemplateData`
/// (live-photo-info and still-image-time + still-image-transform).
struct LivePhotoMaker: Sendable {
    // MARK: Output spec

    static let frameRate: Int32 = 60
    static let frameCount: Int = 60
    /// Length of every Live Photo movie: 60 frames at 60 fps = 1.0 s.
    static var outputDuration: CMTime { CMTime(value: CMTimeValue(frameCount), timescale: frameRate) }
    static var outputSeconds: Double { Double(frameCount) / Double(frameRate) }
    static var defaultRenderSize: CGSize { CGSize(width: 1080, height: 1920) }
    /// How much of the source the user may pick. Anything above 1 s is sped up into the 1 s movie.
    static let clipDurationRange: ClosedRange<Double> = 1.0...3.0
    /// Shorter sources are slowed down to fill the second; below this there is nothing useful left.
    static let minimumSourceDuration: Double = 0.25
    static var defaultWorkDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotos", isDirectory: true)
    }

    // MARK: Metadata keys

    static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    static let stillImageTimeIdentifier = "mdta/com.apple.quicktime.still-image-time"
    static let stillImageTransformIdentifier = "mdta/com.apple.quicktime.live-photo-still-image-transform"
    static let livePhotoInfoIdentifier = "mdta/com.apple.quicktime.live-photo-info"
    /// MakerApple tag 17 holds the asset identifier that pairs the still with its movie.
    static let makerAppleAssetIdentifierKey = "17"

    // MARK: Types

    struct Options: Sendable, Equatable {
        /// Where the clip starts in the source video, in seconds.
        var startTime: Double
        /// Seconds of source video to use, clamped to `clipDurationRange` and to the video length.
        /// The Live Photo always lasts 1 s; longer clips play faster.
        var clipDuration: Double
        /// Key photo position in seconds from the clip start (source time). `nil` means the middle,
        /// which is the setting reported to work for Lock Screen motion.
        var stillTime: Double?
        /// Output frame size. Aspect-fill: the picture is scaled to cover it and the overflow is cropped.
        var renderSize: CGSize
        /// Adds the Lock Screen wallpaper metadata tracks. When false only a classic still-image-time
        /// track is written: still a valid Live Photo in Photos, but the Lock Screen shows no motion.
        var includesWallpaperMetadata: Bool

        init(
            startTime: Double = 0,
            clipDuration: Double = 1.0,
            stillTime: Double? = nil,
            renderSize: CGSize = LivePhotoMaker.defaultRenderSize,
            includesWallpaperMetadata: Bool = true
        ) {
            self.startTime = startTime
            self.clipDuration = clipDuration
            self.stillTime = stillTime
            self.renderSize = renderSize
            self.includesWallpaperMetadata = includesWallpaperMetadata
        }
    }

    /// Options resolved against a concrete source video.
    struct Plan: Equatable {
        /// Seconds from the start of the source video track.
        let sourceStart: Double
        /// Seconds of source video squeezed (or stretched) into the 1 s movie.
        let sourceLength: Double
        /// Frame of the output movie used as the key photo, 0..<frameCount.
        let stillFrameIndex: Int
        let renderSize: CGSize

        var stillTime: CMTime { CMTime(value: CMTimeValue(stillFrameIndex), timescale: LivePhotoMaker.frameRate) }
        /// Playback speed relative to the source (2.0 = twice as fast).
        var speed: Double { sourceLength / CMTimeGetSeconds(LivePhotoMaker.outputDuration) }
    }

    struct Output: Sendable, Equatable {
        let photoURL: URL
        let videoURL: URL
        let assetIdentifier: String
        /// Length of the Live Photo movie in seconds.
        let duration: Double
        /// Where the key photo sits in the movie, in seconds.
        let stillTime: Double
        let sourceStart: Double
        let sourceLength: Double

        func removeFiles() {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)
        }
    }

    private struct TemplateTrack {
        let track: AVAssetTrack
        /// Passthrough metadata writer inputs need the source format as a hint.
        let format: CMFormatDescription
        let isStill: Bool
    }

    struct SourceInfo {
        /// Kept so the track's (weakly referenced) asset stays alive while it is used.
        let asset: AVURLAsset
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let timeRange: CMTimeRange

        var duration: Double { CMTimeGetSeconds(timeRange.duration) }
    }

    // MARK: Init

    let workDirectory: URL

    init(workDirectory: URL = LivePhotoMaker.defaultWorkDirectory) {
        self.workDirectory = workDirectory
    }

    // MARK: Public API

    /// Length of the first video track, in seconds.
    static func videoDuration(of url: URL) async throws -> Double {
        let info = try await loadSource(url)
        return info.duration
    }

    /// Builds the Live Photo pair. `progress` (0...1) is called from a background queue.
    func make(
        from sourceURL: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Output {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let source = try await Self.loadSource(sourceURL)
        let plan = try Self.plan(sourceDuration: source.duration, options: options)
        try Task.checkCancellation()

        let assetIdentifier = UUID().uuidString
        let baseURL = workDirectory.appendingPathComponent(assetIdentifier)
        let videoURL = baseURL.appendingPathExtension("mov")
        try? fileManager.removeItem(at: videoURL)

        progress?(0)
        do {
            try await writeMovie(
                source: source,
                plan: plan,
                assetIdentifier: assetIdentifier,
                includesWallpaperMetadata: options.includesWallpaperMetadata,
                to: videoURL,
                progress: progress
            )
        } catch {
            try? fileManager.removeItem(at: videoURL)
            throw error
        }
        progress?(0.92)

        // The key photo is taken from the finished movie so both show exactly the same frame.
        let photoURL: URL
        do {
            photoURL = try await Self.writeStillImage(
                fromMovieAt: videoURL,
                at: plan.stillTime,
                assetIdentifier: assetIdentifier,
                baseURL: baseURL
            )
        } catch {
            try? fileManager.removeItem(at: videoURL)
            throw error
        }
        progress?(1)

        withExtendedLifetime(source.asset) {}
        return Output(
            photoURL: photoURL,
            videoURL: videoURL,
            assetIdentifier: assetIdentifier,
            duration: CMTimeGetSeconds(Self.outputDuration),
            stillTime: CMTimeGetSeconds(plan.stillTime),
            sourceStart: plan.sourceStart,
            sourceLength: plan.sourceLength
        )
    }

    // MARK: Planning (pure, unit-tested)

    static func plan(sourceDuration: Double, options: Options) throws -> Plan {
        guard sourceDuration.isFinite, sourceDuration >= minimumSourceDuration else {
            throw LivePhotoError.videoTooShort(seconds: sourceDuration.isFinite ? sourceDuration : 0)
        }
        let requestedLength = options.clipDuration.isFinite ? options.clipDuration : clipDurationRange.lowerBound
        let clampedLength = min(max(requestedLength, clipDurationRange.lowerBound), clipDurationRange.upperBound)
        let length = min(clampedLength, sourceDuration)

        let latestStart = max(0, sourceDuration - length)
        let requestedStart = options.startTime.isFinite ? options.startTime : 0
        let start = min(max(requestedStart, 0), latestStart)

        let fraction: Double
        if let stillTime = options.stillTime, stillTime.isFinite, length > 0 {
            fraction = min(max(stillTime / length, 0), 1)
        } else {
            fraction = 0.5
        }
        let index = min(max(Int((fraction * Double(frameCount)).rounded()), 0), frameCount - 1)

        return Plan(
            sourceStart: start,
            sourceLength: length,
            stillFrameIndex: index,
            renderSize: sanitizedRenderSize(options.renderSize)
        )
    }

    /// Even pixel sizes between 16 and 4096; anything unusable falls back to 1080x1920.
    static func sanitizedRenderSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width >= 16, size.height >= 16 else {
            return defaultRenderSize
        }
        func even(_ value: CGFloat) -> CGFloat {
            // Clamp before converting: Int(_:) traps on huge (but finite) values.
            let rounded = Int(min(value, 4096).rounded())
            return CGFloat(rounded - rounded % 2)
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Transform that shows the track upright (honouring `preferredTransform`), scaled to cover
    /// `renderSize` and centred, so the overflow is cropped evenly.
    static func aspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(bounds.width)
        let height = abs(bounds.height)
        guard width > 0, height > 0 else { return preferredTransform }
        let scale = max(renderSize.width / width, renderSize.height / height)
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (renderSize.width - width * scale) / 2,
                y: (renderSize.height - height * scale) / 2
            ))
    }

    /// Identifiers ("mdta/...") declared by a timed-metadata format description.
    static func metadataIdentifiers(of formatDescription: CMFormatDescription) -> [String] {
        (CMMetadataFormatDescriptionGetIdentifiers(formatDescription) as? [String]) ?? []
    }

    // MARK: Source

    static func loadSource(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        do {
            let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw LivePhotoError.noVideoTrack }
            let naturalSize: CGSize = try await track.load(.naturalSize)
            let preferredTransform: CGAffineTransform = try await track.load(.preferredTransform)
            let timeRange: CMTimeRange = try await track.load(.timeRange)
            guard naturalSize.width > 0, naturalSize.height > 0 else {
                throw LivePhotoError.unreadableVideo("The video has no picture size.")
            }
            return SourceInfo(
                asset: asset,
                track: track,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                timeRange: timeRange
            )
        } catch let error as LivePhotoError {
            throw error
        } catch {
            throw LivePhotoError.unreadableVideo(error.localizedDescription)
        }
    }

    // MARK: Movie

    private func writeMovie(
        source: SourceInfo,
        plan: Plan,
        assetIdentifier: String,
        includesWallpaperMetadata: Bool,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let outputDuration = Self.outputDuration
        let renderSize = plan.renderSize

        // 1. Composition: the chosen range, retimed to exactly one second.
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoError.compositionFailed("Could not add a video track.")
        }
        let insertStart = CMTimeAdd(
            source.timeRange.start,
            CMTime(seconds: plan.sourceStart, preferredTimescale: 600)
        )
        let available = CMTimeSubtract(CMTimeRangeGetEnd(source.timeRange), insertStart)
        let insertDuration = CMTimeMinimum(
            CMTime(seconds: plan.sourceLength, preferredTimescale: 600),
            available
        )
        guard CMTimeCompare(insertDuration, .zero) > 0 else {
            throw LivePhotoError.compositionFailed("The selected part of the video is empty.")
        }
        do {
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: insertStart, duration: insertDuration),
                of: source.track,
                at: .zero
            )
        } catch {
            throw LivePhotoError.compositionFailed(error.localizedDescription)
        }
        if CMTimeCompare(insertDuration, outputDuration) != 0 {
            compositionTrack.scaleTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                toDuration: outputDuration
            )
        }

        // 2. Video composition: upright, aspect-fill, 60 fps.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(
            Self.aspectFillTransform(
                naturalSize: source.naturalSize,
                preferredTransform: source.preferredTransform,
                renderSize: renderSize
            ),
            at: .zero
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: outputDuration)
        instruction.layerInstructions = [layerInstruction]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: Self.frameRate)
        videoComposition.instructions = [instruction]
        // Always SDR Rec. 709: HDR (HLG) iPhone clips are tone-mapped here instead of coming out
        // as 8-bit frames still tagged HDR.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // 3. Reader for the rendered frames.
        let videoReader: AVAssetReader
        do {
            videoReader = try AVAssetReader(asset: composition)
        } catch {
            throw LivePhotoError.readerFailed(error.localizedDescription)
        }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compositionTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard videoReader.canAdd(videoOutput) else {
            throw LivePhotoError.readerFailed("The video frames cannot be read.")
        }
        videoReader.add(videoOutput)

        // 4. Writer: QuickTime movie with the content identifier that pairs it with the still.
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw LivePhotoError.writerFailed(error.localizedDescription)
        }
        writer.metadata = Self.movieMetadata(assetIdentifier: assetIdentifier)

        let videoSettings = Self.videoOutputSettings(renderSize: renderSize)
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw LivePhotoError.encoderUnavailable
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw LivePhotoError.writerFailed("The video track cannot be added.")
        }
        writer.add(videoInput)

        let outputSeconds = CMTimeGetSeconds(outputDuration)
        var pumps: [SamplePump] = [
            SamplePump(
                label: "video",
                output: videoOutput,
                input: videoInput,
                didAppend: { buffer in
                    guard let progress else { return }
                    let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                    guard seconds.isFinite else { return }
                    progress(0.9 * min(max((seconds + 1.0 / 60.0) / outputSeconds, 0), 1))
                }
            )
        ]

        // 5. Timed metadata: wallpaper template tracks, or a classic still-image-time track.
        var metadataReader: AVAssetReader?
        var stillAdaptor: AVAssetWriterInputMetadataAdaptor?
        var templateURL: URL?
        defer {
            if let templateURL {
                try? FileManager.default.removeItem(at: templateURL)
            }
        }
        if includesWallpaperMetadata {
            let url = workDirectory.appendingPathComponent("template-\(assetIdentifier).mov")
            do {
                try TemplateData.makeData().write(to: url, options: .atomic)
            } catch {
                throw LivePhotoError.templateUnavailable(error.localizedDescription)
            }
            templateURL = url
            let template = try await Self.makeTemplatePumps(
                templateURL: url,
                writer: writer,
                stillTime: plan.stillTime
            )
            metadataReader = template.reader
            pumps.append(contentsOf: template.pumps)
        } else {
            let adaptor = try Self.makeStillImageTimeAdaptor()
            guard writer.canAdd(adaptor.assetWriterInput) else {
                throw LivePhotoError.writerFailed("The still-image time track cannot be added.")
            }
            writer.add(adaptor.assetWriterInput)
            stillAdaptor = adaptor
        }

        var readers: [AVAssetReader] = [videoReader]
        if let metadataReader {
            readers.append(metadataReader)
        }

        // 6. Run.
        guard writer.startWriting() else {
            throw LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "Writing could not start.")
        }
        guard videoReader.startReading() else {
            Self.abort(writer, readers: readers)
            throw LivePhotoError.readerFailed(videoReader.error?.localizedDescription ?? "Reading could not start.")
        }
        if let metadataReader, !metadataReader.startReading() {
            Self.abort(writer, readers: readers)
            throw LivePhotoError.templateUnavailable(
                metadataReader.error?.localizedDescription ?? "The template could not be read."
            )
        }
        writer.startSession(atSourceTime: .zero)

        if let stillAdaptor {
            var waits = 0
            while !stillAdaptor.assetWriterInput.isReadyForMoreMediaData && waits < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waits += 1
            }
            guard stillAdaptor.append(Self.stillImageTimeGroup(at: plan.stillTime)) else {
                let reason = writer.error?.localizedDescription ?? "The still-image time could not be written."
                Self.abort(writer, readers: readers)
                throw LivePhotoError.writerFailed(reason)
            }
            stillAdaptor.assetWriterInput.markAsFinished()
        }

        // Every input is fed concurrently on its own queue: AVAssetWriter interleaves tracks and
        // can stall if one input is filled to the end before the others.
        for pump in pumps {
            pump.start()
        }
        while !pumps.allSatisfy({ $0.isFinished }) {
            if Task.isCancelled {
                Self.abort(writer, readers: readers)
                throw CancellationError()
            }
            if writer.status == .failed || writer.status == .cancelled {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if videoReader.status == .failed {
            let reason = videoReader.error?.localizedDescription ?? "Unknown error."
            Self.abort(writer, readers: readers)
            throw LivePhotoError.readerFailed(reason)
        }
        if let metadataReader, metadataReader.status == .failed {
            let reason = metadataReader.error?.localizedDescription ?? "Unknown error."
            Self.abort(writer, readers: readers)
            throw LivePhotoError.templateUnavailable(reason)
        }
        if writer.status != .writing || pumps.contains(where: { $0.appendFailed }) {
            let reason = writer.error?.localizedDescription ?? "A frame could not be written."
            Self.abort(writer, readers: readers)
            throw LivePhotoError.writerFailed(reason)
        }

        await Self.finish(writer)
        guard writer.status == .completed else {
            throw LivePhotoError.writerFailed(writer.error?.localizedDescription ?? "The movie could not be finished.")
        }
    }

    /// Copies the template's two mebx tracks (live-photo-info first, then the still track) the way the
    /// working generators do: all 60 live-photo-info samples pass through unchanged (0.05 s to 1.05 s,
    /// slightly past the 1 s video, as in Video2LivePhoto). Only the still sample is moved, to `stillTime`
    /// (0.5 s, the template's own position, unless another key photo was chosen).
    private static func makeTemplatePumps(
        templateURL: URL,
        writer: AVAssetWriter,
        stillTime: CMTime
    ) async throws -> (reader: AVAssetReader, pumps: [SamplePump]) {
        let templateAsset = AVURLAsset(url: templateURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await templateAsset.loadTracks(withMediaType: .metadata)
        } catch {
            throw LivePhotoError.templateUnavailable(error.localizedDescription)
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: templateAsset)
        } catch {
            throw LivePhotoError.templateUnavailable(error.localizedDescription)
        }

        var infoTracks: [TemplateTrack] = []
        var stillTracks: [TemplateTrack] = []
        for track in tracks {
            let formats: [CMFormatDescription]
            do {
                formats = try await track.load(.formatDescriptions)
            } catch {
                throw LivePhotoError.templateUnavailable(error.localizedDescription)
            }
            guard let format: CMFormatDescription = formats.first else {
                throw LivePhotoError.templateUnavailable("A template track has no format.")
            }
            let identifiers: [String] = formats.flatMap { Self.metadataIdentifiers(of: $0) }
            if identifiers.contains(stillImageTimeIdentifier) {
                stillTracks.append(TemplateTrack(track: track, format: format, isStill: true))
            } else if identifiers.contains(livePhotoInfoIdentifier) {
                infoTracks.append(TemplateTrack(track: track, format: format, isStill: false))
            }
        }
        guard !stillTracks.isEmpty else {
            throw LivePhotoError.templateUnavailable("The template has no still-image time track.")
        }
        guard !infoTracks.isEmpty else {
            throw LivePhotoError.templateUnavailable("The template has no live-photo-info track.")
        }

        var pumps: [SamplePump] = []
        for item in infoTracks + stillTracks {
            let output = AVAssetReaderTrackOutput(track: item.track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw LivePhotoError.templateUnavailable("A template track cannot be read.")
            }
            reader.add(output)

            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: item.format)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw LivePhotoError.writerFailed("A Live Photo metadata track cannot be added.")
            }
            writer.add(input)

            if item.isStill {
                let firstSample = LivePhotoOnceFlag()
                pumps.append(SamplePump(label: "still", output: output, input: input, transform: { buffer in
                    guard CMSampleBufferGetNumSamples(buffer) > 0, firstSample.claim() else { return nil }
                    return Self.retimed(buffer, to: stillTime, duration: CMTime(value: 1, timescale: 600)) ?? buffer
                }))
            } else {
                pumps.append(SamplePump(label: "info", output: output, input: input, transform: {
                    (buffer: CMSampleBuffer) -> CMSampleBuffer? in
                    CMSampleBufferGetNumSamples(buffer) > 0 ? buffer : nil
                }))
            }
        }
        return (reader: reader, pumps: pumps)
    }

    static func movieMetadata(assetIdentifier: String) -> [AVMetadataItem] {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = contentIdentifierKey as NSString
        item.value = assetIdentifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }

    static func videoOutputSettings(renderSize: CGSize) -> [String: Any] {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(frameRate)
        ]
        // Matches the SDR Rec. 709 frames the video composition renders.
        let colorProperties: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    /// Writer input + adaptor for a classic `mdta/com.apple.quicktime.still-image-time` (int8) track.
    static func makeStillImageTimeAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: stillImageTimeIdentifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
        ]
        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == 0, let formatDescription else {
            throw LivePhotoError.metadataFormatFailed(status)
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    /// still-image-time = -1 (the value real camera files carry), one 1/600 s sample at `time`.
    static func stillImageTimeGroup(at time: CMTime) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = stillImageTimeKey as NSString
        item.value = NSNumber(value: Int8(-1))
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 600))
        )
    }

    static func retimed(_ buffer: CMSampleBuffer, to presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == 0 else { return nil }
        return copy
    }

    private static func abort(_ writer: AVAssetWriter, readers: [AVAssetReader]) {
        for reader in readers where reader.status == .reading {
            reader.cancelReading()
        }
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private static func finish(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    // MARK: Still image

    /// Grabs the exact frame at `time` from the finished movie and writes it as HEIC (JPEG when HEIC
    /// encoding is unavailable) with MakerApple["17"] = asset identifier.
    static func writeStillImage(
        fromMovieAt movieURL: URL,
        at time: CMTime,
        assetIdentifier: String,
        baseURL: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: movieURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: time).image
        } catch {
            throw LivePhotoError.stillFrameFailed(error.localizedDescription)
        }

        let properties = stillImageProperties(assetIdentifier: assetIdentifier)
        let supportedTypes: [String] = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if supportedTypes.contains(UTType.heic.identifier) {
            let heicURL = baseURL.appendingPathExtension("heic")
            if writeImage(image, to: heicURL, type: UTType.heic.identifier, properties: properties) {
                return heicURL
            }
            try? FileManager.default.removeItem(at: heicURL)
        }
        let jpegURL = baseURL.appendingPathExtension("jpg")
        if writeImage(image, to: jpegURL, type: UTType.jpeg.identifier, properties: properties) {
            return jpegURL
        }
        try? FileManager.default.removeItem(at: jpegURL)
        throw LivePhotoError.imageWriteFailed
    }

    static func stillImageProperties(assetIdentifier: String) -> [String: Any] {
        [
            kCGImagePropertyMakerAppleDictionary as String: [makerAppleAssetIdentifierKey: assetIdentifier],
            kCGImagePropertyOrientation as String: 1,
            kCGImageDestinationLossyCompressionQuality as String: 0.92
        ]
    }

    private static func writeImage(_ image: CGImage, to url: URL, type: String, properties: [String: Any]) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

// MARK: - Saving

enum LivePhotoLibrary {
    /// Asks for add-only Photos access and saves the pair as one Live Photo asset.
    static func save(_ output: LivePhotoMaker.Output) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: output.photoURL.path),
              fileManager.fileExists(atPath: output.videoURL.path) else {
            throw LivePhotoError.filesMissing
        }
        let status: PHAuthorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw LivePhotoError.photosAccessDenied
        }
        let photoURL = output.photoURL
        let videoURL = output.videoURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }
        } catch {
            throw LivePhotoError.saveFailed(error.localizedDescription)
        }
    }
}

// MARK: - Helpers

/// Thread-safe "first caller wins" flag.
final class LivePhotoOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true exactly once.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Moves samples from one reader output to one writer input on its own serial queue.
fileprivate final class SamplePump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    /// Returns the buffer to append, or nil to skip it.
    private let transform: (CMSampleBuffer) -> CMSampleBuffer?
    private let didAppend: ((CMSampleBuffer) -> Void)?
    private let lock = NSLock()
    private var finishedFlag = false
    private var failedFlag = false

    init(
        label: String,
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        transform: @escaping (CMSampleBuffer) -> CMSampleBuffer? = { $0 },
        didAppend: ((CMSampleBuffer) -> Void)? = nil
    ) {
        self.output = output
        self.input = input
        self.queue = DispatchQueue(label: "com.personal.customize.livephoto.\(label)")
        self.transform = transform
        self.didAppend = didAppend
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedFlag
    }

    var appendFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failedFlag
    }

    func start() {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            self.drain()
        }
    }

    private func drain() {
        if isFinished { return }
        while input.isReadyForMoreMediaData {
            guard let buffer = output.copyNextSampleBuffer() else {
                finish(failed: false)
                return
            }
            guard let sample = transform(buffer) else { continue }
            if input.append(sample) {
                didAppend?(sample)
            } else {
                finish(failed: true)
                return
            }
        }
    }

    /// Only called on `queue`.
    private func finish(failed: Bool) {
        if isFinished { return }
        input.markAsFinished()
        lock.lock()
        finishedFlag = true
        if failed { failedFlag = true }
        lock.unlock()
    }
}

// MARK: - Neutral wallpaper template

extension LivePhotoMaker {
    /// Neutral Live Photo metadata template: a QuickTime movie with two timed-metadata ("mebx") tracks
    /// and no video.
    ///  - track 1: mdta/com.apple.quicktime.live-photo-info, 60 identical 144-byte samples,
    ///    1/60 s each, starting at 0.05 s (media timescale 60000)
    ///  - track 2: mdta/com.apple.quicktime.still-image-time (int8 = -1) +
    ///    mdta/com.apple.quicktime.live-photo-still-image-transform (3x3 float64 identity), at 0.5 s
    /// Byte-identical to Util/metadata.mov of github.com/TouSC/Video2LivePhoto (10,768 bytes,
    /// SHA-256 d9aee044...cff800). That repository has no licence file; the bytes are
    /// machine-generated capture metadata, no imagery.
    enum TemplateData {
        static let expectedByteCount: Int = 10768
        static let expectedSHA256Hex: String = "d9aee0440214bfb0fad75cfe8cde11f098b4546a8ff9fff13807a63d12cff800"

        /// ftyp('qt  ') + wide + mdat header (mdat size 0x2221 = 8737 bytes).
        static let headHex: String = """
        00000014667479707174202000000000717420200000000877696465000022216d646174
        """

        /// One boxed live-photo-info sample: size 0x90, local key 1, 136-byte neutral value.
        static let infoSampleHex: String = """
        000000900000000103000000bdc36d3ce3b5eb6d800000007b80ad425a2d64410a08cb3e7feea6bd79e9f63f00008040
        0400ff00000000000000000000000000000000000000000007000000525e873ee66e52bf1b2a6ac4d37862bf761ed23d
        de3f8ec313f52f39b2f04439ff309dbf1a17f1ed1b070000206796ed1b07000000000000000000000000000000000000
        """

        /// One boxed still sample: [9, key 1, int8 0xFF] + [80, key 2, 3x3 big-endian float64 identity].
        static let stillSampleHex: String = """
        0000000900000001ff00000050000000023ff00000000000000000000000000000000000000000000000000000000000
        003ff00000000000000000000000000000000000000000000000000000000000003ff0000000000000
        """

        /// moov box (2003 bytes): mvhd, two mebx traks, moov/meta with a stale content identifier
        /// (ignored: only the tracks are copied).
        static let moovHex: String = """
        000007d36d6f6f760000006c6d76686400000000e22c2d6de22c2d6e0000025800000276000100000100000000000000
        000000000001000000000000000000000000000000010000000000000000000000000000400000000000000000000000
        0000000000000000000000000000000000000003000004137472616b0000005c746b68640000000fe22c2d6de22c2d6e
        000000010000000000000276000000000000000000000000000000000001000000000000000000000000000000010000
        000000000000000000000000400000000000000000000000000000306564747300000028656c73740000000000000002
        0000001effffffff000100000000025800000000000100000000037f6d646961000000206d64686400000000e22c2d6d
        e22c2d6e0000ea600000ea6055c400000000003468646c72000000006d686c726d6574616170706c0000000100000000
        13436f7265204d65646961204d65746164617461000003236d696e6600000020676d686400000018676d696e00000000
        0040800080008000000000000000003868646c720000000064686c72616c69736170706c000000000000000017436f72
        65204d6564696120446174612048616e646c65720000002464696e660000001c6472656600000000000000010000000c
        616c6973000000010000029f7374626c0000022b7374736400000000000000010000021b6d6562780000000000000001
        0000020b6b65797300000203000000010000002f6b6579646d647461636f6d2e6170706c652e717569636b74696d652e
        6c6976652d70686f746f2d696e666f000000436474797000000001636f6d2e6170706c652e717569636b74696d652e63
        6f6d2e6170706c652e717569636b74696d652e6c6976652d70686f746f2d696e666f0000017173657475000001596366
        677662706c6973743030d301020304050c5f10214c69766550686f746f4d657461646174615365747570446174615665
        7273696f6e5d53797374656d56657273696f6e5f10114672616d65776f726b56657273696f6e731001d3060708090a0b
        5f101350726f647563744275696c6456657273696f6e5b50726f647563744e616d655e50726f6475637456657273696f
        6e583231413532373768596950686f6e65204f535431372e30d40d0e0f10111213145a436f72654d6f74696f6e5d434d
        43617074757265436f72655e483130495350536572766963657359436f72654d6564696158323836382e302e32573434
        362e352e335432302e325e333034352e36392e322e31312e340008000f0033004100550057005e00740080008f009800
        a200a700b000bb00c900d800e200eb00f300f80000000000000201000000000000001500000000000000000000000000
        0001070000001064696d7300000780000005a00000001863747073000000106474797000000000000000000000001873
        74747300000000000000010000003c000003e80000002873747363000000000000000200000001000000110000000100
        0000020000002b00000001000000147374737a00000000000000900000003c000000187374636f000000000000000200
        00002400000a0d000002a07472616b0000005c746b68640000000fe22c2d6de22c2d6e00000002000000000000012d00
        000000000000000000000000000000000100000000000000000000000000000001000000000000000000000000000040
        0000000000000000000000000000306564747300000028656c737400000000000000020000012cffffffff0001000000
        00000100000000000100000000020c6d646961000000206d64686400000000e22c2d6de22c2d6e000002580000000155
        c400000000003468646c72000000006d686c726d6574616170706c000000010000000013436f7265204d65646961204d
        65746164617461000001b06d696e6600000020676d686400000018676d696e0000000000408000800080000000000000
        00003868646c720000000064686c72616c69736170706c000000000000000017436f7265204d65646961204461746120
        48616e646c65720000002464696e660000001c6472656600000000000000010000000c616c6973000000010000012c73
        74626c000000c8737473640000000000000001000000b86d6562780000000000000001000000a86b6579730000004800
        000001000000306b6579646d647461636f6d2e6170706c652e717569636b74696d652e7374696c6c2d696d6167652d74
        696d65000000106474797000000000000000410000005800000002000000406b6579646d647461636f6d2e6170706c65
        2e717569636b74696d652e6c6976652d70686f746f2d7374696c6c2d696d6167652d7472616e73666f726d0000001064
        74797000000000000000530000001873747473000000000000000100000001000000010000001c737473630000000000
        000001000000010000000100000001000000147374737a000000000000005900000001000000147374636f0000000000
        000001000009b4000000ac6d6574610000002268646c7200000000000000006d64746100000000000000000000000000
        000000003e6b65797300000000000000010000002e6d647461636f6d2e6170706c652e717569636b74696d652e636f6e
        74656e742e6964656e74696669657200000044696c73740000003c000000010000003464617461000000010000000041
        354643413542422d423742362d344638382d393431342d334238343234384444353037
        """

        /// File layout: head | info x17 | still | info x43 | moov (stco offsets 36, 2484, 2573).
        static func makeData() -> Data {
            let info: [UInt8] = bytes(infoSampleHex)
            var out: [UInt8] = bytes(headHex)
            out.reserveCapacity(expectedByteCount)
            for _ in 0..<17 { out.append(contentsOf: info) }
            out.append(contentsOf: bytes(stillSampleHex))
            for _ in 0..<43 { out.append(contentsOf: info) }
            out.append(contentsOf: bytes(moovHex))
            return Data(out)
        }

        /// Hex decoder that skips whitespace and newlines.
        static func bytes(_ hex: String) -> [UInt8] {
            var result: [UInt8] = []
            result.reserveCapacity(hex.utf8.count / 2)
            var high: UInt8?
            for character in hex.utf8 {
                let value: UInt8
                switch character {
                case 48...57: value = character - 48
                case 97...102: value = character - 87
                case 65...70: value = character - 55
                default: continue
                }
                if let pending = high {
                    result.append((pending << 4) | value)
                    high = nil
                } else {
                    high = value
                }
            }
            return result
        }
    }
}
