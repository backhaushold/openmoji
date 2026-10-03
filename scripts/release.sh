#!/bin/bash
#
# OpenMoji release lane: tech spec 12.3 steps 0-7, ADR-0010 / 0011 / 0012.
# Run it through `make testflight`, which wraps it in scripts/op-run.sh so the
# 1Password secrets from release/.env.example are in the environment.
#
# Releases publish ONLY from the local release Mac. Nothing here is meant for
# CI, and CI never signs or uploads.
#
#   0. PATH, strict mode, cleanup trap
#   1. Preflight         every check fails here, before anything is signed
#   2. Secret scan       gitleaks (REL-6)
#   3. Generate          xcodegen
#   4. Tests             swift test, OpenMojiCore (REL-7)
#   5. Keychain          unlock the signing keychain, put it first in the search list
#   6. Archive           build number = commit count (REL-3)
#   6b. Artifact scan    fail if the .xcarchive contains an sk- key
#   7. Upload            xcodebuild -exportArchive, destination=upload (REL-1, REL-4)
#
# Steps 8 (post-upload: wait for VALID, What to Test, Family group) and 9 (the
# annotated build-N tag) are not here: they are bead openmoji-2pq, which adds
# them at the marked place at the end of main().
#
# The file can be sourced without running anything (the last lines only call
# main when it is executed), so scripts/test-release.sh can drive the same
# functions with stubbed tools. Written for macOS's /bin/bash 3.2.

# Step 0. Apple's rsync first: Homebrew's breaks `xcodebuild -exportArchive`.
export PATH="/usr/bin:$PATH"
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

APP_SCHEME="OpenMoji"
EXPORT_OPTIONS="release/ExportOptions.plist"
OUTPUT_DIR="build/release" # git-ignored; archives stay here for dSYMs
# Tech spec 12.3 step 6b. Only file names are printed, never the match.
KEY_PATTERN='sk-[A-Za-z0-9_-]{20,}'

# Injected from 1Password by scripts/op-run.sh (release/.env.example).
REQUIRED_ENV=(SIGNING_KEYCHAIN_PASSWORD ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_BASE64)
# Homebrew: gh gitleaks xcodegen. The rest ship with macOS / Xcode.
REQUIRED_TOOLS=(gh gitleaks xcodegen swift xcodebuild security xcode-select base64 grep)
# Not a secret, so not in .env.example. Must not contain whitespace (it is
# passed through OTHER_CODE_SIGN_FLAGS).
SIGNING_KEYCHAIN_PATH="${SIGNING_KEYCHAIN_PATH:-$HOME/Library/Keychains/openmoji-signing.keychain-db}"

# State read by cleanup().
CURRENT_STEP="startup"
SIGNING_STARTED=0
KEYCHAINS_SAVED=0
ORIGINAL_KEYCHAINS=()
WORK_DIR="" # holds the temporary ASC .p8; removed on every exit path
BUILD_NUMBER=""
ARCHIVE_PATH=""

