import SwiftUI

/// The training streak, in weeks, with the last seven days underneath it.
///
/// Weeks rather than days is deliberate: rest days are part of a good program, so a daily streak
/// would quietly punish following the plan. The seven dots exist to give the number some texture —
/// they show *when* the work happened without turning it into a target of its own.
///
/// A trained day is drawn as a filled disc with a tick and an untrained day as an open ring, so the
/// distinction survives greyscale, colour vision deficiency and a screenshot.
struct StreakView: View {
    let weekStreak: Int
    let longestWeekStreak: Int
    /// Start-of-day dates, within the last seven days, that contain a completed session.
    let trainedDays: Set<Date>
    var calendar: Calendar = .current
    var now: Date = Date()

    private var days: [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(spacing: Metrics.spacing6) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(weekStreak > 0 ? Color.appAccent : Color.appTextTertiary)
                    .accessibilityHidden(true)
                Text(weekStreak > 0 ? LPlural("home.streak.weeks", weekStreak) : L("home.streak.none"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                if longestWeekStreak > 0 {
                    Text(L("home.streak.best", longestWeekStreak))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(streakLabel))

            HStack(spacing: Metrics.spacing6) {
                ForEach(days, id: \.self) { day in
                    dayMark(day)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L("home.streak.lastSeven")))
            .accessibilityValue(Text(daysLabel))
        }
    }

    private func dayMark(_ day: Date) -> some View {
        let trained = trainedDays.contains(day)
        return VStack(spacing: Metrics.spacing4) {
            ZStack {
                Circle()
                    .strokeBorder(trained ? Color.clear : Color.appSeparator, lineWidth: 1.5)
                    .background(Circle().fill(trained ? Color.appAccent : Color.clear))
                if trained {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.appSurface)
                }
            }
            .frame(width: 22, height: 22)

            Text(shortWeekday(of: day))
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
        }
    }

    private func shortWeekday(of day: Date) -> String {
        L(Weekday.from(day, calendar: calendar).shortLocalizationKey)
    }

    private var streakLabel: String {
        let headline = weekStreak > 0 ? LPlural("home.streak.weeks", weekStreak) : L("home.streak.none")
        guard longestWeekStreak > 0 else { return "\(L("home.streak.title")): \(headline)" }
        return "\(L("home.streak.title")): \(headline), \(L("home.streak.best", longestWeekStreak))"
    }

    private var daysLabel: String {
        days.map { day in
            let name = L(Weekday.from(day, calendar: calendar).localizationKey)
            return trainedDays.contains(day)
                ? L("home.streak.dayTrained", name)
                : L("home.streak.dayRest", name)
        }
        .joined(separator: ", ")
    }
}

#Preview {
    PreviewHost(scenario: .seasonedUser) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        StreakView(
            weekStreak: 6,
            longestWeekStreak: 11,
            trainedDays: Set([0, -1, -3, -5].compactMap {
                calendar.date(byAdding: .day, value: $0, to: today)
            })
        )
        .padding(Metrics.screenPadding)
        .background(Color.appBackground)
    }
}
