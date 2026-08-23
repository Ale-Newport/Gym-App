#!/usr/bin/env python3
"""
prepare_dataset.py — Ingests the upstream `exercises-dataset` repository and emits the
resources bundled inside GymApp.

Why this exists
---------------
The upstream `data/exercises.json` is a single 17 MB document that carries instructions for
ten languages inside every record. Parsing it at launch would cost hundreds of milliseconds
and tens of megabytes of resident memory for text the user will never read (nine languages
out of ten). This tool splits it into:

    Resources/ExerciseDataset/exercises.core.json          ~0.6 MB, always loaded
    Resources/ExerciseDataset/instructions/instructions.<lang>.json   loaded lazily, per language
    Resources/ExerciseDataset/dataset-manifest.json        version + integrity metadata

and copies the media into a dedicated, replaceable media root:

    Resources/ExerciseMedia/thumbnails/<id>-<mediaId>.jpg
    Resources/ExerciseMedia/animations/<id>-<mediaId>.gif

The media is NOT MIT-licensed (see NOTICE.md / docs/LICENSES.md). It lives in its own
directory so it can be swapped wholesale for self-owned assets without touching any code.

Usage
-----
    python3 Tools/prepare_dataset.py --source /path/to/exercises-dataset [--skip-media]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

LANGUAGES = ["en", "es", "it", "tr", "ru", "zh", "hi", "pl", "ko", "fr"]

REQUIRED_FIELDS = [
    "id", "name", "category", "body_part", "equipment", "instructions",
    "instruction_steps", "muscle_group", "secondary_muscles", "target",
    "media_id", "image", "gif_url", "attribution", "created_at",
]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(REPO_ROOT, "GymApp", "Resources")
DATASET_OUT = os.path.join(RESOURCES, "ExerciseDataset")
MEDIA_OUT = os.path.join(RESOURCES, "ExerciseMedia")
DOCS_OUT = os.path.join(REPO_ROOT, "docs")


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def audit(records: list[dict], source: str) -> tuple[list[str], list[str], dict]:
    """Returns (errors, warnings, stats). Errors are records the app must reject."""
    errors: list[str] = []
    warnings: list[str] = []

    seen_ids: set[str] = set()
    seen_media: set[str] = set()
    name_index: dict[str, list[str]] = defaultdict(list)

    for idx, rec in enumerate(records):
        rid = rec.get("id", f"<index {idx}>")

        for field in REQUIRED_FIELDS:
            if field not in rec:
                errors.append(f"{rid}: missing required field '{field}'")

        if not isinstance(rec.get("id"), str) or not rec.get("id", "").isdigit():
            errors.append(f"{rid}: id is not a numeric string")
        elif rec["id"] in seen_ids:
            errors.append(f"{rid}: duplicate id")
        else:
            seen_ids.add(rec["id"])

        media_id = rec.get("media_id")
        if media_id in seen_media:
            errors.append(f"{rid}: duplicate media_id '{media_id}'")
        elif media_id:
            seen_media.add(media_id)

        if not rec.get("name", "").strip():
            errors.append(f"{rid}: empty name")
        else:
            name_index[rec["name"].strip().lower()].append(rid)

        for path_field, expected_dir, expected_ext in (
            ("image", "images", (".jpg", ".jpeg", ".png")),
            ("gif_url", "videos", (".gif",)),
        ):
            rel = rec.get(path_field, "")
            if not rel.startswith(expected_dir + "/"):
                errors.append(f"{rid}: {path_field} '{rel}' is outside '{expected_dir}/'")
                continue
            if not rel.lower().endswith(expected_ext):
                errors.append(f"{rid}: {path_field} '{rel}' has an unexpected extension")
                continue
            absolute = os.path.join(source, rel)
            if not os.path.isfile(absolute):
                errors.append(f"{rid}: {path_field} '{rel}' does not exist on disk")
            elif os.path.getsize(absolute) == 0:
                errors.append(f"{rid}: {path_field} '{rel}' is a zero-byte file")

        instructions = rec.get("instructions", {}) or {}
        steps = rec.get("instruction_steps", {}) or {}
        for lang in LANGUAGES:
            if not str(instructions.get(lang, "")).strip():
                errors.append(f"{rid}: instructions.{lang} is empty")
            if not steps.get(lang):
                errors.append(f"{rid}: instruction_steps.{lang} is empty")
        step_counts = {len(v) for v in steps.values() if isinstance(v, list)}
        if len(step_counts) > 1:
            warnings.append(f"{rid}: step counts differ across languages {sorted(step_counts)}")

        extra_langs = (set(instructions) | set(steps)) - set(LANGUAGES)
        if extra_langs:
            warnings.append(f"{rid}: unknown language codes {sorted(extra_langs)}")

        if not rec.get("secondary_muscles"):
            warnings.append(f"{rid}: no secondary muscles listed")
        if not str(rec.get("attribution", "")).strip():
            errors.append(f"{rid}: empty attribution — media attribution is mandatory")
        if rec.get("category") != rec.get("body_part"):
            warnings.append(
                f"{rid}: category '{rec.get('category')}' != body_part '{rec.get('body_part')}'"
            )

    for name, ids in sorted(name_index.items()):
        if len(ids) > 1:
            warnings.append(f"duplicate name '{name}' shared by ids {', '.join(ids)}")

    # Orphan media (present on disk, referenced by nobody).
    for folder, field in (("images", "image"), ("videos", "gif_url")):
        folder_path = os.path.join(source, folder)
        if not os.path.isdir(folder_path):
            errors.append(f"source folder '{folder}' is missing")
            continue
        on_disk = {f for f in os.listdir(folder_path) if not f.startswith(".")}
        referenced = {os.path.basename(r.get(field, "")) for r in records}
        for orphan in sorted(on_disk - referenced):
            warnings.append(f"orphan file {folder}/{orphan} is referenced by no record")

    stats = {
        "total": len(records),
        "bodyParts": dict(Counter(r.get("body_part") for r in records).most_common()),
        "equipment": dict(Counter(r.get("equipment") for r in records).most_common()),
        "targets": dict(Counter(r.get("target") for r in records).most_common()),
        "muscleGroups": dict(Counter(r.get("muscle_group") for r in records).most_common()),
        "secondaryMuscles": dict(
            Counter(m for r in records for m in r.get("secondary_muscles", [])).most_common()
        ),
        "languages": LANGUAGES,
    }
    return errors, warnings, stats


def write_json(path: str, payload) -> int:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    return os.path.getsize(path)


def copy_media(records: list[dict], source: str) -> dict:
    thumbs = os.path.join(MEDIA_OUT, "thumbnails")
    anims = os.path.join(MEDIA_OUT, "animations")
    for folder in (thumbs, anims):
        os.makedirs(folder, exist_ok=True)

    copied = {"thumbnails": 0, "animations": 0, "thumbnailsBytes": 0, "animationsBytes": 0}
    keep_thumbs, keep_anims = set(), set()

    for rec in records:
        for rel, dest_dir, key, keep in (
            (rec["image"], thumbs, "thumbnails", keep_thumbs),
            (rec["gif_url"], anims, "animations", keep_anims),
        ):
            filename = os.path.basename(rel)
            keep.add(filename)
            src = os.path.join(source, rel)
            dst = os.path.join(dest_dir, filename)
            if not (os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src)):
                shutil.copy2(src, dst)
            copied[key] += 1
            copied[key + "Bytes"] += os.path.getsize(dst)

    # Prune stale media so a shrinking dataset does not leave dead weight in the bundle.
    for folder, keep in ((thumbs, keep_thumbs), (anims, keep_anims)):
        for existing in os.listdir(folder):
            if existing.startswith("."):
                continue
            if existing not in keep:
                os.remove(os.path.join(folder, existing))
    return copied


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Path to a checkout of exercises-dataset")
    parser.add_argument("--skip-media", action="store_true", help="Only regenerate the JSON payloads")
    parser.add_argument("--strict", action="store_true", help="Fail the run when warnings are present")
    args = parser.parse_args()

    source = os.path.abspath(args.source)
    dataset_path = os.path.join(source, "data", "exercises.json")
    if not os.path.isfile(dataset_path):
        print(f"error: {dataset_path} not found", file=sys.stderr)
        return 2

    with open(dataset_path, encoding="utf-8") as fh:
        records = json.load(fh)
    records.sort(key=lambda r: int(r["id"]))

    errors, warnings, stats = audit(records, source)

    # A defective record must never reach the app. Drop it here, loudly, rather than letting the
    # importer discover the problem on a user's device.
    bad_ids = {e.split(":")[0] for e in errors}
    clean = [r for r in records if r.get("id") not in bad_ids]

    core = []
    instructions: dict[str, dict[str, list[str]]] = {lang: {} for lang in LANGUAGES}
    for rec in clean:
        core.append({
            "id": rec["id"],
            "name": rec["name"],
            "bodyPart": rec["body_part"],
            "equipment": rec["equipment"],
            "target": rec["target"],
            "muscleGroup": rec["muscle_group"],
            "secondaryMuscles": rec["secondary_muscles"],
            "mediaId": rec["media_id"],
            "thumbnail": os.path.basename(rec["image"]),
            "animation": os.path.basename(rec["gif_url"]),
            "attribution": rec["attribution"],
            "createdAt": rec["created_at"],
        })
        for lang in LANGUAGES:
            instructions[lang][rec["id"]] = rec["instruction_steps"][lang]

    core_bytes = write_json(os.path.join(DATASET_OUT, "exercises.core.json"), core)
    lang_bytes = {
        lang: write_json(
            os.path.join(DATASET_OUT, "instructions", f"instructions.{lang}.json"),
            instructions[lang],
        )
        for lang in LANGUAGES
    }

    media_stats = {} if args.skip_media else copy_media(clean, source)

    source_sha = sha256_of_file(dataset_path)
    manifest = {
        "schemaVersion": 1,
        "datasetVersion": source_sha[:12],
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sourceRepository": "https://github.com/hasaneyldrm/exercises-dataset",
        "sourceChecksum": source_sha,
        "exerciseCount": len(core),
        "languages": LANGUAGES,
        "mediaAttribution": "© Gym visual — https://gymvisual.com/",
        "mediaLicense": "Proprietary — see docs/LICENSES.md and NOTICE.md. Not covered by MIT.",
        "mediaResolution": "180x180",
        "files": {
            "core": {"path": "exercises.core.json", "bytes": core_bytes},
            "instructions": {
                lang: {"path": f"instructions/instructions.{lang}.json", "bytes": size}
                for lang, size in lang_bytes.items()
            },
        },
        "media": media_stats,
        "audit": {"errors": len(errors), "warnings": len(warnings), "rejectedRecords": sorted(bad_ids)},
    }
    write_json(os.path.join(DATASET_OUT, "dataset-manifest.json"), manifest)

    os.makedirs(DOCS_OUT, exist_ok=True)
    report = [
        "# Exercise Dataset Audit",
        "",
        "> Generated by `Tools/prepare_dataset.py`. Re-run it after every dataset upgrade.",
        "",
        f"- Source: `{manifest['sourceRepository']}`",
        f"- Source checksum (SHA-256): `{source_sha}`",
        f"- Dataset version: `{manifest['datasetVersion']}`",
        f"- Generated: {manifest['generatedAt']}",
        "",
        "## Result",
        "",
        f"| Records in source | {len(records)} |",
        "|---|---|",
        f"| Records accepted | {len(clean)} |",
        f"| Records rejected | {len(records) - len(clean)} |",
        f"| Blocking errors | {len(errors)} |",
        f"| Warnings | {len(warnings)} |",
        f"| Languages | {len(LANGUAGES)} |",
        "",
        "## Payload sizes",
        "",
        "| File | Bytes |",
        "|---|---|",
        f"| `exercises.core.json` | {core_bytes:,} |",
    ]
    for lang, size in lang_bytes.items():
        report.append(f"| `instructions/instructions.{lang}.json` | {size:,} |")
    if media_stats:
        report += [
            "",
            "## Media",
            "",
            "| Asset | Count | Bytes |",
            "|---|---|---|",
            f"| Thumbnails (JPEG 180x180) | {media_stats['thumbnails']} | {media_stats['thumbnailsBytes']:,} |",
            f"| Animations (GIF 180x180) | {media_stats['animations']} | {media_stats['animationsBytes']:,} |",
            "",
            "Media is © Gym visual — https://gymvisual.com/ and is **not** covered by the dataset's",
            "MIT license. See `docs/LICENSES.md`.",
        ]

    report += ["", "## Distributions", ""]
    for title, key in (
        ("Body part", "bodyParts"), ("Equipment", "equipment"),
        ("Target muscle", "targets"), ("Muscle group", "muscleGroups"),
        ("Secondary muscles", "secondaryMuscles"),
    ):
        report += [f"### {title}", "", "| Value | Count |", "|---|---|"]
        report += [f"| `{k}` | {v} |" for k, v in stats[key].items()]
        report.append("")

    if errors:
        report += ["## Blocking errors", ""] + [f"- {e}" for e in errors] + [""]
    if warnings:
        report += [
            "## Warnings",
            "",
            "Warnings are informational: the app ingests these records normally.",
            "",
        ] + [f"- {w}" for w in warnings] + [""]

    with open(os.path.join(DOCS_OUT, "DATASET_AUDIT.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(report))

    print(f"accepted {len(clean)}/{len(records)} records · {len(errors)} errors · {len(warnings)} warnings")
    print(f"core={core_bytes:,}B  instructions={sum(lang_bytes.values()):,}B")
    if media_stats:
        print(f"media: {media_stats['thumbnails']} thumbnails, {media_stats['animations']} animations")
    print("report -> docs/DATASET_AUDIT.md")

    if errors:
        return 1
    if warnings and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
