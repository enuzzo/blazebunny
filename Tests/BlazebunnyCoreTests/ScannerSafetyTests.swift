import Foundation
import Testing
@testable import BlazebunnyCore

/// A rescan must never destroy an index because the disk is gone, empty or half-readable,
/// and a batch read while the disk vanished must not be recorded as a permanent failure.
struct ScannerSafetyTests {
    func makeFolder(count: Int) throws -> (base: URL, folder: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-safe-" + UUID().uuidString)
        let folder = base.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<count {
            try PNGFixture.plainPNG(width: 30, height: 30).write(to: folder.appendingPathComponent("p\(i).png"))
        }
        return (base, folder)
    }

    @Test func rescanOfAnEmptyRootKeepsTheIndex() async throws {
        let (base, folder) = try makeFolder(count: 20)
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        #expect(try lib.index.counts().total == 20)

        // A stale mount point: the folder exists but shows nothing.
        let emptied = base.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: emptied)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        #expect(try lib.index.counts().total == 20, "an empty listing must not wipe a known library")
    }

    @Test func rescanOfAMissingRootKeepsTheIndex() async throws {
        let (base, folder) = try makeFolder(count: 20)
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("gone"))
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        #expect(try lib.index.counts().total == 20)
    }

    @Test func realDeletionsAreStillPruned() async throws {
        let (base, folder) = try makeFolder(count: 20)
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        for i in 0..<5 { try FileManager.default.removeItem(at: folder.appendingPathComponent("p\(i).png")) }
        try await FolderScanner(root: folder, index: lib.index, thumbnails: nil).run()
        #expect(try lib.index.counts().total == 15)
    }

    @Test func aBatchReadWhileTheDiskVanishesIsNotRecordedAsFailed() async throws {
        let (base, folder) = try makeFolder(count: 200)
        defer { try? FileManager.default.removeItem(at: base) }
        let lib = try Library(root: folder, base: base.appendingPathComponent("libs"))
        let scanner = FolderScanner(root: folder, index: lib.index, thumbnails: nil)
        // The root answers "reachable" for the listing and the first batch, then disappears.
        let calls = Locked(0)
        scanner.isRootReachable = { calls.withLock { $0 += 1; return $0 <= 2 } }
        try await scanner.run()
        let c = try lib.index.counts()
        #expect(c.metadataFailed == 0, "unreachable disk must not mark items as failed")
        #expect(c.metadataDone < 200, "the scan must stop instead of continuing blindly")
        #expect(try lib.index.pendingMetadata(limit: 1).count == 1, "unread items stay pending for the next scan")
    }

    @Test func manyDistinctPriorityLists() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-prio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let idx = try LibraryIndex(url: base.appendingPathComponent("index.sqlite"))
        try idx.upsertFiles((0..<50).map { FileRecord(relPath: "f\($0).png", size: 1, mtime: 1, kind: .png) })
        let all = try idx.pendingThumbnails(limit: 50).map(\.id)
        for n in 1...300 {
            let ids = Array(all.shuffled().prefix(1 + n % 20))
            #expect(try idx.pendingThumbnails(ids: ids).count == ids.count)
        }
        #expect(try idx.pendingThumbnails(ids: []).isEmpty)
    }

    @Test func twoStoresOnOneDirectoryShareTheSamePack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ThumbnailStore.shared(directory: dir)
        let b = try ThumbnailStore.shared(directory: dir)
        #expect(a === b)
        let l1 = try a.append(Data(repeating: 1, count: 10))
        let l2 = try b.append(Data(repeating: 2, count: 10))
        #expect(l2.offset == l1.offset + 10)
        #expect(try a.data(at: l1) == Data(repeating: 1, count: 10))
    }

    @Test func busyDatabaseWaitsInsteadOfFailing() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bb-busy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("index.sqlite")
        let one = try LibraryIndex(url: url)
        let two = try LibraryIndex(url: url)  // a second connection, as after a library switch
        for i in 0..<100 {
            try one.upsertFiles([FileRecord(relPath: "a\(i).png", size: 1, mtime: 1, kind: .png)])
            try two.upsertFiles([FileRecord(relPath: "b\(i).png", size: 1, mtime: 1, kind: .png)])
        }
        #expect(try one.counts().total == 200)
    }
}
