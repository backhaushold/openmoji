#!/bin/bash
#
# Self-test for scripts/inactivity-guard.sh (bead openmoji-pxc.1). Run: make release-test
#
# Never touches GitHub and holds no token. Each case runs the REAL script with a
# stub `gh` first on PATH. The stub logs its calls and answers from environment
# variables: the latest commit's epoch seconds (`gh api`), the number of open
# labelled issues, and whether the label exists. The cases check when an issue
# is opened (the INACTIVITY_DAYS threshold, its default and override), that an
# open issue stops a second one, that the label is created only when missing and
# before the issue, what the issue says, and that bad input or a failed `gh api`
# fail without opening anything.
#
# The `--jq` expression in the script is run by gh itself, so the stub cannot
# check it; it was run once against the real commits endpoint.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/scripts/inactivity-guard.sh"

unset INACTIVITY_DAYS GH_REPO GH_TOKEN

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-inactivity-test.XXXXXX")
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
  api)
    if [ "${STUB_API_FAIL:-}" = 1 ]; then
      echo 'gh: HTTP 401: Bad credentials' >&2
      exit 1
    fi
    printf '%s\n' "$STUB_LAST_EPOCH"
    ;;
  issue)
    case "$2" in
      list) printf '%s\n' "${STUB_OPEN_ISSUES:-0}" ;;
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

# -- running a case ----------------------------------------------------------------
# run_guard_seconds <seconds-old> [VAR=value ...]: the latest commit is that old
# (a second or two more by the time the script reads the clock).
CASE_N=0
run_guard_seconds() {
  local seconds_old="$1"
  shift
  CASE_DIR="$TMP/case-$((++CASE_N))"
  mkdir -p "$CASE_DIR"
  : >"$CASE_DIR/log"
  STATUS=0
  env STUB_DIR="$CASE_DIR" STUB_LOG="$CASE_DIR/log" \
    STUB_LAST_EPOCH="$(($(date +%s) - seconds_old))" \
    PATH="$TMP/bin:$PATH" "$@" \
    "$SCRIPT" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr" || STATUS=$?
}
run_guard() { # <days-old> [VAR=value ...]
  local days_old="$1"
  shift
  run_guard_seconds $((days_old * DAY)) "$@"
}

exited() { [ "$STATUS" -eq "$1" ]; }
opened_issue() { [ -f "$CASE_DIR/title" ] && logged '^issue create '; }
no_issue() { [ ! -e "$CASE_DIR/title" ] && not_logged '^issue create '; }
logged() { grep -qE -- "$1" "$CASE_DIR/log"; }
not_logged() { ! grep -qE -- "$1" "$CASE_DIR/log"; }
only_read_calls() { not_logged '^(issue create|label create) '; }
title_has() { grep -qF -- "$1" "$CASE_DIR/title"; }
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
group "Recent activity: nothing happens"
run_guard 10
check "a 10-day-old commit exits 0" exited 0
check "it opens no issue and creates no label" only_read_calls
check "it asks only for the latest commit (one gh call)" test "$(calls_total)" = 1
check "it says there is nothing to do" said "nothing to do"
run_guard_seconds $((50 * DAY - 120))
check "a commit two minutes short of 50 days opens nothing" no_issue

group "Inactivity at the default 50 days: opens an issue"
LAST=$(($(date +%s) - 50 * DAY))
run_guard 50
check "a 50-day-old commit exits 0" exited 0
check "it opens an issue" opened_issue
check "the issue carries the workflow-inactivity label" issue_label_is workflow-inactivity
check "the title gives the days and GitHub's 60-day rule" title_has "50 days; GitHub disables scheduled workflows at 60"
check "the body names the last commit date" body_has "$(format_date "$LAST")"
check "the body names the date GitHub disables the schedule (last commit + 60 days)" \
  body_has "$(format_date $((LAST + 60 * DAY)))"
check "the body tells the user to push a commit" body_has "push a commit"
check "the body gives the re-enable command" body_has "gh workflow enable testflight-expiry.yml"
check "the body points at the runbook" body_has "docs/runbooks/testflight-release.md"

group "Label: created on first use only"
run_guard 55
check "a missing label is created" logged '^label create workflow-inactivity '
check "the label is created before the issue" label_created_before_issue
run_guard 55 STUB_LABEL_EXISTS=workflow-inactivity
check "an existing label is not created again" not_logged '^label create '
check "the issue is still opened" opened_issue

group "Dedupe: an open issue stops a second one"
run_guard 55 STUB_OPEN_ISSUES=1
check "exits 0" exited 0
check "opens no issue and creates no label" only_read_calls
check "it says one is already open" said "already open"
check "it looks only at its own label" logged '^issue list --label workflow-inactivity --state open'

group "INACTIVITY_DAYS"
run_guard 10 INACTIVITY_DAYS=7
check "an override of 7 opens an issue for a 10-day-old commit" opened_issue
run_guard 30 INACTIVITY_DAYS=45
check "an override of 45 opens nothing for a 30-day-old commit" no_issue
run_guard 51 INACTIVITY_DAYS=
check "an empty value means the default 50" opened_issue
run_guard 30 INACTIVITY_DAYS=
check "an empty value does not warn at 30 days" no_issue
run_guard 0 INACTIVITY_DAYS=0
check "0 opens an issue whatever the commit age" opened_issue

group "Bad input and failures"
run_guard 90 INACTIVITY_DAYS=abc
check "a non-numeric INACTIVITY_DAYS exits 2" exited 2
check "it names the variable" said "INACTIVITY_DAYS must be a non-negative integer"
check "it makes no gh call" test "$(calls_total)" = 0
run_guard 90 STUB_API_FAIL=1
check "a failing gh api exits non-zero" test "$STATUS" -ne 0
check "it opens no issue" no_issue
run_guard 90 STUB_API_FAIL=0 STUB_LAST_EPOCH=null
check "a non-numeric commit date exits 1" exited 1
check "it opens no issue on a bad date" no_issue

group "Repository selection"
run_guard 10 GH_REPO=owner/name
check "with GH_REPO the commits path names that repo" logged '^api repos/owner/name/commits\?per_page=1 '
run_guard 10
check "without GH_REPO gh fills {owner}/{repo} from the git remote" \
  logged '^api repos/\{owner\}/\{repo\}/commits\?per_page=1 '

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
