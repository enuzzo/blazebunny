import Foundation

public struct FileRecord: Sendable, Equatable {
    public var relPath: String
    public var size: Int64
    public var mtime: Double
    public var kind: ItemKind
    public init(relPath: String, size: Int64, mtime: Double, kind: ItemKind) {
        self.relPath = relPath
        self.size = size
        self.mtime = mtime
        self.kind = kind
    }
}

public struct BrowseItem: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var relPath: String
    public var sortDate: Double
    public var width: Int?
    public var height: Int?
    /// Where the thumbnail sits in the packs; nil while it has not been made. Carried here so a
    /// grid cell reads its thumbnail without asking the index.
    public var thumbnail: ThumbnailLocation?
    public var source: ItemSource?
    public var aspect: String?

    public init(id: Int64, relPath: String, sortDate: Double, width: Int? = nil, height: Int? = nil,
                thumbnail: ThumbnailLocation? = nil, source: ItemSource? = nil, aspect: String? = nil) {
        self.id = id
        self.relPath = relPath
        self.sortDate = sortDate
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
        self.source = source
        self.aspect = aspect
    }

    public var hasThumbnail: Bool { thumbnail != nil }
    /// The file's name without its folders.
    public var fileName: Substring { relPath.lastIndex(of: "/").map { relPath[relPath.index(after: $0)...] } ?? relPath[...] }
}

public struct ItemDetail: Sendable, Equatable {
    public var id: Int64
    public var relPath: String
    public var kind: ItemKind
    public var size: Int64
    public var mtime: Double
    /// nil while metadata has not been read yet.
    public var metadata: ItemMetadata?
    public var metadataFailed: Bool
}

public struct PendingItem: Sendable, Equatable {
    public var id: Int64
    public var relPath: String
    public var kind: ItemKind
    public var mtime: Double
}

public struct ThumbnailLocation: Sendable, Hashable {
    public var pack: Int
    public var offset: Int64
    public var length: Int
    public init(pack: Int, offset: Int64, length: Int) {
        self.pack = pack
        self.offset = offset
        self.length = length
    }
}

/// One folder of the library's tree. The library root itself is not a node: top-level
/// folders have `parentID == nil`. Items directly in the root belong to no node.
public struct DirNode: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var parentID: Int64?
    public var name: String
    /// Path relative to the library root, "/"-separated, no leading slash.
    public var path: String
    /// 1 for a top-level folder.
    public var depth: Int
    /// Items directly in this folder.
    public var directCount: Int
    /// Items in this folder and every folder below it.
    public var subtreeCount: Int
}

public enum ItemSort: String, Codable, Sendable, CaseIterable {
    case newestFirst, oldestFirst, name

    public var title: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .name: return "Name"
        }
    }

    public var isByDate: Bool { self != .name }
}

/// The SQLite index of one library, shared between the scanner and the UI.
///
/// Three connections to the same WAL database, each serialised on its own lock: the **writer**
/// (the scanner, and the few edits the UI makes), a read-only one for **lists** (everything a view
/// shows: items, counts, facets, summary) and a read-only one for **lookups** (one image's detail).
/// A reader never waits for the writer, so arrowing through images and reloading the grid stay
/// quick while a scan writes; a lookup never waits for a long list query either.
public final class LibraryIndex: @unchecked Sendable {
    static let schemaVersion = 4

    final class Connection: @unchecked Sendable {
        let db: SQLiteDB
        private let lock = NSLock()
        init(_ db: SQLiteDB) { self.db = db }
        func sync<T>(_ body: (SQLiteDB) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(db)
        }
    }

    let writer: Connection
    private(set) var lists: Connection
    private(set) var lookups: Connection
    private var db: SQLiteDB { writer.db }
    /// Folder path to `dirs.id`. Only touched under the writer's lock (or during migration).
    private var dirCache: [String: Int64] = [:]
    /// The last month histogram, valid while the database has not changed.
    var histogramCache: (key: String, version: Int64, months: [MonthCount])?

