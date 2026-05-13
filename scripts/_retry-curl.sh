#!/usr/bin/env bash
# retry_curl — exponential-backoff wrapper for curl calls to your tenant's API.
#
# Usage: source this file, then call retry_curl exactly like curl:
#
#   source .claude/agents/_shared/_retry-curl.sh
#   retry_curl -X POST "$URL" -H "apikey: $KEY" -d '{...}'
#
# Behavior:
#   - 2xx → echo body, return 0
#   - 4xx (except 429) → client error, no retry, return 1, echo body to stderr
#   - 429 → honor Retry-After header, fallback to exp backoff
#   - 5xx / network / timeout → exp backoff with jitter (1,2,4,8,16s), max 5 attempts
#   - Total retry budget ~30s; caller sees either success body or final failure
#
# Also exposes:
#   retry_curl_bg        — fire in background (& suffixed), returns immediately
#   retry_curl_parallel  — fan out a stdin list across N workers
#
# The orchestration contracts (EPIC_AGENT_CONTRACT.md, ORCHESTRATION_CONTRACT.md)
# assume every agent sources this and uses retry_curl for every REST + RPC call.

retry_curl() {
  local max_attempts=5
  local attempt=0
  local wait_seconds=1
  local tmp_headers tmp_body http_code curl_exit retry_after

  tmp_headers=$(mktemp)
  tmp_body=$(mktemp)

  while [ $attempt -lt $max_attempts ]; do
    http_code=$(curl --max-time 15 -sS -D "$tmp_headers" -o "$tmp_body" -w "%{http_code}" "$@" 2>/dev/null)
    curl_exit=$?

    # Network-level failure (connection refused, DNS, timeout)
    if [ $curl_exit -ne 0 ]; then
      attempt=$((attempt + 1))
      [ $attempt -lt $max_attempts ] && sleep $(( wait_seconds + RANDOM % 2 ))
      wait_seconds=$(( wait_seconds * 2 ))
      continue
    fi

    # 2xx success
    if [[ "$http_code" =~ ^2 ]]; then
      cat "$tmp_body"
      rm -f "$tmp_headers" "$tmp_body"
      return 0
    fi

    # 4xx (except 429) — client error, don't retry
    if [[ "$http_code" =~ ^4 ]] && [ "$http_code" != "429" ]; then
      cat "$tmp_body" >&2
      rm -f "$tmp_headers" "$tmp_body"
      return 1
    fi

    # 429 — honor Retry-After header when present
    if [ "$http_code" = "429" ]; then
      retry_after=$(grep -i "^retry-after:" "$tmp_headers" 2>/dev/null | awk '{print $2}' | tr -d '\r\n')
      if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        sleep "$retry_after"
      else
        sleep $(( wait_seconds + RANDOM % 2 ))
      fi
      wait_seconds=$(( wait_seconds * 2 ))
      attempt=$((attempt + 1))
      continue
    fi

    # 5xx — retry with exp backoff
    attempt=$((attempt + 1))
    [ $attempt -lt $max_attempts ] && sleep $(( wait_seconds + RANDOM % 2 ))
    wait_seconds=$(( wait_seconds * 2 ))
  done

  echo "retry_curl: exhausted $max_attempts attempts (last http_code=$http_code)" >&2
  cat "$tmp_body" >&2
  rm -f "$tmp_headers" "$tmp_body"
  return 1
}

# Fire-and-forget variant — returns immediately, caller doesn't block
retry_curl_bg() {
  retry_curl "$@" >/dev/null 2>&1 &
}

# Parallel batch: accepts stdin list of curl argument arrays, fires in parallel
# Usage: echo -e 'arg1 arg2\narg3 arg4' | retry_curl_parallel 16
retry_curl_parallel() {
  local concurrency="${1:-16}"
  xargs -P "$concurrency" -I{} bash -c 'source "'"${BASH_SOURCE[0]}"'"; retry_curl {}'
}

export -f retry_curl
export -f retry_curl_bg
