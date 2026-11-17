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
    public var hasThumbnail: Bool
    public var source: ItemSource?
    public var aspect: String?
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

public struct ThumbnailLocation: Sendable, Equatable {
    public var pack: Int
    public var offset: Int64
    public var length: Int
    public init(pack: Int, offset: Int64, length: Int) {
        self.pack = pack
        self.offset = offset
        self.length = length
    }
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

/// The SQLite index of one library. All calls are serialised on an internal
/// lock, so it can be shared between the scanner and the UI.
public final class LibraryIndex: @unchecked Sendable {
    static let schemaVersion = 2
    private let db: SQLiteDB
    private let lock = NSLock()

    public init(url: URL) throws {
        // An index file that predates the creation-date key tells us when the
        // library was first opened; a new file is created now.
        let existingDate = FileManager.default.fileExists(atPath: url.path)
            ? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) : nil
        db = try SQLiteDB(path: url.path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try migrate()
        try db.run("INSERT OR IGNORE INTO library(key, value) VALUES('created_at', ?)",
                   [String((existingDate ?? Date()).timeIntervalSince1970)])
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
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
        CREATE INDEX IF NOT EXISTS items_sort ON items(coalesce(created_at, file_mtime));
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
    }

    // MARK: - Library key/value

    public func setValue(_ value: String?, forKey key: String) throws {
        try sync { try db.run("INSERT OR REPLACE INTO library(key, value) VALUES(?, ?)", [key, value]) }
    }

    public func value(forKey key: String) throws -> String? {
        try sync {
            var v: String?
            try db.query("SELECT value FROM library WHERE key = ?", [key]) { v = $0.string(0) }
            return v
        }
    }

