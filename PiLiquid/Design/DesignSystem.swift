import SwiftUI

/// Design tokens transcribed from Apple's published design system
/// (VoltAgent/awesome-design-md · apple/DESIGN.md). Single interactive color
/// (Action Blue `#0066cc` light / Sky `#2997ff` dark — both live in the asset
/// catalog so `.tint` propagates them), 17px editorial body with the signature
/// `-0.374px` tracking, an 8pt spacing scale, the 5/8/11/18/pill radius set,
/// and a strict 300/400/600/700 weight ladder (weight 500 is deliberately
/// absent).
enum DS {
    // Corner radii (px) ------------------------------------------------------
    static let radiusXSmall: CGFloat = 5    // tight chips
    static let radiusSmall: CGFloat = 8     // utility buttons, list selection
    static let radiusMedium: CGFloat = 11   // pearl capsules, cards
    static let radiusLarge: CGFloat = 18    // bubbles, floating surfaces
    // (pill = full capsule, expressed with Capsule())

    // Spacing scale (8pt base) -----------------------------------------------
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 17
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    // Reading typography -----------------------------------------------------
    static let bodySize: CGFloat = 17          // 17px body, never 16 — editorial pace
    static let chatSize: CGFloat = 14.5        // tighter conversation text (must match Web/index.html)
    static let bodyTracking: CGFloat = -0.374  // signature negative letter-spacing
    static let bodyLineSpacing: CGFloat = 4    // ≈ 1.47 line-height at 17px
    static let captionTracking: CGFloat = -0.224

    // Hairlines / fills (adaptive so they read in dark mode too) -------------
    static let hairline = Color(nsColor: .separatorColor)
    static let chipFill = Color.primary.opacity(0.055)
    static let chipFillStrong = Color.primary.opacity(0.10)
}

/// Visual identity for a slash-command category, shared by the composer chip,
/// the palette rows, and the history highlight so they speak one color language.
/// Color here *carries meaning* (the command's type) — the sanctioned exception
/// to the otherwise-neutral palette.
enum CommandKind {
    /// Maps `PiCommand.source` to its accent. None is the interactive accent
    /// blue, so command tints never read as the send button / selection.
    static func tint(for source: String) -> Color {
        switch source {
        case "extension": return .teal
        case "prompt":    return .orange
        case "skill":     return .purple
        case "builtin":   return .gray
        default:          return .gray
        }
    }

    static func symbol(for source: String) -> String {
        switch source {
        case "extension": return "puzzlepiece.extension"
        case "prompt":    return "text.quote"
        case "skill":     return "sparkles"
        case "builtin":   return "gearshape"
        default:          return "chevron.right"
        }
    }
}

extension Color {
    /// `Color(hex: 0x0066CC)`
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// Monospaced font used for tool output and code.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Apple "Body" — 17px / weight 400 / -0.374 tracking / 1.47 line-height.
    func bodyStyle() -> some View {
        self.font(.system(size: DS.bodySize, weight: .regular))
            .tracking(DS.bodyTracking)
            .lineSpacing(DS.bodyLineSpacing)
    }

    /// Apple "Caption" — 14px / -0.224 tracking.
    func captionStyle(weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: 13, weight: weight))
            .tracking(DS.captionTracking)
    }
}
