# M1 generation spike: findings

- **Issue:** openmoji-6sl. Feeds OQ-4 (default quality, openmoji-zrx), OQ-9 (real cost) and the `StyleTemplate` task (openmoji-5lx).
- **Run:** 2026-10-03 01:21 to 01:34 UTC, 60 requests, sequential, from one Mac on a home network. 15 of the 75-request cap unspent.
- **Tooling:** [spikes/m1/](../../spikes/m1/README.md). Raw ledger: `spikes/m1/results/requests.jsonl`. Per-output checks: `spikes/m1/results/analysis-v1.csv`. Scores: `spikes/m1/results/scores.csv`. Generated images are not committed.
- **Status of the numbers below:** measurements are facts from the ledger. The scores are one rater's (an AI agent's) reading of the contact sheets, so look at the sheets before ratifying anything. The OQ-4 and OQ-9 items are **proposals**; the user ratifies them.

## Verdict

The tech spec section 9 template passes the bar at all three qualities: 20 of 20 outputs pass items 1 to 4 at `low`, `medium` and `high` (bar: at least 17 of 20). No refusals, no errors, no halos, no text, every output has real alpha. Nothing needed tuning, so the template for `StyleTemplate` is the section 9 text unchanged. No revised template was run, and none is proposed.

## Setup

