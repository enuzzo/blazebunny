import SwiftUI
import AppKit
import BlazebunnyCore

@main
struct BlazebunnyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var model = LibraryModel()

    init() {
        Perf.launchMark("appInitStart")
        Typeface.registerBundled()
        Perf.launchMark("appInit")
    }

    var body: some Scene {
        Window("Blazebunny", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        // These belong to the main window (they were attached to the Settings scene, where the size did nothing).
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Blazebunny") { BuildInfo.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.openFolderPanel() }
                    .keyboardShortcut("o")
                Button("Open Ghost Folder…") { model.openFolderPanel(ghost: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Close Ghost") { if let g = model.currentLibrary, g.isGhost { model.closeGhost(g) } }
                    .disabled(!model.currentIsGhost)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(model.library == nil)
            }
            CommandMenu("Library") {
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.library == nil || !model.isOnline)
                Divider()
                Button("Clear All") { model.clearAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.library == nil)
            }
            CommandGroup(after: .toolbar) {
                // The title is a view of its own: the app's scenes are not rebuilt when it changes.
                Button { model.fillCells.toggle() } label: { FillMenuTitle(model: model) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Bigger Thumbnails") { model.cellSize = min(DS.Size.thumbnailMax, model.cellSize + DS.Size.thumbnailStep) }
                    .keyboardShortcut("+")
                Button("Smaller Thumbnails") { model.cellSize = max(DS.Size.thumbnailMin, model.cellSize - DS.Size.thumbnailStep) }
                    .keyboardShortcut("-")
                Divider()
            }
        }
        Settings {
            PreferencesView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The window: sidebar, grid column and inspector. Its body reads only what changes rarely (title,
/// alerts); everything that changes often (the grid's items, the scan's progress, thumbnail size,
/// the selection) is read by a small view of its own, so a tick of one never redraws the others.
struct ContentView: View {
    @Bindable var model: LibraryModel
    @State private var showInspector = true
    @State private var showSave = false
    @AppStorage(Typeface.defaultsKey) private var useBrandTypeface = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        // The font modifier reads the environment, so it sits inside `.environment`.
        content
            .dsText(.body)
            .environment(\.brandTypeface, useBrandTypeface && Typeface.isAvailable)
    }

    var content: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 340)
        } detail: {
            DetailColumn(model: model)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 352, max: 520)
                }
        }
        .toolbar(removing: .title)
        .background { WindowBackdrop() }
        .preferredColorScheme(.dark)
        .searchable(text: $model.query.text, placement: .toolbar, prompt: "Search prompts and names")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .benchToggleInspector)) { _ in showInspector.toggle() }
        .toolbar {
            ToolbarItemGroup { ThumbnailControls(model: model) }
            ToolbarItem { SaveSearchButton(model: model, showSave: $showSave) }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the inspector (⌥⌘I)")
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .sheet(isPresented: $showSave) { SaveSearchSheet(model: model, existing: nil) }
        .background {
            Button("") { if model.library != nil { showSave = true } }
                .keyboardShortcut("s")
                .hidden()
        }
        .alert("Blazebunny", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct FillMenuTitle: View {
    let model: LibraryModel
    var body: some View { Text(model.fillCells ? "Fit Thumbnails" : "Fill Thumbnails") }
}

/// Fill or fit, thumbnail size and sort order: the toolbar's grid controls.
struct ThumbnailControls: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Picker("Thumbnails", selection: $model.fillCells) {
            Text("Fill").tag(true)
            Text("Fit").tag(false)
        }
        .pickerStyle(.segmented)
        .help("Fill crops thumbnails to squares; Fit shows whole images (⌥⌘F)")
        Slider(value: $model.cellSize, in: DS.Size.thumbnailMin...DS.Size.thumbnailMax) { Text("Thumbnail Size") }
            .frame(width: DS.Size.toolbarSlider)
            .help("Thumbnail size (⌘+ / ⌘−)")
        Picker("Sort", selection: $model.query.sort) {
            ForEach(ItemSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .help("Sort order. Dates are the ones embedded in the file when present.")
    }
}

struct SaveSearchButton: View {
    let model: LibraryModel
    @Binding var showSave: Bool

    var body: some View {
        if let s = model.activeSavedSearch, model.savedSearchIsModified {
            // Saving a new search is the safe primary action; overwriting is a menu choice.
            Menu {
                Button("Save as New Search…") { showSave = true }
                Button("Update “\(s.name)” with Current Filters") { model.updateSavedSearch(s.id) }
            } label: {
                Label("Save Search", systemImage: "bookmark.fill")
            } primaryAction: {
                showSave = true
            }
            .help("Save these filters as a new search. “\(s.name)” has changed: open the menu to update it instead.")
        } else {
            Button { showSave = true } label: { Label("Save Search", systemImage: "bookmark") }
                .help("Save the current filters and search as a sidebar item (⌘S)")
                .disabled(model.library == nil)
        }
    }
}

/// The middle column: header row, grid (or what stands in for it) and the status bar.
struct DetailColumn: View {
    let model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            if model.library == nil {
                ContentUnavailableView {
                    Label("Blazebunny", systemImage: "hare")
                } description: {
                    Text("Hops through your archive faster than you can scroll.\nOpen a folder of images to start. Blazebunny only reads it.")
                } actions: {
                    Button("Open Folder…") { model.openFolderPanel() }.keyboardShortcut("o")
                }
            } else {
                HeaderRow(model: model)
                Divider().overlay(DS.Palette.hairline)
                GridArea(model: model)
            }
            StatusBar(model: model)
        }
        .ghostOutline(model.currentIsGhost)
        .navigationTitle(model.viewTitle)
    }
}

