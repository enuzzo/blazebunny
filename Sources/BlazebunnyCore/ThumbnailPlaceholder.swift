import Foundation
import CoreGraphics

/// The colours of a thumbnail in sixteen samples: a 4 x 4 grid over the whole picture, each sample
/// 16 bits (5 red, 6 green, 5 blue). Thirty-two bytes per item, kept in the index next to (not
/// inside) the rows the grid reads, and drawn by a cell, stretched and smoothed, while its real
/// thumbnail is read and decoded.
public struct ThumbnailPlaceholder: Sendable, Hashable {
    /// Samples per side.
    public static let side = 4
    /// Size of `data`.
    public static let byteCount = side * side * 2

    /// Rows top to bottom, four samples each, sixteen bits per sample.
    var rows: (UInt64, UInt64, UInt64, UInt64)

    public static func == (a: Self, b: Self) -> Bool { a.rows == b.rows }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rows.0); hasher.combine(rows.1); hasher.combine(rows.2); hasher.combine(rows.3)
    }

    /// From 16 samples of red, green and blue (0 to 255), rows top to bottom.
    public init(samples: [(r: UInt8, g: UInt8, b: UInt8)]) {
        precondition(samples.count == Self.side * Self.side)
        var packed = [UInt64](repeating: 0, count: Self.side)
        for (i, s) in samples.enumerated() {
            let value = UInt64(s.r >> 3) << 11 | UInt64(s.g >> 2) << 5 | UInt64(s.b >> 3)
            packed[i / Self.side] |= value << (UInt64(i % Self.side) * 16)
        }
        rows = (packed[0], packed[1], packed[2], packed[3])
    }

    /// From the bytes stored in the index; nil when they are not a placeholder.
    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        var packed = [UInt64](repeating: 0, count: Self.side)
        for (i, byte) in data.enumerated() { packed[i / 8] |= UInt64(byte) << (UInt64(i % 8) * 8) }
        rows = (packed[0], packed[1], packed[2], packed[3])
    }

    /// The bytes stored in the index (little-endian, the same on every Mac).
    public var data: Data {
        var out = Data(capacity: Self.byteCount)
        for row in [rows.0, rows.1, rows.2, rows.3] {
            for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: row >> UInt64(shift))) }
        }
        return out
    }

    /// The sample at `column`, `row` (0 to 3, from the top left), as 8-bit red, green and blue.
    public func sample(column: Int, row: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let packed = row == 0 ? rows.0 : row == 1 ? rows.1 : row == 2 ? rows.2 : rows.3
        let v = UInt16(truncatingIfNeeded: packed >> (UInt64(column) * 16))
        let r = UInt8(v >> 11), g = UInt8((v >> 5) & 0x3F), b = UInt8(v & 0x1F)
        // Spread 5 and 6 bits back over 8, so white stays white.
        return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The colours of `image`: it is drawn small, then each sample is the average of its part.
    public init?(image: CGImage) {
        // 32 x 32 first (a smooth reduction by the system), then plain averages of 8 x 8 blocks,
        // so the result does not depend on how the system samples a very large reduction.
        let n = Self.side * 8
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: Self.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var samples: [(r: UInt8, g: UInt8, b: UInt8)] = []
        samples.reserveCapacity(Self.side * Self.side)
        for row in 0..<Self.side {
            for column in 0..<Self.side {
                var r = 0, g = 0, b = 0
                for y in (row * 8)..<(row * 8 + 8) {
                    for x in (column * 8)..<(column * 8 + 8) {
                        let i = (y * n + x) * 4
                        r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
                    }
                }
                samples.append((UInt8(r / 64), UInt8(g / 64), UInt8(b / 64)))
            }
        }
        self.init(samples: samples)
    }

    /// A 4 x 4 image of the samples; a layer stretches it with linear filtering into a soft blur.
    public func makeImage() -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: Self.side * Self.side * 4)
        for row in 0..<Self.side {
            for column in 0..<Self.side {
                let s = sample(column: column, row: row)
                let i = (row * Self.side + column) * 4
                pixels[i] = s.r; pixels[i + 1] = s.g; pixels[i + 2] = s.b
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: Self.side, height: Self.side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.side * 4,
                       space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
