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
    private var folderPath: String? { model.currentLibrary?.path }

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
            if model.currentIsGhost {
                GhostBadge().padding(.bottom, DS.Space.s)
            }
            Text(model.viewTitle)
                .dsText(.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Number and unit read as one phrase on one baseline. The mono's separator takes a
            // whole character cell, so it is pulled in to keep "23.193" from reading as "23 . 193".
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(Self.tightened(s.total.formatted(), kern: -0.3 * DS.TextStyle.display.size))
                    .dsText(.display, .number)
                Text(s.total == 1 ? "image" : "images")
                    .dsText(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A number with its group separators pulled in. The mono gives a separator a whole
    /// character cell; the squeeze is split before and after it so the dot stays centred
    /// in the narrower gap instead of touching the next digit.
    static func tightened(_ number: String, kern: CGFloat) -> AttributedString {
        let chars = Array(number)
        var out = AttributedString()
        for (i, ch) in chars.enumerated() {
            var piece = AttributedString(String(ch))
            let nextIsSeparator = i + 1 < chars.count && !chars[i + 1].isNumber
            if !ch.isNumber || nextIsSeparator { piece.kern = kern / 2 }
            out += piece
        }
        return out
    }

    func breakdown(_ title: String, _ values: [FacetValue], label: @escaping (String) -> String) -> some View {
        let top = values.prefix(6)
        let maxCount = max(1, top.map(\.count).max() ?? 1)
        // One fixed width for every count in the table, sized for the longest one, so each bar
        // starts and ends at the same x whatever its own number looks like.
        let digits = top.map { $0.count.formatted().count }.max() ?? 1
        let countWidth = CGFloat(digits) * DS.Size.monoDigitWidth
        return InfoTable(title: title) {
            ForEach(Array(top), id: \.value) { v in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(label(v.value)).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    // Neutral bar on a faint track: it shows proportion, not selection.
                    ZStack(alignment: .trailing) {
                        Capsule().fill(DS.Palette.dataTrack)
                        Capsule().fill(DS.Palette.dataBar)
                            .frame(width: max(2, DS.Size.dataBar * CGFloat(v.count) / CGFloat(maxCount)))
                    }
                    .frame(width: DS.Size.dataBar, height: DS.Size.dataBarHeight)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    Text(v.count.formatted())
                        .dsText(.label, .number)
                        .frame(width: countWidth, alignment: .trailing)
                }
                .dsText(.label)
                .frame(minHeight: DS.Size.control)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.rowRule).frame(height: 1) }
            }
        }
    }

    var details: some View {
        InfoTable(title: "Details") {
            InfoRow(label: "Size") { Text(ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)).dsText(.label, .number) }
            if let range = dateRange { InfoRow(label: "Dates") { Text(range).dsText(.label, .number) } }
            InfoRow(label: "With prompt") { Text(s.withPrompt.formatted()).dsText(.label, .number) }
            if model.currentIsGhost {
                InfoRow(label: "Ghost") { Text("Temporary index").foregroundStyle(DS.Tint.ghost).help(GhostText.explanation) }
            }
            if isWholeLibrary, !model.currentIsGhost, let created = model.libraryCreatedAt {
                InfoRow(label: "Added") { Text(created.formatted(date: .abbreviated, time: .omitted)).dsText(.label, .number) }
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
