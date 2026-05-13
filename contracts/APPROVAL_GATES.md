# Approval Gates

Defines the categories of work that Chuvak MUST halt for explicit human approval. Default is approval, not autonomy. This is the single most important configuration choice when adopting the template — too lax and an agent ships a destructive change; too strict and the system can't move without a human on every step.

## How the gate works

When Chuvak is about to dispatch (or Temo is about to route) a ticket whose title/body/file_hint/labels match a gated category:

1. Halt before dispatch. Do not PATCH `state='in_progress'`.
2. PATCH the ticket: `state='awaiting_approval'`, append the relevant `labels` (e.g. `human-approval-needed`, `infrastructure`, `prod-deploy-pending`).
3. POST an `ASK-USER` decision ticket (`type='decision'`, `labels=['ASK-USER']`) with:
   - Why this needs approval (which category triggered).
   - What the change will do (one-line summary + blast radius).
   - Rollback plan.
   - Recommendation (proceed / discuss / break into stages).
   - `assignee_email = {{TENANT_OWNER_EMAIL}}`.
4. Log `kind='awaiting_approval'` activity on the original.
5. Stop. Resume only when the approver comments with explicit approval.

## What counts as explicit approval

Configurable in `agents.config.yaml`. Default rules:

- A comment on either the original ticket OR the `ASK-USER` decision ticket.
- From `assignee_email == {{TENANT_OWNER_EMAIL}}` (the configured approver) or another email in the `approvers` allowlist.
- Containing at least one of: `approved`, `ship it`, `proceed`, `go ahead`, `lgtm`, `OK`, or an unambiguous yes targeted at the question.
- Most-recent comment wins — chronological. A later "hold off" overrides an earlier "approved".

For the most sensitive gates (production deploys, billing changes), approval requires an EXACT phrase that names both the category and the ticket id. Example: `deploy to production: 1234`. Generic `yes` is not enough. Configure via `approval_gates.strict_phrase_categories[]`.

## The gated categories (default catalog)

### Production deploys

Any operation that writes to a production environment. Examples:

- `<cli> publish --env=production` or `--env=prod`.
- `gcloud run deploy` / `kubectl apply` against a prod service or cluster.
- `wrangler deploy` to a prod CF route.
- `<pkg-manager> publish` to the `latest` dist-tag (vs. a `next` snapshot).
- DNS / registrar mutations on prod domains.
- Billing-platform writes to a live account (Stripe live, etc.).
- Schema migrations applied to a prod database.
- Cross-environment promotions: `next -> production`, `staging -> production`.

### Schema migrations on prod data

Even if the migration is reversible, a prod-data migration MUST have explicit approval. Includes:

- Any SQL touching a prod-scoped table.
- RLS policy weakening (broader access).
- Adding NOT NULL to a populated column.
- Renaming or dropping columns / tables / indexes.

### Billing, pricing, commercial terms

- Changes to pricing tables, plan structure, usage metering, free-vs-paid gating.
- Stripe webhook semantic changes.
- New paywalls or removal of existing ones.
- Coupon / discount creation against the live billing account.

### Permission, auth, security broadening

- Adding a permission to a role.
- Loosening an RLS policy.
- Adding a new OAuth provider.
- Rotating signing keys / KIDs.
- Changing session cookie domain, SameSite, or Secure flags.
- Lowering rate limits in a way that increases capacity.

### External integration provisioning

- Adding a new third-party integration that sends or receives tenant data.
- Onboarding a partner with a data flow agreement.
- API key creation against an external service that bills you.

### Destructive operations

- `DROP TABLE`, `DELETE FROM <table>` without WHERE (or with broad WHERE).
- Force-push to `main` / `master`.
- `git reset --hard origin/main` that discards uncommitted work.
- Package republish / unpublish.
- Mass-delete in object storage.

### Important / critical / mission-critical labels

- Anything labeled `important`, `critical`, `mission-critical`.
- Anything `priority='P0'` from a non-approver source (auto-detected high-priority bugs from QA smoke, watcher anomaly tickets that escalated themselves).

### Cross-cutting architecture

- Tickets that touch 3+ agents' scopes simultaneously.
- New epic creation.
- Changes to `SCOPE_MAP.md` / orchestration contracts.
- Workflow / orchestration agent prompt edits.

## Multiple-direction gate

This is NOT a category-based gate — it fires whenever Chuvak or Temo sees a ticket with two or more plausible-but-conflicting directions:

- Two scope interpretations (just-the-bug vs. full-area-overhaul).
- Two architectural patterns at similar quality (websocket vs. polling vs. realtime).
- Two agents that could plausibly own the work.
- Two or more libraries at similar quality bar.
- Title implies one fix, body implies another.
- Weak acceptance criteria ("make it nicer", "improve UX") with multiple thresholds for done.

When detected:

1. Do NOT classify, route, or spawn.
2. PATCH `state='awaiting_approval'`, `labels += ['human-approval-needed', 'ambiguous-direction']`.
3. POST `ASK-USER` decision ticket with options ranked by best-guess, pros/cons per option, effort estimate, files-affected hint.
4. Wait for a comment selecting the option (`1`, `2`, `3`) or proposing a different direction.

Decision-rule for "is this ambiguous enough?":

- If confidence in the top option is >= 0.85 AND the gap to the next option is >= 0.20, proceed without asking.
- Else, ASK.

Erring toward asking is cheaper than erring toward shipping the wrong direction (wasted work + revert).

Exceptions where Chuvak / Temo can pick silently:
- Pure-bug fixes with one clear failure mode (single root cause + obvious fix).
- Mechanical refactors with tests covering the area (test pass/fail is the verdict).
- Doc-only changes (low blast radius).
- Single-agent-scope tickets where the agent itself can self-correct via `wrong-scope`.

## Per-deploy authorization protocol

For production deploys specifically, the protocol is stricter:

1. STOP before executing the gated step.
2. PATCH ticket `state='awaiting_approval'`, `metadata.awaitingProdDeploy=true`.
3. Comment a summary on the original: env, hostname, service, commit, blast radius, rollback.
4. Surface to the approver.
5. Approver replies with the EXACT phrase `deploy to production: <ticket-id>` (or unambiguous equivalent that names "production" AND the ticket id).
6. Record `metadata.prodDeployApprovedBy=<approver>` + `metadata.prodDeployApprovedAt=<timestamp>` and proceed.
7. After deploy, file a verification ticket with prod state (commit SHA, version, URL) and monitoring signals.

Generic approval phrases (`yes`, `ship it`, `OK`, `approved`) DO NOT count for production deploys. The exact phrase requirement exists because production approvals are routinely the most consequential single action and the cheapest place to add friction.

## Disabling approval gates

In tenant deployments where the operator wants full autonomy, the gates can be disabled per-category in `agents.config.yaml`:

```yaml
approval_gates:
  enabled: true                       # master switch
  triggers:
    production_deploy: true
    schema_migration: true
    billing_change: true
    permission_broadening: true
    external_integration: true
    destructive_ops: true
    cross_cutting: true
    ambiguous_direction: true
```

Setting `enabled: false` disables every gate (not recommended outside of trusted test environments). Setting an individual trigger to `false` disables that specific category.

Caution: gates are the only thing preventing agents from autonomously taking irreversible production actions. Disable knowingly.
