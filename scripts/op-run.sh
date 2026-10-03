#!/bin/bash
#
# Runs a command with the release lane's 1Password secrets in its environment.
#
#   scripts/op-run.sh scripts/release.sh
#
# `op run` reads release/.env.example (op:// references only, never values),
# resolves each reference from the OpenMoji vault and exports the values to the
# command for its lifetime only (ADR-0010, tech spec 12.3). 1Password may ask
# for approval in its app. Secrets that reach stdout/stderr are masked by `op`.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/op-run.sh <command> [args...]   (normally: scripts/op-run.sh scripts/release.sh)" >&2
  exit 2
fi

if ! command -v op >/dev/null 2>&1; then
  echo "op-run: the 1Password CLI (op) is not installed or not on PATH. brew install --cask 1password-cli (runbook 2.0)" >&2
  exit 1
fi

cd "$ROOT"
exec op run --env-file "$ROOT/release/.env.example" -- "$@"
