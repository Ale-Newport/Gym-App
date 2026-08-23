# Exercise selection, recommendation and substitution

Owned by `GymApp/Domain/Training/ExerciseScoring.swift`,
`ExerciseRecommendationEngine.swift` and `ExerciseSubstitutionEngine.swift`.
All three are pure value-type engines: no clock, no randomness, no persistence,
no SwiftUI. Identical inputs always produce an identical, identically-ordered
result, which is what makes generated programs reproducible and every rule below
unit-testable.

## 1. Eligibility gates

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

## 2. Scoring

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
| `equipmentAvailability` | 0.10 | Constant 1.0 — availability is gate 4, and the weight keeps `total` on the documented scale |
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

### Goal formulas

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

### Movement diversity

| | Pattern unused | Pattern already used this session |
|---|---|---|
| Matches `preferredPattern` | 1.00 | 0.60 |
| No preferred pattern | 0.75 | 0.20 |
| Mismatches `preferredPattern` | 0.50 | 0.10 |

`+0.12` (clamped) when the pattern's antagonist is already in the session, which
is how push/pull ratios stay sane across a mesocycle.

### Strength proxy

Best Epley estimate in the session, `w · (1 + reps/30)`, with reps capped at 20 —
every one-rep-max formula becomes fiction well before that, and an uncapped
estimate would let a light high-rep day read as a personal record. Unloadable
movements fall back to total working reps, then to held seconds.

Each proxy carries the unit it is expressed in, and a trend is only computed when
both endpoints use the **same** unit; otherwise the factor stays at the neutral
0.5. A session logged without load sitting next to one logged with it would
otherwise divide kilograms by repetitions and read as a collapse or a
breakthrough that never happened.

### Difficulty ceiling and the safety rail

The ceiling is `ExperienceLevel.maximumDifficulty`, shifted by
`TechniqueConfidence`: `coached` +1, `unfamiliar` −1, otherwise 0. A coached
beginner is therefore offered barbell work that a self-taught beginner is not.

`experienceSuitability` alone carries 7 % of the scale, which is not enough to
keep a novice away from a movement that scores well everywhere else, so
overshoot is *also* charged to `exclusionPenalty` and subtracted outside the
weights: two grades above the ceiling costs roughly a quarter of the whole
score. It is deliberately a demotion rather than a ban — a movement one grade
too hard is often exactly what the user should be working towards.

### Low-fatigue re-weighting

When `favorLowFatigue` is set, 12 % of the non-fatigue additive weight mass (at
most 0.08) is moved into `fatigueEfficiency` and the remaining additive weights
are scaled by `(rest − boost)/rest`. `additiveSum` is preserved *exactly*, so
scores from a nearly-full session stay comparable with scores from a fresh one.
With default weights, `fatigueEfficiency` goes 0.05 → 0.13.

## 3. Recommendation

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
`1 − (0.22·patterns + 0.14·equipment + 0.10·targets)`, floored at 0.25. Two
rules keep variety honest:

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

## 4. Substitution

### Similarity

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
`barbell bench press` ↔ `dumbbell bench press` 0.94, ↔ `lever chest press` 0.86,
↔ `barbell full squat` 0.22.

### Candidate score

`0.72·similarity + 0.18·preference + 0.10·familiarity`, then multiplied by the
reason modifier. Familiarity is
`0.35·min(1, sessions/6) + 0.65·historicalPerformance` — mid-session a known
setup and a known working load have real value, but a familiar movement the user
has stalled on should not outrank a fresh one on habit alone.

### Reason handling

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

### Explanations

One to three per candidate, deduplicated, in a fixed order: the relationship to
the replaced movement (`Same target muscle and pull pattern`), then the answer
to the reason given (`Easier to stabilise`), then one concrete extra (favourite,
equipment, progress, staple). Every candidate carries at least the relationship.

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

### Performance

Measured on the shipping 1,324-record catalogue, release build, Apple silicon:

| Call | Cost |
|---|---|
| Index build (`init`) | ~2 ms, once per app launch |
| `alternatives` | 0.15 – 0.85 ms |
| `rank` | ~0.8 ms |
| `best(count: 6)` | ~4.7 ms (six full re-scoring rounds, as the greedy contract requires) |

The substitution path stays cheap because it touches only the primary-group
bucket (a few hundred records, topped up from the wider index only when fewer
than five survive), gates with `Set` lookups before scoring, and allocates
nothing for a rejected candidate. Ordering is settled by a single sort of the
survivors, never of the catalogue.

If a reason filters everything out — "bodyweight only" where the muscle has no
bodyweight option — the filter is dropped and the reason survives as a ranking
preference. An empty sheet mid-workout is the worst possible answer.
