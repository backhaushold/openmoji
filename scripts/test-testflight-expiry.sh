#!/bin/bash
#
# Self-test for scripts/testflight-expiry.sh (bead openmoji-x8k). Run: make release-test
#
# Never touches GitHub and holds no token. Each case runs the REAL script inside
# a throwaway git repo holding annotated `build-*` tags whose tagger dates are
# set with GIT_COMMITTER_DATE relative to now (the script reads the clock itself,
# so the dates are what pin the expiry math: expiry is tag date + 90 days), with
# a stub `gh` first on PATH. The stub logs its calls and answers from environment
# variables: the number of open labelled issues and whether the label exists. The
# cases check that no build tag and a distant expiry do nothing, when an issue is
# opened (the THRESHOLD_DAYS threshold, its default and override), that the newest
# tag by date is the one used, that an open issue stops a second one, that the
# label is created only when missing and before the issue, what the issue says,
# and that bad input or a failing `gh` fail without opening anything.
#
# The `--jq` expressions in the script are run by gh itself, so the stub cannot
# check them.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/scripts/testflight-expiry.sh"

# Isolate the throwaway repos from this user's git config and hooks.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE THRESHOLD_DAYS GH_REPO GH_TOKEN
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Expiry Test" GIT_AUTHOR_EMAIL="expiry@example.invalid"
export GIT_COMMITTER_NAME="Expiry Test" GIT_COMMITTER_EMAIL="expiry@example.invalid"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-expiry-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DAY=86400
PASSES=0
FAILURES=0
CURRENT_GROUP=""
group() {
  CURRENT_GROUP="$1"
  printf '\n%s\n' "$1"
}
check() { # description, command...
  local description="$1"
  shift
  if "$@"; then
    PASSES=$((PASSES + 1))
    printf '  ok    %s\n' "$description"
  else
    FAILURES=$((FAILURES + 1))
    printf '  FAIL  %s   [%s]\n' "$description" "$CURRENT_GROUP"
  fi
}

# -- the stub gh -------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1" in
  issue)
    case "$2" in
      list)
        if [ "${STUB_LIST_FAIL:-}" = 1 ]; then
          echo 'gh: HTTP 401: Bad credentials' >&2
          exit 1
        fi
        printf '%s\n' "${STUB_OPEN_ISSUES:-0}"
        ;;
      create)
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            --title) printf '%s' "$2" >"$STUB_DIR/title" ;;
            --body) printf '%s' "$2" >"$STUB_DIR/body" ;;
            --label) printf '%s' "$2" >"$STUB_DIR/label" ;;
          esac
          shift 2
        done
        ;;
    esac
    ;;
  label)
    case "$2" in
      list) printf '%s\n' "${STUB_LABEL_EXISTS:-}" ;;
      create) ;;
    esac
    ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# -- the throwaway repo ------------------------------------------------------------
REPO_N=0
TAG_EPOCH=0
new_repo() { # a fresh repo with one commit and no tags
  REPO="$TMP/repo-$((++REPO_N))"
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m first
}
tag_upload_seconds() { # <tag> <seconds-ago>: an annotated tag, tagger date that long ago
  TAG_EPOCH=$(($(date +%s) - $2))
  GIT_COMMITTER_DATE="$TAG_EPOCH +0000" git -C "$REPO" tag -a "$1" -m "TestFlight upload"
}
tag_upload() { tag_upload_seconds "$1" $(($2 * DAY)); } # <tag> <days-ago>

# -- running a case ----------------------------------------------------------------
CASE_N=0
run_expiry() { # [VAR=value ...]: the script, run inside $REPO
  CASE_DIR="$TMP/case-$((++CASE_N))"
  mkdir -p "$CASE_DIR"
  : >"$CASE_DIR/log"
  STATUS=0
  (
    cd "$REPO"
    env STUB_DIR="$CASE_DIR" STUB_LOG="$CASE_DIR/log" PATH="$TMP/bin:$PATH" "$@" \
      "$SCRIPT" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
  ) || STATUS=$?
}

exited() { [ "$STATUS" -eq "$1" ]; }
opened_issue() { [ -f "$CASE_DIR/title" ] && logged '^issue create '; }
no_issue() { [ ! -e "$CASE_DIR/title" ] && not_logged '^issue create '; }
logged() { grep -qE -- "$1" "$CASE_DIR/log"; }
not_logged() { ! grep -qE -- "$1" "$CASE_DIR/log"; }
only_read_calls() { not_logged '^(issue create|label create) '; }
title_has() { grep -qF -- "$1" "$CASE_DIR/title"; }
title_lacks() { ! title_has "$1"; }
body_has() { grep -qF -- "$1" "$CASE_DIR/body"; }
said() { grep -qF -- "$1" "$CASE_DIR/stdout" "$CASE_DIR/stderr"; }
issue_label_is() { [ "$(cat "$CASE_DIR/label")" = "$1" ]; }
format_date() { date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F; }
label_created_before_issue() {
  local label_line issue_line
  label_line=$(grep -n '^label create ' "$CASE_DIR/log" | sed -n '1s/:.*//p')
  issue_line=$(grep -n '^issue create ' "$CASE_DIR/log" | sed -n '1s/:.*//p')
  [ -n "$label_line" ] && [ -n "$issue_line" ] && [ "$label_line" -lt "$issue_line" ]
}
calls_total() { wc -l <"$CASE_DIR/log" | tr -d ' '; }

