#!/bin/bash
#
# Self-test for the release lane (beads openmoji-4kq, openmoji-2pq). Run: make release-test
#
# Signs nothing, uploads nothing, never touches the network, 1Password, App
# Store Connect or the real keychain. Each case runs the REAL scripts/release.sh
# (a copy inside a throwaway git repo with a local bare "origin") in a child
# bash that sources it and replaces the external tools (gh, gitleaks, xcodegen,
# swift, xcodebuild, security, xcode-select) with shell functions that log
# their calls. "Nothing signed" means: no `security unlock-keychain` and no
# `xcodebuild archive` / `-exportArchive` in that log.
#
# Steps 8-9 (bead openmoji-2pq): `swift scripts/asc.swift ...` is one of the
# stubbed tools (logged as "asc <command> ..."), so the lane's own logic is
# tested here: the order of the calls, the What to Test text, and that the
# annotated build-N tag is pushed to the (local, bare) origin only after the
# build is VALID. asc.swift itself is tested against a local stub HTTP server by
# scripts/test-asc.sh.
#
# Section (d) covers scripts/op-run.sh (bead openmoji-pxc.3): it runs a copy of
# the script in a fixture directory with a fake .env and a stub `op`. It never
# reads the repository's own .env, which may hold a live 1Password token.
#
# Secrets in this file are fake and built at runtime, so gitleaks (which scans
# this repo in CI and in the lane) has nothing to flag.
#
# Child mode, used internally:  test-release.sh --driver   (reads env, runs main)
#                               SCAN_TARGET=<dir> ... --driver   (runs scan_for_keys only)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
HARNESS="$HERE/$(basename "${BASH_SOURCE[0]}")"

# Fake secrets, assembled at runtime.
fake_key() { printf 'sk-%s%s' FAKEFAKEFAKEFAKE FAKEFAKEFAKEFAKE0000; }
fake_pem() {
  local begin="-----BEGIN PRIVATE"
  local end="-----END PRIVATE"
  printf '%s KEY-----\n%s\n%s KEY-----\n' "$begin" "FAKE-NOT-A-REAL-KEY-FOR-TESTS" "$end"
}

# ============================================================== child mode ===

# The stubs. They only log; the sole files they create are the fake archive
# and the probe notes. They are called by the sourced release.sh, which the
# linter cannot see.
# shellcheck disable=SC2329
driver() {
  # shellcheck source=/dev/null
  source "$FIXTURE/scripts/release.sh"

  if [ -n "${SCAN_TARGET:-}" ]; then
    scan_for_keys "$SCAN_TARGET"
    exit 0
  fi
  if [ -n "${EXTRA_REQUIRED_TOOL:-}" ]; then
    REQUIRED_TOOLS+=("$EXTRA_REQUIRED_TOOL")
  fi

  log_call() { printf '%s\n' "$*" >>"$CALL_LOG"; }
  probe() { printf '%s\n' "$*" >>"$PROBE"; }

  gh() {
    log_call "gh $*"
    case "${GH_MODE:-ok}" in
      ok) printf 'verify\tcompleted\tsuccess\n' ;;
      multi-ok) printf 'verify\tcompleted\tsuccess\nlint\tcompleted\tskipped\n' ;;
      pending) printf 'verify\tin_progress\t-\n' ;;
      failing) printf 'verify\tcompleted\tfailure\n' ;;
      other-failing) printf 'verify\tcompleted\tsuccess\nlint\tcompleted\tcancelled\n' ;;
      none) ;;
      no-verify) printf 'other\tcompleted\tsuccess\n' ;;
      error)
        printf 'gh: HTTP 401: Bad credentials\n' >&2
        return 1
        ;;
    esac
  }
  xcode-select() {
    log_call "xcode-select $*"
    printf '%s\n' "${XCODE_SELECT_PATH:-/Applications/Xcode.app/Contents/Developer}"
  }
  gitleaks() {
    log_call "gitleaks $*"
    if [ "${FAIL_AT:-}" = gitleaks ]; then return 1; fi
  }
  xcodegen() {
    log_call "xcodegen $*"
    if [ "${FAIL_AT:-}" = xcodegen ]; then return 1; fi
  }
  swift() {
    case "${1:-}" in
      */scripts/asc.swift)
        shift
        stub_asc "$@"
        ;;
      *)
        log_call "swift $*"
        if [ "${FAIL_AT:-}" = swift ]; then return 1; fi
        ;;
    esac
  }
  # `swift scripts/asc.swift <command> ...`. Logs the command line (not the
  # What to Test text, which goes to $NOTES_FILE) and what the lane's state is
  # when it is called: is the build-N tag on origin yet, and does asc.swift see
  # the ASC_* variables and no test hook. ASC_MODE picks a failure.
  stub_asc() {
    local command="$1" tag_on_origin=0
    shift
    if [ -n "$(git ls-remote --tags origin "refs/tags/build-$BUILD_NUMBER")" ]; then tag_on_origin=1; fi
    if [ "$command" = set-whats-new ]; then
      log_call "asc $command $1 <text in notes file>"
      printf '%s' "$2" >"$NOTES_FILE"
    else
      log_call "asc $command $*"
    fi
    probe "tag_on_origin_at_$command=$tag_on_origin"
    if [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_PRIVATE_KEY_BASE64:-}" ]; then
      probe "asc_env_ok_at_$command=1"
    fi
    if [ -z "${ASC_TEST_BASE_URL+x}${ASC_TEST_RETRY_DELAY+x}" ]; then probe "asc_test_hooks_unset=1"; fi
    case "$command:${ASC_MODE:-ok}" in
      wait-for-build:invalid)
        echo "asc: ERROR: build $1 finished processing as INVALID" >&2
        return 4
        ;;
      wait-for-build:timeout)
        echo "asc: ERROR: timed out after 1 s; build $1 was last PROCESSING" >&2
        return 3
        ;;
      wait-for-build:sigint) kill -INT $$ ;;
      set-whats-new:notes-fail) return 1 ;;
      ensure-in-group:group-fail) return 1 ;;
    esac
  }
  security() {
    case "$1" in
      unlock-keychain)
        # $2 is -p, $3 the password; never log the password.
        log_call "security unlock-keychain -p <redacted> $4"
        [ "$3" = "$SIGNING_KEYCHAIN_PASSWORD" ] || return 1
        ;;
      list-keychains)
        log_call "security $*"
        if [ "$#" -eq 3 ]; then
          printf '    "%s"\n    "%s"\n' /fake/login.keychain-db /fake/other.keychain-db
        fi
        ;;
      find-identity)
        log_call "security $*"
        printf '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Fake (AB5S94XWRQ)"\n     1 valid identities found\n'
        ;;
      *) log_call "security $*" ;;
    esac
  }
  xcodebuild() {
    log_call "xcodebuild $*"
    case "$1" in
      archive) stub_archive "$@" ;;
      -exportArchive) stub_export "$@" ;;
    esac
  }
  stub_archive() {
    if [ "${FAIL_AT:-}" = archive ]; then return 1; fi
    local path="" arg
    while [ "$#" -gt 0 ]; do
      arg="$1"
      shift
      if [ "$arg" = "-archivePath" ]; then path="$1"; fi
    done
    mkdir -p "$path/Products/Applications/OpenMoji.app"
    printf 'clean archive\n' >"$path/Info.plist"
    printf '\000\001\002binary\000' >"$path/Products/Applications/OpenMoji.app/OpenMoji"
    case "${SEED_KEY:-}" in
      text) printf 'apiKey = %s\n' "$(fake_key)" >"$path/Info.plist" ;;
      binary) printf '\000\001%s\000\002' "$(fake_key)" >"$path/Products/Applications/OpenMoji.app/OpenMoji" ;;
    esac
  }
  stub_export() {
    local key_path="" arg
    while [ "$#" -gt 0 ]; do
      arg="$1"
      shift
      if [ "$arg" = "-authenticationKeyPath" ]; then key_path="$1"; fi
    done
    probe "key_path=$key_path"
    if [ -f "$key_path" ]; then probe "key_exists=1"; fi
    probe "key_mode=$(stat -f %Lp "$key_path")"
    if cmp -s "$key_path" "$EXPECTED_P8"; then probe "key_matches=1"; fi
    case "${UPLOAD_MODE:-ok}" in
      fail) return 1 ;;
      sigint) kill -INT $$ ;;
      sigterm) kill -TERM $$ ;;
      sighup) kill -HUP $$ ;;
    esac
  }

  main
}

