import SwiftUI
import AppKit

/// Blazebunny's design system. Every size, spacing and control style in the
/// app comes from here, so the UI stays on one grid and one vocabulary.
///
/// Rules:
/// - Spacing is a 4 pt scale; layout uses 8, 12, 16 and 24.
/// - Toolbar: system controls only (they become Liquid Glass with the 27 SDK).
///   View-level actions (Save Search, Inspector) live there.
/// - Filter row: only `PillStyle` controls, all 28 pt high.
/// - Inspector: one prominent action (Copy Prompt), every other button bordered,
///   all at the regular control size.
/// - Glass is allowed on chrome and containers (sidebar, inspector panel,
///   collection cards, popovers) through shared styles in this file, and never
///   over the image grid: thumbnails stay sharp and uncovered.
enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        /// Between an icon and the text next to it (sidebar rows).
        static let iconText: CGFloat = 10
        /// Between a small icon and its label inside a control.
        static let iconGap: CGFloat = 6
        /// Horizontal padding inside a pill.
        static let pillInset: CGFloat = 10
        /// Padding of popovers and sheets' inner blocks is `m`; a sheet's own margin is this.
        static let sheet: CGFloat = 20
        /// Around a value that turns into a link on hover (2 pt above and below, `iconGap` at the sides).
        static let hairGap: CGFloat = 2
    }

    enum Size {
        /// Height of every control in the filter row and of inspector table rows.
        static let control: CGFloat = 28
        /// Height of the filter row.
        static let filterRow: CGFloat = 44
        /// Title, count and filter pills share this one row.
        static let headerRow: CGFloat = 52
        static let statusBar: CGFloat = 32
        /// Fixed icon column in sidebar rows, so every row's text lines up.
        static let sidebarIcon: CGFloat = 20
        /// Height of a sidebar row.
        static let sidebarRow: CGFloat = 28
        /// Column for the disclosure chevron in front of every sidebar row (empty when a row has none).
        static let sidebarChevron: CGFloat = 14
        /// How far each folder level moves in.
        static let sidebarIndent: CGFloat = 14
        /// Width and height of the thin marker at the leading edge of the selected row.
        static let sidebarMarkerWidth: CGFloat = 3
        static let sidebarMarkerHeight: CGFloat = 14
        /// Glyphs: folder, library and view icons in the sidebar.
        static let sidebarGlyph: CGFloat = 14
        /// Tiny glyphs inside pills (chevron, clear cross).
        static let microIcon: CGFloat = 8
        /// Height of a small status badge (source chip, ghost badge).
        static let badge: CGFloat = 22
        /// Advance of one digit or separator in the mono at 11.5 pt (0.612 em), rounded up.
        static let monoDigitWidth: CGFloat = 7.2
        static let dataBar: CGFloat = 72
        static let dataBarHeight: CGFloat = 4
        static let inspectorLabel: CGFloat = 92
        /// Thumbnails: the slider's range, its starting value and the step of ⌘+ and ⌘−.
        static let thumbnailMin: CGFloat = 80
        static let thumbnailDefault: CGFloat = 160
        static let thumbnailMax: CGFloat = 360
        static let thumbnailStep: CGFloat = 40
        static let toolbarSlider: CGFloat = 100
        /// Height of a month header in the grid.
        static let monthHeader: CGFloat = 40
        /// The source badge in a thumbnail's corner, and the glyph inside it.
        static let cellBadge: CGFloat = 18
        static let cellBadgeGlyph: CGFloat = 10
        /// The selection ring around a thumbnail, and how far the image steps back inside it.
        static let selectionRing: CGFloat = 2
        static let selectionInset: CGFloat = 4
        /// Tallest the inspector's preview image gets, so the details below stay in view.
        static let previewMaxHeight: CGFloat = 300
        /// Icon scale: tiny marks (colour dot, pill chevron), glyphs in popover rows, the ghost in a
        /// badge, in a row, and next to the title.
        static let dot: CGFloat = 8
        static let glyphColumn: CGFloat = 18
        static let iconSmall: CGFloat = 12
        static let iconBadge: CGFloat = 14
        static let iconRow: CGFloat = 16
        static let iconTitle: CGFloat = 18
        /// The clear button at the end of an active pill.
        static let pillClear: CGFloat = 20
        /// Thin vertical rule between groups of pills.
        static let pillRule: CGFloat = 20
        /// Colour swatches in the save-search sheet.
        static let swatch: CGFloat = 16
        /// Popovers and sheets.
        static let popover: CGFloat = 280
        static let popoverWide: CGFloat = 360
        static let popoverMaxHeight: CGFloat = 420
        static let sheet: CGFloat = 380
        static let preferences: CGFloat = 440
        /// Height of the month histogram in the date popover.
        static let histogram: CGFloat = 72
        /// Shortest placeholder block ("No values in this view").
        static let placeholder: CGFloat = 64
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let cell: CGFloat = 8
        /// The ghost outline around the content area.
        static let large: CGFloat = 12
        static let panel: CGFloat = 16
        /// Tiny shapes: histogram bars, orientation glyphs.
        static let hair: CGFloat = 2
    }

    /// Tints by meaning, never by decoration.
    enum Tint {
        /// Lighter indigo so text in this tint keeps a readable contrast on the dark window.
        static let midjourney = Color(red: 0.68, green: 0.72, blue: 1.0)
        static let stableDiffusion = Color(red: 0.557, green: 0.839, blue: 0.627)
        static let camera = Color(red: 0.486, green: 0.812, blue: 0.890)
        /// Location (GPS) group in the metadata inspector: rose #E2ABC6, matched lightness to the others.
        static let location = Color(red: 0.886, green: 0.671, blue: 0.776)
        /// Text of an active filter: the system accent lightened for contrast on dark.
        static var activeText: Color {
            Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor)
        }
        /// One opacity for every tinted fill.
        static let fill: Double = 0.15
        /// Sidebar icons: one tint per kind of thing, matched in lightness. Colour sits on the icon
        /// only; text stays neutral. Folders and saved searches take their tints from the palette
        /// below; a library is violet.
        static let library = Color(red: 0.76, green: 0.66, blue: 1.0)
        static let folder = Color(red: 0.557, green: 0.839, blue: 0.627)
        /// Opacity of the selected sidebar row's fill (the accent, clearly visible, not flat grey).
        static let selection: Double = 0.30
        /// Offline or something needs attention. Distinct from the amber of ghosts.
        static let warning = Color(red: 0.96, green: 0.45, blue: 0.38)
    }
}

