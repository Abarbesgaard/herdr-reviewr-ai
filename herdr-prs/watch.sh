#!/usr/bin/env bash
# The dashboard's background watcher. A detached singleton that polls GitHub
# /notifications for the configured repos and, on a change:
#   (a) raises a herdr toast for new PR comments/reviews (reasons in
#       PRS_NOTIFY_REASONS), and
#   (b) nudges the fzf list to repaint (via its --listen socket) so the CI
#       glyphs refresh on their own, without a manual ctrl-r.
# Inspiration: reviewr's PR poll (src/lib.rs PR_POLL = 1 min) — one fetch at a
# time, latest-wins, a fixed floor cadence. GitHub asks pollers for >= 60s
# (X-Poll-Interval), so the interval is clamped there. A per-thread watermark
# (notify.seen) dedupes, and the FIRST cycle seeds it silently so the existing
# unread backlog never floods the screen. GET /notifications is read-only — it
# never marks anything read, so your github.com inbox is untouched.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

[[ "${PRS_WATCH:-1}" == 1 ]] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

mkdir -p "$STATE_DIR"
LOCK="$STATE_DIR/watch.lock"
SEEN="$STATE_DIR/notify.seen"
PORT_FILE="$STATE_DIR/fzf.port"

# Singleton: a lock DIR (atomic mkdir). If another watcher holds it, step aside.
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# GitHub asks for >= 60s between /notifications polls; never go under it.
poll="${INTERVAL:-60}"; (( poll < 60 )) && poll=60
reasons=",${PRS_NOTIFY_REASONS:-},"
repos_json="$(prs_repo_list_json)"

# The dashboard pane still alive? When it's gone, the watcher has nothing to
# feed — exit so we don't leave an orphan poller running forever.
pane_alive() {
  herdr pane list 2>/dev/null \
    | jq -e --arg l "${WS_LABEL:-PRs}" '.result.panes[]? | select(.label==$l)' >/dev/null 2>&1
}

# Poke the fzf list to re-run gen.sh via its --listen HTTP control socket. The
# port is written by dashboard.sh's start bind; absent it, we simply skip (the
# INTERVAL loop still refreshes on its own).
nudge_reload() {
  local port; [[ -f "$PORT_FILE" ]] || return 0
  port="$(<"$PORT_FILE")"; [[ -n "$port" ]] || return 0
  local hdr=()
  [[ -n "${FZF_API_KEY:-}" ]] && hdr=(-H "X-API-Key: $FZF_API_KEY")
  curl -s -m 2 "${hdr[@]}" -XPOST "localhost:$port" \
    -d "reload(bash $HERE/gen.sh)" >/dev/null 2>&1 || true
}

first=1
while true; do
  pane_alive || break

  body="$(gh api /notifications 2>/dev/null)" || body=""
  if [[ -n "$body" ]]; then
    if [[ "$first" == 1 && ! -s "$SEEN" ]]; then
      # First cycle with no history: baseline silently so the current unread
      # backlog isn't announced as if it just arrived.
      printf '%s' "$body" | prs_notify_watermarks > "$SEEN" 2>/dev/null || true
    else
      new="$(printf '%s' "$body" | prs_notify_new "$SEEN" "$repos_json")"
      if [[ -n "$new" ]]; then
        nudge_reload   # something changed — refresh the glyphs now
        while IFS=$'\t' read -r _id reason repo num title _updated; do
          [[ -z "$reason" ]] && continue
          [[ "$reasons" == *",$reason,"* ]] || continue   # toast only chosen reasons
          num_sfx=""; [[ -n "$num" ]] && num_sfx=" #$num"
          herdr notification show "${repo##*/}${num_sfx}: ${reason//_/ }" \
            --body "$title" --position top-right \
            --sound "${PRS_NOTIFY_SOUND:-request}" >/dev/null 2>&1 || true
        done <<< "$new"
      fi
      # Rebuild the watermark file from the current unread set (prunes threads
      # that were read or dropped off, keeping notify.seen bounded).
      printf '%s' "$body" | prs_notify_watermarks > "$SEEN.tmp" 2>/dev/null \
        && mv "$SEEN.tmp" "$SEEN"
    fi
  fi

  first=0
  sleep "$poll"
done
