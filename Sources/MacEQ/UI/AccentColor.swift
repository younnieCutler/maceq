import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        default: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// The app's one accent color, matching the icon's periwinkle. Used
    /// app-wide via `.tint()` instead of the system default blue — a
    /// deliberate, single signature color rather than "didn't customize
    /// anything" (PRD still calls for native materials elsewhere; this is the
    /// one place the product gets its own identity).
    static let macEQAccent = Color(hex: "7C9EFF")

    /// Peripheral frequency cues. They are only used on the active rail,
    /// thumb, and label, never as a band background.
    static let macEQLow = Color(hex: "B2876C")
    static let macEQHigh = Color(hex: "7898C4")
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return L("appearance.system")
        case .light: return L("appearance.light")
        case .dark: return L("appearance.dark")
        }
    }
}
