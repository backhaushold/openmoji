# ADR-0010: Local `make testflight` release lane, reimplemented from the Sagelet pattern

- **Status:** Accepted (user, 2026-10-02: option 1, "reimplement independently; use Sagelet only as a reference")
- **Date:** 2026-10-02

## Context
REL-2 requires reusing Sagelet's pipeline structure, credentials model and runner. Reading `backhaushold/sagelet` @ `4ec916b` showed:
- Sagelet uploads from the **owner's Mac** (`make testflight` → `op run` → `xcodebuild archive` / `-exportArchive destination=upload`), with manual signing from a dedicated keychain.
- GitHub Actions only runs lint and unsigned simulator tests.
- Sagelet has no tests in the lane, no secret scan, no tester-group assignment, no release notes and no expiry handling. REL-5 to REL-9 are therefore new work.

## Decision
- Build OpenMoji's own lane in this repo (`Makefile`, `scripts/op-run.sh`, `scripts/release.sh`, `scripts/asc.swift`, `release/ExportOptions.plist`, `release/.env.example`), following Sagelet's shape: local Mac runner, 1Password for secrets, ASC API key for upload, `git rev-list --count` build numbers.
- No files are copied from or shared with Sagelet.
- Extend it with:
  - A preflight: main == origin, CI green on HEAD.
  - gitleaks (REL-6) and `swift test` (REL-7).
  - "What to Test" from `git log` (REL-8).
  - Internal-group distribution (REL-5).
  - A scheduled GitHub Actions expiry **alert** (REL-9).

## REL-4 interpretation (flagged)
REL-4 says "API key held as a CI secret, not a personal Apple ID session". The lane authenticates with an ASC API key held in 1Password, never an Apple ID session, which meets the intent. The read-only expiry key is also held as a GitHub Actions secret.

## Alternatives
- **Full CI signing on a GitHub macOS runner** (temporary keychain, cert and profiles as secrets). This allows unattended scheduled rebuilds (REL-9's rebuild option), but departs from REL-2's runner and puts the distribution certificate in GitHub.
- **fastlane (match + pilot).** A mature tool, but it adds a Ruby toolchain and a certificate repo, and isn't Sagelet's pattern.

## Consequences
- Releases need the owner's Mac, 1Password and the signing keychain; nothing ships while that Mac is unavailable.
- REL-9 is satisfied by an alert, not an automatic rebuild.
- The Sagelet pitfalls (Homebrew rsync, login-keychain `errSecInternalComponent`, `xcode-select`) are designed in from the start.
