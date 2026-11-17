import Foundation
import Testing
@testable import BlazebunnyCore

struct GhostStorageTests {
    func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bb-ghost-" + UUID().uuidString)
    }

    func contents(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// Indexes a small folder as a ghost and returns the data directory used.
    func scanGhost(folder: URL, base: URL) async throws -> URL {
        for i in 0..<5 {
            try PNGFixture.plainPNG(width: 40, height: 40).write(to: folder.appendingPathComponent("p\(i).png"))
        }
        let lib = try Library(root: folder, base: base)
        try await FolderScanner(root: folder, index: lib.index, thumbnails: lib.thumbnails).run()
        #expect(try lib.index.counts().thumbnailsDone == 5)
        return lib.directory
    }

    @Test func ghostDataLivesOnlyUnderItsBaseAndPurgeLeavesNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let ghostRoot = root.appendingPathComponent("ghosts")
        let base = try GhostStorage.makeBase(root: ghostRoot)
        let dir = try await scanGhost(folder: folder, base: base)

        #expect(dir.path.hasPrefix(base.path + "/"))
        #expect(!contents(dir).isEmpty)  // index and thumbnails exist while the ghost is open

        GhostStorage.purge(base, root: ghostRoot)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        #expect(contents(ghostRoot).isEmpty)
        // Only the source images remain where they were.
        #expect(contents(folder).sorted() == (0..<5).map { "p\($0).png" }.sorted())
    }

    @Test func purgeAllRemovesOrphansFromACrashedSession() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try GhostStorage.makeBase(root: root)
        let b = try GhostStorage.makeBase(root: root)
        try Data("x".utf8).write(to: a.appendingPathComponent("index.sqlite"))
        #expect(contents(root).count == 2)
        #expect(GhostStorage.purgeAll(root: root) == 2)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func purgeRefusesPathsOutsideTheGhostRoot() throws {
        let root = makeRoot()
        let outside = makeRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        _ = try GhostStorage.makeBase(root: root)
        GhostStorage.purge(outside, root: root)
        GhostStorage.purge(root, root: root)  // the root itself is not a ghost base
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func ghostBaseIsPrivateToTheUser() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try GhostStorage.makeBase(root: root)
        let perms = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }
}
