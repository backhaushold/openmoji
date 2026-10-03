#!/bin/bash
#
# Runs a command with the release lane's 1Password secrets in its environment.
#
#   scripts/op-run.sh scripts/release.sh
#   scripts/op-run.sh --check          1Password auth check only (make op-check)
#
# `op run` reads release/.env.example (op:// references only, never values),
# resolves each reference from the OpenMoji vault and exports the values to the
# command for its lifetime only (ADR-0010, tech spec 12.3). Secrets that reach
# stdout/stderr are masked by `op`.
#
# Two ways to authenticate `op` (ADR-0016, runbook 2.6):
#
#   service account  <repo>/.env holds OP_SERVICE_ACCOUNT_TOKEN=<token>. Unattended;
#                    no 1Password prompt. The file must be owner-only (mode 600).
#   interactive      No .env: `op` uses the 1Password desktop app, which may ask
#                    for approval.
#
# The token handling is deliberately narrow:
#   - .env is never sourced or evaluated; only the OP_SERVICE_ACCOUNT_TOKEN line
#     is read, as plain text, and every other line is ignored.
#   - The token travels in the environment only: never argv, never echoed. Any
#     `op` error text is scrubbed of it before it is shown, and tracing is off.
#   - `op` gets it; the command it runs does not (env -u below), so xcodebuild,
#     swift test and anything else the lane starts never sees it.
set -euo pipefail
# Tracing (bash -x, SHELLOPTS) would print the token assignment; this script
# never needs it.
set +x

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VAULT="OpenMoji"
TOKEN_VAR="OP_SERVICE_ACCOUNT_TOKEN"
AUTH_MODE="interactive"

say() { printf 'op-run: %s\n' "$*" >&2; }
die() {
  say "ERROR: $*"
  exit 1
}

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/op-run.sh <command> [args...]   (normally: scripts/op-run.sh scripts/release.sh)" >&2
  echo "       scripts/op-run.sh --check               (1Password auth check only)" >&2
  exit 2
fi
if [ "$1" = "--check" ] && [ "$#" -ne 1 ]; then
  echo "usage: scripts/op-run.sh --check" >&2
  exit 2
fi

if ! command -v op >/dev/null 2>&1; then
  die "the 1Password CLI (op) is not installed or not on PATH. brew install --cask 1password-cli (runbook 2.0)"
fi

# Reads $ROOT/.env, if there is one, and exports the service-account token.
# Called once, before anything else; sets AUTH_MODE.
load_service_account_token() {
  local env_file="$ROOT/.env"
  if [ ! -e "$env_file" ] && [ ! -L "$env_file" ]; then
    # No .env: an OP_SERVICE_ACCOUNT_TOKEN already exported by the caller is
    # still honoured (op reads it itself); otherwise the desktop app.
    if [ -n "${!TOKEN_VAR:-}" ]; then
      AUTH_MODE="service account (token from the environment)"
    fi
    return 0
  fi

  [ -f "$env_file" ] || die "$env_file is not a regular file (or a link to one). Remove it, or fix it (runbook 2.6)."
  [ -O "$env_file" ] || die "$env_file is not owned by you. Fix it (runbook 2.6)."
  local mode
  mode=$(stat -L -f %Lp "$env_file") || die "cannot read the mode of $env_file."
  if [ $((8#$mode & 8#077)) -ne 0 ]; then
    die "$env_file is readable by other users (mode $mode). Run: chmod 600 $env_file"
  fi
  [ -r "$env_file" ] || die "$env_file is not readable by you (mode $mode). Run: chmod 600 $env_file"

  local line value="" found=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      "$TOKEN_VAR="*)
        value=${line#"$TOKEN_VAR="}
        found=1
        ;;
    esac
  done <"$env_file"

  case $value in
    \"*\") value=${value#\"} value=${value%\"} ;;
    \'*\') value=${value#\'} value=${value%\'} ;;
  esac

  # None of these messages contain the value.
  if [ "$found" -eq 0 ]; then
    die "$env_file has no $TOKEN_VAR= line. Add it (see .env.example), or delete the file to use interactive 1Password auth."
  fi
  if [ -z "$value" ]; then
    die "$TOKEN_VAR is empty in $env_file. Fill it in (runbook 2.6), or delete the file to use interactive 1Password auth."
  fi
  case $value in
    *[[:space:]]* | *[[:cntrl:]]*)
      die "$TOKEN_VAR in $env_file contains whitespace or control characters. Expected one line: $TOKEN_VAR=<token>, no spaces, no trailing comment."
      ;;
  esac

  export "$TOKEN_VAR=$value"
  AUTH_MODE="service account (token from .env)"
}

# One fast call that proves `op` is authenticated and can see the vault, so a
# bad token or a locked 1Password stops here, before the lane starts. Metadata
# only: no item or field is read.
check_op_auth() {
  local err
  if ! err=$(op vault get "$VAULT" 2>&1 >/dev/null); then
    local token="${!TOKEN_VAR:-}"
    if [ -n "$token" ]; then
      err=${err//"$token"/<redacted>}
    fi
    say "ERROR: 1Password authentication failed ($AUTH_MODE); cannot read the $VAULT vault. Nothing was run."
    if [ -n "$err" ]; then
      printf 'op-run:   op said: %s\n' "$err" >&2
    fi
    case $AUTH_MODE in
      "service account"*)
        say "Check that the token is current (not revoked or expired) and that its service account has read access to the $VAULT vault (runbook 2.6). To use the 1Password app instead, delete $ROOT/.env and unset $TOKEN_VAR."
        ;;
      *)
        say "Unlock the 1Password app and turn on Settings, Developer, Integrate with the 1Password CLI, or set up a service account token in $ROOT/.env (runbook 2.6)."
        ;;
    esac
    exit 1
  fi
}

load_service_account_token
say "1Password auth: $AUTH_MODE"
check_op_auth

if [ "$1" = "--check" ]; then
  echo "op-run: ok, authenticated ($AUTH_MODE) and the $VAULT vault is readable"
  exit 0
fi

cd "$ROOT"
exec op run --env-file "$ROOT/release/.env.example" -- /usr/bin/env -u "$TOKEN_VAR" "$@"
