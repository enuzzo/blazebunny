import Foundation

// What a view shows: the items, their counts, facets, summary and one item's detail. All of it reads
// through the read-only connections, so none of it waits for the scanner.

extension LibraryIndex {
    static let dateExpr = "coalesce(items.created_at, items.file_mtime)"
    /// Matches the expression stored in `items_browse`, so it is answered from the index.
    static let hasPromptExpr = "(prompt_raw IS NOT NULL AND prompt_raw != '')"
    /// A search with at most this many matches starts from the match list; a broader one walks the
    /// browse index in date order and checks each row against the matches (no sort, no wide rows).
    static let selectiveMatchLimit = 5000

    // MARK: - Query building

    /// WHERE clause for `filter` and `search`, leaving out `excluding` (for facet counts).
    static func whereClause(_ f: FilterState, search: String?, excluding: Facet? = nil, scope: (String, [Any?])? = nil) -> (String, [Any?]) {
        var parts: [String] = []
        var args: [Any?] = []
        if let scope { parts.append(scope.0); args.append(contentsOf: scope.1) }
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

    /// Turns free text into an FTS5 query: every word must match as a prefix.
    static func ftsQuery(_ search: String?) -> String? {
        guard let s = search?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let words = s.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " ")
    }

    /// SQL that limits a query to one folder and everything below it, as an integer match on `dir_id`.
    /// A leaf folder is a plain equality; a folder with subfolders walks the (small) `dirs` table.
    func scopeClause(_ db: SQLiteDB, _ folder: Int64?) throws -> (String, [Any?])? {
        guard let folder else { return nil }
        var hasChildren = false
        try db.query("SELECT 1 FROM dirs WHERE parent_id = ? LIMIT 1", [folder]) { _ in hasChildren = true }
        if !hasChildren { return ("items.dir_id = ?", [folder]) }
        return ("""
        items.dir_id IN (WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT d.id FROM dirs d JOIN sub ON d.parent_id = sub.id) SELECT id FROM sub)
        """, [folder])
    }

    /// `items` with the index a view query should walk. SQLite has no statistics on a fresh library
    /// and guesses badly (it starts from a big source or full-text match, fetches each wide row and
    /// sorts), so the choice is made here:
    /// - inside a folder: the folder index (1 to 15 ms on a subtree of 8k in 100k, against 40 to 90);
    /// - whole library: the browse index, which is in date order and holds every column these queries
    ///   read (a source filter on 100k: 15 ms against 90; a search for a very common word: 37 against 95);
    /// - a search with few matches, and a view sorted by name: SQLite's own choice (the match list, the name index).
    func itemsTable(_ db: SQLiteDB, folder: Int64?, search: String?, byDate: Bool = true) throws -> String {
        if folder != nil { return "items INDEXED BY items_dir_sort" }
        guard byDate else { return "items" }
        if let q = Self.ftsQuery(search) {
            var matches = 0
            try db.query("SELECT count(*) FROM (SELECT rowid FROM items_fts WHERE items_fts MATCH ? LIMIT ?)",
                         [q, Self.selectiveMatchLimit + 1]) { matches = Int($0.int(0)) }
            if matches <= Self.selectiveMatchLimit { return "items" }
        }
        return "items INDEXED BY items_browse"
    }

    // MARK: - Items

    /// `folder` limits the result to that folder and everything below it; `limit` returns only the first rows.
    public func items(filter: FilterState = FilterState(), search: String? = nil, sort: ItemSort = .newestFirst,
                      folder: Int64? = nil, limit: Int? = nil) throws -> [BrowseItem] {
        try lists.sync { db in
            let order: String
            switch sort {
            case .newestFirst: order = "\(Self.dateExpr) DESC, items.id DESC"
            case .oldestFirst: order = "\(Self.dateExpr) ASC, items.id ASC"
            case .name: order = "items.file_name COLLATE NOCASE ASC"
            }
            let (w, args) = Self.whereClause(filter, search: search, scope: try scopeClause(db, folder))
            let table = try itemsTable(db, folder: folder, search: search, byDate: sort.isByDate)
            var out: [BrowseItem] = []
            out.reserveCapacity(limit ?? 20_000)
            let tail = limit.map { " LIMIT \($0)" } ?? ""
            try db.query("""
            SELECT id, rel_path, \(Self.dateExpr), width, height, thumb_pack, thumb_offset, thumb_length, source, aspect FROM \(table)
            WHERE \(w) ORDER BY \(order)\(tail)
            """, args) { r in
                let thumb = r.isNull(5) ? nil : ThumbnailLocation(pack: Int(r.int(5)), offset: r.int(6), length: Int(r.int(7)))
                out.append(BrowseItem(id: r.int(0), relPath: r.string(1)!, sortDate: r.double(2) ?? 0,
                                      width: r.intOrNil(3), height: r.intOrNil(4), thumbnail: thumb,
                                      source: r.string(8).flatMap(ItemSource.init(rawValue:)), aspect: r.string(9)))
            }
            return out
        }
    }

    /// Kept for callers that only search and sort.
    public func gridItems(search: String? = nil, sort: ItemSort = .newestFirst) throws -> [BrowseItem] {
        try items(search: search, sort: sort)
    }

    // MARK: - Facets

