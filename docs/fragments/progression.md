# Progression, 1RM estimation, records and first-load estimation

Files: `GymApp/Domain/Training/OneRepMaxCalculator.swift`, `ProgressionEngine.swift`,
`PersonalRecordDetector.swift`, `LoadEstimator.swift`.
Localisation keys: `Tools/l10n/keys/progression.en.json`.

All four are pure value-in/value-out enums. No clock, no randomness, no persistence, no SwiftUI and
no SwiftData: the same inputs always produce the same outputs, which is what makes the whole set
testable without a database.

---

## 1. One-repetition maximum

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

## 2. Progression engine

### Order of decisions

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

### Judging a session

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

### Double progression (default)

| Last session | Action |
|---|---|
| every set at the top of the range, RIR target met, on the **2nd** consecutive such session | `increaseLoad` |
| same but only the 1st such session | `addReps` (banked; `consecutiveSuccesses += 1`) |
| reps inside the range | `addReps` |
| reps inside the range with no improvement, 4th time | `reduceLoad` −10 % |
| short of the bottom, 1st time | `maintain` (`consecutiveRegressions += 1`) |
| short of the bottom, 2nd time | `reduceLoad` −10 % |

Two consecutive qualifying sessions, not one: a single good session is a good day, and the cost of
being wrong is a failed rep. On an increase the rep target resets to the bottom of the range — the
new load is meant to be hard at the bottom, and climbing back to the top is what earns the next one.

**Counters.** `increaseLoad`/`reduceLoad` → all three reset to 0. Banked success → `successes += 1`,
others 0. Inside range with improvement → all 0; without improvement → `stalls += 1`. Missed bottom →
`regressions += 1`. `maintain` for "no data" or "lighter than planned" leaves them untouched.

### Step size and the caps

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

### Other strategies

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

### Movements with no external load

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
successful session, up to **180 s for isometric holds** — past three minutes a hold trains endurance,
not strength — and **1800 s for timed cardio and loaded carries**. At the ceiling: add load if the
movement is loadable (a carry), else add an interval for cardio, else say it is outgrown. Holds never
add a set at the ceiling: a fourth three-minute plank is a longer session, not a harder plank.

### Weighted and assisted movements

`state.workingWeightKg` is the number the user selects — added load for a weighted dip, assistance for
an assisted pull-up — never total system mass. Zero is a real prescription in both cases (bodyweight
only; fully unassisted), so the "usable working weight" check accepts it for these two loadabilities
and rejects it everywhere else. Assisted movements invert the direction of `harderLoad`, `easierLoad`,
`applyCalibration` and the deload, and are excluded from load, e1RM and tonnage records.

### Deload

`ProgressionInput` carries only `isDeloadWeek`, so `decide` applies the conventional deload:
**−10 % load, −40 % sets**. A caller holding a richer `DeloadAssessment` calls
`deloadPrescription(from:assessment:loadability:increments:currentSets:)` directly. Zero reductions
in the assessment are read as "unspecified" and replaced with those defaults; both are then clamped
at **35 % intensity / 60 % volume** — a deload is a lighter week, not a different sport — and the set
count never falls below 1. Target RIR rises by 2 (capped at 5): staying far from failure is the point.
A deload that rounds back onto the working load is stepped one increment further.

Crucially the **counters and the remembered working load are untouched**: a deload is a planned
lighter week, not evidence about the user, and next week resumes where the progression left off.

### Calibration feedback

`applyCalibration` multiplies the attempted load by `CalibrationFeedback.loadMultiplier`
(1.15 / 1.00 / 0.95 / 0.85), inverting it for assisted movements, and rounds. If the result rounds
straight back onto the load the user just rejected — routine on a coarse ladder — it is forced at
least one selectable step in the intended direction: the user said the load was wrong, so repeating
it is not an answer.

### Reps in reserve

`safeTargetRIR` clamps the caller's target to 0…5 with a floor of **2 for `never`/`beginner`** and 1
for everyone else. Novices' technique degrades before their muscles do, and their perception of how
close to failure they are is the least reliable of any group.

---

## 3. Personal records

`detect(performance:exercise:existing:)` returns records ordered by `PersonalRecordKind.allCases`, so
the output is stable for identical inputs. Only **completed working sets** are considered.

| Kind | Eligible tracking modes | Rule |
|---|---|---|
| `heaviestWeight` | `usesWeight`, not assisted | heaviest set; ties break towards more reps, and `repsContext` records them |
| `mostReps` | `usesReps` | best rep count **among sets at or above the previously recorded heaviest weight** |
| `estimatedOneRepMax` | `usesWeight && usesReps`, not assisted | best `OneRepMaxCalculator.estimate`, which itself refuses reps above 12 |
| `bestSetVolume` | `contributesToTonnage`, not assisted | best `weight × reps` |
| `longestDuration` | `usesDuration` | longest completed set |
| `longestDistance` | `usesDistance` | furthest completed set |

**Why the rep gate.** Fifteen reps at 20 kg is not a rep record for someone who has pressed 60 kg for
eight; it is a lighter session. Gating on the *previous* best weight is the only defensible reading of
"more reps" once load is free to vary — it also stops every deload week from firing a rep PR. When no
heaviest-weight record exists yet the gate is inert, which can happen only once per exercise.

**Margins.** 0.1 kg for load, e1RM and tonnage; one whole rep; 0.5 s; 1 m. Floating-point arithmetic,
unit round-trips and a re-logged set all produce differences in the tenth decimal place, and a PR
banner for one of those is worse than no banner.

**Assisted movements** get rep records only. Assistance is stored as a positive magnitude, so a bigger
number is an *easier* set; a "heaviest weight" record there would celebrate the wrong direction.
Driving assistance down is `ProgressionEngine`'s job, not the detector's.

**`sessionVolume` is not produced here.** This function sees one exercise, so it cannot know a session
total; whoever aggregates a finished workout owns that kind.

---

## 4. First-load estimation

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

### The shared scale

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

### The ratio table

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
(8-rep fraction) `= 35.1` → `× 0.90 = 31.6` → rounded onto a 20 kg bar with 1.25 kg plates = **30 kg**.

### Warm-up ramp

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
ladder. Assisted movements ramp the other way, from 1.6 × down to 1.15 × the working assistance, and
get two sets.

---

## 5. Localisation note

`Explanation` stores a key plus **already-formatted strings** (`arguments: [String]`), so every
placeholder in `Tools/l10n/keys/progression.en.json` is `%@`. Using `%lld` for a numeric argument
would reinterpret the bridged string pointer as an integer and print garbage — verified, not assumed.

Numbers are formatted by `TrainingFormat` without `NumberFormatter`. `Locale.current` is ambient
process state, and an engine whose output changes with the device region cannot be pinned down in a
test; `String(format:)` with no locale always uses the POSIX decimal point. Loads are quoted in
canonical kilograms, because the engines run with no access to the user's unit preference.
