import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Compression

/// Builds real PNG files in memory with arbitrary text chunks, so tests never
/// need anybody's real images.
enum PNGFixture {
    struct TextChunk {
        var type: String  // "tEXt", "zTXt" or "iTXt"
        var key: String
        var value: String
        var compressed: Bool = false  // iTXt only
    }

    static func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func plainPNG(width: Int, height: Int) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(width: width, height: height), nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A PNG with `chunks` inserted right before the first IDAT.
    /// `padding` inserts a private ancillary chunk of that many bytes first,
    /// pushing the text chunks far from the start of the file.
    static func make(width: Int = 64, height: Int = 48, text chunks: [TextChunk], padding: Int = 0) -> Data {
        let png = plainPNG(width: width, height: height)
        var extra = Data()
        if padding > 0 { extra += chunk("pdDg", Data(repeating: 0x2A, count: padding)) }
        for c in chunks { extra += encode(c) }
        let idat = firstIDATOffset(png)
        var result = png.prefix(idat)
        result += extra
        result += png.suffix(from: idat)
        return Data(result)
    }

    static func midjourney(prompt: String, created: String = "Mon, 22 Dec 2025 22:04:32 GMT",
                           author: String = "test_author", width: Int = 64, height: Int = 48) -> Data {
        make(width: width, height: height, text: [
            .init(type: "tEXt", key: "Creation Time", value: created),
            .init(type: "tEXt", key: "Author", value: author),
            .init(type: "tEXt", key: "Description", value: prompt),
            .init(type: "iTXt", key: "XML:com.adobe.xmp", value: "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>"),
        ])
    }

    // MARK: - Encoding

    static func encode(_ c: TextChunk) -> Data {
        var body = Data(c.key.utf8)
        body.append(0)
        switch c.type {
        case "tEXt":
            body += Data(c.value.data(using: .isoLatin1)!)
        case "zTXt":
            body.append(0)
            body += zlib(Data(c.value.data(using: .isoLatin1)!))
        case "iTXt":
            body.append(c.compressed ? 1 : 0)
            body.append(0)
            body.append(0)  // empty language tag
            body.append(0)  // empty translated keyword
            body += c.compressed ? zlib(Data(c.value.utf8)) : Data(c.value.utf8)
        default:
            fatalError("unknown chunk type")
        }
        return chunk(c.type, body)
    }

    static func chunk(_ type: String, _ body: Data) -> Data {
        var d = Data()
        d += be32(UInt32(body.count))
        let typeBytes = Data(type.utf8)
        d += typeBytes
        d += body
        d += be32(crc32(typeBytes + body))
        return d
    }

    static func firstIDATOffset(_ png: Data) -> Int {
        var off = 8
        let bytes = [UInt8](png)
        while off + 8 <= bytes.count {
            let len = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            if String(bytes: bytes[(off + 4)..<(off + 8)], encoding: .ascii) == "IDAT" { return off }
            off += len + 12
        }
        fatalError("no IDAT")
    }

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// zlib stream: 2-byte header + raw deflate + Adler-32.
    static func zlib(_ input: Data) -> Data {
        let cap = input.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = input.withUnsafeBytes { src in
            compression_encode_buffer(&out, cap, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return Data([0x78, 0x9C]) + Data(out[0..<n]) + be32((b << 16) | a)
    }
}
