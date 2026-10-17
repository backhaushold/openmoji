# ADR-0021: Soften the style template's face clause so objects don't all get a face

- **Status:** Accepted (user, 2026-10-17)
- **Date:** 2026-10-15

## Context
The user's daughter, a family tester on TestFlight build 86, reported that every sticker comes out with eyes and a face, plain objects and food included (bead `openmoji-6dr.9`). The M1 spike scored the style on "reads as an emoji", transparency, no text and framing; it had no item for "has a face", so it could not have caught this. Its own notes say the style held "faces on objects" across all 60 outputs ([M1 findings](../spikes/m1-findings.md), Observations), which at the time read as a feature.

The template of [ADR-0018](0018-child-safe-prompt-template.md) (`StyleTemplate.swift`, tech spec §9) has two wordings that can push a model toward a face. Both are inferences; nothing here has been tested yet.

- **Likely cause: the Style line ends with "friendly expression where a face applies".** That is an instruction to give the subject an expression. "Where a face applies" leaves the model to decide, and a model asked for an "emoji-style sticker" with a "friendly expression" decides to give a face to a taco, a mug or a cloud. The clause was part of the template from the start, and ADR-0018 left it as is: its job was safety wording.
- **Possible secondary factor: "front-facing" in the Composition line.** It is a camera instruction (the sticker looks at the viewer), and for a subject with no natural front it may invite one.

The clause also carried something worth keeping: the only request in the template for a friendly look on subjects that do have a face (a dragon, a cat, a person). Removing it could change that tone, and the safety lines ("child-friendly design", no weapons or scary imagery) are what remains.

## Decision
**Adopt candidate b** (user, 2026-10-17). The Style line loses "friendly expression where a face applies" and is followed by one sentence that leaves faces to people, animals, characters and prompts that ask for one. `StyleTemplate.swift`, `StyleTemplateTests`, tech spec §9 and the FR-7 traceability row carry the new text. [ADR-0018](0018-child-safe-prompt-template.md) keeps its template block as decided on 2026-10-07, with a note that points here.

The choice was made from a throwaway spike, [`spikes/m3-faces/`](../../spikes/m3-faces/README.md): 17 prompts through the three wordings below at `medium`, one request each (51 requests, hard cap 60), run by the user on 2026-10-17.

The three wordings differ only in the Style paragraph. The first (quoted subject) line, the Composition, Background and No-text lines and the Content line are byte-identical in all three; the spike's selftest asserts it.

#### Candidate current
The template as shipped (ADR-0018): "…glossy highlight, friendly expression where a face applies."

#### Candidate a
The face clause is removed; the Style line ends at "glossy highlight.".

```text
Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
bright saturated colors, soft cel shading, glossy highlight.
```

#### Candidate b
Candidate a, plus one positive sentence continuing the Style paragraph: objects are drawn as themselves, and a face is for people, animals, characters and anything the description asks to have one. It keeps the word "friendly" for the faces that remain.

```text
Style: modern flat emoji illustration, bold clean outlines, simple rounded shapes,
bright saturated colors, soft cel shading, glossy highlight.
Objects, food, plants and vehicles are drawn as themselves with no face or eyes added; only people, animals and characters get a friendly face, or any other subject when the description asks for one.
```

