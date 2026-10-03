#!/usr/bin/env bash
# TestFlight build-expiry alert (REL-9, tech spec 12.6, ADR-0010).
#
# Finds the newest `build-*` tag (the release lane pushes an annotated tag at
# upload, 12.3 step 9, so its date is the upload date), computes expiry as tag
# date + 90 days, and opens a GitHub issue labelled `testflight-expiry` when
# expiry is within THRESHOLD_DAYS and no such issue is already open.
#
# Alert only: no App Store Connect access, no secrets. The workflow supplies a
# per-run GITHUB_TOKEN as GH_TOKEN (permissions: contents read, issues write).
#
# Env:
#   THRESHOLD_DAYS  alert when expiry is this many days away or fewer
#                   (default 14; an empty value also means 14)
#   GH_TOKEN        read by `gh`; GH_REPO selects the repo (else the git remote)
#
# Run from inside a clone that has the tags (`git fetch --tags`). Works with
# GNU date (ubuntu runner) and BSD date (macOS). All GitHub access goes through
# `gh`, so tests can put a stub `gh` first on PATH.
set -euo pipefail

TAG_GLOB='build-*'
LABEL='testflight-expiry'
VALID_DAYS=90
DAY=86400

threshold_days="${THRESHOLD_DAYS:-14}"
case "$threshold_days" in
  '' | *[!0-9]*)
    echo "::error::THRESHOLD_DAYS must be a non-negative integer, got '$threshold_days'" >&2
    exit 2
    ;;
esac

# Epoch seconds -> YYYY-MM-DD in UTC. GNU `date -d @N`, else BSD `date -r N`
# (GNU's -r takes a file, so GNU must be tried first).
format_date() {
  date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F
}

# Newest build tag by creator date: "<tag> <epoch seconds>". For an annotated
# tag that is the tagger date, which is the upload date.
newest="$(git for-each-ref --sort=-creatordate --count=1 \
  --format='%(refname:strip=2) %(creatordate:unix)' "refs/tags/$TAG_GLOB")"
if [ -z "$newest" ]; then
  echo "No $TAG_GLOB tag found; nothing to check."
  exit 0
fi
tag="${newest% *}"
tag_epoch="${newest##* }"
build="${tag#build-}"

now="$(date +%s)"
expiry_epoch=$((tag_epoch + VALID_DAYS * DAY))
expiry_date="$(format_date "$expiry_epoch")"
uploaded_date="$(format_date "$tag_epoch")"
seconds_left=$((expiry_epoch - now))
echo "Newest tag $tag (uploaded $uploaded_date); build $build expires about $expiry_date."

if [ "$seconds_left" -gt $((threshold_days * DAY)) ]; then
  echo "Expiry is more than $threshold_days days away; nothing to do."
  exit 0
fi

open_issues="$(gh issue list --label "$LABEL" --state open --json number --jq 'length')"
if [ "$open_issues" -gt 0 ]; then
  echo "An issue labelled '$LABEL' is already open; not opening another."
  exit 0
fi

# Create the label on first use. `gh issue create --label` fails on a missing one.
if [ -z "$(gh label list --search "$LABEL" --json name --jq ".[] | select(.name == \"$LABEL\") | .name")" ]; then
  echo "Creating label '$LABEL'."
  gh label create "$LABEL" --color FBCA04 \
    --description 'TestFlight build is close to its 90-day expiry'
fi

if [ "$seconds_left" -lt 0 ]; then
  verb='expired'
else
  verb='expires'
fi
title="TestFlight build $build $verb about $expiry_date; run \`make testflight\` on the release Mac"
body="$(
  cat <<EOF
TestFlight build **$build** (tag \`$tag\`, uploaded $uploaded_date) $verb about **$expiry_date**, 90 days after upload. Testers lose the build then.

Upload a fresh build from the release Mac, from a clean \`main\` that equals \`origin/main\` with CI green:

\`\`\`bash
make testflight
\`\`\`

\`make testflight-status\` shows the exact expiry date. See docs/runbooks/testflight-release.md (section 4).

Opened by the scheduled \`testflight-expiry\` workflow, which infers the date from the \`$tag\` tag. Close this issue after the new build is uploaded.
EOF
)"
gh issue create --title "$title" --body "$body" --label "$LABEL"
echo "Opened a '$LABEL' issue for build $build."
