# Exercise metadata derivation

**Source:** `GymApp/Data/ExerciseDataset/ExerciseMetadataDeriver.swift`
**Tests:** `GymAppTests/ExerciseMetadataDeriverTests.swift`

## The problem

The upstream dataset gives each exercise a name, a body part, an equipment string, a target muscle,
a synergist and a list of secondary muscles. It does **not** say whether a movement is a compound or
an isolation, which pattern it belongs to, how fatiguing it is, how it should be loaded, or whether
it should be logged in reps or in seconds. Every programming decision depends on those judgements.

They are therefore derived once, deterministically, from rules written down here and unit-tested.
No network call and no language model is involved.

## Normalising the vocabularies

The dataset uses three overlapping muscle vocabularies — `target` (19 spellings), `muscle_group`
(29) and `secondary_muscles` (40) — which disagree with each other: `traps` and `trapezius`,
`lats` and `latissimus dorsi`, `delts`, `deltoids` and `shoulders` all appear. `Muscle.init(datasetValue:)`
in `Taxonomy.swift` owns every alias and maps them onto 29 canonical muscles. Unknown spellings
return `nil` rather than collapsing into a wrong bucket; the dataset audit surfaces them.

Canonical muscles roll up into 18 `MuscleGroup` values, which are the unit in which weekly volume,
frequency and recovery are tracked.

## Movement pattern

Keyword rules over the normalised name, evaluated **specific to general**, first match wins, with a
target-muscle fallback so every record gets a usable pattern. Matching is plural-tolerant (`hip
thrust` also matches `hip thrusts`), because the dataset spells the same movement both ways.

Order matters, and three words in particular are overloaded:

| Word | Disambiguated by |
|---|---|
| `raise` | A *lateral* raise is a shoulder movement, a *leg* raise is core work, a *calf* raise is a calf movement. Calf raises are matched first; leg, knee and hip raises are then resolved on the target muscle; only what remains reaches the shoulder-raise rule. |
| `bridge` | A *glute* bridge is hip extension; a *side* bridge is a plank. Resolved on the target muscle. |
| `extension` | A *triceps* extension is elbow extension; a *leg* extension is knee extension; a *hip* extension is a hinge. The leg and hip cases are matched before the generic elbow rule. |

## Mechanic, push/pull, laterality

- **Mechanic** follows from the pattern. Core patterns are the exception: loaded multi-joint core
  work (an ab wheel rollout, a hanging leg raise) with three or more secondary muscles counts as a
  compound.
- **Push/pull class** follows from the pattern, and drives antagonist balancing across a week.
- **Laterality** is keyword-based (`one arm`, `single leg`, `alternate`, plus every lunge pattern).
  Unilateral work carries a `timeMultiplier` of 1.7, because two sides take longer than one — which
  is what keeps the session-length budget honest.

## Tracking mode

What a set is *measured in*, so the logger never asks for reps on a plank or a weight on a
treadmill run:

| Condition | Mode |
|---|---|
| Name contains `stretch`/`mobility` | `duration` |
| Cardio body part, on a machine | `distanceAndDuration` |
| Cardio, running or walking | `distanceAndDuration` |
| Other cardio | `duration` |
| Name contains `plank`, `hold`, `hang`, `wall sit`, `isometric`… | `duration` |
| Carry pattern | `weightAndDuration` |
| Equipment `assisted` | `assistedBodyweight` |
| Equipment `weighted` or `body weight` | `weightedBodyweight` (added load defaults to zero) |
| Bands, balls, rollers, rope | `repsOnly` |
| Everything else | `weightAndReps` |

Bodyweight strength movements deliberately use `weightedBodyweight` rather than `repsOnly`: a
pull-up genuinely progresses as *bodyweight + 10 kg*, and the added-load field simply sits at zero
until the user needs it.

## Continuous scores

All are clamped to their documented range.

