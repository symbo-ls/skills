# skills/ — Agent Hierarchy

Schema for the reusable orchestration template in this repo. Five roles, one execution contract, one routing map. Every tenant gets one of each (except Simone, who is shared at the platform level).

## Tier 0 — Spec / contract files (read by every agent)

```
skills/
├── README.md                            entry point
├── ARCHITECTURE.md                      full role + protocol spec
├── INSTALL.md                           adoption guide
├── agents/
│   ├── simone.md         global · platform-level · 1 instance
│   ├── chuvak.md         per-tenant · the brain
│   ├── temo.md           PM / router
│   ├── watcher.md        analytics / observer
│   ├── ux.md             cross-epic helper
│   ├── ui-design.md      cross-epic helper
│   ├── qa.md             cross-epic helper
│   └── epic-agent.template.md    cloned per scope
├── contracts/
│   ├── EPIC_AGENT_CONTRACT.md      claim / ship / heartbeat
│   ├── ORCHESTRATION_CONTRACT.md   Chuvak ↔ Temo ↔ Watcher messages
│   ├── APPROVAL_GATES.md           when to halt for human
│   ├── PLATFORM_BINDING.md         Symbols stack constraints
│   ├── CODING_GUIDELINES.md        execution-agent behavior
│   └── SCOPE_MAP.template.md       URL/path → agent routing
├── config/
│   ├── agents.config.template.yaml
│   └── env.template.sh
├── scripts/
│   └── _retry-curl.sh
└── examples/
    └── symbols-platform.md
```

## Tier 1–5 — role hierarchy

```
                               PLATFORM LEVEL
                          ┌─────────────────────────┐
                          │         USER            │  human
                          └────────────┬────────────┘
                                       │ chat
                                       ▼
                          ┌─────────────────────────┐
                          │        SIMONE           │  global · 1 per platform
                          │  • drafts task specs    │  cross-tenant aware
                          │  • surfaces ASK-USER    │  (anonymized only)
                          │  • no code, no routing  │
                          └────────────┬────────────┘
                                       │ task hand-off (tenant-scoped)
═══════════════════════════════════════╪═══════════════════════════════════
                               TENANT BOUNDARY
                                       ▼
                       ╔═════════════════════════════╗
                       ║         CHUVAK              ║  per-tenant · 1
                       ║  THE BRAIN — decisions      ║
                       ║  • integrates inputs        ║
                       ║  • approval gates           ║
                       ║  • delegates to Temo        ║
                       ║  • never edits code         ║
                       ╚══════════════╤══════════════╝
                                      │
                  ┌───────────────────┴───────────────────┐
                  │                                       │
                  ▼                                       ▼
       ┌──────────────────────┐               ┌──────────────────────┐
       │        TEMO          │   ◄── obs ──  │       WATCHER        │
       │  PM / router         │               │  analytics / signal  │
       │  • classify          │               │  • telemetry scan    │
       │  • dedup             │               │  • pattern detection │
       │  • dispatch          │               │  • files OBSERVATION │
       │  • dependency chain  │               │    tickets only      │
       │  • QA gate           │               │  • never files work  │
       │  • never decides     │               └──────────────────────┘
       │    scope (escalates  │
       │    ambiguity)        │
       └──────────┬───────────┘
                  │ dispatch (after Chuvak's task_brief)
                  │
       ┌──────────┼──────────────────────────────────────────┐
       │          │                                          │
       ▼          ▼                                          ▼
  CROSS-EPIC HELPERS                              EPIC SUBAGENTS
  (siblings, pair with epics)                    (cloned from template)
  ┌────────────────────────┐                     ┌────────────────────┐
  │  UX                    │                     │  <key1>            │
  │  • flows / a11y / copy │  ◄─ briefs ──►      │  <key2>            │
  ├────────────────────────┤                     │  <key3>            │
  │  UI DESIGN             │                     │  ...               │
  │  • tokens / brand /    │                     │                    │
  │    motion / theming    │                     │  one per scope     │
  │  • ALSO ships primary  │                     │  declared in       │
  │    in design-system    │                     │  SCOPE_MAP.md      │
  ├────────────────────────┤                     │                    │
  │  QA                    │                     │  inherit:          │
  │  • functional review   │                     │  EPIC_AGENT_       │
  │  • Mode B smoke loop   │                     │  CONTRACT.md       │
  │  • never edits code    │                     │  PLATFORM_BINDING  │
  └────────────────────────┘                     └────────────────────┘
```

## Drafting permissions — who creates what

