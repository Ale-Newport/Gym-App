import SwiftUI
import UIKit
import WidgetKit

// MARK: - Strings

/// String lookup for the widget extension.
///
/// The app resolves every string through `LocalizationManager`, which honours the in-app language
/// override by pointing lookups at a specific `.lproj` bundle. That machinery lives in the app
/// target and deliberately is not compiled here — a timeline provider has a fraction of a second to
/// run and no business touching user defaults or the app's object graph. The widget therefore reads
/// the same catalogue (`Localizable.xcstrings` is a resource of this target too) straight out of its
/// own bundle, which means it follows the *system* language. That is the correct behaviour for
/// content the system renders on the Home and Lock Screens.
///
/// The signature deliberately matches the app's `L(_:)` so the localisation audit script finds these
/// keys in the same scan it uses for the app.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localises `key` and substitutes positional arguments (`%@`, `%lld`, `%1$@`, …).
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: L(key), locale: .autoupdatingCurrent, arguments: arguments)
}

/// Localises a plural-aware key. The catalogue entry declares its variations on the count.
func LPlural(_ key: String, _ count: Int) -> String {
    String(format: L(key), locale: .autoupdatingCurrent, count)
}

// MARK: - Colour

/// The widget's palette.
///
/// A deliberate copy of the handful of semantic colours the widgets need rather than a shared
/// module: `Theme.swift` pulls in the whole design system and the `MuscleGroup` taxonomy, none of
/// which a widget can compile against. The hex values are kept in step with the app's palette so a
/// widget never looks like it came from a different product.
enum WidgetPalette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(widgetHex: dark) : UIColor(widgetHex: light)
        })
    }

    /// Training accent — the app's warm red-orange.
    static let accent = dynamic(light: 0xF9531D, dark: 0xFF6633)
    /// Nutrition accent, so food and training read as distinct areas here too.
    static let nutrition = dynamic(light: 0x1E9E62, dark: 0x35C77F)
    /// Rest, recovery and anything calm.
    static let recovery = dynamic(light: 0x3B70D6, dark: 0x5B92F5)

    static let background = dynamic(light: 0xFFFFFF, dark: 0x131517)
    static let fill = dynamic(light: 0xEFEDEA, dark: 0x1F2225)
    static let separator = dynamic(light: 0xE3E0DB, dark: 0x2A2E32)

    static let textPrimary = dynamic(light: 0x111213, dark: 0xF5F5F4)
    static let textSecondary = dynamic(light: 0x5C5F63, dark: 0xA1A5AA)
    static let textTertiary = dynamic(light: 0x8E9296, dark: 0x71767B)

    static let warning = dynamic(light: 0xB8730B, dark: 0xE8A33D)

    /// Text and glyphs drawn on top of a filled accent surface. A palette entry rather than a bare
    /// white so no view ever reaches for a literal colour.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// Macro colours, matching the app's nutrition screens. Every bar that uses one is also labelled,
    /// so the colour is a second cue rather than the only one.
    static let protein = dynamic(light: 0x2E6FB7, dark: 0x5A9BE0)
    static let carbs = dynamic(light: 0xC9871A, dark: 0xE6AB44)
    static let fat = dynamic(light: 0xA9418F, dark: 0xD174BA)
}

