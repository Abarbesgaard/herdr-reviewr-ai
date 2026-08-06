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

header=$'★ = new since last visit   ·   enter: check out & open work workspace   ·   ctrl-r: refresh   ·   ctrl-o: open on GitHub   ·   esc: hide'

# fzf columns are TAB-delimited: {1}=repo {2}=number {3}=localpath {4}=createdAt
# {5}=display. Show only the display column; act on the hidden 1..3 on Enter.
# The load→sleep→reload chain keeps the current list on screen while it waits,
# then repaints — a self-perpetuating refresh loop.
while true; do
  fzf --ansi --no-sort --layout=reverse --info=inline \
      --delimiter='\t' --with-nth='5..' \
      --prompt='PR ▸ ' --header="$header" --header-first \
      --bind "start:reload(bash $HERE/gen.sh)" \
      --bind "load:reload(sleep ${INTERVAL}; bash $HERE/gen.sh)" \
      --bind "ctrl-r:reload(bash $HERE/gen.sh)" \
      --bind "enter:execute-silent(bash $HERE/open-pr.sh {1} {2} {3})" \
      --bind "ctrl-o:execute-silent(gh pr view {2} --repo {1} --web)" \
    || true
  # esc / ctrl-c drops out of fzf; re-open so the dashboard pane stays live.
  sleep 0.2
done
