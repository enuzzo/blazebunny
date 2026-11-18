import SwiftUI
import BlazebunnyCore

/// The row of filter pills under the toolbar. OR inside a pill, AND across.
struct FilterRow: View {
    @Bindable var model: LibraryModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                pill(.type)
                pill(.shape)
                pill(.date)
                pill(.source)
                if model.showsMidjourneyGroup {
                    FilterGroup(title: "Midjourney", symbol: ItemSource.midjourney.symbol, tint: DS.Tint.midjourney) {
                        pill(.version, tint: DS.Tint.midjourney)
                        pill(.param, tint: DS.Tint.midjourney)
                    }
                }
                if model.showsCameraGroup {
                    FilterGroup(title: "Camera", symbol: ItemSource.camera.symbol, tint: DS.Tint.camera) {
                        pill(.camera, tint: DS.Tint.camera)
                    }
                }
                if !model.query.filter.isEmpty || !model.query.text.isEmpty {
                    Divider().frame(height: DS.Size.pillRule)
                    Button("Clear All") { model.clearAll() }
                        .buttonStyle(PillStyle())
                        .help("Remove every filter and the search text (⇧⌘⌫)")
                }
            }
            .padding(.horizontal, DS.Space.l)
        }
        .frame(height: DS.Size.filterRow)
    }

    func pill(_ facet: Facet, tint: Color = .accentColor) -> some View {
        FilterPill(model: model, facet: facet, tint: tint)
    }
}

struct FilterGroup<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Divider().frame(height: DS.Size.pillRule)
            // Not a control: only its icon carries the tint, so it never reads as an active filter.
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .dsText(.metaStrong)
            .fixedSize()
            content
        }
    }
}

struct FilterPill: View {
    @Bindable var model: LibraryModel
    let facet: Facet
    var tint: Color = .accentColor

    var title: String {
        switch facet {
        case .type: return "Type"
        case .shape: return "Shape"
        case .date: return "Date"
        case .source: return "Source"
        case .version: return "Version"
        case .param: return "Parameters"
        case .camera: return "Camera"
        }
    }

    /// Selected values as shown in the pill.
    var values: [String] {
        let f = model.query.filter
        switch facet {
        case .type: return f.types.sorted().map { ItemKind(rawValue: $0)?.title ?? $0 }
        case .shape: return f.orientations.map(\.title).sorted() + f.ratios.sorted()
        case .date: return f.hasDate ? [DateLabel.range(f.dateFrom, f.dateTo)] : []
        case .source: return f.sources.map(\.title).sorted()
        case .version: return f.versions.sorted().map(FacetLabel.version)
        case .param: return f.params.sorted().map { "--" + $0 }
        case .camera: return f.cameras.sorted()
        }
    }

    var isPresented: Binding<Bool> {
        Binding(get: { model.openFacet == facet }, set: { if !$0, model.openFacet == facet { model.openFacet = nil } })
    }

    var body: some View {
        let vals = values
        let on = !vals.isEmpty
        HStack(spacing: 0) {
            Button {
                // The pill toggles its popover: pressing it again closes it.
                if model.openFacet == facet {
                    model.openFacet = nil
                } else {
                    model.openFacet = facet
                    model.loadFacet(facet)
                }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(on ? "\(title):" : title)
                        .foregroundStyle(.secondary)
                    if on {
                        Text(vals.count > 2 ? vals.prefix(2).joined(separator: ", ") + " +\(vals.count - 2)" : vals.joined(separator: ", "))
                            .dsText(.labelStrong)
                            .foregroundStyle(tint == .accentColor ? DS.Tint.activeText : tint)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "chevron.down").dsIcon(DS.Size.microIcon, weight: .semibold).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, DS.Space.pillInset)
                .padding(.trailing, on ? DS.Space.xs : DS.Space.pillInset)
                .frame(height: DS.Size.control)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? "\(title): \(vals.joined(separator: ", "))" : title)
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                FacetPopover(model: model, facet: facet, title: title, tint: tint)
            }
            if on {
                Button { model.clear(facet) } label: {
                    Image(systemName: "xmark").dsIcon(DS.Size.microIcon, weight: .bold)
                        .frame(width: DS.Size.pillClear, height: DS.Size.control)
                        .padding(.trailing, DS.Space.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear \(title)")
                .accessibilityLabel("Clear \(title)")
            }
        }
        // The same capsule as every other control in the row (`PillStyle`).
        .pillChrome(isOn: on, tint: tint)
    }
}