if [ "${1:-}" = "--driver" ]; then
  driver
  exit 0
fi

# ============================================================ parent mode ====

# Isolate the throwaway repos from this user's git config and hooks.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Lane Test" GIT_AUTHOR_EMAIL="lane@example.invalid"
export GIT_COMMITTER_NAME="Lane Test" GIT_COMMITTER_EMAIL="lane@example.invalid"
unset SIGNING_KEYCHAIN_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64 SIGNING_KEYCHAIN_PATH OP_SERVICE_ACCOUNT_TOKEN

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-release-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

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

# Case state, set by new_case / run_lane.
CASE_DIR="" FIXTURE="" RC=0 CALL_LOG="" PROBE="" STDOUT="" STDERR="" KEYCHAIN="" EXPECTED_P8="" NOTES_FILE=""

# -- predicates over the last run ---------------------------------------------
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
err_has() { grep -qF -- "$1" "$STDERR"; }
err_lacks() { ! grep -qF -- "$1" "$STDERR"; }
out_has() { grep -qF -- "$1" "$STDOUT"; }
log_has() { grep -qE -- "$1" "$CALL_LOG"; }
log_lacks() { ! grep -qE -- "$1" "$CALL_LOG"; }
probe_has() { grep -qxF -- "$1" "$PROBE"; }
probe_lacks() { ! grep -q -- "$1" "$PROBE"; }
nothing_signed() { log_lacks '^security unlock-keychain|^xcodebuild archive|^xcodebuild -exportArchive'; }
nothing_past_preflight() { log_lacks '^(gitleaks|xcodegen|swift|asc|security|xcodebuild) '; }
no_leftover_tmp() { [ -z "$(ls -A "$CASE_DIR/tmp")" ]; }
recorded_key_is_gone() {
  local path
  path=$(sed -n 's/^key_path=//p' "$PROBE")
  [ -n "$path" ] && [ ! -e "$path" ]
}
keychains_restored() {
  # The last `list-keychains -d user -s ...` call restores the original list.
  [ "$(grep '^security list-keychains -d user -s' "$CALL_LOG" | tail -n 1)" = \
    "security list-keychains -d user -s /fake/login.keychain-db /fake/other.keychain-db" ]
}
keychains_prepended() {
  grep -qxF "security list-keychains -d user -s $KEYCHAIN /fake/login.keychain-db /fake/other.keychain-db" "$CALL_LOG"
}
no_secret_in_output() {
  local file
  for file in "$STDOUT" "$STDERR" "$CALL_LOG" "$PROBE"; do
    if grep -qF -e "fake-keychain-password-0000" -e "$(fake_key)" -e "FAKE-NOT-A-REAL-KEY" -e "$(fake_pem | base64)" "$file"; then
      return 1
    fi
  done
}
asc_calls() { grep -c '^asc ' "$CALL_LOG" || true; }
no_asc_calls() { [ "$(asc_calls)" -eq 0 ]; }
# The build-N tag (steps 9): local, on the bare origin, annotated, and where.
local_tag_exists() { git -C "$FIXTURE" rev-parse -q --verify "refs/tags/build-$1" >/dev/null; }
origin_tag_exists() { git -C "$CASE_DIR/origin.git" rev-parse -q --verify "refs/tags/build-$1" >/dev/null; }
no_tag() { ! local_tag_exists "$1" && ! origin_tag_exists "$1"; }
tag_is_annotated() { [ "$(git -C "$FIXTURE" cat-file -t "refs/tags/build-$1" 2>/dev/null)" = tag ]; }
origin_tag_is_annotated() { [ "$(git -C "$CASE_DIR/origin.git" cat-file -t "refs/tags/build-$1" 2>/dev/null)" = tag ]; }
tag_points_at_head() { [ "$(git -C "$FIXTURE" rev-parse "refs/tags/build-$1^{commit}")" = "$(git -C "$FIXTURE" rev-parse HEAD)" ]; }
origin_tag_points_at_head() { [ "$(git -C "$CASE_DIR/origin.git" rev-parse "refs/tags/build-$1^{commit}")" = "$(git -C "$FIXTURE" rev-parse HEAD)" ]; }
tag_message_is_upload_stamp() {
  git -C "$FIXTURE" tag -l --format='%(contents:subject)' "build-$1" \
    | grep -qE '^TestFlight upload [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}
tag_date_is_now() { # the tagger date is the upload date the expiry alert reads
  local tagged now
  tagged=$(git -C "$CASE_DIR/origin.git" for-each-ref --format='%(taggerdate:unix)' "refs/tags/build-$1")
  now=$(date +%s)
  [ -n "$tagged" ] && [ "$((now - tagged))" -ge 0 ] && [ "$((now - tagged))" -lt 300 ]
}
notes_are() { [ "$(cat "$NOTES_FILE")" = "$1" ]; }
order_is() { # patterns in the order they must first appear in the call log
  local last=0 pattern line
  for pattern in "$@"; do
    line=$(grep -nE -- "$pattern" "$CALL_LOG" | sed -n '1s/:.*//p')
    if [ -z "$line" ] || [ "$line" -le "$last" ]; then return 1; fi
    last=$line
  done
}

# -- fixtures -------------------------------------------------------------------
# A real git repo (with a local bare origin) holding a copy of the real script,
# so the preflight's git checks run for real.
new_case() {
  CASE_DIR="$TMP/$1"
  FIXTURE="$CASE_DIR/work"
  KEYCHAIN="$CASE_DIR/openmoji-signing.keychain-db"
  EXPECTED_P8="$CASE_DIR/expected.p8"
  mkdir -p "$CASE_DIR/tmp" "$FIXTURE/scripts" "$FIXTURE/release"
  : >"$KEYCHAIN"
  fake_pem >"$EXPECTED_P8"
  cp -f "$ROOT/scripts/release.sh" "$FIXTURE/scripts/release.sh"
  cp -f "$ROOT/release/ExportOptions.plist" "$FIXTURE/release/ExportOptions.plist"
  printf 'build/\n' >"$FIXTURE/.gitignore"
  git init -q --bare -b main "$CASE_DIR/origin.git"
  git -C "$FIXTURE" init -q -b main
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "first"
  printf 'two\n' >"$FIXTURE/two.txt"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "second"
  git -C "$FIXTURE" remote add origin "$CASE_DIR/origin.git"
  git -C "$FIXTURE" push -q -u origin main
}

# extra_commits subject...: more commits on main, pushed so HEAD still equals
# origin/main. The build number (commit count) grows with each.
extra_commits() {
  local subject
  for subject in "$@"; do
    printf '%s\n' "$subject" >"$FIXTURE/file-$subject.txt"
    git -C "$FIXTURE" add -A
    git -C "$FIXTURE" commit -q -m "$subject"
  done
  git -C "$FIXTURE" push -q origin main
}

# run_lane [VAR=value | -u VAR]...: run the lane in the current case with a
# complete, valid environment; the arguments override it.
run_lane() {
  CALL_LOG="$CASE_DIR/calls.log"
  PROBE="$CASE_DIR/probe.log"
  STDOUT="$CASE_DIR/stdout"
  STDERR="$CASE_DIR/stderr"
  NOTES_FILE="$CASE_DIR/whatsnew.txt"
  : >"$CALL_LOG"
  : >"$PROBE"
  : >"$NOTES_FILE"
  RC=0
  (
    export FIXTURE CALL_LOG PROBE EXPECTED_P8 NOTES_FILE
    export TMPDIR="$CASE_DIR/tmp"
    export SIGNING_KEYCHAIN_PATH="$KEYCHAIN"
    export SIGNING_KEYCHAIN_PASSWORD="fake-keychain-password-0000"
    export ASC_KEY_ID="ABCDE12345"
    export ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
    ASC_PRIVATE_KEY_BASE64="$(fake_pem | base64)"
    export ASC_PRIVATE_KEY_BASE64
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-u" ]; then
        unset "$2"
        shift 2
      else
        export "${1?}"
        shift
      fi
    done
    exec /bin/bash "$HARNESS" --driver
  ) >"$STDOUT" 2>"$STDERR" || RC=$?
}

# The common shape of a preflight failure: stops with the message, before
# anything past preflight ran.
expect_preflight_stop() { # description, message fragment
  check "$1: exits non-zero" rc_nonzero
  check "$1: says '$2'" err_has "$2"
  check "$1: nothing past preflight ran (no gitleaks/xcodegen/swift/security/xcodebuild)" nothing_past_preflight
  check "$1: nothing signed" nothing_signed
  check "$1: reports that nothing was signed" err_has "Nothing was signed or uploaded"
  check "$1: no .p8 was ever written" probe_lacks key_path
}

# ================================================================= (a) =======
group "(a) preflight failures stop before anything is signed"

new_case baseline-ok
run_lane
check "baseline: every condition met, preflight passes" out_has "preflight ok"

new_case dirty-tracked
printf 'edit\n' >>"$FIXTURE/two.txt"
run_lane
expect_preflight_stop "dirty tree (modified file)" "working tree is not clean"

new_case dirty-untracked
printf 'stray\n' >"$FIXTURE/stray.txt"
run_lane
expect_preflight_stop "dirty tree (untracked file)" "working tree is not clean"

new_case wrong-branch
git -C "$FIXTURE" switch -q -c feature
run_lane
expect_preflight_stop "wrong branch" "on 'feature'"

new_case detached
git -C "$FIXTURE" checkout -q --detach
run_lane
expect_preflight_stop "detached HEAD" "detached HEAD"

new_case ahead
printf 'local\n' >"$FIXTURE/local.txt"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "local only"
run_lane
expect_preflight_stop "HEAD ahead of origin/main" "is not origin/main"
check "HEAD ahead: says how far ahead" err_has "1 commit(s) ahead, 0 behind"

new_case behind
git clone -q "$CASE_DIR/origin.git" "$CASE_DIR/other"
printf 'remote\n' >"$CASE_DIR/other/remote.txt"
git -C "$CASE_DIR/other" add -A
git -C "$CASE_DIR/other" commit -q -m "remote only"
git -C "$CASE_DIR/other" push -q origin main
run_lane
expect_preflight_stop "HEAD behind origin/main" "is not origin/main"
check "HEAD behind: says how far behind" err_has "0 commit(s) ahead, 1 behind"

new_case ci-failing
run_lane GH_MODE=failing
expect_preflight_stop "CI failed on HEAD" "CI is not green"
HEAD_SHA=$(git -C "$FIXTURE" rev-parse HEAD)
check "CI check queried HEAD's own SHA" log_has "^gh api repos/\{owner\}/\{repo\}/commits/$HEAD_SHA/check-runs"

new_case ci-other-failing
run_lane GH_MODE=other-failing
expect_preflight_stop "another check run failed" "lint(cancelled)"

new_case ci-pending
run_lane GH_MODE=pending
expect_preflight_stop "CI still running" "CI is still running"

new_case ci-none
run_lane GH_MODE=none
expect_preflight_stop "no check runs yet" "no CI check runs found"

new_case ci-no-verify
run_lane GH_MODE=no-verify
expect_preflight_stop "no 'verify' check run" "'verify' not found"

new_case ci-error
run_lane GH_MODE=error
expect_preflight_stop "gh cannot read CI status" "could not read CI status"

new_case ci-multi-ok
run_lane GH_MODE=multi-ok
check "several check runs, all success or skipped: preflight passes" out_has "preflight ok"

new_case xcode-clt
run_lane XCODE_SELECT_PATH=/Library/Developer/CommandLineTools
expect_preflight_stop "xcode-select at Command Line Tools" "not a full Xcode.app"

for var in SIGNING_KEYCHAIN_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64; do
  new_case "env-missing-$var"
  run_lane -u "$var"
  expect_preflight_stop "missing $var" "required environment missing: $var"
done

new_case env-unresolved
run_lane ASC_ISSUER_ID=op://OpenMoji/testflight-asc-api-key/issuer-id
expect_preflight_stop "unresolved op:// reference" "unresolved op:// reference"

new_case env-bad-key-id
run_lane "ASC_KEY_ID=../../etc"
expect_preflight_stop "ASC_KEY_ID with path characters" "ASC_KEY_ID contains unexpected characters"

new_case keychain-missing
run_lane "SIGNING_KEYCHAIN_PATH=$CASE_DIR/nonexistent.keychain-db"
expect_preflight_stop "signing keychain file missing" "signing keychain not found"

new_case tool-missing
run_lane EXTRA_REQUIRED_TOOL=openmoji-no-such-tool
expect_preflight_stop "required tool missing" "missing tools: openmoji-no-such-tool"

new_case direct-run
# The real script, executed directly (not sourced), without 1Password's
# environment and with the real tools: refuses before touching anything.
RC=0
STDOUT="$CASE_DIR/stdout"
STDERR="$CASE_DIR/stderr"
(cd "$FIXTURE" && env -u SIGNING_KEYCHAIN_PASSWORD -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_PRIVATE_KEY_BASE64 \
  ./scripts/release.sh >"$STDOUT" 2>"$STDERR") || RC=$?
check "direct run without 1Password env: exits non-zero" rc_nonzero
check "direct run: preflight error, not a crash" err_has "release: ERROR:"
check "direct run: reports that nothing was signed" err_has "Nothing was signed or uploaded"

group "(a) steps 2-4 failing also stop before signing"
for failing_step in gitleaks xcodegen swift; do
  new_case "fail-$failing_step"
  run_lane FAIL_AT="$failing_step"
  check "$failing_step fails: exits non-zero" rc_nonzero
  check "$failing_step fails: nothing signed" nothing_signed
  check "$failing_step fails: keychain never touched" log_lacks '^security '
  check "$failing_step fails: reports that nothing was signed" err_has "Nothing was signed or uploaded"
done

# ================================================================= (b) =======
group "(b) a seeded sk- key in the archive fails step 6b"

for where in text binary; do
  new_case "seeded-$where"
  run_lane SEED_KEY="$where"
  check "seeded key ($where file): lane exits non-zero" rc_nonzero
  check "seeded key ($where file): says an OpenAI-style key was found" err_has "an OpenAI-style key (sk-...) was found"
  check "seeded key ($where file): names the offending archive" err_has "OpenMoji-2.xcarchive"
  check "seeded key ($where file): the key itself is never printed" no_secret_in_output
  check "seeded key ($where file): upload never started" log_lacks '^xcodebuild -exportArchive'
  check "seeded key ($where file): no .p8 was written" probe_lacks key_path
  check "seeded key ($where file): keychain search list restored" keychains_restored
  check "seeded key ($where file): archive kept for inspection" test -d "$FIXTURE/build/release/OpenMoji-2.xcarchive"
done

scan() { # directory: runs scan_for_keys on it, sets RC
  RC=0
  STDERR="$CASE_DIR/stderr"
  env FIXTURE="$FIXTURE" SCAN_TARGET="$1" /bin/bash "$HARNESS" --driver >/dev/null 2>"$STDERR" || RC=$?
}
new_case scan-unit
mkdir -p "$CASE_DIR/clean/a/b" "$CASE_DIR/short/a" "$CASE_DIR/deep/a/b/c" "$CASE_DIR/dashes"
printf 'nothing here\n' >"$CASE_DIR/clean/a/b/file.txt"
printf '\000\001\002no key\000' >"$CASE_DIR/clean/a/b/binary"
printf 'sk-short and task-queue and desk\n' >"$CASE_DIR/short/a/file.txt"
printf '\000\001%s\000' "$(fake_key)" >"$CASE_DIR/deep/a/b/c/binary"
printf 'x sk-proj-%s_%s-end y\n' ABCDEFGHIJ0123456789 KLMNOPQRST >"$CASE_DIR/dashes/file.txt"
scan "$CASE_DIR/clean"
check "scan: clean tree (text and binary) passes" rc_is 0
scan "$CASE_DIR/short"
check "scan: short sk- strings do not match" rc_is 0
scan "$CASE_DIR/deep"
check "scan: key inside a binary three directories deep fails" rc_nonzero
scan "$CASE_DIR/dashes"
check "scan: sk-proj style key with _ and - fails" rc_nonzero
scan "$CASE_DIR/does-not-exist"
check "scan: missing target is an error, not a pass" rc_nonzero

# ================================================================= (c) =======
group "(c) the temporary .p8 is removed on every exit path"

new_case success
run_lane
check "success: exits 0" rc_is 0
check "success: .p8 existed during the upload" probe_has "key_exists=1"
check "success: .p8 was readable only by the owner (0600)" probe_has "key_mode=600"
check "success: .p8 held the decoded key" probe_has "key_matches=1"
check "success: .p8 removed afterwards" recorded_key_is_gone
check "success: no temp directory left behind" no_leftover_tmp
check "success: keychain search list prepended with the signing keychain" keychains_prepended
check "success: keychain search list restored" keychains_restored
check "success: no secret in output, log or probe" no_secret_in_output

new_case export-fails
run_lane UPLOAD_MODE=fail
check "upload fails: exits non-zero" rc_nonzero
check "upload fails: says so" err_has "exportArchive/upload failed"
check "upload fails: .p8 existed during the upload" probe_has "key_exists=1"
check "upload fails: .p8 removed" recorded_key_is_gone
check "upload fails: no temp directory left behind" no_leftover_tmp
check "upload fails: keychain search list restored" keychains_restored
check "upload fails: archive kept" test -d "$FIXTURE/build/release/OpenMoji-2.xcarchive"

new_case archive-fails
run_lane FAIL_AT=archive
check "archive fails: exits non-zero" rc_nonzero
check "archive fails: upload never started" log_lacks '^xcodebuild -exportArchive'
check "archive fails: no .p8 written" probe_lacks key_path
check "archive fails: keychain search list restored" keychains_restored
check "archive fails: names the failed step" err_has 'FAILED during "6. Archive'

new_case bad-base64
run_lane "ASC_PRIVATE_KEY_BASE64=@@@ not base64 @@@"
check "invalid base64 key: exits non-zero" rc_nonzero
check "invalid base64 key: says so" err_has "not valid base64"
check "invalid base64 key: upload never started" log_lacks '^xcodebuild -exportArchive'
check "invalid base64 key: no temp directory left behind" no_leftover_tmp
check "invalid base64 key: keychain search list restored" keychains_restored

new_case not-a-p8
run_lane "ASC_PRIVATE_KEY_BASE64=$(printf 'hello\n' | base64)"
check "base64 of something else: exits non-zero" rc_nonzero
check "base64 of something else: says it is not a .p8" err_has "does not decode to a .p8"
check "base64 of something else: upload never started" log_lacks '^xcodebuild -exportArchive'
check "base64 of something else: no temp directory left behind" no_leftover_tmp

for sig in "sigint 130" "sigterm 143" "sighup 129"; do
  mode=${sig% *}
  code=${sig#* }
  new_case "signal-$mode"
  run_lane UPLOAD_MODE="$mode"
  check "$mode during upload: exits $code" rc_is "$code"
  check "$mode during upload: .p8 existed when it arrived" probe_has "key_exists=1"
  check "$mode during upload: .p8 removed" recorded_key_is_gone
  check "$mode during upload: no temp directory left behind" no_leftover_tmp
  check "$mode during upload: keychain search list restored" keychains_restored
  check "$mode during upload: names the interrupted step" err_has 'FAILED during "7. Upload'
done

# ============================================== the happy path in detail =====
group "the archive and upload commands (kept archives, flags)"

new_case happy-path
run_lane
N=$(git -C "$FIXTURE" rev-list --count HEAD)
check "steps run in spec order" order_is '^gh api' '^gitleaks ' '^xcodegen ' '^swift ' '^security unlock-keychain' '^xcodebuild archive' '^xcodebuild -exportArchive' '^asc wait-for-build' '^asc set-whats-new' '^asc ensure-in-group'
check "build number is the commit count ($N)" log_has "CURRENT_PROJECT_VERSION=$N( |$)"
check "archive kept at build/release/OpenMoji-$N.xcarchive" test -d "$FIXTURE/build/release/OpenMoji-$N.xcarchive"
check "archive path passed to xcodebuild" log_has "^xcodebuild archive .*-archivePath [^ ]*/build/release/OpenMoji-$N\.xcarchive "
check "archive uses scheme OpenMoji, Release, generic iOS" log_has "^xcodebuild archive -project OpenMoji.xcodeproj -scheme OpenMoji -configuration Release -destination generic/platform=iOS "
check "--keychain goes through OTHER_CODE_SIGN_FLAGS" log_has "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN\$"
check "no PROVISIONING_PROFILE_SPECIFIER on the command line (ADR-0011)" log_lacks 'PROVISIONING_PROFILE_SPECIFIER'
check "no CODE_SIGN_STYLE/IDENTITY on the command line (ADR-0011)" log_lacks 'CODE_SIGN_(STYLE|IDENTITY)'
check "gitleaks runs with --redact --no-banner" log_has '^gitleaks detect --redact --no-banner$'
check "tests run on the OpenMojiCore package" log_has '^swift test --package-path Packages/OpenMojiCore$'
check "export uses release/ExportOptions.plist" log_has "^xcodebuild -exportArchive -archivePath [^ ]*/OpenMoji-$N\.xcarchive -exportOptionsPlist [^ ]*/release/ExportOptions\.plist "
check "export passes the ASC key id and issuer" log_has '-authenticationKeyID ABCDE12345 -authenticationKeyIssuerID 00000000-0000-0000-0000-000000000000$'
check "export passes a temporary .p8 path" log_has '-authenticationKeyPath [^ ]*/openmoji-release\.[A-Za-z0-9]+/AuthKey_ABCDE12345\.p8 '
check "the signing keychain was unlocked" log_has "^security unlock-keychain -p <redacted> $KEYCHAIN\$"
check "final message says the build is VALID, in Family and tagged" out_has "build $N is VALID, has What to Test notes, is in the Family group and is tagged build-$N."

# ================================================================= (c2) ======
group "(c2) steps 8-9: wait for VALID, What to Test, Family group, then the annotated tag"

new_case post-first-build
run_lane ASC_TEST_BASE_URL=http://127.0.0.1:9 ASC_TEST_RETRY_DELAY=9
N=$(git -C "$FIXTURE" rev-list --count HEAD)
check "no earlier build tag (first build): exits 0" rc_is 0
check "asc.swift waits for the build number with the default timeout and interval" log_has "^asc wait-for-build $N --timeout 2700 --interval 30$"
check "asc.swift sets What to Test for that build" log_has "^asc set-whats-new $N <text in notes file>$"
check "asc.swift puts that build in the Family group" log_has "^asc ensure-in-group $N Family$"
check "the order is wait, What to Test, group" order_is '^asc wait-for-build' '^asc set-whats-new' '^asc ensure-in-group'
check "all three run after the upload" order_is '^xcodebuild -exportArchive' '^asc wait-for-build'
check "first build: says it has no earlier build tag" out_has "no earlier build-* tag, so the 20 most recent commits (first build)"
check "first build: What to Test is a header and the recent commits, newest first" \
  notes_are $'First TestFlight build. Most recent changes:\n- second\n- first'
check "asc.swift sees the three ASC_* variables at every step" \
  test "$(grep -c '^asc_env_ok_at_' "$PROBE")" -eq 3
check "the lane never passes asc.swift's test hooks through (ASC_TEST_BASE_URL was set by the caller)" probe_has "asc_test_hooks_unset=1"
check "the tag was not on origin during wait-for-build" probe_has "tag_on_origin_at_wait-for-build=0"
check "the tag was not on origin during set-whats-new" probe_has "tag_on_origin_at_set-whats-new=0"
check "the tag was not on origin during ensure-in-group" probe_has "tag_on_origin_at_ensure-in-group=0"
check "the tag exists locally afterwards" local_tag_exists "$N"
check "the tag is annotated" tag_is_annotated "$N"
check "the tag was pushed to origin" origin_tag_exists "$N"
check "the pushed tag is annotated" origin_tag_is_annotated "$N"
check "the tag points at HEAD (the released commit)" tag_points_at_head "$N"
check "the pushed tag points at HEAD" origin_tag_points_at_head "$N"
check "the tag message is 'TestFlight upload <UTC time>'" tag_message_is_upload_stamp "$N"
check "the tag's date is the upload date (now)" tag_date_is_now "$N"
check "only the build tag was pushed (no branch, no other tag)" test "$(git -C "$CASE_DIR/origin.git" for-each-ref --format='%(refname)' | grep -c .)" -eq 2
check "no secret in output, log or probe" no_secret_in_output

new_case post-previous-tag
extra_commits third fourth fifth
git -C "$FIXTURE" tag build-1 "HEAD~4"
git -C "$FIXTURE" tag -a build-3 -m "older upload" "HEAD~2"
git -C "$FIXTURE" tag build-final "HEAD~1"
git -C "$FIXTURE" tag build-9 HEAD
git -C "$FIXTURE" switch -q -c side "HEAD~4"
printf 'side\n' >"$FIXTURE/side.txt"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "side only"
git -C "$FIXTURE" tag build-4
git -C "$FIXTURE" switch -q main
run_lane
N=$(git -C "$FIXTURE" rev-list --count HEAD)
check "five commits: build number is 5" test "$N" -eq 5
check "earlier tags: exits 0" rc_is 0
check "What to Test uses the newest earlier tag build-3 (not build-1, build-4 off main, non-numeric build-final or build-9 above N)" out_has "What to Test: commits since build-3 (REL-8)"
check "What to Test is exactly the commits since build-3, newest first, as '- subject' lines" notes_are $'- fifth\n- fourth'
check "the new tag build-5 is annotated and on origin" origin_tag_is_annotated 5

new_case post-custom-wait
run_lane ASC_WAIT_TIMEOUT=120 ASC_POLL_INTERVAL=2.5
check "custom wait settings: exits 0" rc_is 0
check "ASC_WAIT_TIMEOUT and ASC_POLL_INTERVAL are passed to asc.swift" log_has "^asc wait-for-build 2 --timeout 120 --interval 2.5$"

for bad in "ASC_WAIT_TIMEOUT=abc" "ASC_WAIT_TIMEOUT=0" "ASC_WAIT_TIMEOUT=-5" "ASC_POLL_INTERVAL=0.0" "ASC_POLL_INTERVAL=1.2.3" "ASC_POLL_INTERVAL=5s"; do
  new_case "bad-wait-${bad//[^A-Za-z0-9]/_}"
  run_lane "$bad"
  expect_preflight_stop "$bad" "must be a positive number of seconds"
  check "$bad: no asc.swift call, no tag" no_asc_calls
done

new_case post-invalid
run_lane ASC_MODE=invalid
check "build INVALID: lane exits non-zero" rc_nonzero
check "build INVALID: says it did not become VALID and that the build is uploaded but not tagged" err_has "build 2 did not become VALID. Build 2 is uploaded but NOT tagged."
check "build INVALID: asc.swift's own message is shown" err_has "finished processing as INVALID"
check "build INVALID: no What to Test, no group" log_lacks '^asc (set-whats-new|ensure-in-group)'
check "build INVALID: NO tag locally or on origin" no_tag 2
check "build INVALID: the cleanup message says the build WAS uploaded" err_has "Build 2 WAS uploaded to App Store Connect"
check "build INVALID: does not claim nothing was uploaded" test "$(grep -c 'Nothing was signed or uploaded' "$STDERR" || true)" -eq 0
check "build INVALID: names the failed step" err_has 'FAILED during "8. Post-upload'
check "build INVALID: keychain search list restored" keychains_restored
check "build INVALID: no temp directory left behind" no_leftover_tmp

new_case post-timeout
run_lane ASC_MODE=timeout
check "processing timeout: lane exits non-zero" rc_nonzero
check "processing timeout: says the build did not become VALID" err_has "build 2 did not become VALID"
check "processing timeout: NO tag locally or on origin" no_tag 2
check "processing timeout: no What to Test, no group" log_lacks '^asc (set-whats-new|ensure-in-group)'
check "processing timeout: the cleanup message says the build WAS uploaded" err_has "Build 2 WAS uploaded to App Store Connect"

new_case post-notes-fail
run_lane ASC_MODE=notes-fail
check "What to Test fails: lane exits non-zero" rc_nonzero
check "What to Test fails: says so" err_has "build 2 is VALID but its What to Test text could not be set"
check "What to Test fails: the group step did not run" log_lacks '^asc ensure-in-group'
check "What to Test fails: NO tag locally or on origin" no_tag 2

new_case post-group-fail
run_lane ASC_MODE=group-fail
check "Family group fails: lane exits non-zero" rc_nonzero
check "Family group fails: says so" err_has "build 2 is VALID but could not be put in the Family group"
check "Family group fails: NO tag locally or on origin" no_tag 2

new_case post-sigint
run_lane ASC_MODE=sigint
check "Ctrl-C while waiting for processing: exits 130" rc_is 130
check "Ctrl-C while waiting: NO tag locally or on origin" no_tag 2
check "Ctrl-C while waiting: says the build WAS uploaded" err_has "Build 2 WAS uploaded to App Store Connect"
check "Ctrl-C while waiting: names the interrupted step" err_has 'FAILED during "8. Post-upload'
check "Ctrl-C while waiting: keychain search list restored" keychains_restored

new_case tag-exists
git -C "$FIXTURE" tag -a build-2 -m "stale local tag"
run_lane
check "a local build-N tag already exists: lane exits non-zero" rc_nonzero
check "existing tag: says so and how to push it" err_has "tag build-2 already exists locally; build 2 is VALID and in Family."
check "existing tag: nothing was pushed" test -z "$(git -C "$CASE_DIR/origin.git" tag -l 'build-*')"

new_case tag-push-fails
git -C "$FIXTURE" remote set-url --push origin "$CASE_DIR/does-not-exist.git"
run_lane
check "tag push fails: lane exits non-zero" rc_nonzero
check "tag push fails: says the build is VALID and in Family but the push failed" err_has "build 2 is VALID and in Family, but pushing the tag failed."
check "tag push fails: gives the exact command to run by hand" err_has "git push origin refs/tags/build-2"
check "tag push fails: the tag exists locally and is annotated" tag_is_annotated 2
check "tag push fails: nothing reached origin" test -z "$(git -C "$CASE_DIR/origin.git" tag -l 'build-*')"

# Failures before the upload never call App Store Connect and never tag.
new_case upload-fails-no-asc
run_lane UPLOAD_MODE=fail
check "upload fails: asc.swift is never called" no_asc_calls
check "upload fails: NO tag" no_tag 2
check "upload fails: still says nothing was uploaded" err_lacks "WAS uploaded"
new_case scan-fails-no-asc
run_lane SEED_KEY=text
check "seeded key: asc.swift is never called" no_asc_calls
check "seeded key: NO tag" no_tag 2

# ================================================================= (d) =======
group "(d) op-run.sh: service-account token from .env, or interactive 1Password"

# Every case runs a COPY of the real scripts/op-run.sh (and the Makefile) in a
# fixture directory with its own .env, never the repository's: the real
# $ROOT/.env, if there is one, holds a live token and is not touched here. `op`
# is a stub that records its arguments and whether the token was in its
# environment (never the value). The token below is fake and built at runtime.
fake_token() { printf 'ops_%s' FAKE_TEST_ONLY_not_a_real_token_0000; }

STUB_BIN="$TMP/stubbin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/op" <<'EOF'
#!/bin/bash
# Test double for the 1Password CLI. Logs to $OP_LOG one line per call with the
# arguments and whether the token was present and equal to the expected one,
# never the token itself. OP_MODE=fail makes `op vault get` fail;
# OP_MODE=fail-echo-token makes it fail while printing the token (a hostile op).
token=absent
matches=no
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN+x}" ]; then token=present; fi
if [ -n "${EXPECTED_TOKEN:-}" ] && [ "${OP_SERVICE_ACCOUNT_TOKEN:-}" = "$EXPECTED_TOKEN" ]; then matches=yes; fi
printf 'op: %s | token=%s matches=%s\n' "$*" "$token" "$matches" >>"$OP_LOG"
printf 'ps: %s\n' "$(ps -o command= -p $$)" >>"$OP_LOG"
case "$1" in
  vault)
    case "${OP_MODE:-ok}" in
      fail)
        echo "[ERROR] 2026/01/01 00:00:00 unauthorized: the service account token is not valid" >&2
        exit 1
        ;;
      fail-echo-token)
        echo "[ERROR] 2026/01/01 00:00:00 invalid token ${OP_SERVICE_ACCOUNT_TOKEN:-none}" >&2
        exit 1
        ;;
    esac
    ;;
  run)
    while [ "$1" != "--" ]; do shift; done
    shift
    exec "$@"
    ;;
