import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import ImageIO
import Photos
import UIKit
import XCTest
@testable import Customize

final class LivePhotoMakerTests: XCTestCase {
    // MARK: - Pure logic

    func testTemplateBytesMatchVerifiedReference() {
        let data = LivePhotoMaker.TemplateData.makeData()
        XCTAssertEqual(data.count, 10768)
        XCTAssertEqual(data.count, LivePhotoMaker.TemplateData.expectedByteCount)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, LivePhotoMaker.TemplateData.expectedSHA256Hex)
    }

    func testPlanClampsRequestedTiming() throws {
        let tooLong = try LivePhotoMaker.plan(
            sourceDuration: 5,
            options: LivePhotoMaker.Options(startTime: 4.5, clipDuration: 10)
        )
        XCTAssertEqual(tooLong.sourceLength, 3, accuracy: 1e-9)
        XCTAssertEqual(tooLong.sourceStart, 2, accuracy: 1e-9)
        XCTAssertEqual(tooLong.stillFrameIndex, 30)
        XCTAssertEqual(CMTimeGetSeconds(tooLong.stillTime), 0.5, accuracy: 1e-9)
        XCTAssertEqual(tooLong.speed, 3, accuracy: 1e-9)
        XCTAssertEqual(tooLong.renderSize, CGSize(width: 1080, height: 1920))

        let tooShort = try LivePhotoMaker.plan(
            sourceDuration: 5,
            options: LivePhotoMaker.Options(startTime: -3, clipDuration: 0.2, stillTime: 0.25)
        )
        XCTAssertEqual(tooShort.sourceLength, 1, accuracy: 1e-9)
        XCTAssertEqual(tooShort.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(tooShort.stillFrameIndex, 15)

        let shortVideo = try LivePhotoMaker.plan(sourceDuration: 0.6, options: LivePhotoMaker.Options())
        XCTAssertEqual(shortVideo.sourceLength, 0.6, accuracy: 1e-9)
        XCTAssertEqual(shortVideo.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(shortVideo.stillFrameIndex, 30)

        let lateStill = try LivePhotoMaker.plan(
            sourceDuration: 5,
            options: LivePhotoMaker.Options(stillTime: 99)
        )
        XCTAssertEqual(lateStill.stillFrameIndex, LivePhotoMaker.frameCount - 1)

        let oddSize = try LivePhotoMaker.plan(
            sourceDuration: 5,
            options: LivePhotoMaker.Options(renderSize: CGSize(width: 721, height: 1281))
        )
        XCTAssertEqual(oddSize.renderSize, CGSize(width: 720, height: 1280))

        XCTAssertThrowsError(try LivePhotoMaker.plan(sourceDuration: 0.1, options: LivePhotoMaker.Options()))
        XCTAssertThrowsError(try LivePhotoMaker.plan(sourceDuration: .nan, options: LivePhotoMaker.Options()))
    }

    func testAspectFillTransformKeepsPortraitVideoUprightAndCoversFrame() {
        let render = CGSize(width: 1080, height: 1920)
        let encoded = CGSize(width: TestVideoFactory.encodedWidth, height: TestVideoFactory.encodedHeight)

        let portrait = LivePhotoMaker.aspectFillTransform(
            naturalSize: encoded,
            preferredTransform: TestVideoFactory.transform(for: .portraitRotated),
            renderSize: render
        )
        let portraitRect = CGRect(origin: .zero, size: encoded).applying(portrait)
        XCTAssertEqual(portraitRect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(portraitRect.minY, 0, accuracy: 0.01)
        XCTAssertEqual(portraitRect.width, 1080, accuracy: 0.01)
        XCTAssertEqual(portraitRect.height, 1920, accuracy: 0.01)
        // The encoded frame's left edge is the top of the upright picture.
        XCTAssertEqual(CGPoint(x: 0, y: 360).applying(portrait).y, 0, accuracy: 0.01)
        XCTAssertEqual(CGPoint(x: 1280, y: 360).applying(portrait).y, 1920, accuracy: 0.01)

        let landscape = LivePhotoMaker.aspectFillTransform(
            naturalSize: encoded,
            preferredTransform: .identity,
            renderSize: render
        )
        let landscapeRect = CGRect(origin: .zero, size: encoded).applying(landscape)
        XCTAssertEqual(landscapeRect.height, 1920, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(landscapeRect.width, 1080)
        XCTAssertEqual(landscapeRect.midX, 540, accuracy: 0.01)
        XCTAssertEqual(landscapeRect.midY, 960, accuracy: 0.01)
    }

    // MARK: - Template movie

    func testTemplateMovieExposesLivePhotoMetadataTracks() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("template.mov")
        try LivePhotoMaker.TemplateData.makeData().write(to: url)

        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty)

        let tracks = try await metadataTracks(of: asset)
        XCTAssertEqual(tracks.count, 2)
        let identifiers = Set(tracks.flatMap { $0.identifiers })
        XCTAssertTrue(identifiers.contains(LivePhotoMaker.livePhotoInfoIdentifier))
        XCTAssertTrue(identifiers.contains(LivePhotoMaker.stillImageTimeIdentifier))
        XCTAssertTrue(identifiers.contains(LivePhotoMaker.stillImageTransformIdentifier))

        let stillTrack = try XCTUnwrap(tracks.first { $0.identifiers.contains(LivePhotoMaker.stillImageTimeIdentifier) })
        let stillSamples = try await readMetadataSamples(of: stillTrack.track, in: asset)
        XCTAssertEqual(stillSamples.count, 1)
        XCTAssertEqual(stillSamples.first?.time ?? -1, 0.5, accuracy: 0.002)

        let infoTrack = try XCTUnwrap(tracks.first { $0.identifiers.contains(LivePhotoMaker.livePhotoInfoIdentifier) })
        let infoSamples = try await readMetadataSamples(of: infoTrack.track, in: asset)
        let infoCount: Int = infoSamples.reduce(0) { $0 + $1.sampleCount }
        XCTAssertEqual(infoCount, 60)
        XCTAssertEqual(infoSamples.first?.time ?? -1, 0.05, accuracy: 0.005)
    }

    // MARK: - End to end

    func testPortraitPhoneVideoBecomesWallpaperReadyLivePhoto() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await TestVideoFactory.makeMovie(orientation: .portraitRotated, in: directory)
        let maker = LivePhotoMaker(workDirectory: directory.appendingPathComponent("output", isDirectory: true))
        let options = LivePhotoMaker.Options(startTime: 0.5, clipDuration: 1.0)
        let recorder = ProgressRecorder()

        let output = try await maker.make(from: source, options: options) { value in
            recorder.record(value)
        }

        // Result and files.
        XCTAssertNotNil(UUID(uuidString: output.assetIdentifier))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.videoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.photoURL.path))
        XCTAssertEqual(output.videoURL.pathExtension, "mov")
        XCTAssertTrue(["heic", "jpg"].contains(output.photoURL.pathExtension))
        XCTAssertEqual(output.sourceStart, 0.5, accuracy: 1e-6)
        XCTAssertEqual(output.sourceLength, 1.0, accuracy: 1e-6)
        XCTAssertEqual(output.stillTime, 0.5, accuracy: 1e-6)
        XCTAssertEqual(recorder.values.last ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertTrue(recorder.values.allSatisfy { $0 >= 0 && $0 <= 1 })

        let asset = AVURLAsset(url: output.videoURL)

        // Movie-level content identifier pairs it with the still.
        let identifier = try await contentIdentifier(of: asset)
        XCTAssertEqual(identifier, output.assetIdentifier)

        // Video: upright 1080x1920, about 60 fps, the requested clip length.
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let naturalSize: CGSize = try await videoTrack.load(.naturalSize)
        let transform: CGAffineTransform = try await videoTrack.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        XCTAssertEqual(displayed.width, 1080, accuracy: 0.5)
        XCTAssertEqual(displayed.height, 1920, accuracy: 0.5)
        let frameRate: Float = try await videoTrack.load(.nominalFrameRate)
        XCTAssertEqual(Double(frameRate), 60, accuracy: 2)
        // The 30 fps source is put on an exact 60 fps grid.
        XCTAssertEqual(try frameCount(of: videoTrack, in: asset), LivePhotoMaker.frameCount)
        let videoRange: CMTimeRange = try await videoTrack.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(videoRange.duration), options.clipDuration, accuracy: 0.05)
        let duration: CMTime = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), options.clipDuration, accuracy: 0.07)
        let audioTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)

        // Timed metadata: live-photo-info plus still-image-time (+ transform) at the key photo.
        let tracks = try await metadataTracks(of: asset)
        XCTAssertEqual(tracks.count, 2)
        let stillTrack = try XCTUnwrap(tracks.first { $0.identifiers.contains(LivePhotoMaker.stillImageTimeIdentifier) })
        XCTAssertTrue(stillTrack.identifiers.contains(LivePhotoMaker.stillImageTransformIdentifier))
        let stillSamples = try await readMetadataSamples(of: stillTrack.track, in: asset)
        XCTAssertEqual(stillSamples.count, 1)
        let stillSample = try XCTUnwrap(stillSamples.first)
        XCTAssertEqual(stillSample.time, output.stillTime, accuracy: 0.002)
        let stillItem = stillSample.group?.items.first { item in
            item.identifier?.rawValue == LivePhotoMaker.stillImageTimeIdentifier
        }
        XCTAssertNotNil(stillItem)
        let stillValue: NSNumber? = try await stillItem?.load(.numberValue)
        XCTAssertEqual(stillValue?.intValue, -1)

        // live-photo-info keeps the template's timeline (0.05 s onwards, 1/60 s apart) up to the end
        // of the video: 57 samples from 0.05 s to 1.0 s.
        let infoTrack = try XCTUnwrap(tracks.first { $0.identifiers.contains(LivePhotoMaker.livePhotoInfoIdentifier) })
        let infoSamples = try await readMetadataSamples(of: infoTrack.track, in: asset)
        let infoCount = infoSamples.reduce(0) { $0 + $1.sampleCount }
        XCTAssertEqual(infoCount, 57)
        XCTAssertEqual(infoSamples.first?.time ?? -1, 0.05, accuracy: 0.005)
        XCTAssertEqual(infoSamples.last?.time ?? -1, 0.05 + 56.0 / 60.0, accuracy: 0.005)
        let infoRange: CMTimeRange = try await infoTrack.track.load(.timeRange)
        XCTAssertEqual(CMTimeGetSeconds(CMTimeRangeGetEnd(infoRange)), 1.0, accuracy: 0.02)

        // Still image: paired by MakerApple 17, same size as the video, upright.
        let properties = try imageProperties(at: output.photoURL)
        let makerApple = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        XCTAssertEqual(makerApple[LivePhotoMaker.makerAppleAssetIdentifierKey] as? String, output.assetIdentifier)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 1080)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 1920)
        let image = try loadImage(at: output.photoURL)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1920)
        try assertColor(of: image, x: 0.5, y: 0.25, isRed: true)
        try assertColor(of: image, x: 0.5, y: 0.75, isRed: false)
    }

    func testLandscapeLongerClipIsCroppedAndSpedUpToOneSecond() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await TestVideoFactory.makeMovie(orientation: .landscape, in: directory)
        let maker = LivePhotoMaker(workDirectory: directory.appendingPathComponent("output", isDirectory: true))
        let options = LivePhotoMaker.Options(startTime: 0.25, clipDuration: 2.0, stillTime: 1.0)

        let output = try await maker.make(from: source, options: options)

        XCTAssertEqual(output.sourceLength, 2.0, accuracy: 1e-6)
        XCTAssertEqual(output.duration, 1.0, accuracy: 1e-6)
        XCTAssertEqual(output.stillTime, 0.5, accuracy: 1e-6)

        let asset = AVURLAsset(url: output.videoURL)
        let duration: CMTime = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.07)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let naturalSize: CGSize = try await videoTrack.load(.naturalSize)
        let transform: CGAffineTransform = try await videoTrack.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        XCTAssertEqual(displayed.width, 1080, accuracy: 0.5)
        XCTAssertEqual(displayed.height, 1920, accuracy: 0.5)
        let identifier = try await contentIdentifier(of: asset)
        XCTAssertEqual(identifier, output.assetIdentifier)

        // Centre crop of a red | blue frame keeps red on the left and blue on the right.
        let image = try loadImage(at: output.photoURL)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1920)
        try assertColor(of: image, x: 0.25, y: 0.5, isRed: true)
        try assertColor(of: image, x: 0.75, y: 0.5, isRed: false)
    }

    func testBasicModeWritesStillImageTimeThroughMetadataAdaptor() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await TestVideoFactory.makeMovie(orientation: .portraitRotated, in: directory)
        let maker = LivePhotoMaker(workDirectory: directory.appendingPathComponent("output", isDirectory: true))
        let options = LivePhotoMaker.Options(clipDuration: 1.0, stillTime: 0.25, includesWallpaperMetadata: false)

        let output = try await maker.make(from: source, options: options)
        XCTAssertEqual(output.stillTime, 0.25, accuracy: 1e-6)

        let asset = AVURLAsset(url: output.videoURL)
        let identifier = try await contentIdentifier(of: asset)
        XCTAssertEqual(identifier, output.assetIdentifier)

        let tracks = try await metadataTracks(of: asset)
        XCTAssertEqual(tracks.count, 1)
        let stillTrack = try XCTUnwrap(tracks.first)
        XCTAssertEqual(stillTrack.identifiers, [LivePhotoMaker.stillImageTimeIdentifier])
        let samples = try await readMetadataSamples(of: stillTrack.track, in: asset)
        XCTAssertEqual(samples.count, 1)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.time, 0.25, accuracy: 0.002)
        let item = sample.group?.items.first
        XCTAssertEqual(item?.identifier?.rawValue, LivePhotoMaker.stillImageTimeIdentifier)
        let value: NSNumber? = try await item?.load(.numberValue)
        XCTAssertEqual(value?.intValue, -1)

        let properties = try imageProperties(at: output.photoURL)
        let makerApple = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        XCTAssertEqual(makerApple[LivePhotoMaker.makerAppleAssetIdentifierKey] as? String, output.assetIdentifier)
    }

    func testPHLivePhotoRequestYieldsNonDegradedLivePhoto() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await TestVideoFactory.makeMovie(orientation: .portraitRotated, in: directory)
        let maker = LivePhotoMaker(workDirectory: directory.appendingPathComponent("output", isDirectory: true))
        let output = try await maker.make(from: source, options: LivePhotoMaker.Options())

        let finished = XCTestExpectation(description: "PHLivePhoto request finished")
        let result = LivePhotoRequestResult()
        _ = PHLivePhoto.request(
            withResourceFileURLs: [output.photoURL, output.videoURL],
            placeholderImage: nil,
            targetSize: .zero,
            contentMode: .aspectFit
        ) { livePhoto, info in
            if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                if result.finish(livePhoto: nil, failure: error.localizedDescription) {
                    finished.fulfill()
                }
                return
            }
            if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true {
                return
            }
            let failure: String? = livePhoto == nil ? "The handler returned no live photo." : nil
            if result.finish(livePhoto: livePhoto, failure: failure) {
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 60)

        XCTAssertNil(result.failure)
        let livePhoto = try XCTUnwrap(result.livePhoto)
        XCTAssertGreaterThan(livePhoto.size.width, 0)
        XCTAssertGreaterThan(livePhoto.size.height, 0)
    }

    func testFileWithoutVideoIsRejected() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The template movie holds only metadata tracks.
        let url = directory.appendingPathComponent("no-video.mov")
        try LivePhotoMaker.TemplateData.makeData().write(to: url)
        let maker = LivePhotoMaker(workDirectory: directory.appendingPathComponent("output", isDirectory: true))

        do {
            _ = try await maker.make(from: url)
            XCTFail("A movie without video should be rejected.")
        } catch let error as LivePhotoError {
            guard case .noVideoTrack = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertNotNil(error.errorDescription)
        }
    }
}

