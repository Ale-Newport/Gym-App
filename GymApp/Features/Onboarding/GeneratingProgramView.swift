import SwiftUI

/// Runs the programming engine, writes the result, and then shows the user what it decided.
///
/// The second half is the point. Every other app in this category hands back a program and expects
/// it to be taken on faith; this one returns the `Explanation` values the engines produced — why
/// this split, why this much volume, why these calories — because a plan the user cannot interrogate
/// is a plan they cannot sensibly overrule.
///
/// Failure is a first-class outcome, not an alert. The engine can legitimately come back empty for a
/// user whose equipment and restrictions leave nothing to program, so the failure state offers both
/// a retry and an empty program they can fill in by hand.
struct GeneratingProgramView: View {
    @Bindable var model: OnboardingViewModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which of the working messages is showing. Purely cosmetic; the work does not report progress.
    @State private var stage = 0

    private static let stageKeys = [
        "onboarding.generate.stage.volume",
        "onboarding.generate.stage.split",
        "onboarding.generate.stage.exercises",
        "onboarding.generate.stage.fitting",
        "onboarding.generate.stage.nutrition"
    ]

    /// Adaptive rather than fixed: at the largest Dynamic Type sizes three tiles side by side would
    /// clip, and a stat nobody can read is worse than a wrap.
    private static let tileColumns = [GridItem(.adaptive(minimum: 96), spacing: Metrics.spacing12)]

