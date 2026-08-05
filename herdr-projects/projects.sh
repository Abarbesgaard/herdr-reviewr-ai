#!/usr/bin/env bash
# Interactive git-project picker (runs in a herdr popup pane).
# Lists git projects under the configured ROOTS, lets you pick one with fzf,
# then hands off to open.sh to build the workspace + panes.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- config -----------------------------------------------------------------
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr}"
CONFIG_FILE="$CONFIG_DIR/config.sh"

# Seed the user config from the plugin default on first run.
if [[ ! -f "$CONFIG_FILE" && -f "$HERE/config.sh" ]]; then
  mkdir -p "$CONFIG_DIR"
  cp "$HERE/config.sh" "$CONFIG_FILE" 2>/dev/null || true
fi

# Defaults (overridden by the user config).
ROOTS=("$HOME/Development")
SCAN_DEPTH=4
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ---- collect projects -------------------------------------------------------
projects=()
while IFS= read -r p; do
  [[ -n "$p" ]] && projects+=("$p")
done < <(
  for root in "${ROOTS[@]}"; do
    root="${root/#\~/$HOME}"
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth "$SCAN_DEPTH" -type d -name .git -prune 2>/dev/null \
      | sed 's#/\.git$##'
  done | sort -u
)

if [[ ${#projects[@]} -eq 0 ]]; then
  echo "No git projects found under: ${ROOTS[*]}"
  echo "Edit $CONFIG_FILE and set ROOTS, then try again."
  read -r -p "Press enter to close..." _ || true
  exit 0
fi

# ---- pick -------------------------------------------------------------------
sel=""
if command -v fzf >/dev/null 2>&1; then
  sel="$(printf '%s\n' "${projects[@]}" \
    | fzf --prompt='project > ' --height=100% --border --no-multi \
          --header='pick a project — enter to open, esc to cancel')" || exit 0
else
  echo "Select a project:"
  select sel in "${projects[@]}"; do [[ -n "${sel:-}" ]] && break; done
fi
[[ -n "${sel:-}" ]] || exit 0

exec "$HERE/open.sh" "$sel"
