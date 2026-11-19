## What and why

<!-- What does this change, and what problem does it solve? Link the issue: Closes #123 -->

## How it was checked

<!-- Commands you ran and what you looked at in the Simulator. Screenshots for UI changes. -->

- [ ] `xcodebuild test -project GymApp.xcodeproj -scheme GymApp -only-testing:GymAppTests -destination 'platform=iOS Simulator,name=iPhone 17'` passes
- [ ] New or changed strings are in `Tools/l10n/keys/*.en.json`, and `python3 Tools/build_localizations.py` was re-run
- [ ] Added or removed Swift files? `Tools/regen.sh` was re-run so the Xcode project includes them
- [ ] Engines stay pure (no SwiftUI, SwiftData or clock access under `GymApp/Domain/`)
- [ ] No secrets, signing material or personal data in the diff

## Notes for review

<!-- Anything the reviewer should look at first, trade-offs, follow-ups. -->

---
Every pull request needs the code owner's approval and green CI before it can be merged.