// MARK: - Type scale

extension DS {
    /// The app's type scale. Sizes follow Apple's macOS text styles (body 13,
    /// callout 12, subheadline 11, minimum 10); hierarchy comes from weight and
    /// colour as much as size, and light weights are kept for large display
    /// numbers only. Rationale and sources: `docs/DESIGN-SYSTEM.md`.
    struct TextStyle {
        let size: CGFloat
        let weight: Font.Weight
        /// Points taken off the size when the text is set in the mono: Space Mono is about 12%
        /// wider than Space Grotesk, so 0.5 pt less keeps lines visually even.
        var monoAdjust: CGFloat = 0
        /// Letter spacing in points: tighter on big titles, looser on small caps.
        var tracking: CGFloat = 0

        /// One big statistic (library count). The only place a light-looking, large size is used.
        static let display = TextStyle(size: 40, weight: .regular)
        /// A page or view title. 20 sits between Apple's Title 2 (17) and Title 1 (22) and fits the 52 pt header row.
        static let title = TextStyle(size: 20, weight: .medium, tracking: -0.3)
        /// A sheet or popover heading.
        static let headline = TextStyle(size: 13, weight: .semibold)
        /// Default text: sidebar rows, general copy.
        static let body = TextStyle(size: 13, weight: .regular)
        /// Long text people actually read: the prompt in the inspector.
        static let reading = TextStyle(size: 15, weight: .regular)
        /// Controls and table rows: pills, inspector rows, footer.
        static let label = TextStyle(size: 12, weight: .regular, monoAdjust: 0.5)
        static let labelStrong = TextStyle(size: 12, weight: .semibold, monoAdjust: 0.5)
        /// Secondary information: counts next to titles, notes.
        static let meta = TextStyle(size: 11, weight: .regular, monoAdjust: 0.5)
        static let metaStrong = TextStyle(size: 11, weight: .semibold)
        /// Smallest text (the macOS minimum is 10): uppercase section captions.
        static let caption = TextStyle(size: 10, weight: .semibold, tracking: 0.6)
    }
}

