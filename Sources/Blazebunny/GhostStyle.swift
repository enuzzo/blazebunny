import SwiftUI

/// How ghost (temporary) folders look: a line ghost icon, an amber tint and
/// dashed outlines, the usual way to say "temporary" and "anonymous". Everything
/// about a ghost is deliberately easy to see.
extension DS.Tint {
    static let ghost = Color(red: 0.95, green: 0.72, blue: 0.38)
}

/// The one sentence that explains a ghost, used in every tooltip and note.
enum GhostText {
    static let explanation = "Ghost: the index and thumbnails are temporary and are deleted when you close it. Your files are never changed."
    static let badge = "Ghost · temporary"
    static let section = "Ghosts · temporary"
}

/// A line-drawn ghost: rounded head, wavy hem, two eyes.
struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.14, 0.88))
        path.addLine(to: p(0.14, 0.46))
        path.addCurve(to: p(0.5, 0.08), control1: p(0.14, 0.22), control2: p(0.30, 0.08))
        path.addCurve(to: p(0.86, 0.46), control1: p(0.70, 0.08), control2: p(0.86, 0.22))
        path.addLine(to: p(0.86, 0.88))
        path.addQuadCurve(to: p(0.62, 0.88), control: p(0.74, 1.0))
        path.addQuadCurve(to: p(0.38, 0.88), control: p(0.50, 0.76))
        path.addQuadCurve(to: p(0.14, 0.88), control: p(0.26, 1.0))
        path.closeSubpath()
        for x in [0.37, 0.63] as [CGFloat] {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 0.04) * rect.width, y: rect.minY + 0.42 * rect.height,
                                       width: 0.08 * rect.width, height: 0.10 * rect.height))
        }
        return path
    }
}

struct GhostIcon: View {
    var size: CGFloat = 16
    var tint: Color = DS.Tint.ghost
    /// True where text next to the icon already says "ghost", so VoiceOver reads it once.
    var decorative = false

    var body: some View {
        GhostShape()
            .stroke(tint, style: StrokeStyle(lineWidth: max(1.2, size * 0.075), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(decorative)
            .accessibilityLabel("Ghost")
    }
}

/// "Ghost" pill with a dashed outline, shown wherever the open folder is a ghost.
struct GhostBadge: View {
    var body: some View {
        HStack(spacing: DS.Space.iconGap) {
            GhostIcon(size: 14, decorative: true)
            Text(GhostText.badge)
                .dsText(.metaStrong)
                .foregroundStyle(DS.Tint.ghost)
        }
        .padding(.horizontal, DS.Space.s + 2)
        .frame(height: DS.Size.badge)
        .background(Capsule().fill(DS.Tint.ghost.opacity(DS.Tint.fill)))
        .overlay(Capsule().strokeBorder(DS.Tint.ghost.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .help(GhostText.explanation)
    }
}

extension View {
    /// Dashed outline in the ghost tint, drawn inside the view's bounds.
    func ghostOutline(_ active: Bool, radius: CGFloat = 12, inset: CGFloat = 3) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Tint.ghost.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
    }
}
