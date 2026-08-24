import SwiftUI

/// The library's filter sheet.
///
/// Every option carries the number of catalogue records behind it, taken from the catalogue itself
/// rather than from a hand-maintained list, so the sheet can never offer a filter that returns
/// nothing. Filters apply live to the list underneath — the dismiss button therefore reports the
/// exact number of exercises the user is about to look at rather than asking them to commit blind.
struct ExerciseFilterSheet: View {
    @Binding var filters: ExerciseFilterState
    let viewModel: ExerciseLibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var matchCount = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing24) {
                    quickFilters
                    mechanicFilter
                    difficultyFilter
                    facetSection(
                        titleKey: "exercises.filters.bodyPart",
                        values: viewModel.availableBodyParts,
                        title: { L($0.localizationKey) },
                        count: { viewModel.facets.bodyParts[$0] ?? 0 },
                        isSelected: { filters.bodyParts.contains($0) },
                        toggle: { toggle($0, in: &filters.bodyParts) }
                    )
                    facetSection(
                        titleKey: "exercises.filters.muscleGroup",
                        values: viewModel.availableMuscleGroups,
                        title: { L($0.localizationKey) },
                        count: { viewModel.facets.muscleGroups[$0] ?? 0 },
                        isSelected: { filters.muscleGroups.contains($0) },
                        toggle: { toggle($0, in: &filters.muscleGroups) }
                    )
                    facetSection(
                        titleKey: "exercises.filters.equipment",
                        values: viewModel.availableEquipment,
                        title: { L($0.localizationKey) },
                        count: { viewModel.facets.equipment[$0] ?? 0 },
                        isSelected: { filters.equipment.contains($0) },
                        toggle: { toggle($0, in: &filters.equipment) }
                    )
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.vertical, Metrics.spacing20)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("exercises.filters.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.clearAll")) {
                        filters.clear()
                        Haptics.tap()
                    }
                    .disabled(!filters.isActive)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text(LPlural("exercises.filters.showCount", matchCount))
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.vertical, Metrics.spacing12)
                .background(.bar)
                .readableWidth()
            }
        }
        .presentationDragIndicator(.visible)
        .task { matchCount = viewModel.matchCount(for: filters) }
        .onChange(of: filters) { matchCount = viewModel.matchCount(for: filters) }
    }

    // MARK: - Sections

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(L("exercises.filters.quick"))
            FlowLayout {
                FacetChip(
                    title: L("exercises.filters.favoritesOnly"),
                    count: viewModel.facets.favorites,
                    systemImage: "heart.fill",
                    isSelected: filters.favoritesOnly
                ) { filters.favoritesOnly.toggle() }

                FacetChip(
                    title: L("exercises.filters.recentlyPerformed"),
                    count: viewModel.facets.recentlyPerformed,
                    systemImage: "clock.arrow.circlepath",
                    isSelected: filters.recentlyPerformedOnly
                ) { filters.recentlyPerformedOnly.toggle() }

                FacetChip(
                    title: L("exercises.filters.bodyweightOnly"),
                    count: viewModel.facets.bodyweight,
                    systemImage: "figure.stand",
                    isSelected: filters.bodyweightOnly
                ) { filters.bodyweightOnly.toggle() }
            }
        }
    }

    private var mechanicFilter: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(L("exercises.filters.mechanic"))
            FlowLayout {
                ForEach(Mechanic.allCases, id: \.self) { mechanic in
                    FacetChip(
                        title: L(mechanic.localizationKey),
                        count: viewModel.facets.mechanics[mechanic] ?? 0,
                        systemImage: nil,
                        isSelected: filters.mechanic == mechanic
                    ) {
                        // Tapping the selected value clears it: "any" is the absence of a choice,
                        // not a third option the user has to hunt for.
                        filters.mechanic = filters.mechanic == mechanic ? nil : mechanic
                    }
                }
            }
        }
    }

    private var difficultyFilter: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(L("exercises.filters.difficulty"))
            FlowLayout {
                ForEach(Difficulty.allCases, id: \.self) { difficulty in
                    FacetChip(
                        title: L(difficulty.localizationKey),
                        count: viewModel.facets.difficulties[difficulty] ?? 0,
                        systemImage: nil,
                        isSelected: filters.difficulties.contains(difficulty)
                    ) {
                        toggle(difficulty, in: &filters.difficulties)
                    }
                }
            }
        }
    }

    private func facetSection<Value: Hashable>(
        titleKey: String,
        values: [Value],
        title: @escaping (Value) -> String,
        count: @escaping (Value) -> Int,
        isSelected: @escaping (Value) -> Bool,
        toggle: @escaping (Value) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(L(titleKey))
            FlowLayout {
                ForEach(values, id: \.self) { value in
                    FacetChip(
                        title: title(value),
                        count: count(value),
                        systemImage: nil,
                        isSelected: isSelected(value)
                    ) {
                        toggle(value)
                    }
                }
            }
        }
    }

    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - Chip

/// A filter option with the number of catalogue records behind it.
private struct FacetChip: View {
    let title: String
    let count: Int
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            Haptics.selectionChanged()
        } label: {
            Chip(
                // The count sits inside the label so the chip stays one visual unit at every Dynamic
                // Type size; VoiceOver reads the two apart via the value below.
                title: "\(title)  \(count)",
                systemImage: systemImage,
                isSelected: isSelected
            )
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(LPlural("exercises.filters.chipCount", count)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Filters") {
    PreviewHost(scenario: .seasonedUser) {
        FilterSheetPreviewHost()
    }
}

/// Owns the state the sheet binds to, so the preview exercises the real live-count behaviour.
private struct FilterSheetPreviewHost: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel = ExerciseLibraryViewModel(mode: .browse)
    @State private var filters = ExerciseFilterState(
        muscleGroups: [.chest],
        equipment: [.barbell, .dumbbell]
    )

    var body: some View {
        ExerciseFilterSheet(filters: $filters, viewModel: viewModel)
            .task { viewModel.load(catalog: environment.catalog, preferences: []) }
    }
}
