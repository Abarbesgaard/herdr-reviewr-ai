#!/usr/bin/env bash
# Fetch + render the production-freshness rows for the dashboard. Called plainly
# for the first paint and as `gen.sh --loop` by fzf's reload bind, which waits
# the refresh INTERVAL, re-fetches, and repaints. Output is NUL-separated fzf
# items (see prod_render_rows); a short-lived cache keeps repaints instant.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config
prod_seed_repos

mkdir -p "$STATE_DIR"
RAW="$STATE_DIR/rows.tsv"     # last raw fetch (repo days ahead prs sha when)

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

fetch() { prod_fetch_all > "$RAW.tmp" 2>/dev/null && mv "$RAW.tmp" "$RAW"; }

mode="${1:-}"
if [[ "$mode" == "--loop" ]]; then
  [[ -s "$RAW" ]] || fetch
  sleep "${INTERVAL:-120}"
  fetch
else
  fetch
fi

prod_render_rows < "$RAW"