extension View {
    /// Sizes an SF Symbol from the icon scale in `DS.Size` (symbols take their size from a font; this
    /// is the one place that says so, so views never write a font).
    func dsIcon(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
    }

    /// Sets text from the type scale. Words are sans; numbers and data are mono.
    func dsText(_ style: DS.TextStyle, _ role: TextRole = .text) -> some View {
        dsFont(style.size - (role == .number ? style.monoAdjust : 0), weight: style.weight, role)
            .tracking(style.tracking)
    }
}

// MARK: - Dark glass language

extension DS {
    /// Near-black surfaces and hairlines. The app is dark-only.
    enum Palette {
        static let window = Color(red: 0.047, green: 0.051, blue: 0.059)
        static let glow = Color(red: 0.30, green: 0.34, blue: 0.45)
        static let hairline = Color.white.opacity(0.09)
        /// Rules between table rows.
        static let rowRule = Color.white.opacity(0.10)
        /// Outline of a control that is off (3:1 is the target for control boundaries; 0.20 is the
        /// strongest that does not make pills shout).
        static let controlStroke = Color.white.opacity(0.20)
        /// Bars that show data are neutral: the accent is kept for selection.
        static let dataBar = Color.white.opacity(0.45)
        static let dataTrack = Color.white.opacity(0.08)
        /// A sidebar row under the pointer.
        static let hover = Color.white.opacity(0.07)
        static let glassFill = Color.white.opacity(0.045)
        static let glassFillSolid = Color(red: 0.094, green: 0.098, blue: 0.110)
        /// A value row under the pointer in the inspector.
        static let rowHover = Color.white.opacity(0.04)
        /// Histogram bars that are not selected.
        static let histogramBar = Color.primary.opacity(0.22)
        /// A pill while it is pressed (and the almost-clear fill that keeps the whole pill clickable).
        static let pressed = Color.primary.opacity(0.10)
        static let hitArea = Color.primary.opacity(0.0001)
        /// Opacity of the window colour behind a pinned month header.
        static let headerVeil: CGFloat = 0.88
        /// A thumbnail cell before its image arrives, and the dark chip behind the source badge (AppKit colours for the grid).
        static let cellPlaceholder = NSColor.labelColor.withAlphaComponent(0.04)
        static let badgeScrim = NSColor.black.withAlphaComponent(0.5)
    }

    enum Motion {
        /// View changes: short, never during fast scroll.
        static let view = Animation.easeOut(duration: 0.3)
        /// Hover and selection in the sidebar.
        static let quick = Animation.easeOut(duration: 0.12)
        /// The grid's reflow: how long thumbnails glide to their new place (ease-out), how long the
        /// width must rest before the reflow starts (a side panel has finished sliding), and the
        /// shortest time between two reflows while the size slider is dragged.
        static let reflowDuration: TimeInterval = 0.24
        static let reflowSettle: TimeInterval = 0.06
        static let reflowStep: TimeInterval = 0.10
    }
}

/// Near-black window with one soft light in the upper left. It is deliberately still: an animated
/// backdrop was redrawn 20 times a second and kept the idle app at 9 to 16% CPU (speed beats flourish).
struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            DS.Palette.window
            RadialGradient(
                colors: [DS.Palette.glow.opacity(0.22), .clear],
                center: UnitPoint(x: 0.12, y: 0.05),
                startRadius: 0, endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}

/// Frosted-glass container: sidebar, inspector panel, collection cards,
/// popovers. Never used over the image grid. With Reduce Transparency it falls
/// back to a solid fill.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = DS.Radius.panel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(DS.Palette.glassFillSolid)
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(DS.Palette.glassFill))
                }
            }
            .overlay { shape.strokeBorder(DS.Palette.hairline) }
            .clipShape(shape)
    }
}

