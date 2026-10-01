#!/usr/bin/env bash
# Action entrypoint (bind to e.g. prefix+shift+p): focus the persistent
# production-freshness dashboard workspace, creating it — with its live list —
# the first time.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config
H="${HERDR_BIN_PATH:-herdr}"

ws_id="$("$H" workspace list 2>/dev/null \
  | jq -r --arg label "$WS_LABEL" '.result.workspaces[]? | select(.label==$label) | .workspace_id' \
  | head -n1)"

if [[ -n "$ws_id" ]]; then
  "$H" workspace focus "$ws_id" >/dev/null 2>&1 || true
  exit 0
fi

ws_json="$("$H" workspace create --label "$WS_LABEL" --focus)" || {
  echo "workspace create failed" >&2; exit 1;
}
pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')"
if [[ -z "$pane" ]]; then
  echo "could not read dashboard pane id" >&2; printf '%s\n' "$ws_json" >&2; exit 1
fi
"$H" pane rename "$pane" "Prod" >/dev/null 2>&1 || true
"$H" pane run "$pane" "exec bash $HERE/dashboard.sh" >/dev/null 2>&1 || true
