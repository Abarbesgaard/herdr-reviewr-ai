#!/usr/bin/env bash
# Fetch (cheaply) + render the PR rows for the dashboard. The CI pipeline glyph is
# loaded LAZILY: this prints the list immediately with a spinner where CI isn't
# known yet, kicks a background enrich.sh to fill the CI cache, and — when called
# as `gen.sh --loop` by fzf's reload bind — animates the spinner on a fast cadence
# while loading, then settles to the normal refresh INTERVAL once CI has landed.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-prs}"
mkdir -p "$STATE_DIR"
SEEN_FILE="$STATE_DIR/seen.keys"
CACHE="$STATE_DIR/ci.cache"       # repo#num<TAB>STATE, written by enrich.sh
LIST="$STATE_DIR/list.json"       # last cheap PR fetch, reused between spinner frames
SPIN_FILE="$STATE_DIR/spin.frame"
LOCK="$STATE_DIR/enrich.lock"

FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
mode="${1:-}"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Kick a background CI enrich if none is running and the cache is missing/stale.
kick_enrich() {
  [[ "${PRS_CI:-1}" == 1 ]] || return 0
  [[ -d "$LOCK" ]] && return 0
  local age=999999
  [[ -f "$CACHE" ]] && age=$(( $(date +%s) - $(mtime "$CACHE") ))
  if [[ ! -f "$CACHE" || $age -ge ${INTERVAL:-60} ]]; then
    # Detach so the enrich outlives this gen.sh invocation. setsid where it
    # exists (Linux); nohup+background otherwise (macOS has no setsid).
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$HERE/enrich.sh" >/dev/null 2>&1 &
    else
      nohup bash "$HERE/enrich.sh" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
  fi
}

# Advance the spinner one frame (persisted so successive repaints "spin").
advance_spinner() {
  local f=0
  [[ -f "$SPIN_FILE" ]] && f="$(<"$SPIN_FILE")"
  f=$(( (f + 1) % ${#FRAMES[@]} ))
  printf '%s' "$f" > "$SPIN_FILE"
  export SPIN_FRAME="${FRAMES[$f]}"
}

# Is CI still loading? (PRS_CI on, and some open PR has no cache entry yet.)
is_loading() {
  [[ "${PRS_CI:-1}" == 1 ]] || return 1
  [[ -s "$CACHE" ]] || return 0
  local missing
  missing="$(comm -23 <(prs_keys < "$LIST" | sort -u) <(cut -f1 "$CACHE" | sort -u) | head -1)"
  [[ -n "$missing" ]]
}

render() {
  if [[ "${PRS_CI:-1}" == 1 ]]; then
    prs_ci_merge "$CACHE" < "$LIST" | prs_render_rows "$SEEN_FILE"
  else
    prs_render_rows "$SEEN_FILE" < "$LIST"
  fi
}

fetch_list() { prs_fetch_all > "$LIST.tmp" && mv "$LIST.tmp" "$LIST"; }

if [[ "$mode" == "--loop" ]]; then
  # Reuse the cached list unless it's gone; only re-fetch on the slow cadence.
  [[ -s "$LIST" ]] || fetch_list
  if is_loading; then
    sleep "${SPIN_INTERVAL:-0.5}"      # fast: animate the spinner, catch the cache
  else
    sleep "${INTERVAL:-60}"            # settled: normal refresh
    fetch_list
    kick_enrich
  fi
else
  fetch_list                            # first paint
  kick_enrich
fi

advance_spinner
render