    /// When this library was first opened on this Mac.
    public func createdAt() throws -> Date? {
        try value(forKey: "created_at").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Summary

    /// Totals for the items a filter and search would show.
    public func summary(filter: FilterState = FilterState(), search: String? = nil) throws -> LibrarySummary {
        try sync {
            let (w, args) = Self.whereClause(filter, search: search)
            var s = LibrarySummary()
            try db.query("""
            SELECT count(*), coalesce(sum(file_size), 0), min(\(Self.dateExpr)), max(\(Self.dateExpr)),
                   coalesce(sum(prompt_raw IS NOT NULL AND prompt_raw != ''), 0)
            FROM items WHERE \(w)
            """, args) { r in
                s.total = Int(r.int(0))
                s.totalBytes = r.int(1)
                s.oldest = r.double(2).map { Date(timeIntervalSince1970: $0) }
                s.newest = r.double(3).map { Date(timeIntervalSince1970: $0) }
                s.withPrompt = Int(r.int(4))
            }
            func group(_ column: String) throws -> [FacetValue] {
                var out: [FacetValue] = []
                try db.query("""
                SELECT \(column), count(*) AS n FROM items WHERE \(w) AND \(column) IS NOT NULL
                GROUP BY \(column) ORDER BY n DESC
                """, args) { r in out.append(FacetValue(value: r.string(0) ?? "", count: Int(r.int(1)))) }
                return out
            }
            s.kinds = try group("items.kind")
            s.sources = try group("items.source")
            return s
        }
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
                    try db.run("""
                    INSERT INTO items(rel_path, file_name, file_size, file_mtime, kind) VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(rel_path) DO UPDATE SET
                      file_size = excluded.file_size, file_mtime = excluded.file_mtime, kind = excluded.kind,
                      meta_state = 0, thumb_state = 0, thumb_pack = NULL, thumb_offset = NULL, thumb_length = NULL
                    WHERE items.file_size != excluded.file_size OR items.file_mtime != excluded.file_mtime
                    """, [f.relPath, (f.relPath as NSString).lastPathComponent, f.size, f.mtime, f.kind.rawValue])
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
        try sync {
            if let loc {
                try db.run("UPDATE items SET thumb_pack = ?, thumb_offset = ?, thumb_length = ?, thumb_state = 1 WHERE id = ?",
                           [loc.pack, loc.offset, loc.length, id])
            } else {
                try db.run("UPDATE items SET thumb_state = 2 WHERE id = ?", [id])
            }
        }
    }

    public func thumbnailLocation(id: Int64) throws -> ThumbnailLocation? {
        try sync {
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

    // MARK: - Filtering

    static let dateExpr = "coalesce(items.created_at, items.file_mtime)"

    /// WHERE clause for `filter` and `search`, leaving out `excluding` (for facet counts).
    static func whereClause(_ f: FilterState, search: String?, excluding: Facet? = nil) -> (String, [Any?]) {
        var parts: [String] = []
        var args: [Any?] = []
        func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
        func inList(_ column: String, _ values: [String]) {
            parts.append("\(column) IN (\(placeholders(values.count)))")
            args.append(contentsOf: values)
        }
        if let q = ftsQuery(search) {
            parts.append("items.id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)")
            args.append(q)
        }
        if excluding != .type, !f.types.isEmpty { inList("items.kind", f.types.sorted()) }
        if excluding != .shape, f.hasShape {
            var ors: [String] = []
            if !f.orientations.isEmpty {
                ors.append("items.orientation IN (\(placeholders(f.orientations.count)))")
                args.append(contentsOf: f.orientations.map(\.rawValue).sorted() as [String])
            }
            if !f.ratios.isEmpty {
                ors.append("items.aspect IN (\(placeholders(f.ratios.count)))")
                args.append(contentsOf: f.ratios.sorted() as [String])
            }
            parts.append("(" + ors.joined(separator: " OR ") + ")")
        }
        if excluding != .date {
            if let from = f.dateFrom { parts.append("\(dateExpr) >= ?"); args.append(from.timeIntervalSince1970) }
            if let to = f.dateTo { parts.append("\(dateExpr) < ?"); args.append(to.timeIntervalSince1970) }
        }
        if excluding != .source, !f.sources.isEmpty { inList("items.source", f.sources.map(\.rawValue).sorted()) }
        if excluding != .version, !f.versions.isEmpty { inList("items.mj_version", f.versions.sorted()) }
        if excluding != .camera, !f.cameras.isEmpty { inList("items.camera", f.cameras.sorted()) }
        if excluding != .param {
            for p in f.params.sorted() {
                parts.append("EXISTS (SELECT 1 FROM item_params ip WHERE ip.item_id = items.id AND ip.facet = ?)")
                args.append(p)
            }
        }
        return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), args)
    }

    public func items(filter: FilterState = FilterState(), search: String? = nil, sort: ItemSort = .newestFirst) throws -> [BrowseItem] {
        try sync {
            let order: String
            switch sort {
            case .newestFirst: order = "\(Self.dateExpr) DESC, items.id DESC"
            case .oldestFirst: order = "\(Self.dateExpr) ASC, items.id ASC"
            case .name: order = "items.file_name COLLATE NOCASE ASC"
            }
            let (w, args) = Self.whereClause(filter, search: search)
            var out: [BrowseItem] = []
            out.reserveCapacity(20_000)
            try db.query("""
            SELECT id, rel_path, \(Self.dateExpr), width, height, thumb_state, source, aspect FROM items
            WHERE \(w) ORDER BY \(order)
            """, args) { r in
                out.append(BrowseItem(id: r.int(0), relPath: r.string(1)!, sortDate: r.double(2) ?? 0,
                                      width: r.intOrNil(3), height: r.intOrNil(4), hasThumbnail: r.int(5) == 1,
                                      source: r.string(6).flatMap(ItemSource.init(rawValue:)), aspect: r.string(7)))
            }
            return out
        }
    }

    /// Kept for callers that only search and sort.
    public func gridItems(search: String? = nil, sort: ItemSort = .newestFirst) throws -> [BrowseItem] {
        try items(search: search, sort: sort)
    }

    /// Values of `facet` with how many items each would show, applying every
    /// other active filter. Shape returns orientations as "o:portrait" and ratios as "r:16:9".
    public func facetCounts(_ facet: Facet, filter: FilterState, search: String?) throws -> [FacetValue] {
        try sync {
            let (w, args) = Self.whereClause(filter, search: search, excluding: facet)
            var out: [FacetValue] = []
            func group(_ column: String, prefix: String = "", limit: Int = 200) throws {
                try db.query("""
                SELECT \(column), count(*) AS n FROM items WHERE \(w) AND \(column) IS NOT NULL
                GROUP BY \(column) ORDER BY n DESC LIMIT \(limit)
                """, args) { r in out.append(FacetValue(value: prefix + (r.string(0) ?? ""), count: Int(r.int(1)))) }
            }
            switch facet {
            case .type: try group("items.kind")
            case .shape:
                try group("items.orientation", prefix: "o:")
                try group("items.aspect", prefix: "r:", limit: 40)
            case .source: try group("items.source")
            case .version: try group("items.mj_version")
            case .camera: try group("items.camera")
            case .param:
                try db.query("""
                SELECT ip.facet, count(DISTINCT ip.item_id) AS n FROM item_params ip JOIN items ON items.id = ip.item_id
                WHERE \(w) GROUP BY ip.facet ORDER BY n DESC LIMIT 60
                """, args) { r in out.append(FacetValue(value: r.string(0) ?? "", count: Int(r.int(1)))) }
            case .date:
                break
            }
            return out
        }
    }

    /// Item count per month ("2025-03"), oldest first, ignoring the date filter.
    public func monthHistogram(filter: FilterState, search: String?) throws -> [MonthCount] {
        try sync {
            let (w, args) = Self.whereClause(filter, search: search, excluding: .date)
            var out: [MonthCount] = []
            try db.query("""
            SELECT strftime('%Y-%m', \(Self.dateExpr), 'unixepoch', 'localtime') AS m, count(*) FROM items
            WHERE \(w) GROUP BY m ORDER BY m
            """, args) { r in out.append(MonthCount(month: r.string(0) ?? "", count: Int(r.int(1)))) }
            return out
        }
    }

    /// Turns free text into an FTS5 query: every word must match as a prefix.
    static func ftsQuery(_ search: String?) -> String? {
        guard let s = search?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let words = s.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " ")
    }

