# Epic Agent Contract

The canonical claim / ship / heartbeat protocol for every epic subagent. This contract OVERRIDES the per-invocation workflow in each individual `agents/<key>.md` file for the steps it covers (boot, heartbeat, context-read, claim, ship). The agent's own file remains authoritative for its scope, escalation triggers, and what-to-edit.

Every epic agent reads this contract before doing any work.

## Step 0 — Boot

Source the retry helper and export the env aliases. All REST + RPC calls go through the workspace API wrapper at `{{TENANT_API_URL}}`. The wrapper enforces tenant isolation, rate limits, and audit logging — bypassing it loses those protections.

```bash
source tenant.env.sh
source .claude/agents/_shared/_retry-curl.sh

export TENANT_API_URL="${TENANT_API_URL}"
export TENANT_WORKSPACE_ID="${TENANT_WORKSPACE_ID}"
export TENANT_DB_URL="${TENANT_API_URL}/sb"
export TENANT_SERVICE_ROLE_KEY="${TENANT_SERVICE_ROLE_KEY}"
```

Every inline snippet uses `${TENANT_DB_URL}/rest/v1/...` and routes through the wrapper automatically. Realtime WebSocket subscriptions (used by the supa-watcher equivalent) may use a raw Supabase URL because most wrappers don't tunnel WS; everything else flows through `${TENANT_DB_URL}`.

Use `retry_curl` for every call, never raw `curl`. It handles 429/503/network blips with exponential backoff.

## Step 1 — Heartbeat (unconditional)

ALWAYS heartbeat on boot. ALWAYS heartbeat every 2 minutes during long work. Do not throttle, do not skip. False-dead is worse than the cost of a heartbeat write.

```bash
retry_curl_bg -X POST "${TENANT_DB_URL}/rest/v1/agent_presence" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Prefer: resolution=merge-duplicates" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_name": "{{AGENT_NAME}}",
    "status": "active",
    "last_heartbeat": "'"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"'",
    "workspace_id": "{{TENANT_WORKSPACE_ID}}",
    "assignee_email": "{{AGENT_IDENTITY}}"
  }'
```

Fire-and-forget via `retry_curl_bg` — never block on the heartbeat. Cost is negligible.

Why unconditional matters: the watchdog audit reads `agent_presence.last_heartbeat`. Stale heartbeat ⇒ agent looks dead even when productively running ⇒ pointless re-routing.

## Step 2 — Validate scope (self-correction)

Read the top ticket from your queue. Check its URL (if in title/body), `file_hint` (if in metadata), and title against your declared scope. If the ticket does NOT match your scope, return without claiming:

```json
{
  "kind": "epic_result",
  "ticket_id": <id>,
  "status": "wrong_scope",
  "suggested_agent": "<correct key>",
  "reasoning": "<why not mine + why theirs>"
}
```

Temo re-routes. Do NOT PATCH `state='in_progress'` before returning — the ticket must remain claimable.

## Step 3 — Read full ticket context

The title + body are a starting point, not the full picture. Before implementing, fetch:

```bash
TID=<ticket_id>

# 1. Comments — clarifications, prior QA fails, briefs, agent self-notes
COMMENTS=$(retry_curl -s "${TENANT_DB_URL}/rest/v1/ticket_comments?ticket_id=eq.${TID}&order=created_at.asc&select=author_email,body,created_at" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}")

# 2. Activity log — full history
ACTIVITY=$(retry_curl -s "${TENANT_DB_URL}/rest/v1/agent_activity_log?ticket_id=eq.${TID}&order=created_at.asc&select=agent_name,kind,metadata,created_at" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}")

# 3. Dependencies — both directions
DEPS=$(retry_curl -s "${TENANT_DB_URL}/rest/v1/ticket_dependencies?or=(ticket_id.eq.${TID},depends_on_ticket_id.eq.${TID})&select=ticket_id,depends_on_ticket_id,kind,note" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}")

# 4. Parent ticket (if present) — inherits acceptance criteria
if [ "$PARENT_ID" != "null" ] && [ -n "$PARENT_ID" ]; then
  PARENT=$(retry_curl -s "${TENANT_DB_URL}/rest/v1/tickets?id=eq.${PARENT_ID}&select=title,body,labels,metadata" \
    -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}")
fi

# 5. Similar resolved — avoid re-deriving fixes
SIMILAR=$(retry_curl -s -X POST "${TENANT_DB_URL}/rest/v1/rpc/find_similar_resolved" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"p_title\":\"${TICKET_TITLE}\",\"p_body\":\"${TICKET_BODY}\",\"p_limit\":3}")
```