extension View {
    func glassPanel(radius: CGFloat = DS.Radius.panel) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}

/// Sidebar rows: icon in a fixed column, a little air before the text.
struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.iconText) {
            configuration.icon.frame(width: DS.Size.sidebarIcon, alignment: .center)
            configuration.title
        }
    }
}

/// A soft coloured light behind the sidebar so the glass has something to refract: violet at the top,
/// a cool blue low down. Still (no timeline), and absent (solid window colour only) when Reduce
/// Transparency is on.
struct SidebarGlow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            ZStack {
                RadialGradient(colors: [DS.Tint.library.opacity(0.13), .clear],
                               center: UnitPoint(x: 0.15, y: 0.02), startRadius: 0, endRadius: 460)
                RadialGradient(colors: [Color(red: 0.30, green: 0.52, blue: 1.0).opacity(0.10), .clear],
                               center: UnitPoint(x: 0.85, y: 0.98), startRadius: 0, endRadius: 480)
            }
            .allowsHitTesting(false)
        }
    }
}

/// What every sidebar row shares: 28 pt height, a visible hover, and a clearly tinted selection with a
/// thin marker at its leading edge. The system's grey selection is switched off (`SidebarTableTweaks`).
struct SidebarRowChrome: ViewModifier {
    var selected: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        content
            .frame(height: DS.Size.sidebarRow)
            // Content sits flush with the section title; the fill is drawn around it, not by padding it.
            .background {
                if selected {
                    shape.fill(Color.accentColor.opacity(DS.Tint.selection)).padding(.horizontal, -DS.Space.xs)
                } else if hovering {
                    shape.fill(DS.Palette.hover).padding(.horizontal, -DS.Space.xs)
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.accentColor)
                        .frame(width: DS.Size.sidebarMarkerWidth, height: DS.Size.sidebarMarkerHeight)
                        .padding(.leading, -DS.Space.xs + 1)
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : DS.Motion.quick, value: hovering)
            .animation(reduceMotion ? nil : DS.Motion.quick, value: selected)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

extension View {
    func sidebarRow(selected: Bool) -> some View { modifier(SidebarRowChrome(selected: selected)) }
}
/// Section title in the sidebar. All of them share one quiet style; a tint
/// and icon are only for ghosts.
struct SidebarHeader: View {
    let title: String
    var icon: AnyView?
    var tint: Color = .secondary

    init(_ title: String, tint: Color = .secondary, @ViewBuilder icon: () -> some View = { EmptyView() }) {
        self.title = title
        self.tint = tint
        let built = icon()
        self.icon = (built is EmptyView) ? nil : AnyView(built)
    }

    var body: some View {
        HStack(spacing: DS.Space.iconGap) {
            icon
            Text(title).dsText(.headline)
        }
        .foregroundStyle(tint)
    }
}

/// The one style for everything in the filter row: filter pills and the
/// actions next to them. Neutral outline when off, tinted fill when on.
struct PillStyle: ButtonStyle {
    var isOn = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? tint : .primary)
            .padding(.horizontal, DS.Space.pillInset)
            .pillChrome(isOn: isOn, tint: tint, isPressed: configuration.isPressed)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The pill itself: label type, 28 pt height, neutral outline when off, tinted fill when on. Shared
/// by `PillStyle` (one button) and the filter pills (a button and a clear button in one capsule).
struct PillChrome: ViewModifier {
    var isOn: Bool
    var tint: Color
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .dsText(.label)
            .frame(height: DS.Size.control)
            .background {
                Capsule().fill(isOn ? tint.opacity(DS.Tint.fill) : (isPressed ? DS.Palette.pressed : DS.Palette.hitArea))
                if !isOn { Capsule().strokeBorder(DS.Palette.controlStroke) }
            }
            .contentShape(Capsule())
    }
}

extension View {
    func pillChrome(isOn: Bool, tint: Color = .accentColor, isPressed: Bool = false) -> some View {
        modifier(PillChrome(isOn: isOn, tint: tint, isPressed: isPressed))
    }
}
