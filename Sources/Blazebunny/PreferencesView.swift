import SwiftUI

/// The Preferences window (⌘,).
struct PreferencesView: View {
    @AppStorage(Typeface.defaultsKey) private var useBrandTypeface = true

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Use Space Grotesk and Space Mono", isOn: $useBrandTypeface)
                    .disabled(!Typeface.isAvailable)
                Text(Typeface.isAvailable
                     ? "Space Grotesk for text, Space Mono for numbers. Turn off to use the system font."
                     : "The bundled fonts are not available in this build, so the system font is used.")
                    .dsText(.label)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .environment(\.brandTypeface, useBrandTypeface && Typeface.isAvailable)
    }
}
