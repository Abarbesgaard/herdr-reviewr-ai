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
#
# This is the CHEAP fetch — no statusCheckRollup. The CI pipeline glyph is loaded
# LAZILY: the list paints immediately from this, and prs_ci_states (below) fills a
# cache in the background that prs_ci_merge folds back in on the next repaint.
# reviewDecision is the one optional inline field (PRS_REVIEW, off by default);
# its cost scales with a repo's open-PR count.
prs_fetch_one() {
  local repo="$1" path="$2"
  local fields="number,title,author,createdAt,isDraft"
  if [[ "${PRS_RICH:-0}" == 1 || "${PRS_REVIEW:-0}" == 1 ]]; then
    fields="$fields,reviewDecision"
  fi
  gh pr list --repo "$repo" --state open --limit 100 \
    --json "$fields" \
    2>/dev/null \
  | jq -c --arg repo "$repo" --arg lp "$path" \
      'map(select(.isDraft|not) | .repo=$repo | .localpath=$lp)'
}

# Fetch across all configured repos → one combined JSON array on stdout.
# Repos are fetched in parallel (bounded) so the dashboard populates quickly
# instead of waiting on ~N serial `gh` round-trips.
prs_fetch_all() {
  local repo path
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-prs-fetch.XXXXXX")" || return 1
  local -i i=0 max="${PRS_FETCH_PARALLEL:-8}"
  while IFS=$'\t' read -r repo path; do
    [[ -z "$repo" ]] && continue
    prs_fetch_one "$repo" "$path" >"$tmp/$i.json" &
    i+=1
    # Bound concurrency: once we hit the cap, wait for one slot to free.
    if (( i % max == 0 )); then wait; fi
  done < <(prs_repos)
  wait
  cat "$tmp"/*.json 2>/dev/null | jq -s 'add // []'
  rm -rf "$tmp"
}

# --- lazy CI enrichment ------------------------------------------------------
# The CI pipeline glyph comes from statusCheckRollup, the one field whose gh cost
# grows with a repo's open-PR count. To keep the first paint instant we fetch it
# OUT OF BAND: prs_ci_states writes a small cache (repo#num<TAB>STATE), and
# prs_ci_merge folds that cache into the cheap PR array so the renderer colours
# the glyph. STATE is the reduced rollup: FAILURE / PENDING / SUCCESS / NONE.

# The reducer: a statusCheckRollup array → one STATE word. Mirrors the renderer's
# precedence (any failure ⇒ FAILURE, else any pending/unknown ⇒ PENDING, …).
_PRS_CI_STATE='
  ([ (. // [])[] | ([.conclusion, .state, .status] | map(select(. != null and . != "")) | .[0]) ]) as $c
  | if   ($c | length) == 0 then "NONE"
    elif ($c | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")) then "FAILURE"
    elif ($c | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "WAITING" or . == null)) then "PENDING"
    else "SUCCESS" end'

# prs_ci_states : for every configured repo, emit "repo#num<TAB>STATE" lines.
# Network + slow (this is the deferred cost). Fetched in parallel like the list.
prs_ci_states() {
  local repo path tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/herdr-prs-ci.XXXXXX")" || return 1
  local -i i=0 max="${PRS_FETCH_PARALLEL:-8}"
  while IFS=$'\t' read -r repo path; do
    [[ -z "$repo" ]] && continue
    {
      gh pr list --repo "$repo" --state open --limit 100 \
        --json number,statusCheckRollup 2>/dev/null \
      | jq -r --arg repo "$repo" \
          ".[] | \"\(\$repo)#\(.number)\t\" + (.statusCheckRollup | $_PRS_CI_STATE)"
    } >"$tmp/$i.txt" &
    i+=1
    if (( i % max == 0 )); then wait; fi
  done < <(prs_repos)
  wait
  cat "$tmp"/*.txt 2>/dev/null
  rm -rf "$tmp"
}

# prs_ci_merge <cachefile> : stdin = cheap PR array → same array annotated for the
# renderer's CI glyph. A PR present in the cache gets a synthetic .statusCheckRollup
# rebuilt from its cached STATE; a PR NOT yet in the cache is marked .ci_loading so
# the renderer shows a dim placeholder. An empty/missing cache = everything is loading.
prs_ci_merge() {
  local cache="${1:-}"
  local map='{}'
  if [[ -n "$cache" && -s "$cache" ]]; then
    map="$(jq -R -s 'split("\n") | map(select(length>0) | split("\t")) | map({(.[0]): .[1]}) | add // {}' < "$cache")"
  fi
  jq -c --argjson map "$map" '
    map(. as $pr
      | ("\(.repo)#\(.number)") as $k
      | ($map[$k]) as $st
      | if   $st == null      then .ci_loading = true
        elif $st == "NONE"    then .
        elif $st == "FAILURE" then .statusCheckRollup = [{"conclusion":"FAILURE"}]
        elif $st == "PENDING" then .statusCheckRollup = [{"status":"PENDING"}]
        else                       .statusCheckRollup = [{"conclusion":"SUCCESS"}] end)'
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
def ci($rollup; $loading):
  if $loading then "\u001b[2m·\u001b[0m"
  else
    ([ ($rollup // [])[] | ([.conclusion, .state, .status] | map(select(. != null and . != "")) | .[0]) ]) as $c
    | (if   ($c | length) == 0 then ["90","·"]
       elif ($c | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")) then ["31","✗"]
       elif ($c | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "WAITING" or . == null)) then ["33","●"]
       else ["32","✓"] end) as $g
    | "\u001b[1;\($g[0])m\($g[1])\u001b[0m"
  end;
def review($d):
  if $d == null then "—"
  else {"APPROVED":"approved","CHANGES_REQUESTED":"changes","REVIEW_REQUIRED":"review-needed"}[$d] // "—" end;
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
      + ci(.statusCheckRollup; (.ci_loading // false)) + "  "
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