What to do with the context:

- **Comments** — read every one in chronological order. Last comment is authoritative. Look for redirects ("actually do X"), pause signals ("hold off"), and design briefs.
- **Activity log** — look for `auto-release-hung` (ticket was hung before; understand why), `qa-failed-*` (specific failure detail in metadata), `blocked` (was unblocked? same blocker still present?), `asked_user` (if no resolution comment, do NOT proceed).
- **Dependencies** — if any `depends_on` ticket is not state='done', return `blocked-internal` with that dep id.
- **Parent** — inherits acceptance from parent's body; honor any "must use X library" directives.
- **Similar resolved** — score >= 0.8 means the same fix likely applies. Read `resolution.fix`, apply the same pattern, comment "Pattern from ticket #N applied" on your ticket.

If comments contradict metadata, the LATER one wins (chronological). If still ambiguous, return `asked-user` with a clear question instead of guessing.

## Step 4 — Claim (atomic)

Use `claim_and_dispatch` — one transaction, three operations (state PATCH, presence upsert, activity insert). Do not do these as separate calls.

```bash
CLAIM=$(retry_curl -s -X POST "${TENANT_DB_URL}/rest/v1/rpc/claim_and_dispatch" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"p_ticket_id\": ${TICKET_ID},
    \"p_agent_name\": \"{{AGENT_NAME}}\",
    \"p_agent_email\": \"{{AGENT_IDENTITY}}\"
  }")

STATUS=$(echo "${CLAIM}" | jq -r '.status')
if [ "${STATUS}" = "already_claimed" ]; then
  return 0
fi
```

The RPC atomically:
1. PATCHes `tickets.state='in_progress'` (only if state was `null`, `not_started`, or `in_progress`).
2. UPSERTs `agent_presence.current_ticket_id` + status + heartbeat.
3. INSERTs `agent_activity_log {kind:'picked_up', ticket_id, agent_name}`.

If `status='already_claimed'`, another agent (or a previous run) won. Don't error — move on to the next ticket in your queue.

## Step 5 — Implement

Work happens here. Domain-specific; your `agents/<key>.md` file is authoritative. A few cross-cutting rules:

- **Stay in scope.** Same-repo cross-scope is permitted only if the ticket explicitly spans multiple scopes and Chuvak preauthorized.
- **Commit with clear messages.** Reference the ticket id at the end (`refs #1234`).
- **Run relevant tests** before claiming the work done.
- **Never run `git push --force`** unless explicitly approved per-deploy.
- **Never amend existing commits.** Always new commits.
- **Long work needs heartbeats.** If your work runs past 2 minutes, fire a heartbeat activity entry every 2 minutes:

```bash
retry_curl_bg -X POST "${TENANT_DB_URL}/rest/v1/agent_activity_log" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "[{
    \"agent_name\": \"{{AGENT_NAME}}\",
    \"kind\": \"heartbeat\",
    \"ticket_id\": ${TICKET_ID},
    \"workspace_id\": \"{{TENANT_WORKSPACE_ID}}\",
    \"metadata\": {\"progress\": \"<short status>\"}
  }]"
```

Use `metadata.progress` for human-readable status: "tests passing", "writing migration", "reviewing PR".

## Step 6 — Ship (atomic)

Two variants depending on QA gate:

### Variant A — direct ship (no `needs-qa` label)

```bash
RESOLUTION=$(jq -n \
  --arg sum "${RESOLUTION_SUMMARY}" \
  --arg rc "${ROOT_CAUSE}" \
  --arg fix "${FIX_DESCRIPTION}" \
  --arg sha "${COMMIT_SHA}" \
  --arg prev "${PREVENTION}" \
  --argjson files "${FILES_TOUCHED_JSON}" \
  --argjson tests "${TESTS_ADDED_JSON}" \
  '{summary:$sum, root_cause:$rc, fix:$fix, commit_sha:$sha, prevention:$prev, files_touched:$files, tests_added:$tests}')

retry_curl -s -X POST "${TENANT_DB_URL}/rest/v1/rpc/open_resolution_ticket" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"p_original_ticket_id\": ${TICKET_ID},
    \"p_resolution\": ${RESOLUTION},
    \"p_agent_name\": \"{{AGENT_IDENTITY}}\"
  }"
```