    /// Values of `facet` with how many items each would show, applying every
    /// other active filter. Shape returns orientations as "o:portrait" and ratios as "r:16:9".
    public func facetCounts(_ facet: Facet, filter: FilterState, search: String?, folder: Int64? = nil) throws -> [FacetValue] {
        try lists.sync { db in
            let (w, args) = Self.whereClause(filter, search: search, excluding: facet, scope: try scopeClause(db, folder))
            let table = try itemsTable(db, folder: folder, search: search)
            var out: [FacetValue] = []
            func group(_ column: String, prefix: String = "", limit: Int = 200) throws {
                try db.query("""
                SELECT \(column), count(*) AS n FROM \(table) WHERE \(w) AND \(column) IS NOT NULL
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
                // The join decides the order here, so the browse index is not forced.
                let joined = folder == nil ? "items" : table
                try db.query("""
                SELECT ip.facet, count(DISTINCT ip.item_id) AS n FROM item_params ip JOIN \(joined) ON items.id = ip.item_id
                WHERE \(w) GROUP BY ip.facet ORDER BY n DESC LIMIT 60
                """, args) { r in out.append(FacetValue(value: r.string(0) ?? "", count: Int(r.int(1)))) }
            case .date:
                break
            }
            return out
        }
    }

    /// Item count per month ("2025-03"), oldest first, ignoring the date filter. Reads only the dates
    /// (in order, from an index) and groups them here; the last answer is kept until the index changes.
    public func monthHistogram(filter: FilterState, search: String?, folder: Int64? = nil) throws -> [MonthCount] {
        try lists.sync { db in
            let (w, args) = Self.whereClause(filter, search: search, excluding: .date, scope: try scopeClause(db, folder))
            let table = try itemsTable(db, folder: folder, search: search)
            var version: Int64 = 0
            try db.query("PRAGMA data_version") { version = $0.int(0) }
            let key = table + "|" + w + "|" + args.map { $0.map { "\($0)" } ?? "nil" }.joined(separator: "\u{1}")
            if let c = histogramCache, c.key == key, c.version == version { return c.months }
            var dates: [Double] = []
            try db.query("SELECT \(Self.dateExpr) FROM \(table) WHERE \(w) ORDER BY 1", args) { dates.append($0.double(0) ?? 0) }
            let months = MonthSections.split(dates).map { MonthCount(month: MonthSections.key($0.monthStart), count: $0.range.count) }
            histogramCache = (key, version, months)
            return months
        }
    }

    // MARK: - Summary and counts

    /// Totals for the items a filter and search would show. One pass over the rows, grouped by kind
    /// and source, added up here (three separate queries each repeated the filter and the search).
    public func summary(filter: FilterState = FilterState(), search: String? = nil, folder: Int64? = nil) throws -> LibrarySummary {
        try lists.sync { db in
            let (w, args) = Self.whereClause(filter, search: search, scope: try scopeClause(db, folder))
            let table = try itemsTable(db, folder: folder, search: search)
            var s = LibrarySummary()
            var kinds: [String: Int] = [:]
            var sources: [String: Int] = [:]
            try db.query("""
            SELECT items.kind, items.source, count(*), coalesce(sum(file_size), 0), min(\(Self.dateExpr)), max(\(Self.dateExpr)),
                   coalesce(sum(\(Self.hasPromptExpr)), 0)
            FROM \(table) WHERE \(w) GROUP BY items.kind, items.source
            """, args) { r in
                let n = Int(r.int(2))
                s.total += n
                s.totalBytes += r.int(3)
                if let d = r.double(4).map({ Date(timeIntervalSince1970: $0) }) { s.oldest = min(s.oldest ?? d, d) }
                if let d = r.double(5).map({ Date(timeIntervalSince1970: $0) }) { s.newest = max(s.newest ?? d, d) }
                s.withPrompt += Int(r.int(6))
                if let k = r.string(0) { kinds[k, default: 0] += n }
                if let src = r.string(1) { sources[src, default: 0] += n }
            }
            // Most common first; equal counts by name, so the order never flickers between reloads.
            func ranked(_ d: [String: Int]) -> [FacetValue] {
                d.map { FacetValue(value: $0.key, count: $0.value) }.sorted { ($0.count, $1.value) > ($1.count, $0.value) }
            }
            s.kinds = ranked(kinds)
            s.sources = ranked(sources)
            return s
        }
    }

    public struct Counts: Sendable, Equatable {
        public var total = 0, metadataDone = 0, metadataFailed = 0, thumbnailsDone = 0, thumbnailsFailed = 0, withPrompt = 0
        public init() {}
    }

    /// Library-wide progress numbers. Three small index scans instead of one pass over every wide row.
    public func counts() throws -> Counts {
        try lists.sync { db in
            var c = Counts()
            try db.query("SELECT meta_state, count(*) FROM items GROUP BY meta_state") { r in
                let n = Int(r.int(1))
                c.total += n
                if r.int(0) == 1 { c.metadataDone = n } else if r.int(0) == 2 { c.metadataFailed = n }
            }
            try db.query("SELECT thumb_state, count(*) FROM items GROUP BY thumb_state") { r in
                if r.int(0) == 1 { c.thumbnailsDone = Int(r.int(1)) } else if r.int(0) == 2 { c.thumbnailsFailed = Int(r.int(1)) }
            }
            try db.query("SELECT coalesce(sum(\(Self.hasPromptExpr)), 0) FROM items INDEXED BY items_browse") { c.withPrompt = Int($0.int(0)) }
            return c
        }
    }

    // MARK: - One item

    public func detail(id: Int64) throws -> ItemDetail? {
        let dec = JSONDecoder()
        return try lookups.sync { db in
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
}
