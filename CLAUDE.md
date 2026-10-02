# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Agent profile

This repo opts into **Team-maintainer**: agents may commit, push, open PRs and
squash-merge on green CI as part of landing requested work (feature branch + PR,
never direct to `main`). A current "don't commit/push" from the user still wins.

## Project

OpenMoji: an iPad-only iMessage app extension that turns a text prompt into an
emoji-style sticker via the OpenAI Images API. Family use, TestFlight internal
testers only, no backend. Pre-code: spec phase (M2) is done; M3 scaffolds the
app and release lane.

- PRD (scope source of truth; locked decisions D1–D10, FR/NFR/REL IDs):
  https://claude.ai/code/artifact/4eb3c358-d044-4b4f-a48b-2aca31cd3bbe (a Claude Doc — read via the Docs connector)
- Tech spec: `docs/tech-spec.md` · ADRs: `docs/adr/` · open questions: `docs/open-questions.md`

## Rules

- Don't reopen a locked PRD decision (D1–D10) or change a FR/NFR/REL without flagging it to the user.
- Any new significant technical decision gets an ADR in `docs/adr/` (next number, add to its README index).
- Releases publish **only from the local release Mac** (`make testflight`, secrets from 1Password).
  CI verifies and alerts but never signs or uploads. **No GitHub Actions secrets**; workflows use only `GITHUB_TOKEN`.
- No third-party SDKs or package dependencies (NFR-7); OpenAI calls go through our own `URLSession` client.
- The OpenAI API key lives only in the Keychain: never log it, put it in errors, or commit it.
- Verify OpenAI/Apple API details against official docs, not memory — the PRD already had stale model facts.

## Build & Test

_Not yet — added in M3 when `project.yml`, `Packages/OpenMojiCore` and the release lane exist (tech spec §3, §11, §12)._
