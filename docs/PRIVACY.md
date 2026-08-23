# Privacy

Forge is a local-first app. The short version: **your training and nutrition data stays on your
device unless you personally send it somewhere.**

## What is stored, and where

| Data | Where it lives | Leaves the device? |
|---|---|---|
| Profile (name, date of birth, sex, height, body mass, goals) | SwiftData store in the app's Application Support directory | No |
| Training programs, workout history, every set | Same store | No |
| Body-weight entries, personal records, recovery check-ins | Same store | No |
| Food log, custom foods, saved meals, recipes, nutrition targets | Same store | No |
| Settings, language override, unit preferences | Same store and `UserDefaults` | No |
| Widget snapshot (next workout, today's macros, streak) | A small JSON file in the app's App Group container | No |
| Exercise catalogue and media | Read-only files inside the app bundle | Not applicable |

The store is protected by iOS file-level encryption while the device is locked, and it is included
in an encrypted iCloud or Finder device backup exactly like any other app's data.

## Analytics and tracking

There are none. No analytics SDK, no crash reporter, no advertising identifier, no third-party
framework of any kind. `PrivacyInfo.xcprivacy` declares `NSPrivacyTracking = false`, an empty
tracking-domains list, and an empty collected-data-types list, because nothing is collected.

## Network access

Forge is fully functional with the network switched off: browsing exercises, playing animations,
running a workout, logging sets, editing programs, searching the bundled food database and reading
your progress all work offline.

The app makes exactly one kind of network request, and only when you ask it to:

**Open Food Facts** (<https://world.openfoodfacts.org>) — used when you search for a packaged
product or scan a barcode. The request contains only the search term or the barcode. It carries no
account identifier, no device identifier and no personal data. Results are cached in memory for the
session. If the request fails, the app falls back to the bundled food database. No API key exists.

Nothing else contacts a server. There is no account, no login and no sync service.

## Health app

HealthKit integration is **off until you turn it on**, and every feature works without it. When you
enable it, iOS shows its own permission sheet and you choose each data type individually.

- **Read** (optional): body mass, height, active energy, steps, sleep, workouts — used to keep your
  weight trend and energy estimates current.
- **Write** (optional): completed workouts and body-mass entries you log in Forge.

Health data is read into memory to compute what is shown on screen and is never transmitted
anywhere. You can revoke access at any time in Settings → Health → Data Access & Devices, and Forge
continues to work.

## Camera

The camera is used for exactly one thing: reading a barcode on food packaging. Frames are processed
on-device by AVFoundation and are never stored, never written to disk and never uploaded. The camera
is only active while the scanner screen is open.

## Notifications

All notifications are local, scheduled on-device by `UNUserNotificationCenter`. There is no push
server and no remote notification capability. Each category — training reminder, rest timer,
weigh-in reminder, meal reminder — is switched on independently and off by default.

## Your data, on your terms

- **Export** (Settings → Data): training and nutrition as CSV or JSON, or a complete versioned JSON
  backup. The file is written to a temporary directory and handed to the iOS share sheet, so you
  decide where it goes.
- **Import**: restore a backup, merging with what is on the device or replacing it. Replacement asks
  for explicit confirmation first.
- **Delete**: Settings → Data → Reset removes everything from the device. Deleting the app removes
  the store with it.

## Children

Forge is a general fitness app. It is not directed at children, and it collects nothing that would
identify anyone.

## Not medical advice

Forge estimates training readiness, recommends loads and calculates energy and macronutrient
targets. These are **estimates produced by documented formulas**, not measurements, diagnoses or
medical advice. The app does not assess injuries and does not replace a doctor, a dietitian or a
coach. See `docs/ALGORITHMS.md` for exactly how every number is produced.
