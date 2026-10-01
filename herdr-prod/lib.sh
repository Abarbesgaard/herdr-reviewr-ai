#!/usr/bin/env bash
# herdr-prod shared library: config loading, repo-list parsing, and the pure row
# renderer. Sourced by gen.sh, dashboard.sh, action-open.sh and the tests. The
# only network lives in prod_fetch_*; everything else is pure and unit-tested.

# --- config ------------------------------------------------------------------

prod_load_config() {
  : "${HERE:?prod_load_config needs HERE set to the plugin dir}"
  # shellcheck disable=SC1091
  [[ -f "$HERE/config.sh" ]] && source "$HERE/config.sh"
  local cfg="${HERDR_PLUGIN_CONFIG_DIR:-}"
  if [[ -n "$cfg" && -f "$cfg/config.sh" ]]; then
    # shellcheck disable=SC1090
    source "$cfg/config.sh"
  fi
  : "${REPOS_FILE:=$HERE/repos.conf}"
  : "${PROD_SEED_FROM:=$HERE/../herdr-prs/repos.conf}"
  : "${PICK_ORG:=vippsas}"
  : "${PICK_TEAM:=team-risky-business}"
  : "${PROD_ENV:=prod}"
  : "${PROD_GATE_ENV:=approval-gate-prod}"
  : "${INTERVAL:=120}"
  : "${PROD_FRESH_DAYS:=2}"
  : "${PROD_STALE_DAYS:=7}"
  : "${PROD_WARN_COMMITS:=1}"
  : "${PROD_WARN_PRS:=10}"
  : "${PROD_FETCH_PARALLEL:=8}"
  : "${WS_LABEL:=Prod}"
  : "${STATE_DIR:=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-prod}}"
}

# repos.conf → one "owner/repo" per line (first TAB-field). Blank lines and lines
# starting with # are skipped. Only the repo column is read; paths are ignored.
prod_repos() {
  local file="${1:-$REPOS_FILE}"
  [[ -f "$file" ]] || return 0
  local line repo
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    repo="${line%%$'\t'*}"
    repo="${repo#"${repo%%[![:space:]]*}"}"; repo="${repo%"${repo##*[![:space:]]}"}"
    [[ -z "$repo" ]] && continue
    printf '%s\n' "$repo"
  done < "$file"
}

# Seed REPOS_FILE from PROD_SEED_FROM (the PR dashboard's list) the first time,
# so a fresh install starts watching the repos you already track. No-op once
# REPOS_FILE exists, or when there is nothing to seed from.
prod_seed_repos() {
  local dst="${1:-$REPOS_FILE}" src="${2:-${PROD_SEED_FROM:-}}"
  [[ -e "$dst" ]] && return 0
  [[ -n "$src" && -f "$src" ]] || return 0
  local repos; repos="$(prod_repos "$src")"
  [[ -z "$repos" ]] && return 0
  {
    echo "# herdr-prod watch list — seeded from $src on $(date '+%Y-%m-%d %H:%M')."
    echo "# One owner/repo per line. Edit here or with the ctrl-e picker."
    echo
    printf '%s\n' "$repos"
  } > "$dst"
}

# --- pure render -------------------------------------------------------------

# ANSI helpers (respect NO_COLOR).
prod_c() { [[ -n "${NO_COLOR:-}" ]] && { printf '%s' "$2"; return; }; printf '\033[%sm%s\033[0m' "$1" "$2"; }

# Age colour by day count: green <= FRESH_DAYS, red >= STALE_DAYS, yellow between.
# "—" (no prod deploy on record) is informational, not a risk → dim grey.
prod_age_color() {
  local days="$1"
  if [[ "$days" == "—" ]]; then echo "2"; return; fi
  if [[ "$days" == "?" ]]; then echo "2"; return; fi
  if (( days <= ${PROD_FRESH_DAYS:-2} )); then echo "32"; return; fi
  if (( days >= ${PROD_STALE_DAYS:-7} )); then echo "31;1"; return; fi
  echo "33"
}

# Run-state colour + short label for the latest prod deployment's newest status.
prod_run_label() {
  case "$1" in
    success)                 echo "32 ok" ;;
    failure|error)           echo "31;1 failed" ;;
    in_progress)             echo "33 running" ;;
    queued|pending|waiting)  echo "33 pending" ;;
    *)                       echo "2 ${1:-?}" ;;
  esac
}

