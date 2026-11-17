import AppKit
import BlazebunnyCore
import Observation

/// A folder the user has opened, remembered across launches.
struct SavedLibrary: Codable, Hashable, Identifiable {
    var path: String
    var bookmark: Data?
    /// A name the user chose. Display only: the folder itself is never renamed.
    var displayName: String?
    /// Set for ghost (temporary) libraries: where their index and thumbnails live.
    /// Never written to disk: a ghost is not remembered across launches.
    var ghostBase: URL?
    var isGhost: Bool { ghostBase != nil }
    private enum CodingKeys: String, CodingKey { case path, bookmark, displayName }
    var id: String { path }
    var folderName: String { (path as NSString).lastPathComponent }
    var name: String { displayName ?? folderName }
}

/// Built-in views every library offers in the sidebar.
enum BuiltInView: String, CaseIterable, Identifiable {
    case all, recent, generated, photos, screenshots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Images"
        case .recent: return "Recently Added"
        case .generated: return "Generated"
        case .photos: return "Photos"
        case .screenshots: return "Screenshots"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .recent: return "clock"
        case .generated: return "sparkles"
        case .photos: return "camera"
        case .screenshots: return "macwindow"
        }
    }
    var filter: FilterState {
        var f = FilterState()
        switch self {
        case .all: break
        case .recent: f.dateFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .generated: f.sources = [.midjourney, .stableDiffusion]
        case .photos: f.sources = [.camera]
        case .screenshots: f.sources = [.screenshot]
        }
        return f
    }
}

/// What is selected in the sidebar.
enum SidebarItem: Hashable {
    case library(String)
    case view(BuiltInView)
    case saved(Int64)
    /// A folder of the open library, by its path relative to the library root.
    case folder(String)
}

/// The library's folder tree prepared for the sidebar: children sorted by name once, off the main thread.
struct FolderTree: Equatable {
    var nodes: [String: DirNode] = [:]
    /// Children by parent path ("" is the library root), shown folders only, alphabetical.
    var children: [String: [DirNode]] = [:]

    init() {}

    /// Folders that hold no image anywhere below them are left out: a folder of documents or an
    /// empty one would only add noise to an image browser.
    init(_ list: [DirNode]) {
        var byID: [Int64: DirNode] = [:]
        for n in list { byID[n.id] = n }
        for n in list {
            nodes[n.path] = n
            guard n.subtreeCount > 0 else { continue }
            let parentPath = n.parentID.flatMap { byID[$0]?.path } ?? ""
            children[parentPath, default: []].append(n)
        }
        for key in children.keys {
            children[key]!.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    var isEmpty: Bool { children.isEmpty }
}

/// One visible row of the Folders section.
struct FolderRow: Identifiable, Equatable {
    var node: DirNode
    var id: String { node.path }
    var hasChildren: Bool
    var isExpanded: Bool
}

/// Named colours for saved searches.
enum TagColor: String, CaseIterable {
    case orange, red, pink, purple, blue, teal, green, yellow, gray
    var color: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .teal: return .systemTeal
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .gray: return .systemGray
        }
    }
}