esac
EOF
chmod +x "$STUB_BIN/op"

# A stand-in for scripts/release.sh: records that it ran and what it could see.
cat >"$STUB_BIN/release-stand-in" <<'EOF'
#!/bin/bash
printf 'child: ran args=%s\n' "$*" >>"$OP_LOG"
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN+x}" ]; then
  printf 'child: token=present\n' >>"$OP_LOG"
else
  printf 'child: token=absent\n' >>"$OP_LOG"
fi
if [ -n "${OTHER_VAR+x}" ]; then
  printf 'child: other_var=present\n' >>"$OP_LOG"
else
  printf 'child: other_var=absent\n' >>"$OP_LOG"
fi
EOF
chmod +x "$STUB_BIN/release-stand-in"

# A stand-in for `swift` (so `make testflight-status` never reaches App Store
# Connect): records its arguments and what it can see. ASC_* values are fake and
# are never logged, only whether they were set.
cat >"$STUB_BIN/swift" <<'EOF'
#!/bin/bash
printf 'swift: args=%s\n' "$*" >>"$OP_LOG"
if [ -n "${OP_SERVICE_ACCOUNT_TOKEN+x}" ]; then
  printf 'swift: token=present\n' >>"$OP_LOG"
else
  printf 'swift: token=absent\n' >>"$OP_LOG"
