# ADR-0009: Validate the API key with GET /v1/models/{model}

- **Status:** Accepted (user, 2026-10-02)
- **Date:** 2026-10-02

## Context
FR-4 asks for a cheap authenticated call on save. The PRD's risk mitigation restricts the key to image generation. `GET /v1/models` requires the **List models: Read** (`api.model.read`) permission; a key restricted to Model capabilities alone fails it ([RBAC](https://developers.openai.com/api/docs/guides/rbac)).

## Decision
- Grant the family key **Model capabilities: Request** plus **List models: Read**.
- Validate with `GET /v1/models/{configured model ID}`. 401 means invalid; 403 means not permitted. 404 saves with a warning: valid key, model not visible, possibly an unverified org. A 403 whose error `code` is `model_not_found` (reported for project-scoped keys, undocumented by OpenAI) is treated like 404.
- Offline offers "Save anyway".

## Alternatives
- **Validate with a `low`-quality generation.** Needs no extra permission and proves image access end to end, but costs about $0.006 every save and takes seconds.
- **No validation.** FR-4 is only *Should*, but a bad key would then surface on the first generation, a worse first-run experience.

## Consequences
- The key carries one extra read-only scope, a negligible risk increase.
- Also detects a wrong model ID or missing org verification at setup.
- Treats the models endpoint as free: OpenAI's pricing bills only tokens, image outputs and tool calls (OQ-6, resolved 2026-10-03).
