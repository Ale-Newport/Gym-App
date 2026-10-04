# Algorithms

Every recommendation Forge makes is produced by deterministic code that runs entirely on the
device. There is no model call, no server and no hidden randomness: the same inputs always produce
the same output, and every rule below is unit-tested.

This document is the specification. Where the code and this document disagree, the document is
right and the code has a bug.

> **Not medical advice.** These are estimates produced by published formulas and by conventions
> drawn from mainstream strength and nutrition practice. They are not measurements, diagnoses or
> clinical guidance, and the app never presents them as such.

## How the pieces fit together

```
UserProfile + EquipmentProfile
        |
        v
TrainingProfileSnapshot ──> VolumeAllocator ──> weekly set targets per muscle group
                                  |
                                  v
                            SplitSelector ──> session blueprints
                                  |
                                  v
                 ExerciseRecommendationEngine ──> ExerciseScoring ──> a ranked exercise per slot
                                  |
                                  v
                       WorkoutProgrammingEngine ──> GeneratedProgram
                                  |
        performed sets ───────────┴──────────> ProgressionEngine ──> next session's loads
                |                                      ^
                v                                      |
        RecoveryEngine ──> fatigue per group ──> AutoregulationEngine
                |                                      |
                v                                      v
          DeloadEngine ──────────────────────> volume and intensity adjustments
```

Nutrition runs alongside on the same principle:

```
NutritionProfileSnapshot ──> NutritionRecommendationEngine ──> energy + macro targets
        body-weight log ──> WeightTrendAnalyzer ──> NutritionAdjustmentEngine ──> proposed change
       remaining macros ──> MealRecommendationEngine ──> scored meal suggestions
```


## Contents

