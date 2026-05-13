# Orchestration Contract

Defines the message shape and protocol between Chuvak, Temo, Watcher, and the epic subagents. Every cross-agent invocation conforms to this contract — no ad-hoc message shapes, no implicit state.

## Invocation primitives

All agent-to-agent calls happen through:

- the **`Agent` tool** (Claude Code) for spawning a subagent with a fresh context, OR
- **ticket writes** (Supabase REST + RPC) for asynchronous delegation.

There is no third channel. No HTTP, no message bus, no agent-to-agent direct call.

## Message shapes

Every message exchanged between agents is one of these structured shapes. Strings are quoted; numbers and booleans are bare; unknown fields are forbidden (extensions go in `metadata`).

### `Task brief` — Chuvak → Temo (sync chain)

```json
{
  "kind": "task_brief",
  "ticket_id": 1234,
  "summary": "<one-line>",
  "acceptance": "<concrete criteria>",
  "approval_status": "approved | not_needed | pending",
  "approver_signal": "<comment id, when approved>",
  "dependencies": [<ticket_id>, ...],
  "depth": 0,
  "max_depth": 3
}
```

Temo refuses the brief if:
- `approval_status` is `pending`. Approval-gated work doesn't get dispatched.
- `dependencies` contains any non-done ticket — return `{status: 'blocked', depends_on: [...]}`.
- `depth >= max_depth` — return `{status: 'depth_exceeded', escalate: true}`.

### `Dispatch` — Temo → Epic agent

```json
{
  "kind": "dispatch",
  "ticket_id": 1234,
  "agent_key": "<key>",
  "scope_paths": ["..."],
  "prior_context": {
    "comments": [...],
    "activity": [...],
    "similar_resolved": [{"ticket_id": N, "score": 0.0-1.0, "fix": "..."}],
    "design_brief": "..." | null,
    "qa_failure_note": "..." | null
  },
  "qa_required": true | false
}
```

Epic agents claim the dispatched ticket atomically (see `EPIC_AGENT_CONTRACT.md § Step 4`). On race-loss the epic returns `already_claimed`; Temo moves on.

### `Epic result` — Epic agent → Temo

```json
{
  "kind": "epic_result",
  "ticket_id": 1234,
  "status": "shipped | shipped_to_qa | wrong_scope | blocked_external | blocked_internal | asked_user | failed",
  "commit_sha": "<sha>" | null,
  "resolution": { ... } | null,           // populated on shipped/shipped_to_qa
  "suggested_agent": "<key>" | null,       // populated on wrong_scope
  "reasoning": "<why>",                    // populated on wrong_scope, blocked_*, failed
  "need": "<what is needed>" | null,       // populated on blocked_external
  "file_hint": "<path>" | null,            // populated on blocked_external
  "decision_ticket_id": <id> | null,       // populated on asked_user
  "depends_on": <id> | null                // populated on blocked_internal
}
```

### `Chain result` — Temo → Chuvak

```json
{
  "kind": "chain_result",
  "root_ticket_id": 1234,
  "status": "shipped | chained | asked_user | blocked | ambiguous_direction | failed",
  "agent": "<final agent that shipped>" | null,
  "commit_sha": "<sha>" | null,
  "chain": [{"ticket_id": N, "agent": "...", "status": "..."}, ...],
  "ask_user_ticket_id": <id> | null,
  "ambiguous_options": [...] | null
}
```

### `Observation` — Watcher → Chuvak (via ticket)

Posted as a `type='observation'` ticket with `labels=['OBSERVATION']`:

```json
{
  "title": "<short signal>",
  "body": "<evidence + analysis + suggested directions>",
  "metadata": {
    "kind": "observation",
    "signal": "error_spike | latency_regression | abandoned_flow | conversion_drop | usage_anomaly | other",
    "evidence": {
      "timeframe": "...",
      "metric": "...",
      "before": ...,
      "after": ...,
      "samples": [...]
    },
    "severity": "low | medium | high | critical",
    "suggested_directions": [
      {"option": "<short>", "effort": "small|medium|large", "files_hint": "..."}
    ],
    "recommended_approver": "<email>" | null
  }
}
```

