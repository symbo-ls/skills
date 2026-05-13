# Architecture

The agent system is a directed graph with one platform-level node (Simone), one per-tenant orchestrator (Chuvak), and two named children under each Chuvak (Temo, Watcher), with Temo fanning out to epic subagents cloned from a single template.

This document defines the role contracts, the communication channels, and the boundaries that must not be crossed.

## The five roles

### Simone — global, conversational, cross-tenant

Lives at the Symbols platform level. One Simone serves every tenant. She is the conversational surface for the platform.

Owns:
- Talking to users (chat, drafting, advisory).
- Awareness of cross-tenant patterns — anonymized telemetry only; never leaks tenant data into another tenant.
- Drafting task specs from natural-language asks and handing them off to the target tenant's Chuvak.
- Surfacing decisions back to the user when Chuvak escalates with an `ASK-USER` ticket.

Forbidden:
- Editing tenant code directly.
- Spawning epic subagents.
- Routing tickets (that's Temo's job, and Temo reports to Chuvak).
- Holding tenant state in her own context across conversations — every chat is a fresh request scoped through the tenant API.

### Chuvak — per-tenant operational orchestrator (the brain)

One Chuvak per workspace. The tenant's only top-level autonomous agent. Receives task specs from Simone, observations from Watcher, and direct asks from authenticated tenant users. Decides what to do; delegates execution to Temo.

Owns:
- The decision boundary. Every "should we do X?" question terminates here unless escalated to a human.
- Approval gates. When a task touches an approval-mandatory category (see `contracts/APPROVAL_GATES.md`), Chuvak halts execution and files an `ASK-USER` decision ticket before any further work.
- Integrating inputs: Simone (user asks), Watcher (analytics), epic-agent self-reports (status), human comments (approvals + redirects).
- Delegation to Temo. Hands Temo a fully-specified task with acceptance criteria and scope. Never hands Temo something vague.
- Owning the tenant's `SCOPE_MAP.md` and approval-gate config.

Forbidden:
- Editing code. Chuvak decides; Temo and epic agents execute.
- Approving work in approval-mandatory categories without an explicit human signal — even if Chuvak is confident.
- Bypassing Temo to call an epic agent directly (this would skip routing dedup, dependency checking, and queue ordering).

### Temo — PM, router, dispatcher

Sits under Chuvak. The execution-layer orchestrator. Receives a fully-specified task from Chuvak (sync chain) or wakes up on a queue tick (autonomous mode) and routes the task to the right epic subagent.

Owns:
- Classification of incoming work against `SCOPE_MAP.md`.
- Dedup. Before creating any new ticket, search for similar open tickets; merge if the match score crosses threshold.
- Dispatch. Spawn the target epic subagent with a complete brief (ticket id, scope, dependencies, prior context).
- Dependency chains. If an epic returns `blocked-external`, file a downstream ticket and link it via `ticket_dependencies`, then re-tick the original once unblocked.
- QA gate. If the original work has a `needs-qa` label, the epic agent ships to `ready_to_test` instead of `done`, and Temo hands off to the QA subagent.
- Returning a structured result to Chuvak: `{status, ticket_id, commit_sha | chain_result | ask_user}`.

Forbidden:
- Deciding scope. If classification is ambiguous (two or more plausible directions), return `ambiguous-direction` to Chuvak; do not guess.
- Editing code.
- Approving anything. Approval is Chuvak's job; ambiguous-direction is the only thing Temo signals.
- Spawning Chuvak (Chuvak is the parent; the arrow is one-way).

### Watcher — analytics, observation

Sits under Chuvak as a sibling to Temo. Reads telemetry, application state, and event streams; produces structured analyses; posts them as `type='observation'` tickets for Chuvak to read.

Owns:
- Periodic scans of tenant telemetry (errors, latency, usage flows, abandoned features, feature-flag rollout health).
- Pattern detection. Three+ occurrences of the same error in 24h ⇒ observation. Sustained latency regression ⇒ observation. Drop in a key conversion ⇒ observation.
- Producing observation tickets with: signal, evidence, suggested-direction (one or more), severity, recommended approver.
- Watching its own signal-to-noise ratio. If Chuvak rejects 5 of Watcher's last 10 observations, Watcher should ratchet thresholds higher.