@MainActor @Observable
final class LibraryModel {
    var saved: [SavedLibrary] = []
    /// Ghost libraries open right now. In memory only; see `GhostStorage`.
    var ghosts: [SavedLibrary] = []
    var currentPath: String?
    private(set) var library: Library?
    private(set) var items: [BrowseItem] = []
    var query = SearchQuery() { didSet { if query != oldValue { queryChanged(textOnly: query.filter == oldValue.filter && query.sort == oldValue.sort && query.folder == oldValue.folder) } } }
    var sidebarSelection: SidebarItem?
    var savedSearches: [SavedSearch] = []
    var cellSize: Double = 160
    var fillCells = true
    var selection: [Int64] = [] { didSet { loadDetail() } }
    private(set) var detail: ItemDetail?
    private(set) var progress: ScanProgress?
    /// Set when a scan stopped with an error, so the footer says so instead of showing a stale status.
    private(set) var scanFailure: String?
    private(set) var counts = LibraryIndex.Counts()
    /// What the current view holds (the whole library when no filter is on).
    private(set) var summary = LibrarySummary()
    /// Which copy button was just used, shown as "Copied" for a moment.
    private(set) var copiedKind: CopyKind?
    /// Incremented by Edit > Find, so the toolbar search field takes focus.
    var searchFocusRequest = 0
    private(set) var libraryCreatedAt: Date?
    /// Item count per source for the current query, ignoring the source filter.
    private(set) var sourceCounts: [ItemSource: Int] = [:]
    private(set) var isOnline = false
    var errorMessage: String?
    /// Facet values for the open popover.
    private(set) var facetValues: [Facet: [FacetValue]] = [:]
    private(set) var histogram: [MonthCount] = []
    var openFacet: Facet?
    /// The library's folders, for the sidebar.
    private(set) var folderTree = FolderTree()
    /// Paths of the folders shown open in the sidebar. Remembered per library, except for ghosts.
    private(set) var expandedFolders: Set<String> = []
    /// True while only the first screen of a new result is shown and the rest is still loading.
    private(set) var isPartialPage = false

    @ObservationIgnored let thumbnails = ThumbnailLoader()
    @ObservationIgnored private var scanner: FolderScanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = true
    @ObservationIgnored private var lastProgressReload = Date.distantPast
    @ObservationIgnored private var observers: [Any] = []

    private static let savedKey = "savedLibraries"
    private static let currentKey = "currentLibrary"
    private static let expandedKey = "expandedFolders"

