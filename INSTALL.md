# Install — adopting the template for a new tenant

This document walks through standing up the agent system inside a fresh tenant workspace. Estimated time end-to-end: 30 minutes for a tenant with 3 epics, plus the time to seed the backing tables (which is normally a one-shot platform-level migration).

## Prerequisites

- A workspace in your Symbols-shaped backend with the tables listed in `README.md § Backing store`.
- Service-role credentials for that workspace.
- An `assignee_email` namespace you control (e.g. `*-agent@<tenant>.example.com`).
- A target repo with a `.claude/` directory (Claude Code conventions).

## Step 1 — Add the submodule

```bash
cd <tenant-repo>
git submodule add <this-skills-repo-url> skills
git commit -m "feat: add agent skills submodule"
```

## Step 2 — Fill out the config

Copy the template:

```bash
cp skills/config/agents.config.template.yaml ./agents.config.yaml
```

Edit `agents.config.yaml`:

- `tenant.workspace_id` — your workspace primary key.
- `tenant.api_url` — the REST/RPC URL all agents talk to.
- `tenant.owner_email` — who the approval gates page (this becomes the `assignee_email` on every `ASK-USER` decision ticket).
- `orchestration.<role>.identity` — agent service-account email per role (chuvak, temo, watcher, qa).
- `orchestration.<role>.model` — claude model id per role.
- `orchestration.<role>.enabled` — flip false to disable a role.
- `epics[]` — one entry per epic you want spawned. Each entry needs `key`, `name`, `identity`, `scope_paths`, `tools`, `model`.
- `approval_gates.triggers` — which categories halt execution; see `contracts/APPROVAL_GATES.md` for the catalog.

## Step 3 — Generate the agent files

For each agent listed in your config, copy the source into `.claude/agents/` and substitute placeholders. The placeholders are mustache-style `{{NAME}}` for easy find-replace.

Each agent template references these standard placeholders:

| Placeholder              | Source                                                       |
|--------------------------|--------------------------------------------------------------|
| `{{TENANT_NAME}}`        | Display name of your tenant                                  |
| `{{TENANT_WORKSPACE_ID}}`| `tenant.workspace_id`                                        |
| `{{TENANT_API_URL}}`     | `tenant.api_url`                                             |
| `{{TENANT_OWNER_EMAIL}}` | `tenant.owner_email`                                         |
| `{{AGENT_KEY}}`          | lowercase slug (`server`, `content`, `qa`, …)                |
| `{{AGENT_NAME}}`         | uppercase name (`SERVER`, `CONTENT`, `QA`, …)                |
| `{{AGENT_IDENTITY}}`     | `<key>-agent@<tenant>.example.com`                           |
| `{{AGENT_MODEL}}`        | claude model id (`claude-sonnet-4-6`, etc.)                  |
| `{{AGENT_DESCRIPTION}}`  | one-line description shown in the agent picker               |
| `{{AGENT_SCOPE_PATHS}}`  | glob patterns the agent owns                                 |
| `{{AGENT_TOOLS}}`        | comma-separated tool whitelist                               |
| `{{AGENT_ESCALATION}}`   | epic-specific escalation triggers (optional, free text)      |

A quick way to do the substitution:

```bash
# Manual; safer than a script — review each substitution as you go.
cp skills/agents/chuvak.md      .claude/agents/chuvak.md
cp skills/agents/temo.md        .claude/agents/temo.md
cp skills/agents/watcher.md     .claude/agents/watcher.md
cp skills/agents/qa.md          .claude/agents/qa.md
cp skills/agents/ux.md          .claude/agents/ux.md
cp skills/agents/ui-design.md   .claude/agents/ui-design.md

# For each epic in your config:
cp skills/agents/epic-agent.template.md  .claude/agents/<epic-key>.md
```

Then run a find-replace across `.claude/agents/*.md` swapping each `{{PLACEHOLDER}}` for the value from your config. If you have many epics, write a tiny shell script that wraps `sed -i` per file.

## Step 4 — Wire the shared scripts and contracts

The agent prompts `source` these helpers at boot; they need to live where the agent shell can find them.

```bash
mkdir -p .claude/agents/_shared
cp skills/scripts/_retry-curl.sh                  .claude/agents/_shared/
cp skills/contracts/EPIC_AGENT_CONTRACT.md        .claude/agents/_shared/
cp skills/contracts/ORCHESTRATION_CONTRACT.md     .claude/agents/_shared/
cp skills/contracts/APPROVAL_GATES.md             .claude/agents/_shared/
cp skills/contracts/PLATFORM_BINDING.md           .claude/agents/_shared/
cp skills/contracts/CODING_GUIDELINES.md          .claude/agents/_shared/
cp skills/contracts/SCOPE_MAP.template.md         .claude/agents/_shared/SCOPE_MAP.md
```

