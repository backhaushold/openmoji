# ADR-0002: Use the Images API generations endpoint

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
GPT Image 2.5 Flare (`gpt-image-2.5-flare`) is reachable two ways: `POST /v1/images/generations`, or the Responses API with a mainline model and the `image_generation` tool. The model page lists `v1/responses` as unsupported for direct calls. OpenAI's guide recommends the Image API "if you only need to generate or edit a single image from one prompt" ([guide](https://developers.openai.com/api/docs/guides/image-generation)).

## Decision
Use `POST /v1/images/generations` with `n: 1`, `size: 1024x1024`, `background: transparent`, `output_format: png`, and the model ID and quality from configuration (ADR-0013). Parse `data[0].b64_json`.

## Alternatives
- **Responses API + image tool.** Supports multi-turn refinement and `revised_prompt`, but bills a mainline model on top, adds latency, and needs a more complex response parser. Multi-turn editing is out of scope (D2, D3).
- **`/v1/images/edits`.** Needs input images, which D2 excludes.

## Consequences
- One request and one response shape; simple to stub in tests.
- If OpenAI moves 2.5 off the Images API, the client changes, but only inside `OpenAIClient`.
- Prompt rewriting by the model is invisible; the style template (FR-7) carries all the steering.
