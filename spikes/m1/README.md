# M1 generation spike

Throwaway tooling for openmoji-6sl. It runs the tech spec section 9 evaluation set (20 prompts)
against `gpt-image-2.5-flare` at `low`, `medium` and `high`, measures latency and usage cost, turns
each result into a sticker the way section 7 does, and renders contact sheets for scoring. Results
and the recommendation are in [docs/spikes/m1-findings.md](../../docs/spikes/m1-findings.md).

Nothing here is part of the app, `OpenMojiCore` or CI. Foundation, ImageIO and CoreGraphics only.

## Files

| Path | What |
|---|---|
| `spike.swift` | The script: `run`, `render`, `summary`, `selftest` |
| `alpha-snap.swift` | openmoji-ufo: would snapping alpha 250 to 254 up to 255 shrink the sticker PNG? `dir`, `synthetic`, `sheets` modes; see the findings doc |
| `op.env` | One line, `OPENAI_API_KEY=op://...`, a 1Password reference (no secret) |
| `results/requests.jsonl` | Ledger, one line per API request: status, latency, `usage`, cost, error. Also enforces the 75-request cap |
| `results/analysis-<template>.csv` | Programmatic transparency, framing and edge checks per output |
| `results/scores.csv` | Hand scores per output (see the findings doc) |
| `out/` | Git-ignored. Raw model PNGs, processed stickers and contact sheets under `out/sheets/<template>/` |

## Secrets

The OpenAI key lives only in 1Password (`op://OpenMoji/openai-backhaushold-openmoji-sa/password`).
`op run` injects it as `OPENAI_API_KEY` for the one command and masks it in output. The script
never prints it, writes it to disk, or puts it in an error. Text taken from API error bodies is
scrubbed of `sk-...` strings before it is stored.

The 1Password service-account token (`OP_SERVICE_ACCOUNT_TOKEN`) lives in the main checkout's
`.env`, which is git-ignored. Load it inside the same shell command that runs `op`, and never
read, print or copy that file:

```bash
set -a; . /path/to/repo/.env; set +a
op run --env-file spikes/m1/op.env -- swift spikes/m1/spike.swift run
```

## Re-running

From the repo root. `swift spikes/m1/spike.swift ...` interprets the script; `swiftc -O` first is faster for `render`.

```bash
# Free: check the processing, analysis and sheet code with synthetic images.
swift spikes/m1/spike.swift selftest --out /tmp/m1-selftest --results /tmp/m1-selftest/results

# Spends money: all 20 prompts x low, medium, high = 60 requests, sequential.
set -a; . /path/to/repo/.env; set +a
op run --env-file spikes/m1/op.env -- swift spikes/m1/spike.swift run

# Spends money: a subset (prompt numbers 1-20, comma separated, and chosen qualities).
op run --env-file spikes/m1/op.env -- swift spikes/m1/spike.swift run --prompts 1,2,3 --qualities medium

# Free: rebuild stickers, analysis CSV and contact sheets from the saved raw PNGs.
swift spikes/m1/spike.swift render

# Free: latency percentiles, cost and score counts from the ledger and scores.csv.
swift spikes/m1/spike.swift summary
```

- A prompt x quality x template that already has a ledger line is skipped, so a re-run never pays twice. `--force` overrides that (and counts against the cap).
- The cap is 75 requests in total across all invocations: `run` refuses to start if the ledger plus the planned requests would exceed it, and `--max-requests` can only lower it.
- No retries, including after moderation refusals: every refusal is recorded and moves on.
- Templates live in `Templates` in `spike.swift`; `--template <name>` selects one, and outputs and sheets are kept apart per template name.
- Requests use exactly the section 5.1 fields: `model`, `prompt`, `n=1`, `size=1024x1024`, `quality`, `background=transparent`, `output_format=png`, `moderation=auto`; no `response_format`. The spike timeout is 180 s (not NFR-4's 90 s) so slow runs are measured; runs over 90 s are counted in `summary`.

## Contact sheets

For each template and quality, `out/sheets/<template>/`:

- `<quality>-dark.png`, `<quality>-light.png`: the 20 processed stickers at 300 px on `#1C1C1E` and `#F2F2F7` (a halo shows on the dark one).
- `<quality>-small.png`: the same 20 at 100 px, dark row then light row (the "reads as an emoji at 100 pt" check).

## Scoring

Items 1 to 4 are pass (1) or fail (0): emoji read at 100 pt, background fully transparent, no text,
subject centred and uncropped. Item 5 is halo seen on the dark bubble (1) or not (0). The pass bar is
at least 17 of 20 on items 1 to 4. The findings doc reports both per-item counts and the stricter
count of outputs that pass all four.
