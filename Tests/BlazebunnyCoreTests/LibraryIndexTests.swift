import Foundation
import Testing
@testable import BlazebunnyCore

struct LibraryIndexTests {
    func makeIndex() throws -> LibraryIndex {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LibraryIndex(url: dir.appendingPathComponent("index.sqlite"))
    }

    func rec(_ name: String, mtime: Double = 100, size: Int64 = 10) -> FileRecord {
        FileRecord(relPath: name, size: size, mtime: mtime, kind: .png)
    }

    @Test func upsertAndList() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("a.png"), rec("b.png"), rec("c.png")])
        #expect(try idx.gridItems().count == 3)
        #expect(try idx.counts().total == 3)
        #expect(try idx.pendingMetadata(limit: 10).count == 3)
    }

    @Test func changedFileResetsState() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("a.png")])
        let id = try idx.pendingMetadata(limit: 1)[0].id
        try idx.saveMetadata(id: id, ItemMetadata(width: 1, height: 1))
        try idx.saveThumbnail(id: id, ThumbnailLocation(pack: 0, offset: 0, length: 5))
        try idx.upsertFiles([rec("a.png")])  // unchanged
        #expect(try idx.pendingMetadata(limit: 10).isEmpty)
        #expect(try idx.thumbnailLocation(id: id) != nil)
        try idx.upsertFiles([rec("a.png", mtime: 200)])  // changed
        #expect(try idx.pendingMetadata(limit: 10).count == 1)
        #expect(try idx.thumbnailLocation(id: id) == nil)
    }

    @Test func deleteRemovesRow() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("a.png"), rec("b.png")])
        try idx.deleteFiles(relPaths: ["a.png"])
        #expect(try idx.gridItems().map(\.relPath) == ["b.png"])
    }

    @Test func fullTextSearchWithPrefixes() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("one.png"), rec("two.png"), rec("rainbow_file.png")])
        let items = try idx.pendingMetadata(limit: 10)
        try idx.saveMetadata([
            (items[0].id, ItemMetadata(promptRaw: "a cat in the rain --v 7")),
            (items[1].id, ItemMetadata(promptRaw: "a dog in the sun --ar 16:9")),
            (items[2].id, ItemMetadata()),
        ])
        #expect(try idx.gridItems(search: "rai cat").map(\.relPath) == ["one.png"])
        #expect(Set(try idx.gridItems(search: "rain").map(\.relPath)) == ["one.png", "rainbow_file.png"])
        // Parameters are not searchable text.
        #expect(try idx.gridItems(search: "16").isEmpty)
        #expect(try idx.gridItems(search: "  ").count == 3)
        #expect(try idx.gridItems(search: "\"quote").isEmpty)
    }

    @Test func sortsByEmbeddedDateWithFallback() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("old.png", mtime: 5000), rec("new.png", mtime: 1), rec("mid.png", mtime: 3000)])
        let items = try idx.pendingMetadata(limit: 10)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.relPath, $0.id) })
        try idx.saveMetadata(id: byName["old.png"]!, ItemMetadata(createdAt: Date(timeIntervalSince1970: 1000), createdSource: .pngText))
        try idx.saveMetadata(id: byName["new.png"]!, ItemMetadata(createdAt: Date(timeIntervalSince1970: 9000), createdSource: .pngText))
        // mid.png has no metadata yet: falls back to mtime 3000
        #expect(try idx.gridItems(sort: .newestFirst).map(\.relPath) == ["new.png", "mid.png", "old.png"])
        #expect(try idx.gridItems(sort: .oldestFirst).map(\.relPath) == ["old.png", "mid.png", "new.png"])
    }

    @Test func detailRoundTrip() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("a.png")])
        let id = try idx.pendingMetadata(limit: 1)[0].id
        #expect(try idx.detail(id: id)?.metadata == nil)
        let m = ItemMetadata(width: 3, height: 4, createdAt: Date(timeIntervalSince1970: 42), createdSource: .pngText,
                             author: "me", promptRaw: "x --ar 3:4 Job ID: 00000000-0000-0000-0000-000000000000", xmp: "<x/>")
        try idx.saveMetadata(id: id, m)
        #expect(try idx.detail(id: id)?.metadata == m)
        try idx.saveMetadata(id: id, nil)
        #expect(try idx.detail(id: id)?.metadataFailed == true)
    }
}
