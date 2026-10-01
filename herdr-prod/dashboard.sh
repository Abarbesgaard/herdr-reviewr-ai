#!/usr/bin/env bash
# The live production-freshness list, run inside the dashboard workspace's pane.
# fzf shows the rows from gen.sh, auto-refreshes every $INTERVAL seconds, and on
# Enter lists that repo's merged-but-undeployed PRs (drill.sh) — without closing
# itself.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config
mkdir -p "$STATE_DIR"

header=$'red: ≥'"${PROD_STALE_DAYS:-7}"$'d since prod   ·   ↑N: commits ahead   ·   N PR: merged, not shipped   ·   j/k or ↑/↓: move   ·   enter: approval-gate deploys   ·   ctrl-p: undeployed PRs   ·   ctrl-e: pick repos   ·   ctrl-r: refresh   ·   esc: hide'

# Neutralise any global --height/--border from FZF_DEFAULT_OPTS: --height forces
# inline mode and a --border leaves ghost top-border rows stacking on reload.
export FZF_DEFAULT_OPTS="$(printf '%s' "${FZF_DEFAULT_OPTS:-}" \
  | sed -E 's/--height[=[:space:]]+[0-9]+%?//g; s/--border(=[a-z-]+)?//g')"

# Columns are TAB-delimited: {1}=owner/repo {2}=last-deploy-iso {3}=display.
# Show only {3}; act on {1}/{2} on Enter. Rows arrive NUL-separated (--read0).
while true; do
  fzf --ansi --no-sort --read0 --border=none --layout=reverse --info=inline \
      --delimiter='\t' --with-nth='3..' \
      --prompt='Prod ▸ ' --header="$header" --header-first \
      --bind 'j:down,k:up,g:first,G:last,ctrl-d:half-page-down,ctrl-u:half-page-up' \
      --bind "start:reload(bash $HERE/gen.sh)" \
      --bind "load:reload(bash $HERE/gen.sh --loop)" \
      --bind "ctrl-r:reload(bash $HERE/gen.sh)" \
      --bind "ctrl-e:execute(bash $HERE/pick-repos.sh)+reload(bash $HERE/gen.sh)" \
      --bind "enter:execute-silent(bash $HERE/open-gate.sh {1})" \
      --bind "ctrl-p:execute(bash $HERE/drill.sh {1} {2})" \
      --bind "ctrl-o:execute-silent(gh browse --repo {1} deployments 2>/dev/null || gh repo view {1} --web)" \
    || true
  # esc / ctrl-c drops out of fzf; re-open so the dashboard pane stays live.
  sleep 0.2
done