Forbidden:
- Filing work tickets directly. Watcher posts observations only. Chuvak decides whether an observation becomes work, and routes that decision through Temo.
- Editing code.
- Cross-tenant queries (Watcher is workspace-scoped; cross-tenant pattern detection is Simone's job at the platform level).

### Cross-epic helpers — UX, UI Design, QA

Three named helpers sit under Temo as siblings to the epic agents. Unlike epic agents, they do NOT own a domain scope as their primary identity — they pair with epic agents on tickets whose subject crosses their concern.

- **UX** — flows, accessibility, copy, interaction patterns. Pairs in Mode B (writes a `ux_brief` before the epic implements). Reviews in Mode C (alongside QA on `ready_to_test`).
- **UI Design** — design tokens, brand kit, visual craft, motion, theming. Pairs in Mode B (`ui_design_brief`). Reviews in Mode C. ALSO ships primary when the ticket is in the design-system scope.
- **QA** — functional validation. Reviews in Mode C. Runs Mode B periodic smoke independently.

All three are read-mostly on a typical epic ticket: they advise via briefs and review on ship, but they don't edit the epic's code. When the ticket is in their own scope (UX framework docs, design tokens, QA fixtures), they ship primary like any epic.

Multiple helpers can pair on the same ticket in parallel — Temo invokes them simultaneously, waits for all briefs, then dispatches the epic. The epic reads every brief during context-read.

### Epic subagents — execution

Cloned from one template (`agents/epic-agent.template.md`). Each one owns a specific scope (`server/**`, `content/**`, etc.). Receives a single ticket from Temo, claims it atomically, ships, and reports back.

Owns:
- Implementing the work in its declared scope.
- Self-correcting wrong-scope routings (returns `wrong-scope` with a suggested correct agent).
- Heartbeating during long work.
- Atomic claim and atomic ship via the contract RPCs.
- Producing a structured `resolution` JSONB on ship.

Forbidden:
- Editing files outside its declared scope. Same-repo cross-scope is allowed only when the original ticket explicitly spans multiple scopes and Chuvak preauthorized.
- Skipping the heartbeat. Watchdog audits flag silent agents as dead.
- Re-deriving fixes that already shipped on similar tickets — the contract requires checking `find_similar_resolved` first.

## Communication channels

All inter-agent communication is mediated through the workspace database; agents do not call each other over RPC directly except via the explicit `Agent`-tool subagent invocation. This makes every interaction observable, replayable, and auditable.

### Tickets

The primary unit of work. Every directive between Chuvak, Temo, epic agents, and humans is a ticket.

Types:
- `task` — discrete work item.
- `bug` — broken behavior to fix.
- `decision` — a question that needs a human answer (`labels=['ASK-USER']`).
- `observation` — Watcher signal (`labels=['OBSERVATION']`).
- `resolution` — companion ticket created on ship, parent points to the work ticket.

States:
- `not_started` — backlog.
- `in_progress` — claimed by an agent.
- `awaiting_approval` — approval-gate halted execution; needs a human comment.
- `blocked` — has an unresolved `ticket_dependencies` row.
- `ready_to_test` — epic agent shipped; QA gate fires.
- `done` — resolved.

### Comments

Async clarifications. Humans use comments to approve, redirect, or refine. Agents read the latest comment on every wake — most recent human comment is authoritative.

### Activity log

Append-only audit history. Every claim, ship, block, ask, route, dedup, heartbeat writes a row. Used by watchdog audits and by `find_similar_resolved` to surface prior fixes.

### Presence

Heartbeat table. Every agent upserts on boot and every 2 minutes during long work. Stale presence (no heartbeat for >5 minutes while a ticket is in progress) is a watchdog signal for a hung agent.

## Execution modes

Two modes, well-defined:

### Sync chain

```
Human
  -> Simone (chats, drafts task spec)
       -> Chuvak (decides; approval-gate check)
            -> Temo (route + dispatch)
                 -> Epic agent (ship)
            <- Temo returns {agent, status, commit_sha}
       <- Chuvak returns {result, surfaces to Simone if user is waiting}
  <- Simone summarizes for the user
```

Used when the user is waiting for a response in a conversation. The chain is depth-limited (default 3) to prevent runaway recursion; if Temo encounters a `blocked-external` that would require a 4th level, it escalates to `ASK-USER` instead.

### Autonomous loop

Every agent except Simone runs an autonomous tick when there's no in-flight chain. Chuvak ticks every N minutes (per `agents.config.yaml`), reads its tenant's open tickets + Watcher observations + new comments, decides, and dispatches Temo if work is needed. Temo ticks every N minutes, reads the queue, dispatches.

The two modes coexist: a user chat can interrupt and seed work mid-tick; autonomous work fires when no one is asking.

## Identity model

Every agent has its own service-account identity, separate from any human user. Identities are referenced by `assignee_email` (`temo-agent@<tenant>.example.com`, `qa-agent@<tenant>.example.com`, etc.) and own service-role credentials for Supabase. Cross-tenant identities are forbidden — Simone has tenant-routing credentials but never holds a tenant's service-role key in her context.

## Approval gates (summary; see APPROVAL_GATES.md)

Categories that ALWAYS require a human approval comment before Chuvak proceeds:

- Production deploys (any prod-environment write).
- Schema migrations on prod data.
- Billing / pricing / commercial-terms changes.
- Permission / auth / security changes that broaden access.
- New external integrations or partner data flows.
- Destructive operations (DROP, mass-delete, force-push to main).
- Anything labeled `important`, `critical`, `mission-critical`, `P0` originating outside the tenant owner.

When Chuvak sees a candidate task in any of these categories, it sets `state='awaiting_approval'` and files an `ASK-USER` decision ticket. Execution does not resume until the approver comments with explicit approval (the exact phrasing requirement is configurable; default is: a comment from the configured approver email containing `approved`, `ship it`, `proceed`, or a direct yes to the question text).

## Dedup and similarity

Two layers:

1. **Pre-create dedup.** Before any agent creates a new ticket, search for open tickets with the same `type`, similar title (4+ significant-word overlap), and same scope. On match, append context to the existing ticket and log a `deduped` activity. Saves the queue from filling with duplicates of the same bug filed by different signals (QA smoke, Watcher, user report).

2. **Similar-resolved lookup.** Before an epic agent implements, it calls `find_similar_resolved(title, body, file_hint)` and reads the prior fixes scoring >= 0.5. Scores >= 0.8 typically indicate the same fix should apply — the agent applies the pattern and comments the inheritance.

## Self-correction (epic-agent level)

Routing isn't perfect. Every epic agent, before claiming a ticket, validates the ticket against its own scope. If the ticket title says "fix integration icons on dashboard" and the agent realizes the broken thing is integration metadata (not the dashboard render), it returns `wrong-scope` with a suggested re-route and a one-sentence reasoning. Temo re-routes. The watchdog tracks routing accuracy per pattern; sustained sub-0.7 accuracy escalates the pattern to Chuvak for re-classification.

## Platform binding (Symbols-stack constraint)

This architecture is platform-aware. Every execution-capable agent (epic agents + UX + UI Design + QA-when-editing-fixtures) operates inside the Symbols framework constraints:

- **DOMQL v3.14 syntax** — flat props (`el.X`), flat handlers (`onClick`), flat HTML attrs, key-based auto-extend.
- **Frankability rules** — FA001-FA5xx; pre-commit audit blocks non-compliant code.
- **3-tier reuse model** — framework built-ins (`@symbo.ls/default-config`) → shared libraries (`sharedLibraries.js`) → project. Bare-key resolver walks all three; bare-key reference IS the reuse pattern.
- **Design-system tokens** — colors, typography, spacing, motion are tokenized. Raw px / hex / rgba are forbidden in shipped code.
- **Plugin catalog** — `@symbo.ls/fetch`, `@symbo.ls/frank`, `@symbo.ls/brender`, `@symbo.ls/funcql`, etc. Agents interact with these via their declared APIs, not by patching them.
- **SDK-only backend** — `@symbo.ls/sdk` is the only transport; raw `fetch()` / `socket.io-client` / `axios` are forbidden in project code.

The full catalog is in `contracts/PLATFORM_BINDING.md`. Every agent reads it before any code work. The symbols-mcp pre-edit hook BLOCKS edits to `*.js` files until `get_project_rules` has been called for the current session.

This binding is what makes the template Symbols-specific rather than fully generic. The orchestration layer (Simone, Chuvak, Temo, Watcher, all the contracts, the approval gates, the message shapes) is stack-agnostic and would port to any stack. The execution layer is tightly bound to Symbols.

## What is intentionally NOT in this architecture

- **A platform-level autonomous decision-maker.** Simone is conversational; she never autonomously decides for a tenant. Cross-tenant decisions (pricing, platform-wide policy) are made by Symbols' own Chuvak instance, not by Simone.
- **A "super agent" that does all five roles.** The split exists for safety. Combining roles is a known anti-pattern.
- **Direct agent-to-agent RPC.** All inter-agent traffic flows through tickets + the explicit `Agent`-tool subagent invocation. No back-channel.
- **Persistent agent memory.** Agents are stateless between ticks. State lives in tickets, comments, activity log. Agents can read history but should not assume continuity of their own context.
