# ADR-0012: Secret scanning with gitleaks in CI and the release lane

- **Status:** Proposed
- **Date:** 2026-10-02

## Context
REL-6: fail the pipeline if any secret, including an OpenAI key, is found in the source tree. The acceptance criteria also require that build artifacts contain no API key. Sagelet has no scanning. GitHub secret scanning and push protection are free on public repos, but they don't run inside the release lane.

## Decision
- Run `gitleaks detect --redact` (default rules include OpenAI `sk-` keys) as the first CI step and as release-lane step 2, over the working tree and git history.
- Add a `.gitleaks.toml` only if false positives appear, such as the test sentinel key.
- Also enable GitHub secret scanning and push protection on the repo, as defence in depth.
- The release lane additionally greps the built `.xcarchive` for `sk-` between archive and upload.

## Alternatives
- **GitHub push protection alone.** It blocks pushes but isn't a pipeline gate the lane can check.
- **trufflehog.** Comparable; gitleaks is a single static binary via Homebrew with simpler config.

## Consequences
- One extra Homebrew tool locally and one Action in CI.
- Test fixtures must use a sentinel that doesn't match the OpenAI key pattern, or be allowlisted explicitly.