    init() {
        // A crashed session may have left ghost data behind: nothing is open yet, so remove it all.
        GhostStorage.purgeAll()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAllGhosts() }
        })
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let list = try? JSONDecoder().decode([SavedLibrary].self, from: data) {
            saved = list
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesChanged() }
            })
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            open(URL(fileURLWithPath: args[i + 1]), ghost: args.contains("--ghost"))
        } else if let path = UserDefaults.standard.string(forKey: Self.currentKey), saved.contains(where: { $0.path == path }) {
            select(path: path)
        }
    }

    var allLibraries: [SavedLibrary] { saved + ghosts }
    var currentLibrary: SavedLibrary? { allLibraries.first { $0.path == currentPath } }
    var currentLibraryName: String { currentLibrary?.name ?? "Blazebunny" }
    var currentIsGhost: Bool { currentLibrary?.isGhost ?? false }

    /// Title of what the grid shows.
    var viewTitle: String {
        switch sidebarSelection {
        case .view(let v): return v.title
        case .saved(let id): return savedSearches.first(where: { $0.id == id })?.name ?? currentLibraryName
        case .folder(let path): return (path as NSString).lastPathComponent
        default: return currentLibraryName
        }
    }

    /// One crumb of the context line above the title.
    struct Crumb: Identifiable {
        let id: String
        let title: String
        /// Where a click goes; nil for plain text.
        let target: SidebarItem?
    }

    /// What the grid shows and where it is, for the 11 pt line above the title.
    /// For a folder: "Folder · files › Renders" (the library, then the folders above this one).
    var contextKind: String {
        if currentIsGhost { return "Ghost · temporary" }
        switch sidebarSelection {
        case .folder: return "Folder"
        case .saved: return "Saved search"
        case .view: return "View"
        default: return "Library"
        }
    }

    var contextCrumbs: [Crumb] {
        guard let path = currentPath else { return [] }
        let libCrumb = Crumb(id: "lib", title: currentLibraryName, target: .library(path))
        switch sidebarSelection {
        case .folder(let p):
            var crumbs = [libCrumb]
            var acc = ""
            for part in p.split(separator: "/").dropLast() {
                acc = acc.isEmpty ? String(part) : acc + "/" + part
                crumbs.append(Crumb(id: acc, title: String(part), target: .folder(acc)))
            }
            return crumbs
        case .saved:
            var crumbs = [Crumb(id: "in", title: "live · in " + currentLibraryName, target: .library(path))]
            if let f = query.folder { crumbs.append(Crumb(id: "f", title: f.replacingOccurrences(of: "/", with: " › "), target: .folder(f))) }
            return crumbs
        case .view:
            return [Crumb(id: "in", title: "in " + currentLibraryName, target: .library(path))]
        default:
            return [Crumb(id: "all", title: "everything, subfolders included", target: nil)]
        }
    }

    // MARK: - Libraries

    /// Asks for a folder. `ghost` sets the checkbox's starting state; the user can flip it.
    func openFolderPanel(ghost: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of images. Blazebunny only reads it."
        let box = NSButton(checkboxWithTitle: "Open as ghost (no index or thumbnails kept)", target: nil, action: nil)
        box.state = ghost ? .on : .off
        box.toolTip = GhostText.explanation + " Use it for private or accounting folders."
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        box.frame = NSRect(x: 12, y: 8, width: 396, height: 20)
        accessory.addSubview(box)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        let response = panel.runModal()
        let asGhost = box.state == .on
        if asGhost {
            // The panel remembers the last folder in the app's own defaults: a ghost must
            // not leave the folder's path behind.
            for key in ["NSNavLastRootDirectory", "NSNavLastCurrentDirectory"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        guard response == .OK, let url = panel.url else { return }
        open(url, ghost: asGhost)
    }

    func open(_ url: URL, ghost: Bool = false) {
        let path = url.standardizedFileURL.path
        if let existing = allLibraries.first(where: { $0.path == path }) {
            select(path: path)  // already open, as a library or as a ghost
            if existing.isGhost != ghost {
                errorMessage = existing.isGhost
                    ? "This folder is already open as a ghost, so nothing about it is saved. Close the ghost to add it as a normal library."
                    : "This folder is already a saved library, so it was opened as one. Forget the library first to open it as a ghost."
            }
            return
        }
        if ghost {
            guard let base = try? GhostStorage.makeBase() else {
                errorMessage = "Could not create temporary storage for a ghost folder."
                return
            }
            ghosts.append(SavedLibrary(path: path, bookmark: nil, ghostBase: base))
        } else {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            saved.append(SavedLibrary(path: path, bookmark: bookmark))
            persist()
        }
        select(path: path)
    }

    /// Closes a ghost and deletes everything it stored.
    func closeGhost(_ lib: SavedLibrary) {
        guard let i = ghosts.firstIndex(where: { $0.path == lib.path }) else { return }
        if currentPath == lib.path { dropCurrentLibrary() }
        if let base = ghosts[i].ghostBase { GhostStorage.purge(base) }
        ghosts.remove(at: i)
    }

    func closeAllGhosts() {
        for g in ghosts { closeGhost(g) }
        GhostStorage.purgeAll()
    }

    /// Stops the scan and releases the open library, so its files can be deleted.
    private func dropCurrentLibrary() {
        stopScan()
        thumbnails.library = nil
        library = nil
        currentPath = nil
        items = []
        detail = nil
        selection = []
        savedSearches = []
        sidebarSelection = nil
        folderTree = FolderTree()
        expandedFolders = []
    }

    /// Gives a library a display name; an empty name goes back to the folder name.
    func rename(_ lib: SavedLibrary, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed.isEmpty || trimmed == lib.folderName) ? nil : trimmed
        if let i = saved.firstIndex(where: { $0.path == lib.path }) {
            saved[i].displayName = name
            persist()
        } else if let i = ghosts.firstIndex(where: { $0.path == lib.path }) {
            ghosts[i].displayName = name
        }
    }

    /// Reorders the saved libraries (drag in the sidebar) and remembers the order.
    func moveLibraries(from: IndexSet, to: Int) {
        saved.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func remove(_ lib: SavedLibrary) {
        saved.removeAll { $0.path == lib.path }
        persist()
        var all = UserDefaults.standard.dictionary(forKey: Self.expandedKey) as? [String: [String]] ?? [:]
        if all.removeValue(forKey: lib.path) != nil { UserDefaults.standard.set(all, forKey: Self.expandedKey) }
        if currentPath == lib.path { dropCurrentLibrary() }
    }

    func select(path: String) {
        if path == currentPath, library != nil {
            apply(SearchQuery(sort: query.sort), selecting: .library(path))
            return
        }
        stopScan()
        currentPath = path
        sidebarSelection = .library(path)
        // A ghost is never remembered, not even as "the library to reopen".
        if currentLibrary?.isGhost != true { UserDefaults.standard.set(path, forKey: Self.currentKey) }
        selection = []
        detail = nil
        items = []
        progress = nil
        errorMessage = nil
        query = SearchQuery()
        folderTree = FolderTree()
        expandedFolders = currentLibrary?.isGhost == true ? [] : Self.storedExpansion(for: path)
        do {
            let lib: Library
            if let base = currentLibrary?.ghostBase {
                lib = try Library(root: URL(fileURLWithPath: path), base: base)
            } else {
                lib = try Library(root: resolvedURL(for: path))
            }
            library = lib
            thumbnails.library = lib
            savedSearches = (try? lib.index.savedSearches()) ?? []
        } catch {
            errorMessage = "Could not open the library: \(error.localizedDescription)"
            library = nil
            return
        }
        scheduleReload(delay: 0, refresh: true)
        refreshOnline()
        if isOnline { startScan() }
    }

    func selectSidebar(_ item: SidebarItem?) {
        guard let item else { return }
        switch item {
        case .library(let path):
            select(path: path)
        case .view(let v):
            apply(SearchQuery(filter: v.filter, sort: query.sort), selecting: item)
        case .saved(let id):
            if let s = savedSearches.first(where: { $0.id == id }) { apply(s.query, selecting: item) } else { sidebarSelection = item }
        case .folder(let path):
            // A folder shows everything inside it, subfolders included; filters start clean.
            expandAncestors(of: path)
            apply(SearchQuery(sort: query.sort, folder: path), selecting: item)
        }
    }

    private func apply(_ q: SearchQuery, selecting item: SidebarItem) {
        sidebarSelection = item
        query = q
        sidebarSelection = item
        // A change of scope is a change of view: a stale selection would point into the old one.
        if !selection.isEmpty { selection = [] }
    }

    // MARK: - Folders

    /// Rows of the Folders section: the tree flattened, open folders only.
    var folderRows: [FolderRow] {
        var out: [FolderRow] = []
        func walk(_ parent: String) {
            for n in folderTree.children[parent] ?? [] {
                let kids = folderTree.children[n.path]?.isEmpty == false
                let open = kids && expandedFolders.contains(n.path)
                out.append(FolderRow(node: n, hasChildren: kids, isExpanded: open))
                if open { walk(n.path) }
            }
        }
        walk("")
        return out
    }

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
        storeExpansion()
    }

    private func expandAncestors(of path: String) {
        var p = (path as NSString).deletingLastPathComponent
        var changed = false
        while !p.isEmpty { changed = expandedFolders.insert(p).inserted || changed; p = (p as NSString).deletingLastPathComponent }
        if changed { storeExpansion() }
    }

    private func storeExpansion() {
        // A ghost leaves no trace, not even which of its folders were open.
        guard let path = currentPath, currentLibrary?.isGhost != true else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.expandedKey) as? [String: [String]] ?? [:]
        all[path] = expandedFolders.sorted()
        UserDefaults.standard.set(all, forKey: Self.expandedKey)
    }

    private static func storedExpansion(for path: String) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: expandedKey) as? [String: [String]] ?? [:]
        return Set(all[path] ?? [])
    }

    private func resolvedURL(for path: String) -> URL {
        if let saved = saved.first(where: { $0.path == path }), let bm = saved.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(fileURLWithPath: path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    private func refreshOnline() {
        guard let root = library?.root else { isOnline = false; return }
        var isDir: ObjCBool = false
        isOnline = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func volumesChanged() {
        let was = isOnline
        refreshOnline()
        if isOnline && !was { startScan() }
        if !isOnline && was { stopScan() }
    }

    // MARK: - Saved searches

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

    // MARK: - Filters

    /// Midjourney filters are shown when the view is about Midjourney images.
    var showsMidjourneyGroup: Bool {
        let f = query.filter
        if f.sources.contains(.midjourney) || !f.versions.isEmpty || !f.params.isEmpty { return true }
        if f.sources.isEmpty, let mj = sourceCounts[.midjourney], mj > 0 { return true }
        return false
    }

    var showsCameraGroup: Bool {
        let f = query.filter
        if f.sources.contains(.camera) || !f.cameras.isEmpty { return true }
        if f.sources.isEmpty, let c = sourceCounts[.camera], c > 0 { return true }
        return false
    }

    func toggle(_ facet: Facet, _ value: String) {
        var f = query.filter
        func flip<T: Hashable>(_ set: inout Set<T>, _ v: T) { if set.contains(v) { set.remove(v) } else { set.insert(v) } }
        switch facet {
        case .type: flip(&f.types, value)
        case .shape:
            if value.hasPrefix("o:"), let o = Orientation(rawValue: String(value.dropFirst(2))) { flip(&f.orientations, o) }
            if value.hasPrefix("r:") { flip(&f.ratios, String(value.dropFirst(2))) }
        case .source: if let s = ItemSource(rawValue: value) { flip(&f.sources, s) }
        case .version: flip(&f.versions, value)
        case .param: flip(&f.params, value)
        case .camera: flip(&f.cameras, value)
        case .date: break
        }
        query.filter = f
    }

    func isOn(_ facet: Facet, _ value: String) -> Bool {
        let f = query.filter
        switch facet {
        case .type: return f.types.contains(value)
        case .shape:
            if value.hasPrefix("o:") { return Orientation(rawValue: String(value.dropFirst(2))).map { f.orientations.contains($0) } ?? false }
            return f.ratios.contains(String(value.dropFirst(2)))
        case .source: return ItemSource(rawValue: value).map { f.sources.contains($0) } ?? false
        case .version: return f.versions.contains(value)
        case .param: return f.params.contains(value)
        case .camera: return f.cameras.contains(value)
        case .date: return false
        }
    }

    /// Adds one value to a filter (from a click in the inspector).
    func addFilter(_ facet: Facet, _ value: String) {
        if !isOn(facet, value) { toggle(facet, value) }
        if facet == .version || facet == .param { query.filter.sources.insert(.midjourney) }
        if facet == .camera { query.filter.sources.insert(.camera) }
    }

    func clear(_ facet: Facet) { query.filter.clear(facet) }
    func clearAll() { query.filter = FilterState(); query.text = "" }

    func setDateRange(from: Date?, to: Date?) {
        query.filter.dateFrom = from
        query.filter.dateTo = to
    }

    /// Loads the values of a facet for its popover.
    func loadFacet(_ facet: Facet) {
        guard let lib = library else { return }
        let q = query
        Task.detached(priority: .userInitiated) {
            let folder = q.folder.flatMap { try? lib.index.dirID(forPath: $0) } ?? nil
            let values = facet == .date ? [] : ((try? lib.index.facetCounts(facet, filter: q.filter, search: q.text, folder: folder)) ?? [])
            let hist = facet == .date ? ((try? lib.index.monthHistogram(filter: q.filter, search: q.text, folder: folder)) ?? []) : []
            await MainActor.run { [weak self] in
                guard let self, self.library === lib else { return }
                if facet == .date { self.histogram = hist } else { self.facetValues[facet] = values }
            }
        }
    }

    private func queryChanged(textOnly: Bool) {
        scheduleReload(delay: textOnly ? 0.12 : 0, phased: !textOnly)
        if let f = openFacet { loadFacet(f) }
    }

    // MARK: - Scanning

    func rescan() {
        refreshOnline()
        guard isOnline else { return }
        startScan()
    }

    func startScan() {
        stopScan()
        guard let lib = library else { return }
        let scanner = FolderScanner(root: lib.root, index: lib.index, thumbnails: lib.thumbnails, ioConcurrency: 2)
        self.scanner = scanner
        scanFailure = nil
        thumbnails.scanner = scanner
        scanTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await scanner.run { p in
                    // A cancelled scan may still report once more: ignore it after a switch.
                    Task { @MainActor in
                        guard let self, self.scanner === scanner else { return }
                        self.didProgress(p)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.scanner === scanner else { return }
                    self.progress = nil
                    self.scanFailure = error.localizedDescription
                }
            }
        }
    }

    func stopScan() {
        scanner?.cancel()
        scanTask?.cancel()
        scanner = nil
        thumbnails.scanner = nil
        scanTask = nil
    }

    private func didProgress(_ p: ScanProgress) {
        progress = p
        let interval: TimeInterval = items.isEmpty ? 0.3 : 3
        if p.phase == .done || Date().timeIntervalSince(lastProgressReload) > interval {
            lastProgressReload = Date()
            scheduleReload(delay: 0, refresh: true)
        }
        // Thumbnails are made alongside metadata, so retry as soon as any exist.
        if p.thumbnailsDone > 0 || p.phase == .done { thumbnails.retryMissing() }
    }

    // MARK: - Grid data

    /// Reloads what the grid shows. `phased` first publishes the first screen of rows (a few ms even on
    /// 100k items) and then the full result. `refresh` also re-reads the library-wide numbers (counts,
    /// folder tree): they do not change when only a filter does, so a filter change skips them.
    private func scheduleReload(delay: TimeInterval, phased: Bool = false, refresh: Bool = false) {
        reloadTask?.cancel()
        pendingRefresh = pendingRefresh || refresh
        guard let lib = library else { return }
        let q = query
        let doRefresh = pendingRefresh
        reloadTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { return }
            if phased {
                let page = await Task.detached(priority: .userInitiated) { () -> [BrowseItem]? in
                    let folder = q.folder.flatMap { try? lib.index.dirID(forPath: $0) } ?? nil
                    return try? lib.index.items(filter: q.filter, search: q.text, sort: q.sort, folder: folder, limit: 400)
                }.value
                guard !Task.isCancelled, let self, self.library === lib, let page else { return }
                self.items = page
                self.isPartialPage = true
            }
            typealias Result = ([BrowseItem], LibraryIndex.Counts?, FolderTree?, [FacetValue], LibrarySummary, Date?)
            let result = await Task.detached(priority: .userInitiated) { () -> Result? in
                let folder = q.folder.flatMap { try? lib.index.dirID(forPath: $0) } ?? nil
                guard let items = try? lib.index.items(filter: q.filter, search: q.text, sort: q.sort, folder: folder) else { return nil }
                let counts = doRefresh ? try? lib.index.counts() : nil
                let tree = doRefresh ? (try? lib.index.directoryTree()).map(FolderTree.init) : nil
                let sources = (try? lib.index.facetCounts(.source, filter: q.filter, search: q.text, folder: folder)) ?? []
                let summary = (try? lib.index.summary(filter: q.filter, search: q.text, folder: folder)) ?? LibrarySummary()
                let created = doRefresh ? (try? lib.index.createdAt()) ?? nil : nil
                return (items, counts, tree, sources, summary, created)
            }.value
            guard !Task.isCancelled, let self, let (items, counts, tree, sources, summary, created) = result, self.library === lib else { return }
            if doRefresh { self.pendingRefresh = false }
            self.isPartialPage = false
            if items != self.items { self.items = items }
            // An image selected before its metadata was read would stay on "Reading metadata…".
            if let d = self.detail, d.metadata == nil, !d.metadataFailed {
                self.detail = try? lib.index.detail(id: d.id)
            }
            if let counts { self.counts = counts }
            if let tree, tree != self.folderTree { self.folderTree = tree }
            if summary != self.summary { self.summary = summary }
            if doRefresh { self.libraryCreatedAt = created }
            self.sourceCounts = Dictionary(uniqueKeysWithValues: sources.compactMap { v in ItemSource(rawValue: v.value).map { ($0, v.count) } })
        }
    }

    // MARK: - Selection

    private func loadDetail() {
        guard let id = selection.last, let lib = library else { detail = nil; return }
        detail = try? lib.index.detail(id: id)
    }

    func originalURL(_ relPath: String) -> URL? {
        library?.root.appendingPathComponent(relPath)
    }

    // MARK: - Copy

    enum CopyKind { case prompt, text, parameters }

    func copy(_ kind: CopyKind) {
        guard let lib = library else { return }
        let lines: [String] = selection.compactMap { id in
            guard let m = (try? lib.index.detail(id: id))??.metadata else { return nil }
            switch kind {
            case .prompt: return m.fullPrompt
            case .text: return m.promptText
            case .parameters: return m.prompt?.parameterString
            }
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedKind = kind
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if self?.copiedKind == kind { self?.copiedKind = nil }
        }
    }

    /// Copies the full path of each selected image, one per line.
    func copyPath() {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let paths = selection.compactMap { byID[$0].flatMap { originalURL($0.relPath)?.path } }
        guard !paths.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func revealInFinder() {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let urls = selection.compactMap { byID[$0].flatMap { originalURL($0.relPath) } }
        guard isOnline, !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openOriginal() {
        guard isOnline, let d = detail, let url = originalURL(d.relPath) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }
}

/// Loads thumbnails from the packs off the main thread, with a memory cache.
@MainActor
final class ThumbnailLoader {
    var library: Library? { didSet { cache.removeAllObjects(); missing.removeAll(); inFlight.removeAll() } }
    weak var scanner: FolderScanner?
    private let cache = NSCache<NSNumber, NSImage>()
    private var inFlight: [Int64: [(NSImage?) -> Void]] = [:]
    private(set) var missing = Set<Int64>()
    var onAvailable: ((Set<Int64>) -> Void)?

    init() { cache.countLimit = 3000 }

    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func load(_ id: Int64, completion: @escaping (NSImage?) -> Void) {
        if let img = cached(id) { completion(img); return }
        if inFlight[id] != nil { inFlight[id]!.append(completion); return }
        guard let lib = library else { completion(nil); return }
        inFlight[id] = [completion]
        Task.detached(priority: .userInitiated) {
            var cg: CGImage?
            if let loc = try? lib.index.thumbnailLocation(id: id), let data = try? lib.thumbnails.data(at: loc),
               let src = CGImageSourceCreateWithData(data as CFData, nil) {
                cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            let result = cg
            await MainActor.run { [weak self] in
                guard let self, self.library === lib else { return }
                var image: NSImage?
                if let result {
                    let img = NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
                    self.cache.setObject(img, forKey: NSNumber(value: id))
                    image = img
                    self.missing.remove(id)
                } else {
                    self.missing.insert(id)
                }
                for c in self.inFlight.removeValue(forKey: id) ?? [] { c(image) }
            }
        }
    }

    func markMissing(_ id: Int64) { missing.insert(id) }

    /// Asks the scanner to make these thumbnails first.
    func prioritize(_ ids: [Int64]) {
        scanner?.prioritize(ids: ids.filter { cached($0) == nil })
    }

    /// Lets the grid retry items whose thumbnail was not ready before.
    func retryMissing() {
        guard !missing.isEmpty else { return }
        let ids = missing
        missing.removeAll()
        onAvailable?(ids)
    }
}