`open_resolution_ticket`:
1. Writes structured `tickets.resolution` JSONB on the original (powers `find_similar_resolved`).
2. Creates a companion `type='resolution'` ticket linked via `parent_ticket_id`.
3. Sets `state='done'` + records commit_sha in metadata.
4. Clears `agent_presence.current_ticket_id`.

### Variant B — ship to QA gate (`needs-qa` label present)

Work isn't done until QA passes. Hand off to `ready_to_test` instead of `done`:

```bash
retry_curl -s -X POST "${TENANT_DB_URL}/rest/v1/rpc/release_ticket" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"p_ticket_id\": ${TICKET_ID},
    \"p_agent_name\": \"{{AGENT_IDENTITY}}\",
    \"p_kind\": \"ship-to-qa\"
  }"

retry_curl -s -X PATCH "${TENANT_DB_URL}/rest/v1/tickets?id=eq.${TICKET_ID}" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{
    \"state\": \"ready_to_test\",
    \"metadata\": {
      \"commitSha\": \"${COMMIT_SHA}\",
      \"qaOriginalAssignee\": \"{{AGENT_IDENTITY}}\",
      \"draftResolution\": ${RESOLUTION}
    }
  }"
```

After QA passes, the QA agent calls `open_resolution_ticket` with the merged resolution.

## Step 7 — Return

Return a structured `epic_result` to Temo (see `ORCHESTRATION_CONTRACT.md § Epic result`):

```json
{
  "kind": "epic_result",
  "ticket_id": 1234,
  "status": "shipped" | "shipped_to_qa" | "wrong_scope" | "blocked_external" | "blocked_internal" | "asked_user" | "failed",
  "commit_sha": "<sha>" | null,
  ...
}
```

## Failure modes

### Claim race — `already_claimed`

Skip, move to next ticket. Don't error.

### `claim_and_dispatch` fails with 5xx

`retry_curl` already retried 5x with backoff. If still failing, the RPC is broken or DB is down. Return `{status: 'failed', reasoning: 'claim_rpc_5xx', ticket_id}`. Chuvak escalates.

### `open_resolution_ticket` fails after work shipped

Critical — work is done but state not updated. Retry once with fresh resolution. If still failing, fall back to direct PATCH:

```bash
retry_curl -X PATCH "${TENANT_DB_URL}/rest/v1/tickets?id=eq.${TICKET_ID}" \
  -H "apikey: ${TENANT_SERVICE_ROLE_KEY}" \
  -H "Authorization: Bearer ${TENANT_SERVICE_ROLE_KEY}" \
  -d "{\"state\":\"done\",\"metadata\":{\"commitSha\":\"${COMMIT_SHA}\",\"resolutionPending\":true}}"
```

Then file a follow-up task: "Backfill resolution for ticket ${TICKET_ID} — RPC failed at ship time."

### Worktree cleanup

If you ran with worktree isolation, clean up post-ship:

```bash
git worktree list | grep "${TICKET_ID}" && git worktree remove --force <path>
```

## Production deploy gate

Every epic agent defers production deployment to an explicit per-deploy authorization comment. Default working scope is the configured non-prod environment (per `agents.config.yaml`).

If a ticket's acceptance criteria imply a prod-targeted action (live DB migration, prod CF Worker deploy, prod DNS change, billing-account write, etc.):

1. STOP before executing the gated step.
2. PATCH `state='awaiting_approval'`, set `metadata.awaitingProdDeploy=true`, comment summarizing the change.
3. Return `status='asked_user'` with the decision ticket id.

Authorization is the configured approver commenting the exact phrase (or unambiguous equivalent that names "production" AND the ticket id). Generic "yes, ship it" does not count.

See `APPROVAL_GATES.md` for the full list of gated categories.

## Variables to substitute

When the install step copies a template into your tenant's `.claude/agents/`, replace:

| Placeholder              | Example                                          |
|--------------------------|--------------------------------------------------|
| `{{AGENT_NAME}}`         | `SERVER`, `CONTENT`, `QA`                        |
| `{{AGENT_KEY}}`          | `server`, `content`, `qa`                        |
| `{{AGENT_IDENTITY}}`     | `server-agent@acme.example.com`                  |
| `{{TENANT_WORKSPACE_ID}}`| `69e5911201b0ef47b675463f`                       |
| `{{TENANT_API_URL}}`     | `https://api.acme.example.com`                   |
| `{{TENANT_OWNER_EMAIL}}` | `owner@acme.example.com`                         |
| `${TICKET_ID}`           | the integer ticket id at runtime                 |
| `${COMMIT_SHA}`          | `git rev-parse HEAD` after work commit           |