log() { printf 'release: %s\n' "$*"; }
step() {
  CURRENT_STEP="$1"
  printf '\n==> %s\n' "$1"
}
# Never call from inside $(...): exit would only leave the subshell.
die() {
  printf 'release: ERROR: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- cleanup ----

remove_asc_key() {
  if [ -n "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR" || printf 'release: WARNING: could not remove %s, delete it by hand\n' "$WORK_DIR" >&2
    WORK_DIR=""
  fi
}

restore_keychains() {
  if [ "$KEYCHAINS_SAVED" -eq 1 ]; then
    KEYCHAINS_SAVED=0
    if [ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
        || printf 'release: WARNING: could not restore the keychain search list; check: security list-keychains -d user\n' >&2
    fi
  fi
}

# EXIT trap. INT/TERM/HUP are routed here by main() via `exit`, so the key and
# the search list are cleaned up on success, failure and signals alike.
cleanup() {
  local rc=$?
  trap '' INT TERM HUP # finish cleaning up even if another signal arrives
  trap - EXIT
  remove_asc_key
  restore_keychains
  if [ "$rc" -ne 0 ]; then
    printf 'release: FAILED during "%s" (exit %s).' "$CURRENT_STEP" "$rc" >&2
    if [ "$SIGNING_STARTED" -eq 0 ]; then
      printf ' Nothing was signed or uploaded.' >&2
    fi
    if [ -n "$ARCHIVE_PATH" ] && [ -d "$ARCHIVE_PATH" ]; then
      printf ' Archive kept at %s.' "$ARCHIVE_PATH" >&2
    fi
    printf '\n' >&2
  fi
  exit "$rc"
}

# ------------------------------------------------------- 1. preflight --------

preflight_tools() {
  local tool missing=""
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="$missing $tool"
    fi
  done
  if [ -n "$missing" ]; then
    die "missing tools:$missing. Install with: brew install xcodegen gitleaks gh (runbook 2.0); Xcode provides the rest."
  fi
}

preflight_env() {
  local name value missing=""
  for name in "${REQUIRED_ENV[@]}"; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      missing="$missing $name"
    elif [ "${value#op://}" != "$value" ]; then
      die "$name still holds an unresolved op:// reference. Run through 'make testflight' so scripts/op-run.sh resolves it."
    fi
  done
  if [ -n "$missing" ]; then
    die "required environment missing:$missing. Run through 'make testflight' (scripts/op-run.sh injects them from 1Password via release/.env.example), not release.sh directly."
  fi
  case "$ASC_KEY_ID" in
    *[!A-Za-z0-9]*) die "ASC_KEY_ID contains unexpected characters; expected the 10-character key ID." ;;
  esac
}

preflight_files() {
  [ -f "$REPO_ROOT/$EXPORT_OPTIONS" ] || die "$EXPORT_OPTIONS not found."
  case "$SIGNING_KEYCHAIN_PATH" in
    *[[:space:]]*) die "SIGNING_KEYCHAIN_PATH must not contain whitespace: $SIGNING_KEYCHAIN_PATH" ;;
  esac
  [ -f "$SIGNING_KEYCHAIN_PATH" ] \
    || die "signing keychain not found at $SIGNING_KEYCHAIN_PATH. Create it per runbook 2.3."
}

preflight_xcode_select() {
  local dev
  dev=$(xcode-select -p 2>&1) || die "xcode-select -p failed: $dev"
  case "$dev" in
    */Xcode*.app/Contents/Developer) ;;
    *) die "xcode-select points at '$dev', not a full Xcode.app. Fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" ;;
  esac
}

preflight_clean_tree() {
  local dirty
  dirty=$(git status --porcelain) || die "git status failed."
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty" | sed -n '1,10p' >&2
    die "working tree is not clean (changes listed above). Land them via PR, then release from a clean checkout of main."
  fi
}

preflight_on_main() {
  local branch
  branch=$(git symbolic-ref --short -q HEAD) || branch="(detached HEAD)"
  [ "$branch" = "main" ] \
    || die "on '$branch'; releases are cut from main only. Fix: git switch main && git pull --ff-only"
}

preflight_head_is_origin_main() {
  local head remote counts ahead behind
  git fetch --quiet origin main || die "could not fetch origin/main (network or credentials)."
  head=$(git rev-parse HEAD)
  remote=$(git rev-parse refs/remotes/origin/main)
  if [ "$head" != "$remote" ]; then
    counts=$(git rev-list --left-right --count "HEAD...refs/remotes/origin/main")
    ahead="${counts%%[[:space:]]*}"
    behind="${counts##*[[:space:]]}"
    die "HEAD (${head:0:9}) is not origin/main (${remote:0:9}): $ahead commit(s) ahead, $behind behind. The build number is the commit count, so releases must come from exactly origin/main. Fix: git pull --ff-only, or land the local commits via PR first."
  fi
}

