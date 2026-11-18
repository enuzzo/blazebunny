import AppKit
import BlazebunnyCore

// What the grid shows and where it is: the title and the context line above it.
extension LibraryModel {
    /// Title of what the grid shows.
    var viewTitle: String {
        switch sidebarSelection {
        case .view(let v): return v.title
        case .saved(let id): return savedSearches.first(where: { $0.id == id })?.name ?? currentLibraryName
        case .folder(let path): return (path as NSString).lastPathComponent
        default: return currentLibraryName
        }
    }

    /// One crumb of the context line above the title.
    struct Crumb: Identifiable {
        let id: String
        let title: String
        /// Where a click goes; nil for plain text.
        let target: SidebarItem?
    }

    /// What the grid shows and where it is, for the 11 pt line above the title.
    /// For a folder: "Folder · files › Renders" (the library, then the folders above this one).
    var contextKind: String {
        if currentIsGhost { return "Ghost · temporary" }
        switch sidebarSelection {
        case .folder: return "Folder"
        case .saved: return "Saved search"
        case .view: return "View"
        default: return "Library"
        }
    }

    var contextCrumbs: [Crumb] {
        guard let path = currentPath else { return [] }
        let libCrumb = Crumb(id: "lib", title: currentLibraryName, target: .library(path))
        switch sidebarSelection {
        case .folder(let p):
            var crumbs = [libCrumb]
            var acc = ""
            for part in p.split(separator: "/").dropLast() {
                acc = acc.isEmpty ? String(part) : acc + "/" + part
                crumbs.append(Crumb(id: acc, title: String(part), target: .folder(acc)))
            }
            return crumbs
        case .saved:
            var crumbs = [Crumb(id: "in", title: "live · in " + currentLibraryName, target: .library(path))]
            if let f = query.folder { crumbs.append(Crumb(id: "f", title: f.replacingOccurrences(of: "/", with: " › "), target: .folder(f))) }
            return crumbs
        case .view:
            return [Crumb(id: "in", title: "in " + currentLibraryName, target: .library(path))]
        default:
            return [Crumb(id: "all", title: "everything, subfolders included", target: nil)]
        }
    }
}