private extension UIColor {
    convenience init(widgetHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Metrics

/// Spacing and sizing for the widget target. Smaller than the app's scale throughout: a small
/// widget is 155 pt wide, so the app's 16–20 pt gaps would leave no room for content.
enum WidgetMetrics {
    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10

    static let barHeight: CGFloat = 5
}

// MARK: - Typography

extension Font {
    /// Numeric face for calories, counts and timers. Monospaced digits stop a widget's layout from
    /// twitching as a timer ticks.
    static func widgetNumeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let widgetTitle = Font.system(size: 15, weight: .semibold)
    static let widgetLabel = Font.system(size: 12, weight: .medium)
    static let widgetCaption = Font.system(size: 11, weight: .medium)
    static let widgetOverline = Font.system(size: 10, weight: .semibold)
}

// MARK: - Number formatting

/// Locale-aware number formatting for the widget. `NumberFormatter` instances are cached because a
/// timeline provider builds several entries in one pass and creating a formatter is measurably slow.
enum WidgetFormat {
    private static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// A whole number, grouped for the user's locale. NaN and infinity render as zero rather than
    /// as the literal text "nan", which is the only thing worse than a wrong number on a widget.
    static func whole(_ value: Double) -> String {
        let safe = value.isFinite ? value.rounded() : 0
        return integer.string(from: NSNumber(value: safe)) ?? String(Int(safe))
    }

    static func whole(_ value: Int) -> String {
        integer.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Percentage 0…100 as a whole number, for accessibility text.
    static func percent(_ fraction: Double) -> String {
        whole((fraction.isFinite ? fraction : 0) * 100)
    }
}

// MARK: - Deep links

/// The URLs a widget hands back to the app when it is tapped.
///
/// These strings are duplicated in `GymApp/Core/Intents/IntentDeepLinks.swift`, which parses them.
/// The duplication is deliberate: the two targets share only `Core/SharedSnapshot`, and adding a
/// third shared file to carry eight string constants would cost more than it saves. Both sides
/// carry this comment so neither is changed alone.
enum WidgetLink {
    private static func url(_ host: String, _ path: String = "", query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "forge"
        components.host = host
        components.path = path.isEmpty ? "" : "/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        // Every combination below is a valid URL; the fallback exists so the type never traps.
        return components.url ?? URL(string: "forge://workout")!
    }

    /// Start (or resume) today's session.
    static let startWorkout = url("workout", "start")
    /// Open the workout that is already running.
    static let resumeWorkout = url("workout", "resume")
    /// Open today's session without starting it.
    static let todayWorkout = url("workout", "today")
    /// Open the nutrition tab for today.
    static let nutritionToday = url("nutrition", "today")
    /// Open the progress tab.
    static let progress = url("progress")
}

// MARK: - Shared components

/// A horizontal progress bar sized for a widget.
struct WidgetProgressBar: View {
    let value: Double
    let total: Double
    var tint: Color = WidgetPalette.accent
    var height: CGFloat = WidgetMetrics.barHeight
    /// When true the bar turns amber past 100 % instead of clamping silently.
    var warnsOnOverflow: Bool = false

    private var fraction: Double {
        guard total > 0, value.isFinite, total.isFinite else { return 0 }
        return min(max(value / total, 0), 1)
    }

    private var isOver: Bool { total > 0 && value > total }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.fill)
                Capsule()
                    .fill(warnsOnOverflow && isOver ? WidgetPalette.warning : tint)
                    .frame(width: max(height, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A ring, used for the circular Lock Screen family and for the medium nutrition widget.
struct WidgetRing<Label: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 6
    var tint: Color = WidgetPalette.accent
    var trackOpacity: Double = 1
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetPalette.fill.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction.isFinite ? fraction : 0, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
    }
}

/// One labelled macro bar. The gram figure is spelled out next to the bar so the information never
/// depends on reading a colour or judging a length.
struct WidgetMacroBar: View {
    let title: String
    let consumed: Double
    let target: Double
    let tint: Color

    private var valueText: String {
        target > 0
            ? L("widget.macro.value", WidgetFormat.whole(consumed), WidgetFormat.whole(target))
            : L("widget.macro.valueOnly", WidgetFormat.whole(consumed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing4) {
            HStack(spacing: WidgetMetrics.spacing4) {
                Text(title)
                    .font(.widgetOverline)
                    .foregroundStyle(WidgetPalette.textSecondary)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.widgetNumeric(11, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textPrimary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            WidgetProgressBar(value: consumed, total: target, tint: tint, warnsOnOverflow: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(valueText))
    }
}

/// Shown whenever a widget has nothing truthful to display: no snapshot in the App Group, no
/// programme yet, or nutrition switched off. Never an empty rectangle, never invented data.
struct WidgetNeutralMessage: View {
    let symbolName: String
    let title: String
    var message: String?
    var tint: Color = WidgetPalette.textTertiary

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing6) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.widgetTitle)
                .foregroundStyle(WidgetPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.widgetCaption)
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// The small "FORGE" wordmark that identifies a widget on a crowded Home Screen.
struct WidgetBrandMark: View {
    var tint: Color = WidgetPalette.accent

    var body: some View {
        HStack(spacing: WidgetMetrics.spacing4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .bold))
            Text(L("app.name").uppercased())
                .font(.widgetOverline)
                .tracking(0.6)
        }
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}