/// One row: what you are looking at, then how to narrow it.
struct HeaderRow: View {
    let model: LibraryModel

    var body: some View {
        HStack(spacing: 0) {
            PageHeader(title: model.viewTitle, subtitle: subtitle, isGhost: model.currentIsGhost,
                       contextKind: model.contextKind, crumbs: model.contextCrumbs) { model.selectSidebar($0) }
                .padding(.leading, DS.Space.l)
            FilterRow(model: model)
        }
        .frame(height: DS.Size.headerRow)
    }

    var subtitle: String {
        // Only the first screen is loaded yet: do not show a count that is about to change.
        if model.isPartialPage { return "" }
        // The total of what is being browsed: the library, or the open folder with everything below it.
        let total = model.query.folder.flatMap { model.folderTree.nodes[$0]?.subtreeCount } ?? model.counts.total
        let shown = model.grid.items.count
        if shown == total { return "\(total.formatted()) images" }
        return "\(shown.formatted()) of \(total.formatted()) images"
    }
}

/// The grid, or the message that stands in for it when there is nothing to show.
struct GridArea: View {
    let model: LibraryModel

    var body: some View {
        switch model.contentState {
        case .grid:
            GridHost(model: model)
        case .noMatches:
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(model.query.filter.isEmpty && model.query.text.isEmpty && model.query.folder != nil
                     ? "No images in this folder."
                     : model.query.filter.isEmpty && !model.query.text.isEmpty
                     ? "No images match “\(model.query.text)”."
                     : "No images match these filters.")
            } actions: {
                Button("Clear All") { model.clearAll() }
                    .disabled(model.query.filter.isEmpty && model.query.text.isEmpty)
            }
            .frame(maxHeight: .infinity)
        case .looking:
            ContentUnavailableView {
                Label("Looking for images…", systemImage: "magnifyingglass")
            } description: {
                Text(model.isOnline ? "Listing the folder. This can take a while on a large or external disk."
                                    : "The folder is not connected.")
            }
            .frame(maxHeight: .infinity)
        case .noImages:
            ContentUnavailableView("No Images", systemImage: "photo.on.rectangle",
                                   description: Text("This folder has no supported images."))
                .frame(maxHeight: .infinity)
        }
    }
}

