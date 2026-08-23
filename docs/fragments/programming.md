# Split selection, weekly volume and program generation

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

## 1. The unit: volume credits, not sets

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

## 2. The weekly time budget

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

## 3. The volume envelope and its modifiers

### Base envelope, per *major* muscle group, in weekly credits

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

### `groupScale` — how much of a major group's envelope each group gets

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

### `indirectShare` — the fraction of a group's credit that arrives as synergist work

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

### Modifiers, in the order they are applied

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

### `fit` — walking the targets down into the calendar

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

### Frequency

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

## 4. Choosing the split

`SplitSelector` never looks a split up by day count. Every well-known structure is *generated* as a
candidate at every day count and scored, so "1 day → full body" and "6 days → push/pull/legs" are
predictions of the scoring rather than table entries, and can be unit-tested as such.

### Candidate generation

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

### Archetype composition

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

### Weekday assignment

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

### The seven scoring terms

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

## 5. From a split to blueprints

### Day credits

Each day's credit for a group is `target / exposures`, damped to **75 %** if the same group was
already trained on a calendar day exactly one apart. Back-to-back exposure is not forbidden — some
structures need it — but the second day runs on a muscle that has had roughly a day, not the two to
three its `baselineRecoveryHours` asks for.

### Concentration

A group whose *per-day* direct requirement rounds below two sets but whose *weekly* requirement does
not is pulled onto a single day. Spreading two weekly sets of shrugs across three exposures produces
nothing at all: each day rounds to zero and the group silently vanishes from the program.

The receiving day is the lightest of the days that already cover the group, so the extra movement
lands where there is time for it — and "lightest" is **re-measured after each decision**. Scoring
every group against the original day loads makes them all pick whichever day started lightest; on a
three-day full-body week, where all three days start identical, that is day one every time, and the
user gets one overloaded session and two nearly empty ones.

### Slot vocabulary

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

### `makeSlots` — credits to concrete slots

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

### Ordering inside a session

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

### Titles

`session.title.<archetype>` plus a lettered variant when the archetype repeats: `Upper Body A`,
`Upper Body B`, and so on. The variant count per archetype has to be at least one below the most
times that archetype can occur in a single structure, because occurrences past the last variant all
fall back to the unlettered base key — and two blueprints sharing a title key are two sessions the
user cannot tell apart, and that `regenerateSession` cannot tell apart either. `expandBiased` can
append up to `cycle.count − 1` extra days, so a four-entry cycle can run its favoured archetype four
times: `posteriorChain` therefore carries four variants, not two.

### Conditioning placement

The number of weekly conditioning blocks comes from the goal alone, blended and clamped to
`daysPerWeek`: 3 for fat loss and endurance, 2 for general fitness and recomposition, 1 for
maintenance and muscle, 0 for strength. `CardioPreference.none` always means none — cardio the user
did not ask for is cardio they will skip.

Blocks land on any active-recovery day first, then on the shortest lifting days.
`.separateSessions` cannot be honoured literally inside a weekly lifting plan, so it degrades to the
lightest days available — the closest thing to a standalone session the schedule allows — and the
explanation says which of the two happened.

---

## 6. Filling the blueprint

### The slot ladder

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

### Prescription

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

## 7. Making it fit the clock

### The session cost model

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

### Trimming

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

### Extending

When a session finishes more than five minutes early, sets are added to whichever exercise offers the
most `stimulusScore` per unit of time, with a small penalty per set already assigned. The total is
capped at `plannedSets × 1.30`: two hours of availability is not an instruction to train for two
hours, and a generous cap must not quietly inflate the week past its recovery ceiling.

**Active-recovery days are never extended.** Topping a light day up to fill a two-hour cap turns the
one day that exists to dissipate fatigue into another hard one.

---

## 8. Determinism, locking and regeneration

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

## 9. A worked example

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

## 10. Known limits

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

**Performance**, on the shipping 1,324-record catalogue, `-O` build, Apple silicon:

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
