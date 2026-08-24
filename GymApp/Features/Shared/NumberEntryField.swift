import SwiftUI

/// A large, tappable numeric field built for use mid-set.
///
/// Design constraints come straight from the gym: the target is at least 56 pt tall so it can be
/// hit one-handed without looking; the value uses monospaced digits so the layout does not shift as
/// it changes; the keyboard is decimal or number-pad as appropriate; and a Done button is always
/// reachable because the number pad has no return key.
struct NumberEntryField: View {
    let title: String
    @Binding var value: Double?
    var unit: String?
    var allowsDecimals: Bool = true
    var range: ClosedRange<Double> = 0...9999
    /// Applied when the user taps the plus/minus buttons.
    var step: Double = 2.5
    var showsStepper: Bool = true
    var placeholder: String = "—"

    @FocusState private var isFocused: Bool
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)

            HStack(spacing: Metrics.spacing8) {
                if showsStepper {
                    stepButton(systemImage: "minus", delta: -step)
                }

                HStack(spacing: Metrics.spacing4) {
                    TextField(placeholder, text: $text)
                        .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
                        .multilineTextAlignment(.center)
                        .font(.appNumeric(24))
                        .foregroundStyle(Color.appTextPrimary)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onChange(of: text) { _, newValue in commit(newValue) }
                        .accessibilityLabel(Text(title))
                    if let unit, !text.isEmpty {
                        Text(unit)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.gymTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .strokeBorder(isFocused ? Color.appAccent : .clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
                .onTapGesture { isFocused = true }

                if showsStepper {
                    stepButton(systemImage: "plus", delta: step)
                }
            }
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, newValue in
            // Only rewrite the field when the change came from outside, so typing is never fought.
            let formatted = Self.format(newValue)
            if !isFocused, formatted != text { text = formatted }
        }
        .toolbar {
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("common.done")) { isFocused = false }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func stepButton(systemImage: String, delta: Double) -> some View {
        Button {
            let current = value ?? 0
            let updated = min(max(current + delta, range.lowerBound), range.upperBound)
            value = updated
            text = Self.format(updated)
            Haptics.tap()
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: Metrics.gymTapTarget, height: Metrics.gymTapTarget)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextPrimary)
        .accessibilityLabel(Text(delta > 0 ? L("common.increase") : L("common.decrease")))
    }

    private func commit(_ raw: String) {
        // Accept both decimal separators: users type whichever their keyboard offers.
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let filtered = normalized.filter { $0.isNumber || $0 == "." }
        if filtered != raw {
            text = filtered
            return
        }
        guard !filtered.isEmpty else { value = nil; return }
        guard let parsed = Double(filtered) else { return }
        value = min(max(parsed, range.lowerBound), range.upperBound)
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        if abs(value.rounded() - value) < 0.001 { return String(Int(value.rounded())) }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
}

/// An integer variant, for reps and set counts.
struct IntegerEntryField: View {
    let title: String
    @Binding var value: Int?
    var range: ClosedRange<Int> = 0...500
    var step: Int = 1
    var showsStepper: Bool = true
    var unit: String?

    private var doubleBinding: Binding<Double?> {
        Binding(
            get: { value.map(Double.init) },
            set: { value = $0.map { Int($0.rounded()) } }
        )
    }

    var body: some View {
        NumberEntryField(
            title: title,
            value: doubleBinding,
            unit: unit,
            allowsDecimals: false,
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: Double(step),
            showsStepper: showsStepper
        )
    }
}

/// A compact horizontal picker for small closed sets, e.g. RIR 0…5.
struct SegmentedValuePicker<Value: Hashable>: View {
    let title: String?
    let values: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            if let title {
                Text(title)
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
            }
            HStack(spacing: Metrics.spacing6) {
                ForEach(values, id: \.self) { value in
                    Button {
                        selection = value
                        Haptics.selectionChanged()
                    } label: {
                        Text(label(value))
                            .font(.subheadline.weight(selection == value ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.minimumTapTarget)
                            .foregroundStyle(selection == value ? Color.appOnAccent : Color.appTextSecondary)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                                    .fill(selection == value ? Color.appAccent : Color.appFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}