- [Exercise metadata derivation](#exercise-metadata-derivation)
- [Exercise scoring, selection and substitution](#exercise-scoring-selection-and-substitution)
- [Split selection, weekly volume and program generation](#split-selection-weekly-volume-and-program-generation)
- [Progression, 1RM estimation and personal records](#progression-1rm-estimation-and-personal-records)
- [Recovery, deload and autoregulation](#recovery-deload-and-autoregulation)
- [Energy, macros, weight trend and meal recommendation](#energy-macros-weight-trend-and-meal-recommendation)
- [The bundled food database](#the-bundled-food-database)
- [Persistence boundaries](#persistence-boundaries)


## Exercise metadata derivation

**Source:** `GymApp/Data/ExerciseDataset/ExerciseMetadataDeriver.swift`
**Tests:** `GymAppTests/ExerciseMetadataDeriverTests.swift`

### The problem

The upstream dataset gives each exercise a name, a body part, an equipment string, a target muscle,
a synergist and a list of secondary muscles. It does **not** say whether a movement is a compound or
an isolation, which pattern it belongs to, how fatiguing it is, how it should be loaded, or whether
it should be logged in reps or in seconds. Every programming decision depends on those judgements.

They are therefore derived once, deterministically, from rules written down here and unit-tested.
No network call and no language model is involved.

### Normalising the vocabularies

The dataset uses three overlapping muscle vocabularies — `target` (19 spellings), `muscle_group`
(29) and `secondary_muscles` (40) — which disagree with each other: `traps` and `trapezius`,
`lats` and `latissimus dorsi`, `delts`, `deltoids` and `shoulders` all appear. `Muscle.init(datasetValue:)`
in `Taxonomy.swift` owns every alias and maps them onto 29 canonical muscles. Unknown spellings
return `nil` rather than collapsing into a wrong bucket; the dataset audit surfaces them.

Canonical muscles roll up into 18 `MuscleGroup` values, which are the unit in which weekly volume,
frequency and recovery are tracked.

### Movement pattern

Keyword rules over the normalised name, evaluated **specific to general**, first match wins, with a
target-muscle fallback so every record gets a usable pattern. Matching is plural-tolerant (`hip
thrust` also matches `hip thrusts`), because the dataset spells the same movement both ways.

Order matters, and three words in particular are overloaded:

| Word | Disambiguated by |
|---|---|
| `raise` | A *lateral* raise is a shoulder movement, a *leg* raise is core work, a *calf* raise is a calf movement. Calf raises are matched first; leg, knee and hip raises are then resolved on the target muscle; only what remains reaches the shoulder-raise rule. |
| `bridge` | A *glute* bridge is hip extension; a *side* bridge is a plank. Resolved on the target muscle. |
| `extension` | A *triceps* extension is elbow extension; a *leg* extension is knee extension; a *hip* extension is a hinge. The leg and hip cases are matched before the generic elbow rule. |

### Mechanic, push/pull, laterality

- **Mechanic** follows from the pattern. Core patterns are the exception: loaded multi-joint core
  work (an ab wheel rollout, a hanging leg raise) with three or more secondary muscles counts as a
  compound.
- **Push/pull class** follows from the pattern, and drives antagonist balancing across a week.
- **Laterality** is keyword-based (`one arm`, `single leg`, `alternate`, plus every lunge pattern).
  Unilateral work carries a `timeMultiplier` of 1.7, because two sides take longer than one — which
  is what keeps the session-length budget honest.

### Tracking mode

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

### Continuous scores

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

### Rep ranges and rest

Derived from pattern, mechanic and equipment: barbell squat and hinge 5–8; other compounds 6–10;
chest flies, raises and shrugs 10–15; arms 8–14; calves 10–20; core 10–20; abduction/adduction
12–20. Rest is 210 s for loaded squat and hinge, 165 s for other compounds, 105 s for accessory
work, 60–75 s for isolation and core.

`estimatedSetSeconds` is `midpointReps × 3.5 s + (25 s compound | 12 s isolation)`, multiplied by
the laterality factor. This is what the programming engine uses to guarantee a session actually
fits the user's stated time.

### Volume contribution

The target group earns a **full set** (1.0). Synergists and listed secondary muscles earn a **half
set** for compounds and a third for isolations — the widely used direct/indirect convention. A group
never earns more than one full set from a single exercise.

Stretches, cardio and distance-tracked work contribute **nothing**. A skipping-rope round genuinely
works the calves, but counting it as calf volume would corrupt every recovery and progression
decision downstream.

### Substitution tags

A free-form tag set per exercise — position (`incline`, `seated`, `lying`, `prone`), grip
(`close_grip`, `wide_grip`, `reverse_grip`, `neutral_grip`), equipment class (`machine`, `cable`,
`free_weight`, `band`, `bodyweight`), and the safety tags that mobility limitations filter on
(`overhead`, `axial_load`, `hinge`, `deep_knee`, `wrist_loaded`, `grip_limited`,
`deep_stretch_shoulder`). These are what let the substitution engine find a genuinely like-for-like
swap rather than merely another exercise for the same muscle.

### Verified output over the full catalogue

Running the deriver across all 500 shipping records (the Gym avatar selection) produces:

| Dimension | Distribution |
|---|---|
| Mechanic | 244 compound / 256 isolation |
| Tracking | 298 weight×reps, 177 bodyweight+load, 15 reps-only, 6 duration, 2 assisted, 2 weight+time |
| Difficulty | 205 beginner / 250 intermediate / 45 advanced |
| Laterality | 423 bilateral / 76 unilateral / 1 alternating |
| Push/pull | 168 pull, 120 push, 135 legs, 70 core, 7 neutral |
| Empty volume contribution | 0 — the selection has no stretches and no cardio |
| Unresolved muscle strings | 0 |

The cardio, stretch and distance rules are still exercised by the unit tests, against the upstream
records' fields (`Upstream` in `ExerciseMetadataDeriverTests.swift`).

---

## Exercise scoring, selection and substitution

Owned by `GymApp/Domain/Training/ExerciseScoring.swift`,
`ExerciseRecommendationEngine.swift` and `ExerciseSubstitutionEngine.swift`.
All three are pure value-type engines: no clock, no randomness, no persistence,
no SwiftUI. Identical inputs always produce an identical, identically-ordered
result, which is what makes generated programs reproducible and every rule below
unit-testable.

### 1. Eligibility gates

`ExerciseScoring.blockingReason(...)` is the single gate, shared by selection and
substitution so both agree on what "allowed" means. It is checked before any
arithmetic, and a failure is final — a hard rule must never be out-voted by a
strong score elsewhere. Order is chosen so the most actionable reason wins,
because the returned `Explanation` is what the user reads when an exercise they
expected is missing.

| Order | Condition | Key |
|---|---|---|
| 1 | Id already taken by this session / this week | `selection.blocked.alreadyInSession` |
| 2 | Id in `profile.excludedExerciseIDs` | `selection.blocked.excluded` |
| 3 | Preference feedback `neverRecommend` | `selection.blocked.neverRecommend` |
| 4 | Preference `isExcluded` | `selection.blocked.excluded` |
| 5 | `exercise.equipment` not in the available set | `selection.blocked.equipment` |
| 6 | Pattern in `profile.avoidedPatterns` | `selection.blocked.avoidedPattern` |
| 7 | Any `MobilityLimitation` blocks the pattern **or** intersects `substitutionTags` | `selection.blocked.limitation` |
| 8 | `metadata.isStretch` and stretches are not allowed for this call | `selection.blocked.stretch` |
| 9 | `requiresLoadableMovement` and the tracking mode does not use both weight and reps | `selection.blocked.notLoadable` |

Rules 3 and 4 are separate because a user who set both gets the more specific
message: "you asked not to see this again" rather than "you removed this
exercise".

Rule 7 needs both halves: `behind neck` presses are vertical pushes like any
other, and only the tag distinguishes the one variation a restricted shoulder
should not do. Rule 8 always fires for an `ExerciseSelectionRequest` because that
type always describes a working slot; `warmupSuggestions` calls the same gate
with stretches allowed, which is the only place the flag is turned off.

No gate is medical. A `MobilityLimitation` is treated as a user preference about
movement, never as a diagnosis.

### 2. Scoring

Every factor is normalised to 0…1, then combined with `ExerciseScoringWeights`.
The additive weights sum to `additiveSum` = 1.0, so `total` is comparable
between users, muscle groups and releases. `priorityBonus` is added on top of
that sum (it may push a prioritised group's best options against the ceiling
rather than merely reshuffling them); `recentRepetitionPenalty` and
`exclusionPenalty` are subtracted; the result is clamped to 0…1.

| Factor | Weight | Definition |
|---|---|---|
| `targetMatch` | 0.24 | 1.0 when `primaryGroup == targetGroup`, else `metadata.volumeCredit(for:)` (0.5 compound / 0.33 isolation) |
| `secondaryUtility` | 0.06 | `0.65 · best + 0.35 · min(1, Σ/2)` over the other priority groups, each rank-decayed by `max(0.6, 1 − 0.1·index)`. With no stated priorities: `min(1, indirectCredit/1.5)` |
| `goalSuitability` | 0.12 | Per-goal formula below, blended over the first three goals with weights 1, ½, ¼ and renormalised; ×0.6 when `preferredMechanic` mismatches |
| `equipmentAvailability` | 0.10 | Constant 1.0 — availability is gate 5, and the weight keeps `total` on the documented scale |
| `userPreference` | 0.12 | `min(1, ExercisePreferenceSnapshot.scoreMultiplier / 2)`. Multiplier runs 0…1.62 around a neutral 1.0, so "no opinion" maps to exactly 0.5 |
| `historicalPerformance` | 0.05 | `0.5 + clamp(5·Δ, −0.35, +0.4)` where Δ is the relative change in the strength proxy across up to five sessions. 0.5 with fewer than two sessions, or whenever the two endpoints cannot be compared (see below) |
| `movementDiversity` | 0.07 | Table below |
| `progressionSuitability` | 0.08 | `metadata.progressionSuitability` verbatim |
| `fatigueEfficiency` | 0.05 | `r/(r+1)` where `r = stimulusScore / max(fatigueCost, 0.05)`; when `favorLowFatigue`, `0.55·that + 0.45·(1 − fatigueCost)` |
| `experienceSuitability` | 0.07 | `0.88 − 0.35·overshoot − noviceness·max(0, stability − 0.45)·0.55`, `+0.10` machine/supported for a novice, `−0.08` beginner machine work for an advanced lifter |
| `stapleBonus` | 0.04 | `metadata.stapleScore` verbatim |
| `priorityBonus` | +0.06 | Rank-decayed 1.0 when the target group is a stated priority and the exercise trains it directly, 0.5 indirectly |
| `recentRepetitionPenalty` | −0.10 | 1.0 if already selected, 0.7 if in `recentlyUsedIDs`, halved to 0.35 for a favourite |
| `exclusionPenalty` | −1.00 | 1.0 for a hard gate; otherwise `0.12/step` above the difficulty ceiling (×1.5 for an untrained user), capped at 0.36 |

#### Goal formulas

`compoundness` = 1.0 compound / 0.4 isolation. `affinity` compares the
exercise's own `recommendedRepRange` with `goal.primaryRepRange` as
`0.6 · overlapFraction + 0.4 · max(0, 1 − |Δmidpoint|/10)`; the blend exists
because overlap alone puts a cliff between 5–8 and 8–12, which does not reflect
how interchangeable those prescriptions are. Movements that do not use reps
return a neutral 0.55 rather than a near-zero score, so a plank is not punished
for having no rep window.

* **buildStrength** — `0.42·progression + 0.28·compoundness + 0.30·affinity`.
  Strength is bought with load that can be added in small repeatable steps, on
  multi-joint movements, in low rep ranges.
* **buildMuscle / recomposition / targetMuscleGroup** —
  `0.60·stimulus + 0.25·affinity + 0.15·compoundness`. Hypertrophy tracks
  stimulus per set far more closely than it tracks movement selection.
* **loseFat** — `0.45·stimulus + 0.30·compoundness + 0.25·affinity`. Fat loss is
  a nutrition outcome; training's job is to hold muscle in the time available.
* **improveEndurance** — `0.5·affinity + 0.5·(1 − fatigueCost)`.
* **maintain / generalFitness** —
  `0.45·stimulus + 0.30·compoundness + 0.25·affinity`.

#### Movement diversity

| | Pattern unused | Pattern already used this session |
|---|---|---|
| Matches `preferredPattern` | 1.00 | 0.60 |
| No preferred pattern | 0.75 | 0.20 |
| Mismatches `preferredPattern` | 0.50 | 0.10 |

`+0.12` (clamped) when the pattern's antagonist is already in the session, which
is how push/pull ratios stay sane across a mesocycle.

#### Strength proxy

Best Epley estimate in the session, `w · (1 + reps/30)`, with reps capped at 20 —
every one-rep-max formula becomes fiction well before that, and an uncapped
estimate would let a light high-rep day read as a personal record. Unloadable
movements fall back to total working reps, then to held seconds.

Each proxy carries the unit it is expressed in, and a trend is only computed when
both endpoints use the **same** unit; otherwise the factor stays at the neutral
0.5. A session logged without load sitting next to one logged with it would
otherwise divide kilograms by repetitions and read as a collapse or a
breakthrough that never happened.

#### Difficulty ceiling and the safety rail

The ceiling is `ExperienceLevel.maximumDifficulty`, shifted by
`TechniqueConfidence`: `coached` +1, `unfamiliar` −1, otherwise 0. A coached
beginner is therefore offered barbell work that a self-taught beginner is not.

`experienceSuitability` alone carries 7 % of the scale, which is not enough to
keep a novice away from a movement that scores well everywhere else, so
overshoot is *also* charged to `exclusionPenalty` and subtracted outside the
weights: two grades above the ceiling costs roughly a quarter of the whole
score. It is deliberately a demotion rather than a ban — a movement one grade
too hard is often exactly what the user should be working towards.

#### Low-fatigue re-weighting

When `favorLowFatigue` is set, 12 % of the non-fatigue additive weight mass (at
most 0.08) is moved into `fatigueEfficiency` and the remaining additive weights
are scaled by `(rest − boost)/rest`. `additiveSum` is preserved *exactly*, so
scores from a nearly-full session stay comparable with scores from a fresh one.
With default weights, `fatigueEfficiency` goes 0.05 → 0.13.

### 3. Recommendation

`rank()` scores the target group's index bucket, drops disqualified and
zero-scoring rows, and sorts by **score → stapleScore → id**. The final id
comparison makes the ordering total, and therefore stable: the list never
flickers between two identical requests.

Indexes are built once in `init` (group → exercises, pre-sorted by id; group →
warm-up candidates, pre-sorted by warm-up score). The primary group is inserted
explicitly as well as every group with volume credit, because cardio work
carries no credit at all and would otherwise be unreachable.

`best(count:)` is greedy with re-scoring. After each pick the id is marked
selected and the pattern marked used, so the next round's scores already reflect
the choice; on top of that a multiplier discounts repeats:
`1 − (0.22·patterns + 0.14·equipment + 0.10·targets)`, floored at 0.25. Each
round looks only at that round's top 24 — wide enough that a different pattern or
a different implement is always inside the window, narrow enough that the pass
never buys variety with a genuinely unsuitable choice. Two rules keep variety
honest:

* **Quality band.** Only candidates scoring ≥ 88 % of the round's leader are
  considered at all; everything below it is out of the running regardless of how
  much variety it would add.
* **Directness first.** *Within that band*, a candidate whose `primaryGroup` is
  the target group always beats one that only earns indirect credit, whatever the
  diversity multiplier says. Without this, a back day whose two available
  patterns are exhausted starts buying variety with a triceps movement, which is
  a worse session. An indirect pick can still win the round, but only when no
  direct option is inside the band — which on the shipping catalogue happens
  almost exclusively for `obliques` and `adductors`, where the dataset files most
  of the plausible work under a neighbouring target muscle.

`warmupSuggestions` uses a separate pool — `isWarmupCandidate`, or
`fatigueCost ≤ 0.25 && stabilityDemand ≤ 0.7`, never plyometric — scored as
`0.30 + 0.30·isWarmupCandidate + 0.25·(1 − fatigueCost) + 0.10·stapleScore
+ 0.05·beginner − 0.08·isStretch`. The stretch term is negative on purpose:
static stretching immediately before lifting transiently reduces force output, so
band and bodyweight drills rank first and held stretches stay available further
down. Suggestions are handed out round-robin across the requested groups so a
full-body session warms up everything it is about to use.

Warm-ups are not scored, but they are still gated. When a
`TrainingProfileSnapshot` is supplied, every candidate goes through the same
`blockingReason` as a working slot, with `allowsStretch: true` and
`requiresLoadableMovement: false` — so mobility limitations, avoided patterns and
exclusions are honoured, while a held stretch, which rule 8 would reject from a
working slot, is exactly what belongs here. Equipment is passed separately from
the profile because the kit within reach mid-session is often not the kit the
profile describes. Omitting the profile gates on equipment alone.

### 4. Substitution

#### Similarity

Weighted sum, renormalised by the weight total so an unnormalised
`SubstitutionWeights` still yields 0…1. Component order is the product's:

| Component | Weight | Definition |
|---|---|---|
| Same target | 0.30 | 1.0 same muscle, 0.75 same group, else `0.6 ·` the stronger cross volume credit |
| Same pattern | 0.22 | 1.0 identical, otherwise a hand-written affinity table (squat↔lunge 0.65, hinge↔hipThrust 0.60, horizontalPush↔chestFly 0.60, horizontal↔vertical 0.55, …) |
| Secondary overlap | 0.12 | Jaccard over synergist + secondary muscles; 0.5 when both sets are empty, which is absence of evidence rather than evidence of difference |
| Same push/pull | 0.06 | 1 or 0 |
| Same mechanic | 0.08 | 1 or 0.3 — a fly does replace a bench press when the rack is taken, just imperfectly |
| Tag overlap | 0.10 | Rarity-weighted Jaccard over `substitutionTags` |
| Difficulty proximity | 0.06 | `1 − |Δrank| / 2` |
| Equipment fit | 0.06 | 1.0 identical, 0.7 same family, 0.5 cable↔machine, 0.4 bodyweight↔band, else 0.25 |

Tag rarity is inverse document frequency computed over the catalogue in `init`:
`min(1, max(0.05, log((N+1)/(df+1)) / log(N+1)))`. `compound` sits on half the
catalogue and says almost nothing; `preacher` or `behind_neck` sits on a handful
and says almost everything. The 0.05 floor keeps a universal tag worth a little
rather than nothing. Weights are catalogue-dependent but deterministic for a
given catalogue.

Reference values on the shipping dataset, using the dataset's own record names:
`barbell bench press` ↔ `dumbbell bench press` 0.94, ↔ `cable decline press` 0.85,
↔ `barbell high bar squat` 0.23.

#### Candidate score

`0.72·similarity + 0.18·preference + 0.10·familiarity`, then multiplied by the
reason modifier. Familiarity is
`0.35·min(1, sessions/6) + 0.65·historicalPerformance` — mid-session a known
setup and a known working load have real value, but a familiar movement the user
has stalled on should not outrank a fresh one on habit alone.

#### Reason handling

Each reason contributes a hard filter and a 0…1 fit. The fit is mapped onto
`[0.55, 1.0]` rather than used as a multiplier above 1, so scores never saturate
at the ceiling and the ordering stays meaningful when a dozen candidates all
satisfy the reason perfectly.

| Reason | Filter | Fit favours |
|---|---|---|
| `machineUnavailable`, `machineOccupied` | exclude the original's exact equipment | free weight 1.0, bodyweight 0.9, band 0.6, cable 0.45, machine 0.1 |
| `preferDumbbell` | dumbbell only | dumbbell 1.0, kettlebell 0.55, weighted 0.4 |
| `preferBarbell` | barbell, olympic, EZ, trap bar | those 1.0/0.85/0.8, smith 0.6 |
| `preferCable` | cable only | cable 1.0, band 0.55, machine 0.45 |
| `bodyweightOnly` | bodyweight, assisted, weighted | 1.0 / 0.8 / 0.75 |
| `dislike` | exclude anything sharing the original's two rarest non-structural tags | different equipment +0.25, different pattern +0.25 |
| `easier` | difficulty ≤ original | lower difficulty, lower stability demand, supported/seated/machine tags |
| `harder` | difficulty ≥ original | higher difficulty, free weight or bodyweight, unilateral |
| `sameMuscleDifferentExercise` | pattern **or** equipment must differ | same target +0.35, different pattern +0.20, different equipment +0.15 |
| `jointDiscomfort` | pattern must differ | supported/machine +0.30, plus 0.40 · the stability reduction |

`dislike` excludes only *non-structural* tags — pattern, mechanic and implement
class are filtered out first — because disliking the preacher curl is not a
statement about elbow flexion.

#### Explanations

One to three per candidate, deduplicated, in a fixed order: the relationship to
the replaced movement (`Same target muscle and pull pattern`), then the answer
to the reason given (`Easier to stabilise`), then one concrete extra (favourite,
equipment, progress, staple). Every candidate carries at least the relationship.

Deduplication happens *as* the list is built, not after it. For the four
implement reasons the answer to the reason already **is** the equipment line, so
filtering afterwards would let that repeat consume the third slot and leave every
candidate with two lines; skipping the repeat hands the slot to the next distinct
extra instead. A candidate ends up with fewer than three only when there is
genuinely nothing else true to say about it.

All keys are argument-free, and none of their English values contains a format
specifier. `Explanation.arguments` is `[String]` and resolves through
`String(format:arguments:)`, so a `%lld` placeholder would misread a `String`
argument; this area therefore uses `%@` only, and would pre-format any number
into its argument rather than relying on integer placeholders.

The reason the user picks is labelled separately from the reasons a candidate
carries: `SubstitutionReason.localizationKey` produces `substitution.<rawValue>`,
and those eleven keys live in `Tools/l10n/keys/selection.en.json` alongside the
`substitution.reason.*` explanations, mirroring how `progressionAction.*` sits in
the progression area's key file rather than in `taxonomy.en.json`.

#### Performance

Measured on the earlier 1,324-record catalogue (the shipping one has 500 records, so these are
upper bounds), `-O` build, Apple silicon, with
a full preference and history dictionary loaded — which is the expensive case,
since every candidate then costs two dictionary lookups and a trend computation:

| Call | Cost |
|---|---|
| Index build (`init`) | 3 – 4 ms per engine, once per app launch |
| `alternatives` | 0.10 – 1.25 ms, against a mid-set budget of ~10 ms |
| `rank` | 0.5 – 1.1 ms depending on how large the group's bucket is |
| `best(count: 6)` | 3.4 – 6.8 ms (six full re-scoring rounds, as the greedy contract requires) |

The substitution path stays cheap because it touches only the primary-group
bucket (a few hundred records, topped up from the wider index only when fewer
than five survive), gates with `Set` lookups before scoring, and allocates
nothing for a rejected candidate. Ordering is settled by a single sort of the
survivors, never of the catalogue.

If a reason filters everything out — "bodyweight only" where the muscle has no
bodyweight option — the filter is dropped and the reason survives as a ranking
preference. An empty sheet mid-workout is the worst possible answer.

---

## Split selection, weekly volume and program generation

Files: `GymApp/Domain/Training/VolumeAllocator.swift`, `SplitSelector.swift`,
`WorkoutProgrammingEngine.swift`.
Localisation keys: `Tools/l10n/keys/programming.en.json`.

Three engines run in a fixed order and each one hands the next a value type:

```
TrainingProfileSnapshot + RecoverySnapshot
        |
        v
VolumeAllocator.targets(...)  ──> VolumeTargets   (credits + frequency per muscle group)
        |
        v
SplitSelector.selectSplit(...) ──> SelectedSplit  (one SessionBlueprint per training day)
        |
        v
WorkoutProgrammingEngine.generate(...) ──> GeneratedProgram
```

All three are pure: no clock, no persistence, no SwiftUI, and no randomness beyond
`ProgrammingRequest.randomSeed`. The same request always produces a byte-identical program,
including the session `UUID`s, which is what makes snapshot tests and "regenerate this week"
meaningful.

---

### 1. The unit: volume credits, not sets

Everything in this area is counted in **credits**, following the direct/indirect convention
`ExerciseMetadataDeriver.volumeContribution` implements. One working set of a barbell bench press
earns the chest 1.0 credit and the triceps and front delts 0.5 each; one set of a cable curl earns
the biceps 1.0 and the forearms about 0.33.

Counting credits rather than performed sets is what lets the allocator prescribe far fewer
*exercises* than the sum of its per-group targets implies, and it is the same unit
`weeklyVolume(of:catalog:)` reports back, so the plan and the measurement of the plan are directly
comparable. Three constants tie credits to the clock and back:

| Constant | Value | Where it comes from |
|---|---|---|
| `averageSetSecondsIncludingRest` | 170 s | ~50 s of work for a compound (7 reps × 3.5 s + 25 s set-up) with 165 s rest, ~50 s for an isolation with 90 s rest, at a 40/60 compound-to-isolation mix: 0.4 × 215 + 0.6 × 140 ≈ 170 |
| `averageVolumeCreditPerSet` | 1.8 | a compound with three secondary groups scores 1 + 3 × 0.5 = 2.5, a typical isolation 1 + 0.33 ≈ 1.33; the same 40/60 mix averages ≈ 1.8 |
| `sessionOverheadMinutes` | 8 | general warm-up, ramp-up sets, walking between stations |

`WorkoutProgrammingEngine` re-computes each session's real cost from the exercises actually chosen;
these constants only have to be good enough to set the **weekly ceiling**. Section 10 records how
far off they are in practice.

---

### 2. The weekly time budget

`VolumeAllocator.timeBudget(for:)` is the hard ceiling. It is applied last, after every
physiological modifier, because bending the envelope after fitting it would let the modifiers push
the program back over the calendar.

```
usableMinutes  = max(12, sessionMinutesCap − 8)
workingSeconds = daysPerWeek × usableMinutes × 60
secondsPerSet  = 170 × restFactor(goals)
setCapacity    = workingSeconds / secondsPerSet
creditCapacity = setCapacity × 1.8
```

The `max(12, …)` floor means a session shorter than twenty minutes is still budgeted as if it held
twelve minutes of working sets. That floor is deliberate and is mirrored in two other places —
`SplitSelector.capacityFit` and `WorkoutProgrammingEngine.capSeconds(for:)` both treat the cap as
`max(15, sessionMinutesCap)` — so all three agree on the shortest session the engine will plan.
`InputValidation.sessionMinutes` permits values down to 10; below 15 the engine plans a
fifteen-minute session and says so honestly in `estimatedMinutes`.

`restFactor` is the goal-blended multiplier on the rest interval, which is what makes a set
expensive in clock time:

| Goal | Rest multiplier | Volume multiplier |
|---|---|---|
| `buildStrength` | 1.30 | 0.80 |
| `buildMuscle` | 1.00 | 1.15 |
| `targetMuscleGroup` | 1.00 | 1.10 |
| `recomposition` | 0.95 | 1.05 |
| `maintain` | 0.95 | 0.70 |
| `generalFitness` | 0.92 | 0.90 |
| `loseFat` | 0.85 | 1.00 |
| `improveEndurance` | 0.78 | 0.95 |

Hypertrophy sits highest on volume because volume is its primary driver. Strength is deliberately
lower: the same weekly stimulus is bought at a much higher intensity and each heavy set costs far
more recovery. Fat loss *maintains* volume rather than cutting it — cutting sets in a deficit is the
standard way to lose lean mass. Maintenance runs at the bottom because minimum effective volume is
the entire point of a maintenance block.

**Blending.** `VolumeAllocator.blended(_:_:)` mixes the first three goals at weights
**0.60 / 0.25 / 0.15**, renormalised by however many were supplied, so "build muscle, then lose fat"
lands nearer hypertrophy than either goal alone would. An empty list falls back to
`.generalFitness`.

---

### 3. The volume envelope and its modifiers

#### Base envelope, per *major* muscle group, in weekly credits

| Experience | Minimum | Target | Maximum |
|---|---|---|---|
| `never` | 6 | 8 | 11 |
| `beginner` | 8 | 10 | 13 |
| `intermediate` | 12 | 15 | 18 |
| `advanced` | 14 | 18 | 22 |

These follow the mainstream evidence-based consensus in Schoenfeld's dose-response work and the
volume landmarks popularised by Israetel: roughly 8–12 weekly sets for a novice, 12–18 for an
intermediate, 14–22 for an advanced lifter, target in the middle of the band. Novices sit at the
bottom on purpose — they get a disproportionate return from low volume, and their limiting factor is
technique practice and recovery, not stimulus. The maximum is a *recovery* ceiling: past it, added
sets buy fatigue rather than adaptation, and the priority bonus below is clamped to it.

#### `groupScale` — how much of a major group's envelope each group gets

| Scale | Groups |
|---|---|
| 1.35 | `back` |
| 1.00 | `chest`, `shoulders`, `quads`, `hamstrings`, `glutes` |
| 0.80 | `biceps`, `triceps` |
| 0.60 | `calves`, `abs`, `traps` |
| 0.40 | `lowerBack` |
| 0.35 | `obliques`, `forearms` |
| 0.20 | `adductors`, `abductors` |
| 0 | `neck`, `cardio` (programmed separately) |

Small muscles take less absolute volume for two reasons: they fatigue the whole system less per set,
and every press, row and hinge already showers them with indirect work. The tail groups sit lowest
because in practice they are trained almost entirely as synergists.

`back` sits above 1.0 deliberately: the taxonomy collapses lats, upper back and rhomboids into one
bucket, so a single `back` target has to cover what the push side spreads across `chest` **and**
`shoulders`. Leaving it at parity is the standard way programs end up pressing half again as much as
they pull. 1.35 does not fully close that gap — see section 10.

#### `indirectShare` — the fraction of a group's credit that arrives as synergist work

| Share | Groups |
|---|---|
| 0.75 | `forearms`, `lowerBack` |
| 0.55 | `triceps`, `shoulders` |
| 0.50 | `biceps`, `traps`, `glutes` |
| 0.45 | `hamstrings` |
| 0.30 | everything else |

This turns a credit target into a number of *directly targeted* sets. Without it the engine would
prescribe six triceps exercises on top of five pressing movements. The values are read off
`volumeContribution`: every press hands the triceps and front delts half a credit, every pull does
the same for the biceps and forearms, every hinge and squat loads the lower back and glutes.

#### Modifiers, in the order they are applied

| Step | Effect |
|---|---|
| 1. Envelope | `envelope.target × groupScale(group)` |
| 2. Goal | `× blended(goals, volumeMultiplier)` → 0.70 … 1.15 |
| 3. Age | `× ageFactor(ageYears)` → 1 % off per year past 45, capped at −15 % |
| 4. Systemic readiness | `× (1 − 0.20 × (1 − readiness))` → down to 0.80 |
| 5. Per-group fatigue | `× (1 − 0.35 × clamp((fatigue − 0.35)/0.65))` → down to 0.65 |
| 6. Priority | `× 1.30` for a declared priority group |
| 7. Recovery ceiling | `min(value, envelope.maximum × groupScale)` |
| 8. **Time budget** | `fit(…)` — see below |
| 9. Deload | `× 0.60` on both target and minimum, if this is a deload week |
| 10. Reconcile | `minimum ≤ planned ≤ maximum`, so neither reads as a broken promise |

Fatigue below 0.35 is normal training residue and is ignored; cutting volume the moment a group is
at all fatigued would make the program oscillate week to week.

The age factor is a conservative programming default, **not** a medical judgement and not a claim
about any individual. A 55-year-old who feels fine simply raises their volume and the autoregulation
engine follows them.

Priorities are sanitised by `effectivePriorityGroups`: de-duplicated, restricted to
`MuscleGroup.volumeTracked`, **capped at three**. A list of eight priorities is not a list of
priorities, and spreading the 30 % bonus over everything merely raises the whole program into
territory the time budget immediately cuts back out.

#### `fit` — walking the targets down into the calendar

Water-filling rather than one proportional scale, because groups that hit their floor stop absorbing
and the rest have to take up the slack.

Each group has a floor: `minimum × 0.60` for a priority group, `minimum × 0.50` for a group whose
`groupScale ≥ 1.0`, and **zero** for everything else — a tail group with one weekly set is noise in
the plan rather than training.

Each group also has a willingness to shed:

| `shedFactor` | Applies to |
|---|---|
| 0.35 | any priority group |
| 0.60 | `chest`, `back`, `shoulders`, `quads`, `hamstrings`, `glutes` |
| 1.00 | `biceps`, `triceps`, `abs`, `calves` |
| 1.40 | everything else |

Six passes remove the excess in proportion to `headroom × shedFactor`, re-checking each time. A
uniform scale afterwards guarantees termination — not a normal path, but it is the path a very short
week takes, because there the floors alone already exceed the capacity.

#### Frequency

`VolumeAllocator.frequency(for:target:daysPerWeek:isPriority:)` resolves three constraints:

- **Volume.** Per-session volume has diminishing returns past roughly nine *directly targeted* sets
  for a major group and six for a small one, so `sessionsNeeded = ceil(directSets / ceiling)`. The
  ceiling is compared against direct sets, not credits: a chest carrying 20 weekly credits only
  performs about 14 chest sets, and comparing credits against a set ceiling would inflate every
  frequency by half. Once a group carries five or more weekly credits, two exposures beat one.
- **Recovery.** `min(3, floor(168 / baselineRecoveryHours))` — quads, hams, glutes and back (60 h)
  top out at twice a week; chest and delts (52 h) and arms (44 h) tolerate three.
- **Availability.** Nothing is trained more often than the user trains at all.

A priority group gets one extra exposure, but only when `daysPerWeek ≥ 5`: a third exposure is worth
the scheduling cost only when the week is long enough for it to land on a genuinely recovered muscle.
A target at or below 0.5 credits returns frequency 0 and the group is dropped from the plan entirely.

---

### 4. Choosing the split

`SplitSelector` never looks a split up by day count. Every well-known structure is *generated* as a
candidate at every day count and scored, so "1 day → full body" and "6 days → push/pull/legs" are
predictions of the scoring rather than table entries, and can be unit-tested as such.

#### Candidate generation

Eight **cycles**, each repeated across the week rather than written out as a weekly template:

| Key | Cycle |
|---|---|
| `split.fullBody` | full body |
| `split.upperLower` | upper, lower |
| `split.pushPullLegs` | push, pull, legs |
| `split.upperLowerFull` | upper, lower, full body |
| `split.torsoArmsLegs` | torso, shoulders+arms, legs |
| `split.fourWay` | upper, lower, push, pull |
| `split.pplUpperLower` | push, pull, legs, upper, lower |
| `split.posteriorEmphasis` | posterior chain, push, legs, pull |

Each cycle is expanded twice — plainly, and **biased**, where leftover days go to whichever
archetype in the cycle covers the most priority groups (a chest priority over five days turns
upper/lower into U-L-U-L-**U**). Then:

- at 2 days or more, each cycle also generates a **specialisation** variant: the base cycle over one
  fewer day plus a day given to the priority groups;
- at 6 days or more, each cycle also generates an **active-recovery** variant: six hard days is the
  practical ceiling, so a seventh has to be light.

That yields 9 candidates at one day, 16–19 in the middle of the range and 27 at six or seven.
Duplicates are collapsed by `key + archetype sequence`.

#### Archetype composition

| Archetype | Groups |
|---|---|
| `fullBody` | quads, back, chest, hamstrings, glutes, shoulders, triceps, biceps, calves, abs, lowerBack |
| `upper` | back, chest, shoulders, triceps, biceps, traps, forearms |
| `lower` / `legs` | quads, hamstrings, glutes, calves, adductors, abductors, abs, obliques, lowerBack |
| `push` | chest, shoulders, triceps |
| `pull` | back, biceps, traps, forearms |
| `torso` | back, chest, abs, obliques |
| `shouldersArms` | shoulders, triceps, biceps, traps, forearms |
| `posteriorChain` | back, hamstrings, glutes, traps, lowerBack |
| `specialisation` | the priority groups plus one complement each (antagonist or synergist), capped at six |
| `activeRecovery` | abs, obliques |

A group is only counted for a day if its weekly target exceeds 0.5 credits, so a plan never claims to
train something it has budgeted nothing for.

The specialisation day defaults to shoulders and arms when the user declared no priorities at all —
by far the most commonly specialised groups, and the ones whose 44–52 hour recovery window tolerates
a third weekly exposure. That default exists only so the candidate can still be scored; with no
declared priority it earns no priority credit and loses to the balanced structures.

#### Weekday assignment

`trainingWeekdays(profile:count:)` is shared with the programming engine, so a candidate is scored
against exactly the calendar it will later be scheduled on.

- If the user offered at least as many days as sessions, an evenly spaced subset is taken
  (`position = floor(index × declared.count / count)`), topped up from the remainder if the spacing
  produced a collision, and returned sorted Monday-first.
- If the user asked for more sessions than days, the remaining weekdays are added one at a time,
  always taking the day whose *minimum cyclic gap* from anything already chosen is largest. Sunday
  and Monday count as one day apart.

Seven sessions from an all-week availability gives Mon–Sun; six gives Mon–Sat; three gives
Mon/Wed/Fri; two gives Mon/Thu. A weekend-only user who asks for four sessions gets
Mon/Wed/Sat/Sun.

#### The seven scoring terms

Weights sum to 1.0, so a candidate's score reads directly as "how good a fit, 0…1".

| Term | Weight | What it measures |
|---|---|---|
| **frequency** | 0.30 | per-group |achieved − desired| exposures, volume-weighted; under-training is penalised at full rate, over-training at `× 0.35` |
| **capacity** | 0.20 | whether each day's share of the week's volume fits `sessionMinutesCap` |
| **experience** | 0.14 | how many *distinct* session types the user's training age warrants |
| **priority** | 0.12 | whether the declared priority groups actually get their exposures |
| **goal** | 0.10 | groups per session, against what the goal wants |
| **spacing** | 0.09 | same groups on consecutive calendar days, plus long unbroken streaks |
| **balance** | 0.05 | push versus pull *exposure* across the week |

**Frequency dominates** because getting a group trained the right number of times is the one
decision a split exists to make. Under-shooting is penalised at full rate and over-shooting at
`× 0.35`: volume left on the table cannot be made up, whereas a redundant exposure is a mild
inefficiency. Each group's penalty is weighted by its own target, so missing the chest matters more
than missing the adductors.

**Capacity** catches *uneven* structures rather than over-large weeks — the weekly total already fits
because `VolumeAllocator` guaranteed it. A single legs day carrying every lower-body set overflows
even though the week as a whole does not. Sessions finishing below 55 % of the cap are penalised too,
but at 0.4 of the weight, because wasting time is a smaller failure than not finishing.
Active-recovery days are exempt from the underflow penalty: a light day is the point of a light day.

**Experience** bands the number of *distinct* sessions: `never` and `beginner` want exactly 1,
`intermediate` 2–5, `advanced` 2–6. The band is one-sided — being simpler costs 0.6 of what being
more complicated costs. Novices do best with one session they repeat, because the practice *is* the
point and a four-way split asks them to learn four sessions before they can perform any well.

**Goal** measures groups per session — the one axis the other terms do not capture. Strength and
hypertrophy want a narrow session (5 groups) leaving room for two heavy compounds and long rest; fat
loss and general fitness want the opposite (8), endurance more still (9), because broad dense
sessions burn more energy per minute and are easier to recover from in a deficit. The ideal is raised
to whatever the calendar makes unavoidable before it is compared: a three-day week cannot run
five-group sessions however much the goal would prefer them.

**Spacing** sums the pairwise credit overlap of every pair of days one apart on the calendar, then
adds 0.20 per hard day beyond a run of four consecutive ones.

**Balance** compares volume-weighted mean *exposures* of `[chest, shoulders, triceps]` against
`[back, biceps, traps, forearms]`. Exposures rather than credits, because the credits are the
allocator's decision and identical for every candidate — comparing them would score every candidate
the same. Inside 20 % scores full marks; a 50 % imbalance scores nothing.

Ties break on score, then split key, then the joined blueprint title keys, so two identically scoring
candidates always resolve the same way.

---

### 5. From a split to blueprints

#### Day credits

Each day's credit for a group is `target / exposures`, damped to **75 %** if the same group was
already trained on a calendar day exactly one apart. Back-to-back exposure is not forbidden — some
structures need it — but the second day runs on a muscle that has had roughly a day, not the two to
three its `baselineRecoveryHours` asks for.

#### Concentration

A group whose *per-day* direct requirement rounds below two sets but whose *weekly* requirement does
not is pulled onto a single day. Spreading two weekly sets of shrugs across three exposures produces
nothing at all: each day rounds to zero and the group silently vanishes from the program.

The receiving day is the lightest of the days that already cover the group, so the extra movement
lands where there is time for it — and "lightest" is **re-measured after each decision**. Scoring
every group against the original day loads makes them all pick whichever day started lightest; on a
three-day full-body week, where all three days start identical, that is day one every time, and the
user gets one overloaded session and two nearly empty ones.

#### Slot vocabulary

Each group has an ordered list of `(pattern, mechanic)` pairs. A `nil` mechanic means "either", used
where the natural next movement for a group is not reliably a compound or an isolation. Being
explicit matters: asking the recommender for an *isolation* with a `horizontalPull` pattern would
disqualify the entire catalogue, because the metadata deriver classifies every row as a compound.

| Group | Slots, in order |
|---|---|
| chest | horizontalPush/compound, chestFly/isolation, horizontalPush/either |
| back | verticalPull/compound, horizontalPull/compound, horizontalPull/either |
| shoulders | verticalPush/compound, shoulderRaise/isolation, shoulderRaise/either |
| traps | shrug/isolation |
| biceps | elbowFlexion/isolation, elbowFlexion/either |
| triceps | elbowExtension/isolation, elbowExtension/either |
| forearms | wristFlexion/isolation, wristExtension/isolation |
| quads | squat/compound, kneeExtension/isolation, lunge/either |
| hamstrings | hinge/compound, kneeFlexion/isolation |
| glutes | hipThrust/either, hinge/compound, lunge/either |
| adductors | hipAdduction/isolation |
| abductors | hipAbduction/isolation |
| calves | calfRaise/isolation, calfRaise/either |
| abs | coreAntiExtension/either, coreFlexion/either |
| obliques | coreRotation/either, coreLateralFlexion/either |
| lowerBack | hinge/either |
| cardio | cardio/either |

#### `makeSlots` — credits to concrete slots

```
direct    = min(perSessionCeiling, credits × (1 − indirectShare(group)))   // 9 major, 6 small
sets      = round(direct)
if sets < 2 { return isPriority ? 2 sets : no slot at all }
maxSlots  = min(vocabulary.count, isSmallMuscle ? 2 : 3)
slotCount = clamp(ceil(sets / 3), 1, maxSlots)
```

Sets are then front-loaded across the slots — `ceil(remaining / slotsLeft)`, clamped to 2…5 — because
the first movement of a group is the one worth the most sets, and allocation stops once fewer than
two sets remain.

**Roughly three working sets per exercise.** Fewer wastes the set-up; more runs into within-exercise
fatigue and stops adding stimulus. Three rather than four also matters for balance: at four, a back
carrying seven sets gets two movements while chest plus shoulders get three between them, and the
week quietly ends up pressing more than it pulls. Groups whose direct requirement rounds below two
get no slot at all unless prioritised — one weekly set of wrist curls is clutter, not training, and
the forearms are already saturated by every row in the plan.

**The floor under a day.** When the time budget is very small, *every* group rounds below two at
once and the day comes back with nothing in it. `minimumSlots(for:)` then gives the day's biggest
groups one two-set compound each, stopping once the sets would cost more credit than the day was
allocated. Without it, a user who asked for twenty minutes once a week received a program whose only
content was a conditioning block.

#### Ordering inside a session

| Bucket | Contents |
|---|---|
| 0 | primary compounds — first, while the user is freshest and their technique is best |
| 1 | remaining multi-joint work |
| 2 | isolation, including any "either" slot on a single-joint pattern (`chestFly`, `shoulderRaise`, `shrug`, `elbowFlexion`, `elbowExtension`, `wristFlexion/Extension`, `kneeExtension`, `kneeFlexion`, `calfRaise`, `hipAbduction/Adduction`, `neckMovement`) |
| 3 | core (`abs`, `obliques`, `lowerBack`) |
| 4 | conditioning |

Core sits after isolation deliberately: a pre-fatigued trunk makes every subsequent loaded lift
worse. Inside a bucket, priority groups come first, then larger muscles (`sizeRank`), then more sets,
then pattern name — a total order, so the sequence is reproducible.

An "either" mechanic means the slot will accept a compound or an isolation; it does **not** mean the
movement is multi-joint. Treating it as such used to put the second calf-raise slot in among the
squats while the first sat three exercises later with the leg curls.

#### Titles

`session.title.<archetype>` plus a lettered variant when the archetype repeats: `Upper Body A`,
`Upper Body B`, and so on. The variant count per archetype has to be at least one below the most
times that archetype can occur in a single structure, because occurrences past the last variant all
fall back to the unlettered base key — and two blueprints sharing a title key are two sessions the
user cannot tell apart, and that `regenerateSession` cannot tell apart either. `expandBiased` can
append up to `cycle.count − 1` extra days, so a four-entry cycle can run its favoured archetype four
times: `posteriorChain` therefore carries four variants, not two.

#### Conditioning placement

The number of weekly conditioning blocks comes from the goal alone, blended and clamped to
`daysPerWeek`: 3 for fat loss and endurance, 2 for general fitness and recomposition, 1 for
maintenance and muscle, 0 for strength. `CardioPreference.none` always means none — cardio the user
did not ask for is cardio they will skip.

Blocks land on any active-recovery day first, then on the shortest lifting days.
`.separateSessions` cannot be honoured literally inside a weekly lifting plan, so it degrades to the
lightest days available — the closest thing to a standalone session the schedule allows — and the
explanation says which of the two happened.

---

### 6. Filling the blueprint

#### The slot ladder

`WorkoutProgrammingEngine.choose(...)` relaxes one requirement at a time, in the order in which each
matters least:

1. group + preferred pattern + mechanic, avoiding anything already used **this week**;
2. group + mechanic, any pattern, avoiding week repeats;
3. group only, avoiding week repeats;
4. group only, allowing a movement already programmed elsewhere this week;
5. a neighbouring muscle group (chest ↔ shoulders/triceps, back ↔ traps/biceps, quads ↔
   glutes/hamstrings, …), which sets `usedGroupFallback`;
6. a straight catalogue scan for anything admissible that touches the group at all;
7. the same scan restricted to bodyweight, which sets `usedBodyweightFallback`.

Steps 1–4 ask `ExerciseRecommendationEngine.rank(…, limit: 8)`, and `pick` takes the best — except
that anything within **3 %** of the top score, among the top four, counts as the same exercise and is
chosen by the seeded generator. Always taking the numerically highest makes every user's program
identical and every week's identical to the last.

Steps 6 and 7 bypass the recommender entirely and take the most canonical option by
`stapleScore + volumeCredit`, which is what lets a bodyweight-only user with a shoulder limitation
still get a session rather than an empty screen. They apply the same hard gates the recommender
would: user exclusions, `neverRecommend` feedback, avoided patterns, and every
`MobilityLimitation`'s blocked patterns and blocked tags.

**Isolation filling a compound slot.** `ExerciseSlot.isPrimary` describes the heavy compound the
session is built around. When the ladder has had to relax all the way to an isolation — a leg curl
standing in for a hinge because the user's kit has nothing better — the flag is cleared before the
prescription is made. Otherwise the movement would collect the extra rest, the extra rep of margin,
a ramp-up allowance and the trimmer's protection, and the app would tell the user a leg curl is "the
main lift for this muscle".

#### Prescription

| Field | Rule |
|---|---|
| `sets` | the slot's sets, clamped to 1…5 |
| `repRange` | the exercise's own recommended range, shifted by goal, clamped to 3…35 with `upper > lower` |
| `restSeconds` | `metadata.defaultRestSeconds × restFactor(goals)`, `× 1.10` on a primary, clamped to 30…300 |
| `targetRIR` | see below, clamped to 1…5 |
| `targetDurationSeconds` | for duration-tracked work: 20…120 s, or a conditioning block of 8–15 min by goal |

Rep shift, in reps, applied to the metadata range:

| Goal | Primary | Accessory |
|---|---|---|
| `buildStrength` | −3 | −1 |
| `maintain` | −1 | −1 |
| `generalFitness` | −1 | 0 |
| `buildMuscle` / `recomposition` / `targetMuscleGroup` | 0 | 0 |
| `loseFat` | +1 | +1 |
| `improveEndurance` | +6 | +5 |

The metadata range already knows a barbell squat belongs at 5–8 and a lateral raise at 10–15; the
goal only bends it. Strength pulls the primary compound down towards heavy triples and fives while
leaving accessories alone, because accessories exist to add tissue, not to be maxed. The clamp at
three reps is a safety floor: **the engine never programmes singles or doubles automatically**, since
near-maximal work needs a coach's eye on technique and a spotter, not an algorithm.

RIR starts from `ExperienceLevel.defaultRIR` (4 for `never`, 3 for `beginner`, 2 otherwise) and then:

- **+1** on a primary whose `fatigueCost ≥ 0.70` — a failed squat or overhead press is dangerous in
  a way a failed cable curl is not;
- **−1** on an isolation whose `fatigueCost < 0.25` — that is where taking a set close to failure is
  both safe and productive;
- **+1** when the group's fatigue exceeds 0.60;
- **+1** on a deload week;
- **+1** on the primary when the first goal is strength.

Never below 1: the engine does not prescribe training to failure.

---

### 7. Making it fit the clock

#### The session cost model

```
warm-up      = min(300, max(120, capSeconds / 5))   seconds
ramp-ups     = min(primaryCount, 3) × 90            seconds
per exercise = 40 s set-up + sets × setSeconds + (sets − 1) × restSeconds
transitions  = (exerciseCount − 1) × 60             seconds
```

Ramp-ups are paid only for the first three heavy movements: by the fourth compound the body and the
relevant joints are already warm and one light set is enough. The warm-up is capped at a fifth of the
session because five fixed minutes is right for an hour and absurd for twenty, where the trimmer
would then be deleting real work to pay for it. Any cap of 25 minutes or more gets the full 300 s.

#### Trimming

The order removes work in the order it costs the least. A *conservative* pass first:

1. shave 15 s off the longest non-primary rest, down to a floor of 60 s (density rises, stimulus
   barely moves);
2. remove one set from the non-primary exercise carrying the most, down to a floor of 2;
3. remove one set from the primary carrying the most, down to a floor of 3;
4. drop one exercise, keeping at least three.

Then an *aggressive* pass, because a 30-minute session cannot hold a textbook prescription and the
user's stated time wins:

5. shave rest including primaries, down to a floor of 90 s;
6. remove primary sets down to 2;
7. drop exercises, keeping at least two, primaries last.

Rest on the main lifts is never cut below 90 s and no exercise below two sets, so what survives is
still training. The loop is bounded at 160 iterations.

**Which exercise is dropped.** Cheapest first: the conditioning block before any lifting (a
ten-minute block is worth two accessory movements in clock time), then a movement whose muscle group
is still trained by something else left in the session, and only then a group's only movement. Ties
break towards the exercise furthest into the session. Position alone used to decide, which deleted
the only curl in an upper day before it touched the third row — the arms sort last, so they were
always first out, and a four-day upper/lower week could finish with three back movements and no
direct biceps work at all.

#### Extending

When a session finishes more than five minutes early, sets are added to whichever exercise offers the
most `stimulusScore` per unit of time, with a small penalty per set already assigned. The total is
capped at `plannedSets × 1.30`: two hours of availability is not an instruction to train for two
hours, and a generous cap must not quietly inflate the week past its recovery ceiling.

**Active-recovery days are never extended.** Topping a light day up to fill a two-hour cap turns the
one day that exists to dissipate fatigue into another hard one.

---

### 8. Determinism, locking and regeneration

`GeneratedSession` defaults its `id` to a fresh `UUID()`, which would make two runs of the same
request unequal and every snapshot test useless. Every id — training days and rest days alike — is
therefore drawn from a `SeededGenerator` (SplitMix64: four lines, no bad seeds including zero,
passes BigCrush) seeded from

```
randomSeed + weekIndex × 0x9E3779B9 + stableHash(titleKey) + sessionIndex × 0x10000001
```

`stableHash` is FNV-1a over UTF-8 because Swift's `hashValue` is seeded per process and cannot be
used anywhere a result must be identical between two runs of the app.

Every other decision is a pure function of the request. Sorting comparators are total orders down to
an id or a raw string, so no tie is ever resolved by the sort algorithm's internals.

**Locked exercises.** `lockedExerciseIDs` are placed before generation begins. Each pinned exercise
takes the best-matching free slot across the whole week — 4 points for the exact target group, 2 for
any volume credit, 2 for the pattern, 1 for the mechanic — and needs at least 2 points to claim one.
Anything that matches no slot is appended to the first session whose focus includes its primary
group, because a pin is the user's decision and dropping it silently is not an option.

**`regenerateSession`** rebuilds one session against the same blueprint. The structure of the week is
not up for renegotiation, only which exercises fill it. Everything currently in the session that is
not locked is added to the recently-used set, so a re-roll produces genuinely different work rather
than the same picks in a different order. It carries a different seed constant (`0x5EEDC0DE`) so it
cannot reproduce the session it was asked to replace.

---

### 9. A worked example

**Profile.** Intermediate, technique "confident", goals `[buildMuscle, loseFat]`, priorities
`[chest, back]`, Mon/Tue/Thu/Fri, 60-minute cap, full gym, no limitations, fresh recovery.

**Time budget.** `restFactor = (1.00 × 0.60 + 0.85 × 0.25) / 0.85 = 0.956`; `secondsPerSet =
170 × 0.956 = 162.5`; `usableMinutes = 52`; `workingSeconds = 4 × 52 × 60 = 12 480`;
`setCapacity = 76.8`; `creditCapacity = 138.2`.

**Envelope.** Intermediate → target 15. Goal multiplier `(1.15 × 0.60 + 1.00 × 0.25) / 0.85 = 1.106`.
No age, fatigue or readiness modifier. Chest: `15 × 1.00 × 1.106 × 1.30 (priority) = 21.6`, clamped
to its ceiling `18 × 1.00 = 18.0`. Back: `15 × 1.35 × 1.106 × 1.30 = 29.1`, clamped to `18 × 1.35 =
24.3`. Shoulders: `15 × 1.00 × 1.106 = 16.6`. Raw total ≈ 155 credits against a 138.2 capacity, so
`fit` removes about 17.

**After fitting** (credits, and the frequency each earns):

| Group | Target | Freq | | Group | Target | Freq |
|---|---|---|---|---|---|---|
| back | 22.3 | 2 | | triceps | 8.0 | 2 |
| chest | 16.5 | 2 | | calves | 6.0 | 2 |
| shoulders | 14.1 | 2 | | abs | 6.0 | 2 |
| quads | 14.1 | 2 | | traps | 4.4 | 1 |
| hamstrings | 14.1 | 2 | | lowerBack | 2.9 | 1 |
| glutes | 14.1 | 2 | | forearms, obliques | 2.6 | 1 |
| biceps | 8.0 | 2 | | adductors, abductors | 1.5 | 1 |

Total 138.2 — the calendar bound exactly, so the plan carries the `programming.volume.timeCapped`
explanation.

**Split.** 16 candidates at four days. `split.upperLower` wins, ahead of two specialisation variants
and `split.upperLowerFull`. It scores well on frequency (every group with a frequency of 2 gets
exactly 2), and the experience band (2 distinct sessions, inside 2–5) rules out the four-way
structures a novice profile would also have rejected. Weekdays: Mon, Tue, Thu, Fri.

**Upper A blueprint.** Chest credit for the day is `16.5 / 2 = 8.25`; direct sets are
`8.25 × 0.70 = 5.8 → 6`, over `ceil(6/3) = 2` slots at 3 sets each. Back is `22.3 / 2 = 11.15` →
`7.8 → 8` direct sets over 3 slots at 3/3/2. Shoulders is `14.1 / 2 = 7.05` → `× 0.45 = 3.2 → 3` in
one slot. Traps concentrate onto this day (`2.2 × 0.5 = 1.1` per day rounds to 1, but `4.4 × 0.5 =
2.2` for the week rounds to 2). Biceps and triceps get one 2-set slot each. Nine slots, 23 sets:

```
0  back        verticalPull    compound   3  primary
1  chest       horizontalPush  compound   3  primary
2  shoulders   verticalPush    compound   3  primary
3  back        horizontalPull  compound   3
4  back        horizontalPull  either     2
5  chest       chestFly        isolation  3
6  traps       shrug           isolation  2
7  triceps     elbowExtension  isolation  2
8  biceps      elbowFlexion    isolation  2
```

**Delivered Monday** — 56 minutes, 17 sets. Non-primary rest is shaved to 60 s, then two exercises
are dropped: back has three movements and chest two, so the trimmer takes the last back row and the
chest fly rather than the curl.

```
barbell pullover to press        3 × 6–10   rest 173 s  RIR 2
barbell guillotine bench press   3 × 6–10   rest 173 s  RIR 2
barbell seated overhead press    3 × 6–10   rest 173 s  RIR 2
barbell incline row              2 × 6–10   rest  60 s  RIR 2
dumbbell decline shrug           2 × 10–15  rest  60 s  RIR 1
cable rear drive                 2 × 8–14   rest  60 s  RIR 1
barbell curl                     2 × 8–14   rest  60 s  RIR 1
```

Rep ranges come from the metadata with a zero shift (the blend of `buildMuscle` and `loseFat` rounds
to no change on compounds). Rest is `defaultRestSeconds × 0.956`, with `× 1.10` on the three
primaries. RIR is the intermediate default of 2, dropping to 1 on the low-fatigue isolations.

**The week.** Mon Upper A (56 min), Tue Lower A (59 min), Wed rest, Thu Upper B (56 min), Fri Lower B
(57 min), Sat/Sun rest. Conditioning is programmed on the two lightest days and then trimmed off
both, because a 60-minute leg day has no room for it — which is the correct outcome and is why no
`programming.cardio.*` explanation survives into the final program.

**Delivered against target**, in credits:

| Group | Planned | Target | | Group | Planned | Target |
|---|---|---|---|---|---|---|
| hamstrings | 18.0 | 14.1 | | back | 16.3 | 22.3 |
| glutes | 15.3 | 14.1 | | chest | 9.0 | 16.5 |
| triceps | 13.7 | 8.0 | | traps | 2.0 | 4.4 |
| shoulders | 13.1 | 14.1 | | obliques | 1.3 | 2.6 |
| quads | 12.7 | 14.1 | | adductors/abductors | 0.0 | 1.5 |
| calves, abs, biceps | 8.0 / 7.0 / 7.0 | 6.0 / 6.0 / 8.0 | | | | |

---

### 10. Known limits

Written down because the numbers above are the specification and it should be obvious where the
specification is approximate.

**The credit-to-set conversion is about 6 % optimistic.** `averageVolumeCreditPerSet = 1.8` implies a
volume-weighted mean `indirectShare` of `1 − 1/1.8 = 0.444`. Measured against the target vector in
section 9 the actual mean is **0.411**, which implies 1.70 credits per set. The consequence is that
the blueprint asks for roughly 6 % more direct sets than the time budget sized, and `fitToTime` gives
them back. Neither constant is obviously the wrong one, so both are left as they are and the
discrepancy is recorded here.

**Uneven days amplify that.** `capacityFit` scores unevenness at weight 0.20 but does not forbid it.
In section 9, Upper A carries 28 % of the week's credit against a flat 25 % share of the clock, so it
is trimmed by six sets while Lower B finishes three minutes early. Everything the trimmer removes is
work the allocator had already decided the user could recover from.

**Legs over-deliver on long weeks.** `indirectShare` is a single per-group constant, but on a
push/pull/legs week every squat, hinge, lunge and hip thrust cross-credits hamstrings and glutes at
0.5. An advanced seven-day profile measures roughly twice its hamstring and glute targets and about
+90 % on calves and triceps, while chest and back land within 15 % of theirs. Reducing the constants
would fix the leg days and starve the short ones; it needs a per-session estimate of cross-credit
rather than a per-group constant.

**Push runs about 10 % ahead of pull in delivered volume**, regardless of what the targets ask for —
measured at a delivered pull/push ratio of 0.83–0.94 across every profile in the harness, including
profiles whose *targets* ask for 1.11. Two causes: a full-body or upper day structurally has two
pushing slots (chest and shoulders) against one pulling slot, which `groupScale(.back) = 1.35` only
partly offsets; and the `verticalPull/compound` slot is frequently filled by a pullover variant,
which credits no biceps or forearms, whereas every press credits triceps and delts. The second is a
selection and metadata issue rather than a programming one. `SplitSelector.balanceFit` measures
*exposures*, not volume, so it does not catch this — and the `programming.balance` explanation
correctly stays silent when the delivered split exceeds 20 %.

**A very short session is planned as a fifteen-minute one.** `sessionMinutesCap` accepts 10, but
`timeBudget`, `capacityFit` and `capSeconds(for:)` all floor at 15. The reported `estimatedMinutes`
is the honest figure, so a 10-minute user sees a 13–15 minute session rather than a 10-minute one.

**Performance**, measured on the earlier 1,324-record catalogue (the shipping one has 500 records, so these are upper bounds), `-O` build, Apple silicon:

| Call | Cost |
|---|---|
| `WorkoutProgrammingEngine.init` | ~6 ms, once per app launch |
| `VolumeAllocator.targets` | 0.03 ms |
| `SplitSelector.selectSplit` (16–27 candidates) | 1.2 ms |
| `generate` — 4 days, 60 min | 28–33 ms |
| `generate` — 7 days, 120 min | 44–48 ms |

Generation is not on any interactive path — it runs when a program is created or rebuilt — so tens of
milliseconds is comfortable. Nearly all of it is the slot ladder re-scoring the catalogue: a session
with nine slots that relax twice each costs about twenty `rank` calls.

---

## Progression, 1RM estimation and personal records

Files: `GymApp/Domain/Training/OneRepMaxCalculator.swift`, `ProgressionEngine.swift`,
`PersonalRecordDetector.swift`, `LoadEstimator.swift`.
Localisation keys: `Tools/l10n/keys/progression.en.json`.

All four are pure value-in/value-out enums. No clock, no randomness, no persistence, no SwiftUI and
no SwiftData: the same inputs always produce the same outputs, which is what makes the whole set
testable without a database.

---

### 1. One-repetition maximum

The app never asks for a maximal single. Every strength figure it shows is estimated from work the
user already did.

| Formula | Equation | Behaviour |
|---|---|---|
| Epley (1985) | `1RM = w × (1 + reps / 30)` | linear, drifts **high** as reps climb |
| Brzycki (1993) | `1RM = w × 36 / (37 − reps)` | hyperbolic, drifts **low** as reps climb |
| Lombardi (1989) | `1RM = w × reps^0.10` | power law, flattest of the three |
| `.average` (default) | mean of Epley and Brzycki | the two err in opposite directions, so their mean is more stable than either |

**Bounds.**

- `reps < 1`, non-finite or non-positive load → `nil`.
- `reps == 1` → the load itself. Running a single through a formula would inflate it.
- `reps > maximumReliableReps` (**12**) → `nil`. Every prediction equation is fitted on sets of
  roughly 1–10 reps; past 10–12 the residual error grows steeply and becomes dominated by rep
  endurance rather than maximal strength. Refusing to answer beats answering badly, because the rest
  of the app treats whatever comes back as fact.
- Brzycki's denominator is guarded against `reps ≥ 37`, where it divides by zero and then flips sign
  into a *negative* one-rep max.

**Inverse (`weight(forReps:oneRepMaxKg:)`).** Prescribing downwards is a much easier problem than
estimating upwards — an error at 20 reps costs a slightly light set, not a failed rep under a bar —
so the inverse runs to `maximumPrescribableReps` (**30**), covering the 15–25 endurance ranges the
programming engine produces. Up to 12 reps it inverts the selected formula (`.average` takes the mean
of the two inverses; that is not the exact inverse of the mean of the forward equations, but the two
differ by well under 0.5 % over 1–12 reps, far below the resolution of any plate). Past 12 it always
uses the Epley inverse: 60 % of 1RM at 20 reps and 50 % at 30, within about three points of the
conventional NSCA percentage table, whereas the Brzycki inverse collapses towards zero.

**`bestEstimate(from:)`** ignores warm-up, drop and calibration sets (`SetKind.countsAsWorkingSet`)
and any set the user did not complete, then takes the maximum, keeping the earliest set on a tie so
the result is stable.

---

### 2. Progression engine

#### Order of decisions

1. **Not loadable** → reps, seconds or sets. "Not loadable" means
   `!loadability.carriesExternalLoad || LoadRounding.increment == 0`; the second clause catches
   `.fixedImplement` (a medicine ball weighs what it weighs). `recommendedWeightKg` stays `nil` —
   never a fabricated kilogram figure.
2. **Calibration** — history empty, `state.needsCalibration`, or no usable working weight → action
   `.calibrate`, `requiresCalibration = true`, weight `nil`. `LoadEstimator` owns the first number;
   returning a half-guess here would let it be mistaken for a decision the engine stands behind.
   Unloaded movements skip this: there is nothing to calibrate, so the first session simply runs the
   recommended prescription.
3. **Deload week** → below.
4. **Strategy**.

`input.strategy` is the authority, not `state.strategy`: the caller may be running a program-level
override, and `updatedState.strategy` records what was actually applied.

#### Judging a session

Only the **most recent session with completed working sets** is judged, and within it only sets
performed **at or above the planned load**. Back-off sets count as working sets for volume but are
deliberately lighter; holding a session hostage to them would stall every program that uses them. If
no set reached the planned load the session is silent about it → `.maintain`, counters untouched.

- `allHitTop` — every judged set reached `range.upper`.
- `allMetBottom` — every judged set reached `range.lower`.
- `meetsRIRTarget` — no *recorded* RIR fell below the target. A set with no recorded RIR is missing
  evidence, not evidence of failure, so it does not block a progression. (`PerformedSet.effectiveRIR`
  derives RIR from RPE where needed: `RIR = 10 − RPE`.)
- Assisted movements invert every load comparison, because a *smaller* assistance is a *harder* set.

#### Double progression (default)

| Last session | Action |
|---|---|
| every set at the top of the range, RIR target met, on the **2nd** consecutive such session | `increaseLoad` |
| same but only the 1st such session | `addReps` (banked; `consecutiveSuccesses += 1`) |
| reps inside the range | `addReps` |
| every set at the top of the range but the RIR target missed | `addReps`, load held (`progression.explain.holdForMargin`) — the reps are already there, so telling this user to "work towards `range.upper`" would be nonsense; the load waits until the same reps come back with the intended margin |
| reps inside the range with no improvement, 4th time | `reduceLoad` −10 % |
| short of the bottom, 1st time | `maintain` (`consecutiveRegressions += 1`) |
| short of the bottom, 2nd time | `reduceLoad` −10 % |

Two consecutive qualifying sessions, not one: a single good session is a good day, and the cost of
being wrong is a failed rep. On an increase the rep target resets to the bottom of the range — the
new load is meant to be hard at the bottom, and climbing back to the top is what earns the next one.

**Counters.** `increaseLoad`/`reduceLoad` → all three reset to 0. Banked success → `successes += 1`,
others 0. Inside range with improvement → all 0; without improvement → `stalls += 1`. Missed bottom →
`regressions += 1`. `maintain` for "no data" or "lighter than planned" leaves them untouched.

#### Step size and the caps

- Preferred step = `LoadRounding.increment(for:profile:)`, raised to **2.5 kg** for compound barbell
  and EZ-bar lifts. That is a pair of 1.25 kg plates — the smallest jump most gyms can actually make
  and the customary one. Where a gym stocks micro-plates the raw increment is smaller, but half a
  kilogram on a squat is noise, not progress. Isolation work always takes the smallest increment,
  because relative to a 10 kg curl a 2.5 kg jump is 25 %.
- **Cap: 10 % of the current load, 5 % above 100 kg.** Plate sizes are absolute, so an unchecked
  "one more pair" rule gets relatively *smaller* as loads grow, which is fine. The caps exist for the
  light end: a 2 kg step on a 10 kg dumbbell is 20 %. Above 100 kg the absolute jump is already
  meaningful and 10 % of a 140 kg squat is a different exercise.
- A cap cannot conjure a finer increment. When the smallest available step exceeds the cap — a 5 kg
  machine stack at 25 kg, a 2 kg dumbbell at 10 kg — the engine requires **one extra** qualifying
  session before taking it, and says so (`progression.explain.bankBeforeBigJump`). The user keeps
  training; the load waits until the evidence is stronger.
- Rounding can snap a nominal increase back onto the current load (sparse dumbbell racks do it
  routinely), so `harderLoad`/`easierLoad` step outwards by whole increments until the *rounded*
  result actually moves, bounded at 16 probes. At the floor — an empty bar, or no assistance left to
  add — they return `nil` and the engine answers `progression.explain.atMinimumLoad` instead of
  pretending.

#### Other strategies

| Strategy | Trigger | Effect |
|---|---|---|
| `loadProgression` | target reps met once, RIR target met | `increaseLoad` (1 session — that is what makes it linear) |
| `repProgression` | all sets at the top | rep window shifts up (+2 to 15 reps, +3 to 24, +5 above); at the 30-rep ceiling it converts to a load increase and the window resets to the exercise's recommended range |
| `rirBased` | min recorded RIR ≥ target + 1 | `increaseLoad` after 1 session |
| | min recorded RIR ≤ target − 2 | `reduceLoad` −5 % immediately — keeping distance from failure is the point of this strategy, and one hard session is not a plateau |
| | no RIR recorded at all | falls back to double progression's evidence |
| `volumeProgression` | all sets at the top | `addReps` with one more working set, to 5 (compound) / 6 (isolation); at the ceiling, `increaseLoad` and sets drop back to 3 |

`ProgressionAction` has no "add a set" case, so `.addReps` carries it: the load did not change, which
is what the action means to the caller.

#### Movements with no external load

Reps: window shifts up on success by the same steps as `repProgression`, capped at **30** reps; then
a set is added (ceiling 5 compound / 6 isolation) with the rep window left where it is — someone
managing thirty press-ups a set does not need to be sent back to ten; then
`progression.explain.outgrown` says plainly that the movement needs load or a harder variation.
Two sessions short of the bottom shortens the window instead (floor 3 reps), reported as
`reduceLoad` because it is a back-off of the prescription.

Time: `ProgressionDecision` has no duration field, so for timed movements `recommendedRepRange`
carries **seconds**. `ProgressionEngine.prescribedSeconds(from:for:)` is the supported way to read it.
A stored window whose top is under 15 cannot be seconds — it is the default 8–12 rep range a fresh
state carries — so the window is derived from `metadata.estimatedSetSeconds` instead
(`lower = 0.6 × target` rounded to 5 s, floor 15 s). The window grows by 15 % (rounded to 5 s) per
successful session, up to three ceilings: **180 s for isometric holds** — past three minutes a hold
trains endurance, not strength — **120 s for loaded carries**, and **1800 s for timed cardio**. The
carry ceiling is deliberately low: a carry is a strength movement, and past roughly two minutes grip
endurance becomes the limit while the trunk stops being loaded hard enough to adapt. Sharing the
cardio ceiling made a farmer's walk effectively unprogressable — starting near 40 s and growing
5–10 s a session, it would have taken well over a hundred sessions to earn a single kilogram.
At the ceiling: add load if the movement is loadable (a carry), else add an interval for cardio, else
say it is outgrown. Holds never add a set at the ceiling: a fourth three-minute plank is a longer
session, not a harder plank.

#### Weighted and assisted movements

`state.workingWeightKg` is the number the user selects — added load for a weighted dip, assistance for
an assisted pull-up — never total system mass. Zero is a real prescription in both cases (bodyweight
only; fully unassisted), so the "usable working weight" check accepts it for these two loadabilities
and rejects it everywhere else. Assisted movements invert the direction of `harderLoad`, `easierLoad`,
`applyCalibration` and the deload, and are excluded from load, e1RM and tonnage records.

#### Deload

`ProgressionInput` carries only `isDeloadWeek`, so `decide` applies the conventional deload:
**−10 % load, −40 % sets**. A caller holding a richer `DeloadAssessment` calls
`deloadPrescription(from:assessment:loadability:increments:currentSets:)` directly. Zero reductions
in the assessment are read as "unspecified" and replaced with those defaults; both are then clamped
at **35 % intensity / 60 % volume** — a deload is a lighter week, not a different sport — and the set
count never falls below 1. Target RIR rises by 2 (capped at 5): staying far from failure is the point.
A deload that rounds back onto the working load is stepped one increment further.

`deloadPrescription` treats zero as a real working load on the two body-mass loadabilities, exactly as
`usableWorkingWeight` does: an unassisted pull-up in a deload week gets assistance *added* (0 → one
increment), and a bodyweight-only dip comes back as `0`, not `nil` — `nil` is reserved for movements
that carry no external load at all. It also returns `nil` where `LoadRounding.increment` is zero: with
no selectable step there is no lighter setting to name, and rounding one would invent a load the
implement does not have. When the load cannot move, the explanation drops to the sets-only wording
rather than reading "drops from 0 kg to 0 kg".

Crucially the **counters and the remembered working load are untouched**: a deload is a planned
lighter week, not evidence about the user, and next week resumes where the progression left off.

#### Calibration feedback

`applyCalibration` multiplies the attempted load by `CalibrationFeedback.loadMultiplier`
(1.15 / 1.00 / 0.95 / 0.85), inverting it for assisted movements, and rounds. If the result rounds
straight back onto the load the user just rejected — routine on a coarse ladder — it is forced at
least one selectable step in the intended direction: the user said the load was wrong, so repeating
it is not an answer.

#### Reps in reserve

`safeTargetRIR` clamps the caller's target to 0…5 with a floor of **2 for `never`/`beginner`** and 1
for everyone else. Novices' technique degrades before their muscles do, and their perception of how
close to failure they are is the least reliable of any group.

---

### 3. Personal records

`detect(performance:exercise:existing:)` returns records ordered by `PersonalRecordKind.allCases`, so
the output is stable for identical inputs. Only **completed working sets** are considered.

| Kind | Eligible tracking modes | Rule |
|---|---|---|
| `heaviestWeight` | `usesWeight`, not assisted | heaviest set; ties break towards more reps, and `repsContext` records them |
| `lightestAssistance` | assisted only | **least** assistance used for a completed set — the one record where a lower number wins |
| `mostReps` | `usesReps` | best rep count, gated on load (see below) |
| `estimatedOneRepMax` | `usesWeight && usesReps`, not assisted | best `OneRepMaxCalculator.estimate`, which itself refuses reps above 12 |
| `bestSetVolume` | `contributesToTonnage`, not assisted | best `weight × reps` |
| `longestDuration` | `usesDuration` | longest completed set |
| `longestDistance` | `usesDistance` | furthest completed set |

**Why the rep gate, and which way it faces.** Fifteen reps at 20 kg is not a rep record for someone
who has pressed 60 kg for eight; it is a lighter session. Gating on the *previous* best load is the
only defensible reading of "more reps" once load is free to vary — it also stops every deload week
from firing a rep PR. When no load record exists yet the gate is inert, which can happen only once per
exercise.

The gate has a direction, and it has to match the direction the movement progresses in
(`PersonalRecordDetector.RepGate`):

| Movement | Gate | Eligible sets |
|---|---|---|
| unloaded (`repsOnly`) | `.none` | every completed set |
| loaded | `.atOrAbove(heaviestWeight)` | at or above the heaviest load recorded |
| assisted | `.atOrBelow(lightestAssistance)` | at or **below** the least assistance recorded |

Assistance is a counterweight: 20 reps against 40 kg of help is a far easier set than 10 reps against
10 kg. Without the inverted gate, an assisted movement fires a "rep record" every time the user makes
the exercise easier — exactly the failure this section exists to prevent.

**Margins.** 0.1 kg for load, e1RM and tonnage; one whole rep; 0.5 s; 1 m. Floating-point arithmetic,
unit round-trips and a re-logged set all produce differences in the tenth decimal place, and a PR
banner for one of those is worse than no banner.

**Assisted movements** get `lightestAssistance` and `mostReps`, and nothing else. Assistance is stored
as a positive magnitude, so a bigger number is an *easier* set: `heaviestWeight`, `estimatedOneRepMax`
and `bestSetVolume` would all celebrate the wrong direction and are skipped. `lightestAssistance` is
the strength record for these movements, and zero — an unassisted rep — is a real and reachable value
rather than "no data". Everything downstream that compares record values (`ProgressRepository`'s
best-per-kind reduction, and the backup importer's keep-the-better rule) branches on
`PersonalRecordKind.lowerIsBetter` so the inversion is honoured in one place per consumer.
Driving assistance down is `ProgressionEngine`'s job, not the detector's.

**`sessionVolume` is not produced here.** This function sees one exercise, so it cannot know a session
total; whoever aggregates a finished workout owns that kind.

---

### 4. First-load estimation

`estimateStartingLoad` never invents a number. Sources in descending order of trustworthiness:

| Tier | Source | Confidence |
|---|---|---|
| 1 | `StrengthSeed` for this exact exercise | 0.80 |
| 2 | e1RM from this or a related exercise (same movement pattern **and** same target muscle) | 0.88 same exercise / 0.72 same implement / 0.62 across implements, minus 0.06 for a laterality mismatch and 0.04 for different equipment, then scaled by data sufficiency `min(1, 0.5 + 0.125 × min(sessions, 4))` |
| 3 | body-weight ratio table by experience | 0.45 beginner, 0.36 above |
| 4 | lightest selectable setting on the implement | 0.15 |

`requiresCalibration = confidence < 0.60`, set so that a number carried across from a *different*
implement always gets rated while the user's own numbers are trusted straight away. Returns `nil` for
anything with no selectable load (bodyweight, bands, holds, cardio, fixed implements) — those progress
in reps or time. Dictionary keys are sorted before iteration; unordered iteration would make the
choice between two equally good sources non-deterministic.

#### The shared scale

Every source is converted to a common **barbell-equivalent** figure, then back out to the target
implement's own units.

*Implement coefficients* (barbell = 1.00): EZ bar 0.92, machine stack 0.90, cable stack 0.85,
dumbbell **0.42**, kettlebell 0.40, fixed implement 0.25. The dumbbell figure is the important one: a
pair moves roughly 0.85 of the barbell total because each side stabilises itself, and the app stores
dumbbell loads **per bell**, which halves it to the widely quoted 0.40–0.45 of the barbell total.

*One documented exception*: `.squat` on a machine stack uses **1.40**. Leg presses and hack squats both
derive as a machine squat and their loadable ranges differ by more than a factor of two (leg press
≈ 2 × free squat, hack squat ≈ 0.8 ×). The pattern alone cannot tell them apart, so the app takes a
deliberately low middle and lets calibration correct it upwards.

*Laterality*: unilateral work on a barbell, EZ bar, machine or cable is halved per side. Handheld
implements are excluded — a dumbbell load is already per hand, and a one-arm row is if anything
slightly heavier per hand than the two-arm version because the free hand braces.

*Body-mass movements*: `system = bodyWeight × f + added` for weighted, `bodyWeight × f − assistance`
for assisted, where `f` is the share of body mass the pattern moves — vertical pull 0.95, calf raise
0.90, horizontal push (dips) 0.90, vertical push 0.85, horizontal pull and squat 0.65, lunge and
hinge 0.60, hip thrust 0.55, carry 0.50, core flexion 0.45, core anti-extension 0.40, else 0.55.
Assistance is never allowed to exceed 90 % of body mass; past that the machine is doing the set.

#### The ratio table

Estimated 1RM as a multiple of body mass, on the implement each pattern is calibrated against
(barbell for squat/hinge/lunge/hip thrust/carry/presses/rows/shrugs/curls/wrists; machine stack for
pulldowns, flyes, leg extension and curl, calf raise, ab/adduction, neck; cable stack for lateral
raises, pushdowns and cable core work), per experience level `never / beginner / intermediate /
advanced`:

```
squat            0.55 0.75 1.15 1.55      chestFly           0.20 0.30 0.45 0.60
hinge            0.70 0.95 1.40 1.85      shoulderRaise      0.10 0.14 0.20 0.26
lunge            0.35 0.50 0.75 1.00      shrug              0.50 0.70 1.00 1.30
hipThrust        0.60 0.85 1.30 1.75      elbowFlexion       0.18 0.25 0.35 0.45
carry            0.45 0.60 0.90 1.20      elbowExtension     0.20 0.28 0.40 0.52
horizontalPush   0.40 0.55 0.85 1.15      kneeExtension      0.40 0.55 0.80 1.05
verticalPush     0.28 0.38 0.58 0.78      kneeFlexion        0.28 0.40 0.58 0.75
horizontalPull   0.38 0.52 0.78 1.05      calfRaise          0.60 0.85 1.20 1.55
verticalPull     0.55 0.75 1.20 1.55      hipAb/Adduction    0.25 0.35 0.50 0.65
wristFlexion     0.10 0.14 0.20 0.26      coreFlexion        0.25 0.35 0.50 0.65
wristExtension   0.06 0.09 0.13 0.17      coreRotation       0.12 0.18 0.26 0.34
neckMovement     0.05 0.07 0.10 0.13      coreLateralFlexion 0.15 0.22 0.32 0.42
other            0.15 0.22 0.30 0.40      coreAntiExtension  0.12 0.18 0.25 0.32
```

Calibrated against the untrained/novice/intermediate/advanced columns of the commonly cited strength
standards for men, then trimmed towards their lower bound. These exist to produce a *safe first
guess*, not to grade anybody: 20 % light costs one warm-up set, 20 % heavy costs a failed rep on a
movement the user has never performed.

**Sex factor.** Population averages put female upper-body strength at roughly 0.60–0.65 of male at the
same body mass and lower-body at 0.70–0.80, chiefly through lean-mass distribution, so the table is
scaled by 0.62 (upper) / 0.75 (lower) for female. When the user declined to say, the app takes the
midpoint of the two constants — the same convention its metabolic formulas already use.

**Safety factors and clamps.** Working load = `weight(forReps:) × 0.95` for tiers 1–2 and `× 0.90` for
tier 3. Body mass is clamped to 30–250 kg (outside that it is a typo, not a person) and the
barbell-equivalent 1RM to **4 × body mass** — a 4 × body-weight deadlift is a world record, so anything
past it is corrupt input. The result is floored at the implement's minimum (bar weight, lightest
dumbbell, one stack increment) except for weighted and assisted movements, where zero is meaningful.

Worked example — 80 kg beginner male, barbell bench, 8 reps: `0.55 × 80 = 44 kg` 1RM → `× 0.797`
(8-rep fraction) `= 35.1` → `× 0.90 = 31.6` → rounded onto a 20 kg bar with 1.25 kg plates (so 2.5 kg
of total load per pair) = **32.5 kg**.

#### Warm-up ramp

2–4 sets from roughly 40 % to 85 % of the working load with descending reps: enough exposure to
rehearse the groove and raise tissue temperature, not enough volume to eat into the working sets.

| Working load (compound) | Sets | Fractions |
|---|---|---|
| < 30 kg | 2 | 50 %, 75 % |
| 30–70 kg | 3 | 40 %, 60 %, 80 % |
| ≥ 70 kg | 4 | 40 %, 55 %, 70 %, 85 % |

**Light isolation work is skipped entirely** below **20 kg**: 40 % of that is a load the user could
hold all day, the first working set is a better warm-up than any ramp, and across a session full of
isolation movements the ramps cost several minutes for nothing. Isolation above the threshold gets a
single set at 60 %.

Reps descend as a fraction of the movement's own top-of-range (anchored at `min(12, upper)`, so a
5-rep squat does not get a 12-rep warm-up), forced strictly decreasing and floored at 2. Rest is 45 s
except before the working set, where it is half the movement's own rest quantised to quarter-minutes
and clamped to 60–120 s — a rest timer that reads 82 seconds looks calculated rather than coached.
Sets that round onto or past the working load are dropped, as are duplicates produced by a coarse
ladder. Assisted movements ramp the other way — the fractions are mirrored about 1, so the two rungs
they get land at 1.5 × and 1.25 × the working assistance.

---

### 5. Localisation note

`Explanation` stores a key plus **already-formatted strings** (`arguments: [String]`), so every
placeholder in `Tools/l10n/keys/progression.en.json` is `%@`. Using `%lld` for a numeric argument
would reinterpret the bridged string pointer as an integer and print garbage — verified, not assumed.

Numbers are formatted by `TrainingFormat` without `NumberFormatter`. `Locale.current` is ambient
process state, and an engine whose output changes with the device region cannot be pinned down in a
test; `String(format:)` with no locale always uses the POSIX decimal point. Loads are quoted in
canonical kilograms, because the engines run with no access to the user's unit preference.

---

## Recovery, deload and autoregulation

Three pure engines, all value-in / value-out, all deterministic, none of them aware of SwiftUI,
SwiftData or the clock (every entry point takes `now:`).

| Engine | File | Answers |
|---|---|---|
| `RecoveryEngine` | `Domain/Training/RecoveryEngine.swift` | how much recent stimulus is still outstanding |
| `DeloadEngine` | `Domain/Training/DeloadEngine.swift` | has the user earned an easy week |
| `AutoregulationEngine` | `Domain/Training/AutoregulationEngine.swift` | what small change should the next session carry |

> **What the recovery model is.** Bookkeeping. It counts stimulus applied, lets it decay, and
> reports the remainder so the app can make a *recommendation*. It measures no physiology — not
> muscle damage, not hormones, not nervous-system state — and the app must never present it as a
> medical or diagnostic figure.

---

### 1. Recovery

#### Fatigue per muscle group

```
raw(group)  = Σ over sessions in the last 10 days
                  [ Σ over hard sets  fatigueCost × volumeCredit(group) × proximity(RIR) ] × effort
                  × 0.5 ^ (hoursSince / halfLife(group))

fatigue(group) = 1 − e^(−raw / 2.75)                                     → 0…1
halfLife(group) = MuscleGroup.baselineRecoveryHours / log2(10) ≈ /3.32
```

**Two paths into `raw`, and it matters which one you are reading.** The per-set form above needs the
exercise catalogue, so it is what `fatigueContribution(of:catalog:)` computes. `snapshot` — the
entry point that actually produces a `RecoverySnapshot` — takes no catalogue, and works instead from
`SessionOutcome.groupSets`, the per-group set credits the logger already recorded (these have
`volumeContribution` baked into them). Each credit is priced at the catalogue-typical cost, using
the session's mean reps in reserve rather than each set's own:

```
raw(group)  = groupSets[group] × 0.45 × proximity(sessionRIR) × effort
              × 0.5 ^ (hoursSince / halfLife(group))
```

Same shape, one degree less fidelity: a session of heavy compounds and one of machine isolations
cost the same per credit. Decay, saturation and the subjective terms are identical, so everything
below applies to both.

* **Half-life.** `baselineRecoveryHours` is defined as the point at which 90 % of the stimulus has
  dissipated, which fixes the half-life at `baseline / log2(10)`. Quads (60 h) → 18.1 h: ~40 % left
  after a day, ~16 % after two, 10 % at the 60 h mark. Calves and abs (34 h) → 10.2 h, which is why
  small muscles tolerate more frequency.
* **Saturation.** Raw units are unbounded, so `1 − e^(−raw/K)` maps them onto 0…1 with diminishing
  returns and no clipping artefacts. `K = 2.75` is calibrated so that one hard session for a group
  (≈4 working sets of a ~0.6-cost compound ≈ 2.5 raw units on the per-set path) reads ≈0.60
  immediately afterwards. Measured through `snapshot`: 6 quad set credits at 1.5 RIR on a session
  rated "hard" (3.54 raw) → quads 0.72 at +0 h, 0.67 at +4 h, 0.40 at +24 h, 0.18 at +48 h.
* **Spill onto synergists.** Credit is `ExerciseMetadata.volumeContribution`, so a barbell row
  credits lats 1.0 and biceps 0.5, exactly as weekly volume accounting does. Indirect work
  therefore fatigues at its fractional rate rather than not at all — on the per-set path because
  the cost is multiplied by the credit, on the `snapshot` path because the credit is already inside
  `groupSets`.
* **Session effort.** `SessionEffortFeedback.fatigueDelta` scales the whole session: easy ×0.85,
  good ×1.00, hard ×1.15, exhausting ×1.35.

#### Proximity to failure

```
proximity(rir) = clamp(1.32 − 0.12 × rir, 0.80, 1.35)
```

Failure 1.32, 1 RIR 1.20, 2 RIR 1.08, 3 RIR 0.96, 4 RIR 0.84 — a set to failure costs ~37 % more
than the same set stopped at 3 RIR. The value comes from the set's own `rir`, then from its `rpe`
(`RIR = 10 − RPE`), then from the session's `averageRIR`, and finally from an assumed target —
`TrainingProfileSnapshot.defaultTargetRIR` (i.e. `ExperienceLevel.defaultRIR`, 2–4) inside
`snapshot`, and the neutral `RecoveryTuning.assumedTargetRIR` of 2 in `fatigueContribution`, which
is not given a profile. A missing rating is never read as "taken to failure".

On the per-set path each set is priced by its own rating; on the `snapshot` path the whole session
is priced by the mean of whatever its sets rated, falling back the same way.

#### Subjective check-ins

Each check-in becomes a 0…1 index where 0.5 is neutral, weighting whatever the user actually
answered and renormalising over the rest:

| component | weight | mapping |
|---|---|---|
| energy | 0.28 | (v − 1) / 4 |
| sleep quality | 0.22 | (v − 1) / 4 |
| sleep hours | 0.14 | clamp((h − 5) / 3) — 5 h → 0, 8 h → 1 |
| soreness | 0.16 | inverted |
| stress | 0.12 | inverted |
| motivation | 0.08 | (v − 1) / 4 |

Check-ins inside a 72 h window are combined with a 24 h recency half-life (yesterday counts half).

Readiness:

```
objective = 1 − (1 − e^(−Σ_g raw(g)·w(g) / 12))          w = 1.0 large, 0.5 small, 0.8 cardio
readiness = objective + 0.20 × (2 × subjectiveIndex − 1)   ← term omitted entirely when no check-in
```

The subjective term is a **modulation around neutral**, not a blend. That is what makes "no
check-in" mathematically identical to "no information": a neutral check-in moves readiness by ~0,
a great one by up to +0.20, a poor one by up to −0.20, and an absent one by exactly nothing.

`K_sys = 12` is calibrated against one reference day, measured through `snapshot`: six quad set
credits plus three glute credits at 1.5 RIR, rated "hard", is 5.31 weighted raw units → **0.64
readiness** on the day, 0.84 after a day, 0.93 after two. Four of those days on four consecutive
days stack to 8.6 raw → **0.49 readiness** (0.64 → 0.54 → 0.50 → 0.49 as each is added). Anything
below that is a genuinely heavy block rather than a normal week.

**Sore groups.** A group the user names as sore has its raw fatigue multiplied by
`1 + 0.35 × severity·recency` and is floored at `0.30 × severity·recency`, so a group reported sore
never reads as completely fresh even when the app has no session record for it. Severity is the
numeric soreness answer, floored at 0.4 because naming the group is itself the signal, or 0.6 when
the numeric question was skipped.

#### Other snapshot fields

* `daysSinceStimulus` — whole elapsed days (`floor(hours / 24)`, not calendar days, so it is
  reproducible across time zones) since the group last received ≥0.5 set credits. `nil` = never.
* `weeklySets` — fractional set credits over the trailing 168 h.
* `recentSessionCount` — sessions in the trailing 168 h with at least one completed set.
* `readyGroups(_:threshold: 0.35)` — the point at which roughly two thirds of a hard session has
  dissipated. Sorted ascending by fatigue; cardio and neck are excluded (programmed separately).
* `readinessSummary` — four wide bands (0.85 / 0.65 / 0.45). The top two say the same thing either
  way; the bottom two each have a group-level and a systemic-level wording, chosen by whether any
  group is carrying ≥0.5 fatigue. Bands are wide because a summary that flips on a 0.01 change
  reads as noise.

---

### 2. Deload detection

Six independent signals, scored 0…1, weighted and summed. **Weights sum to 1.0 and the largest
(0.28) sits below the 0.40 severity threshold, so no single signal can ever recommend a deload** —
the property is structural, not just a rule. On top of that, at least two signals must reach 0.30.

| # | Signal | Weight | Fires when |
|---|---|---|---|
| a | performance regression | 0.28 | e1RM down over the last three sessions (two consecutive steps) on ≥2 exercises |
| b | elevated fatigue | 0.20 | several groups ≥0.60 fatigue, or systemic readiness low |
| c | effort inflation | 0.16 | same loads (±3 %) leaving ≥0.75 *fewer* reps in reserve |
| d | block length | 0.18 | hard weeks since the last easy one, ramping 3 → 7 |
| e | poor check-ins | 0.12 | ≥3 check-ins in a week averaging below neutral |
| f | missed sets | 0.06 | unfinished-set rate high or rising |

* **(a)** Epley `1RM ≈ w × (1 + reps/30)` on the best working set, capped at 15 reps because every
  rep-max formula falls apart above that. A drop counts only past **2.5 %**, since session-to-session
  e1RM noise from bar speed, rounding and rep judgement is routinely 1–2 %. Needs ≥3 eligible
  exercises and ≥2 regressing; strength is `clamp((regressingFraction − 0.2) / 0.4)`.
* **(b)** `max(clamp((elevatedGroups − 1)/4), clamp((0.55 − readiness)/0.35))`. One loaded group
  after a hard day is normal; five at once is a block catching up.
* **(c)** Per exercise: newest top-set load within 3 % of the mean of the previous two, with mean
  reps in reserve down ≥0.75. Falls back to session-level `averageRIR` drift for users who rate
  sessions but not sets: `clamp((drop − 0.5) / 1.0)`.
* **(d)** `clamp((weeks − 3) / 4)` — a 4–6 week mesocycle before an easy week is the standard
  convention, so the ramp spans exactly that window. It never forces a deload on a calendar date;
  it only contributes.
* **(e)** `clamp((0.5 − meanIndex) / 0.3)` over check-ins in the last 7 days, and **only** with at
  least three of them. Fewer means no opinion, never a bad one.
* **(f)** `max(level, rise)` where `level = clamp((missed − 0.08) / 0.22)` (8 % missed is ordinary,
  30 % is a session falling apart) and `rise` compares the last 4 sessions with the 4 before them.

**Gates — a deload is never recommended without a block to unload.** At least 6 sessions in the last
28 days, at least 21 days between the oldest and newest session on record, experience above
`.never`, and at least 2 weeks since the last deload.

**Prescription.**

```
n                  = clamp((severity − 0.40) / 0.35)
volumeReduction    = 0.40 + 0.10 × n        → 40…50 %
intensityReduction = 0.10 + 0.05 × n        → 10…15 %
```

Keeping the movements and the habit while cutting the dose is the conventional prescription, and
deliberately not a week off. Reasons are returned strongest-contribution-first and name the signals
that actually fired; when signals fire but the threshold is not met the assessment returns
`shouldDeload = false` with a "worth watching" note and zero reductions.

Worked examples from the harness: three exercises regressing and nothing else → severity 0.28
(one signal), no recommendation. Effort inflation plus a five-week block → 0.16 + 0.09 = 0.25, two
signals fired but under threshold, so a "worth watching" note. All three of the eligible exercises
regressing + four groups at or above 0.60 fatigue + a six-week block + three check-ins answered at
the bottom of every scale → 0.28 + 0.15 + 0.135 + 0.12 = severity **0.685**, deload at 48 % volume
and 14 % intensity, reasons ordered regression → fatigue → block length → check-ins.

---

### 3. Autoregulation

`magnitude` semantics, which the contract type does not spell out: fraction of load for
`reduceLoad`/`increaseLoad`, number of sets for `addSet`/`removeSet`, seconds for `restLonger`,
minutes for `shortenSession`, and 0 for `swapExercise`/`noChange`.

| Proposal | Condition | Size |
|---|---|---|
| `reduceLoad` | ≥50 % of an exercise's ≥2 rated sets badly missed (≥2 reps short, or below 75 % of target), on a movement that carries external load | −5 %, or −10 % past a 75 % miss share |
| `restLonger` | reps fell to <65 % of the first set, or ≥4 reps down, across ≥3 sets at a load that did not drop, on an exercise that did **not** just earn a load cut | +30 s |
| `removeSet` | group fatigue ≥0.75 and the week stays at or above `VolumeTargets.minimum` | −1 set, one group |
| `addSet` | session easy — rated `.easy`, or ≥1.5 RIR above target, and never one the user called hard or exhausting — **and** ≥95 % of the planned sets finished **and** `weeklySets + 1 ≤ min(target, maximum)` **and** group fatigue ≤0.45 | +1 set, ≤2 groups |
| `swapExercise` | user replaced it mid-session (it is a key of `substitutedExerciseIDs`), or it fell short on all of ≥3 rated sets and the load cannot be lightened | — |
| `shortenSession` | duration >115 % of `sessionMinutesCap` | min(overrun, 15) minutes |
| `noChange` | nothing above fired | — |

* **Everything is small and it is enforced in code, not just intended.** One load adjustment per
  exercise (miss shares are aggregated per exercise id before anything is proposed); one added set
  per group per round, and never one that would push `weeklySets` past `min(target, maximum)` — the
  week's additions are bounded by the volume budget itself, not by a counter, so a group already at
  its target finds the room taken while one well under it can gain a set on more than one day; at
  most two groups gaining a set, two swap suggestions, two rest changes and six proposals in total.
* **Load cut versus rest.** When the *first* working set hit its target and only later sets fell
  away, the load is demonstrably right and the load cut is suppressed in favour of longer rest.
  When even the first set fell short, the load is the problem and the load cut fires — and the rest
  change is then suppressed for that exercise, so the user is never handed "lift less **and** rest
  longer", which is two changes to one variable in a single session.
* **Load cut versus swap.** Anything that earned a load cut is excluded from the failure-based swap:
  taking weight off is the gentler fix and deserves a session to work, and "lighten this *and*
  replace it" is not advice a user can act on. The swap therefore fires for exercises the user
  actively substituted away, and for exercises that failed on every set where there is no load to
  remove or the movement is above the user's difficulty ceiling.
* **"Repeatedly".** A single `SessionOutcome` cannot see repetition, so an active mid-session
  substitution (the user already swapped it once) and a total failure across every set stand in for
  it. The substitution signal is read from `substitutedExerciseIDs`, whose keys are the exercises
  swapped *away from*; it is deliberately not intersected with `skippedExerciseIDs`, which records
  the id of the slot as finally performed — the replacement — so requiring both would make the
  branch unreachable.

#### `apply(_:to:catalog:)`

Applies only what a session plan can express — sets, rest, session length. `reduceLoad` and
`increaseLoad` are deliberate no-ops here because a `GeneratedSession` carries no loads; those go to
`ProgressionEngine`. `swapExercise` is a no-op because choosing the replacement belongs to
`ExerciseSubstitutionEngine`.

Guarantees:

* a `GeneratedExercise` with `isLocked` is never touched, for any reason;
* no exercise ever drops below one working set;
* at most one set removed per exercise and three per session per call, so a fatigue-driven removal
  and a length-driven trim cannot compound and gut the main lift;
* rest is capped at 240 s and sets at 6 per exercise;
* `estimatedMinutes` moves by exactly the time added or removed (`estimatedSetSeconds + restSeconds`
  per set), so it stays consistent with however the programming engine originally computed it —
  with a 10-minute floor, which is the only case where the move is not exact;
* `magnitude` is an unconstrained `Double` on a public type, and `apply` accepts adjustments it did
  not build, so every conversion to seconds is guarded: a non-finite magnitude means "no change"
  and an absurd one is clamped (`Int(Double.nan)` and `Int(1e30)` both trap in Swift).

Order of application: rest, then additions, then removals, then the trim — so the trim sees the
session as it will actually be performed. Volume is added to the lowest-`fatigueCost` movement for
the group and removed from the highest, with `orderIndex` as the tie-break.

#### Determinism

`AutoregulationAdjustment.id` defaults to a fresh `UUID()`, which would make identical inputs
produce non-equal outputs. Ids are therefore derived from the adjustment's own content with FNV-1a
(run twice from different offset bases to fill sixteen bytes, then stamped with the RFC 4122 version
and variant bits). Swift's `Hasher` is deliberately not used: its seed is randomised per process.
Every dictionary iteration that reaches an output is sorted, and every sort has an explicit
tie-break.

#### Localisation

Every proposal whose sentence names an exercise (`reduceLoad`, `restLonger`, both swaps) requires
the exercise to be in the catalogue and is dropped otherwise — a raw dataset id such as `0025` is
not something to put in front of a user.

Keys live in `Tools/l10n/keys/recovery.en.json`. `Explanation.arguments` is `[String]`, so **every**
placeholder in these keys is `%@`, including numeric ones — passing a `String` where `%lld` is
expected would format a pointer. Numbers are pre-formatted by the engine as plain integers (no
decimal separator, so the stored argument is locale-independent). Muscle-group names are never put
into arguments, because an argument cannot be localised at resolution time; the group travels on
`AutoregulationAdjustment.muscleGroup` and the UI localises it. Counts only appear where the signal
that produced them guarantees a value of two or more, which sidesteps "1 exercises".

A number in a sentence has to be the number the sentence is about, which is not always the
`magnitude`. `autoreg.shortenSession` says how far the session ran past the cap, so its argument is
the **overrun**, while the magnitude is the trim — `min(overrun, 15)`. Quoting the magnitude would
tell a user who ran 45 minutes over that they ran 15 minutes over.

---

## Energy, macros, weight trend and meal recommendation

Four pure engines in `GymApp/Domain/Nutrition`, all value-in/value-out, all free of SwiftUI and
SwiftData. Nothing reads the clock or the calendar from inside a decision: where "now" or a calendar
matters they are parameters, defaulted at the call boundary purely for convenience, so every result
below is reproducible in a test.

| Engine | Question it answers |
| --- | --- |
| `NutritionRecommendationEngine` | What should this person eat today? |
| `WeightTrendAnalyzer` | What is the scale actually doing? |
| `NutritionAdjustmentEngine` | Should the target move, and by how much? |
| `MealRecommendationEngine` | What could they eat right now to hit what is left? |

Every user-facing string is an `Explanation` — a localisation key plus already-formatted arguments.
Because `Explanation.arguments` is `[String]`, **every catalogue entry for these keys uses `%@`
only**, and the engines format numbers themselves through `NutritionFormat` with a fixed,
locale-independent formatter. A `%lld` against a `String` argument would be undefined behaviour, and
a `NumberFormatter` bound to `Locale.current` would break reproducibility.

### 1. Energy targets

#### Resting energy — Mifflin-St Jeor

```
male:        10·kg + 6.25·cm − 5·age + 5
female:      10·kg + 6.25·cm − 5·age − 161
unspecified: 10·kg + 6.25·cm − 5·age − 78      // (5 + −161) / 2
```

`.unspecified` averages the two sex constants rather than guessing a sex, and says so in its
explanation. A missing age defaults to **30** (mid-adult range, worth at most ~±100 kcal across a
20–60 year old) and the explanation names the assumption. Inputs are clamped (30–300 kg,
120–230 cm, 14–100 years) so a half-finished profile cannot produce nonsense.

#### Maintenance

```
TDEE = BMR × ActivityLevel.multiplier × (1 + 0.012 × max(0, trainingDays − 3))
```

The activity multipliers are the conventional Harris–Benedict/Mifflin factors, and this app's
onboarding copy describes them in terms of *daily* movement ("desk work, little walking"), so
lifting sessions are only partly captured. A 60-minute session costs roughly 250–350 kcal; since
part of that already sits inside the multiplier, only **1.2 % of maintenance per session beyond the
third** is credited, capping at +4.8 %.

#### Offset from maintenance

```
weeklyChangeKg = ±pace.weeklyBodyMassFraction × bodyMass
dailyOffset    = weeklyChangeKg × 7700 / 7
```

7,700 kcal/kg is the conventional energy density of body-mass change (Wishnofsky's 3,500 kcal/lb).

| Direction | Rate |
| --- | --- |
| `.deficit` | full pace fraction (0.25 / 0.5 / 0.75 % of body mass per week) |
| `.slightDeficit` (recomposition) | half the pace fraction, with protein at the top of its band |
| `.maintenance` | 0 |
| `.surplus` | pace fraction capped at **0.5 %/week** — faster is mostly fat |

Direction comes from the primary goal's `energyBalanceDirection`. When that is `.maintenance` but a
target weight differs from current mass by more than **2 kg** (roughly a scale's noise floor over
weeks), the target weight steers instead.

#### Safety clamps

* Daily offset capped at **−1000 / +700 kcal** before anything else.
* Floor = `max(BMR × 1.1, absoluteFloor)`, with `absoluteFloor` = 1200 kcal (female) or 1500 kcal
  (male). `.unspecified` takes the **higher** floor: a floor set too high only slows progress, one
  set too low risks under-eating, so the asymmetry runs towards caution.
* Ceiling on later increases: maintenance + 750 kcal.
* Energy rounds to 10 kcal **away from** the floor, never through it. `.rounded()` on a target
  sitting two kcal above a floor of 1,252.9 lands on 1,250, which quietly breaks the one number the
  app promised never to go under, so the rounded value is raised back onto the grid.
* `weeklyBodyMassChangeKg` is recomputed **after** clamping, so it always describes the number the
  user was actually given.
* **When the floor lands above maintenance on a cut**, the explanation and the macro split both
  follow the balance the user actually gets rather than the one they asked for. A small, older,
  sedentary person can have an estimated maintenance below the 1,200/1,500 kcal absolute floor, so
  their target is above maintenance however hard they asked to cut; the app says exactly that ("the
  lowest intake this app will recommend for you is already above your estimated maintenance —
  moving more is the better lever") instead of claiming a deficit that does not exist, and the
  macros drop the deficit protein bump. `EnergyTargets.direction` still records the *intent*, which
  is what the rest of the app reasons about.
  A **surplus** is excluded from this rule. That user already asked to eat above maintenance, so the
  floor removed nothing — it only made the surplus bigger than requested. They keep the surplus
  sentence plus the "raised to the app's minimum" note; handing them the fat-loss "moving more is
  the better lever" line would be advice against the goal they chose.
* The final explanation on every target set states plainly that these are estimates, not medical
  advice.

### 2. Macronutrients

Order of operations: protein, then fat with a hard floor, then carbohydrate as the remainder.

**Protein** — 1.6–2.2 g/kg/day, the mainstream sports-nutrition consensus band for people who train.
Starting at 1.6 and adding: +0.3 in any deficit (protein sparing is why the band has an upper end),
+0.2 for a muscle/strength/recomp goal (+0.1 for fat loss), +0.1 for ≥5 training days or an
active/very active lifestyle; clamped back into the band.

*Adjusted mass*: above **BMI 30**, prescribing g/kg on scale mass produces numbers nobody eats
(2 g/kg of 140 kg = 280 g). The clinical adjusted-body-weight correction is used instead —
`reference + 0.4 × (actual − reference)` where `reference` is the mass at BMI 25 — and the
explanation names the adjusted figure. Skipped when the height on file is implausible.

**Fat** — 25 % of energy in a deficit or surplus, 27 % at maintenance or on a recomp (carbohydrate
protects training quality, which is what protects muscle on a cut and builds it on a bulk). Floor is
`max(0.6 g/kg, 20 % of energy)`, enforced, for hormone production and fat-soluble vitamin
absorption.

**Carbohydrate** — the remainder. If it would fall below **40 g**, protein is walked back towards
its 1.6 g/kg floor; if it would still go negative, fat is walked back towards its floor; if both
floors together still exceed the budget, protein and fat are scaled proportionally and carbohydrate
is set to zero with an explanation suggesting a slower pace. **No macro is ever returned negative.**

Protein and carbohydrate round to 5 g, fat to 1 g, energy to 10 kcal, so the macro-derived energy
can sit up to ~20 kcal from the headline figure. That is deliberate: round numbers are worth more to
the user than an arithmetic identity.

### 3. Weight trend

Daily body mass swings by roughly ±1 kg on water, glycogen, sodium and gut content — more than a
week of real fat loss at any sane rate. Nothing downstream is allowed to see raw readings.

* Readings are bucketed per calendar day and **averaged** within the day (weighing before and after
  breakfast must not inject a step), implausible masses (outside 20–400 kg) and future dates are
  dropped. The `Calendar` doing the bucketing is a parameter rather than ambient state, since which
  readings land on which day depends on the time zone. Both windows below are stepped with that same
  calendar rather than with a multiple of 86,400 seconds: a day is 23 or 25 hours across a
  daylight-saving change, and a fixed-seconds cutoff silently shortens the 7-day average to six days
  — and drops the oldest day of the 21-day regression — for the week after an autumn transition.
* **Moving average**: trailing 7-day. Trailing rather than centred because a centred window cannot
  produce a value for today, which is the number the dashboard needs. Seven days so the window
  closes over exactly one of every weekday — weekend eating is the largest weekly cycle in most
  people's data.
* **`weeklyChangeKg`**: OLS regression slope × 7 over the trailing **21 days**, requiring ≥8
  readings spanning ≥14 days. Regressing the *raw* daily points, never the moving average: smoothing
  has already removed exactly the variation the confidence figure is supposed to measure.
* **`hasEnoughData`**: ≥10 daily readings spanning ≥14 days.
* **`confidence`** = `0.40 × count + 0.35 × noise + 0.25 × span`, where
  `count = min(1, readings/21)`, `span = min(1, spanDays/21)` and
  `noise = clamp01(1 − (residualSD − 0.3) / 0.9)` — residual SD ≤0.3 kg scores full marks, ≥1.2 kg
  scores zero, bracketing normal daily fluctuation. Rounded to 3 dp so equality is stable.

### 4. Calorie adjustment

Slow, small, and always proposed rather than applied — `requiresUserApproval` is `true` on every
result, including the "nothing changes" ones.

Gates, in order:

1. `hasEnoughData` and a regression slope, else `.insufficientData`.
2. Newest trend point no older than **10 days**, else `.insufficientData` (the user stopped weighing
   in).
3. `confidence ≥ 0.35`, else `.hold`.
4. `daysSinceLastAdjustment ≥ 14`, else `.hold` — a weekly nudge chases measurement error and leaves
   the user unable to tell which change caused which result.
5. `adherence ≥ 0.8` when known, else `.hold`: the observed trend cannot be attributed to a target
   the user was not following. `nil` adherence does not block.

Then compare observed against intended:

```
gap       = targetWeekly − observedWeekly
tolerance = max(0.15, 0.30 × |targetWeekly|) × (2 − confidence)      // kg/week
```

The 0.15 kg/week floor covers the standard error of a three-week regression on noisy daily readings.
The confidence term widens the band when data is poor, so noisy data makes the engine *more*
reluctant to act rather than equally willing.

Inside the band → `.hold` ("on track"). Outside it:

```
delta = gap × 7700 / 7 × 0.5                                  // correct half the gap
      clamped to [5 %, 10 %] of current intake, hard cap ±250 kcal
      then clamped by the safety floor and the maintenance + 750 ceiling
```

Half-gap damping exists because the observed gap contains estimation error and the body closes part
of any gap by itself; correcting it fully produces oscillation. A residual change below 25 kcal is
dropped as not worth asking about.

The ceiling can never sit below the floor: it is `max(floor, current intake, maintenance + 750)`.
Clamping to a bare `maintenance + 750` after the floor had already been applied would hand the user
a target *under* the lowest intake the app is willing to recommend whenever the incoming record
carried a stale or missing maintenance figure. For the same reason a `totalDailyEnergyExpenditure`
of zero is read as "this record never carried one" and re-estimated from the profile, rather than
taken literally.

**Macro redistribution**: protein does not move — it is the macro with an intake target independent
of total energy, and its job matters most precisely when calories are being cut. The change splits
**70 % carbohydrate / 30 % fat** by energy, with the fat floor enforced first (overflow goes to
carbohydrate) and a zero floor on carbohydrate second (overflow comes off fat).

Adding the change onto the existing grams only produces a coherent plate when those grams already
account for the existing calorie figure, and `EnergyTargets` defaults every field, so a caller can
hand over a set that does not reconcile. Two guards keep the output honest:

* Protein that is zero, negative, or alone larger than the new energy budget (or a negative
  carbohydrate or fat figure) means there is no split left to nudge, so one is **rebuilt** from
  scratch by `NutritionRecommendationEngine.macros`. Protein moving is the lesser evil against a
  plan that cannot be eaten.
* Otherwise carbohydrate and fat are **re-anchored** on the energy actually left after protein. On a
  consistent target set this changes nothing; what it prevents is the few kcal of rounding drift
  each adjustment introduces compounding across a year of fortnightly changes. Every later step
  moves energy *between* the two macros, so the returned split always adds up to the new target.

### 5. Meal recommendation

A suggestion has to be something a person can put on a plate, which rules out both picking foods at
random and offering fixed servings that never land on the macros actually left. So the engine builds
**patterns** and then **solves for portion sizes**.

#### Target for the meal

`min(dailyTarget × slotShare, cap)` where `slotShare` is `MealSlot.defaultEnergyShare` renormalised
over the slots the user actually eats (three-meal users have the snack share redistributed), and
`cap` is 900 kcal for a main meal, 350 kcal for a snack. When the remainder is already smaller, it
is taken whole — this is the last meal of the day. Macros already overshot target zero rather than
negative. Below 80 kcal remaining, nothing is suggested.

#### Hard exclusions

`dietType.excludedTags ∪ allergenTags ∪ intoleranceTags ∪ excludedFoodTags`, matched against the
union of a food's dietary, allergen and role tags. A hard exclusion is **never** softened into a
penalty, is applied in exactly one place, and also removes saved meals containing an excluded food
and recipes carrying an excluded tag.

#### Roles and patterns

Explicit `roleTags` win; otherwise composition decides, using both a share-of-energy and an
absolute-amount test (lettuce is 25 % protein by energy and is not a protein source):

| Role | Fallback rule |
| --- | --- |
| protein | ≥35 % of energy **and** ≥10 g/100 g |
| carbohydrate | ≥45 % of energy **and** ≥15 g/100 g |
| vegetable (incl. fruit) | <80 kcal/100 g **and** ≥1.5 g fibre |
| fat | ≥55 % of energy **and** ≥10 g/100 g |

Main-meal patterns, in priority order: protein+carb+veg, protein+carb+fat, protein+veg+fat,
protein+carb, protein+veg, carb+veg, carb+fat, protein alone. Snacks use a compact one-to-two item
list. The top 3 foods per role (4 for pairs, 6 for singles) feed a cartesian product that skips
repeated foods, capped at 400 evaluated combinations.

`other` is the role a food gets when neither its tags nor its composition single one out — a
sandwich, a ready meal, a protein bar, much of a supermarket. None of the named patterns can use
such a food, so **when every named pattern comes back empty** the engine falls back to one or two
`other` items. A user whose whole log is composite meals would otherwise be shown nothing at all,
which is a worse answer than an unglamorous one.

The suggestion's title key describes the plate that *survived rounding*, not the pattern that was
attempted: rounding a portion to whole pieces can drop an item, and a two-item plate must not be
announced as "Protein, carbs and vegetables". A shape with no name of its own — two composite
foods, or a plate whose roles collapsed after pruning — is titled "A mix of foods" rather than
mislabelled as a single food.

#### Portion solver

Bounded weighted least squares, solved by cyclic coordinate descent — each food's optimum given the
others has a closed form, clamped to that food's sensible range, repeated for a fixed **40 passes**
(fixed so the result is reproducible to the gram). Residuals are divided by the size of the thing
they measure, so a 10 g protein miss and a 10 g carbohydrate miss are not equally bad when the
targets are 40 g and 200 g. Macro weights: **protein 1.0, energy 1.2, carbohydrate 0.6, fat 0.6** —
protein because it is hardest to hit, energy because it is the day's ceiling.

Portion bounds (grams), overridden by the food's own default serving where it has one (up to 3×):

| Role | lower | upper | start |
| --- | --- | --- | --- |
| protein | 40 | 300 | 150 |
| carbohydrate | 30 | 300 | 120 |
| vegetable | 50 | 400 | 150 |
| fat | 5 | 60 | 20 |
| other | 20 | 300 | 100 |

Fats are bounded tightly or the solver would cheerfully prescribe 200 g of olive oil to close an
energy gap. Solutions are pruned (anything under 10 g is dropped) and re-solved so survivors take up
the slack, then rounded to **whole pieces** for foods with a meaningful `gramsPerPiece` (≥15 g — a
single almond is not a unit) and **5 g steps** otherwise.

#### Scoring

```
score = 0.34·macroFit + 0.22·calorieFit + 0.18·preferenceFit
      + 0.12·micronutrientFit + 0.14·varietyBonus
      − 0.25·restrictionPenalty
      + savedMealBonus (0.08) | recipeBonus (0.06)
```

Weights live in `MealScoringWeights`; the five additive weights sum to 1.0 so a raw score sits on
0…1 before bonuses.

* **macroFit** = `1 − (0.5·relProteinErr + 0.25·relCarbErr + 0.25·relFatErr)`, each error divided by
  the target macro (floored at 20/30/10 g).
* **calorieFit** = `1 − |Δ|/target`, with overshoot multiplied by **1.4**: the day has a ceiling and
  the next meal still has to fit.
* **preferenceFit** = `0.6 × (favourite/log-count) + 0.4 × slotFit`. Log count saturates
  logarithmically at 20 entries. Slot fit is 1.0 for a matching slot tag, 0.15 for a tag belonging
  to a different slot, and **0.5 for no slot tags at all** — treating unknown as wrong would bury
  the whole database under the handful of tagged items.
* **micronutrientFit** — coverage of fibre, potassium, calcium, iron and vitamin C against 25 % of
  their reference intakes, minus 0.4 × the excess sodium/saturated-fat load beyond 60 % of a 35 %
  meal share (saturated fat has no reference intake, so a 20 g/day ceiling is used ≈10 % of energy).
  Unknown nutrients are skipped; all-unknown scores a neutral 0.5, never zero.
* **varietyBonus** = share of items *not* logged in the last two days.
* **restrictionPenalty** = `0.7 × budget overrun + 0.3 × plate bulk`, where the per-meal budget is
  `weeklyFoodBudget / (7 × mealsPerDay)` and bulk ramps in above 900 g of total food. Costing more
  than **2× the meal budget** is a hard drop, not a penalty. Unknown cost is neutral, never free.

Saved meals and recipes are scored on the same macro and calorie fit, with use-count as preference
and a neutral 0.5 micronutrient score (no micronutrient data travels with them, and they must not be
punished for what the app failed to record). Recipes are offered at two servings only when one
serving leaves more than 45 % of the meal unfilled.

#### Output

De-duplicated by food set (same foods = same suggestion, however differently portioned), then picked
greedily with a **0.05 demotion per food already used by a picked suggestion** so the list is not
four variations on chicken and rice, then returned sorted by score, at most `request.limit`.

Every suggestion carries reasons naming the macros it fills, capped at four. Ids are FNV-1a hashes
of the suggestion's contents rather than fresh UUIDs, so identical requests produce identical
output and SwiftUI does not re-animate an unchanged list.

#### Determinism

No clock reads, no randomness, no reliance on `Set`/`Dictionary` iteration order, and every
comparison carries a full tie-break — down to the suggestion id — because Swift's `sort` is not
stable and de-duplication otherwise keeps whichever equal-scoring plate the caller happened to pass
first. Verified: reversing the candidate list, permuting it eight ways and re-running the same
request twenty-five times all produce byte-identical suggestions.

Formatting is part of this. Every explanation argument goes through `NutritionFormat`, which is
locale-independent (a `NumberFormatter` bound to `Locale.current` would make output depend on the
device) and saturates before converting to `Int` rather than trapping: `Int(_: Double)` is a
crashing conversion, and an imported food carrying an absurd per-100 g value must not be able to
take the app down inside a number formatter.

---

## The bundled food database

Everything the app knows about food arrives through one of three doors: the database bundled in
the app, Open Food Facts, or the user typing it in. This fragment covers the first two and the
machinery that keeps them interchangeable.

### The bundled database

`GymApp/Resources/FoodDatabase/foods.json` holds **594 records**, each stated per 100 g — or per
100 ml where `basisUnit` is `"ml"`, which covers 56 drinks and liquid staples. Coverage spans
meats and poultry, fish and seafood, eggs and dairy, legumes and meat alternatives, grains,
breads and pasta, nuts, seeds, oils and fats, fruit, vegetables, tubers, cooked staples (rice,
pasta, oats, potatoes), everyday prepared dishes, protein powders and supplements, drinks, and a
modest set of everyday packaged categories described generically. **No brand names or trademarks
appear anywhere in the file**; a packaged category is described by what it is ("Digestive
biscuit", "Energy drink, sugar free"), never by who makes it.

#### Provenance

Values are taken from **USDA FoodData Central — SR Legacy and Foundation Foods**. These are works
of the US Government and are in the public domain, which is why they can be shipped inside the app
with nothing more than an attribution. The attribution is recorded in
`food-database-manifest.json`, stamped onto every imported row as `FoodItem.attribution`, and
shown to the user under the key `food.database.attribution`.

A small number of generic composite dishes — lasagne, chicken curry, a chicken wrap — have no
single USDA record and are estimated from their ingredient lists instead. The manifest says so.

#### Unknown is not zero

`Micronutrients` stores every nutrient as an `Optional`, and the JSON honours that: **a
micronutrient key is emitted only when there is a defensible value for it, and omitted
otherwise.** Nothing is ever filled in with a plausible-looking guess. This is a product
requirement rather than a stylistic choice — conflating "not measured" with "contains none" would
let the app tell somebody they are deficient in a nutrient the data never measured.

Coverage, by way of illustration: fibre and sodium on all 594 records, potassium on 573, sugars on
389, saturated fat on 333, cholesterol on 172, iron on 150, vitamin C on 137, and progressively
fewer for the trace vitamins, which are populated mainly for the curated everyday foods.

#### Energy consistency check

Every record must have energy that agrees with its macros. The check runs in three tiers, plus a
fourth group whose energy does not live in the macros at all, and **594 of 594 records are
accounted for**:

| Tier | Rule | Records |
| --- | --- | --- |
| 1 | Atwater `protein × 4 + carbs × 4 + fat × 9` within **12%** of the stated kcal | 498 |
| 2 | The EU labelling calculation, crediting fibre at 2 kcal/g instead of 4 | 61 |
| 3 | Absolute error ≤ **15 kcal per 100 g**, by either calculation | 26 |
| — | Energy outside the macros: ethanol or acetic acid, checked separately below | 9 |

Tier 2 exists because USDA carbohydrate is *by difference* and therefore already includes fibre,
so plain Atwater systematically overstates fibrous plant foods. Crediting fibre at 2 kcal/g is
exactly the calculation EU Regulation 1169/2011, Annex XIV prescribes: energy =
`protein × 4 + (carbs − fibre) × 4 + fibre × 2 + fat × 9`. Raw broccoli, for example, is 41 kcal
under plain Atwater against a stated 34, and 36 kcal once fibre is credited correctly.

Tier 3 catches very low-energy plant foods — lemons, limes, cucumber, mushrooms, watercress, bean
sprouts — where USDA applies FAO *specific* Atwater factors and discounts organic acids such as
citric acid. The relative error looks alarming and the absolute error is trivial: at most 15 kcal
per 100 g, on foods logged in tens of grams. The bound still catches real data errors, because a
misplaced macro is worth far more than 15 kcal.

Two categories of energy sit outside the macros entirely and are handled explicitly rather than
being waved through:

- **Alcohol.** Ethanol supplies 7 kcal/g and no macronutrient field carries it. The seven
  alcoholic drinks in the database are checked against `macros + ethanol × 7`, where ethanol
  grams per 100 ml is `ABV × 0.789` (the density of ethanol). Their stored macros are correct; the
  app simply shows kcal that its own macro arithmetic cannot reproduce, which is how every food
  tracker handles alcohol.

  | Record | ABV | Ethanol g | Macros + ethanol | Stated | Residual |
  | --- | --- | --- | --- | --- | --- |
  | Lager | 4.0% | 3.16 | 38.5 | 43 | −10.5% |
  | Ale | 4.0% | 3.16 | 40.1 | 45 | −10.9% |
  | Cider, dry | 4.5% | 3.55 | 38.9 | 49 | **−20.7%** |
  | Sparkling wine | 11.5% | 9.07 | 69.9 | 76 | −8.0% |
  | White wine | 12.5% | 9.86 | 79.8 | 82 | −2.6% |
  | Red wine | 13.0% | 10.26 | 82.6 | 85 | −2.8% |
  | Spirits | 40.0% | 31.56 | 220.9 | 231 | −4.4% |

  **Dry cider is the one record this database cannot fully reconcile.** At 4.5% ABV and 3.5 g
  carbohydrate its composition implies roughly 39 kcal per 100 ml, and the file states 49. USDA
  FoodData Central carries no generic hard cider, so there is no authoritative figure to replace
  either number with, and each of the three on file is individually plausible: published dry
  ciders at this strength range from 36 to 49 kcal per 100 ml depending on residual sugar. The
  stated energy is left alone deliberately, because the residual errs towards *over*-stating a
  drink's calories, which is the safe direction for anyone tracking an intake target. Anyone
  revisiting this should change carbohydrate or energy together, never one alone.
- **Organic acids.** Balsamic and cider vinegar derive most of their energy from acetic acid at
  roughly 3.5 kcal/g, and are checked the same way. Both reconcile closely: balsamic at 6% acidity
  computes to 91 kcal against a stated 88 (+3.4%), cider vinegar at 5% to 21.1 against 21 (+0.5%).

A handful of USDA records were **deliberately excluded** because they cannot pass any honest
version of this check: wheat bran, oat bran and unsweetened cocoa powder, whose
carbohydrate-by-difference includes large unavailable fractions that USDA discounts through
specific factors the raw macros do not expose. Shipping them would mean shipping numbers that
contradict themselves.

#### Structural checks

Alongside energy, every record is checked for: a valid `basisUnit`; no negative values; macros
summing to no more than 100 g per 100 g; fibre never exceeding carbohydrate; saturated fat never
exceeding fat; and no non-positive serving size. All 594 pass.

One deliberate exception is worth knowing about before somebody "fixes" it: on the three milk
records, **sugars exceed carbohydrate** by 0.2–0.3 g (whole milk is 4.8 g carbohydrate and 5.1 g
sugars). That is USDA's own arithmetic, not a transcription error — carbohydrate is computed *by
difference* while lactose is measured directly, and for milk the measured sugar comes out slightly
above the difference. The values are kept as USDA states them. Any UI that renders "of which
sugars" as a fraction of carbohydrate must clamp the ratio at 1 rather than assume it cannot
exceed it.

#### Tags

Three closed vocabularies, declared once in `FoodTagVocabulary` and enforced by the generator:

- `dietaryTags` — exactly `meat`, `poultry`, `fish`, `seafood`, `dairy`, `egg`, `honey`. This is
  precisely the set `DietType.excludedTags` matches against; anything else would silently fail to
  filter. Coverage leaves 471 foods for a vegetarian, 364 for a vegan and 520 for a pescatarian.
- `allergenTags` — `gluten`, `nuts`, `peanut`, `soy`, `shellfish`, `sesame`.
- `roleTags` — the vocabulary `MealRecommendationEngine` reads.

A dietary tag is only ever added, never inferred at read time, so the file is the whole story and
a missing tag is invisible until somebody is handed a food they do not eat. Four categories are
easy to miss and are called out here so the next audit starts from them:

- **Animal products that do not read as animal products.** Gelatin, collagen peptides, bone broth
  and fish oil all carry the relevant tag. Collagen peptides are hydrolysed bovine collagen and
  carry `meat` for exactly the same reason gelatin does — a supplement that reads as pure protein
  powder is precisely the sort of record a vegan filter must not miss.
- **Hidden ingredients in composite foods.** Worcestershire sauce is `fish` (anchovies), Thai
  curry paste is `seafood` (shrimp paste), mycoprotein is `egg` (egg-white binder), coleslaw and
  potato salad are `egg` (mayonnaise), and pesto and naan are `dairy`.
- **Molluscs are shellfish.** Every `seafood` record also carries the `shellfish` allergen,
  crustaceans and molluscs alike — squid and octopus included. Crab sticks carry it too: the base
  is pollock, but crab extract is a normal ingredient and the packs declare crustaceans.
- **Beer is a cereal product.** Lager and ale carry `gluten` because they are brewed from barley
  malt. Cider does not.

Where a generic record could plausibly go either way — stock cubes, gravy, refried beans, kimchi,
fresh gnocchi — no dietary tag is asserted, because the database describes a category rather than
a recipe. This is the one place where the honest answer is "the app cannot know", and a tag
invented to be safe would be a claim about somebody's dinner that the data does not support.

Role tags are **derived, not hand-typed**, so they cannot drift. The thresholds are regulatory
definitions rather than invented numbers, and `FoodRoleTagDeriver` applies the identical rules to
remote records so an imported tuna tin behaves like the bundled one:

| Tag | Rule | Basis |
| --- | --- | --- |
| `protein_source` | ≥ 10 g protein per 100 g **and** protein ≥ 25% of energy | EU Reg. 1924/2006 sets "source of protein" at 12% of energy and "high protein" at 20%; raised to 25% because in a training app the label should mean something stronger than yogurt-coated cereal |
| `carb_source` | ≥ 20 g carbs **and** carbs ≥ 45% of energy | Practical threshold: identifies foods eaten *for* their carbohydrate |
| `fat_source` | ≥ 15 g fat **and** fat ≥ 50% of energy | As above |
| `high_fiber` | ≥ 6 g fibre per 100 g | EU Reg. 1924/2006 "high fibre" |
| `lean` | a protein source with ≤ 10 g fat and ≤ 4.5 g saturated fat per 100 g | USDA labelling definition of "lean" |
| `drink` | `basisUnit == "ml"` | — |

`vegetable`, `fruit`, `supplement`, `budget`, `quick` and the four meal-slot tags are assigned per
record, because no formula can tell you that porridge is breakfast.

#### Localisation

244 records — the everyday foods a typical user logs most often — carry a `nameKey` and ship
translated; the remainder show their English name. Portions use a **closed vocabulary of 62
serving names** (`food.serving.tbsp`, `food.serving.fillet`, …) rather than free text, so every
built-in portion is translatable without translating six hundred bespoke strings.

### Search

`FoodSearchIndex` follows `ExerciseSearchIndex` deliberately, so search behaves identically in
both halves of the app: everything is pre-normalised at load (lowercased, diacritics stripped,
punctuation collapsed), and a query is a linear scan over compact strings with no per-keystroke
allocation. 200 searches over the full catalogue take ~165 ms in a release build, i.e. **under a
millisecond per keystroke**.

Every word of a multi-word query must match somewhere. Match quality is ranked
`exactName → namePrefix → nameTokenPrefix → nameSubstring → synonym → tag`, and the result takes
the *worst* rank across the query's words. Ties break on prominence, then on name length, then on
catalogue id so ordering is fully deterministic.

**Prominence** is the tie-breaker: `+1.0` for a curated `nameKey`, `+0.2` for having named
portions, `+0.1` for a budget staple. The curated set is the best available proxy for "what people
actually log", which is exactly what a tie-breaker wants.

Two fallbacks fire only when a word fails outright, and both were added to fix real misses:

- **Singularisation** — "eggs" → "egg", "tomatoes" → "tomato". Both `-es` candidates are tried,
  since the suffix is ambiguous ("grapes" drops one character, "tomatoes" two). A stemmer would be
  overkill for 600 fixed English names.
- **Synonyms** — a deliberately small table covering cooking states (the catalogue says "boiled"
  where users type "cooked") and British/American names (`courgette`/`zucchini`,
  `mince`/`ground`, `prawns`/`shrimp`, `tinned`/`canned`, `chips`/`crisps`/`fries`). Every entry
  is a rule somebody must maintain, and a broad synonym list makes search vaguer, not better.

Portion names are indexed as tags, so "cod fillet" and "chicken breast" find what the user means
even when the catalogue calls the portion a serving.

### Providers

```
protocol FoodDataProvider: Sendable {
    var identifier: String { get }
    var isRemote: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [FoodSearchResult]
    func food(withBarcode barcode: String) async throws -> FoodSearchResult?
    func food(withIdentifier identifier: String) async throws -> FoodSearchResult?
}
```

Providers return **values**, never model objects. Only a food the user actually logs becomes a
`FoodItem`. `CompositeFoodDataProvider` runs local providers first, then races the remote ones
against a 6 s budget, merges, and de-duplicates: same barcode, or same folded name with energy
agreeing to within 5 kcal. Any provider that fails is dropped with a logged reason rather than
taking the search down with it.

#### LocalFoodDatabaseProvider

**This is the provider that makes the app work offline.** It loads `foods.json` once, lazily, off
the main actor via a detached task whose handle is shared so concurrent callers pay for one
decode, and answers from memory afterwards. It holds no barcodes — the bundled database describes
generic foods, not packaged products — so `food(withBarcode:)` returns `nil` and lets the
composite fall through to a remote lookup. A failed load resets to `idle` so a later caller can
retry.

#### OpenFoodFactsProvider

Real `URLSession` calls against the public Open Food Facts API. `/api/v2/product/<barcode>.json`
for barcodes, `/cgi/search.pl` for text search. **No API keys exist anywhere** — their read API is
open, which is also why the whole provider could be deleted without touching anything else.

- **User-Agent.** Their terms require an identifying agent:
  `Forge/<version> (iOS <major>.<minor>; +<contact>)`. Sending a generic agent is grounds for
  being blocked.
- **Timeouts.** 8 s per request. Long enough for a slow mobile connection, short enough that a
  scan going nowhere returns to the local fallback before the user gives up.
- **Cancellation.** `Task.isCancelled` is checked before each request and after each response;
  `URLError.cancelled` maps to `FoodProviderError.cancelled`.
- **Rate limiting.** Client-side rolling one-minute windows at their published limits: 100 product
  reads and 10 searches per minute. Being throttled server-side costs the user a failed search;
  refusing locally costs them nothing, because the bundled results are already in hand.
- **Cache.** In-memory, keyed by request: 30 min for products, 10 min for searches, 5 min for
  misses (so re-scanning an unknown packet does not refire a doomed request), capped at 200
  entries with oldest-first eviction. The clock is injected, so expiry and rate limiting are
  deterministic under test.
- **Every failure is non-fatal** and maps onto `FoodProviderError`.

Their nutriment fields are the awkward part, and the mapper is built around it:

- Values arrive as numbers *or* strings, including `"12,5"` with a comma decimal separator, `""`
  and `null`. `LooseNumber` accepts all of them and yields `nil` rather than throwing, so one bad
  field cannot lose the whole product.
- Per-100 keys vary. `*_100g` is preferred; failing that, `*_serving` rescaled by
  `serving_quantity`.
- Energy: `energy-kcal_100g`, else `energy-kj_100g / 4.184`, else `energy_100g / 4.184` (their
  generic field is kilojoules), else Atwater from the macros — and the Atwater fallback is held to
  the same 950 kcal ceiling as a stated energy value, because each macro is capped independently
  and three capped-but-nonsensical macros would otherwise derive 1700 kcal per 100 g.
- **Minerals and vitamins are stored in grams** in the `_100g` fields, so each is scaled to the
  unit `Micronutrients` uses — ×1000 to mg, ×1 000 000 to µg — and each carries a plausibility
  ceiling, because a hundredfold error is common when a contributor types milligrams into a grams
  field. Sodium falls back to `salt × 400 mg`.
- Macros above 100 g per 100 g and energy above 950 kcal per 100 g are rejected as unit errors
  rather than imported.
- Dietary tags come from `categories_tags` keyword matching plus declared allergens (a legal
  statement about contents, hence trusted). An `en:vegan` analysis tag clears them outright, since
  that signal beats any category-name guess; `en:vegetarian` clears the flesh tags.
  Keyword matching on a category slug is deliberately biased towards over-tagging: `en:peanut-
  butters` and `en:coconut-milks` both match the `dairy` needles `butter` and `milk`, and
  `en:eggplants` matches `egg`, so a plant product with no ingredient analysis can be hidden from
  a vegan. That is the wrong answer, but it is the *harmless* wrong answer — one food the user
  does not see, against the alternative of narrowing the needles and handing a vegan something
  made of milk. The `en:vegan` analysis tag, which Open Food Facts assigns to most such products,
  clears the false positive; nothing clears a false negative.
- UPC-A is a 12-digit code that Open Food Facts stores as EAN-13 with a leading zero, so a
  12-digit miss is retried once with the zero prepended.

`FoodSearchResult.hasInconsistentEnergy(tolerance:)` flags remote records whose macros and energy
disagree, at a deliberately loose 25% — far looser than the 12% the bundled database is held to,
because crowd-sourced label data legitimately drifts and flagging a quarter of Open Food Facts
would train the user to ignore the warning.

### Import into SwiftData

`FoodDatabaseImporter` is a `@ModelActor`, so it owns a private `ModelContext` on its own executor
and runs off the main thread by construction. Four guarantees:

1. **Idempotent.** Rows match on `catalogID`, so re-running updates rather than duplicates.
2. **Versioned.** The manifest's `version` is recorded in `UserDefaults` under
   `"foodDatabaseVersion"`. An unchanged version does no work at all — but the built-in row count
   is checked too, so a user who reset their data is not left with an empty database because the
   version still "matched".
3. **Never touches user data.** Only `source == .builtIn` rows are considered. Custom foods and
   recipes are invisible to it, and the user state living on a built-in row — `isFavorite`,
   `timesLogged`, `lastLoggedAt`, `costPer100` — is read but never written. Only the
   catalogue-owned fields are copied, and only when they actually changed.
4. **Survives an upgrade that adds, changes and removes foods.** Additions insert; changes update
   in place so existing references keep working; removals are pruned only when nothing points at
   them.

That last point deserves its own paragraph. Before pruning, the importer gathers every food id
referenced by `FoodLogEntry`, `SavedMealItem` and `RecipeIngredient` in three fetches rather than
three per candidate. A withdrawn food that is referenced, favourited or has ever been logged is
**adopted** — converted to `source = .custom` with its `catalogID` cleared — rather than deleted.
The user keeps the food and every reference to it, the importer will never touch it again (that
is exactly the guarantee custom foods have), and a later database reintroducing the same slug
inserts a fresh built-in row instead of fighting over this one. Only genuinely unused withdrawn
foods are deleted.

Writes are saved every 200 rows so a first-run import never holds the whole change set in memory,
and progress is reported at most every 25 records so a fast import does not flood the main actor
with updates nobody can perceive. `now` is a parameter rather than a call to `Date()`, so the same
input produces the same `updatedAt`.

`resetBuiltInFoods()` deletes every built-in row and forgets the version, backing the settings
screen's rebuild action — which exists because a store that has gone strange is otherwise
unrecoverable without deleting the app.

### Barcode scanning

`BarcodeScannerService` wraps an `AVCaptureSession` with an `AVCaptureMetadataOutput`. It imports
`AVFoundation` and `Foundation` and nothing else — the view layer wraps its `previewLayer` in its
own representable, which is what lets the scanner be exercised without a view hierarchy.

- **Symbologies:** EAN-8, EAN-13, UPC-E and Code 128. UPC-A is absent on purpose — AVFoundation
  reports it as an EAN-13 with a leading zero, which is also how Open Food Facts stores it.
- **Permission** is a five-state answer, not a boolean: `ready`, `notDetermined`, `denied`,
  `restricted`, `noCamera`. The UI needs the distinction — the first warrants a prompt, the second
  a link to Settings, the last a quiet fall-back to typing the number.
- **The simulator has no camera.** `availability` reports `.noCamera` and `start()` throws
  `BarcodeScannerError.unavailable(.noCamera)` rather than trapping inside AVFoundation.
- **Threading.** `startRunning()` blocks for a noticeable fraction of a second, so configuration
  and start/stop are serialised onto a private queue that `start()` simply awaits. Metadata
  callbacks land on a second queue. Shared state is guarded by a lock and the type is
  `@unchecked Sendable`; an actor would force every camera callback through a suspension point.
- **Debouncing.** The metadata output fires several times a second while a packet sits in frame.
  The same value is suppressed for **2 s** — long enough that a held packet does not refire,
  short enough that deliberately rescanning to add a second portion is not a wait — and any
  emission at all is suppressed for **0.3 s**, so a shelf of packets cannot produce a burst. One
  code is emitted per callback.
- **Validation.** Only plausible GTINs are published: digits only, length 8, 12, 13 or 14. Code
  128 carries arbitrary text, so it is accepted only when it is in fact all digits of a GTIN
  length. A malformed read would otherwise become a wasted network round trip.
- Codes arrive on a single-consumer `AsyncStream` that survives stop/start cycles; `invalidate()`
  closes it. `setScanRegion(_:)` narrows detection to a band of the preview, which both speeds
  detection up and stops the scanner reading a neighbouring packet from the edge of the frame.

---

## Persistence boundaries

### Repository layer

The repositories are the only place in Forge where SwiftData and the pure engines meet. Engines take
value types in and return value types out; models are `@Model` classes owned by a `ModelContext`.
Everything below is the translation between the two, plus the handful of rules that translation has
to enforce.

Every repository is a `@MainActor struct` holding a `ModelContext` and conforming to a small
`Repository` protocol that supplies `persist()`, `fetch(_:)`, `fetchFirst(_:)`, `count(_:)` and
`deleteAll(_:)`. SwiftData's API is synchronous, so the repositories are too — wrapping synchronous
calls in `async` would buy a suspension point and nothing else. `persist()` never swallows a failure:
a `save()` error becomes `RepositoryError.saveFailed` and is thrown to the caller, because a lost save
in a fitness app is a lost set, a lost meal or a lost body-mass reading.

#### Validation bounds

`InputValidation` is the single place that decides which numbers the app accepts. Two rules drive it.

**Reject the impossible, permit the unusual.** A 47 kg lifter and a 190 kg lifter are both real; 0.5 kg
and 4,000 kg are typing mistakes.

**Clamp what is out of shape, throw what is meaningless.** Forty sets is over-ambitious intent the app
can partially honour, so it clamps. A height of 1,750 cm carries no intent, so it is refused.

| Quantity | Range | Behaviour | Why this bound |
|---|---|---|---|
| Height | 50–260 cm | throw | 260 cm exceeds the tallest recorded adult |
| Body mass | 20–400 kg | throw | feeds every energy calculation; a silent clamp would be quietly wrong for weeks |
| Age | 10–120 years | throw | outside this the value cannot be a birth date |
| Daily energy target | 500–10,000 kcal | throw | below 500 is not a diet the app will help construct |
| Load per set | 0–1,000 kg | clamp below, throw above | a stray minus sign is a slip; 5,000 kg is not a lift |
| Sets per exercise | 1–20 | clamp | 20 is already far past any evidence-backed dose |
| Reps | 0–500 | clamp | 0 records a failed attempt; 500 covers high-rep bodyweight work |
| Macro grams | 0–2,000 g | clamp | usually derived from a portion the user already confirmed |
| Days per week | 1–7 | clamp | |
| Session length | 10–300 min | clamp | 10 min is the shortest worth programming |
| Rest | 0–900 s | clamp | |
| RIR / RPE | 0–10 / 1–10 | clamp | |
| Set duration | 0–14,400 s | clamp | |
| Distance | 0–200,000 m | clamp | |
| Portion quantity | 0.01–10,000 | throw | a zero-gram entry is a mistake, not a log |
| Recipe servings | 0.25–100 | throw | |
| Water, one entry | 1–5,000 ml | clamp | |
| Water, daily target | 0–10,000 ml | clamp | a target of zero is a user turning the ring off |
| Load increment | 0.25–50 kg | throw | zero makes progression impossible; 0.25 kg is the smallest micro-plate anybody stocks |
| Serving or piece weight | 0.1–10,000 g | throw | a zero-gram serving makes every portion using it compute to nothing |
| Energy density (custom food) | 0–1,000 kcal/100 g | throw | pure fat is 900; anything higher is a typo |
| Macro density (custom food) | 0–100 g/100 g | clamp | a food cannot be more than entirely one macronutrient |
| Names | 1–120 characters | throw | |
| Notes | ≤2,000 characters | truncate | the user has already typed them; losing the lot is worse |

Messages are factual and state the accepted range. They never comment on the value the user typed, and
the numbers in a message are formatted from the same constant the check uses — a message that quotes a
bound the code does not actually apply is worse than no message.

#### ProfileRepository

Three singleton rows — `UserProfile`, `UserSettings`, `EquipmentProfile` — created lazily on first
access rather than seeded at launch, which makes creation idempotent and survives a crash before
onboarding finishes. If a store somehow holds two rows of a singleton (an interrupted merge, a
restored backup) exactly one is kept and the extras are deleted, so the app never starts writing to a
second, invisible profile. The profile keeps the *oldest* row, because its creation date is the user's
join date; settings and equipment carry no creation date, so they keep the most recently *updated*
row, which is the one holding the user's current intent. Both choices are made by an explicit sort —
an unordered fetch would keep an arbitrary row, and could keep a different one on the next launch.

`EquipmentProfile` is seeded from `preset.equipment` on creation, because its declared default of an
empty array would otherwise mean "this user owns nothing" to every engine.

**`TrainingProfileSnapshot` mapping.** Age is computed from `birthDate` against an injected `now`, so
the same store state always produces the same snapshot. Priority groups come from
`UserProfile.resolvedPriorityGroups`, which merges explicit groups with the groups implied by any
chosen `TrainingFocusRegion` — the engines only ever see groups. Empty goals fall back to
`.generalFitness` and empty weekdays fall back to the snapshot's own Mon/Wed/Fri default, so a
pre-onboarding preview is still sensible.

**`effectiveEquipment`.** `EquipmentProfile.effectiveEquipment` subtracts anything flagged temporarily
out of service. The repository adds one rule on top: the result is never empty. An empty set would
make the exercise selector return nothing at all, which reads as a broken app rather than as an empty
gym, so it falls back to the preset minus the unavailable items, and finally to
`Equipment.homeMinimum` (bodyweight), which is always true of a human being.

**`NutritionProfileSnapshot` mapping.** `trainingDaysPerWeek` comes from stated availability rather
than from what the user actually did, because the energy target has to be set in advance of the week
it covers. Tag lists are normalised (trimmed, lower-cased, de-duplicated) on the way in *and* on the
way out, so a store written by an earlier build cannot make `"Gluten"` and `"gluten "` behave as two
different allergens.

`resetAllData()` deletes from the most dependent model to the least and commits once: a reset that
half-succeeded would be worse than one that failed outright.

#### ProgramRepository

Two invariants live here and nowhere else.

**Exactly one program is active.** Activating one deactivates the rest in the same save. Reads are
defensive: if more than one row is active, the newest wins and the others are stood down.

**The engine may rewrite a program, but never erase what came before.** Every engine-driven change
bumps `TrainingProgram.currentVersion` and appends a `ProgramVersion` holding a complete JSON copy of
the templates.

`apply(_:to:reason:)` always appends the incoming shape with the caller's explanation, and appends a
second row for the *outgoing* shape (`program.version.superseded`) only when the program has actually
drifted from the newest version already stored. After an engine-driven change it has not — the newest
row already holds exactly that shape — and writing it again would put a byte-identical duplicate,
under a version number that already exists, into the history on every regeneration. After hand editing
it has: adding a template or changing a prescription does not bump the version, so that row is the
only record of what the user built, and it is kept. `versions(of:)` therefore sorts by version number,
then creation date, then id, so a number carrying two rows still reads in the same order every time.

The snapshot is JSON rather than a second family of `@Model` rows because a version is never queried,
only read back whole. `JSONEncoder.outputFormatting = [.sortedKeys]` and a date-free payload make two
encodings of the same state byte-identical — that is what makes "has anything changed?" a data
comparison rather than a guess, and it is what the rule above is built on. Snapshot encoding failure
returns `nil` rather than throwing: losing the readable copy of a version is regrettable, but refusing
to save the user's new program because its history blob would not encode is worse.

**Substitution keeps the original.** Swapping A → B → C still records "instead of A", because A is
what the plan asked for. Swapping back to A clears the marker instead of claiming a substitution. The
prescription (sets, reps, rest, RIR) is preserved across a swap: a substitution changes the movement,
not the dose.

Order indices are renumbered to 0…n−1 after every structural change. Gaps sort fine but make
"insert after this one" arithmetic fragile.

`generatedProgram(from:catalog:)` recomputes `weeklyVolume` from the catalogue rather than storing it,
because the metadata that defines a set's volume credit ships with the app and can change with a
dataset update; a stored figure would go stale silently.

#### WorkoutRepository

**A session is a snapshot, not a view of the plan.** `startSession(from:catalog:)` copies the title,
the exercise ids, the exercise *names*, the tracking mode and the set targets out of the template.
Editing the template afterwards — or a dataset update renaming an exercise, or the programming engine
swapping a movement out — can then never rewrite what the user actually did last Tuesday.

Set targets store the **top** of the rep range as `targetReps`. Under double progression the
instruction is "reach the top of the range, then the load goes up", so that is the number the user
should be chasing on every set.

**Everything commits immediately.** A workout is logged over forty minutes on a phone that may ring,
lock, run out of battery or be force-quit. Every mutating method saves before it returns, so the worst
case is losing the set currently being typed.

Cached figures on the session row:

- `totalVolumeKg` — sum of `weight × reps` over completed working sets, but only for tracking modes
  where `TrackingMode.contributesToTonnage` is true. An assisted pull-up records the *assistance*, so
  counting it as tonnage would reward the user for making the movement easier.
- `plannedSetCount` — every working-kind set row in the session, skipped exercises included. A set the
  user planned and did not do is still a set they planned; excluding it would make completion rate
  meaningless.
- `completedSetCount` — the completed subset of those.
- `activeSeconds` — accumulated by the workout timer and passed in, not derived from the wall clock,
  so time in the background does not inflate the session. Falls back to wall clock only when nothing
  reported a timer, because a session recorded as taking no time is obviously wrong.

**Batched history is one fetch.** `histories(forExerciseIDs:sessionLimit:)` issues a single
`FetchDescriptor<ExerciseSession>` with an `ids.contains(exerciseID)` predicate, then groups, orders
and truncates in memory. `ExerciseSession` carries no store index on `exerciseID`, so this is a scan —
which is exactly why it is one scan for the whole id set rather than one per exercise. The programming
engine asks for dozens of exercises before it builds a week, so N queries here would be N × the cost of
generating a program. The full result set feeds the all-time figures (`totalSessions`, best estimated
one-rep max) while only the newest `sessionLimit` performances are handed to the engine, which never
looks further back than a handful of sessions.

**One performance per session.** An exercise can hold two slots in one workout — a second block, or a
back-off after a heavy top set — and those rows are merged into a single `ExercisePerformance` rather
than reported as two. Counting them separately would inflate `totalSessions` and hand the progression
engine two same-day performances where it expects one per session, quietly shortening the window it
reasons over. `sessions(forExerciseID:)` de-duplicates for the same reason. Both orderings break ties
on the session id so repeated reads return the same order.

Estimated one-rep max delegates to `OneRepMaxCalculator`, which owns the formulas and the reliability
bounds. The repository does not reimplement the arithmetic: there must be exactly one answer in the
app to "what is this lifter's estimated max", or the progress chart and the progression engine will
drift apart.

`sessionOutcome(for:catalog:)` needs the catalogue because per-group set attribution lives in the
exercise metadata — one set of chin-ups is a full set of back plus a fractional set of biceps. Skipped
exercises contribute nothing to group totals but still count as planned. `averageRIR` is the mean of
`PerformedSet.effectiveRIR` over completed working sets that recorded one (RIR directly, or derived
from RPE as `10 − RPE`).

#### ExercisePreferenceRepository

Rows are created lazily on the first opinion the user expresses. The catalogue holds over a thousand
exercises; pre-seeding a row each would turn "no opinion" into 1,300 rows of nothing. An absent row
means exactly "no opinion", which is what `ExercisePreferenceSnapshot`'s defaults already encode.

`.neverRecommend` and exclusion are deliberately different things: the former zeroes the selection
score but leaves the exercise pickable by hand, the latter is a hard filter. That lets someone say
"stop suggesting this" without losing the ability to do it when they feel like it.

`recordPerformed(exerciseIDs:at:)` is called once per finished session, not per set, so
`timesPerformed` counts *sessions containing the exercise* — the unit both the variety penalty and
the "you have done this 14 times" copy mean. Duplicate ids in the argument count once. The
`lastPerformedAt` marker never moves backwards, so importing an old session cannot make a recent
exercise look stale.

#### ProgressRepository

**Same-day de-duplication.** People weigh themselves twice when the first number surprises them. Two
readings on one day double that day's weight in any average that is not day-aware, which drags the
trend line and, through it, the automatic calorie adjustment. `deduplicateSameDayManualEntries` keeps
the *latest* manual reading per day — the one the user was looking at when they stopped — and deletes
the rest. HealthKit rows are never touched: several readings in a day are legitimate data owned by
another app, and editing them would only be fighting the next sync.

`weightTrendPoints` passes readings through one per row rather than pre-averaging per day.
`WeightTrendAnalyzer` owns the smoothing; doing half of it here would make its window arithmetic
depend on how the repository happened to bucket the input. Either bound may be omitted independently —
"everything since January" and "everything up to the deload" are both things a chart asks for — and a
missing bound becomes an open end rather than quietly widening the query to all time.

**Personal records.** `recordPersonalRecord` looks up the previous best and writes it into
`previousValue`, which is what lets the UI say "+2.5 kg" rather than just "new record". A value that
does not beat the stored best returns `nil` instead of inserting: a "record" that is not a record
would corrupt every delta after it.

**Check-ins are one row per day.** A check-in is a statement about how the day feels; a second row
would give the recovery engine two contradictory answers to weigh. Every field is separately optional,
so a user who only wants to answer "how did you sleep?" can.

**Weekly buckets are Monday-first**, regardless of locale, to match `Weekday.orderedMondayFirst` and
the way training weeks are conventionally laid out. Letting the locale decide would mean a user in the
United States and a user in Germany saw identical training histories bucketed differently. Empty weeks
are emitted as zero rows rather than omitted, because a missing week is exactly the thing the user
needs to see.

**Adherence.** Session adherence is measured against `expectedSessionsPerWeek × weeks in range` when a
program supplies one, and against sessions actually started when it does not — which answers "did I
finish what I began?" rather than "did I follow the plan?". Both rates are capped at 1: reporting
140 % adherence reads as a bug rather than as enthusiasm.

**Streaks carry a one-period grace.** The current week counts even if the user has not trained *yet*
this week, because it may only be Monday; the current day streak likewise survives the hours before
today's session. Without the grace every streak in the app would reset at midnight on Sunday and read
as a bug. Both walkers are bounded (520 weeks / 1,000 periods) so a corrupt date can never spin.

The weekly streak is the headline figure. A daily streak is a poor fit for strength training — rest
days are part of the programme — but it is computed because it is the right unit for a "three days in
a row" achievement.

#### NutritionRepository

**A log entry is history, not a pointer.** Every entry stores the food's name and its complete macro
and micronutrient contribution at the moment it was logged. Editing a food's nutrition tomorrow, or
deleting it outright, therefore cannot rewrite what the user ate last month. The cost is a little
duplicated data per row; the alternative is a diary whose past silently changes.

**Safe deletion.** Deleting a food clears `foodID` on referencing log entries — their snapshots are
already complete, so all they lose is the ability to jump to the food's detail screen. Saved meals and
recipes are different: they store only a reference and a quantity, so they cannot compute their own
nutrition without the food. Those are reported back as `RepositoryError.stillReferenced` with a count,
and are only detached on an explicit second confirmation (`force: true`).

**Portion edits.** When the underlying food still exists the snapshot is recomputed from it, which is
exact. When it has been deleted the existing snapshot is rescaled by the ratio of the two amounts —
correct while the unit is unchanged, and refused when it is not, because nothing left knows how many
grams are in "one piece".

**Copying is verbatim.** `copyDay` and `copyYesterdayMeal` duplicate the stored snapshots rather than
recomputing from the food, which keeps the copy honest if the food has been edited since and makes the
operation independent of whether the food still exists.

**Saved meals skip missing foods rather than logging zeroes.** A silent zero would understate the
day's intake, which is the one failure mode a food diary must not have. The skipped count is logged.

**Recipes are logged as one line.** The user ate "chilli"; a diary that expands it into eleven rows of
tinned tomatoes is unreadable. Per-serving nutrition is computed from the ingredients on every read
rather than stored, so correcting an ingredient immediately corrects every serving figure — recipes
are a dozen ingredients at most, so this is one dictionary lookup each.

**Custom food energy.** Values are entered per 100 g (or 100 ml), the basis the whole app stores and
the basis every packaged food in the EU is already labelled in. When the user leaves energy blank it
is derived from the macros at 4/4/9 kcal per gram, because that is a far better answer than "this food
has no calories".

**Target changes are journalled.** `replaceActiveTarget` writes a `NutritionTargetHistory` row holding
both the old and the new numbers plus the reason, and deactivates rather than deletes the previous
target. "Why did my calories move?" is the most common question a calorie app has to answer, and
answering it from a diff of two rows that may both have been edited since is not an answer.
Micronutrient goals are carried forward unless explicitly replaced: they are a separate decision from
the energy target and should not be reset by a calorie adjustment.

Days are addressed by `DayKey` (`yyyy-MM-dd` in the user's calendar), so a day's log is one indexed
equality fetch and a flight across time zones does not move yesterday's dinner into today.

**Recommender candidates.** `mealCandidateFoods` orders by how often the user logs each food, because
the recommender's job is to suggest meals somebody will actually eat and the strongest available
signal for that is what they already eat; the limit (400 by default) keeps the scoring pass bounded on
a large database. `defaultServingGrams` prefers a named serving, then a natural piece, then `nil` —
which leaves the portion solver free. `savedMealCandidates` and `recipeCandidates` each resolve their
foods in a single batched fetch, so they stay two queries regardless of how many meals or recipes
exist.
