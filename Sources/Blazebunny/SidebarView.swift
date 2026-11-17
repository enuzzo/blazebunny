import SwiftUI
import BlazebunnyCore

struct SidebarView: View {
    @Bindable var model: LibraryModel
    @State private var editing: SavedSearch?
    @State private var renamingPath: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarSelection }, set: { model.selectSidebar($0) })
    }

    var body: some View {
        List(selection: selection) {
            Section("Libraries") {
                ForEach(model.saved) { lib in
                    libraryRow(lib)
                        .badge(lib.path == model.currentPath && model.counts.total > 0 ? Text(model.counts.total.formatted()) : nil)
                        .tag(SidebarItem.library(lib.path))
                        .help(lib.path)
                        .contextMenu {
                            Button("Rename…") { beginRename(lib) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lib.path)]) }
                            Divider()
                            Button("Forget Library", role: .destructive) { model.remove(lib) }
                        }
                }
            }
            if !model.ghosts.isEmpty {
                Section {
                    ForEach(model.ghosts) { lib in
                        libraryRow(lib)
                            .badge(lib.path == model.currentPath && model.counts.total > 0 ? Text(model.counts.total.formatted()) : nil)
                            .tag(SidebarItem.library(lib.path))
                            .help("Ghost: \(lib.path)\nNothing is kept after you close it.")
                            .contextMenu {
                                Button("Rename…") { beginRename(lib) }
                                Divider()
                                Button("Close Ghost and Delete Its Data", role: .destructive) { model.closeGhost(lib) }
                            }
                    }
                } header: {
                    Label {
                        Text("Ghosts · leave no trace")
                    } icon: {
                        GhostIcon(size: 14)
                    }
                    .foregroundStyle(DS.Tint.ghost)
                }
            }
            if model.library != nil {
                Section(model.currentLibraryName) {
                    ForEach(BuiltInView.allCases.filter { $0 != .all }) { v in
                        Label(v.title, systemImage: v.symbol).tag(SidebarItem.view(v))
                    }
                }
                if !model.savedSearches.isEmpty {
                    Section("Saved Searches") {
                        savedRows(in: nil)
                        ForEach(model.savedFolders, id: \.self) { folder in
                            DisclosureGroup {
                                savedRows(in: folder)
                            } label: {
                                Label(folder, systemImage: "folder")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                WindowBackdrop()
                Rectangle().fill(.ultraThinMaterial).opacity(0.5)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.openFolderPanel() } label: { Label("Open Folder…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { model.openFolderPanel(ghost: true) } label: { GhostIcon(size: 18) }
                    .buttonStyle(.borderless)
                    .help("Open a Ghost Folder… (⇧⌘O): keeps nothing after you close it")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { s in SaveSearchSheet(model: model, existing: s) }
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
            .padding(.horizontal, lib.isGhost ? 4 : 0)
            .overlay {
                if lib.isGhost {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DS.Tint.ghost.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .onTapGesture(count: 2) { beginRename(lib) }
        }
    }

    func beginRename(_ lib: SavedLibrary) {
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
                Button("Update with Current Filters") { model.updateSavedSearch(s.id) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteSavedSearch(s.id) }
            }
        }
        .onMove { from, to in model.moveSavedSearches(in: folder, from: from, to: to) }
    }
}
