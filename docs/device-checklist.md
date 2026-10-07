# OpenMoji — Device acceptance checklist

Manual run on the real iPad Air against a TestFlight build ([tech spec §11](tech-spec.md#11-test-strategy), "Device checklist (manual)"). Print or copy this file per run, fill in the header, tick items as they pass and write what you saw under **Notes** for anything that doesn't.

Sources: the nine PRD acceptance criteria are copied verbatim (AC-1 to AC-9). Everything else comes from the [tech spec](tech-spec.md): assumptions A3–A5 (§1.3), NFR-9 and NFR-10 (§10, §13 — worded as the spec words them, not as the PRD does), the halo check (§9, §11, [ADR-0004](adr/0004-imageio-thumbnail-pipeline.md)), and every "Device checklist" row in §13 (see the [coverage map](#coverage-map-tech-spec-13-device-checklist-rows)).

## Run details

- **Build number:**
- **Device:** (target: iPad Air 4th gen)
- **iPadOS version:** (target: 26.7)
- **Tester:**
- **Date:**

> v1 is done when a family member can make and send a sticker on the iPad Air from a TestFlight build, with no help.

Suggested order: fresh install first (AC-1, FR-1, FR-20, A-3), then generate and keep a few stickers, then the send and display checks, then airplane mode and the failure cases, then restart the iPad (AC-7). AC-8, AC-9, AC-3 and NFR-5 need the Mac.

Use a throwaway OpenAI project key for the failure cases in AC-6, never the family key.

---

## 1. PRD acceptance criteria (verbatim)

- [ ] **AC-1** Fresh install with no key: opening the extension lands on the library with a "Set up OpenMoji" button that leads to the settings sheet; a valid key saves and the library shows "New sticker".
  - Source: AC-1; FR-5 (§13), FR-1, FR-4; [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: start with no key. Deleting and reinstalling OpenMoji is not enough: the Keychain key survives a reinstall, and that is intended (user decision 2026-10-05). So open Settings from the gear in Compose and tap Clear (and delete every sticker if you want the empty state). Open Messages, open OpenMoji from the app drawer, expand it. The empty library shows with "Set up OpenMoji" (not "New sticker"); tap it and the settings sheet opens. Enter a valid key (needs internet for validation); Save. The library shows again, now with "New sticker".
  - Notes:

- [ ] **AC-2** A typical prompt yields a sticker with a transparent background in under 30 s on Wi-Fi.
  - Source: AC-2; NFR-4 (§13), NFR-3
  - How: on Wi-Fi, time from tapping Generate to the preview appearing, for three typical prompts (for example `taco`, `rocket`, `grumpy cat`). Each under 30 s. Look at the preview against a non-white surface or send it to a dark bubble to confirm the background is transparent, not white.
  - Times: ______ s, ______ s, ______ s
  - Notes:

- [ ] **AC-3** Every saved sticker file is under 500 KB and between 300 and 618 px square.
  - Source: AC-3; NFR-1 (§13), FR-13, FR-14
  - How: with the library holding several stickers (include a detailed prompt such as `fluffy dog`), read each saved PNG under `Library/Application Support/Stickers/` in the App Group container: `ls -l` for size (< 500,000 bytes) and `sips -g pixelWidth -g pixelHeight` for 300 to 618 px with width equal to height. `index.json` also records `pixelSize` and `byteCount` per sticker (§4) but check the files themselves. TestFlight builds can't be inspected from Xcode, so use a dev-signed build of the same commit installed from Xcode (Window > Devices and Simulators > OpenMoji > Download Container) and note under Notes which method you used and that the App Group container was included.
  - Notes:

- [ ] **AC-4** Kept stickers send by tap and by peel-and-drag onto a bubble, and appear correctly on the recipient's iPhone.
  - Source: AC-4; FR-17, FR-18, A-4; recipient display in [REC-1](#4-rendering); [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: in a Messages conversation, in the expanded view, tap a kept sticker (it goes into the compose field, then send). Then touch-and-hold a sticker, peel it and drop it onto an existing bubble. Then confirm the recipient result under REC-1.
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **AC-5** Regenerate produces a new image from the same prompt without losing the library.
  - Source: AC-5; FR-11, FR-12, FR-24
  - How: count the stickers in the library. Generate a sticker, tap Regenerate without editing the prompt. A visibly new image replaces the preview and the prompt text is unchanged. Then tap Discard on the preview: Compose comes back with the prompt as it was, and the library count, contents and order are unchanged.
  - Notes:

- [ ] **AC-6** Each FR-22 failure (invalid key, budget exhausted, refusal, rate limit, timeout, offline) shows its own plain message.
  - Source: AC-6; FR-22 (§6 table), FR-23, FR-24
  - How: provoke each case and compare against the message in §6. For every case also confirm the prompt text is still there (FR-23) and the library is unchanged (FR-24). If a case can't be provoked on the device, say why under Notes; the `ErrorMapper` tests cover the mapping but not how it displays.
    - [ ] Invalid key: save a throwaway key, revoke or delete it in the OpenAI dashboard, then Generate. "The OpenAI key isn't working. Check it in Settings." with a Settings button.
    - [ ] Budget exhausted: Generate with a throwaway project whose spend limit or credit is used up. "The sticker budget is used up. Ask the family admin to top it up."
    - [ ] Refusal: Generate a prompt the admin has picked beforehand because OpenAI's moderation blocks it. "OpenAI won't make that one. Try wording it differently."
    - [ ] Rate limit: Generate or Regenerate repeatedly against a throwaway project with a low rate limit. "Too many stickers at once. Try again in N seconds." (no number if there is no `Retry-After`).
    - [ ] Timeout: start Generate, then stall the network (for example Settings > Developer > Network Link Conditioner at 100% loss, if available) and wait out the 90 s timeout. "That took too long. Try again."
    - [ ] Offline: turn on airplane mode, then Generate. "You're offline. Your stickers still work; making new ones needs internet."
  - Notes:

- [ ] **AC-7** The library survives closing Messages and restarting the iPad.
  - Source: AC-7; FR-16, FR-17 (§4: Application Support, not Caches)
  - How: with at least three kept stickers, swipe Messages away from the app switcher and reopen OpenMoji: same stickers, same newest-first order. Then power the iPad off, start it, unlock it, open Messages and OpenMoji: same stickers, same order.
  - Notes:

- [ ] **AC-8** A search of the repo and build artifacts finds no API key.
  - Source: AC-8; NFR-6, REL-6 (§12.3 steps 2 and 6b, [ADR-0012](adr/0012-secret-scanning-gitleaks.md))
  - How: on the Mac, at the commit of the build under test: `gitleaks detect --redact --no-banner` reports no leaks, and `grep -ra -E "sk-[A-Za-z0-9_-]{20,}" build/release/OpenMoji-<N>.xcarchive` finds nothing (the release lane's step 6b runs the same search, so its log can stand in). Also search for the real test key's value without typing it into the terminal, for example `grep -rFa -f <(op read "<1Password reference of the test key>") . build/release/OpenMoji-<N>.xcarchive`, and check the pattern file wasn't empty.
  - Notes:

- [ ] **AC-9** One pipeline run puts a new build in front of the family tester group.
  - Source: AC-9; REL-1 (§13), REL-5, REL-8
  - How: from a clean `main` on the release Mac run `make testflight` once (§12.3), with no manual App Store Connect step afterwards. Build N (`git rev-list --count HEAD`) appears in the Family group, and a family tester sees it offered in TestFlight with the "What to Test" notes taken from `git log`.
  - Notes:

---

## 2. Spec assumptions A3 to A5 (§1.3)

- [ ] **A-3** Text entry works in the expanded Messages-context view on iPadOS 26.
  - Source: A-3
  - How: expand OpenMoji in Messages and tap the prompt field. The keyboard opens and typed text (software keyboard, and dictation or a hardware keyboard if available) appears in the field without the extension collapsing or closing. Type up to the 200-character limit and see the counter.
  - Notes:

- [ ] **A-4 / FR-18** `MSStickerView` supports tap-to-insert and peel-and-drag in the expanded style (FR-18: library stickers send by tap and by peel-and-drag).
  - Source: A-4; FR-18 (§13 "Device checklist (A4)"); OQ-10, [ADR-0008](adr/0008-swiftui-with-msstickerview.md), [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: in the expanded view, tap a library sticker (it is inserted into the compose field) and peel-and-drag one onto a bubble. Also touch-and-hold a cell: the context menu (Delete) may open, but it must not stop the peel gesture from working. If tap doesn't insert, the fallback in ADR-0008 (`activeConversation?.insert`) is needed.
  - Expanded tap [ ] · expanded peel [ ] · context menu vs peel [ ]
  - Compact tap (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **A-5** `MSSticker` accepts file URLs inside the App Group container.
  - Source: A-5; OQ-11
  - How: Keep a sticker, then look at the library: kept stickers are read from the App Group container, so they must render in their cells and be insertable (tap or peel). A blank cell or a failed insert means the assumption is wrong and the temp-file fallback is needed.
  - Notes:

---

## 3. Accessibility and offline use

- [ ] **NFR-9 (VoiceOver)** VoiceOver labels cover every control, and each sticker cell's label is its description.
  - Source: NFR-9 (§10, §13), FR-15, [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: turn on VoiceOver (Settings > Accessibility). Swipe through the expanded library, Compose, Generating, Preview, Error and the Settings sheet: every control (prompt field, Generate, gear, Cancel, Keep, Regenerate, Discard, Try again, Save, Clear) has a meaningful spoken label. Each sticker cell reads its prompt as its description (the first 150 characters of the prompt).
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **NFR-9 (Dynamic Type)** Dynamic Type covers every control.
  - Source: NFR-9 (§10, §13), [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: set the text size to the largest accessibility size (Settings > Accessibility > Display & Text Size > Larger Text) and also check the smallest. In the expanded library, Compose, Preview, Error and the Settings sheet nothing is cut off or overlapping and every control is still reachable.
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **NFR-10** Library browsing, insert and drag need no network.
  - Source: NFR-10 (§10, §13)
  - How: with several kept stickers, turn on airplane mode (Wi-Fi off too). Open OpenMoji in Messages: the library shows, a sticker sends by tap, and a sticker sends by peel-and-drag. Generating is not expected to work offline (see the offline case in AC-6).
  - Notes:

---

## 4. Rendering

- [ ] **HALO-1** No light edge halo shows around a sticker on a dark bubble.
  - Source: §11 and §9 scoring item 5; [ADR-0004](adr/0004-imageio-thumbnail-pipeline.md)
  - How: use the iPad in Dark Appearance. Send kept stickers made from fine-detail prompts (`fluffy dog`, `curly hair girl`) onto a dark bubble (a dark gray or blue one) and zoom in on the edges. Fail if a light fringe or outline follows the shape.
  - Notes:

- [ ] **REC-1** The sticker appears correctly on a family iPhone (the recipient).
  - Source: AC-4; [ADR-0014](adr/0014-ipad-only-device-family.md)
  - How: send a sticker from the iPad to a family iPhone in an iMessage conversation. On the iPhone it arrives complete (not cropped), with a transparent background, sharp, and looks right in both light and dark appearance. Recipient device and iOS version: ______________
  - Notes:

---

## 5. Other tech spec §13 "Device checklist" rows

- [ ] **FR-1** The settings sheet is reachable from the expanded view and takes the key.
  - Source: FR-1 (§13, §8)
  - How: open Settings from the gear on the Compose screen (the library screen has no gear; with no key, its Set up OpenMoji button opens Settings). One secure field, Save and Clear are there. Enter something that doesn't start with `sk-`: "That doesn't look like an OpenAI key" and no network call.
  - Notes:

- [ ] **FR-3** After saving, only the last four characters of the key are shown; Clear removes the key.
  - Source: FR-3 (§13, §8)
  - How: after Save, the field is replaced by `•••• last4` matching the end of the key, and the full key never comes back into a text field (reopen Settings to confirm). Tap Clear: the key is gone, and the expanded view shows the library with "Set up OpenMoji" again (FR-5, ADR-0017).
  - Notes:

- [ ] **FR-17** The library grid shows in expanded, newest first.
  - Source: FR-17 (§13, §10), [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: Keep three stickers one after another. In the expanded view, the grid lists them newest first.
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **FR-20** An empty library shows an empty state.
  - Source: FR-20 (§13, §10), [ADR-0017](adr/0017-expanded-first-layout.md)
  - How: on a fresh install (before any Keep), the expanded view shows the empty state (and with no key also a "Set up OpenMoji" button, §8). Delete every sticker and it returns.
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **FR-21** "Reuse prompt" on a library cell's context menu (*Could* priority, built).
  - Source: FR-21 (§13, §10)
  - How: touch-and-hold a cell and choose Reuse prompt: Compose opens with that sticker's prompt in the field, and you can edit it. With no key the menu has Delete only.
  - Expanded test [ ]
  - Compact test (N/A: unreachable on iPadOS 26 per [ADR-0017](adr/0017-expanded-first-layout.md))
  - Notes:

- [ ] **NFR-5** Peak memory on the generation-to-keep path stays under 30 MB resident above the idle baseline.
  - Source: NFR-5 (§13 "Instruments on iPad Air"), §7.2
  - How: attach Xcode Instruments (Allocations) to the Messages extension process on the iPad Air, from a dev-signed build of the same commit (TestFlight builds can't be attached). Note the idle baseline, run Generate, Preview and Keep, and record the peak. The Instruments run is the evidence for NFR-5, not the API's name (§7.2).
  - Idle ______ MB, peak ______ MB, difference ______ MB
  - Notes:

---

## Coverage map (tech spec §13 "Device checklist" rows)

| §13 row | Verified by | Item |
|---|---|---|
| FR-1 | Device checklist | FR-1 |
| FR-3 | `AppModel` tests; device checklist | FR-3 |
| FR-5 | Acceptance criterion 1 | AC-1 |
| FR-17 | `LibraryStore` order test; device checklist | FR-17 |
| FR-18 | Device checklist (A4) | A-4 / FR-18, AC-4 |
| FR-20 | Device checklist | FR-20 |
| FR-21 | `AppModel` test; device checklist | FR-21 |
| NFR-1 | Acceptance criterion 3 | AC-3 |
| NFR-4 | Acceptance criterion 2 | AC-2 |
| NFR-5 | Instruments on iPad Air | NFR-5 |
| NFR-9 | Device checklist with VoiceOver | NFR-9 (VoiceOver), NFR-9 (Dynamic Type) |
| NFR-10 | Device checklist in airplane mode | NFR-10 |
| REL-1 | Acceptance criterion "one pipeline run" | AC-9 |

Also from §11: A3–A5 (A-3, A-4, A-5), Instruments peak memory (NFR-5) and the dark-bubble halo check (HALO-1). AC-5, AC-6, AC-7 and AC-8 have no §13 row of their own and come from the PRD list.
