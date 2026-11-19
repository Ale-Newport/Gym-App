#!/usr/bin/env python3
"""
check_infoplist_strings.py — Keeps the translated permission prompts in step with project.yml.

iOS shows the Health and camera prompts from `GymApp/Resources/InfoPlist.xcstrings` in the
interface language, falling back to the Info.plist value from project.yml. If someone edits the
English text in project.yml and forgets the catalogue, every other language would keep describing
the old behaviour — which App Review treats as an inaccurate purpose string. This fails when the
English source differs, or when a language is missing a translation.

    python3 Tools/check_infoplist_strings.py
"""

from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUAGES = ["en", "es", "it", "tr", "ru", "zh-Hans", "hi", "pl", "ko", "fr"]


def main() -> int:
    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as fh:
        project = fh.read()
    with open(os.path.join(ROOT, "GymApp", "Resources", "InfoPlist.xcstrings"), encoding="utf-8") as fh:
        catalogue = json.load(fh)["strings"]

    problems = []
    for key, entry in sorted(catalogue.items()):
        match = re.search(rf'^\s*{re.escape(key)}: "(.*)"\s*$', project, re.MULTILINE)
        if not match:
            problems.append(f"{key}: not set in project.yml")
            continue
        localizations = entry.get("localizations", {})
        english = localizations.get("en", {}).get("stringUnit", {}).get("value")
        if english != match.group(1):
            problems.append(f"{key}: English differs from project.yml")
        for language in LANGUAGES:
            value = localizations.get(language, {}).get("stringUnit", {}).get("value", "")
            if not value.strip():
                problems.append(f"{key}: no {language} translation")

    for usage_key in re.findall(r"^\s*(NS\w+UsageDescription):", project, re.MULTILINE):
        if usage_key not in catalogue:
            problems.append(f"{usage_key}: in project.yml but not translated in InfoPlist.xcstrings")

    for problem in problems:
        print(f"  - {problem}")
    print(f"InfoPlist.xcstrings: {len(catalogue)} keys, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
