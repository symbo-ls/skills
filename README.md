# Symbols Skills — Agentic Orchestration Template

A reusable, multi-tier agent system that runs inside a Symbols workspace tenant. Drop this submodule into any tenant repo, fill in the config, and you get a self-operating PM + execution loop wired to Supabase tickets.

## What you get

A five-role hierarchy that separates conversation, decision-making, routing, execution, and observation:

```
                       Simone   (global · Symbols platform · cross-tenant)
                          |
                          v   task hand-off (tenant-scoped)
                       Chuvak   (per-tenant · operational orchestrator · the brain)
                       /       \
                      v         v
                    Temo      Watcher   (siblings under Chuvak)
                     |           |
                     |           +--> observations -> Chuvak
                     |
                     +---- Cross-epic helpers (pair with epic agents):
                     |       UX            (flows, a11y, copy)
                     |       UI Design     (tokens, brand, motion)
                     |       QA            (functional validation)
                     |
                     v
              Epic subagents   (cloned from one template, one per scope)
              content, billing, server, growth, ...
```

Roles in one line each:

| Role            | Scope                       | Owns                                                      |
|-----------------|-----------------------------|-----------------------------------------------------------|
| **Simone**      | Global, all tenants         | Conversation with users; drafts task specs; never edits.  |
| **Chuvak**      | One tenant                  | Decisions, approval gates, integrating inputs, delegation.|
| **Temo**        | Under Chuvak                | Classify and route tasks to epic subagents; dependency chains.|
| **Watcher**     | Under Chuvak                | Reads telemetry, produces analyses, posts observations.   |
| **UX**          | Cross-epic, under Temo      | Flows, a11y, copy. Pairs with epics; reviews on ready_to_test.|
| **UI Design**   | Cross-epic, under Temo      | Tokens, brand, visual craft. Pairs with epics; reviews.   |
| **QA**          | Cross-epic, under Temo      | Functional validation. Reviews on ready_to_test.          |
| **Epic agent**  | Scope-owning, under Temo    | Executes work inside a defined scope.                     |

## Why split it this way

Conflating these roles is the most common failure mode for agent systems:

- If the **conversational** agent also routes tickets, it can spawn execution mid-chat with no review surface.
- If the **executor** also decides scope, scope creeps every run.
- If **analytics** can file work directly, every minor anomaly becomes a ticket.
- If **decision-making** lives inside the router, approval gates become afterthoughts.

This split puts a human-controllable boundary between every layer. Watcher reports up; Chuvak decides; Temo dispatches; epic agents execute; Simone communicates. No layer skips the next.

## What's in this repo

```
skills/
  README.md                          this file
  ARCHITECTURE.md                    full role + protocol spec
  INSTALL.md                         step-by-step adoption guide
  agents/
    simone.md                        global agent (Symbols platform deploys ONE)
    chuvak.md                        per-tenant orchestrator (you customize)
    temo.md                          PM under Chuvak
    watcher.md                       analytics under Chuvak
    ux.md                            cross-epic helper — flows, a11y, copy
    ui-design.md                     cross-epic helper — tokens, brand, motion
    qa.md                            cross-epic helper — functional validation
    epic-agent.template.md           parameterized epic-agent template
  contracts/
    EPIC_AGENT_CONTRACT.md           claim/ship/heartbeat protocol every epic agent inherits
    ORCHESTRATION_CONTRACT.md        Chuvak <-> Temo <-> Watcher message protocol
    APPROVAL_GATES.md                when Chuvak MUST ask a human before proceeding
    SCOPE_MAP.template.md            URL + path -> agent routing table (per tenant)
    PLATFORM_BINDING.md              Symbols stack constraints — DOMQL v3.14, frankability, reuse, tokens, plugins, SDK
    CODING_GUIDELINES.md             behavioral guidelines for any execution-capable agent
  scripts/
    _retry-curl.sh                   retry helper for the REST + RPC calls all agents make
  config/
    agents.config.template.yaml      one file the tenant fills in; drives the install
    env.template.sh                  env vars every agent expects in its shell
  examples/
    symbols-platform.md              how the Symbols platform itself adopts this template
```

## Platform binding

This template is for tenants running on the **Symbols platform**. The agents are tightly coupled to the Symbols stack — DOMQL v3.14 syntax, the design-system token model, the 3-tier reuse model (framework built-ins → shared libraries → project), the plugin catalog (`@symbo.ls/fetch`, `@symbo.ls/frank`, …), and SDK-only backend access. Every execution-capable agent reads `contracts/PLATFORM_BINDING.md` before generating or editing code; the symbols-mcp pre-edit hook enforces it.

Tenants running on a different stack would need to rewrite `PLATFORM_BINDING.md` plus the audit / generate steps in the epic-agent template. The orchestration layer (Simone, Chuvak, Temo, Watcher, the contracts, the approval gates) is stack-agnostic; the EXECUTION layer is bound to Symbols.

## Quick start (TL;DR)

1. Add this repo as a git submodule of your tenant repo.
2. Copy `config/agents.config.template.yaml` to your repo root as `agents.config.yaml`. Fill in workspace_id, API URL, owner email, and the epics you want to spawn.
3. For each entry in `epics:`, copy `agents/epic-agent.template.md` into your repo's `.claude/agents/<key>.md` and substitute the placeholders (a 30-second find-replace per epic).
4. Copy `agents/simone.md`, `chuvak.md`, `temo.md`, `watcher.md`, `qa.md` into `.claude/agents/` and fill the placeholders.
5. Copy `contracts/*` and `scripts/_retry-curl.sh` into `.claude/agents/` so the agents can `source` them.
6. Source `config/env.template.sh` (filled in with your tenant secrets) before invoking any agent.

Full walk-through with concrete commands lives in [INSTALL.md](./INSTALL.md).

## Customizing per tenant

Three layers of customization, in order of frequency:

1. **Config only** — workspace_id, API URL, agent identities, approval-gate triggers, epic list. Edit `agents.config.yaml` and re-run the install copy step.
2. **Add an epic** — clone `epic-agent.template.md` into a new `.claude/agents/<key>.md`, list the scope paths, set tools and model. Add the entry to `SCOPE_MAP.md` so Temo routes to it.
3. **Add a sibling to Temo / Watcher** — for novel orchestration patterns (e.g., a "Negotiator" agent that handles partner integrations). Use `chuvak.md`'s `delegations` section as the registry; write the new agent with a clear contract to Chuvak.

The execution contracts (`EPIC_AGENT_CONTRACT.md`, `ORCHESTRATION_CONTRACT.md`) should rarely change — they encode the claim/ship/heartbeat semantics and the cross-agent message shape. Override only if you have a strong reason.

## Backing store

The template assumes a Supabase-shaped backend with these tables (already shipped on the Symbols platform):

- `tickets` — work items (type: task / bug / decision / observation / resolution)
- `ticket_comments` — async clarifications between agents and humans
- `ticket_dependencies` — explicit blocked-by edges
- `agent_presence` — heartbeats per agent per workspace
- `agent_activity_log` — append-only history
- `v_agent_queue` — view returning unblocked work per assignee_email

Plus a small set of stored procedures used by the contracts: `claim_and_dispatch`, `open_resolution_ticket`, `release_ticket`, `find_similar_resolved`. Schema specs live in the Symbols platform's `architecture/MODEL.md`; ports to other backends are straightforward if you keep the verbs.

## License

MIT. Use it, fork it, ship it.
