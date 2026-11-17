import Foundation
import Compression

/// Text metadata and pixel size of a PNG, read without decoding the image.
public struct PNGTextInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Keyword → value for every tEXt, zTXt and iTXt chunk before the first IDAT.
    public var text: [String: String]
}

/// Reads PNG text chunks with as few bytes as possible: it starts with a small
/// read and extends it only when a chunk runs past the window. It stops at the
/// first IDAT, where image data begins.
public enum PNGTextReader {
    public enum Error: Swift.Error, Equatable {
        case notPNG
        case truncated
    }

    public enum ParseResult: Equatable {
        case complete(PNGTextInfo)
        case needMore(Int)  // total byte count needed
        case invalid
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Reads from the start of `fileHandle`, never past the first IDAT header.
    public static func read(fileHandle: FileHandle, initialWindow: Int = 4096) throws -> PNGTextInfo {
        try fileHandle.seek(toOffset: 0)
        var data = try fileHandle.read(upToCount: initialWindow) ?? Data()
        while true {
            switch parse(data) {
            case .complete(let info):
                return info
            case .invalid:
                throw data.count >= 8 && !data.starts(with: signature) ? Error.notPNG : Error.truncated
            case .needMore(let total):
                // Grow at least geometrically to keep the number of reads small.
                let want = max(total, data.count * 2) - data.count
                guard let more = try fileHandle.read(upToCount: want), !more.isEmpty else {
                    throw data.starts(with: signature) || data.count < 8 ? Error.truncated : Error.notPNG
                }
                data += more
            }
        }
    }

    /// Parses as much as `data` allows.
    public static func parse(_ data: Data) -> ParseResult {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return .needMore(8) }
        guard Array(bytes[0..<8]) == signature else { return .invalid }
        var info = PNGTextInfo(width: 0, height: 0, text: [:])
        var off = 8
        while true {
            guard off + 8 <= bytes.count else { return .needMore(off + 8) }
            let length = Int(be32(bytes, off))
            let type = String(decoding: bytes[(off + 4)..<(off + 8)], as: UTF8.self)
            if type == "IDAT" || type == "IEND" { return .complete(info) }
            guard length >= 0, length < 16 << 20 else { return .invalid }  // text chunks are small; 16 MB is generous
            let end = off + 8 + length + 4
            // Only text chunks and IHDR need their body; others can be skipped,
            // but we still need their header to find the next chunk.
            let needsBody = type == "IHDR" || type == "tEXt" || type == "zTXt" || type == "iTXt"
            if needsBody {
                guard end <= bytes.count else { return .needMore(end) }
                let body = Array(bytes[(off + 8)..<(off + 8 + length)])
                switch type {
                case "IHDR":
                    guard body.count >= 8 else { return .invalid }
                    info.width = Int(be32(body, 0))
                    info.height = Int(be32(body, 4))
                default:
                    if let (k, v) = decodeText(type: type, body) { info.text[k] = v }
                }
            }
            off = end
        }
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    static func decodeText(type: String, _ body: [UInt8]) -> (String, String)? {
        guard let nul = body.firstIndex(of: 0) else { return nil }
        let key = String(decoding: body[0..<nul], as: UTF8.self)
        let rest = Array(body[(nul + 1)...])
        switch type {
        case "tEXt":
            return (key, latin1(rest))
        case "zTXt":
            guard rest.count >= 1, let raw = inflate(Array(rest[1...])) else { return nil }
            return (key, latin1(raw))
        case "iTXt":
            guard rest.count >= 2 else { return nil }
            let compressed = rest[0] == 1
            var p = 2
            // language tag, then translated keyword, each NUL-terminated
            for _ in 0..<2 {
                guard let z = rest[p...].firstIndex(of: 0) else { return nil }
                p = z + 1
            }
            let payload = Array(rest[p...])
            let textBytes = compressed ? inflate(payload) : payload
            guard let t = textBytes else { return nil }
            return (key, String(decoding: t, as: UTF8.self))
        default:
            return nil
        }
    }

    static func latin1(_ b: [UInt8]) -> String {
        String(b.map { Character(Unicode.Scalar($0)) })
    }

    /// Inflates a zlib stream (2-byte header, deflate data, Adler-32).
    static func inflate(_ zlib: [UInt8]) -> [UInt8]? {
        guard zlib.count > 2 else { return nil }
        let src = Array(zlib[2...])
        var cap = max(src.count * 8, 4096)
        while cap <= 64 << 20 {
            var out = [UInt8](repeating: 0, count: cap)
            let n = compression_decode_buffer(&out, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if n == 0 { return nil }
            if n < cap { return Array(out[0..<n]) }
            cap *= 4
        }
        return nil
    }
}
