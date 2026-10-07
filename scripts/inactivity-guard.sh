#!/usr/bin/env bash
# Scheduled-workflow inactivity guard (REL-9, tech spec 12.6, ADR-0010).
#
# GitHub disables scheduled workflows in a public repository after 60 days
# without repository activity, which would silence the daily testflight-expiry
# alert. This reads the committer date of the latest commit on the default
# branch and, once it is INACTIVITY_DAYS old (default 50, so there are about ten
# days to react), opens a GitHub issue labelled `workflow-inactivity` unless one
# is already open. The fix is for a person to push a commit or, if the schedule
# is already off, run `gh workflow enable testflight-expiry.yml`. This script
# never commits or pushes.
#
# Alert only: no secrets. The workflow supplies a per-run GITHUB_TOKEN as
# GH_TOKEN (permissions: contents read, issues write).
#
# Env:
#   INACTIVITY_DAYS  warn when the latest commit is this many days old or more
#                    (default 50; an empty value also means 50)
#   GH_TOKEN         read by `gh`; GH_REPO ("owner/name") selects the repo
#                    (else the git remote of the current directory)
#
# Works with GNU date (ubuntu runner) and BSD date (macOS). All GitHub access
# goes through `gh`, so tests can put a stub `gh` first on PATH.
set -euo pipefail

LABEL='workflow-inactivity'
GITHUB_DISABLE_DAYS=60
DAY=86400

inactivity_days="${INACTIVITY_DAYS:-50}"
case "$inactivity_days" in
  '' | *[!0-9]*)
    echo "::error::INACTIVITY_DAYS must be a non-negative integer, got '$inactivity_days'" >&2
    exit 2
    ;;
esac

# Epoch seconds -> YYYY-MM-DD in UTC. GNU `date -d @N`, else BSD `date -r N`
# (GNU's -r takes a file, so GNU must be tried first).
format_date() {
  date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F
}

# `gh api` does not read GH_REPO, so name the repo in the path. Without it, gh
# fills {owner}/{repo} from the git remote. With no `sha` parameter the commits
# endpoint starts from the repository's default branch.
repo="${GH_REPO:-}"
if [ -z "$repo" ]; then
  repo='{owner}/{repo}'
fi
last_epoch="$(gh api "repos/$repo/commits?per_page=1" \
  --jq '.[0].commit.committer.date | fromdateiso8601')"
case "$last_epoch" in
  '' | *[!0-9]*)
    echo "::error::Could not read the latest commit date, got '$last_epoch'" >&2
    exit 1
    ;;
esac

now="$(date +%s)"
age_seconds=$((now - last_epoch))
age_days=$((age_seconds / DAY))
last_date="$(format_date "$last_epoch")"
echo "Latest commit on the default branch is from $last_date; days since: $age_days."

if [ "$age_seconds" -lt $((inactivity_days * DAY)) ]; then
  echo "Less than $inactivity_days days of inactivity; nothing to do."
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
  gh label create "$LABEL" --color D93F0B \
    --description 'No repository activity; GitHub may disable the scheduled expiry alert'
fi

disable_date="$(format_date $((last_epoch + GITHUB_DISABLE_DAYS * DAY)))"
title="No commits to main for $age_days days; GitHub disables scheduled workflows at $GITHUB_DISABLE_DAYS"
body="$(
  cat <<EOF
The latest commit on the default branch is from **$last_date**, $age_days days ago. GitHub disables scheduled workflows in a public repository after $GITHUB_DISABLE_DAYS days without repository activity, which would be about **$disable_date**. The daily \`testflight-expiry\` workflow would then stop running, and a TestFlight build could expire with no alert.

To keep it running, push a commit to \`main\` (merge any small change through a pull request). That is the fix; CI never makes commits for this.

If the schedule is already off (the \`testflight-expiry\` workflow shows "disabled" in the Actions tab, or \`gh workflow list --all\`), turn it back on:

\`\`\`bash
gh workflow enable testflight-expiry.yml
\`\`\`

See docs/runbooks/testflight-release.md (section 4).

Opened by the scheduled \`testflight-expiry\` workflow. Close this issue once there is a new commit on \`main\`.
EOF
)"
gh issue create --title "$title" --body "$body" --label "$LABEL"
echo "Opened a '$LABEL' issue after $age_days days of inactivity."
