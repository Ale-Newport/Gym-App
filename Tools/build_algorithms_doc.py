#!/usr/bin/env python3
"""
build_algorithms_doc.py — Assembles docs/ALGORITHMS.md from docs/fragments/*.md.

Each engine area documents itself in its own fragment, so the file that explains an algorithm
lives next to the person who wrote it and two areas never collide in the same document. This tool
stitches the fragments together in a deliberate reading order, with a table of contents.

    python3 Tools/build_algorithms_doc.py
"""

from __future__ import annotations

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAGMENTS = os.path.join(REPO_ROOT, "docs", "fragments")
OUTPUT = os.path.join(REPO_ROOT, "docs", "ALGORITHMS.md")

# Reading order: data first, then the training chain in the order it runs, then nutrition.
ORDER = [
    ("metadata", "Exercise metadata derivation"),
    ("selection", "Exercise scoring, selection and substitution"),
    ("programming", "Split selection, weekly volume and program generation"),
    ("progression", "Progression, 1RM estimation and personal records"),
    ("recovery", "Recovery, deload and autoregulation"),
    ("nutrition", "Energy, macros, weight trend and meal recommendation"),
    ("food-database", "The bundled food database"),
    ("repositories", "Persistence boundaries"),
]

HEADER = """# Algorithms

Every recommendation Forge makes is produced by deterministic code that runs entirely on the
device. There is no model call, no server and no hidden randomness: the same inputs always produce
the same output, and every rule below is unit-tested.

This document is the specification. Where the code and this document disagree, the document is
right and the code has a bug.

> **Not medical advice.** These are estimates produced by published formulas and by conventions
> drawn from mainstream strength and nutrition practice. They are not measurements, diagnoses or
> clinical guidance, and the app never presents them as such.

## How the pieces fit together

```
UserProfile + EquipmentProfile
        |
        v
TrainingProfileSnapshot ──> VolumeAllocator ──> weekly set targets per muscle group
                                  |
                                  v
                            SplitSelector ──> session blueprints
                                  |
                                  v
                 ExerciseRecommendationEngine ──> ExerciseScoring ──> a ranked exercise per slot
                                  |
                                  v
                       WorkoutProgrammingEngine ──> GeneratedProgram
                                  |
        performed sets ───────────┴──────────> ProgressionEngine ──> next session's loads
                |                                      ^
                v                                      |
        RecoveryEngine ──> fatigue per group ──> AutoregulationEngine
                |                                      |
                v                                      v
          DeloadEngine ──────────────────────> volume and intensity adjustments
```

Nutrition runs alongside on the same principle:

```
NutritionProfileSnapshot ──> NutritionRecommendationEngine ──> energy + macro targets
        body-weight log ──> WeightTrendAnalyzer ──> NutritionAdjustmentEngine ──> proposed change
       remaining macros ──> MealRecommendationEngine ──> scored meal suggestions
```

"""


def slugify(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def main() -> int:
    if not os.path.isdir(FRAGMENTS):
        print(f"error: {FRAGMENTS} does not exist", file=sys.stderr)
        return 1

    present = {f[:-3]: f for f in os.listdir(FRAGMENTS) if f.endswith(".md")}
    ordered = [(key, title) for key, title in ORDER if key in present]
    extras = sorted(k for k in present if k not in {key for key, _ in ORDER})

    if not ordered and not extras:
        print("error: no fragments found", file=sys.stderr)
        return 1

    toc = ["## Contents", ""]
    for _, title in ordered:
        toc.append(f"- [{title}](#{slugify(title)})")
    for key in extras:
        toc.append(f"- [{key}](#{slugify(key)})")
    toc.append("")

    parts = [HEADER, "\n".join(toc), ""]

    for key, title in ordered + [(k, k) for k in extras]:
        with open(os.path.join(FRAGMENTS, present[key]), encoding="utf-8") as fh:
            body = fh.read().strip()

        # A fragment may or may not open with its own H1. Normalise to a single H2 per section and
        # demote everything inside it so the assembled document has one coherent heading tree.
        lines = body.split("\n")
        if lines and lines[0].startswith("# "):
            lines = lines[1:]
        demoted = []
        in_code = False
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("```"):
                in_code = not in_code
            if not in_code and re.match(r"^#{1,5} ", line):
                line = "#" + line
            demoted.append(line)

        parts.append(f"## {title}\n")
        parts.append("\n".join(demoted).strip())
        parts.append("\n---\n")

    if parts[-1] == "\n---\n":
        parts.pop()

    with open(OUTPUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts).rstrip() + "\n")

    print(f"wrote {OUTPUT} from {len(ordered) + len(extras)} fragments")
    missing = [key for key, _ in ORDER if key not in present]
    if missing:
        print("missing fragments: " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
