import SwiftData
import SwiftUI

/// Logs one body-mass reading.
///
/// Presented from the Progress tab, from the body-weight screen and from the `logBodyWeight` deep
/// link, so it takes no parameters and seeds itself from the last stored reading — the number a
/// user is about to type is almost always within a kilogram of the one before it.
struct BodyWeightEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = BodyWeightEntryViewModel()
    @FocusState private var isNoteFocused: Bool

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    NumberEntryField(
                        title: L("progress.weight.field", formatter.weightUnitLabel),
                        value: $model.displayedWeight,
                        unit: formatter.weightUnitLabel,
                        allowsDecimals: true,
                        range: 0...900,
                        // 0.1 in the user's own unit: the resolution of every bathroom scale, and
                        // small enough that the stepper is a genuine alternative to typing.
                        step: 0.1
                    )

                    DatePicker(
                        L("progress.weight.date"),
                        selection: $model.date,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .tint(Color.appAccent)

                    VStack(alignment: .leading, spacing: Metrics.spacing6) {
                        Text(L("progress.weight.note"))
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        TextField(L("progress.weight.notePlaceholder"), text: $model.note, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.plain)
                            .padding(Metrics.spacing12)
                            .frame(minHeight: Metrics.minimumTapTarget)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                    .fill(Color.appFill)
                            )
                            .focused($isNoteFocused)
                            .accessibilityLabel(Text(L("progress.weight.note")))
                    }

                    if let previous = model.lastWeightKg {
                        ExplanationNote(
                            text: L("progress.weight.previous", formatter.weight(previous)),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }

                    Text(L("progress.weight.noiseNote"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage = model.errorMessage {
                        ErrorStateView(message: errorMessage)
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("progress.weight.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .font(.body.weight(.semibold))
                        .disabled(!model.canSave)
                }
            }
            .onAppear { model.prepare(context: modelContext, formatter: formatter) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        isNoteFocused = false
        if model.save(context: modelContext, formatter: formatter) {
            dismiss()
        }
    }
}

#Preview("Log body weight") {
    PreviewHost(scenario: .seasonedUser) {
        Color.appBackground
            .sheet(isPresented: .constant(true)) {
                BodyWeightEntrySheet()
            }
    }
}
