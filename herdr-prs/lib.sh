#!/usr/bin/env bash
# herdr-prs shared library: config loading, local-path resolution, and the pure
# PR-rows renderer. Sourced by the generator, the dashboard, and the tests.
# No network here except fetch_prs; everything else is pure and unit-tested.

# --- config ------------------------------------------------------------------

# Load config.sh (defaults + user overrides). HERE must point at the plugin dir.
prs_load_config() {
  : "${HERE:?prs_load_config needs HERE set to the plugin dir}"
  # Defaults first, then the user's copy in the plugin config dir (if any).
  # shellcheck disable=SC1091
  [[ -f "$HERE/config.sh" ]] && source "$HERE/config.sh"
  local cfg="${HERDR_PLUGIN_CONFIG_DIR:-}"
  if [[ -n "$cfg" && -f "$cfg/config.sh" ]]; then
    # shellcheck disable=SC1090
    source "$cfg/config.sh"
  fi
  : "${REPOS_FILE:=$HERE/repos.conf}"
  : "${INTERVAL:=60}"
  : "${WS_LABEL:=PRs}"
  : "${AGENT_CMD:=command copilot}"
  : "${REVIEWER:=plugin:persiyanov.reviewr:pane}"
}

# Read repos.conf → emit "owner/repo<TAB>path" lines, resolving a missing path by
# scanning $ROOTS for a clone whose origin remote ends in owner/repo(.git).
prs_repos() {
  local file="${1:-$REPOS_FILE}"
  [[ -f "$file" ]] || return 0
  local line repo path
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    repo="${line%%$'\t'*}"
    path=""
    [[ "$line" == *$'\t'* ]] && path="${line#*$'\t'}"
    repo="${repo#"${repo%%[![:space:]]*}"}"; repo="${repo%"${repo##*[![:space:]]}"}"
    [[ -z "$repo" ]] && continue
    [[ -z "$path" ]] && path="$(prs_resolve_path "$repo")"
    printf '%s\t%s\n' "$repo" "$path"
  done < "$file"
}

# Find a local clone of owner/repo under $ROOTS. Prints the path or nothing.
prs_resolve_path() {
  local repo="$1" root d url
  for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    for d in "$root"/*/; do
      [[ -e "$d/.git" ]] || continue
      url="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
      case "$url" in
        *"$repo".git|*"$repo") printf '%s' "${d%/}"; return 0 ;;
      esac
    done
  done
  return 0
}

# --- data --------------------------------------------------------------------

# Fetch open, non-draft PRs for one repo, tagging each with its repo + local path.
# Emits a JSON array (possibly empty). Network — not unit-tested.
prs_fetch_one() {
  local repo="$1" path="$2"
  gh pr list --repo "$repo" --state open --limit 100 \
    --json number,title,author,createdAt,isDraft,reviewDecision,statusCheckRollup \
    2>/dev/null \
  | jq -c --arg repo "$repo" --arg lp "$path" \
      'map(select(.isDraft|not) | .repo=$repo | .localpath=$lp)'
}

# Fetch across all configured repos → one combined JSON array on stdout.
prs_fetch_all() {
  local repo path
  {
    while IFS=$'\t' read -r repo path; do
      [[ -z "$repo" ]] && continue
      prs_fetch_one "$repo" "$path"
    done < <(prs_repos)
  } | jq -s 'add // []'
}

# --- rendering (pure) --------------------------------------------------------

# The jq program that turns the combined PR array into fzf TSV rows, oldest first.
# Args: --argjson now <epoch>  --argjson seen <["repo#num", ...]>
# Output columns (TAB): repo  number  localpath  createdAt  DISPLAY
_PRS_JQ='
def age($created):
  ($now - ($created | fromdateiso8601)) as $s
  | if   $s < 60    then "just now"
    elif $s < 3600  then "\(($s/60)   | floor)m"
    elif $s < 86400 then "\(($s/3600) | floor)h"
    else                 "\(($s/86400)| floor)d" end;
def ci($rollup):
  ([ ($rollup // [])[] | (.conclusion // .state // .status) ]) as $c
  | if   ($c | length) == 0 then "·"
    elif ($c | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")) then "✗"
    elif ($c | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "WAITING" or . == null)) then "•"
    else "✓" end;
def review($d):
  {"APPROVED":"approved","CHANGES_REQUESTED":"changes","REVIEW_REQUIRED":"review-needed"}[$d] // "—";
def pad($s; $n): ($s + (" " * ($n - ($s|length)))) | .[0:$n];
sort_by(.createdAt)[]
| ("\(.repo)#\(.number)") as $key
| (if ($seen | index($key)) then "  " else "★ " end) as $new
| [ .repo, (.number|tostring), (.localpath // ""), .createdAt,
    ( $new
      + pad((.repo | sub("^[^/]+/";"")); 34) + " "
      + pad("#\(.number)"; 7) + " "
      + pad(.title; 60) + "  @"
      + pad(.author.login; 20) + " "
      + pad("[" + review(.reviewDecision) + "]"; 16) + " "
      + ci(.statusCheckRollup) + "  "
      + age(.createdAt)
    )
  ] | @tsv
'

# render_rows [seen_file] : stdin = combined PR JSON array → TSV rows.
# NOW_EPOCH overrides "now" (for tests). Missing seen file = everything is NEW.
prs_render_rows() {
  local seen_file="${1:-}" now="${NOW_EPOCH:-$(date +%s)}" seen='[]'
  if [[ -n "$seen_file" && -f "$seen_file" ]]; then
    seen="$(jq -R -s 'split("\n") | map(select(length>0))' < "$seen_file")"
  fi
  jq -r --argjson now "$now" --argjson seen "$seen" "$_PRS_JQ"
}

# prs_keys : stdin = combined PR JSON array → "repo#num" keys, one per line.
prs_keys() {
  jq -r '.[] | "\(.repo)#\(.number)"'
}
