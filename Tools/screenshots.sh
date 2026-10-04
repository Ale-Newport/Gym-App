#!/usr/bin/env bash
#
# screenshots.sh — Generates the App Store screenshot set.
#
# App Store Connect validates screenshots by exact pixel size, per device class, and accepts a
# separate set per language. Taking them by hand does not survive the first copy change, so this
# drives `AppStoreScreenshotTests` (GymAppUITests) once per device and language and extracts the
# captures out of the result bundle.
#
#     Tools/screenshots.sh                     # required device sizes, English
#     Tools/screenshots.sh es                  # one language
#     Tools/screenshots.sh en es fr            # several
#     Tools/screenshots.sh --all-languages     # every language the app ships
#
# Output:
#
#     Screenshots/<device>/<language>/01-home.png …
#
# The language is selected by TEST NAME, not by an environment variable. Both env-var spellings
# were tried and both failed the same silent way — the run passes and every language folder fills
# with English — so `AppStoreScreenshotTests` has one method per language and this script picks one
# with `-only-testing`. Asking for Spanish and getting English is no longer expressible.
#
# Apple currently requires one iPhone size (6.9") and, because this app supports iPad, one iPad
# size (13"). Both are captured. Anything else App Store Connect will scale from these.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUTPUT_DIR="$REPO_ROOT/Screenshots"
DERIVED="${TMPDIR:-/tmp}/forge-screenshots-dd"

# Device class -> simulator name. The names must exist in `xcrun simctl list devices`.
#   iPhone 6.9"  1320 x 2868  — required
#   iPad   13"   2064 x 2752  — required while TARGETED_DEVICE_FAMILY includes iPad
DEVICES=(
  "iphone-6.9:iPhone 17 Pro Max"
  "ipad-13:iPad Pro 13-inch (M5)"
)

# Must match CFBundleLocalizations in project.yml, and each needs a matching test method in
# GymAppUITests/AppStoreScreenshotTests.swift.
ALL_LANGUAGES=(en es it tr ru zh-Hans hi pl ko fr)

# Language code -> the test method that captures it.
test_method_for() {
  case "$1" in
    en) echo testCaptureEnglish ;;
    es) echo testCaptureSpanish ;;
    it) echo testCaptureItalian ;;
    tr) echo testCaptureTurkish ;;
    ru) echo testCaptureRussian ;;
    zh-Hans) echo testCaptureChinese ;;
    hi) echo testCaptureHindi ;;
    pl) echo testCapturePolish ;;
    ko) echo testCaptureKorean ;;
    fr) echo testCaptureFrench ;;
    *) echo "" ;;
  esac
}

if [[ "${1:-}" == "--all-languages" ]]; then
  LANGUAGES=("${ALL_LANGUAGES[@]}")
elif [[ $# -gt 0 ]]; then
  LANGUAGES=("$@")
else
  LANGUAGES=(en)
fi

echo "Languages: ${LANGUAGES[*]}"
echo "Devices:   ${#DEVICES[@]}"
echo

command -v xcodegen >/dev/null || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

# The per-run logs are written here, so it has to exist before the first redirect.
mkdir -p "$DERIVED" "$OUTPUT_DIR"

for entry in "${DEVICES[@]}"; do
  slug="${entry%%:*}"
  device="${entry#*:}"

  # Fail early and loudly rather than after a five-minute build.
  if ! xcrun simctl list devices available | grep -qF "$device ("; then
    echo "!! Simulator '$device' is not available. Install it in Xcode > Settings > Components."
    echo "   Available iPhone/iPad simulators:"
    xcrun simctl list devices available | grep -E "iPhone|iPad" | sed 's/^/     /'
    exit 1
  fi

  for language in "${LANGUAGES[@]}"; do
    method="$(test_method_for "$language")"
    if [[ -z "$method" ]]; then
      echo "!! '$language' has no capture method. Add one to AppStoreScreenshotTests and map it here."
      exit 1
    fi
    echo "==> $device · $language ($method)"

    result="$DERIVED/$slug-$language.xcresult"
    rm -rf "$result"

    # `-only-testing` keeps the behavioural suites out of the run: they pin English and would
    # roughly quadruple the wall clock for no captures.
    xcodebuild test \
      -project GymApp.xcodeproj \
      -scheme GymApp \
      -destination "platform=iOS Simulator,name=$device" \
      -derivedDataPath "$DERIVED" \
      -resultBundlePath "$result" \
      -only-testing:"GymAppUITests/AppStoreScreenshotTests/$method" \
      > "$DERIVED/$slug-$language.log" 2>&1 || {
        echo "!! Run failed. Last 40 lines of $DERIVED/$slug-$language.log:"
        tail -40 "$DERIVED/$slug-$language.log"
        exit 1
      }

    staging="$DERIVED/$slug-$language-attachments"
    rm -rf "$staging"
    xcrun xcresulttool export attachments --path "$result" --output-path "$staging" >/dev/null

    destination="$OUTPUT_DIR/$slug/$language"
    rm -rf "$destination"
    mkdir -p "$destination"

    # The exporter writes opaque file names and a manifest that maps them back to the names the
    # test gave each attachment. Renaming through the manifest is what makes the output readable
    # and ordered.
    python3 - "$staging" "$destination" <<'PYTHON'
import json, os, re, shutil, sys

staging, destination = sys.argv[1], sys.argv[2]

# The exporter suffixes each attachment with "_<index>_<UUID>". Strip it so the set sorts and reads
# as 01-home.png … 08-settings.png rather than as a wall of hex.
SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f-]{36}$")
manifest_path = os.path.join(staging, "manifest.json")
if not os.path.exists(manifest_path):
    sys.exit(f"no manifest in {staging} — the run captured nothing")

with open(manifest_path) as handle:
    manifest = json.load(handle)

count = 0
for test in manifest:
    for attachment in test.get("attachments", []):
        exported = attachment.get("exportedFileName")
        name = attachment.get("suggestedHumanReadableName") or exported
        if not exported:
            continue
        source = os.path.join(staging, exported)
        if not os.path.exists(source):
            continue
        stem, extension = os.path.splitext(name)
        name = SUFFIX.sub("", stem) + (extension or ".png")
        shutil.copyfile(source, os.path.join(destination, name))
        count += 1

print(f"    {count} screenshots -> {destination}")
if count == 0:
    sys.exit("the run produced no screenshots")
PYTHON
  done
done

echo
echo "Done. Upload from $OUTPUT_DIR."
echo "Sizes captured:"
# One representative file per device folder — every shot in a folder is the same size, and listing
# all of them overflows the argument list.
for dir in "$OUTPUT_DIR"/*/; do
  shot="$(find "$dir" -name '*.png' | head -1)"
  [[ -n "$shot" ]] || continue
  size="$(sips -g pixelWidth -g pixelHeight "$shot" | awk '/pixel/ {printf "%s ", $2}')"
  count="$(find "$dir" -name '*.png' | wc -l | tr -d ' ')"
  echo "  $(basename "$dir"): ${size}px · $count files"
done