fi
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_PRIVATE_KEY_BASE64:-}" ]; then
  printf 'swift: asc_vars=set\n' >>"$OP_LOG"
else
  printf 'swift: asc_vars=missing\n' >>"$OP_LOG"
fi
echo "asc: newest build 7: state=VALID (stub)"
EOF
chmod +x "$STUB_BIN/swift"

OPR="" OP_LOG=""
oprun_case() { # name: a fixture "repo" holding copies of the real script and Makefile
  mkdir -p "$TMP/oprun/$1"
  # Normalised the way op-run.sh derives its own ROOT (TMPDIR may end in a "/").
  OPR=$(cd "$TMP/oprun/$1" && pwd)
  mkdir -p "$OPR/scripts" "$OPR/release"
  cp -f "$ROOT/scripts/op-run.sh" "$OPR/scripts/op-run.sh"
  cp -f "$ROOT/Makefile" "$OPR/Makefile"
  cp -f "$ROOT/release/.env.example" "$OPR/release/.env.example"
  cp -f "$STUB_BIN/release-stand-in" "$OPR/scripts/release.sh"
}
write_dotenv() { # mode, line...: the fixture's .env, created owner-only, then chmod'ed
  local mode="$1"
  shift
  (umask 077 && printf '%s\n' "$@" >"$OPR/.env")
  chmod "$mode" "$OPR/.env"
}
valid_dotenv() { write_dotenv "${1:-600}" "# local" "OP_SERVICE_ACCOUNT_TOKEN=$(fake_token)"; }

