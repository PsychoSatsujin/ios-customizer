import UIKit
import ImageIO

/// Turns a picked image into the square, opaque PNG used as a web clip icon.
enum IconRenderer {
    /// Output size in pixels. Apple allows up to 400 x 400; 256 is sharp on
    /// iPhone (60 pt @3x = 180 px, larger in big-icon mode) and keeps the profile small.
    static let pixelSize = 256

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Center-crops `image` to a square (aspect fill) and renders it at
    /// `pixelSize` x `pixelSize` pixels, scale 1, fully opaque. `background`
    /// fills any transparent parts. iOS rounds the corners itself.
    static func renderPNG(
        from image: UIImage,
        background: UIColor = .white,
        pixelSize: Int = IconRenderer.pixelSize
    ) -> Data {
        let side = CGFloat(max(pixelSize, 1))
        let canvas = CGSize(width: side, height: side)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.pngData { context in
            background.withAlphaComponent(1).setFill()
            context.fill(CGRect(origin: .zero, size: canvas))

            let source = image.size
            guard source.width > 0, source.height > 0 else { return }
            let scale = max(side / source.width, side / source.height)
            let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
            let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    /// Decodes image data (JPEG, HEIC, PNG...) at a reduced size so huge photos
    /// don't need to be fully decoded. Applies the EXIF orientation.
    static func downsampledImage(from data: Data, maxPixelSize: Int = 1024) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func isPNG(_ data: Data) -> Bool {
        Array(data.prefix(pngSignature.count)) == pngSignature
    }

    /// Reads the pixel size from a PNG's IHDR chunk without decoding it.
    static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes: [UInt8] = Array(data.prefix(24))
        guard bytes.count == 24,
              Array(bytes[0..<8]) == pngSignature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }
        return (width: bigEndianInt(bytes, at: 16), height: bigEndianInt(bytes, at: 20))
    }

    private static func bigEndianInt(_ bytes: [UInt8], at offset: Int) -> Int {
        var value = 0
        for index in offset..<(offset + 4) {
            value = (value << 8) | Int(bytes[index])
        }
        return value
    }
}
