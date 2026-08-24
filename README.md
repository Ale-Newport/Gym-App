<div align="center">

# Forge

**An adaptive training and nutrition app for iOS.**

Forge decides what you should train today, which exercises, in which order, for how many sets and
reps, at what load, with how much rest — then watches what you actually did and adjusts. It ships
with 1,324 exercises, each with an animation, and instructions in ten languages. Everything runs on
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

<!-- Replace these placeholders with real captures before submitting to the App Store.
     Suggested set: Home, Active Workout, Exercise Detail, Exercise Library, Program Overview,
     Nutrition Today, Progress, Settings — each in light and dark. -->

| Home | Active workout | Exercise detail | Nutrition |
|---|---|---|---|
| _screenshot_ | _screenshot_ | _screenshot_ | _screenshot_ |

| Library | Program | Progress | Settings |
|---|---|---|---|
| _screenshot_ | _screenshot_ | _screenshot_ | _screenshot_ |

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

`project.yml` leaves `DEVELOPMENT_TEAM` empty and signs simulator builds ad-hoc, so a clone builds
and runs in the Simulator with no setup. To run on a device, set your team in Xcode's Signing &
Capabilities tab (or fill in `DEVELOPMENT_TEAM` in `project.yml`) and change the bundle identifiers
from `com.gymapp.forge*` to something you own — including the App Group
`group.com.gymapp.forge`, which the app and the widget share.

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

**2. The exercise catalogue is not in the database.** All 1,324 records are static reference data
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

Source: **<https://github.com/hasaneyldrm/exercises-dataset>** — 1,324 exercises with a 180×180
thumbnail and animation each, and instructions in English, Spanish, Italian, Turkish, Russian,
Chinese, Hindi, Polish, Korean and French.

The upstream `data/exercises.json` is a single 17 MB document carrying all ten languages inside
every record. Parsing that at launch would cost hundreds of milliseconds and tens of megabytes for
text nobody will read. `Tools/prepare_dataset.py` therefore audits it and splits it:

```bash
git clone https://github.com/hasaneyldrm/exercises-dataset /tmp/exercises-dataset
python3 Tools/prepare_dataset.py --source /tmp/exercises-dataset
```

| Output | Size | Loaded |
|---|---|---|
| `Resources/ExerciseDataset/exercises.core.json` | ~0.5 MB | Once at launch, off the main actor |
| `Resources/ExerciseDataset/instructions/instructions.<lang>.json` | ~0.8 MB each | Lazily, only the active language |
| `Resources/ExerciseDataset/dataset-manifest.json` | <1 KB | Version, checksum and counts |
| `Resources/ExerciseMedia/thumbnails/` | ~11 MB | Per row, cached |
| `Resources/ExerciseMedia/animations/` | ~125 MB | Per exercise on screen, cached under a hard ceiling |

The tool also writes **`docs/DATASET_AUDIT.md`**: record count, duplicate ids, missing or zero-byte
media, missing translations, orphaned files and the full field distributions. A defective record is
rejected there rather than shipped — one bad row in a future revision cannot brick the app.

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
device; the override persists and re-renders the whole interface immediately.

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

**904 unit tests** across 78 suites, plus **20 UI tests** covering the flows that matter. Unit tests
use **Swift Testing**; UI tests use **XCTest**. The core suites run without the UI: they build value
types, call an engine, and check the result, so the whole unit suite finishes in about 15 seconds.

There is also a one-command pre-release checklist:

```bash
Tools/audit.sh            # dataset, food data, localisation, placeholders, both builds, both suites
Tools/audit.sh --quick    # skips the Release build and the UI tests
```

Coverage is concentrated where correctness matters most — progression decisions, substitution
ranking, volume and split selection, recovery and deload, nutrition maths, dataset integrity
(including that every one of the 1,324 records has media that actually exists in the bundle), food
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
| Exercise **media** (thumbnails, animations) | **Proprietary** © [Gym visual](https://gymvisual.com/) — *not* MIT |
| Food database | USDA FoodData Central — public domain |
| Open Food Facts (runtime, optional) | ODbL |

> ⚠️ **The artwork is not yours by cloning.** The upstream `NOTICE.md` states plainly that the media
> is included there under a separate written permission granted to that repository's author, and
> that cloning grants you no rights to it. Shipping this app with that artwork requires **your own
> licence from Gym visual**. The app honours every attribution and resolution term already — that is
> necessary, not sufficient. See [`docs/LICENSES.md`](docs/LICENSES.md).

### Replacing the artwork

Everything reaches media through `ExerciseMediaProviding`. To swap it out:

1. Drop your files into `Resources/ExerciseMedia/thumbnails/` and `.../animations/`, named after the
   `thumbnail` and `animation` fields in `exercises.core.json` — or write your own conformance to
   `ExerciseMediaProviding` that maps ids to your own URLs.
2. Change the single line in `AppEnvironment.init` that constructs `BundledExerciseMediaProvider`,
   passing your own `attribution` and `attributionURL` (or `nil` for both).

No view, engine or model changes. `EmptyExerciseMediaProvider` demonstrates that the app remains
fully usable with no artwork at all.

### Verifying by running it

The unit suite does not prove the app works — several of the bugs above were only visible with the
app on screen. `UITestLaunchSupport` (DEBUG only) seeds a named fixture from launch arguments, which
is how both the UI tests and a manual check start from a known state:

```bash
xcrun simctl launch booted com.gymapp.forge \
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

1. **Settle the media licence** with Gym visual, or replace the artwork. This is the blocking item.
2. Set `DEVELOPMENT_TEAM` and change every bundle identifier and the App Group to identifiers you
   own.
3. Add a real app icon to `Resources/Assets.xcassets/AppIcon.appiconset`.
4. Capture screenshots for every required device size, in light and dark.
5. Archive with the Release configuration and validate.
6. Fill in App Privacy: with the defaults, the honest answer is **no data collected**. The Health,
   camera and notification usage strings are already in `project.yml`.
7. `ITSAppUsesNonExemptEncryption` is already declared `false`.
8. Note in review comments that the app gives fitness and nutrition *estimates*, not medical advice.
