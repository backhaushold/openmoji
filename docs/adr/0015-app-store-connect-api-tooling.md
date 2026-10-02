# ADR-0015: App Store Connect API calls via a dependency-free Swift script

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
REL-5 (distribute to the internal group), REL-8 ("What to Test" notes) and REL-9 (expiry check) need App Store Connect API calls: `GET /v1/builds`, `POST/PATCH /v1/betaBuildLocalizations`, `POST /v1/builds/{id}/relationships/betaGroups`. These require an ES256-signed JWT from the `.p8` key. `xcodebuild -exportArchive` covers only the upload.

## Decision
`scripts/asc.swift`, a single-file Swift script run with `swift scripts/asc.swift <command>`:
- Signs the JWT with CryptoKit `P256.Signing`.
- Calls the API with `URLSession`.
- Exposes `wait-for-build`, `set-whats-new`, `ensure-in-group` and `latest-build`.
- Runs on the Mac and on `macos-latest` runners; no dependencies.
- Primary REL-5 mechanism: the "Family" internal group's **automatic distribution** setting. `ensure-in-group` is a verifying fallback.

## Alternatives
- **fastlane `pilot`.** Covers all of this, but adds a Ruby toolchain.
- **Python + PyJWT, or a shell script with `openssl` and `curl`.** Either works, but adds a second language or fragile DER-to-raw signature conversion.
- **Third-party `asc` CLIs.** An external binary with our ASC key.

## Consequences
- About 200 lines of Swift we own, with `swift test`-style unit tests for JWT claims and request building in a small `Tools` package if it grows.
- macOS runner needed for the expiry workflow; free because the repo is public.
