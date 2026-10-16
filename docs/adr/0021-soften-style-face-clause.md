# ADR-0021: Soften the style template's face clause so objects don't all get a face

- **Status:** Proposed
- **Date:** 2026-10-15

## Context
The user's daughter, a family tester on TestFlight build 86, reported that every sticker comes out with eyes and a face, plain objects and food included (bead `openmoji-6dr.9`). The M1 spike scored the style on "reads as an emoji", transparency, no text and framing; it had no item for "has a face", so it could not have caught this. Its own notes say the style held "faces on objects" across all 60 outputs ([M1 findings](../spikes/m1-findings.md), Observations), which at the time read as a feature.

The template of [ADR-0018](0018-child-safe-prompt-template.md) (`StyleTemplate.swift`, tech spec §9) has two wordings that can push a model toward a face. Both are inferences; nothing here has been tested yet.

- **Likely cause: the Style line ends with "friendly expression where a face applies".** That is an instruction to give the subject an expression. "Where a face applies" leaves the model to decide, and a model asked for an "emoji-style sticker" with a "friendly expression" decides to give a face to a taco, a mug or a cloud. The clause was part of the template from the start, and ADR-0018 left it as is: its job was safety wording.
- **Possible secondary factor: "front-facing" in the Composition line.** It is a camera instruction (the sticker looks at the viewer), and for a subject with no natural front it may invite one.

The clause also carried something worth keeping: the only request in the template for a friendly look on subjects that do have a face (a dragon, a cat, a person). Removing it could change that tone, and the safety lines ("child-friendly design", no weapons or scary imagery) are what remains.

## Decision
**Pending the paid run.** Nothing in `StyleTemplate.swift` changes in this ADR's first PR. The choice is made from a throwaway spike, [`spikes/m3-faces/`](../../spikes/m3-faces/README.md): 17 prompts through the three wordings below at `medium`, one request each (51 requests, about $0.72, hard cap 60 requests, worst case about $0.85). Section "Result" is filled in after the run, and the template, tech spec §9 and `StyleTemplateTests` follow in a separate change.

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

**Result.** Pending the paid run. To be filled in: faces on the 8 object prompts and the 4 face prompts per wording, `style_ok` and `safe` counts, the chosen wording, and the cost of the run.

## Alternatives
- **Keep the template as is.** It is the baseline in the spike. Its cost is the report that started this: every sticker gets a face, which is not what the family wants from objects and food.
- **Remove the clause (a).** The smallest change and the first to try: if the clause alone causes the faces, nothing else needs saying.
- **Remove the clause and add the sentence (b).** Costs about 40 input tokens (about $0.0002 per sticker) and carries a risk: an image model can be primed by a negation ("no face or eyes") to draw what it names. The spike will show it; if it happens, a version worded only in the positive is the next try.
- **Also drop "front-facing".** Not in this round. The M1 spike tuned the Composition line and the framing results rest on it, so it is kept to isolate the variable. If `a` and `b` both still give objects a face, a third wording without it is the next spike (a further 17 requests, about $0.24).
- **Detect object versus character in the app and switch the template.** Rejected: code, a classifier or a word list for a four-person family app, when one line of wording may do.
- **Ask the user to type "no face".** Rejected: children won't, and it puts a prompt-engineering chore on every sticker.

## Consequences
- **Style may drift.** A shorter or longer Style paragraph shifts every sticker, as ADR-0018 did. The spike's `style_ok` and the M1 prompts in it are the check; M1's 20 of 20 and M2's 13 of 14 for ADR-0018 are the baselines.
- **Faces that remain may look less friendly.** `a` drops the only request for a friendly look; `b` keeps it for faces. The `dragon` and `grumpy cat` prompts check the tone.
- **Safety wording is untouched** (Content line, quoted subject). The two M2 prompts in the spike check that removing the clause doesn't loosen them; the layered defence of ADR-0018 and [ADR-0019](0019-moderation-check.md) is unchanged.
- **Sample size.** One request per prompt and wording: a single miss is within run-to-run variance, which M2 saw (a different shirt colour on the same prompt). The bar is stated with that in mind.
- **When a wording is chosen:** `StyleTemplate.swift`, `StyleTemplateTests.swift` (the template is copied into its tests), tech spec §9 and ADR-0018's template block are updated together, and this ADR's status moves to Accepted only on the user's go-ahead. `spikes/m3-faces/` and `spikes/m2-safety/` both compare against `StyleTemplate.swift`, so their selftests need the new text or are retired.
- **Cost of the decision:** the run is about $0.72 for 51 requests at M1's $0.0137 per medium request plus extra input tokens; the user runs it, per the project rule on paid calls.
