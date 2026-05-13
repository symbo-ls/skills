# Coding Guidelines

Behavioral guidelines for any execution-capable agent (epic agents, QA when fixing, Temo when patching scope maps). Derived from common-failure observations across LLM coding agents. Bias toward caution over speed; for trivial tasks, judgment applies.

## 1. Think before coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:
- State your assumptions explicitly. If uncertain, ask via `ASK-USER`.
- If multiple interpretations exist, present them — don't pick silently. The orchestration contract requires this for ambiguous-direction.
- If a simpler approach exists, say so. Push back via a comment on the ticket when a simpler fix matches the acceptance criteria.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity first

Minimum code that solves the problem. Nothing speculative.

- No features beyond what the ticket asks for.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical changes

Touch only what you must. Clean up only your own mess.

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it via a follow-up ticket — don't delete it inline.

When your changes create orphans:
- Remove imports / variables / functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless explicitly asked.

The test: every changed line should trace directly to the ticket's acceptance criteria.

## 4. Goal-driven execution

Define success. Loop until verified.

Transform tasks into verifiable goals:
- "Add validation" -> "Write tests for invalid inputs, then make them pass."
- "Fix the bug" -> "Write a test that reproduces it, then make it pass."
- "Refactor X" -> "Ensure tests pass before and after."

For multi-step tasks, state a brief plan:

```
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
3. [Step] -> verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. No hacks, no workarounds

If something doesn't work, diagnose the root cause. Do not patch around it.

- If a bug is in the framework, fix it at the framework level — file the upstream ticket and surface the dependency.
- If a pattern is missing from the design system, add it to the design system — don't hardcode values.
- If a component needs a capability that doesn't exist, extend the framework correctly — don't special-case it inline.
- If a rule conflicts with what you need, surface the conflict and resolve it properly — don't silently violate the rule.

Never:
- Use `!important` or selector hacks to force visual output.
- Wrap a broken component in a div to hide its broken behavior.
- Copy-paste duplicated logic instead of fixing the abstraction.
- Disable a failing test instead of fixing what it tests.

## 6. Tests before shipping

Every change must be verified before the ticket is considered complete:

1. Run relevant unit + integration tests.
2. If a UI/UX change, smoke-test the change visually.
3. Check for new console errors / warnings introduced by the change.
4. Framework-level changes: run the full test suite.
5. Schema migrations: verify both up and down (rollback) on a scratch database before marking done.

Do not mark a task done if you haven't verified it works end-to-end. If you can't test (no env access, missing fixture data), say so explicitly in the resolution rather than claiming success.

## 7. Avoid backwards-compat hacks unless required

If the ticket is removing an obsolete code path, remove it fully — don't leave it commented out, don't rename variables with leading underscore. Backwards-compat shims should be added only when the ticket explicitly requires it (e.g., "30-day deprecation window").

## 8. Use the right resource — Symbols 3-tier reuse

Before writing new code, walk the 3 tiers and reuse:

1. **Framework built-ins** — `@symbo.ls/default-config` provides Avatar, Button, Card, Dialog, Dropdown, Link, Notification, Range, Select, Tooltip, Icon, Input plus atoms (Block, Box, Flex, Grid, Hgroup, Img, Text, Form, Svg, Theme, …). Reference by bare key; never redefine.
2. **Shared libraries** — listed in `sharedLibraries.js` at the project root. Read-only from a consumer ticket; override via local file (`components/<Name>.js` with `extends: '<Name>'`).
3. **Current project** — `components/`, `snippets/`, `functions/`, `methods/`.

A capability already in any tier covers ~80% of the need? Use the bare key + override differing props. Don't redefine.

Three near-duplicates of the same logic locally? Stop and extract to `components/<Name>.js` or `functions/<name>.js`. Replace duplicates with bare-key references or `el.call('name', ...)`. NEVER import between project files.

Two pages compute the same thing? Extract to `functions/<name>.js`, invoke via `el.call`. Project files do not sibling-import.

See `PLATFORM_BINDING.md § Reuse` for the full mechanic.

## 9. Commit hygiene

- One logical change per commit.
- Clear commit messages: imperative mood, what + why in one line, body if needed.
- Reference the ticket id at the end (`refs #1234`).
- Never amend a pushed commit.
- Never `--no-verify` unless explicitly approved (hook failures usually mean a real problem).

## 10. Communicate clearly in resolutions

The `resolution` JSONB you write on ship is what future agents (and humans) will read to understand your work. Include:

- `summary` — one sentence: what you fixed.
- `root_cause` — why it was broken (or what was missing).
- `fix` — what you did, concretely.
- `files_touched` — array of paths.
- `tests_added` — array of test names / locations.
- `prevention` — what stops this from regressing (test? lint? policy?).
- `commit_sha` — the head SHA after your commit.

Be specific. "Fixed the bug" is useless to the next agent reading `find_similar_resolved` output six months from now.
