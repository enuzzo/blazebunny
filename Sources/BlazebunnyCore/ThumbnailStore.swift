import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Append-only pack files holding encoded thumbnails, so a library is a few
/// large files instead of tens of thousands of small ones.
public final class ThumbnailStore: @unchecked Sendable {
    public let directory: URL
    let maxPackSize: Int64
    private let lock = NSLock()
    private var currentPack = 0
    private var currentOffset: Int64 = 0
    private var writer: FileHandle?
    private var readers: [Int: FileHandle] = [:]

    /// One store per directory, shared by every `Library` opened on it. Two stores on the
    /// same packs would both append at the same offset and overwrite each other (seen when
    /// a library is re-selected while its previous scan is still finishing).
    public static func shared(directory: URL, maxPackSize: Int64 = 256 << 20) throws -> ThumbnailStore {
        try ThumbnailRegistry.shared.store(for: directory, maxPackSize: maxPackSize)
    }

    public init(directory: URL, maxPackSize: Int64 = 256 << 20) throws {
        self.directory = directory
        self.maxPackSize = maxPackSize
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packs = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let numbers = packs.compactMap { name -> Int? in
            guard name.hasPrefix("thumbs-"), name.hasSuffix(".pack") else { return nil }
            return Int(name.dropFirst(7).dropLast(5))
        }
        currentPack = numbers.max() ?? 0
        let attrs = try? FileManager.default.attributesOfItem(atPath: packURL(currentPack).path)
        currentOffset = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit {
        try? writer?.close()
        for r in readers.values { try? r.close() }
    }

    func packURL(_ n: Int) -> URL {
        directory.appendingPathComponent(String(format: "thumbs-%03d.pack", n))
    }

    public func append(_ data: Data) throws -> ThumbnailLocation {
        lock.lock()
        defer { lock.unlock() }
        if currentOffset > 0 && currentOffset + Int64(data.count) > maxPackSize {
            try writer?.close()
            writer = nil
            currentPack += 1
            currentOffset = 0
        }
        if writer == nil {
            let url = packURL(currentPack)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                var u = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? u.setResourceValues(values)
            }
            writer = try FileHandle(forWritingTo: url)
        }
        try writer!.seek(toOffset: UInt64(currentOffset))
        try writer!.write(contentsOf: data)
        let loc = ThumbnailLocation(pack: currentPack, offset: currentOffset, length: data.count)
        currentOffset += Int64(data.count)
        return loc
    }

    public func data(at loc: ThumbnailLocation) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let fh: FileHandle
        if let r = readers[loc.pack] {
            fh = r
        } else {
            fh = try FileHandle(forReadingFrom: packURL(loc.pack))
            readers[loc.pack] = fh
        }
        try fh.seek(toOffset: UInt64(loc.offset))
        guard let d = try fh.read(upToCount: loc.length), d.count == loc.length else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return d
    }
}

final class ThumbnailRegistry: @unchecked Sendable {
    static let shared = ThumbnailRegistry()
    private final class Weak { weak var store: ThumbnailStore? }
    private var stores: [String: Weak] = [:]
    private let lock = NSLock()

    func store(for directory: URL, maxPackSize: Int64) throws -> ThumbnailStore {
        let key = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = stores[key]?.store { return existing }
        let made = try ThumbnailStore(directory: directory, maxPackSize: maxPackSize)
        let box = Weak()
        box.store = made
        stores[key] = box
        stores = stores.filter { $0.value.store != nil }
        return made
    }
}

/// Makes a JPEG thumbnail from a source file, reading it once, sequentially.
public enum ThumbnailMaker {
    public static func make(from url: URL, kind: ItemKind, maxPixel: Int = Blazebunny.thumbnailMaxPixel) async throws -> Data {
        let image: CGImage
        if kind.isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            image = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 128 << 20 {
                // A huge file (big PSD or TIFF): let ImageIO read what it needs instead of
                // holding the whole file in memory.
                image = try thumbnail(url: url, maxPixel: maxPixel)
            } else {
                let data = try Data(contentsOf: url, options: .uncached)
                image = try thumbnail(data: data, maxPixel: maxPixel)
            }
        }
        return try encodeJPEG(image)
    }

    static func thumbnail(url: URL, maxPixel: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try thumbnail(source: src, maxPixel: maxPixel)
    }

    public static func thumbnail(data: Data, maxPixel: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try thumbnail(source: src, maxPixel: maxPixel)
    }

    private static func thumbnail(source src: CGImageSource, maxPixel: Int) throws -> CGImage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return img
    }

    public static func encodeJPEG(_ image: CGImage, quality: Double = 0.75) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}