enum FacetLabel {
    static func version(_ v: String) -> String { v.hasPrefix("niji") ? v : "v" + v }

    static func label(_ facet: Facet, _ value: String) -> String {
        switch facet {
        case .type: return ItemKind(rawValue: value)?.title ?? value
        case .source: return ItemSource(rawValue: value)?.title ?? value
        case .version: return version(value)
        case .param: return "--" + value
        case .shape:
            if value.hasPrefix("o:") { return Orientation(rawValue: String(value.dropFirst(2)))?.title ?? value }
            return String(value.dropFirst(2))
        default: return value
        }
    }
}

enum DateLabel {
    static let month: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()

    static func range(_ from: Date?, _ to: Date?) -> String {
        switch (from, to) {
        case let (f?, t?): return "\(day.string(from: f)) – \(day.string(from: t.addingTimeInterval(-1)))"
        case let (f?, nil): return "since \(day.string(from: f))"
        case let (nil, t?): return "before \(day.string(from: t))"
        default: return ""
        }
    }
}

/// The list inside a pill's popover: checkboxes with counts.
struct FacetPopover: View {
    @Bindable var model: LibraryModel
    let facet: Facet
    let title: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).dsText(.headline)
                Spacer()
                Text(facet == .param ? "all of" : facet == .date ? "embedded date, else file date" : "any of")
                    .dsText(.meta).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            Divider()
            content
        }
        .frame(width: facet == .date ? DS.Size.popoverWide : DS.Size.popover)
        .presentationBackground(DS.Palette.glassFillSolid)
    }

    @ViewBuilder var content: some View {
        if facet == .date {
            DatePopoverContent(model: model)
        } else {
            let values = model.facetValues[facet] ?? []
            if values.isEmpty {
                Text("No values in this view.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: DS.Size.placeholder)
            } else if facet == .shape {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Orientation", values.filter { $0.value.hasPrefix("o:") }.sorted { orientationRank($0.value) < orientationRank($1.value) })
                        Divider().padding(.vertical, DS.Space.xs)
                        section("Exact ratio", values.filter { $0.value.hasPrefix("r:") })
                    }
                    .padding(DS.Space.iconGap)
                }
                .frame(height: min(DS.Size.popoverMaxHeight, CGFloat(values.count) * DS.Size.control + 3 * DS.Size.control))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(values, id: \.value) { v in row(v) }
                    }
                    .padding(DS.Space.iconGap)
                }
                .frame(height: min(DS.Size.popoverMaxHeight, CGFloat(values.count) * DS.Size.control + 2 * DS.Space.iconGap))
            }
        }
    }

    func orientationRank(_ v: String) -> Int {
        ["o:portrait", "o:landscape", "o:square", "o:wide"].firstIndex(of: v) ?? 9
    }

    func section(_ title: String, _ values: [FacetValue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).dsText(.metaStrong).foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            ForEach(values, id: \.value) { v in row(v) }
        }
    }

    func row(_ v: FacetValue) -> some View {
        let on = model.isOn(facet, v.value)
        return Button {
            model.toggle(facet, v.value)
        } label: {
            HStack(spacing: DS.Space.iconText) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? tint : .secondary)
                    .dsText(.body)
                glyph(v.value)
                Text(FacetLabel.label(facet, v.value))
                    .dsText(.label, facet == .param || (facet == .shape && v.value.hasPrefix("r:")) ? .number : .text)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Text(v.count.formatted())
                    .dsText(.meta, .number)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: DS.Size.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "Selected" : "Not selected")
        .accessibilityAddTraits(on ? .isSelected : [])
        .background(on ? tint.opacity(DS.Tint.fill) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.medium))
    }

    @ViewBuilder func glyph(_ value: String) -> some View {
        if facet == .source, let s = ItemSource(rawValue: value) {
            Image(systemName: s.symbol).frame(width: DS.Size.glyphColumn).foregroundStyle(.secondary)
        } else if facet == .shape, value.hasPrefix("o:") {
            let size: CGSize = switch value {
            case "o:portrait": CGSize(width: 9, height: 13)
            case "o:landscape": CGSize(width: 13, height: 9)
            case "o:square": CGSize(width: 11, height: 11)
            default: CGSize(width: 15, height: 7)
            }
            RoundedRectangle(cornerRadius: DS.Radius.hair)
                .strokeBorder(.secondary, lineWidth: 1.5)
                .frame(width: size.width, height: size.height)
                .frame(width: DS.Size.glyphColumn)
        }
    }
}

