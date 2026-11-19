# Contributing to Forge

Thanks for wanting to help. Forge is a small project with strong opinions — offline, private,
explained — so a little context up front saves everyone time.

## Ways to help

- **Report a bug** with the [bug template](https://github.com/Ale-Newport/Gym-App/issues/new?template=bug_report.yml).
- **Suggest a feature or an improvement** with the
  [feature](https://github.com/Ale-Newport/Gym-App/issues/new?template=feature_request.yml) or
  [improvement](https://github.com/Ale-Newport/Gym-App/issues/new?template=improvement.yml) templates.
- **Fix translations.** Every interface string in ten languages lives in plain JSON under
  `Tools/l10n/translations/` — no Xcode needed.
- **Pick up an issue** labelled
  [`good first issue`](https://github.com/Ale-Newport/Gym-App/labels/good%20first%20issue) or
  [`help wanted`](https://github.com/Ale-Newport/Gym-App/labels/help%20wanted).
- **Ask or discuss** in [Discussions](https://github.com/Ale-Newport/Gym-App/discussions).

For anything bigger than a small fix, open an issue first so we can agree on the approach before you
spend time on it.

## Setting up

You need a Mac with **Xcode 26 or newer** and **Python 3.9+**. There are no package managers and no
third-party dependencies.

```bash
git clone https://github.com/Ale-Newport/Gym-App.git && cd Gym-App && open GymApp.xcodeproj
```

Pick the **GymApp** scheme and an iPhone simulator, then run. Simulator builds are signed ad hoc and
need no Apple account. To start the app from a known state, pass a fixture on launch — see
[Verifying by running it](README.md#verifying-by-running-it).

`brew install xcodegen` too if you will add or remove files (see below).

## Making a change

1. **Fork** the repository and create a branch in your fork: `git switch -c fix/short-description`.
2. Make the change. Keep it focused: one problem per pull request.
3. Follow the project rules:
   - **The Xcode project is generated.** After adding, moving or deleting any file, run
     `Tools/regen.sh` (it calls `xcodegen generate`). Otherwise the new file is silently not built.
   - **Every user-visible string goes through `L("key")`.** Add the English text to
     `Tools/l10n/keys/<area>.en.json`, then run `python3 Tools/build_localizations.py`. If you can,
     add the translations to `Tools/l10n/translations/<lang>.json`; otherwise say so in the PR.
   - **Engines stay pure.** Code under `GymApp/Domain/` takes value types and returns value types:
     no SwiftUI, no SwiftData, no clock, no I/O. That is what keeps the training logic testable.
   - **SwiftData is touched only in `GymApp/Data/Repositories/`.**
   - **No new dependencies, no network calls, no tracking.** Open an issue first if you think the
     project needs one.
   - **Explain changes to the user.** If an engine changes a number, it says why.
4. Add or update tests. Unit tests use Swift Testing (`GymAppTests/`); UI tests use XCTest and look
   up elements by accessibility identifier, never by visible text.
5. Run the checks CI runs:

   ```bash
   python3 Tools/build_localizations.py --report
   python3 Tools/check_localization_keys.py --strict
   xcodebuild test -project GymApp.xcodeproj -scheme GymApp -only-testing:GymAppTests \
     -destination 'platform=iOS Simulator,name=iPhone 17'
   ```

   `Tools/audit.sh --quick` runs all of that and more in one go.
6. Commit with a [Conventional Commits](https://www.conventionalcommits.org) style message —
   `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:` — written in the present tense and describing
   what changes for the user.
7. Open a pull request against `main` and fill in the template.

## Review and merging

- Every pull request is reviewed by the code owner ([@Ale-Newport](https://github.com/Ale-Newport))
  and needs that approval plus green CI before it can be merged. Pushing new commits dismisses an
  earlier approval.
- Workflows from first-time contributors wait for maintainer approval before they run.
- Expect a first response within a week. If a PR goes quiet for longer, a friendly ping is fine.

## Licence

By contributing you agree that your contribution is licensed under the [MIT Licence](LICENSE) of
the project. The exercise media under `GymApp/Resources/ExerciseMedia/` is not MIT — please do not
submit changes to it; see [`docs/LICENSES.md`](docs/LICENSES.md).

Please also read the [code of conduct](CODE_OF_CONDUCT.md) and the [security policy](SECURITY.md).
