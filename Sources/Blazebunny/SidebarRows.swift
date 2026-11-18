import SwiftUI
import AppKit
import BlazebunnyCore

/// Turns off the sidebar table's own grey selection, so `SidebarRowChrome` can draw the tinted one.
struct SidebarTableTweaks: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TweakView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? TweakView)?.apply() }

    final class TweakView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            var ancestor: NSView? = self
            while let current = ancestor {
                if let table = Self.findTable(in: current) {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = current.superview
            }
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let t = findTable(in: sub) { return t } }
            return nil
        }
    }
}

/// The content of one sidebar row: chevron column, 20 pt icon column, 10 pt gap, title, count.
/// Colour is on the icon; the title keeps the primary colour and the count is the mono, secondary.
struct SidebarRowContent<Icon: View, Title: View>: View {
    var depth = 0
    /// Folders only: keep a chevron column in front of the icon, even when this row has no chevron,
    /// so icons of folders with and without subfolders line up. Other rows start with the icon.
    var chevronColumn = false
    /// nil: no chevron. true: open. false: closed.
    var expanded: Bool?
    var count: Int?
    /// Shown at the trailing edge instead of `count` (a view that reads its own number, so a change
    /// of that number redraws it alone).
    var accessory: AnyView?
    var onToggle: () -> Void = {}
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * DS.Size.sidebarIndent, height: 1)
            if chevronColumn { ZStack {
                if let expanded {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.right")
                            .dsIcon(DS.Size.microIcon + 1, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.2), value: expanded)
                            .frame(width: DS.Size.sidebarChevron, height: DS.Size.sidebarRow)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse" : "Expand")
                }
            }
            .frame(width: DS.Size.sidebarChevron) }
            icon
                .dsIcon(DS.Size.sidebarGlyph)
                .frame(width: DS.Size.sidebarIcon, alignment: .center)
            title
                .dsText(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DS.Space.iconText)
            Spacer(minLength: DS.Space.s)
            if let accessory {
                accessory
            } else if let count {
                SidebarCount(count)
            }
        }
    }
}

/// A count at the trailing edge of a sidebar row: the mono, secondary.
struct SidebarCount: View {
    let value: Int
    init(_ value: Int) { self.value = value }
    var body: some View {
        Text(value.formatted())
            .dsText(.meta, .number)
            .foregroundStyle(.secondary)
    }
}

/// The image count of the open library. It reads the count itself, so the count ticking up during a
/// scan redraws this number and not the whole sidebar.
struct LibraryCount: View {
    let model: LibraryModel
    let path: String
    var body: some View {
        if path == model.currentPath, model.counts.total > 0 { SidebarCount(model.counts.total) }
    }
}

/// Tells a sidebar row about clicks without taking part in them.
///
/// A SwiftUI tap gesture on a list row competes with the list's own mouse handling: the list
/// has to wait for the gesture to fail before it can select the row or start dragging it, which made
/// reordering libraries by drag work only some of the time. This view sits behind the row, is never
/// hit, and only watches mouse-down events as they pass through the app, so selection, drag and the
/// context menu stay entirely the list's. A press with a click count of two is a double click; a
/// single press is reported with where it happened, for the slow-click rename.
struct RowClicks: NSViewRepresentable {
    var onPress: (_ screenPoint: NSPoint) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.onPress = onPress
        view.onDoubleClick = onDoubleClick
    }

    final class Watcher: NSView {
        var onPress: ((NSPoint) -> Void)?
        var onDoubleClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The monitor lives while the view is in a window (a view leaves its window before it goes away).
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.see(event)
                return event
            }
        }

        private func see(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.clickCount == 2 {
                onDoubleClick?()
            } else if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty {
                onPress?(NSEvent.mouseLocation)
            }
        }
    }
}
