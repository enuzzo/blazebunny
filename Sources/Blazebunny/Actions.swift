import SwiftUI
import AppKit

/// The app's shared actions: one name and one icon each, so the same action looks the same
/// in the grid's context menu, the sidebar menus, the inspector and the menu bar. Icons are
/// SF Symbols for now; they move to the Iconoir set in the icons stage with no change here.
enum AppAction {
    case copyPrompt, copyText, copyParameters, copyPath
    case openDefault, showInFinder
    case rename, forgetLibrary, closeGhost, deleteSavedSearch, editSavedSearch
    // Planned: addToTray, addToCompare, addToCollection (tray and comparer stages).

    var title: String {
        switch self {
        case .copyPrompt: return "Copy Prompt"
        case .copyText: return "Copy Text Only"
        case .copyParameters: return "Copy Parameters"
        case .copyPath: return "Copy Path"
        case .openDefault: return "Open in Default App"
        case .showInFinder: return "Show in Finder"
        case .rename: return "Rename…"
        case .forgetLibrary: return "Forget Library…"
        case .closeGhost: return "Close Ghost"
        case .deleteSavedSearch: return "Delete…"
        case .editSavedSearch: return "Edit…"
        }
    }

    var symbol: String {
        switch self {
        case .copyPrompt: return "doc.on.doc"
        case .copyText: return "text.alignleft"
        case .copyParameters: return "slider.horizontal.3"
        case .copyPath: return "link"
        case .openDefault: return "arrow.up.forward.app"
        case .showInFinder: return "folder"
        case .rename: return "pencil"
        case .forgetLibrary: return "trash"
        case .closeGhost: return "xmark.circle"
        case .deleteSavedSearch: return "trash"
        case .editSavedSearch: return "slider.horizontal.3"
        }
    }

    var nsImage: NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
}

/// A SwiftUI menu button with the action's title and icon.
func actionButton(_ action: AppAction, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
    Button(role: role, action: perform) { Label(action.title, systemImage: action.symbol) }
}
