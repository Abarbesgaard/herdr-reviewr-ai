#!/usr/bin/env bash
# Enter on a repo: list the merged PRs that landed since its last successful prod
# deploy — the work that is waiting to ship. Runs its own fzf; Enter opens the
# chosen PR on GitHub, esc returns to the dashboard.
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config

repo="${1:-}"; since_iso="${2:-}"
[[ -z "$repo" ]] && exit 0

since="${since_iso%T*}"   # YYYY-MM-DD; empty ⇒ no prod deploy recorded
search="is:merged"
title="merged PRs not yet in prod"
if [[ -n "$since" ]]; then
  search="merged:>=$since"
  title="merged since last prod deploy ($since)"
fi

rows="$(gh pr list --repo "$repo" --state merged --search "$search" --limit 100 \
          --json number,title,mergedAt,author \
          --jq '.[] | "#\(.number)\t\(.mergedAt[0:10])\t\(.author.login)\t\(.title)"' \
          2>/dev/null)"

if [[ -z "$rows" ]]; then
  printf '\n  No merged PRs found for %s %s.\n\n  Press enter to go back.' "$repo" "$title" \
    | fzf --ansi --header="$repo — $title" --disabled >/dev/null 2>&1 || true
  exit 0
fi

# Columns: {1}=#num {2}=mergedAt {3}=author {4}=title. Show a compact display.
sel="$(printf '%s\n' "$rows" \
  | awk -F'\t' '{ printf "%s\t\033[2m%s\033[0m  \033[36m%-16s\033[0m  %s\n", $1, $2, $3, $4 }' \
  | fzf --ansi --no-sort --delimiter='\t' --with-nth='2..' \
        --prompt="$repo ▸ " \
        --header="$repo — $title   ·   enter: open on GitHub   ·   esc: back" \
        --bind 'j:down,k:up,g:first,G:last' \
        --bind "ctrl-o:execute-silent(gh pr view {1} --repo $repo --web)" \
    || true)"

num="${sel%%$'\t'*}"; num="${num#\#}"
[[ -n "$num" ]] && gh pr view "$num" --repo "$repo" --web >/dev/null 2>&1 || true
