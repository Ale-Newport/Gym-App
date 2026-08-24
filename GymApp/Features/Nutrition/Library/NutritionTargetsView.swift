import SwiftUI
import SwiftData

/// The daily energy and macro targets, with the arithmetic that produced them.
///
/// Three rules shape this screen. Every number shows its working, because a calorie target the user
/// cannot audit is one they cannot sensibly overrule. Every number can be overridden by hand, and
/// going back to automatic is one tap. And the adjustment engine only ever *proposes* — the Accept
/// button here is the only thing that can move somebody's calories, which is what makes the rest of
/// the app's numbers worth trusting.
struct NutritionTargetsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = NutritionTargetsViewModel()
    @State private var isEditingManually = false
    @State private var isShowingHistory = false

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.targets.title"))
            .task { await model.load(context: modelContext) }
            .sheet(isPresented: $isEditingManually) {
                manualOverrideSheet
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let explanation):
            ErrorStateView(
                message: explanation.text,
                retryTitle: L("common.retry"),
                retry: { Task { await model.load(context: modelContext) } }
            )
        case .ready:
            ScrollView {
                VStack(spacing: Metrics.spacing16) {
                    if let failure = model.actionFailure {
                        FailureBanner(explanation: failure) { model.clearFailure() }
                    }
                    if let proposal = model.visibleProposal {
                        proposalCard(proposal)
                    }
                    if model.hasStoredTarget {
                        targetCard
                        energyBreakdownCard
                        reasoningCard
                        historyCard
                    } else {
                        noTargetState
                        energyBreakdownCard
                        reasoningCard
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
        }
    }

    // MARK: - Current target

    private var targetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    title: L("nutritionLibrary.targets.currentTitle"),
                    subtitle: L(model.isManualOverride
                        ? "nutritionLibrary.targets.manualSubtitle"
                        : "nutritionLibrary.targets.automaticSubtitle")
                ) { EmptyView() }

                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                    Text(formatter.energy(model.current.kilocalories, includeUnit: false))
                        .font(.appNumeric(40, weight: .bold))
                        .foregroundStyle(Color.appNutrition)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(formatter.energyUnitLabel)
                        .font(.headline)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(L(
                    "nutritionLibrary.targets.energyAccessibility",
                    formatter.energy(model.current.kilocalories)
                )))

                macroRow(
                    label: L("nutritionLibrary.food.protein"),
                    grams: model.current.proteinG,
                    energyShare: model.current.energyShares.protein,
                    tint: .appAccent
                )
                macroRow(
                    label: L("nutritionLibrary.food.carbs"),
                    grams: model.current.carbsG,
                    energyShare: model.current.energyShares.carbs,
                    tint: .appNutrition
                )
                macroRow(
                    label: L("nutritionLibrary.food.fat"),
                    grams: model.current.fatG,
                    energyShare: model.current.energyShares.fat,
                    tint: .appRecovery
                )

                HStack(spacing: Metrics.spacing8) {
                    Button(L("nutritionLibrary.targets.override")) {
                        model.seedDraft()
                        isEditingManually = true
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if model.isManualOverride {
                        Button(L("nutritionLibrary.targets.reset")) {
                            Task { _ = await model.resetToAutomatic() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                NavigationLink {
                    MicronutrientDetailView()
                } label: {
                    HStack {
                        Text(L("nutritionLibrary.micros.title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func macroRow(label: String, grams: Double, energyShare: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                Text(L(
                    "nutritionLibrary.targets.macroValue",
                    formatter.macro(grams),
                    NutritionFormat.percent(energyShare)
                ))
                .font(.appNumeric(15, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
            }
            ProgressBar(value: energyShare, total: 1, tint: tint, height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L(
            "nutritionLibrary.targets.macroAccessibility",
            label,
            formatter.macro(grams),
            NutritionFormat.percent(energyShare)
        )))
    }

    private var noTargetState: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                EmptyStateView(
                    systemImage: "target",
                    title: L("nutritionLibrary.targets.noTargetTitle"),
                    message: L("nutritionLibrary.targets.noTargetMessage")
                )
                Button(L("nutritionLibrary.targets.useAutomatic", formatter.energy(model.automatic.kilocalories))) {
                    Task { _ = await model.resetToAutomatic() }
                }
                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
            }
        }
    }

    // MARK: - Energy breakdown

    private var energyBreakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.targets.breakdownTitle"),
                    subtitle: L("nutritionLibrary.targets.breakdownSubtitle")
                ) { EmptyView() }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        restingTile
                        maintenanceTile
                        offsetTile
                    }
                    Grid(alignment: .leading, horizontalSpacing: Metrics.spacing12, verticalSpacing: Metrics.spacing12) {
                        GridRow { restingTile; maintenanceTile }
                        GridRow { offsetTile; Color.clear.frame(height: 1) }
                    }
                }

                Text(rateLine)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let trendWeight = model.trend.currentTrendKg {
                    Text(L(
                        "nutritionLibrary.targets.trendWeight",
                        formatter.weight(trendWeight),
                        NutritionFormat.signedOneDecimal(model.trend.weeklyChangeKg ?? 0)
                    ))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var restingTile: some View {
        StatTile(
            value: formatter.energy(model.current.basalMetabolicRate, includeUnit: false),
            label: L("nutritionLibrary.targets.bmr"),
            caption: L("nutritionLibrary.targets.bmrCaption"),
            tint: .appTextPrimary
        )
    }

    private var maintenanceTile: some View {
        StatTile(
            value: formatter.energy(model.current.totalDailyEnergyExpenditure, includeUnit: false),
            label: L("nutritionLibrary.targets.tdee"),
            caption: L("nutritionLibrary.targets.tdeeCaption"),
            tint: .appTextPrimary
        )
    }

    /// The deficit or surplus. The word carries the direction as well as the sign, so the
    /// information is never in the sign alone.
    private var offsetTile: some View {
        let offset = model.energyOffset
        let labelKey: String = offset < -1
            ? "nutritionLibrary.targets.deficit"
            : (offset > 1 ? "nutritionLibrary.targets.surplus" : "nutritionLibrary.targets.balanced")
        return StatTile(
            value: formatter.energy(abs(offset), includeUnit: false),
            label: L(labelKey),
            caption: L("nutritionLibrary.targets.offsetCaption"),
            tint: offset < -1 ? .appRecovery : (offset > 1 ? .appAccent : .appTextPrimary)
        )
    }

    private var rateLine: String {
        let weekly = model.current.weeklyBodyMassChangeKg
        guard abs(weekly) >= 0.05 else { return L("nutritionLibrary.targets.rateNone") }
        return L(
            "nutritionLibrary.targets.rate",
            formatter.weight(abs(weekly)),
            L(weekly < 0 ? "nutritionLibrary.targets.rateLoss" : "nutritionLibrary.targets.rateGain")
        )
    }

    // MARK: - Reasoning

    private var reasoningCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.targets.reasoningTitle"),
                    subtitle: L("nutritionLibrary.targets.reasoningSubtitle")
                ) { EmptyView() }
                ForEach(Array(model.automatic.explanations.enumerated()), id: \.offset) { _, explanation in
                    ExplanationNote(text: explanation.text)
                }
            }
        }
    }

    // MARK: - Proposal

    /// The adjustment engine's proposal, never applied on its own.
    private func proposalCard(_ proposal: CalorieAdjustmentDecision) -> some View {
        Card(background: .appSurfaceElevated) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Label {
                    Text(L(proposal.action.localizationKey))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                } icon: {
                    Image(systemName: proposal.deltaKilocalories > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(Color.appNutrition)
                }

                ExplanationNote(text: proposal.explanation.text, systemImage: "chart.line.uptrend.xyaxis")

                if let proposed = proposal.newTargets {
                    InsetGroup {
                        VStack(alignment: .leading, spacing: Metrics.spacing6) {
                            Text(L(
                                "nutritionLibrary.targets.proposedEnergy",
                                formatter.energy(model.current.kilocalories),
                                formatter.energy(proposed.kilocalories)
                            ))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            Text(L(
                                "nutritionLibrary.common.macroLine",
                                formatter.energy(proposed.kilocalories),
                                formatter.macro(proposed.proteinG),
                                formatter.macro(proposed.carbsG),
                                formatter.macro(proposed.fatG)
                            ))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(L("nutritionLibrary.targets.proposalConsent"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Metrics.spacing8) {
                    Button(L("nutritionLibrary.targets.accept")) {
                        Task { _ = await model.acceptProposal() }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))

                    Button(L("nutritionLibrary.targets.notNow")) {
                        model.dismissProposal()
                        Task { await model.load(context: modelContext) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 140)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - History

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.targets.historyTitle"),
                    subtitle: L("nutritionLibrary.targets.historySubtitle")
                ) {
                    if model.history.count > 3 {
                        Button(L(isShowingHistory ? "common.showLess" : "common.showMore")) {
                            isShowingHistory.toggle()
                        }
                        .font(.footnote.weight(.semibold))
                        .minimumTapTarget()
                    }
                }

                if model.history.isEmpty {
                    Text(L("nutritionLibrary.targets.historyEmpty"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(isShowingHistory ? model.history : Array(model.history.prefix(3))) { row in
                        historyRow(row)
                    }
                }
            }
        }
    }

    private func historyRow(_ row: TargetChangeRow) -> some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                HStack {
                    Text(formatter.mediumDate(row.changedAt))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: Metrics.spacing8)
                    Text(L(row.wasAutomatic
                        ? "nutritionLibrary.targets.historyAutomatic"
                        : "nutritionLibrary.targets.historyManual"))
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
                Text(L(
                    "nutritionLibrary.targets.historyChange",
                    formatter.energy(row.previous.kilocalories),
                    formatter.energy(row.updated.kilocalories)
                ))
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                Text(row.reason.text)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Manual override

    private var manualOverrideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    Text(L("nutritionLibrary.targets.overrideMessage"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    NumberEntryField(
                        title: L("nutritionLibrary.targets.energyField"),
                        value: $model.draftKilocalories,
                        unit: formatter.energyUnitLabel,
                        allowsDecimals: false,
                        range: InputValidation.kilocalories.lowerBound...InputValidation.kilocalories.upperBound,
                        step: 50
                    )
                    NumberEntryField(
                        title: L("nutritionLibrary.food.protein"),
                        value: $model.draftProtein,
                        unit: "g",
                        allowsDecimals: false,
                        range: 0...InputValidation.macroGrams.upperBound,
                        step: 5
                    )
                    NumberEntryField(
                        title: L("nutritionLibrary.food.carbs"),
                        value: $model.draftCarbs,
                        unit: "g",
                        allowsDecimals: false,
                        range: 0...InputValidation.macroGrams.upperBound,
                        step: 5
                    )
                    NumberEntryField(
                        title: L("nutritionLibrary.food.fat"),
                        value: $model.draftFat,
                        unit: "g",
                        allowsDecimals: false,
                        range: 0...InputValidation.macroGrams.upperBound,
                        step: 5
                    )

                    // Both notes warn rather than block. The user is entitled to a plan the app
                    // would not have chosen; they are not entitled to be kept in the dark about it.
                    if let entered = model.draftKilocalories, model.draftImpliedKilocalories > 0,
                       abs(model.draftImpliedKilocalories - entered) >= 25 {
                        ExplanationNote(
                            text: L(
                                "nutritionLibrary.targets.macroMismatch",
                                formatter.energy(model.draftImpliedKilocalories),
                                formatter.energy(entered)
                            ),
                            systemImage: "exclamationmark.circle",
                            tint: .appWarning
                        )
                    }
                    if model.isDraftBelowSafeMinimum {
                        ExplanationNote(
                            text: L(
                                "nutritionLibrary.targets.belowFloor",
                                formatter.energy(model.safeMinimumKilocalories)
                            ),
                            systemImage: "exclamationmark.triangle",
                            tint: .appWarning
                        )
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.targets.override"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { isEditingManually = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        Task {
                            if await model.saveManualOverride() { isEditingManually = false }
                        }
                    }
                }
            }
        }
    }
}

#Preview("Nutrition targets") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            NutritionTargetsView()
        }
    }
}
