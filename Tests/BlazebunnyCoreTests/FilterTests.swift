import Foundation
import SQLite3
import Testing
@testable import BlazebunnyCore

struct FilterTests {
    let job = " Job ID: 00000000-0000-0000-0000-000000000000"

    /// Index with: 3 Midjourney (v7 16:9 raw, v7 2:3, v6.1 2:3 sref), 1 camera, 1 unknown.
    func makeIndex() throws -> (LibraryIndex, [String: Int64]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let idx = try LibraryIndex(url: dir.appendingPathComponent("index.sqlite"))
        let names = ["a.png", "b.png", "c.png", "photo.jpg", "plain.png"]
        try idx.upsertFiles(names.map { FileRecord(relPath: $0, size: 1, mtime: 0, kind: $0.hasSuffix("jpg") ? .jpeg : .png) })
        let ids = Dictionary(uniqueKeysWithValues: try idx.pendingMetadata(limit: 10).map { ($0.relPath, $0.id) })
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        try idx.saveMetadata([
            (ids["a.png"]!, ItemMetadata(width: 1600, height: 900, createdAt: d(1_000), createdSource: .pngText, promptRaw: "red cat --ar 16:9 --v 7 --raw --stylize 250" + job)),
            (ids["b.png"]!, ItemMetadata(width: 800, height: 1200, createdAt: d(2_000), createdSource: .pngText, promptRaw: "blue dog --ar 2:3 --v 7" + job)),
            (ids["c.png"]!, ItemMetadata(width: 800, height: 1200, createdAt: d(3_000), createdSource: .pngText, promptRaw: "red fox --ar 2:3 --v 6.1 --sref 123" + job)),
            (ids["photo.jpg"]!, ItemMetadata(width: 6000, height: 4000, createdAt: d(4_000), createdSource: .exif, camera: CameraInfo(camera: "Leica Q3"))),
            (ids["plain.png"]!, ItemMetadata(width: 100, height: 100, createdAt: d(5_000))),
        ])
        return (idx, ids)
    }

    func names(_ idx: LibraryIndex, _ f: FilterState, search: String? = nil) throws -> Set<String> {
        Set(try idx.items(filter: f, search: search).map(\.relPath))
    }

    @Test func sourcesAreStored() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState(); f.sources = [.midjourney]
        #expect(try names(idx, f) == ["a.png", "b.png", "c.png"])
        f.sources = [.camera, .unknown]
        #expect(try names(idx, f) == ["photo.jpg", "plain.png"])
    }

    @Test func orWithinAndAcross() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState()
        f.versions = ["7", "6.1"]
        #expect(try names(idx, f).count == 3)
        f.ratios = ["2:3"]
        #expect(try names(idx, f) == ["b.png", "c.png"])
        f.orientations = [.landscape]  // shape: portrait-ratio OR landscape
        #expect(try names(idx, f) == ["a.png", "b.png", "c.png"])
    }

    @Test func paramsAreAllOf() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState(); f.params = ["raw"]
        #expect(try names(idx, f) == ["a.png"])
        f.params = ["raw", "stylize 250"]
        #expect(try names(idx, f) == ["a.png"])
        f.params = ["raw", "sref"]
        #expect(try names(idx, f).isEmpty)
    }

    @Test func facetCountsIgnoreOwnSelection() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState(); f.versions = ["7"]
        let versions = try idx.facetCounts(.version, filter: f, search: nil)
        #expect(versions.first(where: { $0.value == "7" })?.count == 2)
        #expect(versions.first(where: { $0.value == "6.1" })?.count == 1)
        let shapes = try idx.facetCounts(.shape, filter: f, search: nil)
        #expect(shapes.first(where: { $0.value == "r:2:3" })?.count == 1)  // limited by version 7
        #expect(shapes.contains(FacetValue(value: "o:landscape", count: 1)))
        let params = try idx.facetCounts(.param, filter: FilterState(), search: nil)
        #expect(Set(params.map(\.value)) == ["raw", "stylize 250", "sref"])
        let cams = try idx.facetCounts(.camera, filter: FilterState(), search: nil)
        #expect(cams == [FacetValue(value: "Leica Q3", count: 1)])
    }

    @Test func dateRangeAndSearch() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState(); f.dateFrom = Date(timeIntervalSince1970: 1_500); f.dateTo = Date(timeIntervalSince1970: 4_500)
        #expect(try names(idx, f) == ["b.png", "c.png", "photo.jpg"])
        #expect(try names(idx, f, search: "red") == ["c.png"])
        #expect(try idx.monthHistogram(filter: FilterState(), search: nil).reduce(0) { $0 + $1.count } == 5)
    }

    @Test func savedSearchesRoundTrip() throws {
        let (idx, _) = try makeIndex()
        var f = FilterState(); f.sources = [.midjourney]; f.params = ["raw"]
        let a = try idx.addSavedSearch(name: "Raw MJ", color: "orange", folder: "Portraits", query: SearchQuery(text: "cat", filter: f, sort: .oldestFirst))
        let b = try idx.addSavedSearch(name: "Photos", color: "blue", folder: nil, query: SearchQuery())
        #expect(try idx.savedSearches().map(\.name) == ["Raw MJ", "Photos"])
        try idx.reorderSavedSearches([b.id, a.id])
        let list = try idx.savedSearches()
        #expect(list.map(\.name) == ["Photos", "Raw MJ"])
        #expect(list[1].query == SearchQuery(text: "cat", filter: f, sort: .oldestFirst))
        try idx.deleteSavedSearch(id: b.id)
        #expect(try idx.savedSearches().count == 1)
    }

    @Test func tolerantDecoding() throws {
        let json = #"{"text":"x","filter":{"sources":["midjourney","alien"],"future":1},"sort":"bogus"}"#
        let q = try JSONDecoder().decode(SearchQuery.self, from: Data(json.utf8))
        #expect(q.text == "x")
        #expect(q.filter.sources == [.midjourney])
        #expect(q.sort == .newestFirst)
    }

    @Test func migratesV1KeepingThumbnails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        // A minimal v1 file.
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
        CREATE TABLE library(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO library VALUES('schema_version','1');
        CREATE TABLE items(id INTEGER PRIMARY KEY, rel_path TEXT UNIQUE NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL,
          file_mtime REAL NOT NULL, kind TEXT NOT NULL, width INTEGER, height INTEGER, created_at REAL, created_source TEXT, author TEXT,
          prompt_raw TEXT, prompt_text TEXT, params TEXT, aspect TEXT, job_id TEXT, xmp TEXT, meta_state INTEGER NOT NULL DEFAULT 0,
          thumb_pack INTEGER, thumb_offset INTEGER, thumb_length INTEGER, thumb_state INTEGER NOT NULL DEFAULT 0);
        INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind, meta_state, thumb_pack, thumb_offset, thumb_length, thumb_state)
          VALUES('a.png','a.png',1,0,'png',1,0,0,10,1);
        """, nil, nil, nil)
        sqlite3_close(db)
        let idx = try LibraryIndex(url: URL(fileURLWithPath: path))
        #expect(try idx.pendingMetadata(limit: 5).count == 1)  // metadata re-read
        let id = try idx.pendingMetadata(limit: 1)[0].id
        #expect(try idx.thumbnailLocation(id: id) == ThumbnailLocation(pack: 0, offset: 0, length: 10))  // thumbnail kept
        #expect(try idx.value(forKey: "schema_version") == "5")
    }
}