# -- cases -------------------------------------------------------------------------
group "No build tag: nothing to check"
new_repo
tag_upload v1.0 0
run_expiry
check "a repo with only a non-build tag exits 0" exited 0
check "it says there is no build tag" said "No build-* tag found"
check "it makes no gh call" test "$(calls_total)" = 0

group "Expiry beyond the threshold: nothing happens"
new_repo
tag_upload build-3 10
run_expiry
check "a build uploaded 10 days ago exits 0" exited 0
check "it says expiry is more than 14 days away" said "more than 14 days away"
check "it makes no gh call" test "$(calls_total)" = 0
new_repo
tag_upload_seconds build-3 $((76 * DAY - 120))
run_expiry
check "an expiry two minutes beyond 14 days opens nothing" no_issue

group "Expiry within the default 14 days: opens an issue"
new_repo
tag_upload build-12 76
EXPIRY_DATE=$(format_date $((TAG_EPOCH + 90 * DAY)))
UPLOAD_DATE=$(format_date "$TAG_EPOCH")
run_expiry
check "a build uploaded 76 days ago exits 0" exited 0
check "it opens an issue" opened_issue
check "it opens exactly one" test "$(grep -c '^issue create ' "$CASE_DIR/log")" = 1
check "the issue carries the testflight-expiry label" issue_label_is testflight-expiry
check "the title names the build and says it expires" title_has "TestFlight build 12 expires about"
check "the title gives the expiry date (upload + 90 days)" title_has "$EXPIRY_DATE"
check "the title tells the user to run make testflight" title_has "run \`make testflight\`"
check "the body names the tag and the upload date" body_has "tag \`build-12\`, uploaded $UPLOAD_DATE"
check "the body points at the runbook" body_has "docs/runbooks/testflight-release.md"
new_repo
tag_upload build-13 100
run_expiry
check "an already-expired build still opens an issue" opened_issue
check "its title says it expired" title_has "TestFlight build 13 expired about"

group "Newest tag by date wins"
new_repo
tag_upload build-10 80
tag_upload build-9 100
tag_upload v1.0 0
run_expiry
check "with build-10 newer than build-9 (and a newer non-build tag) it opens an issue" opened_issue
check "the title is for build 10, not 9 (not the highest name)" title_has "TestFlight build 10 expires"
check "the title does not mention build 9" title_lacks "build 9"
check "it says which tag it used" said "Newest tag build-10"
new_repo
tag_upload build-10 10
tag_upload build-9 100
run_expiry
check "an old build near expiry is ignored when a newer one is fresh" no_issue

group "THRESHOLD_DAYS"
new_repo
tag_upload build-4 70 # expires in 20 days
run_expiry THRESHOLD_DAYS=30
check "an override of 30 opens an issue 20 days before expiry" opened_issue
run_expiry THRESHOLD_DAYS=
check "an empty value means the default 14, so 20 days opens nothing" no_issue
new_repo
tag_upload build-4 80 # expires in 10 days
run_expiry THRESHOLD_DAYS=
check "an empty value means the default 14, so 10 days opens an issue" opened_issue
run_expiry THRESHOLD_DAYS=5
check "an override of 5 opens nothing 10 days before expiry" no_issue

group "Label: created on first use only"
new_repo
tag_upload build-4 80
run_expiry
check "a missing label is created" logged '^label create testflight-expiry '
check "the label is created before the issue" label_created_before_issue
run_expiry STUB_LABEL_EXISTS=testflight-expiry
check "an existing label is not created again" not_logged '^label create '
check "the issue is still opened" opened_issue

group "Dedupe: an open issue stops a second one"
run_expiry STUB_OPEN_ISSUES=1
check "exits 0" exited 0
check "opens no issue and creates no label" only_read_calls
check "it says one is already open" said "already open"
check "it looks only at its own label" logged '^issue list --label testflight-expiry --state open'

group "Bad input and failures"
run_expiry THRESHOLD_DAYS=abc
check "a non-numeric THRESHOLD_DAYS exits 2" exited 2
check "it names the variable" said "THRESHOLD_DAYS must be a non-negative integer"
check "it makes no gh call" test "$(calls_total)" = 0
run_expiry THRESHOLD_DAYS=-1
check "a negative THRESHOLD_DAYS exits 2" exited 2
run_expiry STUB_LIST_FAIL=1
check "a failing gh exits non-zero" test "$STATUS" -ne 0
check "it opens no issue" no_issue

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
