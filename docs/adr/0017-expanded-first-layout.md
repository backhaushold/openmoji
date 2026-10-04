# ADR-0017: Expanded-first layout, with the library grid as the landing screen

- **Status:** Proposed (design approved by the user, 2026-10-04)
- **Date:** 2026-10-04

## Context
[Tech spec](../tech-spec.md) §10 (2026-10-02) assumed the usual Messages flow: the extension opens compact, in the drawer under the thread, showing the library grid, and "New sticker" requests expanded for text entry. The M3 on-device probe (bead `openmoji-25h`, PR #54) ran on 2026-10-04 on the iPad Air with iPadOS 26: a Debug build of `main@ddc3bb4`, opened from the Messages + menu. Results are on beads `openmoji-zls`, `openmoji-jqa` and `openmoji-25h`.

- **Compact is unreachable.** `requestPresentationStyle(.compact)` does nothing: the style stays expanded and no transition is logged. Swiping down on the extension, or tapping Messages' own text box, dismisses the app instead of collapsing it. The same holds in landscape: closing and reopening OpenMoji from the + menu still opens expanded only.
- **Expanded works.** Tap-to-insert and peel-and-drag from `MSStickerView` both work, and a SwiftUI `.contextMenu` on a cell coexists with peel: holding still shows the menu, an immediate drag peels (OQ-10). `activeConversation.insert` also works. A `TextField` takes keyboard input (A3). An `MSSticker` created from an App Group file URL renders, with no temp copy (OQ-11, A5).
- Compact therefore couldn't be tested at all, so A4 is verified for expanded only.

## Decision
- The extension is designed for expanded. The **library grid is the first screen of the expanded view**: newest first, with the empty state, and a "New sticker" button that opens Compose. The grid moves out from below Compose to this landing screen.
- Compose, Generating, Preview, Error and Settings stay in expanded, unchanged. Settings stays reachable from Compose.
- A **minimal compact layout** stays: the same grid, with "New sticker" requesting expanded. It exists only in case compact ever appears (another iPad, a later iPadOS). `MessagesViewController` keeps forwarding presentation-style transitions into `AppModel.presentationStyle`.
- **Routing with no key (FR-5).** The old rule opened expanded straight to Settings and showed the library only in compact. With compact unreachable, that would hide the library behind Settings whenever there is no key, for example after Clear, although browsing and sending existing stickers need no key (NFR-10). So expanded with no key lands on the same library grid, with the empty state if the library is empty, and a **"Set up OpenMoji"** button in place of "New sticker". The button opens Settings. This is what the old compact route did, now applied to the landing screen. Saving a key returns to the grid with "New sticker".

## Alternatives
- **Keep compact-first.** Rejected: the primary screen would be built, and tested, for a presentation style the app never starts in on the target device. The grid would stay a secondary section under Compose in expanded, and no-key expanded would keep hiding the library behind Settings.
- **Investigate further** (other iPad models or iPadOS versions, Stage Manager, other ways to trigger compact) before deciding. Rejected for now: the probe covered the target device in portrait and landscape, and the minimal compact layout already handles compact if it appears. Revisiting costs little.

## Consequences
- Tech spec updated: A3–A5 (verified), the architecture diagram, §8 Routing, §10 and FR-17's traceability row. OQ-10 and OQ-11 are resolved.
- [ADR-0008](0008-swiftui-with-msstickerview.md) stands. Its Edit-mode fallback (long-press versus peel) and its `activeConversation?.insert` fallback are not needed.
- FR-17 holds: the grid shows in expanded, and in compact if it appears. FR-18 is verified in expanded. If compact ever appears, repeat the tap, peel and context-menu checks there.
- A first run with no key takes one extra tap: the empty grid with "Set up OpenMoji", then Settings, instead of opening straight on Settings. That is the price of one uniform rule that keeps the library reachable.
