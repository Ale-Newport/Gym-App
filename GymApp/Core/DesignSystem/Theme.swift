import SwiftUI
import UIKit

// MARK: - Colour

/// The app's semantic palette.
///
/// Every colour is defined as a dynamic pair so light and dark are equally deliberate rather than
/// one being a washed-out inversion of the other. Colours are declared in code instead of an asset
/// catalogue so the whole palette is readable and reviewable in one place.
extension Color {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// Primary brand accent — a warm, high-energy red-orange.
    static let appAccent = dynamic(light: 0xF9531D, dark: 0xFF6633)
    static let appAccentMuted = dynamic(light: 0xFDEAE3, dark: 0x3A1A0F)

    /// Secondary accent used for nutrition surfaces, so training and food read as distinct areas.
    static let appNutrition = dynamic(light: 0x1E9E62, dark: 0x35C77F)
    static let appNutritionMuted = dynamic(light: 0xE4F4EC, dark: 0x0E2A1D)

    /// Tertiary accent for recovery, rest and calm states.
    static let appRecovery = dynamic(light: 0x3B70D6, dark: 0x5B92F5)
    static let appRecoveryMuted = dynamic(light: 0xE7EDFB, dark: 0x111E38)

    static let appBackground = dynamic(light: 0xF7F6F4, dark: 0x08090A)
    static let appSurface = dynamic(light: 0xFFFFFF, dark: 0x131517)
    static let appSurfaceElevated = dynamic(light: 0xFFFFFF, dark: 0x1B1E21)
    static let appFill = dynamic(light: 0xEFEDEA, dark: 0x1F2225)
    static let appFillSecondary = dynamic(light: 0xF3F1EE, dark: 0x181B1E)
    static let appSeparator = dynamic(light: 0xE3E0DB, dark: 0x2A2E32)

    static let appTextPrimary = dynamic(light: 0x111213, dark: 0xF5F5F4)
    static let appTextSecondary = dynamic(light: 0x5C5F63, dark: 0xA1A5AA)
    static let appTextTertiary = dynamic(light: 0x8E9296, dark: 0x71767B)

    /// Foreground for content sitting on a filled accent surface — a primary button, a selected
    /// segment, a coloured banner. A literal `Color.white` happens to be right today because every
    /// accent is dark enough in both themes, but it hard-codes that assumption into forty call
    /// sites. Changing the accent should not mean auditing all of them.
    static let appOnAccent = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    static let appSuccess = dynamic(light: 0x1B8F4D, dark: 0x35C77F)
    static let appWarning = dynamic(light: 0xB8730B, dark: 0xE8A33D)
    static let appDanger = dynamic(light: 0xC42D2D, dark: 0xF06060)

    /// Stable colour per muscle group, used in charts and volume bars. Chosen for separation in
    /// both themes and checked to stay distinguishable for common colour-vision deficiencies —
    /// every chart that uses them also labels its series, so colour is never the only cue.
    static func forGroup(_ group: MuscleGroup) -> Color {
        switch group {
        case .chest: dynamic(light: 0xE0532F, dark: 0xF4744F)
        case .back: dynamic(light: 0x2E6FB7, dark: 0x5A9BE0)
        case .shoulders: dynamic(light: 0xC9871A, dark: 0xE6AB44)
        case .traps: dynamic(light: 0x8C6D3F, dark: 0xB79463)
        case .biceps: dynamic(light: 0x6B4EAF, dark: 0x9B80D9)
        case .triceps: dynamic(light: 0xA9418F, dark: 0xD174BA)
        case .forearms: dynamic(light: 0x776B5D, dark: 0xA79A8B)
        case .quads: dynamic(light: 0x1F8A70, dark: 0x3FBFA0)
        case .hamstrings: dynamic(light: 0x0E6E86, dark: 0x38A3BD)
        case .glutes: dynamic(light: 0xB1476B, dark: 0xDE7A9D)
        case .adductors: dynamic(light: 0x5D7F3C, dark: 0x8FB268)
        case .abductors: dynamic(light: 0x3F7F70, dark: 0x6FB2A2)
        case .calves: dynamic(light: 0x4A7A2E, dark: 0x7CB255)
        case .abs: dynamic(light: 0xD0742A, dark: 0xEC9C54)
        case .obliques: dynamic(light: 0xA9662E, dark: 0xCE9159)
        case .lowerBack: dynamic(light: 0x5A6473, dark: 0x8E99AA)
        case .neck: dynamic(light: 0x807A96, dark: 0xACA6C2)
        case .cardio: dynamic(light: 0xCF3B5B, dark: 0xF06B87)
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Metrics

/// Spacing, radius and sizing constants. Using the scale rather than ad-hoc numbers is what keeps
/// unrelated screens looking like the same product.
enum Metrics {
    /// 4-point spacing scale.
    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32
    static let spacing40: CGFloat = 40

    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 14
    static let cornerLarge: CGFloat = 20
    static let cornerXLarge: CGFloat = 28

    /// Apple's minimum comfortable hit target.
    static let minimumTapTarget: CGFloat = 44
    /// Controls used mid-set, one-handed, with chalky fingers. Deliberately larger.
    static let gymTapTarget: CGFloat = 56

    static let screenPadding: CGFloat = 20
    static let cardPadding: CGFloat = 16
    /// Widest a reading column is allowed to get on iPad.
    static let readableWidth: CGFloat = 620
}

// MARK: - Typography

extension Font {
    /// Numeric display face for weights, reps and timers. Monospaced digits stop the layout from
    /// twitching as values change mid-set.
    static func appNumeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let appTitle = Font.largeTitle.weight(.bold)
    static let appSectionTitle = Font.title3.weight(.semibold)
    static let appCardTitle = Font.headline
    static let appBody = Font.body
    static let appCaption = Font.caption
    /// Small all-caps label used above grouped content.
    static let appOverline = Font.caption.weight(.semibold)
}

// MARK: - Haptics

/// Central haptics. Every call is a no-op when the device cannot vibrate, and the app never relies
/// on haptics alone to convey information.
@MainActor
enum Haptics {
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
        selection.prepare()
    }

    static func tap() { impactLight.impactOccurred() }
    static func setCompleted() { impactMedium.impactOccurred() }
    static func restFinished() { impactHeavy.impactOccurred() }
    static func selectionChanged() { selection.selectionChanged() }
    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error() { notification.notificationOccurred(.error) }
}