The `PLATFORM_BINDING.md` is the Symbols-stack-specific binding (DOMQL v3.14, frankability, design tokens, 3-tier reuse, plugins, SDK). Every execution-capable agent reads it before generating or editing code; the symbols-mcp pre-edit hook enforces the must-do sequence at runtime.

Edit `.claude/agents/_shared/SCOPE_MAP.md` — list every URL prefix and path glob you want routed, with the owning agent. The orchestration agents read this on boot and cache it.

## Step 5 — Environment variables

Copy the env template and fill it:

```bash
cp skills/config/env.template.sh ./tenant.env.sh
```

Edit `tenant.env.sh` with the secrets (service role key, etc.). Add it to `.gitignore`; never commit. Then `source tenant.env.sh` in any shell that's going to invoke an agent (or rely on a launcher script that loads it).

## Step 6 — Seed service-account rows

Each agent identity needs a row in your auth.users table (or equivalent) so it can write to `agent_presence` and `agent_activity_log` against your workspace's `workspace_id`. The Symbols platform handles this via a one-shot migration when a tenant is provisioned; if you're standing up your own backend, mirror the script in `examples/symbols-platform.md`.

## Step 7 — Wire Simone (platform-side)

Simone is platform-owned, not tenant-owned. If you operate the Symbols platform, deploy `agents/simone.md` once at the platform level with a routing layer that knows which tenant Chuvak to invoke. If you're a tenant adopting this template, you don't deploy Simone yourself — the platform's Simone calls into your tenant's Chuvak over the tenant-scoped API.

If you're operating without a platform-level Simone (single-tenant deployment), you can either:
- Skip Simone entirely; Chuvak can also handle conversational asks (just expand Chuvak's `tools` whitelist to include browser/chat tools).
- Deploy Simone locally as if she were a tenant agent, with the conversational tools and no cross-tenant logic.

## Step 8 — Smoke test

In your tenant workspace, file one trivial task ticket against an epic you've configured. Within one tick, you should see:

1. Heartbeat row in `agent_presence` for the epic agent.
2. `picked_up` activity in `agent_activity_log`.
3. State transition from `not_started` to `in_progress`.
4. A commit on the matching branch.
5. State transition to `ready_to_test` or `done` plus a `resolution` JSONB.

If any of those don't appear, check:
- Is `tenant.env.sh` sourced in the agent shell?
- Is the agent identity in `auth.users` with the right `workspace_id`?
- Does `SCOPE_MAP.md` route to the configured `assignee_email` exactly?
- Did the agent's `tools` list include the tools its work requires?

## Step 9 — Periodic ticks

For autonomous mode, the orchestration agents need to wake periodically. Two common patterns:

- **Cron-driven** — a cron job invokes Chuvak's `/loop` slash command every N minutes.
- **Realtime-driven** — a tiny Node service subscribes to Supabase realtime on `tickets`, `ticket_comments`, and `agent_activity_log`, fanning events to Chuvak. The Symbols platform ships such a service; see `examples/symbols-platform.md`.

Pick whichever your environment supports. Either way, the agent prompts themselves stay identical — only the trigger differs.

## Common mistakes during install

- **Skipping the wrapper.** All REST/RPC calls go through your tenant's API wrapper (the URL in `tenant.api_url`), not directly to Supabase, even if your wrapper just proxies. The wrapper is where you enforce tenant isolation and rate limiting; bypassing it during install creates a hard-to-find security gap later.
- **Reusing one identity for multiple agents.** Each agent needs its own `assignee_email` so the queue view, the heartbeat watchdog, and the activity log all attribute work correctly.
- **Leaving `{{PLACEHOLDERS}}` in agent files.** Grep for `{{` in `.claude/agents/` after substitution; any remaining placeholder is a misconfiguration that will fail at runtime.
- **Forgetting to add the `needs-qa` label when shipping schema migrations.** QA gate is opt-in by label, not by file path. Set it during ticket creation, or have Temo add it based on `SCOPE_MAP` annotations.
- **Letting Watcher file work tickets.** Watcher posts `type='observation'` only; if you see Watcher filing tasks, fix Watcher's prompt — Chuvak must be the one deciding.

## Upgrading

When this template repo gets new content (new contracts, refined approval gates, new common epic templates), pull the submodule, diff `agents/*.md` against your `.claude/agents/*.md`, and rerun the find-replace for any new placeholders. The contracts in `_shared/` you can overwrite directly; the agent files in your tenant repo will need a per-tenant merge.
