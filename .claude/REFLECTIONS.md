# Project Reflections

Notes kept up to date at the end of each session. Rules live in CLAUDE.md, the backlog lives in Beads (`bd ready`), and this file holds understanding.

## Current understanding (as of 2026-10-02)

- **Where we are:** M2 (the tech spec) is done and the backlog is decomposed. No code exists yet. The App Store Connect record name is "OpenMoji Family" (OQ-5, resolved). Start with `bd ready --exclude-type=epic`. The first code task is the OpenMojiCore package skeleton (`e4h`). M1 waits on OQ-7 (org verification), which only the user can check.
- **How the backlog is shaped, and why.** There are 7 capability epics, cut as vertical slices (the user chose this). Each one owns its Core logic and its UI, so it can be verified on the device by itself. Milestones M1–M5 are labels (`m1`–`m5`), not epics, because one capability spans several milestones. Each open question is a `decision` bead that blocks only the tasks it governs. That keeps `bd ready` honest, so don't wire a decision to a whole epic. Tasks only the user can do (Apple portal, ASC record, inviting testers) carry the label `human`. Don't hand those to subagents.
- **The M3 probe (`25h`) is load-bearing.** It answers OQ-10 (`MSStickerView` gestures vs. a context menu) and OQ-11 (App Group URLs) on a real iPad. Those answers gate the library grid, delete and preview. If the probe is skipped, the M4 UI is built on guesses.
- **The PRD is a Claude Doc, not a repo file.** Read it with the Claude Docs connector (`read` the project, then the prose node). The only `projection` value is `"outline"`; leave it out to get the full text. Edit with targeted `find`/`replace` operations. The PRD was corrected this session (model facts, NFR-1, NFR-8, REL-4, REL-9, OQ-2, OQ-3).
- **Sagelet is a reference, not a template.** Its TestFlight lane runs on the user's Mac: `make testflight` → `op run` → `xcodebuild archive` / `-exportArchive destination=upload`, with manual signing from a dedicated keychain. Its CI only runs simulator tests. The user wants OpenMoji's lane *reimplemented independently* with no copied files. Sagelet has no tests in the lane, no secret scan and no expiry handling; OpenMoji adds all three.
- **The release design follows from the user's rule: publish locally, keep no secrets in GitHub.** That rule shaped the REL-9 expiry alert. CI can't call App Store Connect without a key, so the lane pushes an annotated `build-N` tag after the build becomes VALID, and a scheduled workflow computes expiry as the tag date plus 90 days. That trade-off is in ADR-0010. Don't "improve" it by adding an ASC key to GitHub.

## Lessons & gotchas

- **PRD and model facts go stale fast; check them against official docs.** The PRD said GPT Image 2 was deprecated (false) and quoted a per-image price OpenAI doesn't publish for 2.5. Verified on 2026-10-02:
  - The model IDs are `gpt-image-2.5-flare` / `-sunburst`, with snapshots dated `-2026-09-08`.
  - Moderation refusals are `image_generation_user_error` / `moderation_blocked`.
  - Billing 429s have their own codes (`project_spend_limit_exceeded` etc.), separate from rate-limit 429s.
  - `GET /v1/models` needs the "List models: Read" permission, which is why the key gets that scope (ADR-0009).
- **OpenAI's smallest image is about 810², so 618 px can't be requested.** Downscaling on the device is unavoidable (ADR-0004).
- **Passing one provisioning profile on the command line signs every target with it.** Sagelet passes a single `PROVISIONING_PROFILE_SPECIFIER`; doing that here would break the extension. Profiles go per target in `project.yml` (ADR-0011).
- **`bd init` commits straight to local `main`.** It's a one-off, but watch for it if the repo is ever re-initialized.
- **Until `ci.yml` lands (`q4o`), PRs have no checks.** "Watch to green" has nothing to watch. Re-read the diff yourself, then merge. Once CI exists, the release-lane preflight needs a check run on every `main` commit, so don't add `paths-ignore`.
- **Local hooks guard token use.** A Bash `cat` of a file over 350 lines is blocked; use `Read` with `limit`/`offset` or the bulk-reader. A new file over 100 lines is bounced to the code-writer once; re-sending the same Write goes through when the content is novel reasoning, such as a bd graph plan.
- **`bd lint` has a template per type.** Decisions need `## Decision`, `## Rationale` and `## Alternatives Considered`; `spike` issues need `## Goal` and `## Findings`. Build the backlog with one `bd create --graph` plan, written by a small Python generator in the scratchpad, and run it with `--dry-run` first.
- **The git-policy ambiguity is settled.** The beads block in CLAUDE.md defaults to "conservative", which conflicted with the user's global "landing is the ask" rule. The repo now opts into Team-maintainer explicitly.

## Open questions

The canonical list is `docs/open-questions.md`, mirrored as `open-question` decision beads. The ones most likely to bite next:
- Is the OpenAI org verified (OQ-7, `q2h`)? M1 fails without it.
- Do `MSStickerView` peel-and-drag and a long-press context menu coexist (OQ-10)? This decides the delete UX.
- Does `MSSticker` load from App Group URLs (OQ-11)?
- 11 ADRs are still marked "Proposed", awaiting review with the spec PR, even though that PR merged. Nobody has decided whether merging the spec counts as accepting them. Ask the user before flipping their status.
