# Changelog

All notable changes to Forge are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
