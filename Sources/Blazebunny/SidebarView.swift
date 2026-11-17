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
                        .badge(lib.path == model.currentPath && model.counts.total > 0 ? Text(model.counts.total.formatted()) : nil)
                        .tag(SidebarItem.library(lib.path))
                        .help(lib.path)
                        .contextMenu {
                            Button("Rename…") { beginRename(lib) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lib.path)]) }
                            Divider()
                            Button("Forget Library…", role: .destructive) { pendingForget = lib }
                        }
                }
            } header: {
                SidebarHeader("Libraries")
            }
            if !model.ghosts.isEmpty {
                Section {
                    ForEach(model.ghosts) { lib in
                        libraryRow(lib)
                            .badge(lib.path == model.currentPath && model.counts.total > 0 ? Text(model.counts.total.formatted()) : nil)
                            .tag(SidebarItem.library(lib.path))
                            .help("\(lib.path)\n\(GhostText.explanation)")
                            .contextMenu {
                                Button("Rename…") { beginRename(lib) }
                                Divider()
                                Button("Close Ghost", role: .destructive) { model.closeGhost(lib) }
                            }
                    }
                } header: {
                    SidebarHeader(GhostText.section, tint: DS.Tint.ghost) { GhostIcon(size: 12, decorative: true) }
                }
            }
            if model.library != nil {
                Section {
                    ForEach(BuiltInView.allCases.filter { $0 != .all }) { v in
                        Label(v.title, systemImage: v.symbol).tag(SidebarItem.view(v))
                    }
                } header: {
                    SidebarHeader("Views")
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
        .background {
            ZStack {
                WindowBackdrop()
                if !reduceTransparency { Rectangle().fill(.ultraThinMaterial).opacity(0.5) }
            }
        }
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
        if renamingPath == lib.path {
            Label {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(lib) }
                    .onExitCommand { renamingPath = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(lib) } }
            } icon: {
                Image(systemName: "photo.stack")
            }
        } else {
            Label {
                Text(lib.name)
            } icon: {
                if lib.isGhost { GhostIcon(size: 16) } else { Image(systemName: "photo.stack") }
            }
            .padding(.vertical, lib.isGhost ? 2 : 0)
            .padding(.leading, lib.isGhost ? 6 : 0)
            .padding(.trailing, lib.isGhost ? 10 : 0)
            .overlay {
                if lib.isGhost {
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .strokeBorder(DS.Tint.ghost.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .onTapGesture(count: 2) { pendingRename?.cancel(); beginRename(lib) }
            .simultaneousGesture(TapGesture().onEnded { slowClick(lib) })
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
            Label {
                Text(s.name)
            } icon: {
                Circle().fill(Color(nsColor: (TagColor(rawValue: s.color) ?? .gray).color)).frame(width: 8, height: 8)
            }
            .tag(SidebarItem.saved(s.id))
            .contextMenu {
                Button("Edit…") { editing = s }
                if model.activeSavedSearch?.id == s.id {
                    Button("Update with Current Filters") { model.updateSavedSearch(s.id) }
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = s }
            }
        }
        .onMove { from, to in model.moveSavedSearches(in: folder, from: from, to: to) }
    }
}
