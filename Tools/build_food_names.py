#!/usr/bin/env python3
"""
build_food_names.py — Assembles `GymApp/Resources/FoodDatabase/foods.names.json`.

The bundled food database (`foods.json`) is English. Food names are everyday words, so the app shows
and searches them in the interface language. Two sources feed one lookup table, keyed
`{language: {catalogID: name}}`:

  1. The 244 curated foods already carry a `nameKey` (`food.apple`), translated into every language
     in `Tools/l10n/translations/<lang>.json`. Those translations are reused as they are.
  2. The remaining foods are translated in `Tools/l10n/food-names/<lang>.json`, a flat
     `{catalogID: name}` map per language.

English is the record's own `name` and is not repeated. A food with no entry for a language keeps
its English name there.

    python3 Tools/build_food_names.py            # write the file
    python3 Tools/build_food_names.py --report   # coverage per language, non-zero if incomplete
"""

from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOODS = os.path.join(ROOT, "GymApp", "Resources", "FoodDatabase", "foods.json")
OUTPUT = os.path.join(ROOT, "GymApp", "Resources", "FoodDatabase", "foods.names.json")
TRANSLATIONS = os.path.join(ROOT, "Tools", "l10n", "translations")
FOOD_NAMES = os.path.join(ROOT, "Tools", "l10n", "food-names")

# Code in our files -> the dataset code the app looks names up by (`AppLanguage.datasetCode`).
LANGUAGES = ["es", "it", "tr", "ru", "zh", "hi", "pl", "ko", "fr"]


def load(path: str) -> dict:
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def build() -> tuple[dict, dict]:
    with open(FOODS, encoding="utf-8") as fh:
        foods = json.load(fh)

    table: dict[str, dict[str, str]] = {}
    missing: dict[str, list[str]] = {}
    for lang in LANGUAGES:
        curated = load(os.path.join(TRANSLATIONS, f"{lang}.json"))
        extra = load(os.path.join(FOOD_NAMES, f"{lang}.json"))
        names: dict[str, str] = {}
        absent: list[str] = []
        for food in foods:
            catalog_id = food["catalogID"]
            key = food.get("nameKey")
            value = (curated.get(key) if key else None) or extra.get(catalog_id)
            if value and value.strip():
                names[catalog_id] = value.strip()
            else:
                absent.append(catalog_id)
        table[lang] = names
        missing[lang] = absent
    return table, missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()

    table, missing = build()
    total = len(next(iter(table.values()), {})) + len(next(iter(missing.values()), []))

    if args.report:
        for lang in LANGUAGES:
            print(f"  {lang}  {len(table[lang])}/{total}")
        return 1 if any(missing.values()) else 0

    with open(OUTPUT, "w", encoding="utf-8") as fh:
        json.dump(table, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")
    print(f"wrote {OUTPUT} · {len(LANGUAGES)} languages")
    for lang in LANGUAGES:
        print(f"  {lang}  {len(table[lang])}/{total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
