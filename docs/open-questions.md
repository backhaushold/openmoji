# OpenMoji — Open questions

- **As of:** 2026-10-02
- **Context:** the [tech spec](tech-spec.md) and the [PRD](https://claude.ai/code/artifact/4eb3c358-d044-4b4f-a48b-2aca31cd3bbe)

Resolved items stay listed so the history is visible. "Blocks" names the earliest milestone that needs the answer.

## Carried over from the PRD

| ID | Question | Status | Blocks | Notes |
|---|---|---|---|---|
| OQ-1 | Messages context or media context? | **Resolved** 2026-10-02: Messages context (app drawer); media context deferred | — | Tech spec §3 |
| OQ-2 | Universal or iPad-only? | **Resolved** 2026-10-02: iPad-only | — | [ADR-0014](adr/0014-ipad-only-device-family.md) |
| OQ-3 | Sagelet pipeline specifics (tooling, runner, signing) | **Resolved** 2026-10-02: local `make testflight`, 1Password, manual signing, reimplemented for OpenMoji | — | Tech spec §12, [ADR-0010](adr/0010-local-release-lane.md) |
| OQ-4 | Default quality level: `low`, `medium` or `high`? | Open | M1 → M4 | Default `medium` until M1 measures cost, latency and look (tech spec §9). 2.5 adds `xhigh` and `max` levels |
| OQ-5 | App Store Connect record name ("OpenMoji" is taken) | Open | M3 (record is needed for the first upload) | "GenmojiAI" uses Apple's feature name ("Genmoji"), so trademark risk even for a TestFlight-only app. The record name is never shown to testers in the store, only in TestFlight. Candidates should avoid "Genmoji" and "Memoji", e.g. "OpenMoji Family", "OpenMoji Stickers" (availability unchecked) |

## New from the tech spec

| ID | Question | Blocks | Default / proposal |
|---|---|---|---|
| OQ-6 | Is `GET /v1/models/{id}` free of charge, and does it return 404 (not 403) for a model the org can't use yet? | M4 (FR-4) | Assume free; check the OpenAI usage dashboard after the first validation call and adjust the §5.4 table |
| OQ-7 | Is the OpenAI organization verified for GPT Image 2.5? | M1 | Verify before the spike; the spike fails without it |
| OQ-8 | Pin the dated snapshot `gpt-image-2.5-flare-2026-09-08` or use the moving alias `gpt-image-2.5-flare`? | M4 | Alias: picks up fixes automatically, and FR-9 lets us pin later with one build |
| OQ-9 | Real cost and latency per attempt (replaces NFR-8's unverified "< $0.05") | M1 | Measure from `usage` and wall-clock over the 20-prompt set at low, medium and high |
| OQ-10 | Do tap-to-insert and peel-and-drag from `MSStickerView` work in both compact and expanded on iPadOS 26, and does a long-press context menu conflict with peel? | M3 | Verify in the shell build; fallbacks in [ADR-0008](adr/0008-swiftui-with-msstickerview.md) |
| OQ-11 | Does `MSSticker` accept file URLs inside the App Group container? | M3 | Expected yes; fallback is copying to a temp file (tech spec A5) |
| OQ-12 | Lowest App Store Connect API key role that can read builds, for the GitHub-held expiry key | M3 | Try "Developer"; fall back to "App Manager" and accept the wider scope, or drop the GitHub secret and run the check locally |
| OQ-13 | Can the internal group "Family" use automatic distribution, so REL-5 needs no API write? | M3 | Expected yes; `asc.swift ensure-in-group` covers it otherwise |
| OQ-14 | Alert on the yearly expiry of the distribution certificate and profiles too? | M5 | Proposal: extend the expiry workflow to read profile expiry via the ASC API |
| OQ-15 | Correct the PRD: GPT Image 2 isn't deprecated; NFR-8's cost is unverified; Apple's 300–618 px is guidance | M2 | Edit the PRD text; no locked decision changes |
