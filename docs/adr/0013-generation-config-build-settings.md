# ADR-0013: Model ID and quality via build settings into Info.plist

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
FR-9: the model ID and quality come from configuration, not hard-coded call sites. OpenAI changes models often; for example, `gpt-image-1.5` is retired on 2026-12-01. There is no backend (D5) to serve remote config, and the PRD asks for no user-facing model picker.

## Decision
- `project.yml` defines `OPENMOJI_IMAGE_MODEL` (default `gpt-image-2.5-flare`) and `OPENMOJI_IMAGE_QUALITY` (default `medium`, pending OQ-4), exposed as Info.plist keys `OpenMojiImageModel` and `OpenMojiImageQuality`.
- `GenerationConfig` reads them once, with compiled-in fallbacks.
- Changing the model is a one-line `project.yml` edit plus `make testflight`.

## Alternatives
- **Hidden setting in the extension.** Runtime switching without a build, but it's more UI and family members could change it by accident.
- **Remote config file (e.g. a gist).** Needs a fetch, a trust model and offline handling; that's a backend in disguise (D5).

## Consequences
- A model change costs one release, which is cheap with the lane, and builds expire in 90 days anyway.
- The stored `Sticker.modelID` records which model made each sticker.
