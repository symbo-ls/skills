# Example — Symbols platform adoption

The Symbols platform itself uses this template. This document maps the abstract roles to Symbols' concrete deployment, so adopters can see a complete instance.

## Role mapping

| Template role  | Symbols deployment                                                        |
|----------------|---------------------------------------------------------------------------|
| **Simone**     | Single deployment at the platform level (`assistant.localhost:1355` in dev, `assistant.symbols.app` in prod). Routes by authenticated tenant to call the tenant's Chuvak. |
| **Chuvak**     | One per workspace. Each tenant gets a `chuvak-agent@<tenant>` identity. The Symbols org's own Chuvak runs in the platform workspace. |
| **Temo**       | One per workspace. The platform workspace has the canonical TEMO that ships internal tickets (framework, CLI, SDK, etc.). |
| **Watcher**    | One per workspace. The platform workspace's Watcher monitors agent ops + Stripe + the publish pipeline + the SDK channel health. |
| **Epic agents**| ~30 in the platform workspace — server, cli, sdk, design, framework, plugins, dompiler, symbolize, docs, developers, business, company, dashboard, canvas, tickets, chat, meet, workspace-project, marketplace, screenshots, system, spec, mcp, permissions, preview, infra, integrations, domain, documents, extensions, studios. See `.claude/agents/AGENT_SCOPE_MAP.md` in the Symbols monorepo. |

## Backing store

The Symbols platform's workspace database is a Supabase project with the canonical schema (`tickets`, `ticket_comments`, `ticket_dependencies`, `agent_presence`, `agent_activity_log`, `v_agent_queue`, plus the RPCs `claim_and_dispatch`, `open_resolution_ticket`, `release_ticket`, `find_similar_resolved`, `record_routing_decision`, `bulk_route_tickets`, `upsert_pattern`).

All agent traffic flows through the workspace wrapper at `next.api.symbols.app/workspace-project/sb/*` rather than hitting Supabase directly. The wrapper enforces tenant isolation, rate limits, and audit logging.

## Approval gate configuration

The Symbols platform uses the strict default — every category in `APPROVAL_GATES.md` is enabled. Production deploys require the exact phrase `deploy to production: <ticket-id>` — generic approval phrases don't count. The approver is `nika.tomadze@gmail.com`. Per-deploy authorization is enforced after the 2026-04-25 production incident.

## Tick cadences

- Chuvak: realtime via Supabase WebSocket on `tickets`, `ticket_comments`, `agent_activity_log`. Fallback heartbeat tick every 5 minutes.
- Temo: realtime on the same channels; fallback tick every 2 minutes.
- Watcher: signal-specific intervals (errors every 1 min, latency every 5 min, cost every 60 min).
- QA smoke: every 15 minutes; rotates through ~12 canonical flows.

## Watcher signals

Symbols' Watcher monitors:
- Server-side error rate per endpoint.
- p95 latency per endpoint family.
- Stripe webhook delivery health.
- SDK channel availability (next / preview / production health).
- Agent ops anomalies — stuck tickets, routing accuracy drops, repeated `failed` returns.
- Cost — Anthropic API spend per agent per day; outlier detection on individual agent runs.

## How adopters benefit from this example

If you're standing up a new tenant on the Symbols platform, the platform's own `.claude/agents/*.md` is your most concrete reference. Compare:

- The template's `agents/temo.md` (abstract) <-> the platform's `.claude/agents/temo.md` (Symbols-specific).
- The template's `contracts/EPIC_AGENT_CONTRACT.md` (abstract) <-> the platform's `.claude/agents/EPIC_AGENT_CONTRACT.md` (Symbols-specific).
- The template's `agents/epic-agent.template.md` <-> any of the ~30 epic files (`server.md`, `cli.md`, `design.md`).

Where the template uses `{{TENANT_API_URL}}`, the Symbols deployment has `https://next.api.symbols.app`. Where the template uses `{{TENANT_WORKSPACE_ID}}`, Symbols uses `69e5911201b0ef47b675463f`. The substitution pattern is otherwise identical.

## What Symbols does that isn't in the template

A few platform-specific additions you can copy if needed:

- **`supa-watcher.cjs`** — a small Node.js script subscribed to Supabase realtime that fans `INSERT` / `UPDATE` events to a local `/tmp/supabase-events.jsonl`. Temo's autonomous mode tails this file via Claude Code's Monitor tool. Lets the platform run TEMO as a local /loop without polling.
- **`_trigger_auto_file_mcp_followup`** — a Postgres trigger that watches for resolution JSONBs with `triggers_mcp_update=true` and auto-files a child ticket assigned to the MCP doc agent. Keeps the MCP docs synced without manual coordination.
- **`v_agent_queue`** — a view that returns unblocked, unassigned, and ready-to-test tickets per assignee_email, ordered by priority + age. The template assumes this view exists in the backing store.

These are useful patterns but not strictly required — a tenant can run with polling + manual MCP follow-up + a simpler query for the queue.

## Cross-tenant Simone in practice

Simone serves the Symbols platform's own tenant + every external tenant on the platform. When a user opens `assistant.symbols.app`, the routing layer resolves which tenant they belong to and gives Simone tenant-scoped credentials for that workspace. Simone never holds two tenants' credentials in one conversation.

Cross-tenant pattern detection (anonymized): the platform's `Watcher` aggregates anonymized signals across all tenants (e.g., "47% of tenants saw a latency regression on /api/projects/list at the same UTC timestamp"). Simone can surface these anonymized patterns to a tenant's owner as a hint, but never with raw cross-tenant data.