// MARK: - Helpers

private struct MetadataTrackInfo {
    let track: AVAssetTrack
    let identifiers: [String]
}

private struct MetadataSample {
    let time: Double
    let sampleCount: Int
    let group: AVTimedMetadataGroup?
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LivePhotoRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var storedLivePhoto: PHLivePhoto?
    private var storedFailure: String?

    /// Records the first final answer; returns false for any later call.
    func finish(livePhoto: PHLivePhoto?, failure: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        storedLivePhoto = livePhoto
        storedFailure = failure
        return true
    }

    var livePhoto: PHLivePhoto? {
        lock.lock()
        defer { lock.unlock() }
        return storedLivePhoto
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }
}

private extension LivePhotoMakerTests {
    func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhotoMakerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func metadataTracks(of asset: AVURLAsset) async throws -> [MetadataTrackInfo] {
        let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .metadata)
        var result: [MetadataTrackInfo] = []
        for track in tracks {
            let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
            let identifiers: [String] = formats.flatMap { LivePhotoMaker.metadataIdentifiers(of: $0) }
            result.append(MetadataTrackInfo(track: track, identifiers: identifiers))
        }
        return result
    }

    /// Samples of a timed-metadata track with their times on the presentation timeline.
    /// AVAssetReader hands metadata samples out on the media timeline, so they are mapped through
    /// the track's edit list (its first non-empty segment).
    func readMetadataSamples(of track: AVAssetTrack, in asset: AVAsset) async throws -> [MetadataSample] {
        let segments: [AVAssetTrackSegment] = try await track.load(.segments)
        let firstEdit: AVAssetTrackSegment? = segments.first { !$0.isEmpty }
        let mediaToPresentation: Double = firstEdit.map { segment in
            CMTimeGetSeconds(segment.timeMapping.target.start) - CMTimeGetSeconds(segment.timeMapping.source.start)
        } ?? 0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            XCTFail("The metadata track cannot be read.")
            return []
        }
        reader.add(output)
        guard reader.startReading() else {
            XCTFail("Reading failed to start: \(reader.error?.localizedDescription ?? "unknown")")
            return []
        }
        var samples: [MetadataSample] = []
        while let buffer = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) + mediaToPresentation
            samples.append(MetadataSample(time: time, sampleCount: count, group: AVTimedMetadataGroup(sampleBuffer: buffer)))
        }
        XCTAssertNotEqual(reader.status, .failed, reader.error?.localizedDescription ?? "")
        return samples
    }

    func frameCount(of track: AVAssetTrack, in asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            XCTFail("The video track cannot be read.")
            return 0
        }
        reader.add(output)
        guard reader.startReading() else {
            XCTFail("Reading failed to start: \(reader.error?.localizedDescription ?? "unknown")")
            return 0
        }
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertNotEqual(reader.status, .failed, reader.error?.localizedDescription ?? "")
        return count
    }

    func contentIdentifier(of asset: AVURLAsset) async throws -> String? {
        let items: [AVMetadataItem] = try await asset.load(.metadata)
        let match = items.first { item in
            item.identifier == AVMetadataIdentifier.quickTimeMetadataContentIdentifier
                || (item.key as? String) == LivePhotoMaker.contentIdentifierKey
        }
        return try await match?.load(.stringValue)
    }

    func imageProperties(at url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    func loadImage(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func assertColor(
        of image: CGImage,
        x: Double,
        y: Double,
        isRed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let color = try XCTUnwrap(TestVideoFactory.color(in: image, x: x, y: y), file: file, line: line)
        let description = "rgb(\(color.red), \(color.green), \(color.blue)) at (\(x), \(y))"
        if isRed {
            XCTAssertGreaterThan(color.red, 150, "expected red, got \(description)", file: file, line: line)
            XCTAssertLessThan(color.blue, 100, "expected red, got \(description)", file: file, line: line)
        } else {
            XCTAssertGreaterThan(color.blue, 150, "expected blue, got \(description)", file: file, line: line)
            XCTAssertLessThan(color.red, 100, "expected blue, got \(description)", file: file, line: line)
        }
    }
}