# run_oprun [VAR=value | -u VAR]... -- command [args...]: runs the command in
# the current fixture with the stub op first on PATH and no token in the
# environment, unless an override adds one.
run_oprun() {
  OP_LOG="$OPR/op.log"
  STDOUT="$OPR/stdout"
  STDERR="$OPR/stderr"
  : >"$OP_LOG"
  RC=0
  (
    export OP_LOG
    export EXPECTED_TOKEN
    EXPECTED_TOKEN=$(fake_token)
    export PATH="$STUB_BIN:$PATH"
    unset OP_SERVICE_ACCOUNT_TOKEN OP_MODE OTHER_VAR
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      if [ "$1" = "-u" ]; then
        unset "$2"
        shift 2
      else
        export "${1?}"
        shift
      fi
    done
    shift
    cd "$OPR"
    exec "$@"
  ) >"$STDOUT" 2>"$STDERR" || RC=$?
}

oplog_has() { grep -qxF -- "$1" "$OP_LOG"; }
oplog_lacks() { ! grep -qF -- "$1" "$OP_LOG"; }
token_nowhere() { ! grep -qF -- "$(fake_token)" "$STDOUT" "$STDERR" "$OP_LOG"; }
op_never_called() { ! grep -q '^op: ' "$OP_LOG"; }
release_not_run() { oplog_lacks "child: ran"; }
auth_before_run() {
  local auth run
  auth=$(grep -n '^op: vault get OpenMoji ' "$OP_LOG" | sed -n '1s/:.*//p')
  run=$(grep -n '^op: run ' "$OP_LOG" | sed -n '1s/:.*//p')
  [ -n "$auth" ] && [ -n "$run" ] && [ "$auth" -lt "$run" ]
}