```
Simone   →  task spec drafts (hands off to a tenant's Chuvak)
Chuvak   →  ASK-USER decision tickets (approval gate halts)
Temo     →  routed-block tickets, dependency edges, cross-epic helper invocations
Watcher  →  type='observation' tickets ONLY (never work tickets)
QA       →  type='bug' tickets on validation failure
UX       →  ux_brief written to ticket metadata (Mode B); type='task' in own scope (Mode A)
UI       →  ui_design_brief written to ticket metadata (Mode B); type='task' in own scope
Epic     →  resolution ticket on ship (companion to parent work ticket)
            never creates new work — returns blocked-external to Temo instead
```

## Execution modes

```
SYNC CHAIN (user is waiting)              AUTONOMOUS LOOP (no one asking)
─────────────────────────────             ─────────────────────────────────
user → Simone                             Chuvak ticks every N min:
       Simone → Chuvak                       reads tickets + observations
              Chuvak → Temo                  + comments → decides
                     Temo → Epic             → dispatches Temo if work needed
                          Epic ships      Temo ticks every N min:
                     ← Temo                    reads queue → dispatches
              ← Chuvak                     Watcher ticks every N min:
       ← Simone summarizes                    scans telemetry → files
                                              observations for Chuvak
(depth ≤ 3; ambiguity → ASK-USER)
```

## State machine (tickets)

```
                    ┌─► awaiting_approval ─── human comment ───┐
                    │   (approval gate)                         │
                    │                                           ▼
   not_started ─────┼─► in_progress ──── epic ships ──► ready_to_test
                    │       │                                  │
                    │       └─── blocked-external ──► blocked  │
                    │                                  │       │
                    │                                  │       ▼
                    │                                  │   QA verdict
                    │                                  │       │
                    │                                  │       ├─ pass  ──► done
                    │                                  │       ├─ minor ──► back to in_progress
                    │                                  │       └─ critical ► new bug + blocks original
                    │                                  ▼
                    └──────────────── dep cleared ──── in_progress
```

## Back-edges (who reports to whom)

```
Epic     → Temo      {status, commit_sha | wrong-scope | blocked-external}
Temo     → Chuvak    {agent, status, ticket_id | ask-user | ambiguous-direction}
Watcher  → Chuvak    {observation_ticket_id, signal, severity, evidence}
QA       → Temo      {verdict: pass | minor | critical, evidence}
UX / UI  → Temo      {brief written, ticket_id}     ◄─ pair mode
UX / UI  → Temo      {review verdict}               ◄─ review mode (ready_to_test)
Chuvak   → Simone    {result, surfaces if user waiting}
Simone   → user      conversational summary
Chuvak   → human     ASK-USER ticket (comment channel = approval signal)
```

## Communication — all through the workspace DB

No back-channel RPC between agents. Everything is observable, replayable, auditable.

```
tickets              work items (task / bug / decision / observation / resolution)
ticket_comments      async clarifications, approvals (most-recent human comment wins)
ticket_dependencies  blocked-by edges
agent_presence       heartbeats (>5min stale = watchdog signal)
agent_activity_log   append-only history (used by find_similar_resolved)
v_agent_queue        view of unblocked work per assignee_email
```

Stored procedures every contract uses: `claim_and_dispatch`, `open_resolution_ticket`, `release_ticket`, `find_similar_resolved`.

## Key invariants

- **Chuvak is the only decision node** in a tenant. Temo dispatches, Watcher observes, epics execute.
- **Simone never holds tenant state across conversations** — fresh request every chat, scoped through the tenant API.
- **Watcher never files work** — only observations. Chuvak chooses what becomes work.
- **Temo never decides scope** — on ambiguity, returns `ambiguous-direction` to Chuvak.
- **Epic agents never edit outside their scope** — return `wrong-scope` for Temo to re-route.
- **No layer skips the next** — user → Simone → Chuvak → Temo → epic. No shortcuts.
- **Approval is default, not autonomy** — gated categories halt at Chuvak with an ASK-USER ticket; resume only on explicit human approval comment.
- **Platform binding is enforced at the execution layer** — every code-writing agent reads `PLATFORM_BINDING.md` and the symbols-mcp pre-edit hook blocks edits to `*.js` until `get_project_rules` runs.

## Customization layers

```
1. config only    edit agents.config.yaml — workspace_id, API URL, identities,
                  approval triggers, epic list. Re-run install copy step.

2. add an epic    clone epic-agent.template.md → .claude/agents/<key>.md
                  → register in SCOPE_MAP.md → smoke-test routing

3. add a sibling  novel orchestration pattern (e.g. "Negotiator" for partner
   to Temo /      integrations). Register in Chuvak's `delegations` section.
   Watcher       Write contract to Chuvak. Rare.
```

The two execution contracts (`EPIC_AGENT_CONTRACT.md`, `ORCHESTRATION_CONTRACT.md`) should almost never change — they encode the atomic-claim / atomic-ship / message-shape semantics. Override only with strong reason.
