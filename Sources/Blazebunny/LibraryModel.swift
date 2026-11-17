import AppKit
import BlazebunnyCore
import Observation

/// A folder the user has opened, remembered across launches.
struct SavedLibrary: Codable, Hashable, Identifiable {
    var path: String
    var bookmark: Data?
    /// A name the user chose. Display only: the folder itself is never renamed.
    var displayName: String?
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
    var currentPath: String?
    private(set) var library: Library?
    private(set) var items: [BrowseItem] = []
    var query = SearchQuery() { didSet { if query != oldValue { queryChanged(textOnly: query.filter == oldValue.filter && query.sort == oldValue.sort) } } }
    var sidebarSelection: SidebarItem?
    var savedSearches: [SavedSearch] = []
    var cellSize: Double = 160
    var fillCells = true
    var selection: [Int64] = [] { didSet { loadDetail() } }
    private(set) var detail: ItemDetail?
    private(set) var progress: ScanProgress?
    private(set) var counts = LibraryIndex.Counts()
    /// What the current view holds (the whole library when no filter is on).
    private(set) var summary = LibrarySummary()
    private(set) var libraryCreatedAt: Date?
    /// Item count per source for the current query, ignoring the source filter.
    private(set) var sourceCounts: [ItemSource: Int] = [:]
    private(set) var isOnline = false
    var errorMessage: String?
    /// Facet values for the open popover.
    private(set) var facetValues: [Facet: [FacetValue]] = [:]
    private(set) var histogram: [MonthCount] = []
    var openFacet: Facet?

    @ObservationIgnored let thumbnails = ThumbnailLoader()
    @ObservationIgnored private var scanner: FolderScanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressReload = Date.distantPast
    @ObservationIgnored private var observers: [Any] = []

    private static let savedKey = "savedLibraries"
    private static let currentKey = "currentLibrary"

    init() {
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
            open(URL(fileURLWithPath: args[i + 1]))
        } else if let path = UserDefaults.standard.string(forKey: Self.currentKey), saved.contains(where: { $0.path == path }) {
            select(path: path)
        }
    }

    var currentLibraryName: String { saved.first(where: { $0.path == currentPath })?.name ?? "Blazebunny" }

    /// Title of what the grid shows.
    var viewTitle: String {
        switch sidebarSelection {
        case .view(let v): return v.title
        case .saved(let id): return savedSearches.first(where: { $0.id == id })?.name ?? currentLibraryName
        default: return currentLibraryName
        }
    }

    // MARK: - Libraries

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of images. Blazebunny only reads it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !saved.contains(where: { $0.path == path }) {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            saved.append(SavedLibrary(path: path, bookmark: bookmark))
            persist()
        }
        select(path: path)
    }

    /// Gives a library a display name; an empty name goes back to the folder name.
    func rename(_ lib: SavedLibrary, to newName: String) {
        guard let i = saved.firstIndex(where: { $0.path == lib.path }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        saved[i].displayName = (trimmed.isEmpty || trimmed == saved[i].folderName) ? nil : trimmed
        persist()
    }

    func remove(_ lib: SavedLibrary) {
        saved.removeAll { $0.path == lib.path }
        persist()
        if currentPath == lib.path {
            stopScan()
            library = nil
            currentPath = nil
            items = []
            detail = nil
            savedSearches = []
        }
    }

    func select(path: String) {
        if path == currentPath, library != nil {
            sidebarSelection = .library(path)
            apply(SearchQuery(sort: query.sort))
            return
        }
        stopScan()
        currentPath = path
        sidebarSelection = .library(path)
        UserDefaults.standard.set(path, forKey: Self.currentKey)
        selection = []
        detail = nil
        items = []
        progress = nil
        errorMessage = nil
        query = SearchQuery()
        do {
            let lib = try Library(root: resolvedURL(for: path))
            library = lib
            thumbnails.library = lib
            savedSearches = (try? lib.index.savedSearches()) ?? []
        } catch {
            errorMessage = "Could not open the library: \(error.localizedDescription)"
            library = nil
            return
        }
        scheduleReload(delay: 0)
        refreshOnline()
        if isOnline { startScan() }
    }

    func selectSidebar(_ item: SidebarItem?) {
        guard let item else { return }
        switch item {
        case .library(let path):
            select(path: path)
        case .view(let v):
            sidebarSelection = item
            apply(SearchQuery(filter: v.filter, sort: query.sort))
        case .saved(let id):
            sidebarSelection = item
            if let s = savedSearches.first(where: { $0.id == id }) { apply(s.query) }
        }
    }

    private func apply(_ q: SearchQuery) {
        let keep = sidebarSelection
        query = q
        sidebarSelection = keep
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
        if f.sources.isEmpty, let mj = sourceCounts[.midjourney], mj > 0, sourceCounts.count == 1 { return true }
        return false
    }

    var showsCameraGroup: Bool {
        let f = query.filter
        if f.sources.contains(.camera) || !f.cameras.isEmpty { return true }
        if f.sources.isEmpty, let c = sourceCounts[.camera], c > 0, sourceCounts.count == 1 { return true }
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
            let values = facet == .date ? [] : ((try? lib.index.facetCounts(facet, filter: q.filter, search: q.text)) ?? [])
            let hist = facet == .date ? ((try? lib.index.monthHistogram(filter: q.filter, search: q.text)) ?? []) : []
            await MainActor.run { [weak self] in
                guard let self, self.library === lib else { return }
                if facet == .date { self.histogram = hist } else { self.facetValues[facet] = values }
            }
        }
    }

    private func queryChanged(textOnly: Bool) {
        scheduleReload(delay: textOnly ? 0.12 : 0)
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
        thumbnails.scanner = scanner
        scanTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await scanner.run { p in
                    Task { @MainActor in self?.didProgress(p) }
                }
            } catch {
                await MainActor.run { self?.errorMessage = "Scan stopped: \(error.localizedDescription)" }
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
        let interval: TimeInterval = items.isEmpty ? 0.3 : 2
        if p.phase == .done || Date().timeIntervalSince(lastProgressReload) > interval {
            lastProgressReload = Date()
            scheduleReload(delay: 0)
        }
        // Thumbnails are made alongside metadata, so retry as soon as any exist.
        if p.thumbnailsDone > 0 || p.phase == .done { thumbnails.retryMissing() }
    }

    // MARK: - Grid data

    private func scheduleReload(delay: TimeInterval) {
        reloadTask?.cancel()
        guard let lib = library else { return }
        let q = query
        reloadTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> ([BrowseItem], LibraryIndex.Counts, [FacetValue], LibrarySummary, Date?)? in
                guard let items = try? lib.index.items(filter: q.filter, search: q.text, sort: q.sort),
                      let counts = try? lib.index.counts() else { return nil }
                let sources = (try? lib.index.facetCounts(.source, filter: q.filter, search: q.text)) ?? []
                let summary = (try? lib.index.summary(filter: q.filter, search: q.text)) ?? LibrarySummary()
                let created = try? lib.index.createdAt()
                return (items, counts, sources, summary, created ?? nil)
            }.value
            guard !Task.isCancelled, let self, let (items, counts, sources, summary, created) = result, self.library === lib else { return }
            if items != self.items { self.items = items }
            self.counts = counts
            if summary != self.summary { self.summary = summary }
            self.libraryCreatedAt = created
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
    var library: Library? { didSet { cache.removeAllObjects(); missing.removeAll() } }
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