# --- .env present: the token reaches op, and only op ---------------------------
oprun_case dotenv-ok
write_dotenv 600 "# a comment" "OTHER_VAR=should-not-be-exported" "BAD=\$(touch $OPR/pwned)" "OP_SERVICE_ACCOUNT_TOKEN=$(fake_token)"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh one two
check ".env present: exits 0" rc_is 0
check ".env present: auth check ran with the token in op's environment" oplog_has "op: vault get OpenMoji | token=present matches=yes"
check ".env present: op run ran with the same token in its environment" \
  oplog_has "op: run --env-file $OPR/release/.env.example -- /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN scripts/release.sh one two | token=present matches=yes"
check ".env present: the auth check came before op run" auth_before_run
check ".env present: the release script ran, with its arguments" oplog_has "child: ran args=one two"
check ".env present: the release script does not inherit the token" oplog_has "child: token=absent"
check ".env present: says it is using the service account from .env" err_has "service account (token from .env)"
check ".env present: the token appears in no output, log or op argv" token_nowhere
check ".env present: other lines are not exported" oplog_has "child: other_var=absent"
check ".env present: the file is not evaluated as shell code" test ! -e "$OPR/pwned"

oprun_case dotenv-xtrace
valid_dotenv
run_oprun -- /bin/bash -x "$OPR/scripts/op-run.sh" scripts/release.sh
check "bash -x: still runs the release script" oplog_has "child: ran args="
check "bash -x: the token appears in no output, log or op argv" token_nowhere

oprun_case dotenv-double-quoted
write_dotenv 600 "OP_SERVICE_ACCOUNT_TOKEN=\"$(fake_token)\""
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "double-quoted value: quotes are stripped" oplog_has "op: vault get OpenMoji | token=present matches=yes"

