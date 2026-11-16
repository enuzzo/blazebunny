import SwiftUI
import BlazebunnyCore

struct SidebarView: View {
    @Bindable var model: LibraryModel
    @State private var editing: SavedSearch?

    var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarSelection }, set: { model.selectSidebar($0) })
    }

    var body: some View {
        List(selection: selection) {
            Section("Libraries") {
                ForEach(model.saved) { lib in
                    Label(lib.name, systemImage: "photo.stack")
                        .badge(lib.path == model.currentPath && model.counts.total > 0 ? Text(model.counts.total.formatted()) : nil)
                        .tag(SidebarItem.library(lib.path))
                        .help(lib.path)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lib.path)]) }
                            Divider()
                            Button("Forget Library", role: .destructive) { model.remove(lib) }
                        }
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
        .safeAreaInset(edge: .bottom) {
            Button { model.openFolderPanel() } label: { Label("Open Folder…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { s in SaveSearchSheet(model: model, existing: s) }
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
