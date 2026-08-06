#!/usr/bin/env bash
# Check out a chosen PR and open the work workspace for it. Order matters for
# perceived speed: the workspace is created and focused FIRST (instant), then the
# slow `gh pr checkout` runs behind the now-visible window, then the reviewer:
#   1. stash a dirty tree (fast, local) so the checkout can proceed
#   2. new workspace, cwd = clone, label = "repo #num"  → left pane "agent"
#   3. gh pr checkout <number>  in the repo's local clone
#      3b. restore the auto-stash (conflict-safe) onto the PR branch
#   4. right pane "reviewer" (per $REVIEWER — the persiyanov.reviewr plugin)
#   5. focus the agent pane and launch $AGENT_CMD
# The reviewer's PR tab then lands on this very PR, since the branch is checked
# out before the reviewer pane opens.
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

# ---- 1. stash a dirty tree so the checkout can proceed (fast, local) ---------
# The clone may carry uncommitted work. Rather than refuse (which left the user
# staring at a row that "did nothing"), stash it — including untracked files —
# under a labelled ref, switch to the PR, then try to restore it afterwards.
did_stash=0
orig_branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet \
   || [[ -n "$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
  stash_msg="herdr-prs autostash: ${orig_branch:-detached} $(date +%Y-%m-%dT%H:%M:%S)"
  if git -C "$path" stash push -u -m "$stash_msg" >/dev/null 2>&1; then
    did_stash=1
    "$H" notify "herdr-prs: stashed local changes in ${path##*/} before opening PR #$number" 2>/dev/null || true
  else
    "$H" notify "herdr-prs: could not stash ${path##*/}; opening PR #$number without switching branch" 2>/dev/null || true
    echo "stash failed in $path" >&2
  fi
fi

# ---- 2. open the workspace FIRST so it appears instantly ---------------------
# The slow part is `gh pr checkout` (API + git fetch, ~1-2s). Creating the
# workspace + agent pane up front and focusing it means the user lands in their
# work window immediately; the checkout and the reviewer pane follow a moment
# later, in the already-visible workspace, instead of blocking on a dead frame.
label="${repo##*/} #$number"
ws_json="$("$H" workspace create --cwd "$path" --label "$label" --focus)" || {
  echo "workspace create failed" >&2; exit 1;
}
agent_pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty')"
if [[ -z "$agent_pane" ]]; then
  echo "could not read new pane id" >&2; printf '%s\n' "$ws_json" >&2; exit 1
fi
"$H" pane rename "$agent_pane" "agent" >/dev/null 2>&1 || true

# ---- 3. check out the PR branch (the slow bit, now behind a visible window) --
# `gh pr checkout` acts on the CURRENT git repo, so it MUST run inside the clone
# — otherwise it checks out into whatever dir the dashboard happened to sit in
# (or fails), the clone stays on its old branch, and the reviewer, which resolves
# the PR from the checked-out branch name, shows nothing.
if ! ( cd "$path" && gh pr checkout "$number" --repo "$repo" ) 2>/dev/null; then
  # Fall back without --repo (older gh where checkout rejects the flag).
  ( cd "$path" && gh pr checkout "$number" ) || {
    "$H" notify "herdr-prs: gh pr checkout $repo#$number failed" 2>/dev/null || true
    echo "gh pr checkout failed" >&2
  }
fi

# ---- 3b. restore the auto-stash onto the PR branch (conflict-safe) -----------
# If we stashed in step 1, try to re-apply it. A clean pop puts the user's work
# back on top of the PR; a conflicting pop is rolled back (reset --hard) so the
# PR stays clean for review and the changes remain safe in the stash list.
if [[ "$did_stash" == 1 ]]; then
  if git -C "$path" stash pop >/dev/null 2>&1; then
    "$H" notify "herdr-prs: restored your stashed changes onto PR #$number" 2>/dev/null || true
  else
    git -C "$path" reset --hard >/dev/null 2>&1 || true
    "$H" notify "herdr-prs: your changes conflict with PR #$number — kept safe in the stash. Restore with: git -C $path stash pop" 2>/dev/null || true
    echo "stash pop conflicted; changes preserved in stash (git -C $path stash list)" >&2
  fi
fi

# ---- 4. reviewer pane on the right ------------------------------------------
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

# ---- 5. focus the agent pane and launch the agent ---------------------------
"$H" pane focus --direction left >/dev/null 2>&1 || true
[[ -n "${AGENT_CMD:-}" ]] && "$H" pane run "$agent_pane" "$AGENT_CMD" >/dev/null 2>&1 || true
