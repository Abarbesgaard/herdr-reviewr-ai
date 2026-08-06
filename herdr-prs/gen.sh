#!/usr/bin/env bash
# Fetch + render the PR rows for the dashboard (called by fzf's reload). Prints
# TSV rows, oldest first, NEW-marked against the session baseline in $SEEN_FILE.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-prs}"
SEEN_FILE="$STATE_DIR/seen.keys"

prs_fetch_all | prs_render_rows "$SEEN_FILE"