/// Reads exactly what the grid needs, so nothing else that changes in the model reaches it.
struct GridHost: View {
    let model: LibraryModel

    var body: some View {
        GridView(model: model, revision: model.grid.revision, cellSize: model.cellSize, fill: model.fillCells)
    }
}

/// Large, light page title above the filters. The window title stays set for
/// accessibility and Mission Control; only its toolbar rendering is removed.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var isGhost = false
    var contextKind = ""
    var crumbs: [LibraryModel.Crumb] = []
    var onSelect: (SidebarItem) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !contextKind.isEmpty { ContextLine(kind: contextKind, crumbs: crumbs, isGhost: isGhost, onSelect: onSelect) }
            titleRow
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .animation(DS.Motion.view, value: title)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            if isGhost { GhostIcon(size: DS.Size.iconTitle).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 } }
            Text(title)
                .dsText(.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if !subtitle.isEmpty {
                RichText(subtitle, .label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// Which build is running: version, commit count and commit (`+` = built with uncommitted changes).
/// Stamped into the app's Info.plist by `scripts/build-app.sh`; a bare `swift run` shows "dev".
enum BuildInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    static let commit = Bundle.main.infoDictionary?["BlazebunnyCommit"] as? String ?? "dev"
    static let builtAt = Bundle.main.infoDictionary?["BlazebunnyBuiltAt"] as? String ?? ""
    /// The standard About panel, with the build spelled out under the version.
    @MainActor static func showAbout() {
        let credits = NSAttributedString(string: "Build \(build) · \(builtAt.isEmpty ? "dev" : builtAt)\nCommit \(commit)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    static var short: String { "v\(version) · \(builtAt.isEmpty ? "b" + build : builtAt) · \(commit)" }
    static var long: String { "Blazebunny \(version), build \(build), commit \(commit)" + (builtAt.isEmpty ? "" : ", built \(builtAt)") }
}

struct StatusBar: View {
    let model: LibraryModel

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if model.library != nil {
                // State shows by exception: quiet when connected, coral when not.
                Image(systemName: model.isOnline ? "externaldrive" : "externaldrive.badge.xmark")
                    .foregroundStyle(model.isOnline ? Color.secondary : DS.Tint.warning)
                    .help(model.isOnline ? "Folder connected" : "Folder not connected: browsing the cached index")
                RichText(summary, .label)
                Spacer()
                if let p = model.progress, p.phase != .done {
                    ProgressView().controlSize(.small)
                    RichText(phaseText(p), .label)
                } else if let failure = model.scanFailure {
                    // A scan that stopped must not leave a stale "listing" status behind.
                    Label("Scan stopped · Rescan with ⌘R", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.Tint.warning)
                        .help(failure)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Size.statusBar)
        .overlay(alignment: .top) { Divider() }
    }

    var summary: String {
        let c = model.counts
        // While scanning, the thumbnail count is on the right: do not say it twice.
        let scanning = model.progress.map { $0.phase != .done } ?? false
        let base = "\(c.total.formatted()) indexed · \(c.withPrompt.formatted()) with prompt"
        return scanning ? base : base + " · \(c.thumbnailsDone.formatted()) thumbnails"
    }

    func phaseText(_ p: ScanProgress) -> String {
        switch p.phase {
        case .enumerating: return "Listing files… \(p.total.formatted())"
        case .metadata:
            return "Reading metadata \(p.metadataDone.formatted()) / \(p.total.formatted()) · Thumbnails \(p.thumbnailsDone.formatted())"
        case .thumbnails:
            let mbps = p.elapsed > 0 ? Double(p.bytesRead) / 1e6 / p.elapsed : 0
            return "Thumbnails \(p.thumbnailsDone.formatted()) / \(p.total.formatted()) · \(String(format: "%.1f", mbps)) MB/s"
        case .done: return ""
        }
    }
}
