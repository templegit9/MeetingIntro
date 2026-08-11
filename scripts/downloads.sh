#!/usr/bin/env bash
# scripts/downloads.sh — how many people are actually installing MeetingIntro.
#
# Homebrew's own analytics DON'T cover third-party taps (only homebrew/core and
# homebrew/cask are collected), so there is no `brew info --analytics` number for
# this cask. The closest proxies are both GitHub-side:
#
#   1. Release asset downloads — the cask fetches the .zip from GitHub Releases, so
#      each `brew install` / `brew upgrade` of a version is one download. Cached
#      re-installs don't re-download, and your own release testing IS counted.
#   2. Tap clones — `brew install --cask templegit9/tap/meetingintro` git-clones the
#      tap, so unique clones ≈ people adding the tap for the first time.
#
# GitHub keeps traffic (clones) for a 14-DAY WINDOW ONLY and will not backfill it,
# which is why --snapshot exists: run it periodically and the history is yours.
#
# Usage:
#   scripts/downloads.sh              # table + totals + tap traffic
#   scripts/downloads.sh --snapshot   # ...and append one row to the history CSV
#   scripts/downloads.sh --history    # print the history CSV collected so far
#
# Requires: gh (authenticated). No jq needed — gh's built-in --jq does the work.

set -euo pipefail

REPO="${MEETINGINTRO_REPO:-templegit9/MeetingIntro}"
TAP_REPO="${MEETINGINTRO_TAP_REPO:-templegit9/homebrew-tap}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HISTORY="$REPO_ROOT/metrics/downloads-history.csv"

MODE="${1:-report}"

if [[ "$MODE" == "--history" ]]; then
    if [[ -f "$HISTORY" ]]; then cat "$HISTORY"; else echo "No history yet — run: $0 --snapshot"; fi
    exit 0
fi

command -v gh >/dev/null || { echo "gh CLI not found — brew install gh" >&2; exit 1; }

# tag <tab> published_at <tab> zip downloads
RELEASES="$(gh api "repos/$REPO/releases" --paginate \
    --jq '.[] | [.tag_name, .published_at, ([.assets[] | select(.name | endswith(".zip")) | .download_count] | add // 0)] | @tsv')"

printf '\n\033[1m%-12s %-12s %8s %7s   %s\033[0m\n' "VERSION" "PUBLISHED" "DOWNLOADS" "DAYS" "PER DAY"
printf '%s\n' "-------------------------------------------------------------"

TOTAL=0
LATEST_TAG=""
LATEST_COUNT=0
NOW_EPOCH="$(date +%s)"

while IFS=$'\t' read -r tag published count; do
    [[ -z "$tag" ]] && continue
    pub_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$published" +%s 2>/dev/null || echo "$NOW_EPOCH")"
    days=$(( (NOW_EPOCH - pub_epoch) / 86400 ))
    [[ $days -lt 1 ]] && days=1
    per_day="$(awk -v c="$count" -v d="$days" 'BEGIN { printf "%.1f", c / d }')"
    printf '%-12s %-12s %8s %7s   %s\n' "$tag" "${published%%T*}" "$count" "$days" "$per_day"
    TOTAL=$(( TOTAL + count ))
    if [[ -z "$LATEST_TAG" ]]; then LATEST_TAG="$tag"; LATEST_COUNT="$count"; fi
done <<< "$RELEASES"

printf '%s\n' "-------------------------------------------------------------"
printf '\033[1m%-12s %-12s %8s\033[0m\n\n' "TOTAL" "" "$TOTAL"

# Tap traffic — needs push access on the tap repo; degrade gracefully without it.
CLONES="$(gh api "repos/$TAP_REPO/traffic/clones" --jq '[.count, .uniques] | @tsv' 2>/dev/null || echo -e "\t")"
CLONE_COUNT="$(printf '%s' "$CLONES" | cut -f1)"
CLONE_UNIQUES="$(printf '%s' "$CLONES" | cut -f2)"
if [[ -n "$CLONE_COUNT" ]]; then
    echo "Tap clones (last 14 days): $CLONE_COUNT total, $CLONE_UNIQUES unique  ← new installs"
else
    echo "Tap clones: unavailable (traffic needs push access on $TAP_REPO)"
fi

cat <<'NOTE'

Reading these honestly:
  · Downloads ≠ people. One download per install/upgrade of a version; a cached
    re-install doesn't count again, and your own release testing does.
  · Older releases accumulate more simply by having been current longer — the
    PER DAY column is the fairer comparison.
  · The app self-updates by running `brew upgrade`, so the newest version's count
    keeps climbing for days after you ship it.
  · Nothing here measures retention. Homebrew can't tell you that.
NOTE

if [[ "$MODE" == "--snapshot" ]]; then
    mkdir -p "$(dirname "$HISTORY")"
    if [[ ! -f "$HISTORY" ]]; then
        echo "date,total_downloads,latest_tag,latest_downloads,tap_clones_14d,tap_uniques_14d" > "$HISTORY"
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$TOTAL,$LATEST_TAG,$LATEST_COUNT,${CLONE_COUNT:-},${CLONE_UNIQUES:-}" >> "$HISTORY"
    echo "Appended a snapshot to ${HISTORY#$REPO_ROOT/}"
fi
