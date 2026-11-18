import AppKit
import BlazebunnyCore

// Saved searches: live filters kept in the sidebar.
extension LibraryModel {

    var savedFolders: [String] {
        Array(Set(savedSearches.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func saveCurrentSearch(name: String, color: TagColor, folder: String?) {
        guard let lib = library else { return }
        let folder = folder?.trimmingCharacters(in: .whitespaces).isEmpty == false ? folder : nil
        if let s = try? lib.index.addSavedSearch(name: name, color: color.rawValue, folder: folder, query: query) {
            savedSearches.append(s)
            sidebarSelection = .saved(s.id)
        }
    }

    /// Overwrites a saved search with the current query.
    func updateSavedSearch(_ id: Int64) {
        guard let lib = library, var s = savedSearches.first(where: { $0.id == id }) else { return }
        s.query = query
        try? lib.index.updateSavedSearch(s)
        savedSearches = (try? lib.index.savedSearches()) ?? savedSearches
    }

    func renameSavedSearch(_ id: Int64, name: String, color: TagColor, folder: String?) {
        guard let lib = library, var s = savedSearches.first(where: { $0.id == id }) else { return }
        s.name = name
        s.color = color.rawValue
        s.folder = folder?.trimmingCharacters(in: .whitespaces).isEmpty == false ? folder : nil
        try? lib.index.updateSavedSearch(s)
        savedSearches = (try? lib.index.savedSearches()) ?? savedSearches
    }

    func deleteSavedSearch(_ id: Int64) {
        guard let lib = library else { return }
        try? lib.index.deleteSavedSearch(id: id)
        savedSearches.removeAll { $0.id == id }
        if sidebarSelection == .saved(id), let p = currentPath { sidebarSelection = .library(p) }
    }

    func moveSavedSearches(in folder: String?, from: IndexSet, to: Int) {
        guard let lib = library else { return }
        var group = savedSearches.filter { $0.folder == folder }
        group.move(fromOffsets: from, toOffset: to)
        let others = savedSearches.filter { $0.folder != folder }
        let ordered = others + group
        try? lib.index.reorderSavedSearches(ordered.map(\.id))
        savedSearches = (try? lib.index.savedSearches()) ?? savedSearches
    }

    /// The saved search shown, if the current query still matches it.
    var activeSavedSearch: SavedSearch? {
        guard case .saved(let id) = sidebarSelection else { return nil }
        return savedSearches.first(where: { $0.id == id })
    }

    var savedSearchIsModified: Bool {
        guard let s = activeSavedSearch else { return false }
        return s.query != query
    }
}
