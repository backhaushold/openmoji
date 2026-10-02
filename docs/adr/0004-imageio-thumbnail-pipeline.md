# ADR-0004: ImageIO thumbnailing and a PNG step-down ladder

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
OpenAI returns a 1024 × 1024 PNG (the smallest square it offers; custom sizes must be ≥ 655,360 px total). Messages needs < 500 KB (hard) and 300–618 px at @3x (guidance). Extensions run with much less memory than apps, with no documented number (NFR-5: never fully decode the source). FR-14: step down until it fits, never below 300 px.

## Decision
- Create a `CGImageSource` from the encoded bytes with caching off.
- Produce each candidate with `CGImageSourceCreateThumbnailAtIndex` (`CreateThumbnailFromImageAlways`, `ThumbnailMaxPixelSize = edge`, `WithTransform`, `ShouldCacheImmediately`).
- Encode with `CGImageDestination` as PNG.
- Try edges `[618, 560, 512, 448, 384, 300]`, each **from the original source**, and stop at the first result under 500,000 bytes.
- 300 px always fits: 300² RGBA is 360 KB raw, and the PNG worst case is about 362 KB.

## Alternatives
- **`UIImage(data:)` + `UIGraphicsImageRenderer`.** Simple, but decodes the full 1024² bitmap (4 MB) and pulls UIKit into Core.
- **vImage / Core Image resampling.** Higher-quality filters but needs a full decode; more code.
- **Request WebP and convert.** Smaller download, but adds a decode path. Messages accepts PNG, not WebP, so we would re-encode anyway.
- **Binary search on edge size.** Fewer encodes in theory; the ladder is 6 steps max and usually 1.

## Consequences
- Peak extension allocation is about 7 MB for processing; NFR-5 is verified with Instruments on the iPad Air, since Apple doesn't guarantee reduced-resolution decoding.
- The thumbnail filter quality is ImageIO's; acceptable for emoji-style art at ≤ 618 px. M1 checks for edge halos.
- Pure function on `Data`; unit-testable on macOS.