oprun_case dotenv-single-quoted
write_dotenv 600 "OP_SERVICE_ACCOUNT_TOKEN='$(fake_token)'"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "single-quoted value: quotes are stripped" oplog_has "op: vault get OpenMoji | token=present matches=yes"

oprun_case dotenv-crlf
(umask 077 && printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\r\n' "$(fake_token)" >"$OPR/.env")
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "CRLF line ending: the carriage return is not part of the token" oplog_has "op: vault get OpenMoji | token=present matches=yes"

oprun_case dotenv-no-newline
(umask 077 && printf 'OP_SERVICE_ACCOUNT_TOKEN=%s' "$(fake_token)" >"$OPR/.env")
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "no trailing newline: the last line is still read" oplog_has "op: vault get OpenMoji | token=present matches=yes"

oprun_case dotenv-400
valid_dotenv 400
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "mode 400 (owner read-only): accepted" rc_is 0

oprun_case dotenv-symlink
valid_dotenv
mv -f "$OPR/.env" "$OPR/real-dotenv"
ln -s real-dotenv "$OPR/.env"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "symlinked .env to an owner-only file: accepted" rc_is 0

# --- .env readable by others: refused, before op is called ---------------------
for mode in 644 640 604 666 755; do
  oprun_case "dotenv-mode-$mode"
  valid_dotenv "$mode"
  run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
  check ".env mode $mode: refused (exit non-zero)" rc_nonzero
  check ".env mode $mode: says the mode and how to fix it" err_has "readable by other users (mode $mode). Run: chmod 600 "
  check ".env mode $mode: op was never called" op_never_called
  check ".env mode $mode: the release script did not run" release_not_run
  check ".env mode $mode: the token appears in no output, log or op argv" token_nowhere
done

# --- .env present but unusable -------------------------------------------------
oprun_case dotenv-empty
write_dotenv 600 "OP_SERVICE_ACCOUNT_TOKEN="
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check ".env with the empty placeholder: refused" rc_nonzero
check ".env with the empty placeholder: says it is empty" err_has "OP_SERVICE_ACCOUNT_TOKEN is empty"
check ".env with the empty placeholder: op was never called" op_never_called

oprun_case dotenv-no-token-line
write_dotenv 600 "# nothing useful" "OTHER_VAR=1"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check ".env without the token line: refused" rc_nonzero
check ".env without the token line: says so" err_has "has no OP_SERVICE_ACCOUNT_TOKEN= line"
check ".env without the token line: op was never called" op_never_called

oprun_case dotenv-whitespace
write_dotenv 600 "OP_SERVICE_ACCOUNT_TOKEN=$(fake_token) # trailing comment"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check ".env value with a trailing comment: refused" rc_nonzero
check ".env value with a trailing comment: says whitespace" err_has "contains whitespace or control characters"
check ".env value with a trailing comment: op was never called" op_never_called
check ".env value with a trailing comment: the token is not printed" token_nowhere

oprun_case dotenv-directory
mkdir "$OPR/.env"
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check ".env that is a directory: refused" rc_nonzero
check ".env that is a directory: says it is not a regular file" err_has "is not a regular file"

# --- .env absent: interactive 1Password ----------------------------------------
oprun_case interactive
run_oprun -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "no .env: exits 0" rc_is 0
check "no .env: says it is using interactive auth" err_has "1Password auth: interactive"
check "no .env: op ran without a token" oplog_has "op: vault get OpenMoji | token=absent matches=no"
check "no .env: op run ran without a token" \
  oplog_has "op: run --env-file $OPR/release/.env.example -- /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN scripts/release.sh | token=absent matches=no"
check "no .env: the release script ran" oplog_has "child: ran args="

oprun_case env-token-only
run_oprun "OP_SERVICE_ACCOUNT_TOKEN=$(fake_token)" -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "no .env, token already in the environment: used" oplog_has "op: vault get OpenMoji | token=present matches=yes"
check "no .env, token already in the environment: says so" err_has "service account (token from the environment)"
check "no .env, token already in the environment: the release script does not inherit it" oplog_has "child: token=absent"
check "no .env, token already in the environment: the token appears in no output, log or op argv" token_nowhere

# --- op cannot authenticate: stop before the release script --------------------
oprun_case auth-fails-service-account
valid_dotenv
run_oprun OP_MODE=fail -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "service account rejected: exits non-zero" rc_nonzero
check "service account rejected: says authentication failed" err_has "1Password authentication failed (service account (token from .env))"
check "service account rejected: says nothing was run" err_has "Nothing was run."
check "service account rejected: shows what op said" err_has "unauthorized: the service account token is not valid"
check "service account rejected: points at the token and vault access" err_has "service account has read access to the OpenMoji vault"
check "service account rejected: op run was never started" oplog_lacks "op: run "
check "service account rejected: the release script did not run" release_not_run
check "service account rejected: the token appears in no output, log or op argv" token_nowhere

oprun_case auth-fails-interactive
run_oprun OP_MODE=fail -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "interactive auth fails: exits non-zero" rc_nonzero
check "interactive auth fails: says authentication failed" err_has "1Password authentication failed (interactive)"
check "interactive auth fails: points at the app integration and .env" err_has "Integrate with the 1Password CLI"
check "interactive auth fails: op run was never started" oplog_lacks "op: run "
check "interactive auth fails: the release script did not run" release_not_run

oprun_case auth-fails-echoing-token
valid_dotenv
run_oprun OP_MODE=fail-echo-token -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "op error that contains the token: exits non-zero" rc_nonzero
check "op error that contains the token: it is replaced with <redacted>" err_has "invalid token <redacted>"
check "op error that contains the token: the token appears in no output, log or op argv" token_nowhere

# --- op-run.sh --check (make op-check) -----------------------------------------
oprun_case check-ok
valid_dotenv
run_oprun -- "$OPR/scripts/op-run.sh" --check
check "--check: exits 0 when authenticated" rc_is 0
check "--check: says ok" out_has "op-run: ok, authenticated (service account (token from .env))"
check "--check: only the auth check runs (no op run, no release script)" oplog_lacks "op: run "
check "--check: the token appears in no output, log or op argv" token_nowhere
run_oprun OP_MODE=fail -- "$OPR/scripts/op-run.sh" --check
check "--check: exits non-zero when authentication fails" rc_nonzero
check "--check: says authentication failed" err_has "1Password authentication failed"
run_oprun -- "$OPR/scripts/op-run.sh" --check extra
check "--check with extra arguments: usage, exit 2" rc_is 2
check "--check with extra arguments: op was never called" op_never_called

# --- the other op-run.sh preconditions -----------------------------------------
oprun_case usage
run_oprun -- "$OPR/scripts/op-run.sh"
check "no command: prints usage and exits 2" rc_is 2
check "no command: usage names --check" err_has "scripts/op-run.sh --check"

oprun_case op-missing
valid_dotenv
run_oprun PATH=/usr/bin:/bin -- "$OPR/scripts/op-run.sh" scripts/release.sh
check "op missing: exits non-zero" rc_nonzero
check "op missing: clear error" err_has "1Password CLI"
check "op missing: the token appears in no output" token_nowhere

# --- make testflight and make op-check go through the same script --------------
oprun_case make-service-account
valid_dotenv
run_oprun -- make testflight
check "make testflight with .env: exits 0, non-interactively" rc_is 0
check "make testflight with .env: ran the release script through op run" oplog_has "child: ran args="
check "make testflight with .env: used the service account" err_has "service account (token from .env)"
check "make testflight with .env: the token appears in no output, log or op argv" token_nowhere

oprun_case make-interactive
run_oprun -- make testflight
check "make testflight without .env: exits 0, interactively" rc_is 0
check "make testflight without .env: ran the release script through op run" oplog_has "child: ran args="
check "make testflight without .env: used interactive auth" err_has "1Password auth: interactive"

oprun_case make-auth-fails
valid_dotenv
run_oprun OP_MODE=fail -- make testflight
check "make testflight, auth fails: exits non-zero" rc_nonzero
check "make testflight, auth fails: the release script did not run" release_not_run
check "make testflight, auth fails: the token appears in no output, log or op argv" token_nowhere

oprun_case make-op-check
valid_dotenv
run_oprun -- make op-check
check "make op-check: exits 0 and only checks auth" rc_is 0
check "make op-check: no op run, no release script" oplog_lacks "op: run "
check "make op-check: the token appears in no output, log or op argv" token_nowhere

# --- make testflight-status: the same script, asc.swift latest-build -------------
oprun_case make-status
valid_dotenv
# The stub `op run` does not resolve release/.env.example, so the variables 1Password
# would inject are supplied (fake) by the caller.
run_oprun ASC_KEY_ID=ABCDE12345 ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_PRIVATE_KEY_BASE64=ZmFrZQ== -- make testflight-status
check "make testflight-status: exits 0, non-interactively" rc_is 0
check "make testflight-status: authenticated op first, then ran swift scripts/asc.swift latest-build through op run" \
  oplog_has "op: run --env-file $OPR/release/.env.example -- /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN swift scripts/asc.swift latest-build | token=present matches=yes"
check "make testflight-status: the auth check came before op run" auth_before_run
check "make testflight-status: swift got exactly scripts/asc.swift latest-build" oplog_has "swift: args=scripts/asc.swift latest-build"
check "make testflight-status: asc.swift does not inherit the 1Password token" oplog_has "swift: token=absent"
check "make testflight-status: asc.swift has the ASC_* variables" oplog_has "swift: asc_vars=set"
check "make testflight-status: prints what asc.swift printed" out_has "asc: newest build 7: state=VALID"
check "make testflight-status: the release script did not run" release_not_run
check "make testflight-status: the token appears in no output, log or op argv" token_nowhere

oprun_case make-status-auth-fails
valid_dotenv
run_oprun OP_MODE=fail -- make testflight-status
check "make testflight-status, auth fails: exits non-zero" rc_nonzero
check "make testflight-status, auth fails: swift never ran" oplog_lacks "swift: "
check "make testflight-status, auth fails: op run was never started" oplog_lacks "op: run "

# ============================================== the other lane artifacts =====
group "Makefile, .env.example files, ExportOptions.plist, .gitignore"

make_testflight_dry_run() { make -n -C "$ROOT" testflight | grep -qF "scripts/op-run.sh scripts/release.sh"; }
check "Makefile: make testflight runs op-run.sh then release.sh" make_testflight_dry_run
make_op_check_dry_run() { make -n -C "$ROOT" op-check | grep -qxF "scripts/op-run.sh --check"; }
check "Makefile: make op-check runs op-run.sh --check" make_op_check_dry_run
make_status_dry_run() { make -n -C "$ROOT" testflight-status | grep -qxF "scripts/op-run.sh swift scripts/asc.swift latest-build"; }
check "Makefile: make testflight-status runs asc.swift latest-build through op-run.sh" make_status_dry_run
make_release_test_dry_run() {
  local plan
  plan=$(make -n -C "$ROOT" release-test)
  [ "$plan" = "$(printf 'scripts/test-release.sh\nscripts/test-asc.sh\nscripts/test-inactivity-guard.sh')" ]
}
check "Makefile: make release-test runs test-release.sh, test-asc.sh, then test-inactivity-guard.sh" make_release_test_dry_run

# The root .env.example is the committed template for the git-ignored .env.
root_env_assignments() { grep -vE '^[[:space:]]*(#|$)' "$ROOT/.env.example"; }
root_env_is_only_the_empty_placeholder() { [ "$(root_env_assignments)" = "OP_SERVICE_ACCOUNT_TOKEN=" ]; }
check "root .env.example: only an empty OP_SERVICE_ACCOUNT_TOKEN= placeholder" root_env_is_only_the_empty_placeholder
check "root .env.example: says to chmod 600" grep -qF "chmod 600" "$ROOT/.env.example"
check "root .env.example: says to scope it read-only to the OpenMoji vault" grep -qF "read-only to the OpenMoji vault" "$ROOT/.env.example"
check "root .env.example: says never to commit .env" grep -qiF "never commit" "$ROOT/.env.example"

env_names() { sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' "$ROOT/release/.env.example"; }
env_lines_are_op_refs() {
  local lines
  lines=$(grep -E '^[A-Z0-9_]+=' "$ROOT/release/.env.example") || return 1
  ! grep -qv '=op://OpenMoji/' <<<"$lines"
}
every_required_var_is_listed() {
  local var required listed
  required=$(/bin/bash -c "source '$ROOT/scripts/release.sh'; printf '%s\n' \"\${REQUIRED_ENV[@]}\"")
  listed=$(env_names)
  for var in $required; do
    grep -qx "$var" <<<"$listed" || return 1
  done
}
check ".env.example: every value is an op://OpenMoji/ reference" env_lines_are_op_refs
check ".env.example: signing keychain password at the runbook's path" \
  grep -qxF "SIGNING_KEYCHAIN_PASSWORD=op://OpenMoji/openmoji-signing-keychain/password" "$ROOT/release/.env.example"
check ".env.example: lists every variable release.sh requires" every_required_var_is_listed

plist_is() { [ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/release/ExportOptions.plist")" = "$2" ]; }
plist_lints() { plutil -lint "$ROOT/release/ExportOptions.plist" >/dev/null; }
check "ExportOptions.plist: valid" plist_lints
check "ExportOptions.plist: method app-store-connect" plist_is method app-store-connect
check "ExportOptions.plist: destination upload" plist_is destination upload
check "ExportOptions.plist: teamID AB5S94XWRQ" plist_is teamID AB5S94XWRQ
check "ExportOptions.plist: signingStyle manual" plist_is signingStyle manual
check "ExportOptions.plist: signingCertificate Apple Distribution" plist_is signingCertificate "Apple Distribution"
check "ExportOptions.plist: app profile" plist_is "provisioningProfiles:com.backhaushold.openmoji" "OpenMoji App Store"
check "ExportOptions.plist: extension profile" plist_is "provisioningProfiles:com.backhaushold.openmoji.MessagesExtension" "OpenMoji Messages App Store"
check "ExportOptions.plist: uploadSymbols true" plist_is uploadSymbols true
check "ExportOptions.plist: testFlightInternalTestingOnly true" plist_is testFlightInternalTestingOnly true
check "ExportOptions.plist: manageAppVersionAndBuildNumber false" plist_is manageAppVersionAndBuildNumber false

not_ignored() { ! git -C "$ROOT" check-ignore -q "$1"; }
check ".gitignore: build/release output is ignored" git -C "$ROOT" check-ignore -q build/release/OpenMoji-1.xcarchive
check ".gitignore: .p8 keys are ignored" git -C "$ROOT" check-ignore -q AuthKey_ABCDE12345.p8
check ".gitignore: release/.env.example is not ignored" not_ignored release/.env.example
check ".gitignore: the local .env is ignored" git -C "$ROOT" check-ignore -q .env
check ".gitignore: the root .env.example template is not ignored" not_ignored .env.example

no_profile_override_in_script() { ! grep -v '^[[:space:]]*#' "$ROOT/scripts/release.sh" | grep -q 'PROVISIONING_PROFILE_SPECIFIER'; }
check "release.sh: no PROVISIONING_PROFILE_SPECIFIER outside comments" no_profile_override_in_script
# shellcheck disable=SC2016 # the single-quoted $PATH is the literal text to find
check "release.sh: PATH starts with /usr/bin" grep -qxF 'export PATH="/usr/bin:$PATH"' "$ROOT/scripts/release.sh"
check "release.sh: set -euo pipefail" grep -qxF 'set -euo pipefail' "$ROOT/scripts/release.sh"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck: release.sh, op-run.sh, test-release.sh are clean" \
    shellcheck -s bash "$ROOT/scripts/release.sh" "$ROOT/scripts/op-run.sh" "$HARNESS"
else
  printf '  skip  shellcheck is not installed (brew install shellcheck)\n'
fi

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