/// Month histogram with presets. Click a bar for that month, Shift-click to extend.
struct DatePopoverContent: View {
    @Bindable var model: LibraryModel
    @State private var anchor: Int?
    @State private var customFrom = Date()
    @State private var customTo = Date()

    var months: [MonthCount] { model.histogram }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if months.isEmpty {
                Text("No dates in this view.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: DS.Size.placeholder)
            } else {
                bars
                HStack {
                    Text(label(months.first!.month)).dsText(.caption)
                    Spacer()
                    Text(label(months.last!.month)).dsText(.caption)
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Space.iconGap) {
                preset("Last 30 days") { (Calendar.current.date(byAdding: .day, value: -30, to: Date()), nil) }
                preset("This year") { (Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date()))), nil) }
                preset("Last year") {
                    let y = Calendar.current.component(.year, from: Date())
                    return (Calendar.current.date(from: DateComponents(year: y - 1)), Calendar.current.date(from: DateComponents(year: y)))
                }
            }
            HStack {
                DatePicker("From", selection: $customFrom, displayedComponents: .date).labelsHidden()
                Text("–").foregroundStyle(.secondary)
                DatePicker("To", selection: $customTo, displayedComponents: .date).labelsHidden()
                Button("Apply") {
                    model.setDateRange(from: Calendar.current.startOfDay(for: customFrom),
                                       to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customTo)))
                }
            }
            .controlSize(.small)
        }
        .padding(DS.Space.m)
        .onAppear {
            customFrom = model.query.filter.dateFrom ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())!
            customTo = model.query.filter.dateTo?.addingTimeInterval(-1) ?? Date()
        }
    }

    var bars: some View {
        let maxCount = max(1, months.map(\.count).max() ?? 1)
        return HStack(alignment: .bottom, spacing: months.count > 40 ? 1 : 2) {
            ForEach(Array(months.enumerated()), id: \.element.month) { i, m in
                let selected = isSelected(m.month)
                RoundedRectangle(cornerRadius: DS.Radius.hair)
                    .fill(selected ? Color.accentColor : DS.Palette.histogramBar)
                    .frame(height: max(3, DS.Size.histogram * CGFloat(m.count) / CGFloat(maxCount)))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(label(m.month)): \(m.count.formatted()) images")
                    .onTapGesture { pick(i, extend: NSEvent.modifierFlags.contains(.shift)) }
            }
        }
        .frame(height: DS.Size.histogram, alignment: .bottom)
    }

    func monthStart(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1]))
    }

    func label(_ s: String) -> String { monthStart(s).map { DateLabel.month.string(from: $0) } ?? s }

    func isSelected(_ s: String) -> Bool {
        guard let start = monthStart(s), model.query.filter.hasDate else { return false }
        let from = model.query.filter.dateFrom.flatMap { Calendar.current.dateInterval(of: .month, for: $0)?.start } ?? .distantPast
        let to = model.query.filter.dateTo ?? .distantFuture
        return start >= from && start < to
    }

    func pick(_ i: Int, extend: Bool) {
        let a = extend ? (anchor ?? i) : i
        if !extend { anchor = i }
        let lo = min(a, i), hi = max(a, i)
        guard let from = monthStart(months[lo].month), let toStart = monthStart(months[hi].month) else { return }
        model.setDateRange(from: from, to: Calendar.current.date(byAdding: .month, value: 1, to: toStart))
    }

    func preset(_ title: String, _ range: @escaping () -> (Date?, Date?)) -> some View {
        Button(title) { let r = range(); model.setDateRange(from: r.0, to: r.1) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// Name, color and folder for a new or edited saved search.
struct SaveSearchSheet: View {
    let model: LibraryModel
    let existing: SavedSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: TagColor = .orange
    @State private var folder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(existing == nil ? "Save Search" : "Edit Saved Search").dsText(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Portraits, v7 raw"))
                HStack {
                    Text("Color")
                    Spacer()
                    HStack(spacing: DS.Space.iconGap) {
                        ForEach(TagColor.allCases, id: \.self) { c in
                            Circle().fill(Color(nsColor: c.color))
                                .frame(width: DS.Size.swatch, height: DS.Size.swatch)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: color == c ? 2 : 0).padding(-3))
                                .onTapGesture { color = c }
                                .accessibilityLabel(c.rawValue)
                                .accessibilityAddTraits(color == c ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                HStack {
                    TextField("Folder", text: $folder, prompt: Text("Optional"))
                    if !model.savedFolders.isEmpty {
                        Menu {
                            ForEach(model.savedFolders, id: \.self) { f in Button(f) { folder = f } }
                        } label: { Image(systemName: "folder") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .formStyle(.columns)
            if existing == nil {
                Text(summary).dsText(.meta).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Save" : "Done") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if let e = existing { model.renameSavedSearch(e.id, name: n, color: color, folder: folder) }
                    else { model.saveCurrentSearch(name: n, color: color, folder: folder) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.sheet)
        .frame(width: DS.Size.sheet)
        .onAppear {
            if let e = existing {
                name = e.name
                color = TagColor(rawValue: e.color) ?? .orange
                folder = e.folder ?? ""
            }
        }
    }

    var summary: String {
        let f = model.query.filter
        var parts: [String] = []
        if let folder = model.query.folder { parts.append("in " + folder.replacingOccurrences(of: "/", with: " › ")) }
        if !model.query.text.isEmpty { parts.append("“\(model.query.text)”") }
        if !f.types.isEmpty { parts.append(f.types.sorted().joined(separator: " or ")) }
        if f.hasShape { parts.append((f.orientations.map(\.title).sorted() + f.ratios.sorted()).joined(separator: " or ")) }
        if f.hasDate { parts.append(DateLabel.range(f.dateFrom, f.dateTo)) }
        if !f.sources.isEmpty { parts.append(f.sources.map(\.title).sorted().joined(separator: " or ")) }
        if !f.versions.isEmpty { parts.append(f.versions.sorted().map(FacetLabel.version).joined(separator: " or ")) }
        if !f.params.isEmpty { parts.append(f.params.sorted().map { "--" + $0 }.joined(separator: " and ")) }
        if !f.cameras.isEmpty { parts.append(f.cameras.sorted().joined(separator: " or ")) }
        if model.query.folder != nil, parts.count == 1 { return parts[0] + " · " + model.query.sort.title }
        return parts.isEmpty ? "All images, \(model.query.sort.title.lowercased())." : parts.joined(separator: " · ") + " · " + model.query.sort.title
    }
}
