import Foundation

/// Every filter the browser can apply. OR inside a facet, AND across facets;
/// Midjourney parameters are all-of. Codable so saved searches can store it.
public struct FilterState: Codable, Hashable, Sendable {
    public var types: Set<String> = []
    public var orientations: Set<Orientation> = []
    public var ratios: Set<String> = []
    public var dateFrom: Date?
    public var dateTo: Date?
    public var sources: Set<ItemSource> = []
    public var versions: Set<String> = []
    public var params: Set<String> = []
    public var cameras: Set<String> = []

    public init() {}

    public var isEmpty: Bool { self == FilterState() }
    public var hasShape: Bool { !orientations.isEmpty || !ratios.isEmpty }
    public var hasDate: Bool { dateFrom != nil || dateTo != nil }

    public mutating func clear(_ facet: Facet) {
        switch facet {
        case .type: types = []
        case .shape: orientations = []; ratios = []
        case .date: dateFrom = nil; dateTo = nil
        case .source: sources = []
        case .version: versions = []
        case .param: params = []
        case .camera: cameras = []
        }
    }

    // Tolerant decoding: a saved search written by another version keeps working.
    enum CodingKeys: String, CodingKey { case types, orientations, ratios, dateFrom, dateTo, sources, versions, params, cameras }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        types = (try? c.decode(Set<String>.self, forKey: .types)) ?? []
        orientations = Set(((try? c.decode([String].self, forKey: .orientations)) ?? []).compactMap(Orientation.init(rawValue:)))
        ratios = (try? c.decode(Set<String>.self, forKey: .ratios)) ?? []
        dateFrom = try? c.decode(Date.self, forKey: .dateFrom)
        dateTo = try? c.decode(Date.self, forKey: .dateTo)
        sources = Set(((try? c.decode([String].self, forKey: .sources)) ?? []).compactMap(ItemSource.init(rawValue:)))
        versions = (try? c.decode(Set<String>.self, forKey: .versions)) ?? []
        params = (try? c.decode(Set<String>.self, forKey: .params)) ?? []
        cameras = (try? c.decode(Set<String>.self, forKey: .cameras)) ?? []
    }
}

/// The groups the filter row offers; each one is a pill.
public enum Facet: String, CaseIterable, Sendable {
    case type, shape, date, source, version, param, camera
}

public struct FacetValue: Hashable, Sendable {
    public var value: String
    public var count: Int
}

/// What a library, view or saved search holds, at a glance.
public struct LibrarySummary: Equatable, Sendable {
    public var total = 0
    public var totalBytes: Int64 = 0
    public var withPrompt = 0
    /// Embedded or file dates of the oldest and newest item.
    public var oldest: Date?
    public var newest: Date?
    /// Items per file kind ("png", "jpeg"…), most common first.
    public var kinds: [FacetValue] = []
    /// Items per detected source, most common first.
    public var sources: [FacetValue] = []
    public init() {}
}

public struct MonthCount: Hashable, Sendable {
    /// "2025-03"
    public var month: String
    public var count: Int
}

/// Text, filters and order: everything a saved search remembers.
public struct SearchQuery: Codable, Hashable, Sendable {
    public var text: String = ""
    public var filter = FilterState()
    public var sort: ItemSort = .newestFirst
    /// Limits the query to one folder (relative path, "/"-separated) and everything below it.
    /// A path, not an id, so it survives a rebuilt folder table.
    public var folder: String?
    public init(text: String = "", filter: FilterState = FilterState(), sort: ItemSort = .newestFirst, folder: String? = nil) {
        self.text = text
        self.filter = filter
        self.sort = sort
        self.folder = folder
    }
    enum CodingKeys: String, CodingKey { case text, filter, sort, folder }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        filter = (try? c.decode(FilterState.self, forKey: .filter)) ?? FilterState()
        sort = (try? c.decode(ItemSort.self, forKey: .sort)) ?? .newestFirst
        folder = try? c.decode(String.self, forKey: .folder)
    }
}

public struct SavedSearch: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var name: String
    /// A named colour: orange, blue, purple, green, pink, yellow, gray.
    public var color: String
    public var folder: String?
    public var position: Int
    public var query: SearchQuery
}

/// The facet key of a Midjourney parameter: numeric style knobs keep their
/// value ("stylize 250"), everything else is the flag name ("raw", "sref").
public func paramFacetKey(_ p: PromptParameter) -> String {
    let valued: Set<String> = ["stylize", "s", "chaos", "c", "weird", "w", "quality", "q", "style", "exp"]
    let name = ["s": "stylize", "c": "chaos", "w": "weird", "q": "quality"][p.name] ?? p.name
    if valued.contains(p.name), !p.value.isEmpty { return "\(name) \(p.value)" }
    return name
}