    public init(url: URL) throws {
        // An index file that predates the creation-date key tells us when the
        // library was first opened; a new file is created now.
        let existingDate = FileManager.default.fileExists(atPath: url.path)
            ? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) : nil
        let main = try SQLiteDB(path: url.path)
        writer = Connection(main)
        try main.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        // Placeholders so every stored property is set before `migrate()` may throw.
        lists = writer
        lookups = writer
        try migrate()
        try main.run("INSERT OR IGNORE INTO library(key, value) VALUES('created_at', ?)",
                     [String((existingDate ?? Date()).timeIntervalSince1970)])
        lists = Self.openReader(path: url.path) ?? writer
        lookups = Self.openReader(path: url.path) ?? writer
    }

    /// A reader that cannot be opened (an odd file system) is replaced by the writer: slower, still correct.
    private static func openReader(path: String) -> Connection? {
        guard let db = try? SQLiteDB(path: path, readOnly: true),
              (try? db.exec("PRAGMA temp_store=MEMORY;")) != nil else { return nil }
        return Connection(db)
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        try writer.sync { _ in try body() }
    }

    // MARK: - Schema

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS library(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS items(
          id INTEGER PRIMARY KEY,
          rel_path TEXT UNIQUE NOT NULL,
          file_name TEXT NOT NULL,
          file_size INTEGER NOT NULL,
          file_mtime REAL NOT NULL,
          kind TEXT NOT NULL,
          width INTEGER, height INTEGER,
          created_at REAL,
          created_source TEXT,
          author TEXT,
          prompt_raw TEXT,
          prompt_text TEXT,
          params TEXT,
          aspect TEXT,
          job_id TEXT,
          xmp TEXT,
          meta_state INTEGER NOT NULL DEFAULT 0,
          thumb_pack INTEGER, thumb_offset INTEGER, thumb_length INTEGER,
          thumb_state INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS items_meta ON items(meta_state);
        CREATE INDEX IF NOT EXISTS items_thumb ON items(thumb_state);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          prompt_text, file_name, content='items', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, prompt_text, file_name) VALUES (new.id, new.prompt_text, new.file_name);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, prompt_text, file_name) VALUES('delete', old.id, old.prompt_text, old.file_name);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF prompt_text, file_name ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, prompt_text, file_name) VALUES('delete', old.id, old.prompt_text, old.file_name);
          INSERT INTO items_fts(rowid, prompt_text, file_name) VALUES (new.id, new.prompt_text, new.file_name);
        END;
        """)
        var version = 1
        try db.query("SELECT value FROM library WHERE key = 'schema_version'") { version = Int($0.string(0) ?? "1") ?? 1 }
        if version < 2 {
            try db.transaction {
                for col in ["source TEXT", "orientation TEXT", "mj_version TEXT", "camera TEXT", "camera_json TEXT", "generator_json TEXT"] {
                    try db.exec("ALTER TABLE items ADD COLUMN \(col)")
                }
                try db.exec("""
                CREATE TABLE item_params(
                  item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                  name TEXT NOT NULL, value TEXT NOT NULL, facet TEXT NOT NULL);
                CREATE INDEX item_params_item ON item_params(item_id);
                CREATE INDEX item_params_facet ON item_params(facet, item_id);
                CREATE INDEX items_source ON items(source);
                CREATE TABLE saved_searches(
                  id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT NOT NULL, folder TEXT,
                  position INTEGER NOT NULL, query TEXT NOT NULL);
                UPDATE items SET meta_state = 0;
                """)
                try db.run("INSERT OR REPLACE INTO library(key, value) VALUES('schema_version', '2')")
            }
        }
        if version < 3 {
            // Folder tree. Filled from the stored paths only: no disk is read, and thumbnails and
            // metadata are untouched.
            try db.transaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS dirs(
                  id INTEGER PRIMARY KEY,
                  parent_id INTEGER,
                  name TEXT NOT NULL,
                  path TEXT UNIQUE NOT NULL,
                  depth INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS dirs_parent ON dirs(parent_id);
                ALTER TABLE items ADD COLUMN dir_id INTEGER;
                """)
                _ = try ensureDir("")
                var rows: [(Int64, String)] = []
                try db.query("SELECT id, rel_path FROM items") { rows.append(($0.int(0), $0.string(1) ?? "")) }
                for (id, path) in rows {
                    try db.run("UPDATE items SET dir_id = ? WHERE id = ?", [try ensureDir(Self.dirPath(of: path)), id])
                }
                // Folder scope and the counts per folder: one index covers both.
                try db.exec("CREATE INDEX IF NOT EXISTS items_dir_sort ON items(dir_id, coalesce(created_at, file_mtime))")
                try db.run("INSERT OR REPLACE INTO library(key, value) VALUES('schema_version', '3')")
            }
        }
        if version < 4 {
            // One index that holds everything the grid, the counts, the facets and the summary read,
            // in date order: those queries walk it and never touch the wide rows (prompt, XMP). On a
            // 100k library it is about 15 MB and builds in a fraction of a second. It replaces the
            // plain date index. The name index gives the first rows of a name-sorted view at once.
            try db.transaction {
                try db.exec("""
                CREATE INDEX IF NOT EXISTS items_browse ON items(
                  coalesce(created_at, file_mtime), id, rel_path, width, height, thumb_pack, thumb_offset, thumb_length,
                  source, aspect, kind, orientation, mj_version, camera, file_size,
                  (prompt_raw IS NOT NULL AND prompt_raw != ''));
                CREATE INDEX IF NOT EXISTS items_name ON items(file_name COLLATE NOCASE);
                DROP INDEX IF EXISTS items_sort;
                """)
                try db.run("INSERT OR REPLACE INTO library(key, value) VALUES('schema_version', '4')")
            }
        }
    }

    /// Refreshes the query planner's statistics (sampled, so cheap even on 100k rows). Without
    /// them SQLite guesses, and can walk a big filter or full-text index instead of the folder index.
    public func optimize() throws {
        try sync { try db.exec("PRAGMA analysis_limit=1000; PRAGMA optimize=0x10002;") }
    }

    // MARK: - Library key/value

    public func setValue(_ value: String?, forKey key: String) throws {
        try sync { try db.run("INSERT OR REPLACE INTO library(key, value) VALUES(?, ?)", [key, value]) }
    }

    public func value(forKey key: String) throws -> String? {
        try lookups.sync { db in
            var v: String?
            try db.query("SELECT value FROM library WHERE key = ?", [key]) { v = $0.string(0) }
            return v
        }
    }

    /// When this library was first opened on this Mac.
    public func createdAt() throws -> Date? {
        try value(forKey: "created_at").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Files

    public func knownFiles() throws -> [String: (size: Int64, mtime: Double)] {
        try sync {
            var out: [String: (Int64, Double)] = [:]
            try db.query("SELECT rel_path, file_size, file_mtime FROM items") { r in
                out[r.string(0)!] = (r.int(1), r.double(2) ?? 0)
            }
            return out
        }
    }

    /// Inserts new files; files whose size or mtime changed get their
    /// metadata and thumbnail reset to pending.
    public func upsertFiles(_ files: [FileRecord]) throws {
        try sync {
            try db.transaction {
                for f in files {
                    let dir = try ensureDir(Self.dirPath(of: f.relPath))
                    try db.run("""
                    INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind, dir_id) VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(rel_path) DO UPDATE SET
                      file_size = excluded.file_size, file_mtime = excluded.file_mtime, kind = excluded.kind,
                      dir_id = excluded.dir_id,
                      meta_state = 0, thumb_state = 0, thumb_pack = NULL, thumb_offset = NULL, thumb_length = NULL
                    WHERE items.file_size != excluded.file_size OR items.file_mtime != excluded.file_mtime
                       OR items.dir_id IS NOT excluded.dir_id
                    """, [f.relPath, (f.relPath as NSString).lastPathComponent, f.size, f.mtime, f.kind.rawValue, dir])
                }
            }
        }
    }

    public func deleteFiles(relPaths: [String]) throws {
        try sync {
            try db.transaction {
                for p in relPaths { try db.run("DELETE FROM items WHERE rel_path = ?", [p]) }
            }
        }
    }

    // MARK: - Folders

    /// "a/b/c.png" -> "a/b"; a file in the root -> "".
    static func dirPath(of relPath: String) -> String {
        guard let i = relPath.lastIndex(of: "/") else { return "" }
        return String(relPath[..<i])
    }

    /// Finds or creates the folder row for `path` and every folder above it.
    private func ensureDir(_ path: String) throws -> Int64 {
        if let id = dirCache[path] { return id }
        var found: Int64?
        try db.query("SELECT id FROM dirs WHERE path = ?", [path]) { found = $0.int(0) }
        if let found { dirCache[path] = found; return found }
        var parent: Int64?
        var name = ""
        var depth = 0
        if !path.isEmpty {
            let parentPath = Self.dirPath(of: path)
            parent = try ensureDir(parentPath)
            name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
            depth = path.reduce(1) { $1 == "/" ? $0 + 1 : $0 }
        }
        try db.run("INSERT INTO dirs(parent_id, name, path, depth) VALUES(?, ?, ?, ?)", [parent, name, path, depth])
        let id = db.lastInsertRowID
        dirCache[path] = id
        return id
    }

    /// Records folders even when they hold no supported image (so empty folders show in the tree).
    public func upsertDirectories(_ paths: [String]) throws {
        try sync {
            try db.transaction { for p in paths where !p.isEmpty { _ = try ensureDir(p) } }
        }
    }

    /// Removes folder rows that are not in `keeping`, except folders that hold items (directly or
    /// below) and the folders above those. Only call this with a trustworthy listing.
    public func removeDirectories(keeping: Set<String>) throws {
        try sync {
            var dirs: [(id: Int64, path: String)] = []
            try db.query("SELECT id, path FROM dirs WHERE path != ''") { dirs.append(($0.int(0), $0.string(1) ?? "")) }
            var keep = keeping
            try db.query("SELECT d.path FROM dirs d WHERE EXISTS (SELECT 1 FROM items WHERE items.dir_id = d.id)") { r in
                var p = r.string(0) ?? ""
                while !p.isEmpty, keep.insert(p).inserted { p = Self.dirPath(of: p) }
            }
            // Ancestors of listed folders are part of any real listing, but be safe.
            for p in keeping { var q = Self.dirPath(of: p); while !q.isEmpty, keep.insert(q).inserted { q = Self.dirPath(of: q) } }
            let doomed = dirs.filter { !keep.contains($0.path) }
            guard !doomed.isEmpty else { return }
            try db.transaction {
                for d in doomed { try db.run("DELETE FROM dirs WHERE id = ?", [d.id]); dirCache[d.path] = nil }
            }
        }
    }

    public func dirID(forPath path: String) throws -> Int64? {
        try lookups.sync { db in
            var id: Int64?
            try db.query("SELECT id FROM dirs WHERE path = ?", [path]) { id = $0.int(0) }
            return id
        }
    }

    /// Every folder with its counts, in no particular order. Built from one grouped read of the
    /// folder index and an in-memory roll-up, so it stays cheap on 100k items.
    public func directoryTree() throws -> [DirNode] {
        try lists.sync { db in
            var direct: [Int64: Int] = [:]
            try db.query("SELECT dir_id, count(*) FROM items WHERE dir_id IS NOT NULL GROUP BY dir_id") { direct[$0.int(0)] = Int($0.int(1)) }
            var rootID: Int64 = -1
            try db.query("SELECT id FROM dirs WHERE path = ''") { rootID = $0.int(0) }
            var nodes: [DirNode] = []
            try db.query("SELECT id, parent_id, name, path, depth FROM dirs WHERE path != '' ORDER BY id") { r in
                let parent = r.intOrNil(1).map(Int64.init)
                nodes.append(DirNode(id: r.int(0), parentID: parent == rootID ? nil : parent, name: r.string(2) ?? "",
                                     path: r.string(3) ?? "", depth: Int(r.int(4)),
                                     directCount: direct[r.int(0)] ?? 0, subtreeCount: direct[r.int(0)] ?? 0))
            }
            var position: [Int64: Int] = [:]
            for (i, n) in nodes.enumerated() { position[n.id] = i }
            // Deepest first, so each folder's total is complete before it is added to its parent.
            for i in nodes.indices.sorted(by: { nodes[$0].depth > nodes[$1].depth }) {
                if let p = nodes[i].parentID, let pi = position[p] { nodes[pi].subtreeCount += nodes[i].subtreeCount }
            }
            return nodes
        }
    }

    // MARK: - Metadata

    public func pendingMetadata(limit: Int) throws -> [PendingItem] {
        try pending(state: "meta_state", limit: limit)
    }

    public func saveMetadata(id: Int64, _ m: ItemMetadata?) throws {
        try saveMetadata([(id, m)])
    }

    /// Saves a batch of results in one transaction. `nil` marks a failure.
    public func saveMetadata(_ batch: [(id: Int64, metadata: ItemMetadata?)]) throws {
        let enc = JSONEncoder()
        try sync {
            try db.transaction {
                for (id, m) in batch {
                    guard let m else {
                        try db.run("UPDATE items SET meta_state = 2, source = 'unknown' WHERE id = ?", [id])
                        continue
                    }
                    let p = m.prompt
                    let params = p.flatMap { try? String(data: enc.encode($0.parameters), encoding: .utf8) }
                    let cam = m.camera.flatMap { try? String(data: enc.encode($0), encoding: .utf8) }
                    let gen = m.generator.flatMap { try? String(data: enc.encode($0), encoding: .utf8) }
                    try db.run("""
                    UPDATE items SET width = ?, height = ?, created_at = ?, created_source = ?, author = ?,
                      prompt_raw = ?, prompt_text = ?, params = ?, aspect = ?, job_id = ?, xmp = ?, meta_state = 1,
                      source = ?, orientation = ?, mj_version = ?, camera = ?, camera_json = ?, generator_json = ?
                    WHERE id = ?
                    """, [m.width, m.height, m.createdAt?.timeIntervalSince1970, m.createdSource.rawValue, m.author,
                          m.promptRaw, m.promptText, params, m.aspect, p?.jobID, m.xmp,
                          m.source.rawValue, m.orientation?.rawValue, m.mjVersion, m.camera?.camera, cam, gen, id])
                    try db.run("DELETE FROM item_params WHERE item_id = ?", [id])
                    for param in p?.parameters ?? [] where !["ar", "aspect", "v", "version", "niji"].contains(param.name) {
                        try db.run("INSERT INTO item_params(item_id, name, value, facet) VALUES(?, ?, ?, ?)",
                                   [id, param.name, param.value, paramFacetKey(param)])
                    }
                }
            }
        }
    }

    // MARK: - Thumbnails

    public func pendingThumbnails(limit: Int) throws -> [PendingItem] {
        try pending(state: "thumb_state", limit: limit)
    }

    public func pendingThumbnails(ids: [Int64]) throws -> [PendingItem] {
        guard !ids.isEmpty else { return [] }
        return try sync {
            var out: [PendingItem] = []
            // One bound JSON array, so the SQL text is constant and the statement is cached once.
            let list = "[" + ids.map(String.init).joined(separator: ",") + "]"
            try db.query("SELECT id, rel_path, kind, file_mtime FROM items WHERE thumb_state = 0 AND id IN (SELECT value FROM json_each(?))", [list]) { r in
                out.append(PendingItem(id: r.int(0), relPath: r.string(1)!, kind: ItemKind(rawValue: r.string(2)!) ?? .other, mtime: r.double(3) ?? 0))
            }
            return out
        }
    }

    public func saveThumbnail(id: Int64, _ loc: ThumbnailLocation?) throws {
        try saveThumbnails([(id, loc)])
    }

    /// Records a batch of thumbnails in one transaction. `nil` marks a failure.
    public func saveThumbnails(_ batch: [(id: Int64, location: ThumbnailLocation?)]) throws {
        guard !batch.isEmpty else { return }
        try sync {
            try db.transaction {
                for (id, loc) in batch {
                    if let loc {
                        try db.run("UPDATE items SET thumb_pack = ?, thumb_offset = ?, thumb_length = ?, thumb_state = 1 WHERE id = ?",
                                   [loc.pack, loc.offset, loc.length, id])
                    } else {
                        try db.run("UPDATE items SET thumb_state = 2 WHERE id = ?", [id])
                    }
                }
            }
        }
    }

    public func thumbnailLocation(id: Int64) throws -> ThumbnailLocation? {
        try lookups.sync { db in
            var loc: ThumbnailLocation?
            try db.query("SELECT thumb_pack, thumb_offset, thumb_length FROM items WHERE id = ? AND thumb_state = 1", [id]) { r in
                loc = ThumbnailLocation(pack: Int(r.int(0)), offset: r.int(1), length: Int(r.int(2)))
            }
            return loc
        }
    }

    private func pending(state: String, limit: Int) throws -> [PendingItem] {
        try sync {
            var out: [PendingItem] = []
            try db.query("SELECT id, rel_path, kind, file_mtime FROM items WHERE \(state) = 0 ORDER BY id LIMIT ?", [limit]) { r in
                out.append(PendingItem(id: r.int(0), relPath: r.string(1)!, kind: ItemKind(rawValue: r.string(2)!) ?? .other, mtime: r.double(3) ?? 0))
            }
            return out
        }
    }
}
