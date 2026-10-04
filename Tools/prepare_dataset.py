#!/usr/bin/env python3
"""
prepare_dataset.py — Builds the exercise catalogue bundled inside GymApp from the Gym avatar project
(Fitness Athlete Generator, `../Gym avatar/fitness-athlete-generator`).

What ships
----------
Only the exercises the avatar project has signed off: `output/qa/priority-500.json`, the 500
distinct exercises with image-bound visual review evidence (its own `verify_priority_500.py` checks
the same file). Nothing unreviewed is ever used to fill the list.

Where each part comes from
--------------------------
* Records (name, body part, equipment, muscles) and the ten-language instructions: the upstream
  `hasaneyldrm/exercises-dataset` (MIT), read from the avatar project's pinned copy at
  `data/external/exercises.json`. Every avatar exercise carries the upstream id as a suffix
  (`push_up_0662`) or through an explicit alias (`barbell_bench_press` → `barbell_bench_press_0025`),
  so the app keeps the same stable ids it has always used and no saved workout changes meaning.
* English and Spanish steps: the avatar project's, when it has them. They were written against the
  rendered motion, so they describe what the animation shows.
* Exercises with no upstream record: `Tools/exercise_additions.json`, ids from 9001.
* Media: rendered by the avatar project from its own athlete. Each animation is re-encoded from the
  reviewed GIF to an animated WebP (a twentieth of the GIF's size), each thumbnail is a JPEG of the
  middle rendered frame cropped to the area the movement covers.

Outputs
-------
    Resources/ExerciseDataset/exercises.core.json                     always loaded
    Resources/ExerciseDataset/instructions/instructions.<lang>.json   loaded lazily, per language
    Resources/ExerciseDataset/dataset-manifest.json                   version + integrity metadata
    Resources/ExerciseMedia/thumbnails/<id>.jpg
    Resources/ExerciseMedia/animations/<id>.webp
    docs/DATASET_AUDIT.md

Usage
-----
    python3 Tools/prepare_dataset.py [--avatar /path/to/fitness-athlete-generator] [--skip-media]

Needs Pillow built with WebP support (`python3 -c "from PIL import features; print(features.check('webp'))"`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timezone

LANGUAGES = ["en", "es", "it", "tr", "ru", "zh", "hi", "pl", "ko", "fr"]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.join(REPO_ROOT, "GymApp", "Resources")
DATASET_OUT = os.path.join(RESOURCES, "ExerciseDataset")
MEDIA_OUT = os.path.join(RESOURCES, "ExerciseMedia")
DOCS_OUT = os.path.join(REPO_ROOT, "docs")
ADDITIONS = os.path.join(REPO_ROOT, "Tools", "exercise_additions.json")
DEFAULT_AVATAR = os.path.join(os.path.dirname(REPO_ROOT), "Gym avatar", "fitness-athlete-generator")

SELECTION_SIZE = 500
UPSTREAM_REPOSITORY = "https://github.com/hasaneyldrm/exercises-dataset"
MEDIA_ATTRIBUTION = "Original 3D illustrations rendered by Gym avatar"
MEDIA_LICENSE = "Owned by the app's author. Rendered from an original athlete by the Gym avatar project."

# Media encoding. The source GIFs are 512–768 px with up to 145 frames; the app shows them at most
# screen-width and decodes every frame into memory, so they are scaled and their frame count capped.
ANIMATION_SIZE = 400
ANIMATION_QUALITY = 80
ANIMATION_MAX_FRAMES = 36
THUMBNAIL_SIZE = 240
THUMBNAIL_QUALITY = 82
# A pixel belongs to the athlete or his equipment when it differs from the backdrop by more than
# this; the soft floor shadow stays below it, so thumbnails crop to the figure, not the shadow.
CONTENT_THRESHOLD = 28
THUMBNAIL_MARGIN = 0.08


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: str, payload) -> int:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    return os.path.getsize(path)


# MARK: - Selection

def load_selection(avatar: str) -> tuple[list[dict], dict]:
    """The reviewed 500, refusing anything that is not fully reviewed."""
    selection = read_json(os.path.join(avatar, "output", "qa", "priority-500.json"))
    rows = selection["exercises"]
    unreviewed = [r["id"] for r in rows if not r.get("reviewed")]
    if len(rows) != SELECTION_SIZE or selection.get("remaining") != 0 or unreviewed:
        raise SystemExit(
            f"error: priority-500.json lists {len(rows)} exercises, {len(unreviewed)} unreviewed "
            f"(remaining={selection.get('remaining')}). Run the avatar project's "
            "`scripts/build_priority_500.py --reviewed-only` first."
        )
    catalog = {e["id"]: e for e in read_json(os.path.join(avatar, "ui", "catalog.json"))["exercises"]}
    missing = [r["id"] for r in rows if r["id"] not in catalog]
    if missing:
        raise SystemExit(f"error: selected exercises missing from ui/catalog.json: {missing}")
    return rows, catalog


def upstream_ids(row: dict, upstream: dict) -> list[str]:
    """Upstream ids an avatar exercise stands for: its own suffix first, then its aliases'."""
    ids = []
    for ident in [row["id"]] + list(row.get("aliases", [])):
        match = re.search(r"_(\d{4})$", ident)
        if match and match.group(1) in upstream and match.group(1) not in ids:
            ids.append(match.group(1))
    return ids


