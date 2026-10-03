# OpenMoji

An iPad-only iMessage app extension that turns a text prompt into an emoji-style sticker. Type "grumpy cat", get a transparent-background sticker, keep it in a library, and send it from Messages.

- **Generation:** the OpenAI Images API (`/v1/images/generations`, model alias `gpt-image-2.5-flare`, quality `medium`), called from our own `URLSession` client.
- **Audience:** family use. Distributed through TestFlight to internal testers only; it is never submitted to the App Store.
- **No backend.** The app talks straight to OpenAI.
- **No third-party dependencies** (NFR-7): no SDKs, no Swift packages beyond our own local `OpenMojiCore`.
- **The OpenAI API key lives only in the Keychain**, in an access group shared by the app and the extension. It is never logged, put in an error, or committed.

## Status

- **M1 (generation spike):** done. The sticker prompt template passes at `low`, `medium` and `high`; `medium` is the default ([findings](docs/spikes/m1-findings.md)).
- **M2 (spec):** done: PRD, [tech spec](docs/tech-spec.md), [ADRs](docs/adr/README.md).
- **M3 (app scaffold and release lane):** the shell app, the Messages extension, `OpenMojiCore`, CI and the local release lane are built. The one-time Apple setup and the first real TestFlight upload are still to do.
- **M4 (features):** `OpenMojiCore` (OpenAI client, error mapping, sticker processing, library store, Keychain store) and the Settings and Compose screens are in. The generating, preview, library and error screens are not.
- **M5 (family beta):** not started (real icons, testers, [device checklist](docs/device-checklist.md) run).

`bd ready` shows what is open right now.

