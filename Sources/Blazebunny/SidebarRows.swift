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
                            .font(.system(size: DS.Size.microIcon + 1, weight: .semibold))
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
                .font(.system(size: DS.Size.sidebarGlyph))
                .frame(width: DS.Size.sidebarIcon, alignment: .center)
            title
                .dsText(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DS.Space.iconText)
            Spacer(minLength: DS.Space.s)
            if let count {
                Text(count.formatted())
                    .dsText(.meta, .number)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
