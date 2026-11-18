import AppKit
import BlazebunnyCore

// The filter row: which groups show, and switching values on and off.
extension LibraryModel {

    /// Midjourney filters are shown when the view is about Midjourney images.
    var showsMidjourneyGroup: Bool {
        let f = query.filter
        if f.sources.contains(.midjourney) || !f.versions.isEmpty || !f.params.isEmpty { return true }
        if f.sources.isEmpty, let mj = sourceCounts[.midjourney], mj > 0 { return true }
        return false
    }

    var showsCameraGroup: Bool {
        let f = query.filter
        if f.sources.contains(.camera) || !f.cameras.isEmpty { return true }
        if f.sources.isEmpty, let c = sourceCounts[.camera], c > 0 { return true }
        return false
    }

    func toggle(_ facet: Facet, _ value: String) {
        var f = query.filter
        func flip<T: Hashable>(_ set: inout Set<T>, _ v: T) { if set.contains(v) { set.remove(v) } else { set.insert(v) } }
        switch facet {
        case .type: flip(&f.types, value)
        case .shape:
            if value.hasPrefix("o:"), let o = Orientation(rawValue: String(value.dropFirst(2))) { flip(&f.orientations, o) }
            if value.hasPrefix("r:") { flip(&f.ratios, String(value.dropFirst(2))) }
        case .source: if let s = ItemSource(rawValue: value) { flip(&f.sources, s) }
        case .version: flip(&f.versions, value)
        case .param: flip(&f.params, value)
        case .camera: flip(&f.cameras, value)
        case .date: break
        }
        query.filter = f
    }

    func isOn(_ facet: Facet, _ value: String) -> Bool {
        let f = query.filter
        switch facet {
        case .type: return f.types.contains(value)
        case .shape:
            if value.hasPrefix("o:") { return Orientation(rawValue: String(value.dropFirst(2))).map { f.orientations.contains($0) } ?? false }
            return f.ratios.contains(String(value.dropFirst(2)))
        case .source: return ItemSource(rawValue: value).map { f.sources.contains($0) } ?? false
        case .version: return f.versions.contains(value)
        case .param: return f.params.contains(value)
        case .camera: return f.cameras.contains(value)
        case .date: return false
        }
    }

    /// Adds one value to a filter (from a click in the inspector).
    func addFilter(_ facet: Facet, _ value: String) {
        if !isOn(facet, value) { toggle(facet, value) }
        if facet == .version || facet == .param { query.filter.sources.insert(.midjourney) }
        if facet == .camera { query.filter.sources.insert(.camera) }
    }

    func clear(_ facet: Facet) { query.filter.clear(facet) }
    func clearAll() { query.filter = FilterState(); query.text = "" }

    func setDateRange(from: Date?, to: Date?) {
        query.filter.dateFrom = from
        query.filter.dateTo = to
    }
}
