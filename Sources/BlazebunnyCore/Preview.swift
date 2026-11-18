import Foundation
import ImageIO

/// Decoding for the inspector preview and, later, the full-screen viewer: the right pixel size for
/// where the image is shown, and which neighbours to get ready before they are asked for.
public enum PreviewDecoder {
    /// Decodes `url` so its long side is at most `maxPixel`, upright. Runs on the caller's thread:
    /// call it off the main thread. The file is only read.
    public static func decode(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// The long side, in pixels, an image needs to look sharp when fitted into `box` (points) on a
    /// screen of `scale`: never more than the image has. Without the image's size, the box's long side.
    public static func neededPixels(fitting box: CGSize, scale: CGFloat, imageWidth: Int?, imageHeight: Int?) -> Double {
        guard let w = imageWidth, let h = imageHeight, w > 0, h > 0, box.width > 0, box.height > 0 else {
            return Double(max(box.width, box.height) * scale)
        }
        let fit = min(box.width / CGFloat(w), box.height / CGFloat(h))
        return Double(min(CGFloat(max(w, h)) * fit * scale, CGFloat(max(w, h))))
    }

    /// The size to decode at: `neededPixels` rounded up to a step of 256, so a small resize of the
    /// panel does not ask for a new decode.
    public static func pixelSize(fitting box: CGSize, scale: CGFloat, imageWidth: Int?, imageHeight: Int?) -> Int {
        let needed = neededPixels(fitting: box, scale: scale, imageWidth: imageWidth, imageHeight: imageHeight)
        return max(256, Int((needed / 256).rounded(.up)) * 256)
    }

    /// Positions to decode ahead of time around `index` in a list of `count`: first the ones in the
    /// direction of travel, then one behind. `direction` is +1, -1, or 0 when it is not known.
    public static func neighbours(of index: Int, count: Int, direction: Int, ahead: Int = 2, behind: Int = 1) -> [Int] {
        guard count > 0, index >= 0, index < count else { return [] }
        var out: [Int] = []
        func add(_ i: Int) { if i >= 0, i < count, i != index, !out.contains(i) { out.append(i) } }
        if direction == 0 {
            for step in 1...max(1, ahead) { add(index + step); add(index - step) }
        } else {
            for step in 1...max(1, ahead) { add(index + step * direction) }
            for step in 1...max(1, behind) { add(index - step * direction) }
        }
        return out
    }
}