Chuvak reads observation tickets on tick; decides one of: ignore (PATCH `state='done'` with `metadata.disposition='ignored'`), file follow-up task (POST new `type='task'`, link as child), or escalate to human (file `ASK-USER` decision).

### `Ask-user decision` — any agent → human

Posted as a `type='decision'` ticket with `labels=['ASK-USER']`:

```json
{
  "title": "<question>",
  "body": "<why we need a human, ranked options, what we recommend>",
  "assignee_email": "{{TENANT_OWNER_EMAIL}}",
  "parent_ticket_id": <original> | null,
  "metadata": {
    "kind": "ask_user",
    "category": "approval | direction | clarification | observation_action",
    "asked_by": "<agent name>",
    "options": [
      {"label": "...", "pros": "...", "cons": "...", "effort": "..."}
    ],
    "recommended_option": <index> | null
  }
}
```

The decision ticket resolves when the approver comments on it. Most-recent comment from `assignee_email` is authoritative. Chuvak resumes the original ticket once the decision is recorded.

## Boundaries

A boundary is a hard line one agent must not cross. Listed by agent:

### Simone

- MAY: chat, draft tickets, hand off to a tenant's Chuvak via tenant-scoped API.
- MAY NOT: edit code, spawn epic subagents, route tickets, hold cross-tenant data in context, write to a tenant's tables with another tenant's identity.

### Chuvak

- MAY: decide, delegate, file `ASK-USER`, patch ticket state, read observations, comment on tickets to record decisions.
- MAY NOT: edit code, bypass approval gates, call epic subagents directly (must go through Temo), invoke another tenant's Chuvak.

### Temo

- MAY: classify, route, dispatch, dedup, file dependency rows, handle ambiguous-direction by returning to Chuvak.
- MAY NOT: decide approval, edit code, modify `SCOPE_MAP.md`, file `ASK-USER` for anything other than `ambiguous-direction`.

### Watcher

- MAY: read telemetry, query workspace data, post observation tickets.
- MAY NOT: file work tickets, edit code, write to `agent_presence` for anything but its own row, query other tenants.

### Epic agents

- MAY: edit files in declared scope, run tests, commit, push, return `wrong-scope`, `blocked-external`, `blocked-internal`, `asked-user`.
- MAY NOT: file new tickets except via Temo's dependency-create path (for `blocked-external`), edit `.claude/agents/*.md`, deploy to production without explicit per-deploy approval comment, edit files outside scope.

## Recursion and depth limits

Sync chains are bounded at depth 3 by default (Chuvak -> Temo -> Epic -> blocked-external -> Temo -> next Epic -> done). Past depth 3, Temo returns `depth_exceeded` and Chuvak files an `ASK-USER` asking the operator to split the ticket. This prevents pathological dependency chains from running unboundedly.

Autonomous mode is naturally bounded by tick interval — each tick processes one queue item per agent.

## Idempotency and dedup

All ticket-creating operations are idempotent on `(type, scope, normalized_title)`. Concretely:

- Before POSTing a new ticket, search for non-done tickets with same `type`, 80%+ title overlap (4+ significant words), and same `assignee_email` target.
- On match: PATCH the existing ticket's body with a `## Additional context (from <source>, <timestamp>)` block; log activity `kind='deduped'`; do not create.
- On no match: POST normally.

Exception: cross-tenant coordinator tickets and resolution tickets never dedup (each is intrinsically unique).

## Time and timezones

All timestamps are ISO 8601 UTC with milliseconds. `now()` in pseudo-code means `date -u +%Y-%m-%dT%H:%M:%S.000Z`. Tickets surface to humans in their local timezone via the UI; agents never compute local time.

## Error reporting

Any agent failing to complete its dispatch returns `status='failed'` with `reasoning` describing the failure. Chuvak decides whether to retry (transient, retry once), reroute (suggest a different agent), or escalate (`ASK-USER`). Agents do not silently re-attempt the same ticket — every retry is a fresh dispatch with explicit context.
