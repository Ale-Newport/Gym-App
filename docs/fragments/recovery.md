# Recovery, deload detection and autoregulation

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

## 1. Recovery

### Fatigue per muscle group

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

### Proximity to failure

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

### Subjective check-ins

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

### Other snapshot fields

* `daysSinceStimulus` — whole elapsed days (`floor(hours / 24)`, not calendar days, so it is
  reproducible across time zones) since the group last received ≥0.5 set credits. `nil` = never.
* `weeklySets` — fractional set credits over the trailing 168 h.
* `recentSessionCount` — sessions in the trailing 168 h with at least one completed set.
* `readyGroups(_:threshold: 0.35)` — the point at which roughly two thirds of a hard session has
  dissipated. Sorted ascending by fatigue; cardio and neck are excluded (programmed separately).
* `readinessSummary` — four wide bands (0.85 / 0.65 / 0.45), each with a group-level and a
  systemic-level wording. Bands are wide because a summary that flips on a 0.01 change reads as
  noise.

---

## 2. Deload detection

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

## 3. Autoregulation

`magnitude` semantics, which the contract type does not spell out: fraction of load for
`reduceLoad`/`increaseLoad`, number of sets for `addSet`/`removeSet`, seconds for `restLonger`,
minutes for `shortenSession`, and 0 for `swapExercise`/`noChange`.

| Proposal | Condition | Size |
|---|---|---|
| `reduceLoad` | ≥50 % of an exercise's ≥2 rated sets badly missed (≥2 reps short, or below 75 % of target), on a movement that carries external load | −5 %, or −10 % past a 75 % miss share |
| `restLonger` | reps fell to <65 % of the first set, or ≥4 reps down, across ≥3 sets at a load that did not drop, on an exercise that did **not** just earn a load cut | +30 s |
| `removeSet` | group fatigue ≥0.75 and the week stays at or above `VolumeTargets.minimum` | −1 set, one group |
| `addSet` | session easy — rated `.easy`, or ≥1.5 RIR above target, and never one the user called hard or exhausting — **and** `weeklySets + 1 ≤ min(target, maximum)` **and** group fatigue ≤0.45 | +1 set, ≤2 groups |
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

### `apply(_:to:catalog:)`

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

### Determinism

`AutoregulationAdjustment.id` defaults to a fresh `UUID()`, which would make identical inputs
produce non-equal outputs. Ids are therefore derived from the adjustment's own content with FNV-1a
(run twice from different offset bases to fill sixteen bytes, then stamped with the RFC 4122 version
and variant bits). Swift's `Hasher` is deliberately not used: its seed is randomised per process.
Every dictionary iteration that reaches an output is sorted, and every sort has an explicit
tie-break.

### Localisation

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
