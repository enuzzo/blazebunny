import SwiftUI
import AppKit
import CoreText

/// The app's typeface: Space Grotesk for text, Space Mono for numbers and data.
/// Both are bundled (SIL OFL, see NOTICE) and can be switched off in Preferences,
/// which falls back to the system font.
enum Typeface {
    static let defaultsKey = "useBrandTypeface"

    /// Registers the bundled fonts for this process. Called once at launch.
    /// Does nothing when run as a bare executable (`swift run`) with no bundle.
    static func registerBundled() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// False when the fonts could not be loaded, so views fall back to the system font.
    static var isAvailable: Bool {
        NSFont(name: "SpaceGrotesk-Regular", size: 12) != nil && NSFont(name: "SpaceMono-Regular", size: 12) != nil
    }

    static func sansName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: return "SpaceGrotesk-Light"
        case .regular: return "SpaceGrotesk-Regular"
        case .medium, .semibold: return "SpaceGrotesk-Medium"
        default: return "SpaceGrotesk-Bold"
        }
    }

    static func monoName(for weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: return "SpaceMono-Bold"
        default: return "SpaceMono-Regular"
        }
    }
}

/// What a piece of text is: words, or a number/data value.
enum TextRole { case text, number }

private struct BrandTypefaceKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the bundled typeface should be used.
    var brandTypeface: Bool {
        get { self[BrandTypefaceKey.self] }
        set { self[BrandTypefaceKey.self] = newValue }
    }
}

private struct DSFontModifier: ViewModifier {
    @Environment(\.brandTypeface) private var brand
    let size: CGFloat
    let weight: Font.Weight
    let role: TextRole

    func body(content: Content) -> some View {
        content.font(font)
    }

    private var font: Font {
        switch (brand, role) {
        case (true, .text): return .custom(Typeface.sansName(for: weight), fixedSize: size)
        case (true, .number): return .custom(Typeface.monoName(for: weight), fixedSize: size)
        case (false, .text): return .system(size: size, weight: weight)
        case (false, .number): return .system(size: size, weight: weight).monospacedDigit()
        }
    }
}

extension View {
    /// Sets the app font: sans for words, mono for numbers and data.
    func dsFont(_ size: CGFloat, weight: Font.Weight = .regular, _ role: TextRole = .text) -> some View {
        modifier(DSFontModifier(size: size, weight: weight, role: role))
    }
}
