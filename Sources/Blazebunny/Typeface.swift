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

    /// Space Grotesk is a variable font (wght 300 to 700); this maps a SwiftUI weight onto it,
    /// so semibold is a real 600 and not a fallback.
    static func variationWeight(_ weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight, .thin, .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        default: return 700
        }
    }

    static func monoName(for weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: return "SpaceMono-Bold"
        default: return "SpaceMono-Regular"
        }
    }

    /// The bundled font for a role and weight, or nil when it is not available.
    static func ctFont(size: CGFloat, weight: Font.Weight, role: TextRole) -> CTFont? {
        guard isAvailable else { return nil }
        switch role {
        case .text:
            let wghtTag = 0x77676874  // 'wght'
            let attrs: [CFString: Any] = [
                kCTFontNameAttribute: "SpaceGrotesk-Regular",
                kCTFontVariationAttribute: [NSNumber(value: wghtTag): NSNumber(value: variationWeight(weight))],
            ]
            return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        case .number:
            return NSFont(name: monoName(for: weight), size: size) as CTFont?
        }
    }

    /// SwiftUI font for a role: bundled when `brand`, otherwise the system font.
    static func font(size: CGFloat, weight: Font.Weight, role: TextRole, brand: Bool) -> Font {
        if brand, let ct = ctFont(size: size, weight: weight, role: role) { return Font(ct) }
        switch role {
        case .text: return .system(size: size, weight: weight)
        case .number: return .system(size: size, weight: weight).monospacedDigit()
        }
    }

    /// AppKit font for the same roles (the grid's month headers).
    static func nsFont(size: CGFloat, weight: Font.Weight, role: TextRole) -> NSFont {
        let brand = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        if brand, let ct = ctFont(size: size, weight: weight, role: role) { return ct as NSFont }
        let w: NSFont.Weight = weight == .semibold ? .semibold : weight == .medium ? .medium : weight == .bold ? .bold : .regular
        return role == .number ? .monospacedDigitSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
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
        content.font(Typeface.font(size: size, weight: weight, role: role, brand: brand))
    }
}

/// Words in the sans and numbers (digit runs with their separators) in the mono, in one line.
struct RichText: View {
    @Environment(\.brandTypeface) private var brand
    let string: String
    let style: DS.TextStyle

    init(_ string: String, _ style: DS.TextStyle) {
        self.string = string
        self.style = style
    }

    var body: Text {
        var out = Text("")
        for (piece, isNumber) in Self.split(string) {
            let size = style.size - (isNumber ? style.monoAdjust : 0)
            out = out + Text(piece).font(Typeface.font(size: size, weight: style.weight, role: isNumber ? .number : .text, brand: brand))
        }
        return out
    }

    /// Splits into alternating words and numbers; "20.647" and "10:30" stay one number.
    static func split(_ s: String) -> [(String, Bool)] {
        var parts: [(String, Bool)] = []
        var current = ""
        var currentIsNumber = false
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            let prevDigit = i > 0 && chars[i - 1].isNumber
            let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
            let isNumber = ch.isNumber || (".,:".contains(ch) && prevDigit && nextDigit)
            if !current.isEmpty && isNumber != currentIsNumber {
                parts.append((current, currentIsNumber))
                current = ""
            }
            currentIsNumber = isNumber
            current.append(ch)
        }
        if !current.isEmpty { parts.append((current, currentIsNumber)) }
        return parts
    }
}

extension View {
    /// Sets the app font: sans for words, mono for numbers and data.
    func dsFont(_ size: CGFloat, weight: Font.Weight = .regular, _ role: TextRole = .text) -> some View {
        modifier(DSFontModifier(size: size, weight: weight, role: role))
    }
}
