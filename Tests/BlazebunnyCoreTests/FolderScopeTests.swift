import Foundation
import Testing
@testable import BlazebunnyCore

/// Schema v3: the folder tree (`dirs`, `items.dir_id`) and folder scopes.
struct FolderScopeTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeIndex() throws -> LibraryIndex {
        try LibraryIndex(url: tempDir().appendingPathComponent("index.sqlite"))
    }

    func rec(_ path: String, mtime: Double = 100) -> FileRecord {
        FileRecord(relPath: path, size: 10, mtime: mtime, kind: .png)
    }

    /// root.png, a/1.png, a/2.png, a/b/3.png, a/b/c/4.png, a/b/c/5.png, d/6.png, e/ (empty)
    func sample() throws -> LibraryIndex {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("root.png", mtime: 1), rec("a/1.png", mtime: 2), rec("a/2.png", mtime: 3),
                             rec("a/b/3.png", mtime: 4), rec("a/b/c/4.png", mtime: 5), rec("a/b/c/5.png", mtime: 6),
                             rec("d/6.png", mtime: 7)])
        try idx.upsertDirectories(["e"])
        return idx
    }

    func node(_ idx: LibraryIndex, _ path: String) throws -> DirNode {
        try #require(try idx.directoryTree().first { $0.path == path })
    }

    func names(_ items: [BrowseItem]) -> [String] { items.map(\.relPath).sorted() }

    // MARK: - Tree and counts

    @Test func treeHasDirectAndSubtreeCounts() throws {
        let idx = try sample()
        let tree = try idx.directoryTree()
        #expect(tree.map(\.path).sorted() == ["a", "a/b", "a/b/c", "d", "e"])
        let a = try node(idx, "a"), b = try node(idx, "a/b"), c = try node(idx, "a/b/c")
        #expect((a.directCount, a.subtreeCount) == (2, 5))
        #expect((b.directCount, b.subtreeCount) == (1, 3))
        #expect((c.directCount, c.subtreeCount) == (2, 2))
        #expect(a.parentID == nil && b.parentID == a.id && c.parentID == b.id)
        #expect(a.name == "a" && c.name == "c")
        #expect((a.depth, b.depth, c.depth) == (1, 2, 3))
    }

    @Test func emptyFolderIsInTheTreeWithZeroCounts() throws {
        let idx = try sample()
        let e = try node(idx, "e")
        #expect(e.directCount == 0 && e.subtreeCount == 0)
    }

    // MARK: - Scope

    @Test func scopeIncludesDescendants() throws {
        let idx = try sample()
        let a = try node(idx, "a"), b = try node(idx, "a/b"), c = try node(idx, "a/b/c"), e = try node(idx, "e")
        #expect(names(try idx.items(folder: a.id)) == ["a/1.png", "a/2.png", "a/b/3.png", "a/b/c/4.png", "a/b/c/5.png"])
        #expect(names(try idx.items(folder: b.id)) == ["a/b/3.png", "a/b/c/4.png", "a/b/c/5.png"])
        #expect(names(try idx.items(folder: c.id)) == ["a/b/c/4.png", "a/b/c/5.png"])
        #expect(try idx.items(folder: e.id).isEmpty)
        #expect(try idx.items(folder: nil).count == 7)
    }

    @Test func scopeDoesNotMatchSiblingsWithTheSamePrefix() throws {
        let idx = try makeIndex()
        try idx.upsertFiles([rec("a/1.png"), rec("ab/2.png"), rec("a b/3.png"), rec("a.b/4.png")])
        let a = try #require(try idx.dirID(forPath: "a"))
        #expect(names(try idx.items(folder: a)) == ["a/1.png"])
    }

    @Test func scopeAppliesBeforeSortAndMatchesAllSorts() throws {
        let idx = try sample()
        let a = try node(idx, "a")
        #expect(try idx.items(sort: .newestFirst, folder: a.id).map(\.relPath).first == "a/b/c/5.png")
        #expect(try idx.items(sort: .oldestFirst, folder: a.id).map(\.relPath).first == "a/1.png")
        #expect(try idx.items(sort: .name, folder: a.id).map(\.relPath).first == "a/1.png")
    }

    @Test func limitReturnsTheFirstRowsOfTheSameOrder() throws {
        let idx = try sample()
        let all = try idx.items().map(\.id)
        #expect(try idx.items(limit: 3).map(\.id) == Array(all.prefix(3)))
    }

    @Test func scopeCombinesWithFilterSearchFacetsSummaryAndHistogram() throws {
        let idx = try sample()
        let pending = try idx.pendingMetadata(limit: 20)
        var batch: [(id: Int64, metadata: ItemMetadata?)] = []
        for p in pending {
            let m = ItemMetadata(width: 10, height: 10, promptRaw: p.relPath.hasPrefix("a/b") ? "red cat --v 7" : "blue dog")
            batch.append((p.id, m))
        }
        try idx.saveMetadata(batch)
        let a = try node(idx, "a"), b = try node(idx, "a/b")

        #expect(names(try idx.items(search: "cat", folder: a.id)) == ["a/b/3.png", "a/b/c/4.png", "a/b/c/5.png"])
        #expect(names(try idx.items(search: "cat", folder: b.id)).count == 3)
        #expect(try idx.items(search: "dog", folder: b.id).isEmpty)

        let s = try idx.summary(folder: a.id)
        #expect(s.total == 5)
        #expect(s.totalBytes == 50)
        #expect(s.withPrompt == 5)
        #expect(try idx.summary(folder: b.id).total == 3)
        #expect(try idx.summary().total == 7)

        let kinds = try idx.facetCounts(.type, filter: FilterState(), search: nil, folder: b.id)
        #expect(kinds == [FacetValue(value: "png", count: 3)])
        let hist = try idx.monthHistogram(filter: FilterState(), search: nil, folder: b.id)
        #expect(hist.reduce(0) { $0 + $1.count } == 3)
    }

    // MARK: - Scanner behaviour (index level)

    @Test func movingAFileBetweenFoldersUpdatesTheScope() throws {
        let idx = try sample()
        let a = try node(idx, "a"), d = try node(idx, "d")
        // The scanner sees "a/1.png" gone and "d/1.png" new.
        try idx.deleteFiles(relPaths: ["a/1.png"])
        try idx.upsertFiles([rec("d/1.png")])
        #expect(names(try idx.items(folder: a.id)).contains("a/1.png") == false)
        #expect(names(try idx.items(folder: d.id)) == ["d/1.png", "d/6.png"])
        let tree = try idx.directoryTree()
        #expect(tree.first { $0.path == "a" }?.subtreeCount == 4)
        #expect(tree.first { $0.path == "d" }?.directCount == 2)
    }

    @Test func unchangedFileKeepsItsFolderAndMetadata() throws {
        let idx = try sample()
        let id = try #require(try idx.pendingMetadata(limit: 1).first).id
        try idx.saveMetadata(id: id, ItemMetadata(width: 1, height: 1))
        let before = try idx.directoryTree()
        try idx.upsertFiles([rec("a/1.png", mtime: 2)])
        #expect(try idx.directoryTree() == before)
    }

    @Test func removingVanishedDirectoriesKeepsOnesWithFiles() throws {
        let idx = try sample()
        try idx.deleteFiles(relPaths: ["d/6.png"])
        try idx.removeDirectories(keeping: ["a", "a/b", "a/b/c"])  // d and e are gone from disk
        #expect(try idx.directoryTree().map(\.path).sorted() == ["a", "a/b", "a/b/c"])
        // A directory that still holds files is never removed, whatever the listing says.
        try idx.removeDirectories(keeping: [])
        #expect(try idx.directoryTree().map(\.path).sorted() == ["a", "a/b", "a/b/c"])
    }

    @Test func unicodeAndDeepPaths() throws {
        let idx = try makeIndex()
        let deep = (1...60).map { "d\($0)" }.joined(separator: "/")
        try idx.upsertFiles([rec("Ünï/日本語 フォルダ/é.png"), rec("emoji 🐰/x.png"), rec(deep + "/leaf.png")])
        let uni = try #require(try idx.dirID(forPath: "Ünï"))
        #expect(names(try idx.items(folder: uni)) == ["Ünï/日本語 フォルダ/é.png"])
        let top = try #require(try idx.dirID(forPath: "d1"))
        #expect(names(try idx.items(folder: top)) == [deep + "/leaf.png"])
        let tree = try idx.directoryTree()
        #expect(tree.first { $0.path == deep }?.depth == 60)
        #expect(tree.first { $0.path == "emoji 🐰" }?.name == "emoji 🐰")
        #expect(tree.first { $0.path == "d1" }?.subtreeCount == 1)
    }

    @Test func savedSearchRemembersItsFolder() throws {
        let idx = try sample()
        var q = SearchQuery()
        q.folder = "a/b"
        let s = try idx.addSavedSearch(name: "In b", color: "blue", folder: nil, query: q)
        let loaded = try #require(try idx.savedSearches().first { $0.id == s.id })
        #expect(loaded.query.folder == "a/b")
        let id = try #require(try idx.dirID(forPath: loaded.query.folder!))
        #expect(try idx.items(folder: id).count == 3)
        // A search written before folder scopes existed still decodes.
        let old = try JSONDecoder().decode(SearchQuery.self, from: Data(#"{"text":"x","sort":"name"}"#.utf8))
        #expect(old.folder == nil && old.text == "x")
    }

    // MARK: - Migration

    @Test func migratesAV2IndexWithoutLosingAnything() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("index.sqlite")
        do {
        let db = try SQLiteDB(path: url.path)
        try db.exec("""
        CREATE TABLE library(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO library VALUES('schema_version', '2');
        CREATE TABLE items(
          id INTEGER PRIMARY KEY, rel_path TEXT UNIQUE NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL,
          file_mtime REAL NOT NULL, kind TEXT NOT NULL, width INTEGER, height INTEGER, created_at REAL, created_source TEXT,
          author TEXT, prompt_raw TEXT, prompt_text TEXT, params TEXT, aspect TEXT, job_id TEXT, xmp TEXT,
          meta_state INTEGER NOT NULL DEFAULT 0, thumb_pack INTEGER, thumb_offset INTEGER, thumb_length INTEGER,
          thumb_state INTEGER NOT NULL DEFAULT 0, source TEXT, orientation TEXT, mj_version TEXT, camera TEXT,
          camera_json TEXT, generator_json TEXT);
        CREATE TABLE item_params(item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          name TEXT NOT NULL, value TEXT NOT NULL, facet TEXT NOT NULL);
        CREATE TABLE saved_searches(id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, folder TEXT,
          position INTEGER NOT NULL, query TEXT NOT NULL);
        INSERT INTO saved_searches VALUES(1, 'Old', 'blue', NULL, 0, '{"text":"cat"}');
        INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind, meta_state, thumb_pack, thumb_offset, thumb_length, thumb_state, width, height, prompt_raw)
          VALUES('top.png','top.png',1,10,'png',1,0,0,5,1,640,480,'a cat');
        INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind) VALUES('x/y/z.png','z.png',1,20,'png');
        INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind) VALUES('x/w.png','w.png',1,30,'png');
        """)
        }
        let idx = try LibraryIndex(url: url)
        #expect(try idx.counts().total == 3)
        #expect(try idx.directoryTree().map(\.path).sorted() == ["x", "x/y"])
        let x = try #require(try idx.dirID(forPath: "x"))
        #expect(names(try idx.items(folder: x)) == ["x/w.png", "x/y/z.png"])
        let top = try #require(try idx.items(search: nil).first { $0.relPath == "top.png" })
        #expect(top.hasThumbnail && top.width == 640)  // thumbnails and metadata kept
        #expect(try idx.savedSearches().first?.query.text == "cat")
        // Opening it again is a no-op.
        let again = try LibraryIndex(url: url)
        #expect(try again.directoryTree().count == 2)
    }

    // MARK: - Budget

    /// 100 top folders, 10 subfolders each, 100 files each = 100 000 files. The folder scope is an
    /// integer match, so a subtree of 10 000 must not cost more than a few ms of SQL.
    @Test func scopedQueryOnA100kIndexStaysWithinBudget() throws {
        let idx = try makeIndex()
        var files: [FileRecord] = []
        files.reserveCapacity(100_000)
        for t in 0..<100 { for s in 0..<10 { for f in 0..<100 {
            files.append(rec("top\(t)/sub\(s)/img\(f).png", mtime: Double(t * 100_000 + s * 1_000 + f)))
        } } }
        try idx.upsertFiles(files)
        #expect(try idx.counts().total == 100_000)

        let t0 = Date()
        let tree = try idx.directoryTree()
        let treeTime = Date().timeIntervalSince(t0)
        #expect(tree.count == 1_100)
        #expect(tree.first { $0.path == "top7" }?.subtreeCount == 1_000)

        let id = try #require(try idx.dirID(forPath: "top42"))
        let t1 = Date()
        let items = try idx.items(folder: id)
        let scopeTime = Date().timeIntervalSince(t1)
        #expect(items.count == 1_000)

        let t2 = Date()
        _ = try idx.items(filter: FilterState(), search: nil, sort: .newestFirst, folder: id, limit: 400)
        _ = try idx.summary(folder: id)
        let firstTime = Date().timeIntervalSince(t2)

        // Generous in debug builds (Swift row mapping is slow there); tight numbers are
        // measured in release by `bbscopebench` and recorded in docs/MILESTONES.md.
        #if DEBUG
        let slack = 6.0
        #else
        let slack = 1.0
        #endif
        #expect(treeTime < 0.120 * slack, "tree took \(treeTime)")
        #expect(scopeTime < 0.150 * slack, "scope took \(scopeTime)")
        #expect(firstTime < 0.050 * slack, "first rows took \(firstTime)")
    }
}
