import Foundation

extension LibraryIndex {
    // MARK: - Saved searches

    public func savedSearches() throws -> [SavedSearch] {
        let dec = JSONDecoder()
        return try lookups.sync { db in
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
        return try writer.sync { db in
            var pos = 0
            try db.query("SELECT coalesce(max(position), -1) + 1 FROM saved_searches") { pos = Int($0.int(0)) }
            try db.run("INSERT INTO saved_searches(name, color, folder, position, query) VALUES(?, ?, ?, ?, ?)",
                       [name, color, folder, pos, json])
            return SavedSearch(id: db.lastInsertRowID, name: name, color: color, folder: folder, position: pos, query: query)
        }
    }

    public func updateSavedSearch(_ s: SavedSearch) throws {
        let json = String(data: try JSONEncoder().encode(s.query), encoding: .utf8)!
        try writer.sync { db in
            try db.run("UPDATE saved_searches SET name = ?, color = ?, folder = ?, position = ?, query = ? WHERE id = ?",
                       [s.name, s.color, s.folder, s.position, json, s.id])
        }
    }

    public func deleteSavedSearch(id: Int64) throws {
        try writer.sync { db in try db.run("DELETE FROM saved_searches WHERE id = ?", [id]) }
    }

    /// Rewrites positions in the given order.
    public func reorderSavedSearches(_ ids: [Int64]) throws {
        try writer.sync { db in
            try db.transaction {
                for (i, id) in ids.enumerated() { try db.run("UPDATE saved_searches SET position = ? WHERE id = ?", [i, id]) }
            }
        }
    }
}
