# Project Reflections

Notes kept up to date at the end of each session. Rules live in CLAUDE.md, the backlog lives in Beads (`bd ready`), and this file holds understanding.

## Current understanding (as of 2026-10-02)

- **Where we are:** M2 (the tech spec) is done. `docs/tech-spec.md`, ADRs 0001–0015 and `docs/open-questions.md` are merged. No code exists yet. Next are M1, the generation spike, and M3, the pipeline-first scaffold. M3 is blocked on choosing the App Store Connect record name.
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
- **The git-policy ambiguity is settled.** The beads block in CLAUDE.md defaults to "conservative", which conflicted with the user's global "landing is the ask" rule. The repo now opts into Team-maintainer explicitly.

## Open questions

The canonical list is `docs/open-questions.md`. The ones most likely to bite next:
- Is the OpenAI org verified (OQ-7)? M1 fails without it.
- Do `MSStickerView` peel-and-drag and a long-press context menu coexist (OQ-10)? This decides the delete UX.
- Does `MSSticker` load from App Group URLs (OQ-11)?
