# ADR-0015: App Store Connect API calls via a dependency-free Swift script

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
REL-5 (distribute to the internal group), REL-8 ("What to Test" notes) and the local `make testflight-status` exact-expiry check need App Store Connect API calls: `GET /v1/builds`, `POST/PATCH /v1/betaBuildLocalizations`, `POST /v1/builds/{id}/relationships/betaGroups`. These require an ES256-signed JWT from the `.p8` key. `xcodebuild -exportArchive` covers only the upload.

## Decision
`scripts/asc.swift`, a single-file Swift script run with `swift scripts/asc.swift <command>`:
- Signs the JWT with CryptoKit `P256.Signing`.
- Calls the API with `URLSession`.
- Exposes `wait-for-build`, `set-whats-new`, `ensure-in-group` and `latest-build`.
- Runs only on the release Mac, with the key from 1Password; never in CI (no secrets in GitHub). No dependencies.
- Primary REL-5 mechanism: the "Family" internal group's **automatic distribution** setting. `ensure-in-group` is a verifying fallback.

## Alternatives
- **fastlane `pilot`.** Covers all of this, but adds a Ruby toolchain.
- **Python + PyJWT, or a shell script with `openssl` and `curl`.** Either works, but adds a second language or fragile DER-to-raw signature conversion.
- **Third-party `asc` CLIs.** An external binary with our ASC key.

## Consequences
- About 200 lines of Swift we own, with `swift test`-style unit tests for JWT claims and request building in a small `Tools` package if it grows.
- The scheduled expiry alert in CI doesn't use this script. It works from tag dates, so CI needs no App Store Connect access.

## Built (bead `openmoji-2pq`)
The script came out at about 600 lines (models, error text and the four commands), still one file with CryptoKit and Foundation only. The tests went into the lane's shell self-test, not a `Tools` package:
- **A loopback-only test hook.** `ASC_TEST_BASE_URL` points the client at a stub server. Only `http://127.0.0.1` or `http://localhost` is accepted; anything else is an error, so a token can never be sent to a host other than Apple's by mistake. `ASC_TEST_RETRY_DELAY` shortens the GET retry pause and is honoured only together with that URL. `release.sh` unsets both, so the lane never uses them.
- **A stub App Store Connect server** (`scripts/test-support/asc-stub.swift`, Swift and POSIX sockets, so no second language) answers from a scripted scenario, verifies every request's ES256 JWT against a throwaway public key and logs what it saw. `scripts/test-asc.sh` (run by `make release-test`, so in CI) drives `asc.swift` against it. CI makes no call to App Store Connect and needs no key.
- **Request details checked against Apple's documentation** (2026-10-03): the JWT header and claims and the 20-minute token limit ("Generating Tokens for API Requests"); `GET /v1/builds` (`filter[app]`, `filter[version]`, `filter[id]`, `filter[betaGroups]`, `sort=-uploadedDate`, `limit` up to 200) and the build attributes `processingState` (`PROCESSING`, `FAILED`, `INVALID`, `VALID`), `expirationDate`, `uploadedDate`, `version`; `GET /v1/apps` (`filter[bundleId]`); `GET /v1/betaGroups` and `GET /v1/apps/{id}/betaGroups` (`filter[app]`, `filter[name]`, attributes `name`, `isInternalGroup`, `hasAccessToAllBuilds`); `POST /v1/betaBuildLocalizations` and `PATCH /v1/betaBuildLocalizations/{id}` (`whatsNew`, `locale`, the `build` relationship); `POST /v1/builds/{id}/relationships/betaGroups` (204). What the documentation does not settle is listed in the PR: the `whatsNew` length limit (4000 is a conservative cap) and behaviour only a real upload shows (OQ-13).
