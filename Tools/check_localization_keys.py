#!/usr/bin/env python3
"""
check_localization_keys.py — Cross-checks the keys the code uses against the catalogue.

Every user-visible string in the app resolves through `L("key")`, `LPlural("key", n)` or an
`Explanation("key", …)`. A key that the code references but the catalogue does not define falls back
to the raw key at runtime (and trips an assertion in debug), so this check is the guard that keeps
that from shipping. It also lists keys the catalogue defines that nothing references, which is how
dead strings get pruned.

    python3 Tools/check_localization_keys.py            # report
    python3 Tools/check_localization_keys.py --strict   # non-zero exit when keys are missing
    python3 Tools/check_localization_keys.py --strict --fail-on-unused   # …or look unused (CI)
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Static string literals passed to a localisation entry point.
PATTERNS = [
    re.compile(r'\bL\(\s*"([^"\\]+)"'),
    re.compile(r'\bLPlural\(\s*"([^"\\]+)"'),
    re.compile(r'\bExplanation\(\s*"([^"\\]+)"'),
    re.compile(r'localizationKey:\s*"([^"\\]+)"'),
    re.compile(r'\btitleKey:\s*"([^"\\]+)"'),
    re.compile(r'\breasonKey:\s*"([^"\\]+)"'),
    re.compile(r'\brationaleKey:\s*"([^"\\]+)"'),
    re.compile(r'\blabelKey:\s*"([^"\\]+)"'),
    re.compile(r'\bnameKey:\s*"([^"\\]+)"'),
]

# Keys built at runtime from an enum's raw value, e.g. "muscleGroup.\(rawValue)". These are covered
# by the taxonomy key file and cannot be found by a literal scan, so their prefixes are exempt.
DYNAMIC_PREFIXES = (
    "bodyPart.", "muscle.", "muscleGroup.", "focusRegion.", "equipment.", "movementPattern.",
    "pushPull.", "mechanic.", "laterality.", "difficulty.", "loadability.", "trackingMode.",
    "sex.", "experience.", "technique.", "activity.", "goal.", "weekday.", "trainingTime.",
    "cardio.", "gymPreset.", "limitation.", "exerciseFeedback.", "sessionEffort.", "unitSystem.",
    "weightUnit.", "heightUnit.", "distanceUnit.", "energyUnit.", "appearance.", "diet.", "meal.",
    "servingUnit.", "pace.", "sessionStatus.", "setKind.", "calibration.", "progression.",
    "prKind.", "range.", "micro.", "foodSource.", "substitution.", "progressionAction.",
    "split.", "session.", "export.", "import.", "tab.", "food.",
    "start.step.", "tour.",
)


def catalogue_keys() -> set[str]:
    keys: set[str] = set()
    for path in glob.glob(os.path.join(REPO_ROOT, "Tools", "l10n", "keys", "*.en.json")):
        with open(path, encoding="utf-8") as fh:
            keys.update(json.load(fh).keys())
    return keys


def referenced_keys() -> dict[str, list[str]]:
    """Returns key -> the files that reference it."""
    found: dict[str, list[str]] = {}
    # App targets only. Tests pass arbitrary strings where a key is expected — an Explanation
    # built with the key "test" is a fixture, not a missing translation — so scanning them would
    # report noise that can never be fixed.
    roots = ["GymApp", "GymAppWidgets"]
    for root in roots:
        for dirpath, _, filenames in os.walk(os.path.join(REPO_ROOT, root)):
            for filename in filenames:
                if not filename.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, filename)
                with open(path, encoding="utf-8") as fh:
                    source = fh.read()
                for pattern in PATTERNS:
                    for key in pattern.findall(source):
                        found.setdefault(key, []).append(os.path.relpath(path, REPO_ROOT))
    return found


# Any string literal in the app. A defined key that appears as a literal anywhere — passed as a
# `detailKey:`, stored in a table, returned from a computed property — is in use even though no
# localisation call wraps it at that spot.
STRING_LITERAL = re.compile(r'"([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"')

# The fixed part of a key built by interpolation, e.g. "home.greeting.\(period.rawValue)".
INTERPOLATED_PREFIX = re.compile(r'"([A-Za-z][A-Za-z0-9_.]*\.)\\\(')


def app_sources() -> str:
    chunks = []
    for root in ("GymApp", "GymAppWidgets"):
        for path in glob.glob(os.path.join(REPO_ROOT, root, "**", "*.swift"), recursive=True):
            with open(path, encoding="utf-8") as fh:
                chunks.append(fh.read())
    return "\n".join(chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true", help="exit non-zero when keys are missing")
    parser.add_argument(
        "--fail-on-unused", action="store_true", help="also exit non-zero when a key looks unused"
    )
    parser.add_argument("--all", action="store_true", help="list every possibly unused key")
    args = parser.parse_args()

    defined = catalogue_keys()
    used = referenced_keys()
    source = app_sources()
    literals = set(STRING_LITERAL.findall(source))
    prefixes = DYNAMIC_PREFIXES + tuple(sorted(set(INTERPOLATED_PREFIX.findall(source))))

    missing = {key: files for key, files in used.items() if key not in defined}
    unused = sorted(
        key for key in defined
        if key not in used and key not in literals and not key.startswith(prefixes)
    )

    print(f"catalogue keys: {len(defined)}")
    print(f"keys referenced in code: {len(used)}")
    print(f"MISSING (referenced but undefined): {len(missing)}")
    for key in sorted(missing):
        print(f"  - {key}   <- {', '.join(sorted(set(missing[key]))[:3])}")
    print(f"possibly unused: {len(unused)}")
    shown = unused if args.all else unused[:40]
    for key in shown:
        print(f"  · {key}")
    if len(unused) > len(shown):
        print(f"  … and {len(unused) - len(shown)} more (--all lists them)")

    if args.strict and missing:
        return 1
    if args.fail_on_unused and unused:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