    public func detail(id: Int64) throws -> ItemDetail? {
        let dec = JSONDecoder()
        return try sync {
            var d: ItemDetail?
            try db.query("""
            SELECT id, rel_path, kind, file_size, file_mtime, meta_state, width, height, created_at, created_source,
                   author, prompt_raw, xmp, source, camera_json, generator_json FROM items WHERE id = ?
            """, [id]) { r in
                let state = r.int(5)
                var meta: ItemMetadata?
                if state == 1 {
                    meta = ItemMetadata(width: r.intOrNil(6), height: r.intOrNil(7),
                                        createdAt: r.double(8).map { Date(timeIntervalSince1970: $0) },
                                        createdSource: CreatedSource(rawValue: r.string(9) ?? "") ?? .file,
                                        author: r.string(10), promptRaw: r.string(11), xmp: r.string(12),
                                        source: r.string(13).flatMap(ItemSource.init(rawValue:)),
                                        camera: r.string(14).flatMap { try? dec.decode(CameraInfo.self, from: Data($0.utf8)) },
                                        generator: r.string(15).flatMap { try? dec.decode(GeneratorInfo.self, from: Data($0.utf8)) })
                }
                d = ItemDetail(id: r.int(0), relPath: r.string(1)!, kind: ItemKind(rawValue: r.string(2)!) ?? .other,
                               size: r.int(3), mtime: r.double(4) ?? 0, metadata: meta, metadataFailed: state == 2)
            }
            return d
        }
    }

    public struct Counts: Sendable, Equatable {
        public var total = 0, metadataDone = 0, metadataFailed = 0, thumbnailsDone = 0, thumbnailsFailed = 0, withPrompt = 0
        public init() {}
    }

    public func counts() throws -> Counts {
        try sync {
            var c = Counts()
            try db.query("""
            SELECT count(*), sum(meta_state = 1), sum(meta_state = 2), sum(thumb_state = 1), sum(thumb_state = 2),
                   sum(prompt_raw IS NOT NULL AND prompt_raw != '') FROM items
            """) { r in
                c.total = Int(r.int(0)); c.metadataDone = Int(r.int(1)); c.metadataFailed = Int(r.int(2))
                c.thumbnailsDone = Int(r.int(3)); c.thumbnailsFailed = Int(r.int(4)); c.withPrompt = Int(r.int(5))
            }
            return c
        }
    }

    // MARK: - Saved searches

    public func savedSearches() throws -> [SavedSearch] {
        let dec = JSONDecoder()
        return try sync {
            var out: [SavedSearch] = []
            try db.query("SELECT id, name, color, folder, position, query FROM saved_searches ORDER BY position, id") { r in
                let q = (try? dec.decode(SearchQuery.self, from: Data((r.string(5) ?? "{}").utf8))) ?? SearchQuery()
                out.append(SavedSearch(id: r.int(0), name: r.string(1) ?? "", color: r.string(2) ?? "gray",
                                       folder: r.string(3), position: Int(r.int(4)), query: q))
            }
            return out
        }
    }

    @discardableResult
    public func addSavedSearch(name: String, color: String, folder: String?, query: SearchQuery) throws -> SavedSearch {
        let json = String(data: try JSONEncoder().encode(query), encoding: .utf8)!
        return try sync {
            var pos = 0
            try db.query("SELECT coalesce(max(position), -1) + 1 FROM saved_searches") { pos = Int($0.int(0)) }
            try db.run("INSERT INTO saved_searches(name, color, folder, position, query) VALUES(?, ?, ?, ?, ?)",
                       [name, color, folder, pos, json])
            return SavedSearch(id: db.lastInsertRowID, name: name, color: color, folder: folder, position: pos, query: query)
        }
    }

    public func updateSavedSearch(_ s: SavedSearch) throws {
        let json = String(data: try JSONEncoder().encode(s.query), encoding: .utf8)!
        try sync {
            try db.run("UPDATE saved_searches SET name = ?, color = ?, folder = ?, position = ?, query = ? WHERE id = ?",
                       [s.name, s.color, s.folder, s.position, json, s.id])
        }
    }

    public func deleteSavedSearch(id: Int64) throws {
        try sync { try db.run("DELETE FROM saved_searches WHERE id = ?", [id]) }
    }

    /// Rewrites positions in the given order.
    public func reorderSavedSearches(_ ids: [Int64]) throws {
        try sync {
            try db.transaction {
                for (i, id) in ids.enumerated() { try db.run("UPDATE saved_searches SET position = ? WHERE id = ?", [i, id]) }
            }
        }
    }
}
