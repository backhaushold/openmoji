# OpenMoji — Open questions

- **As of:** 2026-10-04
- **Context:** the [tech spec](tech-spec.md) and the [PRD](https://claude.ai/code/artifact/4eb3c358-d044-4b4f-a48b-2aca31cd3bbe)

Resolved items stay listed so the history is visible. "Blocks" names the earliest milestone that needs the answer.

## Carried over from the PRD

| ID | Question | Status | Blocks | Notes |
|---|---|---|---|---|
| OQ-1 | Messages context or media context? | **Resolved** 2026-10-02: Messages context (app drawer); media context deferred | — | Tech spec §3 |
| OQ-2 | Universal or iPad-only? | **Resolved** 2026-10-02: iPad-only | — | [ADR-0014](adr/0014-ipad-only-device-family.md) |
| OQ-3 | Sagelet pipeline specifics (tooling, runner, signing) | **Resolved** 2026-10-02: local `make testflight`, 1Password, manual signing, reimplemented for OpenMoji | — | Tech spec §12, [ADR-0010](adr/0010-local-release-lane.md) |
| OQ-4 | Default quality level: `low`, `medium` or `high`? | **Resolved** 2026-10-02: `medium` | — | M1 spike ([findings](spikes/m1-findings.md)): all three levels pass 20/20; medium costs ~$0.014 and ~10 s per sticker, `low` is a cheaper fallback, `high` is 4× the cost and 2× the latency |
| OQ-5 | App Store Connect record name ("OpenMoji" is taken) | **Resolved** 2026-10-02: "OpenMoji Family" | — | "GenmojiAI" uses Apple's feature name ("Genmoji"), so trademark risk even for a TestFlight-only app. The record name is never shown to testers in the store, only in TestFlight. Candidates should avoid "Genmoji" and "Memoji", e.g. "OpenMoji Family", "OpenMoji Stickers" (availability unchecked) |

## New from the tech spec

| ID | Question | Blocks | Default / proposal |
|---|---|---|---|
| OQ-6 | Is `GET /v1/models/{id}` free of charge, and does it return 404 (not 403) for a model the org can't use yet? | — | **Resolved** 2026-10-03: treat the call as free (OpenAI's pricing bills only tokens, image outputs and tool calls; the endpoint has no listed price). OpenAI doesn't document the status for a model the key can't use, so 404 stays "save with warning", and 403 with `code == "model_not_found"` (reported for project-scoped keys) is handled the same way; any other 403 still refuses (tech spec §5.4, [ADR-0009](adr/0009-key-validation.md)). Optional check: the usage dashboard after the first key save |
| OQ-7 | Is the OpenAI organization verified for GPT Image 2.5? | — | **Resolved** 2026-10-02: yes, the organization is verified (confirmed by the family admin) |
| OQ-8 | Pin the dated snapshot `gpt-image-2.5-flare-2026-09-08` or use the moving alias `gpt-image-2.5-flare`? | — | **Resolved** 2026-10-02: use the alias `gpt-image-2.5-flare`. It picks up fixes automatically, and FR-9 lets us pin a snapshot later with one build |
| OQ-9 | Real cost and latency per attempt (replaces NFR-8's unverified "< $0.05") | — | **Resolved** 2026-10-02: at `medium`, $0.0137 mean / $0.0139 max per attempt, latency p50 10.2 s / p90 11.9 s (M1, [findings](spikes/m1-findings.md)); replaces NFR-8's estimate |
| OQ-10 | Do tap-to-insert and peel-and-drag from `MSStickerView` work in both compact and expanded on iPadOS 26, and does a long-press context menu conflict with peel? | — | **Resolved** 2026-10-04 (M3 device probe, iPad Air, iPadOS 26): in expanded, tap-to-insert and peel-and-drag both work, and a SwiftUI `.contextMenu` coexists with peel (hold still = menu, immediate drag = peel); `activeConversation.insert` also works, so neither [ADR-0008](adr/0008-swiftui-with-msstickerview.md) fallback is needed. Compact couldn't be tested because it can't be reached: `requestPresentationStyle(.compact)` is ignored, and dragging down or tapping Messages' text box dismisses the app, in portrait and landscape ([ADR-0017](adr/0017-expanded-first-layout.md)) |
| OQ-11 | Does `MSSticker` accept file URLs inside the App Group container? | — | **Resolved** 2026-10-04 (M3 device probe, iPad Air, iPadOS 26): yes. An `MSSticker` created from an App Group file URL loads and renders in `MSStickerView`, same as a bundle URL; no temp-file copy is needed (tech spec A5) |
| OQ-12 | ~~Lowest App Store Connect API key role for a GitHub-held expiry key~~ | — | **Moot** 2026-10-02: no secrets in GitHub; the CI expiry alert works from tag dates (tech spec §12.6) |
| OQ-13 | Can the internal group "Family" use automatic distribution, so REL-5 needs no API write? | — | **Resolved** 2026-10-03: yes. The first upload (build 51, via `make testflight`) logged "already in group Family": automatic distribution added the CLI-uploaded build. `ensure-in-group` stays as the check |
| OQ-14 | Alert on the yearly expiry of the distribution certificate and profiles too? | M5 | Proposal: `make testflight-status` also reports profile and certificate expiry (local, via the ASC API); CI can't see them without secrets |
| OQ-15 | Correct the PRD: GPT Image 2 isn't deprecated; NFR-8's cost is unverified; Apple's 300–618 px is guidance | — | **Resolved** 2026-10-02: PRD updated, also OQ-2 and OQ-3 resolved, REL-4 and REL-9 made local-only |
