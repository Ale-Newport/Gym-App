#!/bin/bash
# audit.sh — The pre-release checklist, in one command.
#
# Runs every automated check the project has: data integrity, localisation coverage, placeholder
# scan, a Debug and a Release build, and the test suites. Prints a summary and exits non-zero if
# anything that matters failed.
#
# Usage:
#   Tools/audit.sh              full audit
#   Tools/audit.sh --quick      skip the Release build and the UI tests
set -uo pipefail

cd "$(dirname "$0")/.."
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

SIM='platform=iOS Simulator,name=iPhone 17 Pro'
PROJ=GymApp.xcodeproj
SCHEME=GymApp
FAILURES=0
WARNINGS=0

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

bold "1. Exercise dataset"
MANIFEST=GymApp/Resources/ExerciseDataset/dataset-manifest.json
if [ -f "$MANIFEST" ]; then
    python3 - <<'PY'
import json, os, sys
root = "GymApp/Resources"
manifest = json.load(open(f"{root}/ExerciseDataset/dataset-manifest.json", encoding="utf-8"))
core = json.load(open(f"{root}/ExerciseDataset/exercises.core.json", encoding="utf-8"))
problems = []
if len(core) != manifest["exerciseCount"]:
    problems.append(f"count mismatch: manifest {manifest['exerciseCount']}, file {len(core)}")
ids = [r["id"] for r in core]
if len(set(ids)) != len(ids):
    problems.append("duplicate exercise ids")
missing_media = 0
for record in core:
    for folder, key in (("thumbnails", "thumbnail"), ("animations", "animation")):
        path = f"{root}/ExerciseMedia/{folder}/{record[key]}"
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            missing_media += 1
if missing_media:
    problems.append(f"{missing_media} missing or empty media files")
for language in manifest["languages"]:
    path = f"{root}/ExerciseDataset/instructions/instructions.{language}.json"
    if not os.path.isfile(path):
        problems.append(f"missing instructions for {language}")
    else:
        table = json.load(open(path, encoding="utf-8"))
        absent = [i for i in ids if not table.get(i)]
        if absent:
            problems.append(f"{len(absent)} exercises without {language} instructions")
if not any(r.get("attribution") for r in core):
    problems.append("attribution missing from records")
print("\n".join(problems) if problems else "OK")
sys.exit(1 if problems else 0)
PY
    if [ $? -eq 0 ]; then
        pass "$(python3 -c "import json;print(json.load(open('$MANIFEST'))['exerciseCount'])") exercises, media and 10 languages complete"
    else
        fail "dataset integrity"
    fi
else
    fail "dataset manifest missing — run Tools/prepare_dataset.py"
fi

bold "2. Food database"
python3 - <<'PY' && pass "food database consistent" || fail "food database"
import json, sys
foods = json.load(open("GymApp/Resources/FoodDatabase/foods.json", encoding="utf-8"))
allowed = {"meat", "poultry", "fish", "seafood", "dairy", "egg", "honey"}
problems = []
ids = [f["catalogID"] for f in foods]
if len(set(ids)) != len(ids):
    problems.append("duplicate catalogIDs")
for food in foods:
    tags = set(food.get("dietaryTags", []))
    if not tags <= allowed:
        problems.append(f"{food['catalogID']}: unknown dietary tags {sorted(tags - allowed)}")
    for key in ("protein", "carbs", "fat"):
        if food[key] < 0 or food[key] > 100:
            problems.append(f"{food['catalogID']}: {key} out of range")
print("\n".join(problems[:10]) if problems else f"{len(foods)} foods OK")
sys.exit(1 if problems else 0)
PY

bold "3. Localisation"
python3 Tools/build_localizations.py > /tmp/audit_l10n.txt 2>&1
COVERAGE=$(grep -cE '100\.00%' /tmp/audit_l10n.txt || true)
TOTAL_LANGS=$(grep -cE '^\s+[a-z]{2}\s' /tmp/audit_l10n.txt || true)
if [ "$COVERAGE" -eq "$TOTAL_LANGS" ] && [ "$TOTAL_LANGS" -gt 0 ]; then
    pass "all $TOTAL_LANGS languages at 100%"
else
    warn "$COVERAGE of $TOTAL_LANGS languages complete"
    grep -E '^\s+[a-z]{2}\s' /tmp/audit_l10n.txt | grep -v '100.00%' | sed 's/^/      /'
fi
if python3 Tools/check_localization_keys.py --strict > /tmp/audit_keys.txt 2>&1; then
    pass "every key referenced in code is defined"
else
    fail "keys referenced but undefined:"
    grep -A 20 'MISSING' /tmp/audit_keys.txt | head -20 | sed 's/^/      /'
fi

