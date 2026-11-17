import Foundation
import Testing
@testable import BlazebunnyCore

/// The scanner fills the folder tree and keeps it in step with the disk.
struct ScannerFolderTests {
    func makeFolder() throws -> (base: URL, folder: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-dirs-" + UUID().uuidString)
        let folder = base.appendingPathComponent("lib")
        let fm = FileManager.default
        for d in ["a/b", "c", "empty", "Ünï/深"] { try fm.createDirectory(at: folder.appendingPathComponent(d), withIntermediateDirectories: true) }
        let png = PNGFixture.plainPNG(width: 20, height: 20)
        for f in ["top.png", "a/1.png", "a/b/2.png", "a/b/3.png", "c/4.png", "Ünï/深/5.png"] {
            try png.write(to: folder.appendingPathComponent(f))
        }
        return (base, folder)
    }

    func scan(_ folder: URL, _ lib: Library) async throws {
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
    }

    @Test func scanFillsTheTreeIncludingEmptyFolders() async throws {
        let (base, folder) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await scan(folder, lib)
        let tree = try lib.index.directoryTree()
        #expect(tree.map(\.path).sorted() == ["a", "a/b", "c", "empty", "Ünï", "Ünï/深"])
        #expect(tree.first { $0.path == "a" }?.subtreeCount == 3)
        #expect(tree.first { $0.path == "empty" }?.subtreeCount == 0)
        let a = try #require(try lib.index.dirID(forPath: "a"))
        #expect(try lib.index.items(folder: a).count == 3)
    }

    @Test func rescanFollowsAFileMovedAndAFolderRemoved() async throws {
        let (base, folder) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await scan(folder, lib)
        let fm = FileManager.default
        try fm.moveItem(at: folder.appendingPathComponent("a/1.png"), to: folder.appendingPathComponent("c/1.png"))
        try fm.removeItem(at: folder.appendingPathComponent("empty"))
        try fm.createDirectory(at: folder.appendingPathComponent("new/deeper"), withIntermediateDirectories: true)
        try await scan(folder, lib)
        let tree = try lib.index.directoryTree()
        #expect(tree.first { $0.path == "a" }?.subtreeCount == 2)
        #expect(tree.first { $0.path == "c" }?.directCount == 2)
        #expect(tree.contains { $0.path == "empty" } == false)
        #expect(tree.contains { $0.path == "new/deeper" })
        #expect(try lib.index.counts().total == 6)
    }

    @Test func anUnreachableRootKeepsTheTree() async throws {
        let (base, folder) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await scan(folder, lib)
        let before = try lib.index.directoryTree()
        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("gone"))
        try await scan(folder, lib)
        #expect(try lib.index.directoryTree() == before)
        // An empty mount point: folders are not wiped either.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await scan(folder, lib)
        #expect(try lib.index.directoryTree() == before)
    }
}
