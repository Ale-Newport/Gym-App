# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x (latest release and `main`) | Yes |
| Anything older | No |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub:
**[Report a vulnerability](https://github.com/Ale-Newport/Gym-App/security/advisories/new)**
(Security tab → *Report a vulnerability*). Only the maintainer can see the report.

Include what you found, how to reproduce it, and the version or commit you tested. You will get an
acknowledgement within 7 days and a status update at least every 14 days until it is resolved.
Once a fix ships, the advisory is published with credit to you unless you prefer otherwise.

## Scope

Forge runs entirely on the device. It has no account, no server and no analytics, so the realistic
attack surface is small:

- **Data at rest** — the SwiftData store, the App Group container shared with the widget, and
  export / backup files (`Core/Persistence`).
- **Backup import** — parsing a JSON backup or CSV file that someone else crafted.
- **The one network call** — the optional Open Food Facts lookup (`Data/FoodDatabase`), which must
  degrade safely on any malformed or hostile response.
- **Permissions** — HealthKit, camera (barcode scanning) and notifications, each of which must stay
  off until the user enables it.
- **The build and release pipeline** — GitHub Actions workflows and repository configuration.

Out of scope: problems that need a jailbroken device or physical access to an unlocked one, and
findings in third-party services (report those to Open Food Facts or Apple directly).

## How the repository is protected

- Secret scanning and push protection are on; `gitleaks` scans the full history in CI.
- Dependabot alerts and security updates are on; Actions are restricted to GitHub-owned actions
  pinned to full commit SHAs, and workflows get a read-only token.
- CodeQL analyses the Swift and Python code.
- Every branch is covered by a ruleset: no force pushes, no deletions, and changes land only
  through pull requests approved by the code owner.
