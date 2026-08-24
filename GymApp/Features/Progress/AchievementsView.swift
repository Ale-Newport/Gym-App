import SwiftData
import SwiftUI

/// Formats a milestone for display in the user's own units.
///
/// Kept out of the view model on purpose: thresholds are stored canonically (kilograms, whole
/// sessions) and only become "100 kg" or "220 lb" once a `DisplayFormatter` is in hand.
enum AchievementPresentation {

    @MainActor
    static func title(_ badge: AchievementBadge, formatter: DisplayFormatter) -> String {
        let definition = badge.definition
        switch definition.measure {
        case .sessions(let count):
            return count <= 1 ? L(definition.titleKey) : L(definition.titleKey, count)
        case .dayStreak(let count), .weekStreak(let count),
             .weighIns(let count), .nutritionDays(let count):
            return L(definition.titleKey, count)
        case .liftKg(let kilograms):
            return L(definition.titleKey, formatter.weight(kilograms))
        case .tonnageKg(let kilograms):
            return L(definition.titleKey, formatter.volume(kilograms))
        }
    }

    @MainActor
    static func detail(_ badge: AchievementBadge, formatter: DisplayFormatter) -> String {
        let definition = badge.definition
        switch definition.measure {
        case .sessions(let count):
            return count <= 1 ? L(definition.detailKey) : L(definition.detailKey, count)
        case .dayStreak(let count), .weekStreak(let count),
             .weighIns(let count), .nutritionDays(let count):
            return L(definition.detailKey, count)
        case .liftKg(let kilograms):
            return L(definition.detailKey, formatter.weight(kilograms))
        case .tonnageKg(let kilograms):
            return L(definition.detailKey, formatter.volume(kilograms))
        }
    }

    /// "32 / 50" — how far along a locked badge is. Nil once it is unlocked, where the date says
    /// everything that needs saying.
    @MainActor
    static func progress(_ badge: AchievementBadge, formatter: DisplayFormatter) -> String? {
        guard !badge.isUnlocked else { return nil }
        switch badge.definition.measure {
        case .sessions(let count), .dayStreak(let count), .weekStreak(let count),
             .weighIns(let count), .nutritionDays(let count):
            return "\(Int(badge.currentValue.rounded(.down))) / \(count)"
        case .liftKg(let kilograms):
            return "\(formatter.weight(badge.currentValue)) / \(formatter.weight(kilograms))"
        case .tonnageKg(let kilograms):
            return "\(formatter.volume(badge.currentValue)) / \(formatter.volume(kilograms))"
        }
    }
}

/// Milestone badges, unlocked from real training data.
///
/// Restrained by design: no confetti, no levels, no daily login reward. Each badge marks something
/// a lifter would actually say out loud, and the locked ones show honest progress so the screen is
/// a set of targets rather than a wall of grey padlocks.
struct AchievementsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = AchievementsViewModel()

    private var unlocked: [AchievementBadge] { model.badges.filter(\.isUnlocked) }
    private var locked: [AchievementBadge] { model.badges.filter { !$0.isUnlocked } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                content
            }
            .padding(.vertical, Metrics.spacing16)
            .screenPadding()
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("progress.achievements.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(context: modelContext) }
        .refreshable { await model.load(context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("progress.loading"))
                .frame(minHeight: 320)
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await model.load(context: modelContext) }
            }
            .frame(minHeight: 320)
        case .content:
            if model.badges.isEmpty {
                // Only reachable if the catalogue itself were emptied, but a screen with no branch
                // for "nothing to show" is a screen that renders a blank page one day.
                EmptyStateView(
                    systemImage: "rosette",
                    title: L("progress.achievements.empty.title"),
                    message: L("progress.achievements.empty.message")
                )
                .frame(minHeight: 320)
            } else {
                loadedContent
            }
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            summary
            if !unlocked.isEmpty {
                section(title: L("progress.achievements.earned"), badges: unlocked)
            }
            if !locked.isEmpty {
                section(title: L("progress.achievements.next"), badges: locked)
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    L("progress.achievements.title"),
                    subtitle: L("progress.achievements.unlockedOf", model.unlockedCount, model.badges.count)
                )
                ProgressBar(
                    value: Double(model.unlockedCount),
                    total: Double(max(1, model.badges.count)),
                    tint: .appAccent,
                    height: 10
                )
                if unlocked.isEmpty {
                    Text(L("progress.achievements.noneYet"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("progress.empty.startWorkout")) { router.selectedTab = .workout }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func section(title: String, badges: [AchievementBadge]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(title)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156), spacing: Metrics.spacing12)],
                spacing: Metrics.spacing12
            ) {
                ForEach(badges) { badge in
                    AchievementBadgeTile(badge: badge, animatesUnlock: !reduceMotion)
                }
            }
        }
    }
}

/// One badge.
private struct AchievementBadgeTile: View {
    let badge: AchievementBadge
    var animatesUnlock: Bool

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ZStack {
                Circle()
                    .fill(badge.isUnlocked ? Color.appAccentMuted : Color.appFill)
                    .frame(width: 44, height: 44)
                if !badge.isUnlocked {
                    // The ring is the only place a locked badge shows how close it is at a glance;
                    // the same number is written out below it, so nothing depends on the arc alone.
                    Circle()
                        .trim(from: 0, to: badge.fraction)
                        .stroke(Color.appAccent.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 44, height: 44)
                }
                Image(systemName: badge.definition.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(badge.isUnlocked ? Color.appAccent : Color.appTextTertiary)
            }
            .animation(animatesUnlock ? .easeOut(duration: 0.3) : nil, value: badge.fraction)

            Text(AchievementPresentation.title(badge, formatter: formatter))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(badge.isUnlocked ? Color.appTextPrimary : Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(AchievementPresentation.detail(badge, formatter: formatter))
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let unlockedAt = badge.unlockedAt {
                Label(formatter.mediumDate(unlockedAt), systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.appSuccess)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = AchievementPresentation.progress(badge, formatter: formatter) {
                Text(progress)
                    .font(.appNumeric(12))
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacing12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(
                    badge.isUnlocked ? Color.appAccent.opacity(0.35) : Color.appSeparator.opacity(0.6),
                    lineWidth: badge.isUnlocked ? 1 : 0.5
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AchievementPresentation.title(badge, formatter: formatter)))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        var parts = [AchievementPresentation.detail(badge, formatter: formatter)]
        if let unlockedAt = badge.unlockedAt {
            parts.append(L("progress.achievements.earnedOn", formatter.mediumDate(unlockedAt)))
        } else if let progress = AchievementPresentation.progress(badge, formatter: formatter) {
            parts.append(L("progress.achievements.locked", progress))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Achievements") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            AchievementsView()
        }
    }
}
