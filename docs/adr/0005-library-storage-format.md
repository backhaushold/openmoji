# ADR-0005: Library as PNG files plus an atomic JSON index

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
FR-16 needs each kept sticker stored with its prompt, date and model ID. `MSSticker` needs a **file URL**, so the PNG must exist on disk regardless of the metadata store. The library is per device (D4), expected to hold tens to low hundreds of items, with no querying beyond newest-first. FR-24: never lose a kept sticker.

## Decision
- Each sticker is `<uuid>.png`.
- Metadata is a single `index.json` (`schemaVersion`, `stickers` newest first), rewritten with `Data.write(options: .atomic)`.
- Both live in `<App Group>/Library/Application Support/Stickers/`.
- Write order: PNG first, then the index. Delete order: index first, then the PNG.
- A corrupt index is set aside, never deleted along with images.

## Alternatives
- **SwiftData / Core Data.** Migrations, a model container in the extension, and more memory, for no query need. The PNG still has to be a file.
- **Image blobs inside SQLite / SwiftData.** `MSSticker` still needs a file, so it would mean double storage.
- **One sidecar JSON per sticker.** No single point of corruption, but listing needs a directory scan and N reads. Revisit if the index ever proves fragile.

## Consequences
- Trivial to inspect and test.
- Whole-index rewrite on every Keep or Delete is fine at this scale (a few KB).
- A crash between the PNG and index writes leaves a harmless orphan PNG; v1 doesn't sweep orphans.