# CI must be green on HEAD itself: the `verify` check run exists, every check
# run is completed, and none failed. `gh` does the jq filtering, one
# "name<TAB>status<TAB>conclusion" line per check run.
preflight_ci_green() {
  local sha out line name status conclusion seen_verify=0 pending="" failed=""
  sha=$(git rev-parse HEAD)
  if ! out=$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "-")] | @tsv' 2>&1); then
    die "could not read CI status for ${sha:0:9} from GitHub (is gh logged in? try: gh auth status). gh said: $out"
  fi
  [ -n "$out" ] || die "no CI check runs found for ${sha:0:9} yet. Wait for the CI workflow to start on main, then run again."
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r name status conclusion <<<"$line"
    if [ "$name" = "verify" ]; then
      seen_verify=1
    fi
    if [ "$status" != "completed" ]; then
      pending="$pending $name($status)"
    else
      case "$conclusion" in
        success | neutral | skipped) ;;
        *) failed="$failed $name($conclusion)" ;;
      esac
    fi
  done <<<"$out"
  if [ -n "$failed" ]; then
    die "CI is not green on ${sha:0:9}: failed:$failed. Fix main first."
  fi
  if [ -n "$pending" ]; then
    die "CI is still running on ${sha:0:9}:$pending. Wait for it to finish, then run again."
  fi
  [ "$seen_verify" -eq 1 ] || die "CI check run 'verify' not found for ${sha:0:9}."
}

preflight() {
  step "1. Preflight"
  # Local checks first so a missing tool or variable doesn't cost a network trip.
  preflight_tools
  preflight_env
  preflight_files
  preflight_xcode_select
  preflight_clean_tree
  preflight_on_main
  preflight_head_is_origin_main
  preflight_ci_green
  log "preflight ok"
}

# ------------------------------------------------------------ 2-4 -----------

step_secret_scan() {
  step "2. Secret scan (gitleaks, REL-6)"
  gitleaks detect --redact --no-banner
}

step_generate() {
  step "3. Generate project (xcodegen)"
  xcodegen generate
}

step_unit_tests() {
  step "4. Tests (swift test, OpenMojiCore, REL-7)"
  swift test --package-path Packages/OpenMojiCore
}

# ------------------------------------------------------- 5. keychain ---------

