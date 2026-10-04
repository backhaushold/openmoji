# ADR-0008: SwiftUI hosted in MSMessagesAppViewController, with MSStickerView cells

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
The extension needs a sticker grid with tap-to-insert and peel-and-drag (FR-17, FR-18), plus prompt, preview, settings and delete UI. Messages has no SwiftUI sticker API. `MSStickerBrowserViewController`, `MSStickerBrowserView` and `MSStickerView` are current (not deprecated). `MSStickerView` provides the peel-and-drag gesture.

## Decision
- `MessagesViewController` (an `MSMessagesAppViewController`) hosts a single `UIHostingController`.
- Views are SwiftUI, driven by an `@MainActor @Observable AppModel`.
- Library cells are a `UIViewRepresentable` around `MSStickerView` in a `LazyVGrid`.
- Delete and "reuse prompt" are SwiftUI context-menu actions on the cell.

## Alternatives
- **`MSStickerBrowserViewController` for the grid.** Grid, tap and drag for free, but we must layer delete UI, empty state and mixed compose content around a UIKit collection view we don't control. Some gestures, such as long-press for delete, may conflict with peel.
- **All-UIKit.** More code for the compose, preview and settings flows.

## Consequences
- We own the grid layout and the empty state.
- **Risk:** long-press context menus may compete with `MSStickerView`'s peel gesture. M3 checks this; fallback is an explicit Edit mode with delete badges.
- Tap-to-insert relies on `MSStickerView`. If it doesn't insert on tap in some style, fall back to `activeConversation?.insert(sticker)`.
- **Decided 2026-10-04 (OQ-10, [ADR-0017](0017-expanded-first-layout.md)):** on device in expanded, tap inserts and a context menu coexists with peel, so neither fallback is needed. Compact is unreachable on iPadOS 26, so it is untested.
