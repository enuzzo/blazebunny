import SwiftUI

/// The 11 pt line above the page title: what you are looking at and where, with the parts that lead
/// somewhere (the library, the folders above this one) clickable. "Folder · files › Renders".
struct ContextLine: View {
    let kind: String
    let crumbs: [LibraryModel.Crumb]
    var isGhost = false
    var onSelect: (SidebarItem) -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(kind)
                .dsText(.metaStrong)
                .foregroundStyle(isGhost ? DS.Tint.ghost : Color.secondary)
            if !crumbs.isEmpty { separator("·") }
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, crumb in
                if i > 0 { separator("›") }
                CrumbView(crumb: crumb, onSelect: onSelect)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func separator(_ s: String) -> some View {
        Text(s).dsText(.meta).foregroundStyle(.secondary)
    }

    private struct CrumbView: View {
        let crumb: LibraryModel.Crumb
        var onSelect: (SidebarItem) -> Void
        @State private var hovering = false

        var body: some View {
            if let target = crumb.target {
                Button { onSelect(target) } label: {
                    Text(crumb.title).dsText(.meta).underline(hovering).foregroundStyle(hovering ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            } else {
                Text(crumb.title).dsText(.meta).foregroundStyle(.secondary)
            }
        }
    }
}
