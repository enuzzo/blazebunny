import Foundation
import BlazebunnyCore

/// What the grid shows, prepared off the main thread: the items, their month sections and a lookup
/// from id to position. The grid compares two numbers to know what changed, never the arrays.
struct GridSnapshot: Sendable {
    struct Section: Sendable, Equatable {
        var title: String
        var range: Range<Int>
    }

    private(set) var items: [BrowseItem] = []
    private(set) var sections: [Section] = []
    private(set) var sectioned = true
    private var positions: [Int64: Int32] = [:]
    /// Changes when the list of ids, their order or the sections change: the grid reloads.
    private(set) var structure = 0
    /// Changes with every new snapshot: when only this one moved, cells are refreshed in place.
    private(set) var revision = 0
    /// Changes when the user asked for something else (folder, filter, search, sort): the grid goes
    /// back to the top. A reload during a scan keeps it, and the scroll position with it.
    private(set) var view = 0

    init() {}

    /// Empties the grid, keeping the counters moving so the grid notices.
    mutating func clear() {
        items = []
        sections = []
        positions = [:]
        structure += 1
        revision += 1
    }

    /// The snapshot for `items`, or nil when nothing changed since `previous`. O(n), so call it off
    /// the main thread.
    static func make(items: [BrowseItem], sectioned: Bool, view: Int, previous: GridSnapshot) -> GridSnapshot? {
        if previous.view == view, previous.sectioned == sectioned, previous.items == items { return nil }
        var next = GridSnapshot()
        next.items = items
        next.sectioned = sectioned
        next.view = view
        next.revision = previous.revision + 1
        if sectioned {
            next.sections = MonthSections.split(items.lazy.map(\.sortDate)).map {
                Section(title: monthTitle.string(from: $0.monthStart), range: $0.range)
            }
        } else if !items.isEmpty {
            next.sections = [Section(title: "", range: 0..<items.count)]
        }
        let sameOrder = previous.view == view && previous.sectioned == sectioned && previous.sections == next.sections
            && previous.items.count == items.count && zip(previous.items, items).allSatisfy { $0.id == $1.id }
        if sameOrder {
            next.structure = previous.structure
            next.positions = previous.positions
        } else {
            next.structure = previous.structure + 1
            next.positions.reserveCapacity(items.count)
            for (i, item) in items.enumerated() { next.positions[item.id] = Int32(i) }
        }
        return next
    }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    func position(ofID id: Int64) -> Int? { positions[id].map(Int.init) }

    func item(at path: IndexPath) -> BrowseItem? {
        guard path.section < sections.count else { return nil }
        let i = sections[path.section].range.lowerBound + path.item
        return i < items.count ? items[i] : nil
    }

    func position(of path: IndexPath) -> Int? {
        guard path.section < sections.count else { return nil }
        return sections[path.section].range.lowerBound + path.item
    }

    func indexPath(ofPosition i: Int) -> IndexPath? {
        guard i >= 0, i < items.count else { return nil }
        // Sections are in order and cover every item: find the one that holds `i`.
        var lo = 0, hi = sections.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sections[mid].range.lowerBound <= i { lo = mid } else { hi = mid - 1 }
        }
        guard lo < sections.count, sections[lo].range.contains(i) else { return nil }
        return IndexPath(item: i - sections[lo].range.lowerBound, section: lo)
    }

    func indexPath(ofID id: Int64) -> IndexPath? {
        position(ofID: id).flatMap(indexPath(ofPosition:))
    }

    /// Items per source, for the filter row's groups.
    func sourceCounts() -> [ItemSource: Int] {
        var out: [ItemSource: Int] = [:]
        for item in items { if let s = item.source { out[s, default: 0] += 1 } }
        return out
    }
}