## Repo layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen project definition. The generated `OpenMoji.xcodeproj` is git-ignored |
| `App/` | `OpenMoji`, the shell app: one screen that says where to find OpenMoji in Messages |
| `MessagesExtension/` | `OpenMojiMessages`, the iMessage extension: `MessagesViewController`, SwiftUI views, UI-free `Model/` |
| `MessagesExtensionTests/` | `OpenMojiMessagesTests`, the simulator test bundle (Keychain round trip, view-model tests) |
| `Packages/OpenMojiCore/` | Local Swift package with all logic and its tests (`swift test`) |
| `scripts/` | Release lane: `release.sh`, `op-run.sh`, `asc.swift`, their self-tests, `testflight-expiry.sh` |
| `release/` | `ExportOptions.plist` and `.env.example` (1Password `op://` references, no values) |
| `Makefile` | Release lane entry points (`testflight`, `testflight-status`, `op-check`, `release-test`) |
| `.github/workflows/` | `ci.yml` (verify) and `testflight-expiry.yml` (expiry alert) |
| `docs/` | PRD pointer, tech spec, ADRs, runbook, checklists (see [Docs](#docs)) |
| `spikes/m1/` | The M1 generation spike tooling |

## Prerequisites

- **Xcode 26 or later** (any Xcode that ships Swift 6.2 or newer; `Package.swift` is `swift-tools-version: 6.2`, the lowest that knows `.iOS(.v26)`), selected with `xcode-select`. The deployment target is iPadOS 26.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**, **SwiftLint**, **gitleaks** and **shellcheck**: `brew install xcodegen swiftlint gitleaks shellcheck`.
- **[SwiftFormat](https://github.com/nicklockwood/SwiftFormat) 0.63.0**, exactly. CI pins it because rule sets differ between releases. Check with `swiftformat --version`; CI installs it from the [0.63.0 release zip](https://github.com/nicklockwood/SwiftFormat/releases/tag/0.63.0).
- **For releases only, on the release Mac:** `gh` and the 1Password CLI (`op`): `brew install gh && brew install --cask 1password-cli`. The rest of the one-time setup is in the [runbook](docs/runbooks/testflight-release.md#2-one-time-setup-release-mac).

## Build, test and lint

```bash
# Generate the Xcode project (after editing project.yml or adding or removing files)
xcodegen generate

# OpenMojiCore unit tests, on the Mac host
swift test --package-path Packages/OpenMojiCore

# Extension and app tests on an iPad simulator. Pick a UDID from the list.
xcrun simctl list devices available | grep iPad
xcodebuild test -project OpenMoji.xcodeproj -scheme OpenMojiMessagesTests \
  -destination "id=<UDID>" CODE_SIGN_IDENTITY=-

# Lint and scan (what CI runs on pull requests)
swiftformat --lint .
swiftlint lint --strict
shellcheck scripts/*.sh
gitleaks detect --redact --no-banner

# Release-lane self-test: every external tool stubbed, no secrets, no network
make release-test
```

`CODE_SIGN_IDENTITY=-` signs the simulator build ad hoc so the host app carries its Keychain entitlement. An unsigned build (`CODE_SIGNING_ALLOWED=NO`) fails the Keychain test with `errSecMissingEntitlement` (-34018).

You can also open the generated `OpenMoji.xcodeproj` in Xcode and run the `OpenMoji` scheme on an iPad simulator or device. The image model and quality are build settings in `project.yml` (`OPENMOJI_IMAGE_MODEL`, `OPENMOJI_IMAGE_QUALITY`, [ADR-0013](docs/adr/0013-generation-config-build-settings.md)).

## CI

`.github/workflows/ci.yml` runs on every pull request and every push to `main`, on `macos-latest`, and only verifies: gitleaks over the full history, SwiftFormat and SwiftLint (pull requests), `shellcheck`, `make release-test`, `swift test`, then `xcodegen generate` and the simulator tests. Changes that touch only docs (`docs/`, `*.md`, `.gitignore`, `.claude/`) run just gitleaks. CI never signs or uploads, and the repo has **no GitHub Actions secrets**: the workflows use only the built-in `GITHUB_TOKEN`.

`.github/workflows/testflight-expiry.yml` runs daily and opens a GitHub issue when the newest TestFlight build (TestFlight builds last 90 days) is about two weeks from expiring. It works from the date of the `build-N` tag the release lane pushes, so it needs no App Store Connect access.

## Release

Releases publish **only from the local release Mac**. From a clean `main` that equals `origin/main` with green CI:

```bash
make testflight           # preflight, tests, archive, upload, wait for VALID, What to Test, Family group, build-N tag
make testflight-status    # newest build's processing state and exact expiry date (read-only)
make op-check             # only check that 1Password auth works and the OpenMoji vault is readable
```

Secrets come from 1Password through `op run`, never from GitHub. `scripts/op-run.sh` authenticates `op` with a service-account token in a git-ignored `.env` when there is one (unattended), and through the 1Password app otherwise. To use the service account: `cp .env.example .env && chmod 600 .env`, then paste the token (setup: runbook [section 2.6](docs/runbooks/testflight-release.md#26-non-interactive-1password-auth-a-service-account-optional)). Never commit `.env` or paste the token anywhere.

The runbook has the one-time Apple setup, the routine release steps, failure recovery and the certificate and profile expiry register: [docs/runbooks/testflight-release.md](docs/runbooks/testflight-release.md).

## Docs

| Doc | What |
|---|---|
| [PRD](https://claude.ai/code/artifact/4eb3c358-d044-4b4f-a48b-2aca31cd3bbe) | Scope source of truth: locked decisions D1 to D10, FR, NFR and REL IDs. A Claude Doc, not a repo file |
| [Tech spec](docs/tech-spec.md) | Architecture, data model, OpenAI contract, error mapping, processing, test strategy, release pipeline |
| [ADRs](docs/adr/README.md) | One file per significant technical decision, with an index |
| [Open questions](docs/open-questions.md) | Open and resolved questions, mirrored as `open-question` beads |
| [Release runbook](docs/runbooks/testflight-release.md) | One-time Apple and Mac setup, routine release, recovery, pitfalls |
| [Device checklist](docs/device-checklist.md) | Manual acceptance run on the iPad Air against a TestFlight build |
| [M1 findings](docs/spikes/m1-findings.md) | Results of the generation spike (quality, cost, latency) |

## Issue tracking

Work is tracked with **[bd](https://github.com/gastownhall/beads) (beads)**, not markdown TODO lists. Issues live in a local Dolt database and sync through `refs/dolt/data` on the git remote, so they are not files in the working tree.

```bash
bd ready              # find available work
bd show <id>          # view an issue
bd update <id> --claim
bd close <id>
bd prime              # full workflow context
```

AI agents working in this repo should read [CLAUDE.md](CLAUDE.md) first.
