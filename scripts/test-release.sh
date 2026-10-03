#!/bin/bash
#
# Self-test for the release lane (bead openmoji-4kq). Run: make release-test
#
# Signs nothing, uploads nothing, never touches the network, 1Password, App
# Store Connect or the real keychain. Each case runs the REAL scripts/release.sh
# (a copy inside a throwaway git repo with a local bare "origin") in a child
# bash that sources it and replaces the external tools (gh, gitleaks, xcodegen,
# swift, xcodebuild, security, xcode-select) with shell functions that log
# their calls. "Nothing signed" means: no `security unlock-keychain` and no
# `xcodebuild archive` / `-exportArchive` in that log.
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
    log_call "swift $*"
    if [ "${FAIL_AT:-}" = swift ]; then return 1; fi
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
unset SIGNING_KEYCHAIN_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64 SIGNING_KEYCHAIN_PATH

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
CASE_DIR="" FIXTURE="" RC=0 CALL_LOG="" PROBE="" STDOUT="" STDERR="" KEYCHAIN="" EXPECTED_P8=""

# -- predicates over the last run ---------------------------------------------
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nonzero() { [ "$RC" -ne 0 ]; }
err_has() { grep -qF -- "$1" "$STDERR"; }
out_has() { grep -qF -- "$1" "$STDOUT"; }
log_has() { grep -qE -- "$1" "$CALL_LOG"; }
log_lacks() { ! grep -qE -- "$1" "$CALL_LOG"; }
probe_has() { grep -qxF -- "$1" "$PROBE"; }
probe_lacks() { ! grep -q -- "$1" "$PROBE"; }
nothing_signed() { log_lacks '^security unlock-keychain|^xcodebuild archive|^xcodebuild -exportArchive'; }
nothing_past_preflight() { log_lacks '^(gitleaks|xcodegen|swift|security|xcodebuild) '; }
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

# run_lane [VAR=value | -u VAR]...: run the lane in the current case with a
# complete, valid environment; the arguments override it.
run_lane() {
  CALL_LOG="$CASE_DIR/calls.log"
  PROBE="$CASE_DIR/probe.log"
  STDOUT="$CASE_DIR/stdout"
  STDERR="$CASE_DIR/stderr"
  : >"$CALL_LOG"
  : >"$PROBE"
  RC=0
  (
    export FIXTURE CALL_LOG PROBE EXPECTED_P8
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
check "steps run in spec order" order_is '^gh api' '^gitleaks ' '^xcodegen ' '^swift ' '^security unlock-keychain' '^xcodebuild archive' '^xcodebuild -exportArchive'
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
check "final message says steps 8-9 are not automated yet" out_has "openmoji-2pq"

# ============================================== the other lane artifacts =====
group "Makefile, op-run.sh, .env.example, ExportOptions.plist, .gitignore"

STUB_BIN="$TMP/stubbin"
OP_LOG="$TMP/op.log"
mkdir -p "$STUB_BIN"
: >"$OP_LOG"
cat >"$STUB_BIN/op" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$OP_LOG"
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOF
chmod +x "$STUB_BIN/op"
RC=0
OP_LOG="$OP_LOG" PATH="$STUB_BIN:$PATH" "$ROOT/scripts/op-run.sh" /usr/bin/true || RC=$?
check "op-run.sh: runs the command through op" rc_is 0
check "op-run.sh: op run --env-file release/.env.example -- <command>" \
  grep -qxF "run --env-file $ROOT/release/.env.example -- /usr/bin/true" "$OP_LOG"
STDERR="$TMP/op-run.err"
RC=0
env PATH=/usr/bin:/bin "$ROOT/scripts/op-run.sh" /usr/bin/true 2>"$STDERR" || RC=$?
check "op-run.sh: clear error when op is missing" err_has "1Password CLI"
check "op-run.sh: missing op exits non-zero" rc_nonzero
RC=0
"$ROOT/scripts/op-run.sh" 2>"$STDERR" || RC=$?
check "op-run.sh: no command prints usage and exits 2" rc_is 2

make_testflight_dry_run() { make -n -C "$ROOT" testflight | grep -qF "scripts/op-run.sh scripts/release.sh"; }
check "Makefile: make testflight runs op-run.sh then release.sh" make_testflight_dry_run

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
