import SwiftUI

/// Planned weekly volume per muscle group, drawn against the window `VolumeAllocator` produced.
///
/// The whole point of this chart is that it is a *consequence* view: it is rendered from whatever is
/// currently in the program, so adding a set in the session editor moves a bar here on the same
/// frame. It never blocks anything — a group past its recovery ceiling is annotated, not forbidden,
/// because the ceiling is an estimate about a person the app has known for a few weeks and the
/// person has known for their whole life.
///
/// Everything is measured in volume *credits*: a set of bench press is one credit of chest and half
/// a credit of triceps each. That is the unit the allocator budgets in, so plan and target are
/// directly comparable.
struct WeeklyVolumeChart: View {
    let rows: [VolumeRow]
    /// Groups drawn with emphasis — the ones the screen the chart is embedded in is editing.
    var highlighted: Set<MuscleGroup> = []
    var showsLegend: Bool = true

    var body: some View {
        if rows.isEmpty {
            EmptyStateView(
                systemImage: "chart.bar",
                title: L("program.volume.emptyTitle"),
                message: L("program.volume.emptyMessage")
            )
        } else {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                ForEach(rows) { row in
                    VolumeRowView(row: row, isHighlighted: highlighted.contains(row.group))
                }
                if showsLegend {
                    Divider().overlay(Color.appSeparator)
                    WeeklyVolumeLegend()
                }
            }
        }
    }
}

/// One muscle group: its name, its numbers, and a bar showing where the plan sits in its window.
private struct VolumeRowView: View {
    let row: VolumeRow
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(L(row.group.localizationKey))
                    .font(.subheadline.weight(isHighlighted ? .semibold : .regular))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Metrics.spacing8)

                // The status is spelled out with a symbol as well as a colour, and the numbers
                // themselves carry the information, so nothing here depends on hue alone.
                if row.status != .inRange {
                    Image(systemName: row.status.symbolName)
                        .font(.caption2)
                        .foregroundStyle(row.status.tint)
                }
                Text(L("program.volume.plannedOfTarget",
                       ProgramFormat.sets(row.planned),
                       ProgramFormat.sets(row.target)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
            }

            VolumeBar(row: row, animates: !reduceMotion)

            if row.status != .inRange {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(row.status.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, isHighlighted ? Metrics.spacing6 : 0)
        .padding(.horizontal, isHighlighted ? Metrics.spacing8 : 0)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                .fill(isHighlighted ? Color.appFillSecondary : .clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusMessage: String {
        switch row.status {
        case .belowMinimum: L("program.volume.belowMinimumNote", ProgramFormat.sets(row.minimum))
        case .aboveCeiling: L("program.volume.aboveCeilingNote", ProgramFormat.sets(row.maximum))
        case .inRange: ""
        }
    }

    private var accessibilityLabel: String {
        let base = L("program.volume.axLabel",
                     L(row.group.localizationKey),
                     ProgramFormat.sets(row.planned),
                     ProgramFormat.sets(row.target),
                     ProgramFormat.sets(row.minimum),
                     ProgramFormat.sets(row.maximum))
        return "\(base), \(L(row.status.localizationKey))"
    }
}

/// The bar itself: a recovery window, a target tick and the planned volume.
private struct VolumeBar: View {
    let row: VolumeRow
    let animates: Bool

    private let height: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appFill)

                // The band between the minimum that still produces progress and the ceiling beyond
                // which recovery, not stimulus, becomes the limit.
                Rectangle()
                    .fill(Color.forGroup(row.group).opacity(0.18))
                    .frame(width: max(0, width * (row.fraction(of: row.maximum) - row.fraction(of: row.minimum))))
                    .offset(x: width * row.fraction(of: row.minimum))

                Capsule()
                    .fill(barTint)
                    .frame(width: max(height * 0.4, width * row.fraction(of: row.planned)))

                // The number the program is aiming for.
                Rectangle()
                    .fill(Color.appTextPrimary.opacity(0.55))
                    .frame(width: 2, height: height + 6)
                    .offset(x: min(width - 2, width * row.fraction(of: row.target)))
            }
            .clipShape(Capsule())
            .animation(animates ? .easeOut(duration: 0.25) : nil, value: row.planned)
        }
        .frame(height: height)
        // The bar restates the numbers already read out by the row, so VoiceOver skips it.
        .accessibilityHidden(true)
    }

    private var barTint: Color {
        row.status == .aboveCeiling ? Color.appWarning : Color.forGroup(row.group)
    }
}

/// Explains the three marks on every bar. Without it the band and the tick are decoration.
struct WeeklyVolumeLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            legendRow(color: Color.appAccent, text: L("program.volume.legend.planned"))
            legendRow(color: Color.appAccent.opacity(0.18), text: L("program.volume.legend.window"))
            legendRow(color: Color.appTextPrimary.opacity(0.55), text: L("program.volume.legend.target"))
        }
        .accessibilityElement(children: .combine)
    }

    private func legendRow(color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 14, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown with one group under its minimum and one past its ceiling, because a chart where
/// everything is fine tells you nothing about whether the warnings read correctly.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ScrollView {
            Card {
                WeeklyVolumeChart(
                    rows: [
                        VolumeRow(group: .back, planned: 18, minimum: 12, target: 17, maximum: 24),
                        VolumeRow(group: .chest, planned: 21.5, minimum: 9, target: 13, maximum: 18),
                        VolumeRow(group: .quads, planned: 6, minimum: 9, target: 13, maximum: 18),
                        VolumeRow(group: .biceps, planned: 9, minimum: 7, target: 10, maximum: 14),
                    ],
                    highlighted: [.chest]
                )
            }
            .screenPadding()
            .readableWidth()
        }
        .background(Color.appBackground)
    }
}
