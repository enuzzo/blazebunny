import AppKit
import BlazebunnyCore

/// A folder the user has opened, remembered across launches.
struct SavedLibrary: Codable, Hashable, Identifiable {
    var path: String
    var bookmark: Data?
    /// A name the user chose. Display only: the folder itself is never renamed.
    var displayName: String?
    /// Set for ghost (temporary) libraries: where their index and thumbnails live.
    /// Never written to disk: a ghost is not remembered across launches.
    var ghostBase: URL?
    var isGhost: Bool { ghostBase != nil }
    private enum CodingKeys: String, CodingKey { case path, bookmark, displayName }
    var id: String { path }
    var folderName: String { (path as NSString).lastPathComponent }
    var name: String { displayName ?? folderName }
}

/// Built-in views every library offers in the sidebar.
enum BuiltInView: String, CaseIterable, Identifiable {
    case all, recent, generated, photos, screenshots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Images"
        case .recent: return "Recently Added"
        case .generated: return "Generated"
        case .photos: return "Photos"
        case .screenshots: return "Screenshots"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .recent: return "clock"
        case .generated: return "sparkles"
        case .photos: return "camera"
        case .screenshots: return "macwindow"
        }
    }
    var filter: FilterState {
        var f = FilterState()
        switch self {
        case .all: break
        case .recent: f.dateFrom = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .generated: f.sources = [.midjourney, .stableDiffusion]
        case .photos: f.sources = [.camera]
        case .screenshots: f.sources = [.screenshot]
        }
        return f
    }
}

/// What is selected in the sidebar.
enum SidebarItem: Hashable {
    case library(String)
    case view(BuiltInView)
    case saved(Int64)
    /// A folder of the open library, by its path relative to the library root.
    case folder(String)
}

/// The library's folder tree prepared for the sidebar: children sorted by name once, off the main thread.
struct FolderTree: Equatable {
    var nodes: [String: DirNode] = [:]
    /// Children by parent path ("" is the library root), shown folders only, alphabetical.
    var children: [String: [DirNode]] = [:]

    init() {}

    /// Folders that hold no image anywhere below them are left out: a folder of documents or an
    /// empty one would only add noise to an image browser.
    init(_ list: [DirNode]) {
        var byID: [Int64: DirNode] = [:]
        for n in list { byID[n.id] = n }
        for n in list {
            nodes[n.path] = n
            guard n.subtreeCount > 0 else { continue }
            let parentPath = n.parentID.flatMap { byID[$0]?.path } ?? ""
            children[parentPath, default: []].append(n)
        }
        for key in children.keys {
            children[key]!.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    var isEmpty: Bool { children.isEmpty }
}

/// One visible row of the Folders section.
struct FolderRow: Identifiable, Equatable {
    var node: DirNode
    var id: String { node.path }
    var hasChildren: Bool
    var isExpanded: Bool
}

/// Named colours for saved searches.
enum TagColor: String, CaseIterable {
    case orange, red, pink, purple, blue, teal, green, yellow, gray
    var color: NSColor {
        switch self {
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .teal: return .systemTeal
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .gray: return .systemGray
        }
    }
}
