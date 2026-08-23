#!/usr/bin/env python3
"""
build_localizations.py — Assembles `GymApp/Resources/Localizable.xcstrings`.

Layout
------
    Tools/l10n/keys/<area>.en.json          English source strings, one file per feature area.
    Tools/l10n/translations/<lang>.json     Flat key -> translation map, one file per language.

Splitting the source by area and the translations by language means adding a screen touches one
file and adding a language touches one file — neither ever collides with the other.

Entry shapes in an area file:

    "home.title": "Today"
    "home.sets": {"one": "%lld set", "other": "%lld sets"}     # plural variations
    "home.note": {"value": "…", "comment": "Shown under the hero card"}

Run
---
    python3 Tools/build_localizations.py            # build the catalogue
    python3 Tools/build_localizations.py --report   # coverage per language, non-zero if incomplete
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEYS_DIR = os.path.join(REPO_ROOT, "Tools", "l10n", "keys")
TRANSLATIONS_DIR = os.path.join(REPO_ROOT, "Tools", "l10n", "translations")
OUTPUT = os.path.join(REPO_ROOT, "GymApp", "Resources", "Localizable.xcstrings")

# Language code in our files -> the code Xcode uses for the .lproj folder.
LANGUAGES = {
    "en": "en", "es": "es", "it": "it", "tr": "tr", "ru": "ru",
    "zh": "zh-Hans", "hi": "hi", "pl": "pl", "ko": "ko", "fr": "fr",
}
SOURCE_LANGUAGE = "en"
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")


def load_english() -> tuple[dict, dict]:
    """Returns (key -> value, key -> comment). `value` is a string or a plural dict."""
    values: dict[str, object] = {}
    comments: dict[str, str] = {}
    if not os.path.isdir(KEYS_DIR):
        return values, comments
    for filename in sorted(os.listdir(KEYS_DIR)):
        if not filename.endswith(".en.json"):
            continue
        path = os.path.join(KEYS_DIR, filename)
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        for key, entry in data.items():
            if key in values:
                raise SystemExit(f"error: duplicate key '{key}' (second definition in {filename})")
            if isinstance(entry, dict) and "value" in entry:
                values[key] = entry["value"]
                if entry.get("comment"):
                    comments[key] = entry["comment"]
            else:
                values[key] = entry
    return values, comments


def load_translations() -> dict[str, dict]:
    table: dict[str, dict] = {}
    for code in LANGUAGES:
        path = os.path.join(TRANSLATIONS_DIR, f"{code}.json")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                table[code] = json.load(fh)
        else:
            table[code] = {}
    return table


def make_unit(value) -> dict:
    """Builds one xcstrings localization unit from a string or a plural dict."""
    if isinstance(value, dict):
        variations = {}
        for category in PLURAL_CATEGORIES:
            if category in value:
                variations[category] = {
                    "stringUnit": {"state": "translated", "value": value[category]}
                }
        if "other" not in variations:
            raise SystemExit(f"error: plural entry is missing the required 'other' category: {value}")
        return {"variations": {"plural": variations}}
    return {"stringUnit": {"state": "translated", "value": value}}


def build() -> tuple[dict, dict[str, list[str]]]:
    english, comments = load_english()
    translations = load_translations()
    translations[SOURCE_LANGUAGE] = {**english, **translations.get(SOURCE_LANGUAGE, {})}

    missing: dict[str, list[str]] = {code: [] for code in LANGUAGES}
    strings: dict[str, dict] = {}

    for key in sorted(english):
        localizations: dict[str, dict] = {}
        for code, xcode_code in LANGUAGES.items():
            value = translations.get(code, {}).get(key)
            if value is None:
                missing[code].append(key)
                continue
            # A plural key must stay plural in every language, and vice versa.
            if isinstance(english[key], dict) != isinstance(value, dict):
                missing[code].append(key)
                continue
            localizations[xcode_code] = make_unit(value)
        entry: dict = {"extractionState": "manual", "localizations": localizations}
        if key in comments:
            entry["comment"] = comments[key]
        strings[key] = entry

    catalogue = {
        "sourceLanguage": SOURCE_LANGUAGE,
        "strings": strings,
        "version": "1.0",
    }
    return catalogue, missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="Print coverage and fail if incomplete")
    args = parser.parse_args()

    catalogue, missing = build()
    total = len(catalogue["strings"])

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as fh:
        json.dump(catalogue, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")

    print(f"wrote {OUTPUT} · {total} keys · {len(LANGUAGES)} languages")

    incomplete = False
    for code in LANGUAGES:
        gaps = missing[code]
        covered = total - len(gaps)
        percent = (covered / total * 100) if total else 100.0
        flag = "" if not gaps else f"  ({len(gaps)} missing)"
        print(f"  {code:<3} {covered:>5}/{total}  {percent:6.2f}%{flag}")
        if gaps:
            incomplete = True
            if args.report:
                for key in gaps[:15]:
                    print(f"        - {key}")
                if len(gaps) > 15:
                    print(f"        … and {len(gaps) - 15} more")

    if args.report and incomplete:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
