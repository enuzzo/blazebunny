import Foundation
import CryptoKit

/// Where a library's data lives on this Mac, and its stable identity.
public enum LibraryLocation {
    public static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blazebunny/Libraries", isDirectory: true)
    }

    /// Volume UUID (or volume name when there is none) plus the folder's path
    /// relative to the volume root, hashed. The same disk mounted elsewhere
    /// gives the same id.
    public static func libraryID(for folder: URL) -> String {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey])
        let volumePath = values?.volume?.standardizedFileURL.path ?? "/"
        var rel = folder.path
        if rel.hasPrefix(volumePath) { rel = String(rel.dropFirst(volumePath.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let volume = values?.volumeUUIDString ?? "name:" + (values?.volumeName ?? "unknown")
        let digest = SHA256.hash(data: Data((volume + "\u{0}" + rel).utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public static func directory(for folder: URL, base: URL = defaultBase) -> URL {
        base.appendingPathComponent(libraryID(for: folder), isDirectory: true)
    }
}

/// An opened library: its index and thumbnails.
public final class Library: @unchecked Sendable {
    public let root: URL
    public let directory: URL
    public let index: LibraryIndex
    public let thumbnails: ThumbnailStore

    public init(root: URL, base: URL = LibraryLocation.defaultBase) throws {
        self.root = root
        directory = LibraryLocation.directory(for: root, base: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try LibraryIndex(url: directory.appendingPathComponent("index.sqlite"))
        thumbnails = try ThumbnailStore(directory: directory)
        try index.setValue(root.path, forKey: "root_path")
    }
}
