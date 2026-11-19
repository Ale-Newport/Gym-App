<div align="center">

<img src="docs/assets/demo.gif" width="300" alt="Forge running in the iOS Simulator: starting a workout, logging a set into the rest timer, browsing the exercise library, an animated exercise, the nutrition log and progress">

# Forge

### Adaptive training. Nutrition in the same place.

**An open-source iPhone and iPad gym coach that writes your training plan, tells you what to lift next and why, and tracks your nutrition — on your device, with no account.**

[![CI](https://github.com/Ale-Newport/Gym-App/actions/workflows/ci.yml/badge.svg)](https://github.com/Ale-Newport/Gym-App/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Ale-Newport/Gym-App?sort=semver)](https://github.com/Ale-Newport/Gym-App/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%2018%2B%20·%20iPadOS-lightgrey?logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20·%20SwiftData-F05138?logo=swift&logoColor=white)
![Unit tests](https://img.shields.io/badge/unit%20tests-934%20passing-brightgreen)
![Languages](https://img.shields.io/badge/languages-10-orange)
![Dependencies](https://img.shields.io/badge/third--party%20dependencies-0-success)

</div>

An iPhone and iPad app that builds a training plan around your goals, equipment and schedule, then adjusts it as you log your workouts. Forge pairs that plan with exercise demonstrations, nutrition tracking and progress insights, with the core experience running on device.

**Swift · SwiftUI · SwiftData · Swift Charts · iOS 18+**

[Try it in 1 minute](#try-it-in-the-simulator-without-building) · [Build from source](#run-in-simulator) · [Explore the screens](#a-look-inside) · [Engineering guide](docs/ENGINEERING.md) · [Support site](https://ale-newport.github.io/Gym-App/) · [Contributing](CONTRIBUTING.md)

## A look inside

<table>
<tr>
<td width="33%"><img src="Screenshots/iphone-6.9/en/01-home.png" alt="Forge home with workout summary and recovery information" width="280"></td>
<td width="33%"><img src="Screenshots/iphone-6.9/en/03-active-workout.png" alt="Active workout with exercise demonstration and set logging" width="280"></td>
<td width="33%"><img src="Screenshots/iphone-6.9/en/06-nutrition-today.png" alt="Daily nutrition log and macro targets" width="280"></td>
</tr>
<tr><td align="center">Your day</td><td align="center">Your training</td><td align="center">Your nutrition</td></tr>
</table>

*Actual Simulator captures from the repository's English screenshot set.*

## What Forge does

- **Plans around you:** uses your goals, experience, equipment and available days to build a program.
- **Adapts to your sessions:** progression, autoregulation and deload engines use logged performance to shape recommendations, with an explanation for each adjustment.
- **Shows the movement:** 500 exercises with original 3D demonstrations and instructions in ten languages.
- **Finds a substitute:** ranks alternatives when equipment is unavailable or an exercise needs to change.
- **Keeps nutrition close:** calorie and macro targets, food logging, saved meals, recipes and weight trends.
- **Lets you stay in control:** override recommendations, lock exercises or build a program manually.

No account is required. Core planning and tracking run locally; optional features include HealthKit integration, notifications, widgets, Live Activities and remote food lookup.

## Try it in the Simulator without building

Every [release](https://github.com/Ale-Newport/Gym-App/releases/latest) ships `Forge-Simulator.zip`,
a ready-built Simulator app (Release, Apple silicon and Intel). On a Mac with Xcode and an iPhone
simulator installed, download it and run (change `"iPhone 17"` to any simulator listed by `xcrun simctl list devices available`):

```bash
cd ~/Downloads && { [ -d Forge.app ] || unzip -oq Forge-Simulator.zip; } && open -a Simulator && (xcrun simctl boot "iPhone 17" 2>/dev/null; true) && xcrun simctl install booted Forge.app && xcrun simctl launch booted com.alejandronewport.forge
```

## Run in Simulator

Requires **macOS**, **Xcode 26+** and an installed iOS Simulator runtime. The app targets **iOS 18.0+**. There are no third-party Swift package dependencies to configure.

```bash
git clone https://github.com/Ale-Newport/Gym-App.git && cd Gym-App && open GymApp.xcodeproj
```

1. Select the **GymApp** scheme.
2. Select an installed **iPhone Simulator** as the destination.
3. Press **Run** (`Cmd+R`) and complete onboarding to generate a plan.

The Xcode project is already committed, so XcodeGen is unnecessary for this first run. A Simulator build does not require your own Apple Developer team. For a physical device, configure your signing team, bundle identifiers and App Group as described in the [engineering guide](docs/ENGINEERING.md).

### Command-line build

Choose a destination available on your Mac (`xcrun simctl list devices available`):

```bash
xcodebuild -project GymApp.xcodeproj -scheme GymApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

If you add or remove source files later, regenerate the project from `project.yml` with **XcodeGen** before building:

```bash
brew install xcodegen
xcodegen generate
```

## How it is built

The domain engines accept value types and return decisions. Repositories own persistence, and SwiftUI views consume the results. This keeps training and nutrition rules testable without rendering the interface.

```mermaid
flowchart LR
    UI[SwiftUI features] --> Repositories[Data repositories]
    Repositories --> Storage[SwiftData]
    UI --> Engines[Training and nutrition engines]
    Catalog[Exercise and food catalogues] --> UI
    Engines --> Decisions[Explained recommendations]
    Decisions --> UI
```

| Directory | Responsibility |
| --- | --- |
| `GymApp/Features/` | Onboarding, workouts, exercises, nutrition and progress |
| `GymApp/Domain/` | Training, nutrition and analytics logic |
| `GymApp/Data/` | Repositories and reference catalogues |
| `GymApp/Core/` | Persistence, design system and platform integrations |
| `GymApp/Resources/` | Exercise media, translations and bundled food data |
| `GymAppWidgets/` | Widgets and Live Activity |
| `GymAppTests/` + `GymAppUITests/` | Unit and interface tests |

## Tests and screenshots

```bash
xcodebuild test -project GymApp.xcodeproj -scheme GymApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Regenerate the English App Store screenshot set.
Tools/screenshots.sh en
```

The unit suite — **934 tests in 82 suites** — runs in about 15 seconds, and CI runs it with a Release
build of the app and widget on every push and pull request.

The screenshot script requires the device names listed in `Tools/screenshots.sh`. More languages and device captures are available in [Screenshots/](Screenshots/).

## Further reading

The [engineering guide](docs/ENGINEERING.md) covers the algorithms, datasets, localisation, architecture and release workflow. Also see [privacy](docs/PRIVACY.md), [licences and attribution](docs/LICENSES.md) and the [algorithm reference](docs/ALGORITHMS.md).

## Contributing

Bug reports, translations, ideas and pull requests are welcome — start with
[`CONTRIBUTING.md`](CONTRIBUTING.md), pick up a
[`good first issue`](https://github.com/Ale-Newport/Gym-App/labels/good%20first%20issue), or ask in
[Discussions](https://github.com/Ale-Newport/Gym-App/discussions). Everyone taking part follows the
[code of conduct](CODE_OF_CONDUCT.md). Report security problems privately as described in
[`SECURITY.md`](SECURITY.md). Release history is in [`CHANGELOG.md`](CHANGELOG.md).

## License

The source code is released under the [MIT License](LICENSE). The exercise media is **not** — it
stays all rights reserved, and the Forge name and icon identify the author's App Store release. See
[licences and attribution](docs/LICENSES.md) for exactly what applies to what.
