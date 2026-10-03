# Project Reflections

Notes kept up to date at the end of each session. Rules live in CLAUDE.md, the backlog lives in Beads (`bd ready`), and this file holds understanding.

## Current understanding (as of 2026-10-03)

- **Where we are:** M3/M4 code is largely built and merged (PRs #7–#47): OpenMojiCore (errors, processing, library store, OpenAI client + key check, CredentialStore, StyleTemplate, GenerationService), the extension's AppModel, Settings, Compose, Generating and Error screens, CI, and the full local release lane (`make testflight` through the `build-N` tag, `make testflight-status`, expiry alert, 1Password service-account auth). Everything agent-doable is done. What's left is gated on the user: Apple setup (`t2m`) → first upload (`i5k`), the iPad probes (`25h`, which answer OQ-10/OQ-11 and unblock Preview/Keep, the library grid and delete), and a handful of small decisions.
- **How the backlog is shaped, and why.** 7 capability epics cut as vertical slices; milestones are labels `m1`–`m5`; each open question is a `decision` bead that blocks only the tasks it governs (don't wire a decision to a whole epic). `human`-labelled tasks are the user's.
- **M1 is settled and cheap.** All three qualities passed 20/20; medium ≈ $0.014 and ~10 s per sticker, so OQ-4 = medium and NFR-8's old "< $0.05" is replaced. The §9 template needed no change. Slots 15–17 used stand-in prompts (`6dr.2` re-runs the real ones).
- **The PRD is a Claude Doc, not a repo file.** Read with the Docs connector; edit with targeted `find`/`replace`. Resolving an open question means four places: the bead (`Ratified: …`), `docs/open-questions.md`, any tech-spec text that says "open", and the PRD line if one exists (OQ-6+ mostly have none).
- **The release design follows from "publish locally, no GitHub secrets".** CI can't see App Store Connect, so the lane pushes an annotated `build-N` tag only after VALID and a scheduled workflow computes expiry from the tag date (ADR-0010). Don't "improve" this with an ASC key in GitHub.
- **Toolchain floor is deliberate.** `swift-tools-version: 6.2` is the lowest that knows `.iOS(.v26)` and lets CI use stock `macos-latest` (Xcode 26). A worker first picked 6.4 (the local toolchain), which forced a preview runner — the user chose 6.2 + `macos-latest` instead. Sagelet's CI was the reference (pinned SwiftFormat, PR-only lint, simulator by UDID); its Linux job doesn't transfer because Core uses Apple-only frameworks.

## Lessons & gotchas

- **The agent sandbox won't let a worktree agent source `.env`.** Paid or secret-needing runs (the M1 spike) are handed to the user as a `! …` command; don't route around the refusal, and don't run it "for" the agent either. The worker should still build and test the script with no spend (loopback stub, request cap, ledger) so the user's single run is safe.
- **Copy artifacts out of an agent worktree before removing it.** The M1 raw PNGs were lost with the worktree (only the contact sheets survived), which forced the alpha-snap measurement onto synthetic data.
- **Process-wide test stubs leak across tests on slow runners.** The URLProtocol flake passed 100/100 locally and still failed on GitHub; a "drain" wait didn't fix it, per-test stub state keyed by a request header did. Prove flake fixes with several CI re-runs, not local loops.
- **Simulator Keychain tests need ad-hoc signing** (`CODE_SIGN_IDENTITY=-`); unsigned hosts get -34018. The shared access group's prefix is resolved at runtime via a non-secret probe item, since iOS has no public entitlement API.
- **Parallel workers collide on a few shared files** (`project.yml`, `RootView.swift`, `release.sh`/Makefile, `.gitignore`). Sequencing with `bd dep add` worked well; `gh pr update-branch` reports conflicts — check its output, and re-key CI waiters on the new head SHA.
- **CI flakes seen so far:** a corrupted restored DerivedData cache (cache since removed) and a GitHub 502 downloading the pinned SwiftFormat (re-run once).
- **A SwiftUI `TextField` bound straight to the model doesn't reflect model-side truncation**; use a local `@State` draft synced both ways (ComposeView). Preview's editable prompt (`ijf`) needs the same.
- **gitleaks scans all refs**, so a stale remote-tracking ref to a deliberately leaky probe branch trips the release lane; `git fetch --prune` fixed it. Build fake keys at runtime in tests.
- **The chore tier (Haiku `beads-chore`) went 4/4** on fully specified small tasks with no escalations or hidden defects; judgment-heavy work still goes to `beads-worker`.
- **OpenAI facts (verified 2026-10-02):** model alias `gpt-image-2.5-flare`; smallest image ~810², so on-device downscaling is unavoidable; billing 429s have their own codes; `usage` is always returned; the org is verified.

## Open questions

- 13 ADRs are still "Proposed" (incl. the new ADR-0016). Nobody has decided whether merging counts as acceptance — ask the user before flipping statuses.
- OQ-10/OQ-11 (sticker gestures, App Group URLs) need the iPad probe (`25h`).
- OQ-6 (is the key check free / 404 for an unusable model), OQ-13 (does Family auto-distribution pick up CLI uploads — `ensure-in-group`'s log answers it on the first upload), OQ-14 (cert/profile expiry alerts), and `pxc.1` (guarding the expiry cron against GitHub's 60-day inactivity disable).
- Settings/Error UX choices the user hasn't reacted to yet: spec-silent copy, Clear-with-confirmation, no `keyNotPermitted` Settings button.
