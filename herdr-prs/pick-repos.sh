#!/usr/bin/env bash
# Interactive repo picker for the PR dashboard. Lists every repo the configured
# team can see (owner/write/read), pre-marks the ones you already monitor, and
# writes your selection back to $REPOS_FILE with local paths resolved.
#
#   Tab       toggle a repo
#   Enter     save the selection
#   Esc       cancel (leaves repos.conf untouched)
#
# Config (config.sh): PICK_ORG / PICK_TEAM choose the pool. If PICK_TEAM is empty
# the pool is every repo you can access in PICK_ORG.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prs_load_config

: "${PICK_ORG:=vippsas}"
: "${PICK_TEAM:=team-risky-business}"

# Repos already monitored (owner/repo, one per line) — used to pre-mark the list.
current="$(prs_repos | cut -f1 | sort -u)"

# The pool of selectable repos, "role<TAB>owner/repo", roles sorted owner→write→read.
fetch_pool() {
  if [[ -n "$PICK_TEAM" ]]; then
    gh api "orgs/$PICK_ORG/teams/$PICK_TEAM/repos" --paginate \
      -q '.[] | "\(.role_name)\t\(.full_name)"'
  else
    gh api "orgs/$PICK_ORG/repos" --paginate \
      -q '.[] | "\(.permissions.admin // false | if . then "owner" else "member" end)\t\(.full_name)"'
  fi
}

# Build fzf rows: field1 = owner/repo (the key), field2 = display with a ● if
# currently monitored. Owner repos first, then write, then read; each group A→Z.
rank() { case "$1" in owner) echo 1 ;; write|member) echo 2 ;; read) echo 3 ;; *) echo 4 ;; esac; }

# Build the row list. Columns (TAB): sortkey  owner/repo  DISPLAY.
# Currently-monitored repos are forced to the TOP (sortkey 0) so we can
# pre-select exactly the first N of them in fzf — that makes the picker
# ADDITIVE: your existing repos stay checked unless you deselect them.
# Any monitored repo that isn't in the team pool is kept as a synthetic row
# so saving never silently drops it.
pool="$(fetch_pool)"
rows="$(
  {
    while IFS=$'\t' read -r role repo; do
      [[ -z "$repo" ]] && continue
      if grep -qxF "$repo" <<<"$current"; then
        printf '0\t%s\t● %-6s %s\n' "$repo" "$role" "$repo"
      else
        printf '%s\t%s\t  %-6s %s\n' "$(rank "$role")" "$repo" "$role" "$repo"
      fi
    done <<<"$pool"
    # Monitored repos absent from the pool → keep them (marked, at the top).
    pool_repos="$(cut -f2 <<<"$pool")"
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      grep -qxF "$repo" <<<"$pool_repos" || \
        printf '0\t%s\t● %-6s %s\n' "$repo" "kept" "$repo"
    done <<<"$current"
  } | sort -t$'\t' -k1,1n -k2,2 | cut -f2,3
)"

if [[ -z "$rows" ]]; then
  echo "No repos found for $PICK_ORG${PICK_TEAM:+/$PICK_TEAM}." >&2
  exit 1
fi

# How many monitored rows sit at the top → pre-select the first N.
ncur="$(grep -cE $'\t● ' <<<"$rows" || true)"
preselect="pos(1)"
for (( n=0; n<ncur; n++ )); do preselect="$preselect+select+down"; done

header=$'● = monitored (pre-checked)   ·   j/k or ↑/↓: move   ·   space/tab: add·remove   ·   ctrl-a/ctrl-d: all/none   ·   ENTER: save   ·   esc: cancel'
selected="$(
  printf '%s\n' "$rows" \
  | fzf --multi --ansi --layout=reverse --info=inline --sync \
        --delimiter='\t' --with-nth='2' \
        --marker='●' --pointer='▸' \
        --prompt='repos ▸ ' --header="$header" --header-first \
        --bind 'j:down,k:up,g:first,G:last,ctrl-d:deselect-all,ctrl-a:select-all' \
        --bind 'space:toggle+down,tab:toggle+down,shift-tab:toggle+up' \
        --bind "start:${preselect}+first" \
  | cut -f1
)" || { echo "Cancelled — repos.conf unchanged." >&2; exit 0; }

if [[ -z "$selected" ]]; then
  echo "Nothing selected — repos.conf unchanged." >&2
  exit 0
fi

# Write the new repos.conf: one "owner/repo<TAB>localpath" per selection.
tmp="$(mktemp)"
{
  echo "# herdr-prs repo list — written by pick-repos.sh on $(date '+%Y-%m-%d %H:%M')."
  echo "# One repo per line: owner/repo, optional TAB + local clone path."
  echo
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    path="$(prs_resolve_path "$repo")"
    if [[ -n "$path" ]]; then printf '%s\t%s\n' "$repo" "$path"; else printf '%s\n' "$repo"; fi
  done <<<"$selected"
} > "$tmp"

mv "$tmp" "$REPOS_FILE"
n="$(grep -cvE '^\s*(#|$)' "$REPOS_FILE")"
echo "Saved $n repo(s) to $REPOS_FILE." >&2
