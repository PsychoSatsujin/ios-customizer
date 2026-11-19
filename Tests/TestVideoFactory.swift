import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Makes small synthetic H.264 movies for the Live Photo tests, and reads pixels back.
///
/// Every frame is encoded as 1280x720: the left half red, the right half blue, with a little green
/// that changes per frame so consecutive frames differ.
enum TestVideoFactory {
    enum Orientation {
        /// 1280x720 frames, identity transform: red on the left, blue on the right.
        case landscape
        /// 1280x720 frames rotated 90 degrees, like an iPhone portrait recording. It displays as
        /// 720x1280 with red at the top and blue at the bottom.
        case portraitRotated
    }

    enum FactoryError: LocalizedError {
        case cannotAddInput
        case pixelBuffer(CVReturn)
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                return "The test video input cannot be added."
            case .pixelBuffer(let status):
                return "Could not create a pixel buffer (\(status))."
            case .writer(let reason):
                return "Could not write the test video: \(reason)"
            }
        }
    }

    static let encodedWidth: Int = 1280
    static let encodedHeight: Int = 720

    static func transform(for orientation: Orientation) -> CGAffineTransform {
        switch orientation {
        case .landscape:
            return .identity
        case .portraitRotated:
            // Same matrix an iPhone writes for a portrait recording: (x, y) -> (720 - y, x).
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(encodedHeight), ty: 0)
        }
    }

    /// Writes a `duration`-second movie at `framesPerSecond` into `directory` and returns its URL.
    static func makeMovie(
        orientation: Orientation,
        duration: Double = 3,
        framesPerSecond: Int32 = 30,
        in directory: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: encodedWidth,
            AVVideoHeightKey: encodedHeight
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform(for: orientation)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: encodedWidth,
                kCVPixelBufferHeightKey as String: encodedHeight
            ]
        )
        guard writer.canAdd(input) else { throw FactoryError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw FactoryError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int((duration * Double(framesPerSecond)).rounded())
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw FactoryError.writer(writer.error?.localizedDescription ?? "writer failed")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let buffer = try makeFrame(index: frame)
            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FactoryError.writer(writer.error?.localizedDescription ?? "append failed at frame \(frame)")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: framesPerSecond))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw FactoryError.writer(writer.error?.localizedDescription ?? "finishWriting failed")
        }
        return url
    }

    private static func makeFrame(index: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            encodedWidth,
            encodedHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FactoryError.pixelBuffer(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FactoryError.pixelBuffer(kCVReturnError)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // One BGRA row, copied into every line.
        let green = UInt8((index * 4) % 128)
        var row = [UInt8](repeating: 255, count: encodedWidth * 4)
        for x in 0..<encodedWidth {
            let offset = x * 4
            let isLeft = x < encodedWidth / 2
            row[offset] = isLeft ? 0 : 255      // blue
            row[offset + 1] = green              // green
            row[offset + 2] = isLeft ? 255 : 0  // red
            row[offset + 3] = 255                // alpha
        }
        let rowBytes = encodedWidth * 4
        row.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Void in
            guard let sourceBase = source.baseAddress else { return }
            for y in 0..<encodedHeight {
                (base + y * bytesPerRow).copyMemory(from: sourceBase, byteCount: rowBytes)
            }
        }
        return buffer
    }

    /// RGB (0...255) at a normalised point of `image`; x and y run 0...1 from the top-left corner.
    static func color(in image: CGImage, x: Double, y: Double) -> (red: Int, green: Int, blue: Int)? {
        let width = 90
        let height = 160
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        // Bitmap memory starts with the top row of the drawn image.
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let line = min(height - 1, max(0, Int(y * Double(height))))
        let index = (line * width + column) * 4
        return (red: Int(pixels[index]), green: Int(pixels[index + 1]), blue: Int(pixels[index + 2]))
    }
}