    var body: some View {
        Group {
            switch model.generation {
            case .idle, .running:
                runningView
            case .failed(let message):
                failureView(message)
            case .ready(let result):
                resultView(result)
            }
        }
        .task {
            guard model.shouldGenerate else { return }
            await model.generateProgram(context: modelContext, catalog: environment.catalog)
        }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: Metrics.spacing16) {
            LoadingStateView(message: L(Self.stageKeys[min(stage, Self.stageKeys.count - 1)]))
                .frame(minHeight: 180)
            Text(L("onboarding.generate.patience"))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .task(id: model.generation) {
            // The stages are a description of the pipeline, not a progress bar: the engine is a
            // single synchronous pass and cannot report where it is. They advance on a timer, and
            // stop at the last one rather than looping, so nothing claims to be finished twice.
            guard model.generation.isRunning else { return }
            while !Task.isCancelled, stage < Self.stageKeys.count - 1 {
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 700 : 450))
                guard !Task.isCancelled else { return }
                stage += 1
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("onboarding.generate.stage.volume")))
    }

    // MARK: - Failure

    private func failureView(_ message: String) -> some View {
        VStack(spacing: Metrics.spacing16) {
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                stage = 0
                Task { await model.generateProgram(context: modelContext, catalog: environment.catalog) }
            }

            Button {
                Haptics.tap()
                model.createManualProgram(context: modelContext)
            } label: {
                Text(L("onboarding.generate.manual"))
            }
            .buttonStyle(SecondaryButtonStyle())

            Text(L("onboarding.generate.manual.detail"))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Result

    private func resultView(_ result: OnboardingProgramResult) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing20) {
            headline(result)
            if result.isManual {
                ExplanationNote(text: L("onboarding.generate.manualExplanation"), systemImage: "hand.raised", tint: .appWarning)
            } else {
                sessionsSection(result)
                volumeSection(result)
                reasoningSection(result)
            }
            nutritionSection(result)
        }
    }

    private func headline(_ result: OnboardingProgramResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(L(result.splitKey))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // An adaptive grid rather than a fixed row: at the largest Dynamic Type sizes three
                // tiles side by side would clip, and a stat nobody can read is worse than a wrap.
                LazyVGrid(columns: Self.tileColumns, alignment: .leading, spacing: Metrics.spacing12) {
                    StatTile(
                        value: String(result.daysPerWeek),
                        label: L("onboarding.result.daysPerWeek"),
                        systemImage: "calendar"
                    )
                    StatTile(
                        value: String(result.totalWeeklySets),
                        label: L("onboarding.result.weeklySets"),
                        systemImage: "square.stack.3d.up"
                    )
                    StatTile(
                        value: formatter.durationCompact(estimatedWeeklySeconds(result)),
                        label: L("onboarding.result.weeklyTime"),
                        systemImage: "clock"
                    )
                }
            }
        }
    }

    private func estimatedWeeklySeconds(_ result: OnboardingProgramResult) -> Int {
        result.trainingSessions.reduce(0) { $0 + $1.estimatedMinutes * 60 }
    }

    // MARK: Sessions

    private func sessionsSection(_ result: OnboardingProgramResult) -> some View {
        OnboardingSection(L("onboarding.result.week"), subtitle: L("onboarding.result.week.detail")) {
            LazyVStack(spacing: Metrics.spacing8) {
                ForEach(result.sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: GeneratedSession) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            VStack(spacing: 2) {
                Text(session.weekday.map { L($0.shortLocalizationKey) } ?? "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.isRestDay ? Color.appTextTertiary : Color.appAccent)
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.customTitle ?? L(session.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.isRestDay ? Color.appTextSecondary : Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if session.isRestDay {
                    Text(L("onboarding.result.restDay"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                } else {
                    Text(L(
                        "onboarding.result.sessionDetail",
                        session.exercises.count, session.totalSets, session.estimatedMinutes
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if !session.focusGroups.isEmpty {
                        Text(session.focusGroups.map { L($0.localizationKey) }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.spacing12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
        .opacity(session.isRestDay ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Volume

    private func volumeSection(_ result: OnboardingProgramResult) -> some View {
        let ranked = result.weeklyVolume
            .filter { $0.value >= 1 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
            }
        let maximum = ranked.first?.value ?? 1

        return OnboardingSection(L("onboarding.result.volume"), subtitle: L("onboarding.result.volume.detail")) {
            if ranked.isEmpty {
                EmptyStateView(
                    systemImage: "chart.bar",
                    title: L("onboarding.result.volume.empty.title"),
                    message: L("onboarding.result.volume.empty.message")
                )
            } else {
                VStack(spacing: Metrics.spacing8) {
                    ForEach(ranked.prefix(10), id: \.key) { entry in
                        HStack(spacing: Metrics.spacing12) {
                            Text(L(entry.key.localizationKey))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .frame(width: 92, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            ProgressBar(value: entry.value, total: maximum, tint: .forGroup(entry.key), height: 8)
                            Text(Units.formatDecimal(entry.value, digits: entry.value < 10 ? 1 : 0))
                                .font(.appNumeric(13))
                                .foregroundStyle(Color.appTextPrimary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(L(entry.key.localizationKey)))
                        .accessibilityValue(Text(L("onboarding.result.setsPerWeek", Units.formatDecimal(entry.value, digits: 1))))
                    }
                }
            }
        }
    }

    // MARK: Reasoning

    private func reasoningSection(_ result: OnboardingProgramResult) -> some View {
        OnboardingSection(L("onboarding.result.why"), subtitle: L("onboarding.result.why.detail")) {
            if result.explanations.isEmpty {
                EmptyStateView(
                    systemImage: "text.bubble",
                    title: L("onboarding.result.why.empty.title"),
                    message: L("onboarding.result.why.empty.message")
                )
            } else {
                VStack(spacing: Metrics.spacing8) {
                    ForEach(Array(result.explanations.enumerated()), id: \.offset) { _, explanation in
                        ExplanationNote(text: explanation.text)
                    }
                }
            }
        }
    }

    // MARK: Nutrition

    @ViewBuilder
    private func nutritionSection(_ result: OnboardingProgramResult) -> some View {
        OnboardingSection(L("onboarding.result.nutrition"), subtitle: L("onboarding.result.nutrition.detail")) {
            if let targets = result.energyTargets {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Card(background: .appSurface) {
                        VStack(alignment: .leading, spacing: Metrics.spacing12) {
                            HStack(alignment: .top, spacing: Metrics.spacing12) {
                                StatTile(
                                    value: formatter.energy(targets.kilocalories, includeUnit: false),
                                    label: formatter.energyUnitLabel,
                                    tint: .appNutrition,
                                    systemImage: "flame"
                                )
                                StatTile(
                                    value: Units.formatMacro(grams: targets.proteinG),
                                    label: L("onboarding.result.protein")
                                )
                                StatTile(
                                    value: Units.formatMacro(grams: targets.carbsG),
                                    label: L("onboarding.result.carbs")
                                )
                                StatTile(
                                    value: Units.formatMacro(grams: targets.fatG),
                                    label: L("onboarding.result.fat")
                                )
                            }
                            Text(L(
                                "onboarding.result.maintenance",
                                formatter.energy(targets.totalDailyEnergyExpenditure)
                            ))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ForEach(Array(targets.explanations.enumerated()), id: \.offset) { _, explanation in
                        ExplanationNote(text: explanation.text, systemImage: "fork.knife", tint: .appNutrition)
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "fork.knife",
                    title: L("onboarding.result.nutrition.off.title"),
                    message: L("onboarding.result.nutrition.off.message")
                )
            }
        }
    }
}

#Preview("Generating") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .generating) { model in
            GeneratingProgramView(model: model)
        }
    }
}
