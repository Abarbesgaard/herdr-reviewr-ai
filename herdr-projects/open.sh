#!/usr/bin/env bash
# Build the workspace layout for a chosen project:
#   - new workspace, cwd = project root, label = project name
#   - left  pane "agent"    (runs $AGENT_CMD)
#   - right pane "reviewer" (per $REVIEWER: a herdr plugin pane, a command, or a shell)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HERDR_BIN_PATH:-herdr}"

project="${1:?usage: open.sh <project-dir>}"
name="$(basename "$project")"

# ---- config -----------------------------------------------------------------
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr}"
CONFIG_FILE="$CONFIG_DIR/config.sh"
AGENT_CMD="command copilot"
REVIEWER="plugin:persiyanov.reviewr:pane"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ---- 1. new workspace at the project root -----------------------------------
ws_json="$("$H" workspace create --cwd "$project" --label "$name" --focus)" || {
  echo "workspace create failed" >&2; exit 1;
}
agent_pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')"
if [[ -z "$agent_pane" ]]; then
  echo "could not read new pane id" >&2
  printf '%s\n' "$ws_json" >&2
  exit 1
fi
"$H" pane rename "$agent_pane" "agent" >/dev/null 2>&1 || true

# ---- 2. reviewer pane on the right ------------------------------------------
case "$REVIEWER" in
  plugin:*)
    spec="${REVIEWER#plugin:}"          # e.g. persiyanov.reviewr:pane
    plugin_id="${spec%%:*}"             # persiyanov.reviewr
    entry="${spec#*:}"                  # pane
    [[ "$entry" == "$spec" ]] && entry="pane"
    "$H" plugin pane open \
      --plugin "$plugin_id" --entrypoint "$entry" \
      --placement split --target-pane "$agent_pane" --direction right \
      --cwd "$project" --no-focus >/dev/null 2>&1 || true
    ;;
  cmd:*)
    rj="$("$H" pane split "$agent_pane" --direction right --ratio 0.5 --cwd "$project" --no-focus)"
    rp="$(printf '%s' "$rj" | jq -r '.result.pane.pane_id // empty')"
    if [[ -n "$rp" ]]; then
      "$H" pane rename "$rp" "reviewer" >/dev/null 2>&1 || true
      "$H" pane run "$rp" "${REVIEWER#cmd:}" >/dev/null 2>&1 || true
    fi
    ;;
  *)  # shell
    rj="$("$H" pane split "$agent_pane" --direction right --ratio 0.5 --cwd "$project" --no-focus)"
    rp="$(printf '%s' "$rj" | jq -r '.result.pane.pane_id // empty')"
    [[ -n "$rp" ]] && "$H" pane rename "$rp" "reviewer" >/dev/null 2>&1 || true
    ;;
esac

# ---- 3. focus the agent pane and launch the agent ---------------------------
"$H" pane focus --direction left >/dev/null 2>&1 || true
if [[ -n "${AGENT_CMD:-}" ]]; then
  "$H" pane run "$agent_pane" "$AGENT_CMD" >/dev/null 2>&1 || true
fi
