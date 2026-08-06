#!/usr/bin/env bash
# Check out a chosen PR and open the work workspace for it:
#   1. gh pr checkout <number>  in the repo's local clone
#   2. new workspace, cwd = clone, label = "repo #num"
#   3. left  pane "agent"    (runs $AGENT_CMD)
#   4. right pane "reviewer" (per $REVIEWER — the persiyanov.reviewr plugin by default)
# The reviewer's PR tab then lands on this very PR, since the branch is checked out.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config
H="${HERDR_BIN_PATH:-herdr}"

repo="${1:?usage: open-pr.sh <owner/repo> <number> <localpath>}"
number="${2:?missing PR number}"
path="${3:-}"

# Resolve the local clone if the row carried no path.
[[ -z "$path" ]] && path="$(prs_resolve_path "$repo")"
if [[ -z "$path" || ! -d "$path" ]]; then
  "$H" notify "herdr-prs: no local clone for $repo — add its path to repos.conf" 2>/dev/null || true
  echo "no local clone for $repo" >&2
  exit 1
fi

# ---- 1. check out the PR branch ---------------------------------------------
if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet; then
  "$H" notify "herdr-prs: $path has uncommitted changes — not switching branches" 2>/dev/null || true
  echo "uncommitted changes in $path; refusing to switch" >&2
  exit 1
fi
if ! gh pr checkout "$number" --repo "$repo" 2>/dev/null; then
  # Fall back to running inside the clone (older gh without --repo on checkout).
  ( cd "$path" && gh pr checkout "$number" ) || {
    "$H" notify "herdr-prs: gh pr checkout $repo#$number failed" 2>/dev/null || true
    echo "gh pr checkout failed" >&2; exit 1;
  }
fi

# ---- 2. new workspace at the clone ------------------------------------------
label="${repo##*/} #$number"
ws_json="$("$H" workspace create --cwd "$path" --label "$label" --focus)" || {
  echo "workspace create failed" >&2; exit 1;
}
agent_pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')"
if [[ -z "$agent_pane" ]]; then
  echo "could not read new pane id" >&2; printf '%s\n' "$ws_json" >&2; exit 1
fi
"$H" pane rename "$agent_pane" "agent" >/dev/null 2>&1 || true

# ---- 3. reviewer pane on the right ------------------------------------------
case "$REVIEWER" in
  plugin:*)
    spec="${REVIEWER#plugin:}"; plugin_id="${spec%%:*}"; entry="${spec#*:}"
    [[ "$entry" == "$spec" ]] && entry="pane"
    "$H" plugin pane open \
      --plugin "$plugin_id" --entrypoint "$entry" \
      --placement split --target-pane "$agent_pane" --direction right \
      --cwd "$path" --no-focus >/dev/null 2>&1 || true
    ;;
  cmd:*)
    rj="$("$H" pane split "$agent_pane" --direction right --ratio 0.5 --cwd "$path" --no-focus)"
    rp="$(printf '%s' "$rj" | jq -r '.result.pane.pane_id // empty')"
    if [[ -n "$rp" ]]; then
      "$H" pane rename "$rp" "reviewer" >/dev/null 2>&1 || true
      "$H" pane run "$rp" "${REVIEWER#cmd:}" >/dev/null 2>&1 || true
    fi
    ;;
  *)
    rj="$("$H" pane split "$agent_pane" --direction right --ratio 0.5 --cwd "$path" --no-focus)"
    rp="$(printf '%s' "$rj" | jq -r '.result.pane.pane_id // empty')"
    [[ -n "$rp" ]] && "$H" pane rename "$rp" "reviewer" >/dev/null 2>&1 || true
    ;;
esac

# ---- 4. focus the agent pane and launch the agent ---------------------------
"$H" pane focus --direction left >/dev/null 2>&1 || true
[[ -n "${AGENT_CMD:-}" ]] && "$H" pane run "$agent_pane" "$AGENT_CMD" >/dev/null 2>&1 || true
