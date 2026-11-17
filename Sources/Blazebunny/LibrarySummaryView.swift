import SwiftUI
import BlazebunnyCore

/// The inspector when no image is selected: what the current library, view or
/// saved search holds. Follows the active filters, so it always matches the grid.
struct LibrarySummaryView: View {
    let model: LibraryModel

    private var s: LibrarySummary { model.summary }
    private var isWholeLibrary: Bool {
        if case .library = model.sidebarSelection { return true }
        return false
    }
    private var folderPath: String? { model.saved.first { $0.path == model.currentPath }?.path }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                hero
                if !s.kinds.isEmpty { breakdown("Types", s.kinds, label: { $0.uppercased() }) }
                if !s.sources.isEmpty { breakdown("Sources", s.sources, label: sourceTitle) }
                details
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var hero: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(model.viewTitle)
                .dsFont(12)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(s.total.formatted())
                .dsFont(44, .number)
            Text(s.total == 1 ? "image" : "images")
                .dsFont(12)
                .foregroundStyle(.secondary)
        }
    }

    func breakdown(_ title: String, _ values: [FacetValue], label: @escaping (String) -> String) -> some View {
        let top = values.prefix(6)
        let maxCount = max(1, top.map(\.count).max() ?? 1)
        return InfoTable(title: title) {
            ForEach(Array(top), id: \.value) { v in
                HStack(spacing: DS.Space.s) {
                    Text(label(v.value)).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 72 * CGFloat(v.count) / CGFloat(maxCount), height: 4)
                        .frame(width: 72, alignment: .trailing)
                    Text(v.count.formatted())
                        .dsFont(12, .number)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .dsFont(12)
                .frame(minHeight: DS.Size.control)
                .overlay(alignment: .bottom) { Divider().overlay(DS.Palette.hairline) }
            }
        }
    }

    var details: some View {
        InfoTable(title: "Details") {
            InfoRow(label: "Size") { Text(ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)).dsFont(12, .number) }
            if let range = dateRange { InfoRow(label: "Dates") { Text(range).dsFont(12, .number) } }
            InfoRow(label: "With prompt") { Text(s.withPrompt.formatted()).dsFont(12, .number) }
            if isWholeLibrary, let created = model.libraryCreatedAt {
                InfoRow(label: "Added") { Text(created.formatted(date: .abbreviated, time: .omitted)).dsFont(12, .number) }
            }
            if isWholeLibrary, let path = folderPath {
                InfoRow(label: "Folder") {
                    Text(path).lineLimit(1).truncationMode(.head).help(path)
                }
            }
        }
    }

    var dateRange: String? {
        guard let a = s.oldest, let b = s.newest else { return nil }
        let f = Date.FormatStyle().month(.abbreviated).year()
        let from = a.formatted(f), to = b.formatted(f)
        return from == to ? from : "\(from) – \(to)"
    }

    func sourceTitle(_ raw: String) -> String {
        ItemSource(rawValue: raw)?.title ?? raw.capitalized
    }
}
