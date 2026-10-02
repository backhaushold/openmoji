# ADR-0014: iPad-only device family

- **Status:** Accepted (user, 2026-10-02, resolves PRD OQ-2)
- **Date:** 2026-10-02

## Context
The target device is an iPad Air (4th gen). A universal build would also run on family iPhones. Sagelet's history shows device-family choices have upload consequences: a universal target was rejected for a missing iPad icon.

## Decision
`TARGETED_DEVICE_FAMILY = 2` on both the app and the extension. The App Store Connect record is iPad-only.

## Alternatives
- **Universal.** Small code cost, but adds iPhone icon sets and iPhone compact-layout testing, and widens the family test matrix.

## Consequences
- Family iPhones can still *receive* OpenMoji stickers; they are ordinary image attachments, and the acceptance criteria require that they display correctly on the recipient's iPhone.
- Adding iPhone later means changing this setting, adding icons and a layout pass. Nothing in the architecture is iPad-specific.
