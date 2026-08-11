#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# reindex.sh — Restore the SonarQube global Issues page after cancelled/failed
#               ISSUE_SYNC background tasks.
#
# Background
# ----------
# When SonarQube is restarted (e.g. after an upgrade or redeploy) it queues
# one ISSUE_SYNC background task per project branch/PR to rebuild its
# Elasticsearch index. If any of those tasks end up CANCELED or FAILED, the
# global Issues page is blocked with:
#   "SonarQube Server is reindexing project data. This page is unavailable
#    until this process is complete."
#
# This script finds every project affected by a CANCELED or FAILED ISSUE_SYNC
# task and calls api/issues/reindex for each one, which re-queues the indexing
# work. Because api/issues/reindex operates at the project level (not per
# branch), a single call covers every branch and PR for that project.
#
# Requirements: curl, jq
#
# Usage
# -----
#   export SONAR_HOST_URL=https://sonarqube.example.com
#   export SONAR_TOKEN=squ_...          # token with Administer System permission
#   bash reindex.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# ── configuration ─────────────────────────────────────────────────────────────

# Required — set these before running (or export them in your shell)
SONAR_HOST_URL="${SONAR_HOST_URL:?Set SONAR_HOST_URL before running this script}"
SONAR_TOKEN="${SONAR_TOKEN:?Set SONAR_TOKEN before running this script}"

# Number of tasks to fetch per page from api/ce/activity (max 100)
PAGE_SIZE=100

# Seconds to pause between consecutive api/issues/reindex calls.
# Keeps the CE task queue from being flooded all at once.
REINDEX_DELAY=1

# ── helpers ───────────────────────────────────────────────────────────────────

# Verify that curl and jq are available before doing any real work.
check_deps() {
    local missing=()
    for cmd in curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: missing required tools: ${missing[*]}" >&2
        exit 1
    fi
    return 0
}

# Authenticated GET — passes the token as HTTP Basic auth (user=token, password
# empty), which is the SonarQube Web API convention.
api_get() {
    curl -sf -u "${SONAR_TOKEN}:" "$@"
    return $?
}

# Authenticated POST — same auth convention; returns only the HTTP status code
# so callers can check success/failure without parsing a body.
api_post() {
    curl -s -o /dev/null -w "%{http_code}" -X POST -u "${SONAR_TOKEN}:" "$@"
    return $?
}

# ── main ──────────────────────────────────────────────────────────────────────

check_deps

echo "=== SonarQube ISSUE_SYNC reindex script ==="
echo "Host: $SONAR_HOST_URL"
echo ""

# ── Step 1: discover affected projects ────────────────────────────────────────
#
# api/ce/activity returns background task history. We filter for ISSUE_SYNC
# tasks (the type used for post-startup project reindexing) that ended in
# CANCELED or FAILED state.
#
# The API is paginated (max 100 results per page), so we loop until we have
# collected every matching task. For each task we extract the componentKey
# (project key). Multiple tasks can share the same project key (one per branch
# or PR), so we deduplicate — api/issues/reindex only needs to be called once
# per project regardless of how many branches are affected.

echo "Step 1 — Fetching canceled/failed ISSUE_SYNC tasks from api/ce/activity ..."

declare -A seen_keys   # associative array used for deduplication
project_keys=()        # ordered list of unique project keys to reindex
page=1
total=0
fetched=0

while true; do
    url="${SONAR_HOST_URL}/api/ce/activity?status=CANCELED,FAILED&type=ISSUE_SYNC&ps=${PAGE_SIZE}&p=${page}"
    response=$(api_get "$url") || {
        echo "ERROR: could not reach ${url}" >&2
        exit 1
    }

    # On the first page, report the grand total so the user knows the scale.
    if [[ "$page" -eq 1 ]]; then
        total=$(printf '%s' "$response" | jq -r '.paging.total')
        echo "  Total canceled/failed ISSUE_SYNC tasks found: $total"
    fi

    count=$(printf '%s' "$response" | jq '.tasks | length')

    # An empty page means we have consumed all results.
    if [[ "$count" -eq 0 ]]; then
        break
    fi

    fetched=$((fetched + count))

    # Extract componentKey from each task and add to the deduplicated list.
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ -z "${seen_keys[$key]+x}" ]]; then
            seen_keys[$key]=1
            project_keys+=("$key")
        fi
    done < <(printf '%s' "$response" | jq -r '.tasks[].componentKey // empty')

    echo "  Page ${page}: ${count} tasks fetched — ${#project_keys[@]} unique projects so far"

    # Stop if we have fetched everything.
    if [[ "$fetched" -ge "$total" ]]; then
        break
    fi

    page=$((page + 1))
done

echo ""
total_projects=${#project_keys[@]}
echo "  Unique projects requiring reindex: $total_projects"
echo ""

if [[ "$total_projects" -eq 0 ]]; then
    echo "Nothing to do — no canceled/failed ISSUE_SYNC tasks found."
    echo "The global Issues page should already be available."
    exit 0
fi

# ── Step 2: reindex each affected project ─────────────────────────────────────
#
# api/issues/reindex (POST) triggers a new ISSUE_SYNC background task for the
# given project. Crucially, it covers every branch and PR of that project in a
# single call — there is no need to loop over individual branches.
#
# A short delay between calls (REINDEX_DELAY) avoids submitting hundreds of
# tasks simultaneously and overwhelming the Compute Engine queue.
#
# The global Issues page will become available once all newly queued ISSUE_SYNC
# tasks have completed. Progress can be monitored in SonarQube under
# Administration > Background Tasks.

echo "Step 2 — Triggering api/issues/reindex for each project ..."
echo ""

success=0
failed=0
failed_keys=()

for key in "${project_keys[@]}"; do
    http_status=$(api_post \
        --data-urlencode "project=${key}" \
        "${SONAR_HOST_URL}/api/issues/reindex")

    if [[ "$http_status" == 2* ]]; then
        echo "  [OK  ] ($((success + failed + 1))/${total_projects}) ${key}"
        success=$((success + 1))
    else
        echo "  [FAIL] ($((success + failed + 1))/${total_projects}) ${key}  (HTTP ${http_status})"
        failed=$((failed + 1))
        failed_keys+=("$key")
    fi

    # Brief pause before the next call.
    sleep "$REINDEX_DELAY"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo "  Reindexed OK : $success"
echo "  Failed       : $failed"

if [[ ${#failed_keys[@]} -gt 0 ]]; then
    echo ""
    echo "The following projects could not be reindexed."
    echo "Check that the token has Administer System permission and that the"
    echo "project key is still valid, then rerun the script or call"
    echo "api/issues/reindex manually for each one:"
    printf '  - %s\n' "${failed_keys[@]}"
    exit 1
fi

echo ""
echo "All reindex tasks have been queued successfully."
echo "The global Issues page will become available once SonarQube finishes"
echo "processing the new ISSUE_SYNC tasks. Monitor progress at:"
echo "  ${SONAR_HOST_URL}/admin/background_tasks?taskType=ISSUE_SYNC"
