import Foundation
import CryptoKit
import Testing
@testable import BlazebunnyCore

struct ScannerTests {
    struct Fixture {
        let folder: URL
        let libraryBase: URL
    }

    func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-" + UUID().uuidString)
        let folder = base.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for i in 0..<6 {
            try PNGFixture.midjourney(prompt: "invented prompt number \(i) --ar 3:2 --v 7 Job ID: 00000000-0000-0000-0000-00000000000\(i)",
                                      width: 300, height: 200)
                .write(to: folder.appendingPathComponent("mj_\(i).png"))
        }
        try PNGFixture.plainPNG(width: 100, height: 100).write(to: folder.appendingPathComponent("sub/plain.png"))
        try Data("not a png at all".utf8).write(to: folder.appendingPathComponent("broken.png"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.png"))
        return Fixture(folder: folder, libraryBase: base.appendingPathComponent("libs"))
    }

    /// Names, sizes, mtimes and content hashes of every entry, hidden ones included.
    func snapshot(_ folder: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])!
        for case let url as URL in e {
            let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            var line = "\(v.fileSize ?? -1)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if v.isDirectory != true {
                line += "|" + SHA256.hash(data: try Data(contentsOf: url)).description
            }
            out[url.path] = line
        }
        return out
    }

    @Test func indexesFolderAndLeavesItUntouched() async throws {
        let f = try makeFixture()
        let before = try snapshot(f.folder)
        let lib = try Library(root: f.folder, base: f.libraryBase)
        let scanner = FolderScanner(root: f.folder, index: lib.index, thumbnails: lib.thumbnails)
        try await scanner.run()

        let c = try lib.index.counts()
        #expect(c.total == 8)  // 6 mj + plain + broken; txt and hidden skipped
        #expect(c.metadataDone == 7)
        #expect(c.metadataFailed == 1)
        #expect(c.withPrompt == 6)
        #expect(c.thumbnailsDone == 7)
        #expect(c.thumbnailsFailed == 1)
        #expect(try lib.index.gridItems(search: "number").count == 6)
        #expect(try lib.index.gridItems().contains { $0.relPath == "sub/plain.png" })

        let item = try #require(try lib.index.gridItems(search: "number 3").first)
        let loc = try #require(try lib.index.thumbnailLocation(id: item.id))
        let thumb = try lib.thumbnails.data(at: loc)
        #expect(thumb.starts(with: [0xFF, 0xD8]))  // JPEG

        #expect(try snapshot(f.folder) == before)
        #expect(!lib.directory.path.hasPrefix(f.folder.path))
    }

    @Test func rescanSkipsUnchangedAndDropsRemoved() async throws {
        let f = try makeFixture()
        let lib = try Library(root: f.folder, base: f.libraryBase)
        try await FolderScanner(root: f.folder, index: lib.index, thumbnails: nil).run()

        try FileManager.default.removeItem(at: f.folder.appendingPathComponent("mj_0.png"))
        let second = FolderScanner(root: f.folder, index: lib.index, thumbnails: nil)
        try await second.run()
        #expect(second.metadataReads == 0)
        #expect(try lib.index.counts().total == 7)
        #expect(try lib.index.gridItems(search: "number 0").isEmpty)
    }

    @Test func libraryIDIsStableAndOutsideFolder() throws {
        let f = try makeFixture()
        #expect(LibraryLocation.libraryID(for: f.folder) == LibraryLocation.libraryID(for: f.folder.appendingPathComponent("sub/..")))
        #expect(LibraryLocation.libraryID(for: f.folder) != LibraryLocation.libraryID(for: f.folder.appendingPathComponent("sub")))
    }

    @Test func packRollsOver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ThumbnailStore(directory: dir, maxPackSize: 1000)
        let a = try store.append(Data(repeating: 1, count: 600))
        let b = try store.append(Data(repeating: 2, count: 600))
        #expect(a.pack == 0 && b.pack == 1 && b.offset == 0)
        #expect(try store.data(at: a) == Data(repeating: 1, count: 600))
        #expect(try store.data(at: b) == Data(repeating: 2, count: 600))
        let reopened = try ThumbnailStore(directory: dir, maxPackSize: 1000)
        let c = try reopened.append(Data(repeating: 3, count: 100))
        #expect(c.pack == 1 && c.offset == 600)
    }

    @Test func thumbnailIsBounded() throws {
        let png = PNGFixture.plainPNG(width: 2000, height: 1000)
        let img = try ThumbnailMaker.thumbnail(data: png, maxPixel: 512)
        #expect(img.width == 512 && img.height == 256)
    }
}
