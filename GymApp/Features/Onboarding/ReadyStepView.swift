import SwiftData
import SwiftUI

/// Runs the programming engine, writes the result, and then shows the user what it decided.
///
/// The second half is the point. Every other app in this category hands back a program and expects
/// it to be taken on faith; this one shows the week it built and the calories behind it. The
/// reasoning for every choice stays one tap away in the program screen.
///
/// Failure is a first-class outcome, not an alert. The engine can legitimately come back empty for a
/// user whose equipment and limitations leave nothing to program, so the failure state offers both a
/// retry and an empty program they can fill in by hand.
struct ReadyStepView: View {
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
        "onboarding.generate.stage.nutrition",
    ]

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
                .frame(minHeight: 220)
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
                ExplanationNote(
                    text: L("onboarding.generate.manualExplanation"), systemImage: "hand.raised", tint: .appWarning)
            } else {
                weekSection(result)
            }
            nutritionSection(result)
            OnboardingInlineHint(message: L("start.ready.footer"), systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("onboarding.result")
    }

    private func headline(_ result: OnboardingProgramResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(result.isManual ? result.programTitle : L(result.splitKey))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ScaledTileGrid(minimumWidth: 96) {
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

    // MARK: Week

    private func weekSection(_ result: OnboardingProgramResult) -> some View {
        OnboardingSection(L("onboarding.result.week")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(result.trainingSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: GeneratedSession) -> some View {
        HStack(alignment: .center, spacing: Metrics.spacing12) {
            Text(session.weekday.map { L($0.shortLocalizationKey) } ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.customTitle ?? L(session.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    L(
                        "onboarding.result.sessionDetail",
                        session.exercises.count, session.totalSets, session.estimatedMinutes
                    )
                )
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.spacing12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Nutrition

    @ViewBuilder
    private func nutritionSection(_ result: OnboardingProgramResult) -> some View {
        if let targets = result.energyTargets {
            OnboardingSection(L("onboarding.result.nutrition")) {
                Card {
                    VStack(alignment: .leading, spacing: Metrics.spacing12) {
                        HStack(alignment: .top, spacing: Metrics.spacing12) {
                            StatTile(
                                value: formatter.energy(targets.kilocalories, includeUnit: false),
                                label: formatter.energyUnitLabel,
                                tint: .appNutrition,
                                systemImage: "flame"
                            )
                            StatTile(
                                value: Units.formatMacro(grams: targets.proteinG), label: L("onboarding.result.protein")
                            )
                            StatTile(
                                value: Units.formatMacro(grams: targets.carbsG), label: L("onboarding.result.carbs"))
                            StatTile(value: Units.formatMacro(grams: targets.fatG), label: L("onboarding.result.fat"))
                        }
                        if let reason = targets.explanations.first {
                            Text(reason.text)
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

#Preview("Ready") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .ready) { model in
            ReadyStepView(model: model)
        }
    }
}
