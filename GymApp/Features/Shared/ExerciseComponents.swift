import SwiftUI

/// The standard exercise row: thumbnail, name, and one line of metadata.
///
/// Used by the library, the picker, the program editor and the substitution sheet, so that an
/// exercise looks the same everywhere the user meets it. Thumbnails only — never an animation —
/// because rows appear in lists of hundreds.
struct ExerciseRowView: View {
    let exercise: Exercise
    var thumbnailURL: URL?
    /// Extra line under the metadata, e.g. "Last: 60 kg × 8".
    var detail: String?
    var isFavorite: Bool = false
    var isExcluded: Bool = false
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            ExerciseThumbnail(url: thumbnailURL)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Metrics.spacing4) {
                    Text(exercise.name.localizedCapitalized)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .opacity(isExcluded ? 0.45 : 1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metadataLine: String {
        [L(exercise.target.localizationKey), L(exercise.equipment.localizationKey)]
            .joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [exercise.name, metadataLine]
        if let detail { parts.append(detail) }
        if isFavorite { parts.append(L("exercise.favorite")) }
        if isExcluded { parts.append(L("exercise.excluded")) }
        return parts.joined(separator: ", ")
    }
}

/// The large, dominant animation used on exercise detail and during a workout.
///
/// The product requirement is explicit: while training, seeing the movement clearly matters more
/// than anything else on screen. This view therefore takes as much width as it is given, keeps a
/// square aspect, and carries the mandatory media credit underneath.
struct ExerciseMediaHero: View {
    let exercise: Exercise
    let animationURL: URL?
    let thumbnailURL: URL?
    var attribution: String?
    var attributionURL: URL?
    var isPlaying: Bool = true
    var showsAttribution: Bool = true
    var cornerRadius: CGFloat = Metrics.cornerLarge

    var body: some View {
        VStack(spacing: Metrics.spacing6) {
            AnimatedExerciseImage(
                url: animationURL,
                placeholderURL: thumbnailURL,
                isPlaying: isPlaying
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.appSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.appSeparator.opacity(0.5), lineWidth: 0.5)
            )
            .accessibilityElement()
            .accessibilityLabel(Text(L("exercise.animationLabel", exercise.name)))

            if showsAttribution {
                MediaAttributionLabel(attribution: attribution, url: attributionURL)
            }
        }
    }
}

/// Compact muscle-group tag with its stable colour.
struct MuscleGroupBadge: View {
    let group: MuscleGroup
    var showsIcon: Bool = false

    var body: some View {
        HStack(spacing: Metrics.spacing4) {
            if showsIcon {
                Image(systemName: group.symbolName).font(.caption2)
            }
            Text(L(group.localizationKey))
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, Metrics.spacing8)
        .padding(.vertical, 3)
        .foregroundStyle(Color.forGroup(group))
        .background(Color.forGroup(group).opacity(0.14), in: Capsule())
    }
}

/// The metadata grid shown on the exercise detail screen.
struct ExerciseFactsGrid: View {
    let exercise: Exercise

    private var facts: [(labelKey: String, value: String)] {
        var rows: [(String, String)] = [
            ("exercise.fact.target", L(exercise.target.localizationKey)),
            ("exercise.fact.bodyPart", L(exercise.bodyPart.localizationKey)),
            ("exercise.fact.equipment", L(exercise.equipment.localizationKey)),
            ("exercise.fact.mechanic", L(exercise.metadata.mechanic.localizationKey)),
            ("exercise.fact.pattern", L(exercise.metadata.movementPattern.localizationKey)),
            ("exercise.fact.difficulty", L(exercise.metadata.difficulty.localizationKey)),
        ]
        if !exercise.secondaryMuscles.isEmpty {
            rows.append((
                "exercise.fact.secondary",
                exercise.secondaryMuscles.map { L($0.localizationKey) }.joined(separator: ", ")
            ))
        }
        if exercise.metadata.trackingMode.usesReps {
            rows.append(("exercise.fact.repRange", exercise.metadata.recommendedRepRange.description))
        }
        rows.append(("exercise.fact.rest", Units.formatDuration(seconds: exercise.metadata.defaultRestSeconds)))
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .top) {
                    Text(L(fact.labelKey))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: Metrics.spacing12)
                    Text(fact.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, Metrics.spacing8)
                .accessibilityElement(children: .combine)

                if index < facts.count - 1 {
                    Divider().overlay(Color.appSeparator)
                }
            }
        }
    }
}

/// Step-by-step instructions from the dataset, in the active language.
struct ExerciseInstructionsView: View {
    let steps: [String]

    var body: some View {
        if steps.isEmpty {
            Text(L("exercise.noInstructions"))
                .font(.subheadline)
                .foregroundStyle(Color.appTextTertiary)
        } else {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 22, height: 22)
                            .background(Color.appAccent.opacity(0.14), in: Circle())
                        Text(step)
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(L("exercise.stepLabel", index + 1, step)))
                }
            }
        }
    }
}