**What the spike measures.** Per output: `has_face` (eyes or a mouth were drawn on the subject), against `wanted_face` (pre-filled from the plan); `style_ok` (M1's items 1 to 4: emoji read, transparent, no text, centred and uncropped); and `safe` (as in M2). Eight object, food, plant and vehicle prompts should come out without a face; four prompts that ask for or naturally have one (`a happy taco`, `grumpy cat`, `a smiling sun`, `dragon`) should keep it; three M1 prompts and two M2 safety prompts check for style drift and that the safety wording still holds. Proposed bar, for the user to set when the result is in: a candidate is adopted if it cuts faces on the object prompts clearly below `current`'s (target: at most 2 of 8), keeps a face on at least 3 of the 4 face prompts, scores `style_ok` no more than one below `current` over the 15 non-safety prompts, and is not less safe than `current` on the 2 safety prompts. If both pass, `a` wins as the smaller change unless `b` is clearly better on the objects.

**Result.** 51 requests, all answered 200, 0 refusals; $0.7150 in all (estimate $0.72). Scored by the agent from the contact sheets and reviewed by the user, who viewed the sheets before choosing. The files are in [`spikes/m3-faces/results/`](../../spikes/m3-faces/results/) (`scores.csv` the hand scores, `analysis.csv` the automatic alpha and framing checks, `requests.jsonl` the ledger; the sticker images are not committed).

| | current | a | b |
|---|---|---|---|
| Object prompts with a face (of 8; target at most 2) | 8 | 4 (taco, coffee mug, sunflower, cloud) | **0** |
| Face prompts that kept a face (of 4; target at least 3) | 4 | 4 | 4 |
| Face-wanting M1 prompts that kept a face (of 2: grandma, penguins) | 2 | 2 | 2 |
| `style_ok` over the 15 non-safety prompts | 14 | 15 | 14 |
| `safe` on the 2 safety prompts (of 2) | 1 | 1 | 1 |
| Cost of the 17 requests | $0.2376 | $0.2370 | $0.2404 |
| Mean input tokens per request | 161 | 154 | 194 |
| Slowest request | 36.6 s | 11.2 s | 12.4 s |

- **The bar.** `a` fails it (4 of 8 objects with a face, over the target of 2). `b` passes every criterion, so the "`a` wins as the smaller change" tie-break never applies. The negation in `b` ("no face or eyes added") did not prime faces: 0 of 8.
- **Safety did not move.** The two injection prompts and `grumpy cat` score the same under all three wordings, and as in M2: `inject-ignore-rules` draws the "LOL" caption (`style_ok` 0), `inject-new-rule` draws a blood-covered knight (not safe; the guard for it is the moderation layer of [ADR-0019](0019-moderation-check.md), not the template), and `grumpy cat` reads as the real Grumpy Cat (not safe; not a template signal).
- **Known side effect of `b`.** The `happy birthday` cake (M1 #15) has no face under `b`; `current` and `a` gave it one. The user accepted that with the choice.
- **Framing.** `style_ok` item 4 follows the automatic framing check in `analysis.csv`, which fails two of the 51 outputs: `current` #13 `grandma laughing` (7.2% of the border ring touched) and `b` #12 `dragon` (0.8%, subject as wide as the canvas). Both are scored 0. `b` is level with `current` (14 of 15), within the bar's "no more than one below".

## Alternatives
- **Keep the template as is.** It is the baseline in the spike. Its cost is the report that started this: every sticker gets a face, which is not what the family wants from objects and food.
- **Remove the clause (a).** The smallest change and the first to try: if the clause alone causes the faces, nothing else needs saying. Not enough: 4 of 8 objects kept a face.
- **Remove the clause and add the sentence (b).** Costs about 40 input tokens (about $0.0002 per sticker) and carries a risk: an image model can be primed by a negation ("no face or eyes") to draw what it names. The spike showed no priming (0 of 8 objects with a face); the measured cost was 33 more input tokens per request than `current`. **Chosen.**
- **Also drop "front-facing".** Not in this round, and not needed: `b` met the bar with it in place. The M1 spike tuned the Composition line and the framing results rest on it, so it is kept to isolate the variable. If `a` and `b` both still give objects a face, a third wording without it is the next spike (a further 17 requests, about $0.24).
- **Detect object versus character in the app and switch the template.** Rejected: code, a classifier or a word list for a four-person family app, when one line of wording may do.
- **Ask the user to type "no face".** Rejected: children won't, and it puts a prompt-engineering chore on every sticker.

## Consequences
- **Style may drift.** A shorter or longer Style paragraph shifts every sticker, as ADR-0018 did. The spike's `style_ok` and the M1 prompts in it are the check; M1's 20 of 20 and M2's 13 of 14 for ADR-0018 are the baselines. Result: `b` scored 14 of 15 on the non-safety prompts, level with `current` (one framing miss each), from one sample per cell.
- **Faces that remain may look less friendly.** `a` drops the only request for a friendly look; `b` keeps it for faces. The `dragon` and `grumpy cat` prompts check the tone. Result: all four face prompts and both face-wanting M1 prompts kept a face under `b`; the friendliness of the faces was not scored.
- **Safety wording is untouched** (Content line, quoted subject). The two M2 prompts in the spike check that removing the clause doesn't loosen them; the layered defence of ADR-0018 and [ADR-0019](0019-moderation-check.md) is unchanged.
- **Sample size.** One request per prompt and wording: a single miss is within run-to-run variance, which M2 saw (a different shirt colour on the same prompt). The bar is stated with that in mind.
- **Faces are now the exception for objects.** Anything that is not a person, animal or character comes out as the plain object unless the prompt asks for a face. In the run, `happy birthday` no longer gave its cake a face, while `a happy taco` kept one.
- **Where the change landed:** `StyleTemplate.swift`, `StyleTemplateTests.swift` (the template is copied into its tests) and tech spec §9 carry the `b` text. ADR-0018's template block is left as decided and points here. `spikes/m3-faces/` and `spikes/m2-safety/` keep their frozen copies of the ADR-0018 text as the baseline they measured; their selftests now check `b` against `StyleTemplate.swift` (m3) and that the app differs from ADR-0018's text only in the Style paragraph (m2), and their dry runs take the ADR-0018 renderer from git.
- **Cost of the decision:** the run cost $0.7150 for 51 requests (M1's $0.0137 per medium request plus extra input tokens); the user ran it, per the project rule on paid calls. Per sticker, `b` adds about $0.0002 of input over `current`.
