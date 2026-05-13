# Scope Map — URL + path -> agent (TEMPLATE)

The authoritative routing reference for THIS tenant. Temo reads this on boot, caches it, and consults it on every classification. Every epic agent reads it during scope self-correction.

This file is a template — fill in your tenant's actual URLs, paths, and agent keys. Keep one source of truth; do not duplicate routing logic into individual agent files.

When you add a new epic, update this file FIRST, then add the agent file, then test routing with a smoke ticket.

---

## URL-based routing

The fastest lookup. If a ticket title or body mentions a URL, route by URL prefix first.

### `<app-host>` — primary tenant app

| Path                | Agent          | Source file                           |
|---------------------|----------------|---------------------------------------|
| `/`                 | `<shell-key>`  | `<path/to/shell>`                     |
| `/<feature-1>/*`    | `<key-1>`      | `<path/to/feature-1>`                 |
| `/<feature-2>/*`    | `<key-2>`      | `<path/to/feature-2>`                 |
| `/<feature-3>/*`    | `<key-3>`      | `<path/to/feature-3>`                 |
| `/admin/*`          | `<admin-key>`  | `<path/to/admin>`                     |

### `<admin-host>` — admin app (if separate from the primary)

| Path        | Agent          |
|-------------|----------------|
| `/*`        | `<admin-key>`  |

### Production domains

| Pattern                       | Agent              |
|-------------------------------|--------------------|
| `<your-domain>/docs/*`        | `<docs-key>`       |
| `<api-domain>/*`              | `<server-key>`     |
| `<cdn-domain>/*`              | `<assets-key>`     |
| `*.<your-domain>`             | `<domain-key>`     |

---

## Path-based routing (non-URL)

Backend, tooling, and codebase scopes that aren't reachable via URL.

| Path pattern                        | Agent                |
|-------------------------------------|----------------------|
| `server/**`                         | `<server-key>`       |
| `<some-backend>/**`                 | `<server-key>`       |
| `cli/**`, `packages/cli/**`         | `<cli-key>`          |
| `sdk/**`, `packages/sdk/**`         | `<sdk-key>`          |
| `<framework-package>/**`            | `<framework-key>`    |
| `infrastructure/**`, `.github/workflows/**` | `<infra-key>`|
| `architecture/<spec-file>.md`       | `<spec-key>`         |
| `docs/**`                           | `<docs-key>`         |
| `mobile/**`                         | `<mobile-key>`       |
| `marketing/**`                      | `<marketing-key>`    |

---

## Self-correction rule (every epic agent honors this)

After heartbeat + queue fetch, BEFORE claiming the ticket, every epic agent validates:

1. Read the top ticket.
2. Check: does the ticket's URL (if any in title/body) match a routing row for this agent? Does the `file_hint` (if any) match a path-pattern row? Does the title/body clearly describe work in scope?
3. If NO: return `wrong_scope` with `suggested_agent` and reasoning. Do NOT claim.
4. If YES: proceed with normal claim and ship.

Why: Temo can mis-classify. Each agent is the domain expert on its own scope and should self-correct before doing work in the wrong directory.

---

## When to file ASK-USER

If a ticket fits none of the rows above AND no obvious pattern match AND no existing agent's scope clearly covers it:

- File `type='decision'` ticket with `labels=['ASK-USER']`, `title='Routing: <ticket title>'`.
- Body: what Temo saw, which agents were candidates, why unclear.
- `assignee_email = {{TENANT_OWNER_EMAIL}}`.

The approver decides and either:
- Comments with the correct agent key (Temo updates the scope map and re-routes).
- Comments with a new agent name (operator must add the epic to config + scope map).

---

## Unmapped or in-flight scopes

When a new path appears in the codebase but isn't in this map yet, Temo files ASK-USER asking which agent claims it. After the approver decides, the map is updated to include the row.

Keep an "Unmapped" section at the bottom of this file as a parking lot:

```
## Unmapped (to triage)

- `<path>` — first seen <date>; candidate agents: <key1>, <key2>; approval pending in ticket #N.
```

This makes routing-gap accumulation visible and prevents the map from silently drifting out of date.