step_keychain() {
  step "5. Signing keychain"
  local listing line identities
  local new_list=("$SIGNING_KEYCHAIN_PATH")
  listing=$(security list-keychains -d user) || die "could not read the keychain search list."
  ORIGINAL_KEYCHAINS=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      ORIGINAL_KEYCHAINS+=("$line")
      if [ "$line" != "$SIGNING_KEYCHAIN_PATH" ]; then
        new_list+=("$line")
      fi
    fi
  done < <(sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' <<<"$listing")

  # The password is on argv for an instant; `security unlock-keychain` has no
  # stdin option, and prompting would defeat an unattended run.
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN_PATH" \
    || die "could not unlock $SIGNING_KEYCHAIN_PATH (wrong SIGNING_KEYCHAIN_PASSWORD item?)."
  identities=$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN_PATH") \
    || die "could not list identities in $SIGNING_KEYCHAIN_PATH."
  grep -q "Apple Distribution" <<<"$identities" \
    || die "no valid 'Apple Distribution' identity in $SIGNING_KEYCHAIN_PATH (runbook 2.3)."

  KEYCHAINS_SAVED=1 # restored by cleanup() from here on
  security list-keychains -d user -s "${new_list[@]}"
}

# -------------------------------------------------- 6. archive, 6b. scan ------

step_archive() {
  step "6. Archive (Release, generic/platform=iOS)"
  SIGNING_STARTED=1
  BUILD_NUMBER=$(git rev-list --count HEAD)
  ARCHIVE_PATH="$REPO_ROOT/$OUTPUT_DIR/OpenMoji-$BUILD_NUMBER.xcarchive"
  mkdir -p "$REPO_ROOT/$OUTPUT_DIR"
  rm -rf "$ARCHIVE_PATH" # never scan or upload a stale archive
  log "build number $BUILD_NUMBER (commit count, REL-3)"
  # Only the build number and the --keychain flag go on the command line.
  # Signing style, identity and the per-target profiles come from project.yml;
  # a command-line PROVISIONING_PROFILE_SPECIFIER would apply to the extension
  # too (ADR-0011).
  xcodebuild archive \
    -project OpenMoji.xcodeproj \
    -scheme "$APP_SCHEME" \
    -configuration Release \
    -destination generic/platform=iOS \
    -archivePath "$ARCHIVE_PATH" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    OTHER_CODE_SIGN_FLAGS="--keychain $SIGNING_KEYCHAIN_PATH"
  [ -d "$ARCHIVE_PATH" ] || die "xcodebuild archive reported success but $ARCHIVE_PATH does not exist."
}

# Fails if any file under the path (binaries included, hence -a) has an sk-
# style key. -l prints file names only so a key can never reach the log.
scan_for_keys() {
  local target="$1" hits rc=0
  [ -e "$target" ] || die "nothing to scan at $target"
  hits=$(grep -rlaE -- "$KEY_PATTERN" "$target") || rc=$?
  case "$rc" in
    0) die "an OpenAI-style key (sk-...) was found in the build artifact; refusing to upload. Files: $(printf '%s' "$hits" | tr '\n' ' ')" ;;
    1) ;;
    *) die "artifact scan failed (grep exit $rc) for $target" ;;
  esac
}

step_scan_archive() {
  step "6b. Artifact scan (no sk- keys in the .xcarchive)"
  scan_for_keys "$ARCHIVE_PATH"
  log "no key-shaped strings in $ARCHIVE_PATH"
}

# ---------------------------------------------------------- 7. upload --------

step_upload() {
  step "7. Upload (xcodebuild -exportArchive, destination=upload)"
  local key_file export_path rc=0 first_line=""
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-release.XXXXXX")
  key_file="$WORK_DIR/AuthKey_${ASC_KEY_ID}.p8"
  export_path="$REPO_ROOT/$OUTPUT_DIR/export-$BUILD_NUMBER"

  if ! (umask 077 && printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode >"$key_file") 2>/dev/null; then
    die "ASC_PRIVATE_KEY_BASE64 is not valid base64 (runbook 2.5)."
  fi
  read -r first_line <"$key_file" || true
  [ "$first_line" = "-----BEGIN PRIVATE KEY-----" ] \
    || die "ASC_PRIVATE_KEY_BASE64 does not decode to a .p8 private key (runbook 2.5)."

  rm -rf "$export_path"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$REPO_ROOT/$EXPORT_OPTIONS" \
    -exportPath "$export_path" \
    -authenticationKeyPath "$key_file" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    || rc=$?
  remove_asc_key # as soon as it is not needed; cleanup() covers every other path
  [ "$rc" -eq 0 ] || die "exportArchive/upload failed (exit $rc); export logs are in $export_path"
}

# ------------------------------------------------------------- main ----------

main() {
  cd "$REPO_ROOT"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  preflight
  step_secret_scan
  step_generate
  step_unit_tests
  step_keychain
  step_archive
  step_scan_archive
  step_upload

  # openmoji-2pq adds steps 8 and 9 here: scripts/asc.swift wait-for-build,
  # set-whats-new, ensure-in-group, then the annotated build-$BUILD_NUMBER tag,
  # pushed only after the build is VALID (ADR-0010, tech spec 12.3).
  CURRENT_STEP="done"
  log "build $BUILD_NUMBER uploaded. NOT yet automated (openmoji-2pq): wait for processing, What to Test, Family group, build-$BUILD_NUMBER tag."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
