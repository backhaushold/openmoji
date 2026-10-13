# ADR-0020: Keep the parental prompt log in the app, append-only, shown in Settings

- **Status:** Accepted (user, 2026-10-13)
- **Date:** 2026-10-13

## Context
The users include children under 13. The user asked that every generation prompt, including regenerated and discarded ones, is logged with a timestamp so a parent can review it (bead `openmoji-6dr.4`). Until now only a kept sticker retained its prompt. OQ-16 (bead `openmoji-vqr`) asked where that log lives: in the app, on OpenAI's side, or both. The PRD allows no backend of our own, so "server-side" could only mean what OpenAI keeps.

The user first preferred OpenAI's side "if feasible". Facts checked against the official docs on 2026-10-13 (developers.openai.com; platform.openai.com returns 403):

| Fact | Source |
|---|---|
| `/v1/images/generations` (our endpoint, ADR-0002): abuse-monitoring retention 30 days, application state "None" | [Data controls](https://developers.openai.com/api/docs/guides/your-data) |
| `/v1/moderations` (ADR-0019): "None" for both | [Data controls](https://developers.openai.com/api/docs/guides/your-data) |
| Abuse-monitoring logs "may contain certain customer content, such as prompts and responses"; the page describes no way for a customer to read them | [Data controls](https://developers.openai.com/api/docs/guides/your-data) |
| "Responses are stored by default"; the Responses API has "a 30 day Application State retention period by default" | [Migrate to the Responses API](https://developers.openai.com/api/docs/guides/migrate-to-responses), [Data controls](https://developers.openai.com/api/docs/guides/your-data) |
| With the Responses API image-generation tool, "the mainline model ... will automatically revise your prompt"; the page names no moderation parameter | [Image generation tool](https://developers.openai.com/api/docs/guides/tools-image-generation) |

So the calls the app makes leave nothing on OpenAI's side that a parent can open. Not verified: whether the dashboard's Logs page shows a stored Responses request's input text, and who in the organisation may open it (only forum posts were found; they say Images API calls show usage counts only).

## Decision
**The log lives in the app only** (user, 2026-10-13). No OpenAI-side or server-side logging.

- **What is recorded:** the prompt as typed and the time, one entry per generation request: Generate, Regenerate and Try again alike. Nothing else: no outcome, no image, never the API key (NFR-6).
- **When:** in `AppModel.generate()`, before the generator is called. The prompt is therefore on record whether the sticker is kept, regenerated, discarded, refused by moderation, failed or cancelled, and also if Messages tears the extension down mid-generation.
- **Where:** `PromptLog` (OpenMojiCore) writes `<App Group container>/Library/Application Support/PromptLog/prompts.jsonl`, one JSON object per line (`{"at": ISO 8601, "prompt": ...}`), oldest first.
- **Append-only:** a record is added at the end of the file. Nothing in the app rewrites, trims or deletes it, and there is no clear button. A line that doesn't decode (a write cut short) is skipped when reading.
- **Where it is read:** Settings › **Audit log**, a read-only list, newest first, each prompt with its date and time. The link is there with or without a key.

Defaults the user did not choose otherwise, to change if wanted:

- **No pruning.** Entries are kept for as long as the app's data exists. At 200 characters a prompt the file stays small (10,000 prompts is about 2.5 MB).
- **No parent gate.** Anyone who can open Settings on that iPad can read the log, a child included. Being append-only, reading it changes nothing.
- **A failed log write does not stop the generation.** It is logged with `OSLog` and the sticker is made. The same disk fault would also fail Keep.

## Alternatives
- **OpenAI's side, by moving generation to the Responses API image-generation tool.** Declined by the user. It replaces ADR-0002, puts a prompt-rewriting text model between the ADR-0018 template and the image model (the M2 safety results would need re-running), adds tokens and a model hop per sticker, keeps the record for only 30 days by default, and its dashboard visibility was not verified.
- **Both.** Declined with the above.
- **Rely on OpenAI's abuse-monitoring logs.** Not possible: a customer cannot read them.
- **Record the outcome too (kept, discarded, refused).** Not now: the request asks for prompts and times. A refused prompt is in the log like any other; marking it would be a later addition of a field, which old lines would simply lack.
- **Write the entry when the generation ends.** Rejected: a generation lost to a teardown would leave no record.
- **Keep it in `index.json` with the stickers.** Rejected: that file is rewritten on every Keep and Delete, which is the opposite of append-only.

## Consequences
- **Per device.** Each iPad has its own log, read on that iPad. There is no combined view and no export.
- **Lost with the app's data.** The App Group container goes when the app and its extension are deleted, and the log with it. (The Keychain key survives a reinstall; the log does not.)
- **Children's prompts stay on the device** beyond what was already sent to OpenAI for moderation and generation. No new party, no SDK (NFR-7); the privacy manifest is unchanged (the data is not collected off the device, and no required-reason API is used).
- **No FR covers this.** Like library search, it comes from its bead; the PRD is not changed.
- **Tests:** `PromptLogTests` (order, append-only bytes, newlines in a prompt, an undecodable line, the container path) and `AuditLogModelTests` (recorded before the generation finishes; regenerate, discard, refusal and cancel all on record; a failed write doesn't block; newest first).
