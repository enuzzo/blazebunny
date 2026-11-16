import SwiftUI

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
/// - Content (grid, inspector, filter row) never uses glass.
enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Size {
        /// Height of every control in the filter row and of inspector table rows.
        static let control: CGFloat = 28
        /// Height of the filter row.
        static let filterRow: CGFloat = 44
        static let statusBar: CGFloat = 28
        static let inspectorLabel: CGFloat = 92
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let cell: CGFloat = 8
    }

    /// Tints by meaning, never by decoration.
    enum Tint {
        static let midjourney = Color.indigo
        static let stableDiffusion = Color.green
        static let camera = Color.teal
    }
}

/// The one style for everything in the filter row: filter pills and the
/// actions next to them. Neutral outline when off, tinted fill when on.
struct PillStyle: ButtonStyle {
    var isOn = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(isOn ? tint : .primary)
            .padding(.horizontal, DS.Space.m - 2)
            .frame(height: DS.Size.control)
            .background {
                Capsule().fill(isOn ? tint.opacity(0.15) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.0001))
                if !isOn { Capsule().strokeBorder(Color.primary.opacity(0.14)) }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
