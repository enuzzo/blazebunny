import SwiftUI
import BlazebunnyCore

struct SidebarView: View {
    @Bindable var model: LibraryModel
    @State private var editing: SavedSearch?
    @State private var renamingPath: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool
    /// When the selection last changed, to tell "click to select" from "click on the selected row".
    @State private var selectedSince = Date.distantPast
    @State private var pendingRename: Task<Void, Never>?
    @State private var pendingForget: SavedLibrary?
    @State private var pendingDelete: SavedSearch?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarSelection }, set: { selectedSince = Date(); model.selectSidebar($0) })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(model.saved) { lib in
                    libraryRow(lib)
                        .sidebarRow(selected: model.sidebarSelection == .library(lib.path))
                        .tag(SidebarItem.library(lib.path))
                        .help(lib.path)
                        .contextMenu {
                            actionButton(.rename) { beginRename(lib) }
                            actionButton(.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lib.path)]) }
                            Divider()
                            actionButton(.forgetLibrary, role: .destructive) { pendingForget = lib }
                        }
                }
                // Drag a library up or down to put the libraries in the order you want.
                .onMove { model.moveLibraries(from: $0, to: $1) }
            } header: {
                SidebarHeader("Libraries")
            }
            if !model.ghosts.isEmpty {
                Section {
                    ForEach(model.ghosts) { lib in
                        libraryRow(lib)
                            .sidebarRow(selected: model.sidebarSelection == .library(lib.path))
                            .tag(SidebarItem.library(lib.path))
                            .help("\(lib.path)\n\(GhostText.explanation)")
                            .contextMenu {
                                actionButton(.rename) { beginRename(lib) }
                                Divider()
                                actionButton(.closeGhost, role: .destructive) { model.closeGhost(lib) }
                            }
                    }
                } header: {
                    SidebarHeader(GhostText.section, tint: DS.Tint.ghost) { GhostIcon(size: 12, decorative: true) }
                }
            }
            if model.library != nil {
                Section {
                    ForEach(BuiltInView.allCases.filter { $0 != .all }) { v in
                        SidebarRowContent {
                            Image(systemName: v.symbol).foregroundStyle(viewTint(v))
                        } title: {
                            Text(v.title)
                        }
                        .sidebarRow(selected: model.sidebarSelection == .view(v))
                        .tag(SidebarItem.view(v))
                    }
                } header: {
                    SidebarHeader("Views")
                }
                if !model.folderTree.isEmpty {
                    Section {
                        ForEach(model.folderRows) { row in folderRow(row) }
                    } header: {
                        SidebarHeader("Folders")
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section {
                        savedRows(in: nil)
                        ForEach(model.savedFolders, id: \.self) { folder in
                            DisclosureGroup {
                                savedRows(in: folder)
                            } label: {
                                Label(folder, systemImage: "folder")
                            }
                        }
                    } header: {
                        SidebarHeader("Saved Searches")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .labelStyle(SidebarLabelStyle())
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.openFolderPanel() } label: { Label("Open Folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { model.openFolderPanel(ghost: true) } label: { GhostIcon(size: 18) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open Ghost Folder")
                    .help("Open a Ghost Folder… (⇧⌘O). " + GhostText.explanation)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // One continuous backdrop behind everything, titlebar and footer included, so the light never
        // stops at an edge: it is applied outside the list and its safe-area insets.
        .background {
            ZStack {
                WindowBackdrop()
                SidebarGlow()
                if !reduceTransparency { Rectangle().fill(.ultraThinMaterial).opacity(0.5) }
                SidebarTableTweaks()
            }
            .ignoresSafeArea()
        }
        .sheet(item: $editing) { s in SaveSearchSheet(model: model, existing: s) }
        .confirmationDialog("Forget this library?", isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
                            presenting: pendingForget) { lib in
            Button("Forget “\(lib.name)”", role: .destructive) { model.remove(lib) }
        } message: { _ in
            Text("The folder and its images are not touched. Only Blazebunny's index and thumbnails for it are forgotten.")
        }
        .confirmationDialog("Delete this saved search?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { s in
            Button("Delete “\(s.name)”", role: .destructive) { model.deleteSavedSearch(s.id) }
        } message: { _ in
            Text("Your images are not affected.")
        }
    }

    /// The library's name, editable in place. Renaming only changes the name
    /// shown here; the folder on disk is never touched.
    @ViewBuilder func libraryRow(_ lib: SavedLibrary) -> some View {
        let count = lib.path == model.currentPath && model.counts.total > 0 ? model.counts.total : nil
        if renamingPath == lib.path {
            SidebarRowContent {
                Image(systemName: "photo.stack").foregroundStyle(DS.Tint.library)
            } title: {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(lib) }
                    .onExitCommand { renamingPath = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(lib) } }
            }
        } else {
            SidebarRowContent(count: count) {
                if lib.isGhost { GhostIcon(size: 16) } else { Image(systemName: "photo.stack").foregroundStyle(DS.Tint.library) }
            } title: {
                Text(lib.name)
            }
            .overlay {
                if lib.isGhost {
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .strokeBorder(DS.Tint.ghost.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .padding(.horizontal, -DS.Space.xs)
                }
            }
            .onTapGesture(count: 2) { pendingRename?.cancel(); beginRename(lib) }
            .simultaneousGesture(TapGesture().onEnded { slowClick(lib) })
        }
    }

    func viewTint(_ v: BuiltInView) -> Color {
        switch v {
        case .generated: return DS.Tint.midjourney
        case .photos: return DS.Tint.camera
        default: return .secondary
        }
    }

    /// One folder of the library. Clicking shows everything inside it, subfolders included.
    @ViewBuilder func folderRow(_ row: FolderRow) -> some View {
        SidebarRowContent(depth: row.node.depth - 1, chevronColumn: true, expanded: row.hasChildren ? row.isExpanded : nil,
                          count: row.node.subtreeCount,
                          onToggle: { model.toggleFolder(row.id) }) {
            Image(systemName: "folder").foregroundStyle(DS.Tint.folder)
        } title: {
            Text(row.node.name)
        }
        .sidebarRow(selected: model.sidebarSelection == .folder(row.id))
        .tag(SidebarItem.folder(row.id))
        .help(row.node.path)
        .accessibilityLabel("\(row.node.name), \(row.node.subtreeCount) images")
        .contextMenu {
            Button("Show in Finder") {
                if let url = model.originalURL(row.node.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    /// Like Finder: a click on a row that was already selected starts renaming
    /// after the double-click interval, unless another click follows.
    func slowClick(_ lib: SavedLibrary) {
        pendingRename?.cancel()
        let wait = NSEvent.doubleClickInterval
        // Only when the library is shown plain: after filtering, a click means "show everything".
        guard renamingPath == nil,
              model.sidebarSelection == .library(lib.path),
              model.query.filter.isEmpty, model.query.text.isEmpty,
              Date().timeIntervalSince(selectedSince) > wait + 0.1 else { return }
        pendingRename = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait + 0.15))
            if !Task.isCancelled, renamingPath == nil { beginRename(lib) }
        }
    }

    func beginRename(_ lib: SavedLibrary) {
        pendingRename?.cancel()
        draftName = lib.name
        renamingPath = lib.path
        renameFocused = true
    }

    func commitRename(_ lib: SavedLibrary) {
        guard renamingPath == lib.path else { return }
        renamingPath = nil
        model.rename(lib, to: draftName)
    }

    @ViewBuilder func savedRows(in folder: String?) -> some View {
        ForEach(model.savedSearches.filter { $0.folder == folder }) { s in
            SidebarRowContent {
                Circle().fill(Color(nsColor: (TagColor(rawValue: s.color) ?? .gray).color)).frame(width: 8, height: 8)
            } title: {
                Text(s.name)
            }
            .sidebarRow(selected: model.sidebarSelection == .saved(s.id))
            .tag(SidebarItem.saved(s.id))
            .contextMenu {
                actionButton(.editSavedSearch) { editing = s }
                if model.activeSavedSearch?.id == s.id {
                    Button("Update with Current Filters") { model.updateSavedSearch(s.id) }
                }
                Divider()
                actionButton(.deleteSavedSearch, role: .destructive) { pendingDelete = s }
            }
        }
        .onMove { from, to in model.moveSavedSearches(in: folder, from: from, to: to) }
    }
}
