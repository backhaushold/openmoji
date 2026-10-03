# ADR-0016: 1Password service account for non-interactive release auth

- **Status:** Proposed (the choice of a service account is the user's, per bead `openmoji-pxc.3`; the loader details below are for review with this PR)
- **Date:** 2026-10-02

## Context
[ADR-0010](0010-local-release-lane.md)'s lane resolves its secrets with `op run --env-file release/.env.example`, which assumes the 1Password desktop app: `op` asks the app for approval, so a release needs a person at the keyboard to approve and the 1Password app unlocked. The owner wants `make testflight` to run without that prompt, authenticating `op` with a **1Password service account** instead. A service account is authenticated by one token in `OP_SERVICE_ACCOUNT_TOKEN`; scoped to a vault, it can read only what it is granted.

The token is itself a credential. It must live somewhere the lane can read it, and it must never reach output, logs, process arguments, commits, or an AI agent's context.

## Decision
- **The token lives in a git-ignored `.env` at the repo root.** A committed `.env.example` holds the placeholder `OP_SERVICE_ACCOUNT_TOKEN=` and the instructions. `.gitignore` ignores `.env`, not `.env.example`.
- **The service account is scoped read-only to the `OpenMoji` vault** (`read_items` only), the vault that holds the signing-keychain password and the App Store Connect API key. It is created with the minimum access the lane needs.
- **`scripts/op-run.sh` is the only code that reads `.env`.** If the file exists:
  - It must be a regular file (or a link to one), owned by the user, with **no group or other permission bits** (mode 600; 400 also passes). Otherwise the script refuses with the `chmod` fix and does nothing else.
  - It is **never sourced or evaluated.** The script reads it as text and takes only the `OP_SERVICE_ACCOUNT_TOKEN=` line (last one wins; one pair of surrounding quotes and a trailing CR are tolerated). Every other line is ignored, so nothing in the file can run code or leak other variables. An absent line, an empty value (the unedited placeholder) or a value with whitespace is an error, not a silent fallback to interactive auth.
  - The value is exported to `op` through the environment only: never in argv, never echoed, tracing off (`set +x`), and any `op` error text is scrubbed of it before display.
- **If `.env` is absent, nothing changes:** `op` falls back to interactive 1Password app approval. A `OP_SERVICE_ACCOUNT_TOKEN` already exported in the caller's environment is also honoured (and `.env`, when present, takes precedence over it).
- **A fast auth check runs first:** `op vault get OpenMoji` (vault metadata only; no item or field is read). If it fails, the script stops with what `op` said plus a hint for the mode in use, before `release.sh` or anything else starts. `make op-check` (`scripts/op-run.sh --check`) runs only this check.
- **The released command does not inherit the token.** `op run` would pass `OP_SERVICE_ACCOUNT_TOKEN` through to its child, so `op-run.sh` runs `op run ... -- /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN <command>`. `op` gets the token; `release.sh`, `xcodebuild`, `swift test`, `gitleaks` and any build phase do not.
- `make release-test` covers both modes with a stub `op` and a fake token in a fixture directory (never the repo's `.env`): the token reaches `op`'s environment, appears in no output, log or argv, a world-readable `.env` is refused, an absent `.env` takes the interactive path, and an `op` failure stops before `release.sh`.

## Alternatives
- **Keep interactive approval only.** Nothing new to protect, but every release needs a human to unlock and approve, which defeats an unattended or agent-driven `make testflight`.
- **`source .env` (or `make`'s `include .env`) and let it export everything.** Simpler, but it executes whatever is in the file and exports every variable in it to every child, including the build; a stray line becomes code. Rejected for the strict single-line parse.
- **Keep the token in the macOS Keychain and read it with `security find-generic-password`.** Better at rest, but it adds a second secret store to set up and explain, and the owner chose a `.env`. Possible later without changing `op-run.sh`'s callers.
- **A service account with write access, or access to more vaults.** Not needed: the lane only reads.
- **Check auth with `op whoami`.** It would not catch a service account that lacks access to the `OpenMoji` vault, which is the failure the lane would otherwise hit later at `op run`.

## Consequences
- A plaintext token sits on the release Mac's disk (1Password's own CLI help advises against plaintext storage). The damage if it leaks is bounded by the account's scope: read-only on the `OpenMoji` vault, which holds the signing-keychain password and the ASC API key. Mitigations: mode 600, git-ignored, scoped to one vault, optionally created with `--expires-in`, revocable and replaceable in 1Password at any time (runbook 2.6), and never readable by the lane's children.
- A service account's vault access cannot be edited after creation: changing it means creating a new account and replacing the token in `.env`.
- Two auth modes to document and test. Interactive remains the default and the fallback for a Mac without a `.env`.
- Anyone, or any tool, that can read `.env` has the token. Agent sessions must not read it; the committed `.env.example` is the only version to show.
- Does not change the lane's constraints from ADR-0010: no secrets in GitHub, no signing or upload from CI, no third-party packages.