**`stabilityDemand`** (0.05…1) — a base per equipment (machine 0.10, Smith 0.18, cable 0.32,
barbell 0.52, dumbbell 0.58, kettlebell 0.66, stability ball 0.88), +0.14 unilateral,
+0.12 plyometric, +0.08 standing or overhead, −0.12 seated/lying/supported.

**`fatigueCost`** (0.03…1) — a base per pattern (hinge 0.95, squat 0.90, lunge 0.72, carry 0.70,
vertical push 0.62 … isolation 0.18–0.24, mobility 0.04), then ×1.12 for a barbell, ×0.86 for a
machine, ×0.72 for a band, ×0.92 for an isolation, ×0.92 unilateral, ×1.10 plyometric.

**`progressionSuitability`** (0.05…1) — how readily load can be added: barbell 1.00, EZ bar 0.92,
machine stack 0.90, cable 0.88, dumbbell 0.86, weighted bodyweight 0.80, assisted 0.72, kettlebell
0.58 (fixed jumps), bodyweight 0.45, band 0.32, none 0.20.

**`stimulusScore`** (0.05…1) — `0.45 + (0.18 compound | 0.12 isolation) + 0.28 × progressionSuitability
− 0.35 × max(0, stabilityDemand − 0.55)`. A good hypertrophy set needs load that can be progressed
and enough stability that the target muscle, rather than the stabilisers, is the limiting factor.

**`stapleScore`** (0.02…1) — a tie-breaker only, so that given two equally suitable exercises the
recognisable one wins and generated programs do not fill up with obscure variations. Built from
mechanic, equipment, name length, the dataset's own variant markers (`v. 2`, `(male)`), and a bonus
for a primary compound pattern loaded with a bar, dumbbells or bodyweight.

## Rep ranges and rest

Derived from pattern, mechanic and equipment: barbell squat and hinge 5–8; other compounds 6–10;
chest flies, raises and shrugs 10–15; arms 8–14; calves 10–20; core 10–20; abduction/adduction
12–20. Rest is 210 s for loaded squat and hinge, 165 s for other compounds, 105 s for accessory
work, 60–75 s for isolation and core.

`estimatedSetSeconds` is `midpointReps × 3.5 s + (25 s compound | 12 s isolation)`, multiplied by
the laterality factor. This is what the programming engine uses to guarantee a session actually
fits the user's stated time.

## Volume contribution

The target group earns a **full set** (1.0). Synergists and listed secondary muscles earn a **half
set** for compounds and a third for isolations — the widely used direct/indirect convention. A group
never earns more than one full set from a single exercise.

Stretches, cardio and distance-tracked work contribute **nothing**. A skipping-rope round genuinely
works the calves, but counting it as calf volume would corrupt every recovery and progression
decision downstream.

## Substitution tags

A free-form tag set per exercise — position (`incline`, `seated`, `lying`, `prone`), grip
(`close_grip`, `wide_grip`, `reverse_grip`, `neutral_grip`), equipment class (`machine`, `cable`,
`free_weight`, `band`, `bodyweight`), and the safety tags that mobility limitations filter on
(`overhead`, `axial_load`, `hinge`, `deep_knee`, `wrist_loaded`, `grip_limited`,
`deep_stretch_shoulder`). These are what let the substitution engine find a genuinely like-for-like
swap rather than merely another exercise for the same muscle.

## Verified output over the full catalogue

Running the deriver across all 1,324 records produces:

| Dimension | Distribution |
|---|---|
| Mechanic | 663 compound / 661 isolation |
| Tracking | 820 weight×reps, 297 bodyweight+load, 95 reps-only, 89 duration, 14 distance, 7 assisted, 2 weight+time |
| Difficulty | 636 beginner / 559 intermediate / 129 advanced |
| Laterality | 1,083 bilateral / 203 unilateral / 38 alternating |
| Push/pull | 431 pull, 353 push, 273 legs, 171 core, 67 neutral, 29 cardio |
| Empty volume contribution | 87 (56 stretches + 29 cardio + 2 non-loading) |
| Unresolved muscle strings | 0 |
