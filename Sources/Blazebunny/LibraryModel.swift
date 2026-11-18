import AppKit
import BlazebunnyCore
import Observation

@MainActor @Observable
final class LibraryModel {
    var saved: [SavedLibrary] = []
    /// Ghost libraries open right now. In memory only; see `GhostStorage`.
    var ghosts: [SavedLibrary] = []
    var currentPath: String?
    private(set) var library: Library?
    /// What the grid shows: items, month sections and positions, prepared off the main thread.
    private(set) var grid = GridSnapshot()
    var items: [BrowseItem] { grid.items }
    var query = SearchQuery() { didSet { if query != oldValue { queryChanged(textOnly: query.filter == oldValue.filter && query.sort == oldValue.sort && query.folder == oldValue.folder) } } }
    var sidebarSelection: SidebarItem?
    var savedSearches: [SavedSearch] = []
    var cellSize: Double = DS.Size.thumbnailDefault
    var fillCells = true
    var selection: [Int64] = [] { didSet { if selection != oldValue { selectionChanged(previous: oldValue.last) } } }
    private(set) var detail: ItemDetail?
    /// The inspector's large image.
    @ObservationIgnored let preview = PreviewModel()
    private(set) var progress: ScanProgress? {
        didSet { let done = progress?.phase == .done; if done != scanFinished { scanFinished = done } }
    }
    /// True once the scan of the open library has ended. Kept apart from `progress` so views that only
    /// need to know this are not redrawn at every step of a scan.
    private(set) var scanFinished = false
    /// Set when a scan stopped with an error, so the footer says so instead of showing a stale status.
    private(set) var scanFailure: String?
    private(set) var counts = LibraryIndex.Counts()
    /// What the current view holds (the whole library when no filter is on). Read from the index
    /// only while the inspector shows it (`summaryVisible`).
    private(set) var summary = LibrarySummary()
    /// Set by the summary view while it is on screen.
    @ObservationIgnored var summaryVisible = false { didSet { if summaryVisible, !oldValue { loadSummary() } } }
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
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var lastDetailUpdate = Date.distantPast
    @ObservationIgnored private var pendingRefresh = true
    @ObservationIgnored private var lastProgressReload = Date.distantPast
    /// What the last reload during a scan had seen, to skip reloads when only thumbnails were made.
    @ObservationIgnored private var lastReloadSignature = [-1, -1]
    /// Counts each reload asked for, so an older one that finishes late is dropped.
    @ObservationIgnored private var reloadSerial = 0
    /// Counts changes of what the user asked to see; the grid goes back to the top when it moves.
    @ObservationIgnored private var viewSerial = 0
    /// The scan waits for the first grid of a newly opened library, so launch has the disk to itself.
    @ObservationIgnored private var scanAfterFirstLoad = false
    @ObservationIgnored private var observers: [Any] = []

    private static let savedKey = "savedLibraries"
    private static let currentKey = "currentLibrary"
    private static let expandedKey = "expandedFolders"

    init() {
        // A crashed session may have left ghost data behind: nothing is open yet, so remove it all.
        Perf.launchMark("modelInitStart")
        GhostStorage.purgeAll()
        Perf.launchMark("ghostsPurged")
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
        Perf.launchMark("modelInit")
        PerfBench.startIfRequested(model: self)
    }

    var allLibraries: [SavedLibrary] { saved + ghosts }
    var currentLibrary: SavedLibrary? { allLibraries.first { $0.path == currentPath } }
    var currentLibraryName: String { currentLibrary?.name ?? "Blazebunny" }
    var currentIsGhost: Bool { currentLibrary?.isGhost ?? false }

    /// What stands where the grid is.
    enum ContentState { case grid, noMatches, looking, noImages }