Request fields exactly as in tech spec section 5.1: `model` `gpt-image-2.5-flare`, `n` 1, `size` `1024x1024`, `quality` (varied), `background` `transparent`, `output_format` `png`, `moderation` `auto`; no `response_format`. Every response echoed `background: transparent`, `output_format: png`, the requested quality and `size: 1024x1024`. Sticker processing mirrors section 7 (ImageIO thumbnail at 618 px, step down the ladder until the PNG is under 500,000 bytes). The spike timeout was 180 s (the app's NFR-4 limit is 90 s); no request came near 90 s.

Template: section 9 verbatim, user prompt at `{subject}`.

### Prompt set (20)

| # | Prompt | Source |
|---|---|---|
| 1-2 | grumpy cat, grandma laughing | section 9 (faces) |
| 3-4 | taco, rocket | section 9 (objects) |
| 5-6 | brain freeze, monday mood | section 9 (abstract) |
| 7-8 | happy birthday, thank you | section 9 (text-bait) |
| 9-10 | fluffy dog, curly hair girl | section 9 (fine detail) |
| 11 | two penguins hugging | section 9 (multi-subject) |
| 12 | `a` | section 9 (edge case) |
| 13 | 200-character prompt: "a very tired astronaut cat floating in space, holding a giant cup of coffee, wearing mismatched socks and a party hat, looking surprised that the moon is made of cheese wedges and tiny crispy crackers" | section 9 (edge case, written for the spike) |
| 14 | `🐸☕️` | section 9 (edge case, emoji only) |
| 15-17 | dad's burnt pancakes, the dog stealing socks, grandpa's fishing hat | **stand-ins** for the 3 family in-jokes, which the family has not chosen yet |
| 18-20 | pizza slice, sleepy sloth, thumbs up | **added** to reach 20: an object with fine detail, an animal with fur and a low-energy expression, a hand gesture |

## Results

Scoring items: 1 reads as an emoji at 100 pt; 2 background fully transparent; 3 no text; 4 subject centred and uncropped; 5 edge halo visible on a dark bubble. Items 1 to 4 are pass/fail; "all four" counts outputs that pass every one of them (the stricter reading of the bar).

| | low | medium | high |
|---|---|---|---|
| Requests ok / refused / other errors | 20 / 0 / 0 | 20 / 0 / 0 | 20 / 0 / 0 |
| Item 1 pass | 20 | 20 | 20 |
| Item 2 pass | 20 | 20 | 20 |
| Item 3 pass | 20 | 20 | 20 |
| Item 4 pass | 20 | 20 | 20 |
| All four pass (bar: 17) | **20** | **20** | **20** |
| Halo seen (item 5) | 0 | 0 | 0 |
| Latency p50 (nearest rank) | 9.0 s | 10.2 s | 19.1 s |
| Latency p90 | 10.0 s | 11.9 s | 20.4 s |
| Latency min / max | 7.7 / 10.8 s | 8.9 / 12.3 s | 17.0 / 21.1 s |
| Output image tokens (every request) | 196 | 439 | 1,756 |
| Cost per attempt, mean | $0.0064 | $0.0137 | $0.0532 |
| Cost per attempt, max | $0.0066 | $0.0139 | $0.0534 |
| Cost, 20 attempts | $0.128 | $0.274 | $1.064 |

Latency is wall-clock from sending the request to having the full response body (about 1.5 MB of base64), the same span the app's `URLSession` call covers. Cost is computed from each response's `usage` field (all three token classes were returned) with the GPT Image 2.5 prices in tech spec section 1.2: $5 per million text input tokens, $8 per million image input tokens, $30 per million image output tokens. **Prices are as stated in the spec, not re-checked against OpenAI's pricing page in this spike.** Image input tokens were always 0 and text input was 104 to 109 tokens (142 for the 200-character prompt), so cost is almost entirely the image output: 196, 439 and 1,756 tokens per image at low, medium and high, identical across all 20 prompts at each quality. Total spend for the 60 requests: $1.467.

### Programmatic checks (all 60 outputs, raw 1024 px PNG)

- Alpha channel present: 60 of 60. Corner patches (16 px) have alpha at most 1 of 255 in every output; 26% to 66% of pixels are fully transparent.
- Subject centre within 8% of the canvas centre in every output (largest offset 0.077, `long-200` at medium).
- Nothing touches the canvas edge in 57 of 60. The three flagged: `grandma laughing` at medium and high (the rounded bottom of the bust sits on the bottom edge) and `fluffy dog` at low (ear tips flush with the top edge). Zoomed in, the outlines are intact, so none is sliced; scored as pass with a note in `scores.csv`.
- A light-fringe proxy (share of boundary pixels that are near white) read up to 16%. Zoomed on a dark background these were white mugs, flame and eye highlights and an unoutlined lime belly edge on the frog, not matting halos. Hair, fur and ice edges are cleanly outlined. Halo count is 0 of 60.
- **Finding:** subject pixels are alpha 250 to 254, never 255, so the subject is about 1% see-through. Invisible on a bubble, but it is why the PNGs compress poorly (next item).
- Processed stickers: all 60 are under 500,000 bytes and carry alpha. 57 are 618 px and 3 stepped down to 560 px (all `dad's burnt pancakes`, one per quality). Largest 487,771 bytes, mean about 388,000. The raw PNGs average 1.1 MB, not the roughly 2 MB assumed in section 7.2.

### Observations

- The style is consistent across all 60: bold dark outline, flat colours with glossy highlights, faces on objects.
- Text-bait prompts (`happy birthday`, `thank you`) produced a cake and praying hands with no letters. `a` did not draw a letter; it produced an arbitrary subject (an octopus at low, a golden puppy at medium and high), so one-character prompts are not repeatable. The emoji-only prompt gave a frog holding coffee.
- `long-200` is the busiest output (astronaut cat, coffee, socks, party hat, cheese moon). It still reads at 100 px but the face is small.
- Subjects fill more of the canvas than the template's "about 85%": the longer axis averages 95% to 97% and 13 to 19 outputs per quality reach 95% or more. It works, but there is no margin around the sticker.
- The three qualities differ in detail and in which interpretation the model picks (for example the pizza gets mushrooms and green peppers only at high, and `brain freeze` is a brain with a slushie at low, an iced brain at medium and a blue glowing blob at high), not in whether they read as emoji. High costs about 4 times as much and takes about 2 times as long as medium. This is a judgement from the sheets, not a score.
- Not tested: `xhigh`, `max`, the other output formats, and run-to-run variance (one generation per prompt and quality).

## Proposals (for the user to ratify)

**OQ-4, default quality: `medium`.** It passes 20 of 20, costs about 1.4 cents, answers in about 10 s, and sits well inside both NFR-4 and NFR-8. `low` also passes 20 of 20 at under half the cost and about 1 s faster, so it is a defensible economy setting if the sheets look the same to the family; the visible difference is detail, not failure. `high` doubles latency and costs 4 times as much for richer detail, and misses the NFR-8 figure of $0.05. This keeps the spec's current default (`medium`) rather than changing it. Ratifying means `bd close openmoji-zrx --reason "Ratified: ..."` and the other steps in CLAUDE.md; this spike does not do that.

**OQ-9, real cost and latency per attempt** (replaces NFR-8's unverified "< $0.05"), at `medium`: **$0.0137 mean, $0.0139 max per attempt, p50 10.2 s, p90 11.9 s, max 12.3 s.** At low it is $0.0064 and 9.0 s; at high $0.0532 and 19.1 s. Prices are the spec's section 1.2 values. NFR-8 as worded ("under about $0.05 at medium") is met with a factor of 3.6 to spare. A PRD edit is needed to replace the estimate with the measured figure; that edit is the user's call and was not made here. Rough scale: a $5 top-up is about 360 medium attempts.

## Tuned template for StyleTemplate (openmoji-5lx)

Unchanged from tech spec section 9. `{subject}` receives the trimmed prompt (at most 200 characters), verbatim.

```text
A single emoji-style sticker of {subject}.
Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
bright saturated colors, soft cel shading, glossy highlight, friendly expression where a face applies.
Composition: one subject, centered, filling about 85% of a square canvas, fully in frame, front-facing.
Background: fully transparent. No scene, no ground, no drop shadow, no border, no frame.
No text, letters, numbers, captions or watermarks.
```

Optional, only if the missing margin around subjects turns out to matter on the device: lower "about 85%" to a smaller figure. It is untested and not needed to meet the bar.

## Caveats

- One rater, one generation per cell, one machine and network. A 20 of 20 result with this much headroom is robust to a stray miss, but not a guarantee that a given family prompt works.
- The three family in-jokes are stand-ins; re-run those slots (3 prompts at the chosen quality) once the family picks them.
- Latency includes this network's download time for a 1.5 MB body.

## Follow-ups

- Subjects come back at alpha 250 to 254, which likely inflates PNG size (up to 488 KB at 560 or 618 px against the 500 KB limit). Worth measuring whether snapping alpha of 250 or more to 255 before encoding shrinks stickers without a visible change. Filed as openmoji-ufo. Measured: see Alpha snap below (not implemented).
- Tech spec section 5.2 calls `usage` optional and section 7.2 assumes a roughly 2 MB source PNG. Observed: `usage` is always present with `input_tokens_details` and `output_tokens_details`, and raw PNGs are about 1.1 MB. No spec edit was made here.

## Alpha snap

Issue openmoji-ufo. Question: would snapping alpha 250 to 254 up to 255 on the ImageIO thumbnail, before the PNG encode, shrink the sticker, without changing anything visible? Bar: a size win of at least 10%.

**Decision: not implemented.** `StickerProcessor` is unchanged. The numbers below come from synthetic fixtures, not from real model output (see Data); they put the win at about 0.5% to 6% in the realistic cases and 10% to 14% only in one corner. Re-open if `alpha-snap dir` on real raw PNGs shows 10% or more.

### Data

The 60 raw M1 PNGs are gone (`out/` is git-ignored and lived in a removed worktree) and regenerating them costs money this issue did not authorise, so no real raw output was measured. Two substitutes, both from [spikes/m1/alpha-snap.swift](../../spikes/m1/alpha-snap.swift):

- **Real alpha structure, from the contact sheets (`sheets` mode).** Each sticker is composited over a light (`F2F2F7`) and a dark (`1C1C1E`) background, so per channel (light - dark) = (1 - alpha) x (L - D) and the alpha deficit (255 - alpha) can be read back per pixel to about half a level, at 300 px. Over 2.9 million deep-interior pixels (all 60 stickers): mean deficit 2.3 (alpha about 253), 75% at 2 levels, and neighbouring pixels are strongly correlated (0.79 at 1 px apart, 0.54 at 5 px). I.i.d. noise over 250 to 254 would read 0.20 and 0.05 with a mean deficit of 3.5. So the model's alpha is a slowly varying field around 253, with at most weak per-pixel noise; synthetic fields with a +-1 per-pixel component on 25% to 100% of pixels bracket the real lag figures (0.82 / 0.64 and 0.62 / 0.47).
- **Synthetic 1024 px fixtures (`synthetic` mode).** Flat-shaded emoji art with an outline, gradients, fur-like strokes and anti-aliased edges (4 variants, one with no strokes), straight RGBA like the model's PNG, alpha in the fully opaque pixels from the models above, and per-channel colour grain of 0, 1 or 2 levels. Run through the same thumbnail, PNG encode and ladder as section 7.1. Calibration target: the real stickers cost 12.5 to 20 bits per visible pixel at 618 px (mean 14.3, from `analysis-v1.csv`). Colour grain cannot be read from the sheets well enough to pin down, which is why it is a sweep.

### Results

Size change at 618 px with the snap (negative is smaller), and baseline bits per visible pixel, ranges over the 4 variants:

| Alpha model | grain 0 | grain 1 | grain 2 |
|---|---|---|---|
| smooth (253 +- 1) | -1.5 to -3.5%, 6.7 to 12.5 b/px | -0.6%, 12.0 to 15.7 | -0.4 to -0.5%, 14.1 to 17.2 |
| smooth + noise on 1 pixel in 4 | -9.8 to -13.6%, 9.6 to 14.2 | -3.4 to -4.1%, 12.5 to 16.3 | -2.6 to -3.4%, 14.5 to 17.7 |
| smooth + noise on every pixel | -11.6 to -14.5%, 11.0 to 15.3 | -5.0 to -5.8%, 12.9 to 16.8 | -3.8 to -4.7%, 14.7 to 18.0 |
| i.i.d. 250 to 254 (ruled out by the sheets) | -12.8 to -16.3%, 12.0 to 16.2 | -7.2 to -7.8%, 13.4 to 17.2 | -4.9 to -6.0%, 15.0 to 18.3 |

The same 12.5 to 20 b/px that the real stickers show is reached both with no colour grain and noisy alpha (a roughly 10% to 14% win) and with grain of about 1 level and calm alpha (0.5% to 6%), and the real data cannot tell these apart. Two weak pointers favour the second: the sheet alpha statistics sit between the "smooth" and "noise on every pixel" rows, and the colour residual in flat areas of the sheets (rms 0.54 levels; the same measure gives 0.37 to 0.49 for grain 0, 0.49 to 0.55 for grain 1 and 0.63 or more for grain 2) reads like grain of about a level, though the real art's own texture feeds that number too. So the realistic band is 0.5% to 6%, and the 10%+ corner needs both no colour grain and per-pixel alpha noise.

- **Visible change.** At every edge of every fixture: 0 pixels below alpha 250 changed (byte-identical, so anti-aliased edges are untouched); pixels from 250 to 254 move by at most their own deficit when composited on white or black (5 levels of 255 in the worst case, 2 to 3 at the real mean). The snap un-premultiplies the colour by the old alpha, so only the near-opaque interior goes from about 99% to 100% opaque; there is no halo and no edge change.
- **Cost.** Median 0.46 ms at 618 px (0.12 ms at 300) in an optimised build, against 8 ms for one PNG encode. It needs one extra 618 px premultiplied bitmap (1.5 MB), taking the section 7.2 peak from about 7 MB to about 8.5 MB. Only the thumbnail is workable; a full-size snap would need the 4 MB decode that NFR-5 avoids.
- **It would not change a ladder outcome in the M1 set.** 57 of 60 stickers already fit at 618 px. The three that stepped to 560 px (`dad's burnt pancakes`: 487,771 / 471,924 / 479,559 bytes at 560 px) would be about 594 / 575 / 584 KB at 618 px by pixel count and need a cut of 13% to 16%; the realistic band is nowhere near, and the 10%+ corner only just reaches the smallest of the three. At best the snap buys headroom under 500 KB, not a larger sticker.

### Why not

At best an unproven 10% win in one corner, at 0.5% to 6% in the realistic band, with no sticker in the sample moving up the ladder outside that corner; against about 25 lines of pixel code plus a test in the one function whose point is a simple, predictable ladder. Not worth adding on synthetic evidence.

To settle it with real data: save the raw PNGs from the next paid run (for example the 3 family in-jokes at the chosen quality, see Caveats), then `swiftc -O spikes/m1/alpha-snap.swift -o /tmp/alpha-snap && /tmp/alpha-snap dir spikes/m1/out/raw/<template>/<quality>`.
