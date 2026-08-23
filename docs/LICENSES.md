# Licences and attribution

Forge combines code written for this repository with a third-party exercise dataset and
third-party exercise media. Those three things are licensed **differently**, and the difference
matters. This file is the authoritative summary; the app surfaces the same information under
**Settings → Legal**.

---

## 1. Application source code

Everything under `GymApp/`, `GymAppWidgets/`, `GymAppTests/`, `GymAppUITests/` and `Tools/` that was
written for this project is the project owner's own work. Choose and apply a licence of your own
before publishing the repository — no licence is asserted here on your behalf.

## 2. Exercise dataset (text and structure) — MIT

Source: <https://github.com/hasaneyldrm/exercises-dataset>
Copyright © 2026 Hasan Emir Yıldırım.

The exercise **data** — names, categories, body parts, equipment, target and muscle-group fields,
and the step-by-step instructions in all ten languages — is released under the MIT Licence. The full
text ships inside the app at `GymApp/Resources/Legal/EXERCISE_DATASET_LICENSE.txt` and is displayed
in Settings → Legal → Licences.

The MIT licence requires that the copyright notice and permission notice travel with the data. They
do: the licence file is bundled in the app, not merely referenced.

Anything this project derives from the dataset — the normalised taxonomies in `Taxonomy.swift` and
every field produced by `ExerciseMetadataDeriver` — is this project's own work, computed from the
MIT-licensed fields.

## 3. Exercise media (thumbnails and animations) — NOT MIT

> **© Gym visual — <https://gymvisual.com/>**

The 1,324 thumbnails and 1,324 animations under `GymApp/Resources/ExerciseMedia/` are the property
of Gym visual. They are **explicitly excluded** from the dataset's MIT licence by that repository's
own `LICENSE` and `NOTICE.md`, both of which are bundled in the app at
`GymApp/Resources/Legal/`.

The terms this project honours:

| Requirement | How it is met |
|---|---|
| Attribution "© Gym visual — https://gymvisual.com/" on every use | Every record carries an `attribution` field; `MediaAttributionLabel` renders it under every animation and on every exercise detail screen; Settings → Legal repeats it with a link. |
| Distributed at 180×180 only | `Tools/prepare_dataset.py` copies the files byte-for-byte at their original 180×180 resolution and never upscales or re-encodes them. The app renders them with aspect-fit, never claiming a higher resolution. |
| Not treated as MIT | The media lives in its own directory, under its own notice, and this file plus the in-app Legal screen state the distinction explicitly. |
| Governed by Gym visual's Terms & Conditions | <https://gymvisual.com/content/3-terms-and-conditions-of-use> |

### ⚠️ Before you ship this app

The upstream `NOTICE.md` is unambiguous: *"This repository does not grant you any rights to the
media beyond what Gym visual's terms allow — cloning this repo is not a licence."* The media was
included there under a **separate written permission granted to that repository's author**, not a
transferable licence.

**Distributing Forge on the App Store with this media therefore requires your own licence from
Gym visual.** Review <https://gymvisual.com/content/3-terms-and-conditions-of-use> and contact them
before submitting. This is a licensing step you must complete yourself; no amount of correct
attribution in the code substitutes for it.

### Replacing the media

The architecture assumes you may need to. Media is reached only through the
`ExerciseMediaProviding` protocol (`GymApp/Core/Media/ExerciseMediaProvider.swift`); no view, engine
or model touches a file path. To swap in your own artwork:

1. Put your files in `GymApp/Resources/ExerciseMedia/thumbnails/` and `.../animations/`, named after
   each exercise's `thumbnail` / `animation` field in `exercises.core.json` — **or** write a new
   type conforming to `ExerciseMediaProviding` that maps exercise ids to your own URLs.
2. Change the one line in `AppEnvironment.init` that constructs `BundledExerciseMediaProvider`.
3. Update the `attribution` and `attributionURL` you pass it — or pass `nil` for both if your
   artwork needs no credit.

Nothing else in the app changes. `EmptyExerciseMediaProvider` shows that the app stays fully
functional with no artwork at all.

## 4. Food database — public domain source

`GymApp/Resources/FoodDatabase/foods.json` is compiled from **USDA FoodData Central** (SR Legacy and
Foundation Foods). USDA FoodData Central data are works of the United States Government and are in
the public domain; no licence or attribution is legally required, and the provenance is recorded in
`food-database-manifest.json` regardless.

Values are rounded and edited for a consumer app and are **estimates, not laboratory measurements**.

## 5. Open Food Facts (optional, runtime)

If the user searches for a packaged product or scans a barcode, `OpenFoodFactsProvider` queries
<https://world.openfoodfacts.org>. Open Food Facts data is published under the
**Open Database Licence (ODbL)**; product images are under **CC-BY-SA**. The app stores only the
nutrition values it needs for the user's own log, attributes the source on the food's detail screen,
and never ships an Open Food Facts copy inside the binary. No API key exists or is required.

This provider is entirely optional: the app's food search works offline through the bundled
database, and every Open Food Facts failure degrades to local results.

## 6. Apple frameworks

SwiftUI, SwiftData, Swift Charts, HealthKit, UserNotifications, ActivityKit, WidgetKit, App Intents,
AVFoundation, Vision and ImageIO are used under the Apple Developer Program Licence Agreement.

## 7. Third-party code dependencies

**None.** Forge has no Swift Package, CocoaPods or Carthage dependencies. Everything outside Apple's
SDKs is written in this repository.
