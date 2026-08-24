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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    defined = catalogue_keys()
    used = referenced_keys()

    missing = {key: files for key, files in used.items() if key not in defined}
    unused = sorted(
        key for key in defined
        if key not in used and not key.startswith(DYNAMIC_PREFIXES)
    )

    print(f"catalogue keys: {len(defined)}")
    print(f"keys referenced in code: {len(used)}")
    print(f"MISSING (referenced but undefined): {len(missing)}")
    for key in sorted(missing):
        print(f"  - {key}   <- {', '.join(sorted(set(missing[key]))[:3])}")
    print(f"possibly unused: {len(unused)}")
    for key in unused[:40]:
        print(f"  · {key}")
    if len(unused) > 40:
        print(f"  … and {len(unused) - 40} more")

    return 1 if (args.strict and missing) else 0


if __name__ == "__main__":
    sys.exit(main())
