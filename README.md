<div align="center">

# Forge

**An adaptive training and nutrition app for iOS.**

Forge decides what you should train today, which exercises, in which order, for how many sets and
reps, at what load, with how much rest — then watches what you actually did and adjusts. It ships
with 500 exercises, each animated by its own original 3D athlete, and instructions in ten languages. Everything runs on
device: no account, no server, no model call.

</div>

---

## Contents

- [What it does](#what-it-does)
- [Screens](#screens)
- [Requirements](#requirements)
- [Getting it running](#getting-it-running)
- [Architecture](#architecture)
- [Project layout](#project-layout)
- [The exercise dataset](#the-exercise-dataset)
- [The food database](#the-food-database)
- [Algorithms](#algorithms)
- [Localisation](#localisation)
- [Testing](#testing)
- [Data and privacy](#data-and-privacy)
- [Licences](#licences)
- [How to change things](#how-to-change-things)
- [Preparing for the App Store](#preparing-for-the-app-store)

---

## What it does

**Training.** A first-run questionnaire collects who you are, what you want, when you can train and
what equipment you have. From that, `WorkoutProgrammingEngine` selects a split, allocates weekly
volume per muscle group, and fills every slot with a scored exercise from the catalogue. During a
session the animation dominates the screen while you log sets in one tap each. Afterwards,
`ProgressionEngine` decides — per exercise — whether to add load, add reps, hold, or back off, and
`AutoregulationEngine` adjusts the next session. `DeloadEngine` watches for the pattern that means
you need a lighter week and asks; it never imposes.

**Substitution.** Any exercise, at any point, can be replaced. Filters map to the reasons people
actually have: *the machine is taken*, *I only have dumbbells*, *make it easier*, *give me something
else for the same muscle*. The engine ranks alternatives by target muscle, then movement pattern,
then secondary muscles, then equipment fit, and explains why each one is a fair swap.

**Nutrition.** Mifflin-St Jeor for BMR, an activity multiplier for TDEE, and a conservative deficit
or surplus for your goal. Macros follow. A seven-day weight trend, read with linear regression over
two to three weeks, drives proposed calorie adjustments — which you accept or decline. Foods come
from a bundled database that works offline, from barcodes, or from your own entries; saved meals and
recipes make repeat logging a couple of taps.

**Everything is explained.** No number changes without a sentence saying why:
*"Increased your bench press from 60 to 62.5 kg because you completed 3×12 twice with at least
2 reps in reserve."*

**And you are always in charge.** Every recommendation can be overridden, every exercise locked so
the engine leaves it alone, every program built by hand from nothing.

## Screens

Screenshots are generated, not collected by hand:

```bash
Tools/screenshots.sh                  # required device sizes, English
Tools/screenshots.sh es fr            # specific languages
Tools/screenshots.sh --all-languages  # all ten
```

It drives `AppStoreScreenshotTests` (in `GymAppUITests`) once per device and language and writes
`Screenshots/<device>/<language>/01-home.png` … through `08-settings.png`: Home, today's workout,
an active session, the exercise library, an exercise, the food log, Progress and Settings.

The device sizes are the two App Store Connect requires — iPhone 6.9" (1320×2868) and, because the
app supports iPad, iPad 13" (2064×2752). Everything else is scaled from those by App Store Connect.

The captures are driven entirely by accessibility identifiers, launch arguments and navigation
structure — never by matching a visible label — so the same run works in every language. A screen
that can no longer be reached fails the run rather than leaving a stale PNG behind.

Each simulator is put in the language and region being captured, so the status-bar clock and the
iPad's date read naturally, and shows Apple's 9:41 marketing status bar. Both are restored when the
run ends. A runner launch that SpringBoard refuses while busy is retried rather than failing the run.

## Requirements

- **Xcode 26** or newer
- **iOS 18.0** deployment target
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
- **Python 3.9+** — for the dataset, localisation and documentation tools
- No Swift Packages, no CocoaPods, no Carthage. There are zero third-party code dependencies.

## Getting it running

```bash
git clone <your-remote> "Gym app" && cd "Gym app"
xcodegen generate
open GymApp.xcodeproj
```

Select the **GymApp** scheme and run. The project is generated from `project.yml`, so **any time you
add or remove a file you must re-run `xcodegen generate`** before building.

```bash
# Build
xcodebuild -project GymApp.xcodeproj -scheme GymApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build

# Test
xcodebuild test -project GymApp.xcodeproj -scheme GymApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Signing

`project.yml` signs with team `SM3MGV3PY8` (automatic signing) under the bundle identifiers
`com.alejandronewport.forge*` and the App Group `group.com.alejandronewport.forge`, which the app
and the widget share. Simulator builds are signed ad-hoc, so they need no account. Anyone building
for a device under a different team must change the team and all three identifiers.

## Architecture

```
        Features/                 SwiftUI views + @Observable view models
            │  reads snapshots, calls engines, writes through repositories
            ▼
        Domain/                   Pure algorithms. No SwiftUI. No SwiftData. No clock.
         Training/ Nutrition/     Value types in, value types out, fully testable.
            ▲
            │  value-type snapshots
        Data/
         Repositories/            The ONLY place SwiftData is touched
         ExerciseDataset/         Immutable in-memory catalogue
         FoodDatabase/            Bundled foods + pluggable remote providers
            ▲
        Core/                     Design system, localisation, media, health,
                                  notifications, persistence, units
```

Four decisions shape everything else:

**1. The engines are pure functions.** `ProgressionEngine.decide(_:)` takes a `ProgressionInput`
and returns a `ProgressionDecision`. It cannot read the database, cannot read the clock, and cannot
render anything. That is what makes the training logic — the part that has to be *right* — testable
without a simulator, and reproducible run to run.

**2. The exercise catalogue is not in the database.** All 500 records are static reference data
that never change on device. Modelling them as SwiftData rows would add migration risk, launch cost
and query overhead and buy nothing. `ExerciseCatalog` loads them once into memory; everything the
user creates references an exercise by its stable dataset id.

**3. History is a snapshot, never a live reference.** A `WorkoutSession` copies the plan — exercise
ids, names and set targets — at the moment it starts. Editing a template afterwards, or swapping an
exercise in your routine, cannot rewrite what you did last Tuesday.

**4. Media sits behind a protocol.** Nothing outside `ExerciseMediaProviding` knows where artwork
comes from. Replacing the bundled artwork is one new conformance and one changed line.

Supporting choices: SwiftData with a versioned schema and a migration plan wired up from v1;
`@Observable` view models; `async`/`await` throughout; Swift Charts for every graph; HealthKit,
notifications, Live Activities, WidgetKit and App Intents all strictly optional.

## Project layout

```
GymApp/
├── App/                    Entry point, environment, router, root view, tab shell
├── Core/
│   ├── DesignSystem/       Palette, metrics, typography, components, haptics
│   ├── Localization/       AppLanguage, LocalizationManager, the L() lookup
│   ├── Media/              Media provider protocol, GIF decoding, bounded caches
│   ├── Persistence/        SwiftData stack, export, import, backup format
│   ├── Health/             HealthKit bridge
│   ├── Notifications/      Local notifications, Live Activity
│   ├── SharedSnapshot/     The tiny model shared with the widget target
│   ├── Intents/            App Intents and Shortcuts
│   └── Utilities/          Units, load rounding, day keys, logging
├── Domain/
│   ├── Models/             Taxonomies, Exercise, SwiftData models, nutrition value types
│   ├── Training/           Contracts + the seven training engines
│   ├── Nutrition/          Contracts + the four nutrition engines
│   └── Analytics/
├── Data/
│   ├── ExerciseDataset/    Importer, catalogue, search index, metadata deriver
│   ├── FoodDatabase/       Provider protocol, local + Open Food Facts, importer, scanner
│   └── Repositories/       SwiftData ↔ value-type boundary
├── Features/               Onboarding · Home · Workout · Exercises · Program ·
│                           Nutrition · Progress · Settings · Shared
└── Resources/
    ├── ExerciseDataset/    Split JSON payloads + manifest
    ├── ExerciseMedia/      thumbnails/ and animations/  (replaceable — see below)
    ├── FoodDatabase/       foods.json + manifest
    ├── Legal/              Bundled licence and notice files
    ├── Localizable.xcstrings
    └── Assets.xcassets
GymAppWidgets/              Widget extension + Live Activity
GymAppTests/                Unit tests (Swift Testing)
GymAppUITests/              UI tests (XCTest)
Tools/                      Dataset, localisation and documentation generators
docs/                       ALGORITHMS · DATASET_AUDIT · LICENSES · PRIVACY
```

## The exercise dataset

The catalogue is the **Gym avatar** project's reviewed selection
(`../Gym avatar/fitness-athlete-generator`): the 500 exercises whose renders passed its visual
review (`output/qa/priority-500.json`), balanced across every major muscle group. Every image is
rendered there from one original athlete; nothing comes from a third-party image library.

The records themselves — names, body part, equipment, muscles and instructions in English, Spanish,
Italian, Turkish, Russian, Chinese, Hindi, Polish, Korean and French — come from
**<https://github.com/hasaneyldrm/exercises-dataset>** (MIT), read from the avatar project's pinned
copy. Each avatar exercise carries its upstream id, so ids stay the stable dataset ids the app has
always used. Where the avatar project rewrote the English and Spanish steps to describe exactly the
rendered movement, those are used. Two exercises it created with no upstream record live in
`Tools/exercise_additions.json` (ids 9001 and 9002).

```bash
python3 Tools/prepare_dataset.py        # defaults to ../Gym avatar/fitness-athlete-generator
```

| Output | Size | Loaded |
|---|---|---|
| `Resources/ExerciseDataset/exercises.core.json` | ~0.2 MB | Once at launch, off the main actor |
| `Resources/ExerciseDataset/instructions/instructions.<lang>.json` | ~0.3 MB each | Lazily, only the active language |
| `Resources/ExerciseDataset/dataset-manifest.json` | <1 KB | Version, checksums and counts |
| `Resources/ExerciseMedia/thumbnails/` | ~2.6 MB | 240×240 JPEG, per row, cached |
| `Resources/ExerciseMedia/animations/` | ~18 MB | 400×400 animated WebP, per exercise on screen, cached under a hard ceiling |

The tool refuses to run unless all 500 carry review evidence, re-encodes each reviewed GIF to an
animated WebP (at most 36 frames, the tempo kept), crops each thumbnail to the area the movement
covers, removes any media file no exercise references, and writes **`docs/DATASET_AUDIT.md`**:
counts, distributions, and the upstream ids the avatar project merged into another exercise.

The selection has **no cardio and no stretches**, so the engine's cardio slots and the rest-day
stretch suggestion find nothing to offer and are skipped quietly.

At runtime `ExerciseDatasetImporter` decodes, normalises the three overlapping muscle vocabularies
into one canonical taxonomy, and runs `ExerciseMetadataDeriver` to add the training properties the
dataset does not carry: movement pattern, mechanic, difficulty, laterality, tracking mode, rep
range, rest, fatigue cost, stimulus, and per-muscle-group volume contribution. All of it is
deterministic and unit-tested — see [`docs/ALGORITHMS.md`](docs/ALGORITHMS.md).

### Upgrading the dataset

Re-run `prepare_dataset.py` against the new checkout, read the audit, and rebuild. The manifest's
`datasetVersion` changes; preferences, history and programs are untouched because they reference
exercises by their stable id.

## The food database

The exercise repository contains no nutrition data, so `GymApp/Resources/FoodDatabase/foods.json`
is a separate, self-contained database of common whole foods and staples with values per 100 g or
100 ml, compiled from **USDA FoodData Central** (a US Government work, public domain).

Unknown micronutrients are **omitted**, never written as zero. The app renders a real 0 and an
unknown value differently, because claiming a food contains none of something the data simply does
not cover would be a lie the user cannot see through.

Remote lookup sits behind `FoodDataProvider`. `LocalFoodDatabaseProvider` is the default and needs
no network; `OpenFoodFactsProvider` adds barcode and packaged-product search and degrades silently
to local results on any failure. There are no API keys anywhere.

## Algorithms

Every formula, threshold and weight is documented in **[`docs/ALGORITHMS.md`](docs/ALGORITHMS.md)**,
generated from per-area fragments:

```bash
python3 Tools/build_algorithms_doc.py
```

| Engine | Decides |
|---|---|
| `ExerciseMetadataDeriver` | Pattern, mechanic, difficulty, tracking, fatigue, volume credit |
| `VolumeAllocator` | Weekly hard sets and frequency per muscle group |
| `SplitSelector` | Which split, from days, time, goal and priorities |
| `ExerciseScoring` / `ExerciseRecommendationEngine` | Which exercise fills each slot |
| `ExerciseSubstitutionEngine` | Ranked alternatives, per reason |
| `WorkoutProgrammingEngine` | The whole program, inside the user's real time budget |
| `ProgressionEngine` | Load, reps and sets for next time |
| `OneRepMaxCalculator` | e1RM via Epley and Brzycki |
| `RecoveryEngine` | Per-group fatigue and readiness |
| `DeloadEngine` | Whether a lighter week is warranted |
| `AutoregulationEngine` | Small corrections after each session |
| `NutritionRecommendationEngine` | BMR, TDEE, calories, macros |
| `WeightTrendAnalyzer` | Signal from a noisy daily weight |
| `NutritionAdjustmentEngine` | Proposed calorie changes |
| `MealRecommendationEngine` | What to eat for the macros you have left |

## Localisation

Ten languages: English, Spanish, Italian, Turkish, Russian, Simplified Chinese, Hindi, Polish,
Korean, French. The whole interface is translated, not only the exercise instructions.

English source strings live in `Tools/l10n/keys/*.en.json`, one file per feature area. Translations
live in `Tools/l10n/translations/<code>.json`, one file per language. A generator merges them into
the string catalogue:

```bash
python3 Tools/build_localizations.py          # build Localizable.xcstrings
python3 Tools/build_localizations.py --report # coverage per language; non-zero if incomplete
```

Splitting the source by area and the translations by language means adding a screen touches one file
and adding a language touches one file — neither ever collides with the other.

Lookups go through `L("key")` rather than SwiftUI's implicit `Text("key")`, because the in-app
language override in Settings needs to point at a specific `.lproj` bundle. The default follows the
device; the override persists and re-renders immediately without disturbing navigation
(`LocalizationManager` is `@Observable`, so calling `L(_:)` in a `body` registers the dependency).

**What is and is not translated.** The interface, every explanation the engines produce, the muscle,
equipment and body-part vocabulary, and the exercise instructions are all translated into all ten
languages. **Exercise names are not** — the upstream dataset carries names in English only, and 500
compound names ("barbell incline reverse-grip press") machine-translated into nine languages would
read worse than leaving them in the English every gym already uses. Search matches the English name
alongside the translated muscle and equipment terms, so looking for "pecho" or "mancuerna" still
finds the right exercises. Adding a name table later is a data change, not a code change: the
catalogue already resolves names through one accessor.

### Adding a language

1. Add a case to `AppLanguage` (and its `bundleIdentifierCode` if the script tag differs).
2. Add the code to `LANGUAGES` in `Tools/build_localizations.py`.
3. Add the code to `CFBundleLocalizations` in `project.yml`.
4. Write `Tools/l10n/translations/<code>.json`.
5. Provide `Resources/ExerciseDataset/instructions/instructions.<code>.json` — or let it fall back
   to English, which `ExerciseInstructionStore` already handles.
6. `python3 Tools/build_localizations.py && xcodegen generate`.

## Testing

```bash
xcodebuild test -project GymApp.xcodeproj -scheme GymApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**914 unit tests** across 80 suites, plus the UI tests covering the flows that matter. Unit tests
use **Swift Testing**; UI tests use **XCTest**. The core suites run without the UI: they build value
types, call an engine, and check the result, so the whole unit suite finishes in about 15 seconds.

There is also a one-command pre-release checklist:

```bash
Tools/audit.sh            # dataset, food data, localisation, placeholders, both builds, both suites
Tools/audit.sh --quick    # skips the Release build and the UI tests
```

Coverage is concentrated where correctness matters most — progression decisions, substitution
ranking, volume and split selection, recovery and deload, nutrition maths, dataset integrity
(including that every one of the 500 records has media that actually exists in the bundle), food
data (including that every animal product carries the tag the vegan filter reads), the repository
history-snapshot guarantee, and a full export → wipe → import round trip.

The tests earn their keep. Writing them surfaced, among others: a CSV field containing a Windows
line break escaping unquoted (Swift treats CR-LF as one grapheme cluster, so it matched neither
`"\n"` nor `"\r"` as a `Character`); `182.5 cm` rendering as `5′ 12″`; a food-search predicate that
compiled but could not be translated to SQL, so every search in the app threw; and the bundled food
database never being imported at all.

`PreviewSupport` and `SampleDataBuilder` provide fixtures — new user, fresh program, three months of
history, an active workout, an empty and a full nutrition day — for previews and UI tests. They are
never reachable from a shipping code path.

## Data and privacy

Everything is stored locally in SwiftData. There is no account, no server, no analytics SDK and no
third-party framework of any kind. The single outbound request the app can make is an Open Food
Facts lookup, and only when you search for a packaged product or scan a barcode.

HealthKit, notifications and the camera are each optional and off until enabled; every feature works
without them. `PrivacyInfo.xcprivacy` declares no tracking and no collected data types.

Full detail: **[`docs/PRIVACY.md`](docs/PRIVACY.md)**.

Export and import live in Settings → Data: training and nutrition as CSV or JSON, or a complete
versioned JSON backup that restores on any device.

## Licences

Three different licences apply to three different things. **Read
[`docs/LICENSES.md`](docs/LICENSES.md) before distributing anything.**

| Component | Licence |
|---|---|
| This app's source | Yours to choose — none is asserted here |
| Exercise **data** and instructions | **MIT** © 2026 Hasan Emir Yıldırım |
| Exercise **media** (thumbnails, animations) | **The author's own** — original renders from the Gym avatar project, *not* MIT |
| Food database | USDA FoodData Central — public domain |
| Open Food Facts (runtime, optional) | ODbL |

> The artwork carries no credit line: `BundledExerciseMediaProvider` passes `nil` attribution, so
> every `MediaAttributionLabel` hides itself. The athlete was built from MakeHuman's bundled assets,
> which are CC0 and need no credit either. See [`docs/LICENSES.md`](docs/LICENSES.md).

### Replacing the artwork

Everything reaches media through `ExerciseMediaProviding`. To swap it out:

To refresh it after the avatar project renders or reviews more exercises, re-run
`python3 Tools/prepare_dataset.py`. To use a different source:

1. Drop your files into `Resources/ExerciseMedia/thumbnails/` and `.../animations/`, named after the
   `thumbnail` and `animation` fields in `exercises.core.json` — or write your own conformance to
   `ExerciseMediaProviding` that maps ids to your own URLs.
2. Change the single line in `AppEnvironment.init` that constructs `BundledExerciseMediaProvider`,
   passing an `attribution` and `attributionURL` if the new artwork requires a credit.

No view, engine or model changes. `EmptyExerciseMediaProvider` demonstrates that the app remains
fully usable with no artwork at all.

### Verifying by running it

The unit suite does not prove the app works — several of the bugs above were only visible with the
app on screen. `UITestLaunchSupport` (DEBUG only) seeds a named fixture from launch arguments, which
is how both the UI tests and a manual check start from a known state:

```bash
xcrun simctl launch booted com.alejandronewport.forge \
  -uiTestResetStore -uiTestScenario seasonedUser -uiTestInitialTab nutrition
```

Scenarios: `newUser`, `freshProgram`, `seasonedUser`, `activeWorkout`, `emptyNutritionDay`,
`fullNutritionDay`.

## How to change things

| I want to… | Do this |
|---|---|
| Add a food | Append a record to `Resources/FoodDatabase/foods.json` with a unique `catalogID`. The importer matches on it, so re-running updates rather than duplicating. Omit micronutrients you do not have. |
| Add a language | See [Adding a language](#adding-a-language). |
| Retune exercise selection | Edit `ExerciseScoringWeights` in `TrainingContracts.swift`. The weights are data, and the tests assert the invariants. |
| Change weekly volume targets | `VolumeAllocator` — the base ranges per experience level are constants at the top. |
| Change progression behaviour | `ProgressionEngine`, plus the thresholds documented in `docs/fragments/progression.md`. |
| Add a screen | Create it under `Features/<Area>/`, add its strings to `Tools/l10n/keys/<area>.en.json`, run the localisation builder, then `xcodegen generate`. |
| Rename the app | `PRODUCT_NAME`, `CFBundleDisplayName` and `app.name` in `Tools/l10n/keys/core.en.json`. |

## Preparing for the App Store

The app is configured, signed and archived; [`docs/APP_STORE.md`](docs/APP_STORE.md) is the
submission sheet — name, subtitle, keywords, descriptions in English and Spanish, privacy and
age-rating answers, and the notes for App Review.

Done:

- **Signing.** Team `SM3MGV3PY8`, automatic signing. Bundle ids `com.alejandronewport.forge` and
  `com.alejandronewport.forge.widgets`, App Group `group.com.alejandronewport.forge` — registered,
  with App Store distribution profiles. The App Group must match in `project.yml`,
  `GymApp/App/GymApp.entitlements`, `GymAppWidgets/GymAppWidgets.entitlements` and
  `SharedSnapshot.appGroupIdentifier`.
- **Archive.** *Forge 1.0.0 (1)* is in Xcode's Organizer, and an App Store export of it signs with
  the Apple Distribution certificate (34 MB `.ipa`).
- **Artwork licences.** The exercise art is original, and the athlete uses only MakeHuman's bundled
  CC0 assets — see [`docs/LICENSES.md`](docs/LICENSES.md).
- **Screenshots** for iPhone 6.9" and iPad 13" in all ten languages, from `Tools/screenshots.sh`.
- The app icon is a real 1024×1024 marketing icon in `Resources/Assets.xcassets/AppIcon.appiconset`.
- `ITSAppUsesNonExemptEncryption` is declared `false`.
- App Privacy: the honest answer is **no data collected**. `PrivacyInfo.xcprivacy` declares the
  required-reason APIs the app actually uses.
- The Health, camera and notification usage strings are in `project.yml`. HealthKit asks to *write*
  only workouts and body mass, which is exactly what `NSHealthUpdateUsageDescription` describes — a
  purpose string that does not account for every requested type is a 5.1.1(i) rejection.
- No background modes are declared. The rest-timer alert is a system sound, which needs none, and a
  backgrounded rest timer is covered by a local notification. Declaring `audio` without playing any
  is a 2.5.4 rejection.

Left, because each needs your Apple account or a public web page:

1. Create the app record in App Store Connect with bundle id `com.alejandronewport.forge`.
2. Publish `docs/PRIVACY.md` and a support page, and paste both URLs into the listing.
3. Organizer → *Forge 1.0.0 (1)* → **Distribute App** → **App Store Connect** → **Upload**.
4. Fill the listing from [`docs/APP_STORE.md`](docs/APP_STORE.md), attach the screenshots, select the
   build and submit.

For every later build, bump `CURRENT_PROJECT_VERSION` in `project.yml`, run `Tools/regen.sh`, and
archive again.

### Still unverifiable in the Simulator

HealthKit, the barcode camera and notifications are implemented and build, but the Simulator cannot
exercise real permission prompts or sensors. Run each once on a device before submitting: grant and
then deny Health, scan a real barcode, and let a rest timer finish with the app backgrounded.

### Not implemented

CloudKit sync. The abstraction exists and `groupContainer` / `cloudKitDatabase` are pinned to
`.none` deliberately — the app is offline by design and stores nothing on a server. Turning it on is
a product decision, not a missing piece of wiring.

### A note on download size

The exercise media is about 20 MB: 500 animated WebP animations (~18 MB, 400×400, at most 36
frames each) and 500 JPEG thumbnails (~2.6 MB). Re-encoding the Gym avatar GIFs to WebP took them
from ~500 MB to under a twentieth of that, and the earlier third-party GIFs were ~137 MB, so the
media is no longer what decides the app's download size. `AnimatedImageStore` reads frame timing
from WebP and GIF alike, so either format can ship.
