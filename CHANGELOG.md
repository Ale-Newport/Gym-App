# Changelog

All notable changes to Forge are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Restoring a backup no longer drops bundled foods from saved meals, recipes and log entries: the
  bundled foods they use (and favourites) now travel with the backup and are matched back to the
  local food database by catalogue id, so their calories are counted again.
- After Settings → Reset or a "Replace" restore, the bundled food database is rebuilt straight away
  instead of staying empty until the next launch.
- If the saved data cannot be opened at launch, Forge now says so on a blocking screen instead of
  silently starting an empty, unsaved session that looked like a fresh install.
- At the largest accessibility text sizes, stat rows stack instead of breaking words letter by
  letter, numbers grow with the text, exercise names and the date are no longer cut off.
- The Open Food Facts request identifies Forge with its own support page, as their terms ask.

### Changed

- Health and camera permission prompts are translated into all ten languages.
- The app and widget versions are set in one place, so they can never disagree.
- 41 unused interface strings were removed; CI now fails on unused or missing keys.

### Project

- Swift sources are formatted with the swift-format bundled in Xcode, checked in CI.
- The UI test suite runs in CI; one test no longer depends on the simulator's language.
- A test pins the 1.0 storage schema so a model change cannot ship without a migration.
- Dependabot's GitHub Actions updates merge automatically once approved and green.

## [1.0.0] — 2026-11-19

The first public release: the app as prepared for the App Store, plus the project infrastructure
that makes it an open-source project.

### Training

- First-run setup in five short screens: profile, goal and level, schedule, equipment, reminders.
- `WorkoutProgrammingEngine` picks a split, allocates weekly volume per muscle group and fills
  every slot with a scored exercise, inside the user's real time budget.
- `ProgressionEngine`, `AutoregulationEngine`, `RecoveryEngine` and `DeloadEngine` adjust load,
  reps, sets and the next session from what was actually logged — and explain every change.
- Substitution ranked by the reason for the swap: machine taken, only dumbbells, easier, same muscle.
- 500 exercises, each with an original 3D-rendered animation, and instructions in ten languages.
- Live Activity for the active workout, a home-screen widget and App Intents / Shortcuts.

### Nutrition

- BMR (Mifflin-St Jeor), TDEE and macro targets per goal; weight-trend analysis by linear
  regression drives calorie adjustments the user accepts or declines.
- Bundled offline food database (594 foods from USDA FoodData Central), names translated into all
  ten languages and searchable in any of them; optional Open Food Facts barcode lookup.

### Everything else

- Ten languages across the whole interface: English, Spanish, Italian, Turkish, Russian,
  Simplified Chinese, Hindi, Polish, Korean and French.
- Fully on device: no account, no server, no analytics. Export to CSV / JSON and full versioned
  backups that restore on any device.
- 934 unit tests (Swift Testing) and UI tests (XCTest); generated App Store screenshots for
  iPhone 6.9" and iPad 13" in every language; support and privacy pages on GitHub Pages.

### Project

- MIT licence for the source code (the exercise media stays all rights reserved).
- CI on every push and pull request: localisation and tooling checks, a full-history secret scan,
  and a Release build plus the unit tests on macOS.
- Security: CodeQL, Dependabot, secret scanning with push protection, SHA-pinned GitHub-owned
  Actions with read-only tokens, branch rulesets with code-owner review, and a security policy.
- Contributor guide, code of conduct, issue and pull request templates, and Discussions.

[Unreleased]: https://github.com/Ale-Newport/Gym-App/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Ale-Newport/Gym-App/releases/tag/v1.0.0
