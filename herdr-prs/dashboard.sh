#!/usr/bin/env bash
# The live PR list, run inside the dashboard workspace's pane. fzf shows the rows
# from gen.sh, auto-refreshes every $INTERVAL seconds, and on Enter checks out the
# selected PR and opens the work workspace (open-pr.sh) — without closing itself.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

header=$'★ = new since last visit   ·   j/k or ↑/↓: move   ·   g/G: top/bottom   ·   enter: check out & open work   ·   ctrl-e: pick repos   ·   ctrl-r: refresh   ·   ctrl-o: GitHub   ·   type to filter   ·   esc: hide'

# fzf columns are TAB-delimited: {1}=repo {2}=number {3}=localpath {4}=createdAt
# {5}=display. Show only the display column; act on the hidden 1..3 on Enter.
# The load→sleep→reload chain keeps the current list on screen while it waits,
# then repaints — a self-perpetuating refresh loop.

# The dashboard owns the whole pane, so neutralise any global --height/--border
# from the user's FZF_DEFAULT_OPTS: --height forces fzf's inline mode (no
# alt-screen) and with a --border the reload loop leaves ghost top-border rows
# (╭───╮) stacking up the pane on every repaint. Keep the user's colours; drop
# only the two layout-breakers so fzf runs full-window on the alternate screen.
export FZF_DEFAULT_OPTS="$(printf '%s' "${FZF_DEFAULT_OPTS:-}" \
  | sed -E 's/--height[=[:space:]]+[0-9]+%?//g; s/--border(=[a-z-]+)?//g')"

# Background watcher (config PRS_WATCH): open an fzf --listen control socket and
# start watch.sh, which polls GitHub /notifications and POSTs a reload here when
# something changes (new comment/review, CI transition) — so glyphs refresh and
# toasts fire without a manual ctrl-r. The start bind records fzf's chosen port
# ($FZF_PORT) for the watcher. With PRS_WATCH=0 none of this runs: no socket, no
# poller, no toasts — the list refreshes only on the INTERVAL loop and ctrl-r.
mkdir -p "$STATE_DIR"
listen_opt=""
start_bind="start:reload(bash $HERE/gen.sh)"
if [[ "${PRS_WATCH:-1}" == 1 ]]; then
  listen_opt="--listen=0"
  start_bind="${start_bind}+execute-silent(printf %s \"\$FZF_PORT\" > \"$STATE_DIR/fzf.port\")"
  # Detach the watcher so it outlives any single fzf invocation in the loop.
  # It is a singleton (lock dir) and self-exits when this pane goes away.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$HERE/watch.sh" >/dev/null 2>&1 &
  else
    nohup bash "$HERE/watch.sh" >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
fi

while true; do
  fzf --ansi --no-sort --border=none --layout=reverse --info=inline $listen_opt \
      --delimiter='\t' --with-nth='5..' \
      --prompt='PR ▸ ' --header="$header" --header-first \
      --bind 'j:down,k:up,g:first,G:last,ctrl-d:half-page-down,ctrl-u:half-page-up' \
      --bind "$start_bind" \
      --bind "load:reload(bash $HERE/gen.sh --loop)" \
      --bind "ctrl-r:reload(bash $HERE/gen.sh)" \
      --bind "ctrl-e:execute(bash $HERE/pick-repos.sh)+reload(bash $HERE/gen.sh)" \
      --bind "enter:execute-silent(bash $HERE/open-pr.sh {1} {2} {3})" \
      --bind "ctrl-o:execute-silent(gh pr view {2} --repo {1} --web)" \
    || true
  # esc / ctrl-c drops out of fzf; re-open so the dashboard pane stays live.
  sleep 0.2
done