# MARK: - Records

def audit(core: list[dict], instructions: dict[str, dict[str, list[str]]]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    seen: set[str] = set()
    names: dict[str, list[str]] = defaultdict(list)
    for rec in core:
        rid = rec["id"]
        if not rid.isdigit():
            errors.append(f"{rid}: id is not a numeric string")
        if rid in seen:
            errors.append(f"{rid}: duplicate id")
        seen.add(rid)
        if not rec["name"].strip():
            errors.append(f"{rid}: empty name")
        names[rec["name"].strip().lower()].append(rid)
        for lang in LANGUAGES:
            if not instructions[lang].get(rid):
                errors.append(f"{rid}: no {lang} instructions")
        if not rec["secondaryMuscles"]:
            warnings.append(f"{rid}: no secondary muscles listed")
    for name, ids in sorted(names.items()):
        if len(ids) > 1:
            warnings.append(f"duplicate name '{name}' shared by ids {', '.join(ids)}")
    return errors, warnings


def build_records(rows: list[dict], catalog: dict, upstream: dict, additions: dict):
    core: list[dict] = []
    instructions: dict[str, dict[str, list[str]]] = {lang: {} for lang in LANGUAGES}
    aliases: dict[str, str] = {}
    sources: dict[str, dict] = {}
    avatar_steps = 0

    for row in rows:
        avatar_id = row["id"]
        item = catalog[avatar_id]
        ids = upstream_ids(row, upstream)
        if ids:
            rid = ids[0]
            rec = upstream[rid]
            record = {
                "id": rid,
                "name": rec["name"],
                "bodyPart": rec["body_part"],
                "equipment": rec["equipment"],
                "target": rec["target"],
                "muscleGroup": rec["muscle_group"],
                "secondaryMuscles": rec["secondary_muscles"],
                "createdAt": rec["created_at"],
            }
            steps = {lang: rec["instruction_steps"][lang] for lang in LANGUAGES}
            # Other upstream records the avatar project merged into this one. Recorded in the audit;
            # they do not ship as separate exercises.
            for alias in ids[1:]:
                aliases[alias] = rid
        elif avatar_id in additions:
            addition = additions[avatar_id]
            rid = addition["id"]
            record = {k: addition[k] for k in
                      ("id", "name", "bodyPart", "equipment", "target", "muscleGroup", "secondaryMuscles", "createdAt")}
            steps = dict(addition["steps"])
        else:
            raise SystemExit(
                f"error: {avatar_id} has no upstream record and no entry in {os.path.relpath(ADDITIONS, REPO_ROOT)}"
            )

        rewritten = False
        for lang in ("en", "es"):
            own = (item.get("steps") or {}).get(lang)
            if own:
                rewritten |= own != steps.get(lang)
                steps[lang] = own
        avatar_steps += rewritten

        record.update({
            "mediaId": avatar_id,
            "thumbnail": f"{rid}.jpg",
            "animation": f"{rid}.webp",
            "attribution": MEDIA_ATTRIBUTION,
        })
        core.append(record)
        for lang in LANGUAGES:
            instructions[lang][rid] = steps[lang]
        sources[rid] = {"avatarId": avatar_id, "gif": item["gif"], "frames": item["render"]["frames"]}

    # An alias must never shadow a real record.
    for alias in [a for a in aliases if a in sources]:
        del aliases[alias]

    core.sort(key=lambda r: int(r["id"]))
    return core, instructions, dict(sorted(aliases.items())), sources, avatar_steps


# MARK: - Media

def _decode_gif(path: str):
    from PIL import Image
    frames, delays = [], []
    with Image.open(path) as gif:
        for index in range(gif.n_frames):
            gif.seek(index)
            frames.append(gif.convert("RGB"))
            delays.append(max(20, int(gif.info.get("duration", 100))))
    return frames, delays


def _whiten(image, background):
    """Stretches levels so the render's off-white backdrop becomes pure white and the artwork sits
    on the app's white cards without a visible square. The athlete brightens by the same ~1%."""
    level = min(background) if isinstance(background, tuple) else background
    if level >= 255 or level < 200:
        return image
    return image.point(lambda v: min(255, round(v * 255 / level)))


def _content_box(frames, background):
    """Union bounding box of everything that is not backdrop, across every frame."""
    from PIL import Image, ImageChops
    box = None
    for frame in frames:
        diff = ImageChops.difference(frame, Image.new("RGB", frame.size, background)).convert("L")
        b = diff.point(lambda v: 255 if v > CONTENT_THRESHOLD else 0).getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


def _square(box, size, margin):
    left, top, right, bottom = box
    side = max(right - left, bottom - top) * (1 + 2 * margin)
    side = min(size[0], size[1], max(side, 1))
    cx, cy = (left + right) / 2, (top + bottom) / 2
    x = min(max(cx - side / 2, 0), size[0] - side)
    y = min(max(cy - side / 2, 0), size[1] - side)
    return tuple(int(round(v)) for v in (x, y, x + side, y + side))


def encode_media(job: tuple[str, str, str, str, str]) -> tuple[str, int, int, int]:
    """Writes one exercise's animation and thumbnail. Returns (id, frames, animation bytes, thumb bytes)."""
    from PIL import Image
    rid, gif_path, still_path, animation_out, thumbnail_out = job

    frames, delays = _decode_gif(gif_path)
    background = frames[0].getpixel((1, 1))
    stride = max(1, -(-len(frames) // ANIMATION_MAX_FRAMES))
    kept, kept_delays = [], []
    for index in range(0, len(frames), stride):
        kept.append(_whiten(frames[index], background).resize((ANIMATION_SIZE, ANIMATION_SIZE), Image.LANCZOS))
        # The skipped frames' time is folded into the kept one, so a rep keeps its tempo.
        kept_delays.append(sum(delays[index:index + stride]))
    kept[0].save(animation_out, format="WEBP", save_all=True, append_images=kept[1:],
                 duration=kept_delays, loop=0, quality=ANIMATION_QUALITY, method=6)

    with Image.open(still_path) as raw:
        still = raw.convert("RGBA")
    flat = Image.new("RGBA", still.size, (255, 255, 255, 255))
    flat.alpha_composite(still)
    still = flat.convert("RGB")
    still = _whiten(still, still.getpixel((1, 1)))
    # The GIF and the still can differ in resolution; measure the movement in GIF space and scale.
    box = _content_box(frames, background)
    if box:
        scale = still.size[0] / frames[0].size[0]
        box = tuple(v * scale for v in box)
        still = still.crop(_square(box, still.size, THUMBNAIL_MARGIN))
    still.resize((THUMBNAIL_SIZE, THUMBNAIL_SIZE), Image.LANCZOS).save(
        thumbnail_out, format="JPEG", quality=THUMBNAIL_QUALITY, optimize=True, progressive=True)
    return rid, len(kept), os.path.getsize(animation_out), os.path.getsize(thumbnail_out)


def build_media(avatar: str, sources: dict[str, dict], jobs: int) -> dict:
    thumbs = os.path.join(MEDIA_OUT, "thumbnails")
    anims = os.path.join(MEDIA_OUT, "animations")
    for folder in (thumbs, anims):
        os.makedirs(folder, exist_ok=True)

    work = []
    for rid, src in sources.items():
        gif = os.path.join(avatar, src["gif"])
        frames = [os.path.join(avatar, f.split("?")[0]) for f in src["frames"]]
        missing = [p for p in [gif] + frames if not os.path.isfile(p)]
        if missing:
            raise SystemExit(f"error: {src['avatarId']}: missing rendered media {missing[:2]}")
        still = frames[len(frames) // 2]
        animation_out = os.path.join(anims, f"{rid}.webp")
        thumbnail_out = os.path.join(thumbs, f"{rid}.jpg")
        newest_source = max(os.path.getmtime(gif), os.path.getmtime(still), os.path.getmtime(__file__))
        if all(os.path.isfile(p) and os.path.getmtime(p) >= newest_source for p in (animation_out, thumbnail_out)):
            continue
        work.append((rid, gif, still, animation_out, thumbnail_out))

    print(f"encoding media for {len(work)} of {len(sources)} exercises…")
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        for done, (rid, _, _, _) in enumerate(pool.map(encode_media, work, chunksize=4), 1):
            if done % 50 == 0 or done == len(work):
                print(f"  {done}/{len(work)}")

    # Prune everything else, including any previous provider's files, so nothing unreviewed or
    # third-party is left in the bundle.
    keep_thumbs = {f"{rid}.jpg" for rid in sources}
    keep_anims = {f"{rid}.webp" for rid in sources}
    for folder, keep in ((thumbs, keep_thumbs), (anims, keep_anims)):
        for existing in os.listdir(folder):
            if not existing.startswith(".") and existing not in keep:
                os.remove(os.path.join(folder, existing))

    return {
        "thumbnails": len(keep_thumbs),
        "animations": len(keep_anims),
        "thumbnailsBytes": sum(os.path.getsize(os.path.join(thumbs, f)) for f in keep_thumbs),
        "animationsBytes": sum(os.path.getsize(os.path.join(anims, f)) for f in keep_anims),
    }


# MARK: - Main

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--avatar", default=DEFAULT_AVATAR, help="Path to the fitness-athlete-generator project")
    parser.add_argument("--skip-media", action="store_true", help="Only regenerate the JSON payloads")
    parser.add_argument("--strict", action="store_true", help="Fail the run when warnings are present")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="Parallel media encoders")
    args = parser.parse_args()

    avatar = os.path.abspath(args.avatar)
    upstream_path = os.path.join(avatar, "data", "external", "exercises.json")
    if not os.path.isfile(upstream_path):
        print(f"error: {upstream_path} not found — is --avatar the fitness-athlete-generator folder?", file=sys.stderr)
        return 2

    upstream = {r["id"]: r for r in read_json(upstream_path)}
    rows, catalog = load_selection(avatar)
    additions = {a["avatarId"]: a for a in read_json(ADDITIONS)["exercises"]}
    colliding = [a["id"] for a in additions.values() if a["id"] in upstream]
    if colliding:
        raise SystemExit(f"error: additions reuse upstream ids {colliding}")

    core, instructions, aliases, sources, avatar_steps = build_records(rows, catalog, upstream, additions)
    errors, warnings = audit(core, instructions)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    core_bytes = write_json(os.path.join(DATASET_OUT, "exercises.core.json"), core)
    lang_bytes = {
        lang: write_json(os.path.join(DATASET_OUT, "instructions", f"instructions.{lang}.json"), instructions[lang])
        for lang in LANGUAGES
    }

    media_stats = {} if args.skip_media else build_media(avatar, sources, args.jobs)
    if not media_stats:
        previous = os.path.join(DATASET_OUT, "dataset-manifest.json")
        media_stats = read_json(previous).get("media", {}) if os.path.isfile(previous) else {}

    upstream_sha = sha256_of_file(upstream_path)
    selection_sha = sha256_of_file(os.path.join(avatar, "output", "qa", "priority-500.json"))
    version = hashlib.sha256(
        (upstream_sha + selection_sha + sha256_of_file(os.path.join(DATASET_OUT, "exercises.core.json"))).encode()
    ).hexdigest()[:12]
    manifest = {
        "schemaVersion": 1,
        "datasetVersion": version,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sourceRepository": UPSTREAM_REPOSITORY,
        "sourceChecksum": upstream_sha,
        "selectionChecksum": selection_sha,
        "exerciseCount": len(core),
        "languages": LANGUAGES,
        "mediaAttribution": MEDIA_ATTRIBUTION,
        "mediaLicense": MEDIA_LICENSE,
        "mediaResolution": f"{ANIMATION_SIZE}x{ANIMATION_SIZE}",
        "files": {
            "core": {"path": "exercises.core.json", "bytes": core_bytes},
            "instructions": {
                lang: {"path": f"instructions/instructions.{lang}.json", "bytes": size}
                for lang, size in lang_bytes.items()
            },
        },
        "media": media_stats,
        "audit": {"errors": len(errors), "warnings": len(warnings), "rejectedRecords": []},
    }
    write_json(os.path.join(DATASET_OUT, "dataset-manifest.json"), manifest)

    write_report(manifest, core, aliases, warnings, avatar_steps, len(additions))

    print(f"{len(core)} exercises · {len(aliases)} merged upstream ids · {len(warnings)} warnings")
    print(f"core={core_bytes:,}B  instructions={sum(lang_bytes.values()):,}B")
    if media_stats:
        print(f"media: {media_stats['animations']} animations {media_stats['animationsBytes']:,}B, "
              f"{media_stats['thumbnails']} thumbnails {media_stats['thumbnailsBytes']:,}B")
    print("report -> docs/DATASET_AUDIT.md")
    return 1 if warnings and args.strict else 0


def write_report(manifest: dict, core: list[dict], aliases: dict, warnings: list[str],
                 avatar_steps: int, additions: int) -> None:
    media = manifest["media"]
    report = [
        "# Exercise Dataset Audit",
        "",
        "> Generated by `Tools/prepare_dataset.py`. Re-run it whenever the Gym avatar selection changes.",
        "",
        "The catalogue is the Gym avatar project's reviewed selection (`output/qa/priority-500.json`),",
        "illustrated with its own rendered athlete. Records and translations come from the upstream",
        f"dataset ({manifest['sourceRepository']}, MIT).",
        "",
        f"- Upstream checksum (SHA-256): `{manifest['sourceChecksum']}`",
        f"- Selection checksum (SHA-256): `{manifest['selectionChecksum']}`",
        f"- Dataset version: `{manifest['datasetVersion']}`",
        f"- Generated: {manifest['generatedAt']}",
        "",
        "## Result",
        "",
        f"| Exercises | {len(core)} |",
        "|---|---|",
        f"| From upstream records | {len(core) - additions} |",
        f"| Added (`Tools/exercise_additions.json`) | {additions} |",
        f"| English/Spanish steps rewritten by Gym avatar for the rendered motion | {avatar_steps} |",
        f"| Upstream ids merged into another exercise | {len(aliases)} |",
        f"| Warnings | {len(warnings)} |",
        "",
    ]
    if media:
        report += [
            "## Media",
            "",
            "| Asset | Count | Bytes |",
            "|---|---|---|",
            f"| Thumbnails (JPEG {THUMBNAIL_SIZE}×{THUMBNAIL_SIZE}) | {media['thumbnails']} | {media['thumbnailsBytes']:,} |",
            f"| Animations (animated WebP {ANIMATION_SIZE}×{ANIMATION_SIZE}, ≤{ANIMATION_MAX_FRAMES} frames) "
            f"| {media['animations']} | {media['animationsBytes']:,} |",
            "",
        ]
    for title, key in (("Body part", "bodyPart"), ("Equipment", "equipment"), ("Target muscle", "target")):
        report += [f"## {title}", "", "| Value | Count |", "|---|---|"]
        report += [f"| `{k}` | {v} |" for k, v in Counter(r[key] for r in core).most_common()]
        report.append("")
    if aliases:
        report += ["## Merged upstream ids", "",
                   "The avatar project treats these upstream records as the same exercise as another one,",
                   "so they are not shipped separately.", "",
                   "| Upstream id | Now |", "|---|---|"]
        report += [f"| `{old}` | `{new}` |" for old, new in aliases.items()]
        report.append("")
    if warnings:
        report += ["## Warnings", "", "Informational: the app ingests these records normally.", ""]
        report += [f"- {w}" for w in warnings] + [""]
    os.makedirs(DOCS_OUT, exist_ok=True)
    with open(os.path.join(DOCS_OUT, "DATASET_AUDIT.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(report))


if __name__ == "__main__":
    sys.exit(main())
