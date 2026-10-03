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
  - A secret-free scheduled GitHub Actions expiry **alert** that reads the upload date from the annotated `build-N` tag the lane pushes (REL-9), plus `make testflight-status` for the exact date.

## Constraints (user, 2026-10-02)
- **No publishing from CI; local only.** GitHub Actions verifies and alerts but never signs or uploads.
- **No secrets in GitHub.** The ASC API key lives only in 1Password and is used only by the local lane. Workflows use only the built-in `GITHUB_TOKEN`.

The PRD's REL-4 and REL-9 were updated to match: REL-4 holds the key in 1Password for the local command, and REL-9 is an alert followed by a local release.

## Alternatives
- **Full CI signing on a GitHub macOS runner** (temporary keychain, cert and profiles as secrets). This allows unattended scheduled rebuilds (REL-9's rebuild option), but departs from REL-2's runner and puts the distribution certificate in GitHub.
- **fastlane (match + pilot).** A mature tool, but it adds a Ruby toolchain and a certificate repo, and isn't Sagelet's pattern.

## Consequences
- Releases need the owner's Mac, 1Password and the signing keychain; nothing ships while that Mac is unavailable.
- REL-9 is satisfied by an alert, not an automatic rebuild. The alert infers expiry from tag dates rather than querying App Store Connect, since that would need a key in GitHub.
- The Sagelet pitfalls (Homebrew rsync, login-keychain `errSecInternalComponent`, `xcode-select`) are designed in from the start.
- Authenticating `op` without the 1Password app (a service-account token in a git-ignored `.env`) is covered by [ADR-0016](0016-onepassword-service-account-auth.md).
