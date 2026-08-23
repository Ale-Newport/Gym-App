## Repository layer

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

### Validation bounds

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

### ProfileRepository

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

### ProgramRepository

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

### WorkoutRepository

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

### ExercisePreferenceRepository

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

### ProgressRepository

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

### NutritionRepository

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