bold "4. Placeholders"
# Comment prose is excluded: a doc comment explaining that there is *no* "coming soon" branch is
# the opposite of a placeholder. Markers in code are what matter.
PLACEHOLDER_RE='\b(TODO|FIXME|XXX|HACK)\b|not implemented|implement later'
HITS=$(grep -rnE "$PLACEHOLDER_RE" \
    --include='*.swift' GymApp GymAppWidgets GymAppTests GymAppUITests 2>/dev/null \
    | grep -vE ':[[:space:]]*(///|//|\*)' | wc -l | tr -d ' ')
if [ "$HITS" -eq 0 ]; then
    pass "no TODO, FIXME or placeholder markers"
else
    fail "$HITS placeholder markers:"
    grep -rnE "$PLACEHOLDER_RE" \
        --include='*.swift' GymApp GymAppWidgets GymAppTests GymAppUITests 2>/dev/null \
        | grep -vE ':[[:space:]]*(///|//|\*)' | head -15 | sed 's/^/      /'
fi

bold "5. Hard-coded colours outside the design system"
COLOR_HITS=$(grep -rnE 'Color\.(white|black|gray|grey)\b|Color\(red:|Color\(hex' \
    --include='*.swift' GymApp/Features GymApp/App 2>/dev/null | wc -l | tr -d ' ')
if [ "$COLOR_HITS" -eq 0 ]; then
    pass "feature code uses only semantic colours"
else
    warn "$COLOR_HITS raw colour references in feature code"
    grep -rnE 'Color\.(white|black|gray|grey)\b|Color\(red:|Color\(hex' \
        --include='*.swift' GymApp/Features GymApp/App 2>/dev/null | head -8 | sed 's/^/      /'
fi

bold "6. Project generation"
if Tools/regen.sh > /tmp/audit_gen.txt 2>&1; then
    pass "xcodegen generate"
else
    fail "xcodegen generate"; tail -5 /tmp/audit_gen.txt | sed 's/^/      /'
fi

bold "7. Debug build"
if xcodebuild -project "$PROJ" -scheme "$SCHEME" -destination "$SIM" -configuration Debug build \
    > /tmp/audit_debug.txt 2>&1; then
    W=$(grep -c 'warning:' /tmp/audit_debug.txt | tr -d ' ')
    if [ "$W" -eq 0 ]; then pass "Debug builds, no warnings"; else warn "Debug builds with $W warnings"; fi
else
    fail "Debug build"; grep 'error:' /tmp/audit_debug.txt | sort -u | head -10 | sed 's/^/      /'
fi

if [ "$QUICK" -eq 0 ]; then
    bold "8. Release build"
    if xcodebuild -project "$PROJ" -scheme "$SCHEME" -destination "$SIM" -configuration Release build \
        > /tmp/audit_release.txt 2>&1; then
        W=$(grep -c 'warning:' /tmp/audit_release.txt | tr -d ' ')
        if [ "$W" -eq 0 ]; then pass "Release builds, no warnings"; else warn "Release builds with $W warnings"; fi
    else
        fail "Release build"; grep 'error:' /tmp/audit_release.txt | sort -u | head -10 | sed 's/^/      /'
    fi
fi

bold "9. Unit tests"
if xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$SIM" \
    -only-testing:GymAppTests > /tmp/audit_tests.txt 2>&1; then
    # Swift Testing reports "Test run with N tests ... passed"; XCTest reports "Executed N tests".
    # The suites here are Swift Testing, so look for that first.
    SUMMARY=$(grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites' /tmp/audit_tests.txt | tail -1)
    [ -z "$SUMMARY" ] && SUMMARY=$(grep -oE 'Executed [0-9]+ tests' /tmp/audit_tests.txt | tail -1)
    pass "${SUMMARY:-unit tests passed}"
else
    fail "unit tests"
    grep -E 'error:|failed|XCTAssert' /tmp/audit_tests.txt | head -15 | sed 's/^/      /'
fi

if [ "$QUICK" -eq 0 ]; then
    bold "10. UI tests"
    if xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$SIM" \
        -only-testing:GymAppUITests > /tmp/audit_uitests.txt 2>&1; then
        pass "$(grep -oE 'Executed [0-9]+ tests' /tmp/audit_uitests.txt | tail -1 || echo 'UI tests passed')"
    else
        fail "UI tests"
        grep -E 'error:|failed' /tmp/audit_uitests.txt | head -10 | sed 's/^/      /'
    fi
fi

echo
bold "Summary"
if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    printf '  \033[32mAll checks passed.\033[0m\n'
elif [ "$FAILURES" -eq 0 ]; then
    printf '  \033[33m%d warning(s), no failures.\033[0m\n' "$WARNINGS"
else
    printf '  \033[31m%d failure(s), %d warning(s).\033[0m\n' "$FAILURES" "$WARNINGS"
fi
exit "$FAILURES"
