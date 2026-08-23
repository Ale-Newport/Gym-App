# Nutrition

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

## 1. Energy targets

### Resting energy — Mifflin-St Jeor

```
male:        10·kg + 6.25·cm − 5·age + 5
female:      10·kg + 6.25·cm − 5·age − 161
unspecified: 10·kg + 6.25·cm − 5·age − 78      // (5 + −161) / 2
```

`.unspecified` averages the two sex constants rather than guessing a sex, and says so in its
explanation. A missing age defaults to **30** (mid-adult range, worth at most ~±100 kcal across a
20–60 year old) and the explanation names the assumption. Inputs are clamped (30–300 kg,
120–230 cm, 14–100 years) so a half-finished profile cannot produce nonsense.

### Maintenance

```
TDEE = BMR × ActivityLevel.multiplier × (1 + 0.012 × max(0, trainingDays − 3))
```

The activity multipliers are the conventional Harris–Benedict/Mifflin factors, and this app's
onboarding copy describes them in terms of *daily* movement ("desk work, little walking"), so
lifting sessions are only partly captured. A 60-minute session costs roughly 250–350 kcal; since
part of that already sits inside the multiplier, only **1.2 % of maintenance per session beyond the
third** is credited, capping at +4.8 %.

### Offset from maintenance

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

### Safety clamps

* Daily offset capped at **−1000 / +700 kcal** before anything else.
* Floor = `max(BMR × 1.1, absoluteFloor)`, with `absoluteFloor` = 1200 kcal (female) or 1500 kcal
  (male). `.unspecified` takes the **higher** floor: a floor set too high only slows progress, one
  set too low risks under-eating, so the asymmetry runs towards caution.
* Ceiling on later increases: maintenance + 750 kcal.
* `weeklyBodyMassChangeKg` is recomputed **after** clamping, so it always describes the number the
  user was actually given.
* **When the floor lands above maintenance**, the explanation and the macro split both follow the
  balance the user actually gets rather than the one they asked for. A small, older, sedentary
  person can have an estimated maintenance below the 1,200/1,500 kcal absolute floor, so their
  target is above maintenance however hard they asked to cut; the app says exactly that ("the
  lowest intake this app will recommend for you is already above your estimated maintenance —
  moving more is the better lever") instead of claiming a deficit that does not exist, and the
  macros drop the deficit protein bump. `EnergyTargets.direction` still records the *intent*, which
  is what the rest of the app reasons about.
* The final explanation on every target set states plainly that these are estimates, not medical
  advice.

## 2. Macronutrients

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

## 3. Weight trend

Daily body mass swings by roughly ±1 kg on water, glycogen, sodium and gut content — more than a
week of real fat loss at any sane rate. Nothing downstream is allowed to see raw readings.

* Readings are bucketed per calendar day and **averaged** within the day (weighing before and after
  breakfast must not inject a step), implausible masses (outside 20–400 kg) and future dates are
  dropped. The `Calendar` doing the bucketing is a parameter rather than ambient state, since which
  readings land on which day depends on the time zone.
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

## 4. Calorie adjustment

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

## 5. Meal recommendation

A suggestion has to be something a person can put on a plate, which rules out both picking foods at
random and offering fixed servings that never land on the macros actually left. So the engine builds
**patterns** and then **solves for portion sizes**.

### Target for the meal

`min(dailyTarget × slotShare, cap)` where `slotShare` is `MealSlot.defaultEnergyShare` renormalised
over the slots the user actually eats (three-meal users have the snack share redistributed), and
`cap` is 900 kcal for a main meal, 350 kcal for a snack. When the remainder is already smaller, it
is taken whole — this is the last meal of the day. Macros already overshot target zero rather than
negative. Below 80 kcal remaining, nothing is suggested.

### Hard exclusions

`dietType.excludedTags ∪ allergenTags ∪ intoleranceTags ∪ excludedFoodTags`, matched against the
union of a food's dietary, allergen and role tags. A hard exclusion is **never** softened into a
penalty, is applied in exactly one place, and also removes saved meals containing an excluded food
and recipes carrying an excluded tag.

### Roles and patterns

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

### Portion solver

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

### Scoring

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

### Output

De-duplicated by food set (same foods = same suggestion, however differently portioned), then picked
greedily with a **0.05 demotion per food already used by a picked suggestion** so the list is not
four variations on chicken and rice, then returned sorted by score, at most `request.limit`.

Every suggestion carries reasons naming the macros it fills, capped at four. Ids are FNV-1a hashes
of the suggestion's contents rather than fresh UUIDs, so identical requests produce identical
output and SwiftUI does not re-animate an unchanged list.

### Determinism

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
