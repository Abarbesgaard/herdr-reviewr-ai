#!/usr/bin/env bash
# Background CI enrichment for the dashboard. Fetches the (slow) statusCheckRollup
# for every configured repo and writes the reduced state cache that gen.sh reads:
#   $STATE_DIR/ci.cache : "repo#num<TAB>STATE"  (STATE ∈ FAILURE/PENDING/SUCCESS/NONE)
# Written atomically at the end so gen.sh never sees a half-built cache. A mkdir
# lock keeps only one enrich running at a time.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-prs}"
mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/ci.cache"
LOCK="$STATE_DIR/enrich.lock"

# Non-blocking lock: mkdir is atomic. Bail if another enrich holds it.
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

prs_ci_states > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