    var contentState: ContentState {
        if !grid.items.isEmpty { return .grid }
        if counts.total > 0 { return .noMatches }
        return scanFinished ? .noImages : .looking
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
        preview.reset()
        library = nil
        currentPath = nil
        grid.clear()
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
        grid.clear()
        preview.reset()
        progress = nil
        errorMessage = nil
        viewSerial += 1
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
            Perf.launchMark("libraryOpened")
            library = lib
            thumbnails.library = lib
            savedSearches = (try? lib.index.savedSearches()) ?? []
        } catch {
            errorMessage = "Could not open the library: \(error.localizedDescription)"
            library = nil
            return
        }
        // First rows at once, then everything; the scan starts when the grid is up.
        scanAfterFirstLoad = true
        scheduleReload(phased: true, refresh: true)
        Perf.launchMark("reloadScheduled")
        refreshOnline()
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
        var online = false
        if let root = library?.root {
            var isDir: ObjCBool = false
            online = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
        }
        if online != isOnline { isOnline = online }
    }

    private func volumesChanged() {
        let was = isOnline
        refreshOnline()
        if isOnline && !was { startScan() }
        if !isOnline && was { stopScan() }
    }

    // MARK: - Facet popovers

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
        viewSerial += 1
        // The first rows follow every change at once, typing included (a few milliseconds). The full
        // list of a search waits a moment for the next key, so a word typed quickly is read once.
        scheduleReload(settle: textOnly ? 0.08 : 0, phased: true)
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
        // How many files are read at once follows the kind of disk (see `VolumeKind`).
        let scanner = FolderScanner(root: lib.root, index: lib.index, thumbnails: lib.thumbnails)
        self.scanner = scanner
        scanFailure = nil
        lastReloadSignature = [-1, -1]
        thumbnails.scanner = scanner
        scanner.onThumbnails = { [weak self] batch in
            Task { @MainActor in
                guard let self, self.scanner === scanner else { return }
                self.thumbnails.noteMade(batch)
            }
        }
        // The scanner reports after every batch; the UI needs it about ten times a second.
        let throttle = ProgressThrottle()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await scanner.run { p in
                    guard throttle.shouldReport(p) else { return }
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
        scanAfterFirstLoad = false
    }

    private func didProgress(_ p: ScanProgress) {
        progress = p
        // The grid needs new rows when files were listed or metadata was read (dates, sources and
        // prompts change what it shows). Thumbnails reach the cells on their own (`noteMade`), so a
        // scan that is only making thumbnails reloads nothing until it is done.
        let signature = [p.total, p.metadataDone]
        let interval: TimeInterval = items.isEmpty ? 0.3 : 3
        if p.phase == .done || (signature != lastReloadSignature && Date().timeIntervalSince(lastProgressReload) > interval) {
            lastProgressReload = Date()
            lastReloadSignature = signature
            scheduleReload(refresh: true)
        }
    }

    // MARK: - Grid data

    private struct Loaded: Sendable {
        var snapshot: GridSnapshot?
        var counts: LibraryIndex.Counts?
        var tree: FolderTree?
        var sources: [ItemSource: Int]?
        var created: Date?
    }

    /// Reloads what the grid shows. Everything is read and prepared off the main thread, starting at
    /// once (at launch that is while the window is still being built). `phased` first publishes the
    /// first screen of rows (well under a millisecond on 100k items, about 15 ms for a search) and
    /// then the full result, after `settle` seconds without a newer request.
    /// `refresh` also re-reads the library-wide numbers (counts, folder tree): they do not change when
    /// only a filter does, so a filter change skips them.
    private func scheduleReload(settle: TimeInterval = 0, phased: Bool = false, refresh: Bool = false) {
        reloadTask?.cancel()
        pendingRefresh = pendingRefresh || refresh
        guard let lib = library else { return }
        reloadSerial += 1
        let serial = reloadSerial
        let q = query
        let view = viewSerial
        let doRefresh = pendingRefresh
        let previous = grid
        let asked = Perf.now()
        Perf.signposter.emitEvent("reload.asked")
        // Only the first page of a view is worth showing early: a refresh of the same view keeps its rows.
        let wantsFirstPage = phased && previous.view != view
        // Read after the scan ended, the items carry every thumbnail the scan made.
        let scanIsOver = scanner == nil || progress?.phase == .done
        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            let index = lib.index
            let folder = q.folder.flatMap { try? index.dirID(forPath: $0) } ?? nil
            let sectioned = q.sort.isByDate
            var shown = previous
            if wantsFirstPage,
               let page = try? index.items(filter: q.filter, search: q.text, sort: q.sort, folder: folder, limit: Self.firstPage),
               let first = GridSnapshot.make(items: page, sectioned: sectioned, view: view, previous: previous) {
                shown = first
                let isWhole = page.count < Self.firstPage
                await self?.publish(Loaded(snapshot: first), serial: serial, library: lib, partial: !isWhole, asked: asked)
            }
            if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
            if Task.isCancelled { return }
            guard let items = try? index.items(filter: q.filter, search: q.text, sort: q.sort, folder: folder) else { return }
            if Task.isCancelled { return }
            var loaded = Loaded()
            loaded.snapshot = GridSnapshot.make(items: items, sectioned: sectioned, view: view, previous: shown)
            // The filter row only asks for these when no source is selected, so the items answer it.
            if q.filter.sources.isEmpty { loaded.sources = (loaded.snapshot ?? shown).sourceCounts() }
            if doRefresh {
                loaded.counts = try? index.counts()
                loaded.tree = (try? index.directoryTree()).map(FolderTree.init)
                loaded.created = (try? index.createdAt()) ?? nil
            }
            await self?.publish(loaded, serial: serial, library: lib, partial: false, refreshed: doRefresh,
                                scanIsOver: scanIsOver, asked: asked)
        }
    }

    /// Rows shown first while the rest of a new view loads.
    private nonisolated static let firstPage = 400

    private func publish(_ loaded: Loaded, serial: Int, library lib: Library, partial: Bool, refreshed: Bool = false,
                         scanIsOver: Bool = false, asked: UInt64) {
        guard serial == reloadSerial, library === lib else { return }
        if let snapshot = loaded.snapshot { grid = snapshot }
        if isPartialPage != partial { isPartialPage = partial }
        if partial {
            Perf.log("reload.firstPage", Perf.ms(since: asked))
            return
        }
        Perf.log("reload.complete", Perf.ms(since: asked))
        Perf.signposter.emitEvent("reload.complete")
        if !grid.items.isEmpty { Perf.launchMark("firstItems") }
        if refreshed { pendingRefresh = false }
        if scanIsOver { thumbnails.itemsReloaded() }
        // An image selected before its metadata was read would stay on "Reading metadata…".
        if let d = detail, d.metadata == nil, !d.metadataFailed { detail = try? lib.index.detail(id: d.id) }
        if let counts = loaded.counts, counts != self.counts { self.counts = counts }
        if let tree = loaded.tree, tree != folderTree { folderTree = tree }
        if refreshed, loaded.created != libraryCreatedAt { libraryCreatedAt = loaded.created }
        if let sources = loaded.sources, sources != sourceCounts { sourceCounts = sources }
        if summaryVisible { loadSummary() }
        if scanAfterFirstLoad {
            scanAfterFirstLoad = false
            if isOnline { startScan() }
        }
    }

    /// Reads the summary for the current view. Only called while the inspector shows it.
    private func loadSummary() {
        guard let lib = library else { return }
        let q = query
        summaryTask?.cancel()
        summaryTask = Task.detached(priority: .userInitiated) { [weak self] in
            let folder = q.folder.flatMap { try? lib.index.dirID(forPath: $0) } ?? nil
            guard !Task.isCancelled, let summary = try? lib.index.summary(filter: q.filter, search: q.text, folder: folder) else { return }
            await MainActor.run {
                guard let self, self.library === lib, self.query == q, summary != self.summary else { return }
                self.summary = summary
            }
        }
    }

    // MARK: - Selection

    /// A point lookup on its own connection: a few microseconds, also during a scan or a reload, so
    /// it stays on the main thread and the inspector never shows a stale image.
    private func selectionChanged(previous: Int64?) {
        detailTask?.cancel()
        guard let id = selection.last, library != nil else {
            if detail != nil { detail = nil }
            preview.clear()
            return
        }
        // The image follows every step at once (it is the grid's thumbnail, already in memory).
        showPreview(id: id, previous: previous)
        // The text below it is costly to lay out (10 to 20 ms of the main thread), so while an arrow
        // key is held it follows about ten times a second, and always ends on the last image.
        let wait = Self.detailInterval - Date().timeIntervalSince(lastDetailUpdate)
        if wait <= 0 || detail == nil {
            loadDetail(id)
        } else {
            detailTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.selection.last == id else { return }
                self.loadDetail(id)
            }
        }
    }

    private static let detailInterval: TimeInterval = 0.1

    private func loadDetail(_ id: Int64) {
        lastDetailUpdate = Date()
        detail = try? library?.index.detail(id: id)
    }

    private func previewRequest(at position: Int) -> PreviewModel.Request? {
        guard position >= 0, position < grid.items.count, let lib = library else { return nil }
        let item = grid.items[position]
        return PreviewModel.Request(id: item.id, url: lib.root.appendingPathComponent(item.relPath), width: item.width, height: item.height)
    }

    private func showPreview(id: Int64, previous: Int64?) {
        guard let position = grid.position(ofID: id), let request = previewRequest(at: position) else { preview.clear(); return }
        let item = grid.items[position]
        let from = previous.flatMap { grid.position(ofID: $0) }
        let direction = from.map { (position - $0).signum() } ?? 0
        let around = PreviewDecoder.neighbours(of: position, count: grid.items.count, direction: direction)
        let isVideo = ItemKind(pathExtension: (item.relPath as NSString).pathExtension).isVideo
        let neighbours = around.compactMap { p -> PreviewModel.Request? in
            guard !ItemKind(pathExtension: (grid.items[p].relPath as NSString).pathExtension).isVideo else { return nil }
            return previewRequest(at: p)
        }
        let location = thumbnails.location(for: item)
        preview.show(request, thumbnail: thumbnails.cached(id), decodeOriginal: isOnline && !isVideo, neighbours: neighbours,
                     loadThumbnail: location.map { loc in { [thumbnails] done in thumbnails.load(id, at: loc, completion: done) } })
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
    private func selectedURLs() -> [URL] {
        selection.compactMap { grid.position(ofID: $0).flatMap { originalURL(grid.items[$0].relPath) } }
    }

    func copyPath() {
        let paths = selectedURLs().map(\.path)
        guard !paths.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func revealInFinder() {
        let urls = selectedURLs()
        guard isOnline, !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openOriginal() {
        // The selection, not the inspector's detail: that one may be a step behind while arrowing.
        guard isOnline, let url = selectedURLs().last else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }
}

/// Lets a scan's progress through about ten times a second. Phase changes always pass.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var phase: ScanProgress.Phase?

    func shouldReport(_ p: ScanProgress) -> Bool {
        lock.withLock {
            let now = Date()
            if p.phase == phase, p.phase != .done, now.timeIntervalSince(last) < 0.1 { return false }
            phase = p.phase
            last = now
            return true
        }
    }
}