# prod_render_rows : read raw per-repo TSV on stdin, emit NUL-separated fzf items.
# Input columns (TAB):  repo  days  ahead  prs  sha  when_iso  deployer  runstate
#   days/ahead/prs/sha/deployer/runstate are "—" when there is no prod deploy.
# Output columns (TAB):  repo  when_iso  display   (NUL-terminated)
# with-nth shows only {3}=display; {1}/{2} drive the drill-down on Enter.
prod_render_rows() {
  local repo days ahead prs sha when deployer runstate
  while IFS=$'\t' read -r repo days ahead prs sha when deployer runstate; do
    [[ -z "$repo" ]] && continue
    local short="${repo#*/}"
    local agec; agec="$(prod_age_color "$days")"
    local age_txt
    if [[ "$days" == "—" ]]; then age_txt="no prod deploy"; else age_txt="${days}d ago"; fi
    local age; age="$(prod_c "$agec" "$(printf '%-14s' "$age_txt")")"

    local aheadf prsf runf deployerf shaf
    if [[ "$ahead" == "—" ]]; then
      aheadf="$(prod_c '2' "$(printf '%-5s' '·')")"
      prsf="$(prod_c '2' "$(printf '%6s' '·')")"
      runf="$(prod_c '2' "$(printf '%-8s' '·')")"
      deployerf="$(prod_c '2' "$(printf '%-17s' '·')")"
      shaf="$(prod_c '2' '-------')"
    else
      local ac='2'
      (( ahead >= ${PROD_WARN_COMMITS:-1} )) && ac='0'
      (( ahead >= 20 )) && ac='33'
      aheadf="$(prod_c "$ac" "$(printf '↑%-4s' "$ahead")")"
      local pc='2'; (( prs > 0 )) && pc='0'
      (( prs > ${PROD_WARN_PRS:-10} )) && pc='31;1'
      prsf="$(prod_c "$pc" "$(printf '%3s PR' "$prs")")"
      local rspec rc rl; rspec="$(prod_run_label "$runstate")"; rc="${rspec%% *}"; rl="${rspec#* }"
      runf="$(prod_c "$rc" "$(printf '%-8s' "$rl")")"
      local who="${deployer:-?}"; who="${who:0:16}"
      deployerf="$(prod_c '2' "$(printf '@%-16s' "$who")")"
      shaf="$(prod_c '2' "$sha")"
    fi

    local name; name="$(printf '%-34s' "$short")"
    printf '%s\t%s\t%s  %s  %s  %s  %s  %s  %s\0' \
      "$repo" "$when" "$name" "$age" "$aheadf" "$prsf" "$runf" "$deployerf" "$shaf"
  done
}

# --- network -----------------------------------------------------------------

# Days between an ISO-8601 Zulu timestamp and now. Prints an integer.
prod_days_since() {
  local when="$1" now dep
  now="$(date +%s)"
  dep="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$when" +%s 2>/dev/null \
        || date -d "$when" +%s 2>/dev/null)" || { echo "?"; return; }
  echo $(( (now - dep) / 86400 ))
}

# The latest deployment to $PROD_ENV whose newest status is `success`, plus who
# created it and the newest prod deployment's current state (so a running/failed
# deploy sitting on top of the last good one is visible).
# Prints "sha_short<TAB>created_iso<TAB>deployer<TAB>latest_state" or nothing.
prod_last_deploy() {
  local repo="$1" did st latest="" meta
  for did in $(gh api "repos/$repo/deployments?environment=${PROD_ENV}&per_page=10" \
                 --jq '.[].id' 2>/dev/null); do
    st="$(gh api "repos/$repo/deployments/$did/statuses" --jq '.[0].state' 2>/dev/null)"
    [[ -z "$latest" ]] && latest="$st"
    if [[ "$st" == "success" ]]; then
      meta="$(gh api "repos/$repo/deployments/$did" \
                --jq '[(.sha[0:7]), .created_at, (.creator.login // "?")] | @tsv' 2>/dev/null)"
      printf '%s\t%s\n' "$meta" "$latest"
      return 0
    fi
  done
  return 0
}

# One repo → a raw TSV row: repo  days  ahead  prs  sha  when_iso  deployer  runstate
prod_fetch_one() {
  local repo="$1" sha when deployer runstate db ahead prs days line
  line="$(prod_last_deploy "$repo")"
  IFS=$'\t' read -r sha when deployer runstate <<<"$line"
  if [[ -z "$sha" ]]; then
    printf '%s\t—\t—\t—\t—\t\t—\t—\n' "$repo"
    return 0
  fi
  db="$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null)"; db="${db:-main}"
  ahead="$(gh api "repos/$repo/compare/$sha...$db" --jq '.ahead_by' 2>/dev/null)"; ahead="${ahead:-?}"
  prs="$(gh pr list --repo "$repo" --state merged --search "merged:>=${when%T*}" \
           --json number --jq 'length' 2>/dev/null)"; prs="${prs:-0}"
  days="$(prod_days_since "$when")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo" "$days" "$ahead" "$prs" "$sha" "$when" "${deployer:-?}" "${runstate:-?}"
}

# All configured repos, bounded-parallel → combined raw TSV on stdout, sorted so
# the stalest real deploys float to the top and repos with no prod deploy sink
# to the bottom.
prod_fetch_all() {
  local repo pids=() tmp; tmp="$(mktemp -d)"
  local i=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    prod_fetch_one "$repo" > "$tmp/$i.row" &
    pids+=($!)
    (( ++i ))
    if (( ${#pids[@]} >= ${PROD_FETCH_PARALLEL:-8} )); then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    fi
  done < <(prod_repos)
  wait 2>/dev/null || true
  # Sort: no-deploy (—) first, then by days descending (stalest on top).
  cat "$tmp"/*.row 2>/dev/null | prod_sort_rows
  rm -rf "$tmp"
}

# Sort raw rows: by day count descending (stalest real deploys on top); rows with
# no recorded prod deploy ("—") sink to the bottom.
prod_sort_rows() {
  awk -F'\t' '{ k = ($2=="—") ? -1 : $2+0; printf "%09d\t%s\n", k+1000000, $0 }' \
    | sort -rn -k1,1 | cut -f2-
}
