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
                    Divider().frame(height: 20)
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
            Divider().frame(height: 20)
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
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
                model.openFacet = facet
                model.loadFacet(facet)
            } label: {
                HStack(spacing: 4) {
                    Text(on ? "\(title):" : title)
                        .foregroundStyle(on ? tint.opacity(0.85) : .secondary)
                    if on {
                        Text(vals.count > 2 ? vals.prefix(2).joined(separator: ", ") + " +\(vals.count - 2)" : vals.joined(separator: ", "))
                            .fontWeight(.medium)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, DS.Space.m - 2)
                .padding(.trailing, on ? DS.Space.xs : DS.Space.m - 2)
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
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: DS.Size.control)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint.opacity(0.8))
                .help("Clear \(title)")
                .accessibilityLabel("Clear \(title)")
            }
        }
        .font(.callout)
        .background {
            Capsule().fill(on ? tint.opacity(0.15) : .clear)
            Capsule().strokeBorder(on ? .clear : Color.primary.opacity(0.14))
        }
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
                Text(title).font(.headline)
                Spacer()
                Text(facet == .param ? "all of" : facet == .date ? "embedded date, else file date" : "any of")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            content
        }
        .frame(width: facet == .date ? 360 : 280)
    }

    @ViewBuilder var content: some View {
        if facet == .date {
            DatePopoverContent(model: model)
        } else {
            let values = model.facetValues[facet] ?? []
            if values.isEmpty {
                Text("No values in this view.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else if facet == .shape {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Orientation", values.filter { $0.value.hasPrefix("o:") }.sorted { orientationRank($0.value) < orientationRank($1.value) })
                        Divider().padding(.vertical, 4)
                        section("Exact ratio", values.filter { $0.value.hasPrefix("r:") })
                    }
                    .padding(6)
                }
                .frame(height: min(420, CGFloat(values.count) * DS.Size.control + 3 * DS.Size.control))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(values, id: \.value) { v in row(v) }
                    }
                    .padding(6)
                }
                .frame(height: min(420, CGFloat(values.count) * DS.Size.control + 12))
            }
        }
    }

    func orientationRank(_ v: String) -> Int {
        ["o:portrait", "o:landscape", "o:square", "o:wide"].firstIndex(of: v) ?? 9
    }

    func section(_ title: String, _ values: [FacetValue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(values, id: \.value) { v in row(v) }
        }
    }

    func row(_ v: FacetValue) -> some View {
        let on = model.isOn(facet, v.value)
        return Button {
            model.toggle(facet, v.value)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? tint : .secondary)
                    .font(.system(size: 14))
                glyph(v.value)
                Text(FacetLabel.label(facet, v.value))
                    .font(facet == .param || (facet == .shape && v.value.hasPrefix("r:")) ? .callout.monospaced() : .callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(v.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(height: DS.Size.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(on ? tint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder func glyph(_ value: String) -> some View {
        if facet == .source, let s = ItemSource(rawValue: value) {
            Image(systemName: s.symbol).frame(width: 18).foregroundStyle(.secondary)
        } else if facet == .shape, value.hasPrefix("o:") {
            let size: CGSize = switch value {
            case "o:portrait": CGSize(width: 9, height: 13)
            case "o:landscape": CGSize(width: 13, height: 9)
            case "o:square": CGSize(width: 11, height: 11)
            default: CGSize(width: 15, height: 7)
            }
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(.secondary, lineWidth: 1.5)
                .frame(width: size.width, height: size.height)
                .frame(width: 18)
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
        VStack(alignment: .leading, spacing: 12) {
            if months.isEmpty {
                Text("No dates in this view.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 64)
            } else {
                bars
                HStack {
                    Text(label(months.first!.month)).font(.caption2)
                    Spacer()
                    Text(label(months.last!.month)).font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
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
        .padding(12)
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
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.22))
                    .frame(height: max(3, 72 * CGFloat(m.count) / CGFloat(maxCount)))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(label(m.month)): \(m.count.formatted()) images")
                    .onTapGesture { pick(i, extend: NSEvent.modifierFlags.contains(.shift)) }
            }
        }
        .frame(height: 72, alignment: .bottom)
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

/// Name, colour and folder for a new or edited saved search.
struct SaveSearchSheet: View {
    let model: LibraryModel
    let existing: SavedSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: TagColor = .orange
    @State private var folder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Save Search" : "Edit Saved Search").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Portraits, v7 raw"))
                HStack {
                    Text("Colour")
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(TagColor.allCases, id: \.self) { c in
                            Circle().fill(Color(nsColor: c.color))
                                .frame(width: 16, height: 16)
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
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
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
        .padding(20)
        .frame(width: 380)
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
        if !model.query.text.isEmpty { parts.append("“\(model.query.text)”") }
        if !f.types.isEmpty { parts.append(f.types.sorted().joined(separator: " or ")) }
        if f.hasShape { parts.append((f.orientations.map(\.title).sorted() + f.ratios.sorted()).joined(separator: " or ")) }
        if f.hasDate { parts.append(DateLabel.range(f.dateFrom, f.dateTo)) }
        if !f.sources.isEmpty { parts.append(f.sources.map(\.title).sorted().joined(separator: " or ")) }
        if !f.versions.isEmpty { parts.append(f.versions.sorted().map(FacetLabel.version).joined(separator: " or ")) }
        if !f.params.isEmpty { parts.append(f.params.sorted().map { "--" + $0 }.joined(separator: " and ")) }
        if !f.cameras.isEmpty { parts.append(f.cameras.sorted().joined(separator: " or ")) }
        return parts.isEmpty ? "All images, \(model.query.sort.title.lowercased())." : parts.joined(separator: " · ") + " · " + model.query.sort.title
    }
}
