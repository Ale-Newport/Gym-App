import SwiftUI

/// What the user can train with.
///
/// Four presets cover almost everyone, and each states how many exercises it unlocks — the honest
/// answer to "does this choice matter?". Anything finer than a preset (a specific machine, the
/// plates the gym stocks) lives in Settings. Limitations are one optional line, closed by default:
/// most people have none, and the ones who do need to be able to say so before the program is built.
struct GearStepView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppEnvironment.self) private var environment

    @State private var showsLimitations = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            presets
            limitations
        }
        .task {
            // Reopened with limitations already on file: show them rather than hiding what the
            // program will be built around.
            if !model.mobilityLimitations.isEmpty { showsLimitations = true }
        }
    }

    // MARK: - Presets

    private var presets: some View {
        VStack(spacing: Metrics.spacing8) {
            ForEach(OnboardingSchedule.equipmentPresets) { preset in
                OnboardingChoiceRow(
                    title: L(preset.localizationKey),
                    detail:
                        "\(L(preset.detailLocalizationKey)) · \(L("onboarding.equipment.unlocks", model.exerciseCount(for: preset.equipment, catalog: environment.catalog)))",
                    isSelected: model.equipmentPreset == preset
                ) {
                    model.applyEquipmentPreset(preset)
                }
            }

            if let hint = model.hint(for: "selectedEquipment") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }
        }
    }

    // MARK: - Limitations

    private var limitations: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.2)) { showsLimitations.toggle() }
            } label: {
                HStack(spacing: Metrics.spacing8) {
                    Text(L("start.gear.limitations"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                    Spacer(minLength: 0)
                    Image(systemName: showsLimitations ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(Text(showsLimitations ? L("start.gear.limitations.open") : ""))

            if showsLimitations {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    FlowLayout {
                        ForEach(MobilityLimitation.allCases) { limitation in
                            OnboardingChip(
                                title: L(limitation.localizationKey),
                                isSelected: model.mobilityLimitations.contains(limitation)
                            ) {
                                model.toggleLimitation(limitation)
                            }
                        }
                    }
                    OnboardingInlineHint(message: L("start.gear.limitations.detail"), systemImage: "hand.raised")
                }
                .transition(.opacity)
            }
        }
    }
}

#Preview("Gear") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .gear) { model in
            GearStepView(model: model)
        }
    }
}
