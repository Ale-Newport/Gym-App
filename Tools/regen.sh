#!/bin/bash
# regen.sh — Regenerates GymApp.xcodeproj under a lock.
#
# The project is generated from project.yml, so every added or removed file needs an `xcodegen
# generate`. When several people (or several agents) work in the repository at once, two concurrent
# generates race on the same .xcodeproj and can leave it corrupt. `mkdir` is atomic on every POSIX
# filesystem, so it makes a serviceable mutex without any extra tooling.
#
# Usage: Tools/regen.sh
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK=".xcodegen.lock"
TIMEOUT=180
WAITED=0

while ! mkdir "$LOCK" 2>/dev/null; do
    if [ "$WAITED" -ge "$TIMEOUT" ]; then
        # A crashed run can leave the lock behind; after the timeout, take it.
        echo "regen.sh: lock held for ${TIMEOUT}s, assuming it is stale and taking it" >&2
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || true
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

trap 'rm -rf "$LOCK"' EXIT
xcodegen generate
