#!/usr/bin/env bash
# Snapshot the currently-open PR keys as the "seen" baseline. Anything that shows
# up after this (or was already open but is being re-baselined) decides the NEW
# stars in the dashboard. Called by action-open every time the dashboard is
# focused, so stars clear on a visit and only genuinely new PRs light up.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-prs}"
mkdir -p "$STATE_DIR"
SEEN_FILE="$STATE_DIR/seen.keys"

prs_fetch_all | prs_keys > "$SEEN_FILE.tmp" && mv "$SEEN_FILE.tmp" "$SEEN_FILE"
