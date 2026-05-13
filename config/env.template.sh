#!/usr/bin/env bash
# tenant.env.sh.template — environment variables every agent expects.
#
# Copy to tenant.env.sh, fill in the secrets, add tenant.env.sh to .gitignore,
# and `source tenant.env.sh` in any shell that's going to invoke an agent.
#
# Never commit a filled-in copy of this file.

# Tenant identity ----------------------------------------------------------

export TENANT_WORKSPACE_ID=""                              # primary key in backing store
export TENANT_API_URL="https://api.acme.example.com"       # REST + RPC wrapper
export TENANT_DB_URL="${TENANT_API_URL}/sb"                # path under wrapper that proxies the DB
export TENANT_RAW_DB_URL="https://abc.supabase.co"         # raw Supabase URL — realtime WS only
export TENANT_OWNER_EMAIL="owner@acme.example.com"

# Tenant credentials -------------------------------------------------------
# Service role key gives full DB access scoped to this tenant. Treat like a
# root credential — never log, never paste into prompts, rotate on suspicion.

export TENANT_SERVICE_ROLE_KEY=""                          # fill from secret manager
export TENANT_PUBLISHABLE_KEY=""                           # public anon key (safe to surface)

# QA test account (optional, only if QA Mode B uses it) -------------------

export QA_TEST_USER_EMAIL=""
export QA_TEST_USER_PASSWORD=""

# Channel selection --------------------------------------------------------
# Most tenants only need one channel. If you maintain dev/staging/prod, set
# CHANNEL per-shell before sourcing this file.

export CHANNEL="${CHANNEL:-next}"

# Convenience checks -------------------------------------------------------

for var in TENANT_WORKSPACE_ID TENANT_API_URL TENANT_SERVICE_ROLE_KEY; do
  if [ -z "${!var}" ]; then
    echo "tenant.env.sh: $var is not set — agents will not function" >&2
  fi
done
