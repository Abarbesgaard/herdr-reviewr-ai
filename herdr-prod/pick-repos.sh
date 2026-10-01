#!/usr/bin/env bash
# Interactive repo picker for the production-freshness dashboard. Lists every
# repo the configured team can see, pre-marks the ones you already watch, and
# writes your selection back to $REPOS_FILE. This list is INDEPENDENT from the
# PR dashboard's — editing here never touches herdr-prs.
#
#   space/tab   toggle a repo
#   Enter       save the selection
#   Esc         cancel (leaves the watch list untouched)
#
# Config (config.sh): PICK_ORG / PICK_TEAM choose the pool. Empty PICK_TEAM ⇒
# every repo you can access in PICK_ORG.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config
prod_seed_repos

: "${PICK_ORG:=vippsas}"
: "${PICK_TEAM:=team-risky-business}"

# Repos already watched (owner/repo, one per line) — used to pre-mark the list.
current="$(prod_repos | sort -u)"

fetch_pool() {
  if [[ -n "$PICK_TEAM" ]]; then
    gh api "orgs/$PICK_ORG/teams/$PICK_TEAM/repos" --paginate \
      -q '.[] | "\(.role_name)\t\(.full_name)"'
  else
    gh api "orgs/$PICK_ORG/repos" --paginate \
      -q '.[] | "\(.permissions.admin // false | if . then "owner" else "member" end)\t\(.full_name)"'
  fi
}

rank() { case "$1" in owner) echo 1 ;; write|member) echo 2 ;; read) echo 3 ;; *) echo 4 ;; esac; }

# Rows (TAB): sortkey  owner/repo  DISPLAY. Watched repos are forced to the top
# (sortkey 0) so we can pre-select exactly the first N — making the picker
# additive. Watched repos absent from the pool are kept as synthetic rows so a
# save never silently drops them.
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

ncur="$(grep -cE $'\t● ' <<<"$rows" || true)"
preselect="pos(1)"
for (( n=0; n<ncur; n++ )); do preselect="$preselect+select+down"; done

header=$'● = watched (pre-checked)   ·   j/k or ↑/↓: move   ·   space/tab: add·remove   ·   ctrl-a/ctrl-d: all/none   ·   ENTER: save   ·   esc: cancel'
selected="$(
  printf '%s\n' "$rows" \
  | fzf --multi --ansi --layout=reverse --info=inline --sync \
        --delimiter='\t' --with-nth='2' \
        --marker='●' --pointer='▸' \
        --prompt='watch ▸ ' --header="$header" --header-first \
        --bind 'j:down,k:up,g:first,G:last,ctrl-d:deselect-all,ctrl-a:select-all' \
        --bind 'space:toggle+down,tab:toggle+down,shift-tab:toggle+up' \
        --bind "start:${preselect}+first" \
  | cut -f1
)" || { echo "Cancelled — watch list unchanged." >&2; exit 0; }

if [[ -z "$selected" ]]; then
  echo "Nothing selected — watch list unchanged." >&2
  exit 0
fi

tmp="$(mktemp)"
{
  echo "# herdr-prod watch list — written by pick-repos.sh on $(date '+%Y-%m-%d %H:%M')."
  echo "# One owner/repo per line."
  echo
  printf '%s\n' "$selected"
} > "$tmp"

mv "$tmp" "$REPOS_FILE"
n="$(grep -cvE '^\s*(#|$)' "$REPOS_FILE")"
echo "Saved $n repo(s) to $REPOS_FILE." >&2
