#!/usr/bin/env bash
# herdr-prod tests. Pure render + parse units plus a manifest/lint check. No
# network: fetch helpers are exercised against a fake `gh` on PATH.
#   bash test/test.sh [render|repos|sort|age|fetch|lint|all]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"

fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
have() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

export NO_COLOR=1   # deterministic render output in assertions

test_repos() {
  echo "repos:"
  local tmp; tmp="$(mktemp)"
  printf '# a comment\nvippsas/alpha\t/x/alpha\n\nvippsas/beta\n  vippsas/gamma  \t\n' > "$tmp"
  local out; out="$(prod_repos "$tmp")"
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 3 ]] && pass "skips blanks + comments" || fail "count: $out"
  have "$out" "vippsas/alpha" && pass "reads owner/repo" || fail "no alpha: $out"
  have "$out" "vippsas/gamma" && pass "trims whitespace" || fail "no gamma: $out"
  ! have "$out" "/x/alpha" && pass "drops the path column" || fail "kept path: $out"
  rm -f "$tmp"
}

test_age() {
  echo "age colour:"
  PROD_FRESH_DAYS=2 PROD_STALE_DAYS=7
  [[ "$(prod_age_color 0)"  == 32* ]] && pass "fresh is green"  || fail "0 → $(prod_age_color 0)"
  [[ "$(prod_age_color 4)"  == 33* ]] && pass "mid is yellow"   || fail "4 → $(prod_age_color 4)"
  [[ "$(prod_age_color 7)"  == 31* ]] && pass "stale is red"    || fail "7 → $(prod_age_color 7)"
  [[ "$(prod_age_color 40)" == 31* ]] && pass "very old is red" || fail "40 → $(prod_age_color 40)"
  [[ "$(prod_age_color —)"  == 2 ]]   && pass "no-deploy is grey" || fail "— → $(prod_age_color —)"
}

test_render() {
  echo "render:"
  # repo  days  ahead  prs  sha  when  deployer  runstate
  local raw; raw=$'vippsas/pling-backend\t35\t48\t30\t318b903\t2026-08-27T12:22:52Z\talice\tsuccess\nvippsas/odd\t2\t3\t1\t9b1416a\t2026-09-29T11:40:15Z\tbob\tin_progress\nvippsas/none\t—\t—\t—\t—\t\t—\t—'
  local out; out="$(printf '%s\n' "$raw" | prod_render_rows | tr '\0' '\n')"
  have "$out" "pling-backend" && pass "shows repo short name" || fail "no name: $out"
  have "$out" "35d ago"       && pass "formats age"           || fail "no age: $out"
  have "$out" "↑48"           && pass "shows commits ahead"   || fail "no ahead: $out"
  have "$out" "30 PR"         && pass "shows merged-PR count"  || fail "no prs: $out"
  have "$out" "318b903"       && pass "shows deployed sha"     || fail "no sha: $out"
  have "$out" "@alice"        && pass "shows deployer login"   || fail "no deployer: $out"
  have "$out" "ok"            && pass "shows run state ok"     || fail "no run ok: $out"
  have "$out" "running"       && pass "shows in-progress run"  || fail "no running: $out"
  have "$out" "no prod deploy" && pass "handles no-deploy repo" || fail "no dash row: $out"
  # hidden action columns present: owner/repo then iso then display
  local first; first="$(printf '%s\n' "$raw" | prod_render_rows | tr '\0' '\n' | head -1)"
  have "$first" $'vippsas/pling-backend\t2026-08-27' && pass "carries owner/repo + iso for drill" || fail "cols: $first"
  # PR-count colour: >10 is red, <=10 is not. Check with colour enabled.
  local hi lo
  hi="$(NO_COLOR= PROD_WARN_PRS=10 bash -c 'HERE="'"$HERE"'"; source "$HERE/lib.sh"; prod_load_config; printf "a/x\t3\t2\t30\tsha\t2026-09-29T00:00:00Z\tz\tsuccess\n" | prod_render_rows | tr "\0" "\n"')"
  lo="$(NO_COLOR= PROD_WARN_PRS=10 bash -c 'HERE="'"$HERE"'"; source "$HERE/lib.sh"; prod_load_config; printf "a/x\t3\t2\t4\tsha\t2026-09-29T00:00:00Z\tz\tsuccess\n" | prod_render_rows | tr "\0" "\n"')"
  have "$hi" $'\033[31;1m 30 PR' && pass "PR backlog >10 is red" || fail "hi not red: $hi"
  ! have "$lo" $'\033[31;1m  4 PR' && pass "PR backlog <=10 is not red" || fail "lo wrongly red: $lo"
  # Run-state colour: a failed deploy is red.
  local rf
  rf="$(NO_COLOR= bash -c 'HERE="'"$HERE"'"; source "$HERE/lib.sh"; prod_load_config; printf "a/x\t3\t2\t1\tsha\t2026-09-29T00:00:00Z\tz\tfailure\n" | prod_render_rows | tr "\0" "\n"')"
  have "$rf" $'\033[31;1mfailed' && pass "failed run state is red" || fail "run not red: $rf"
}

test_sort() {
  echo "sort:"
  local raw; raw=$'a/one\t5\t1\t1\tsha\twhen\na/two\t40\t1\t1\tsha\twhen\na/none\t—\t—\t—\t—\t'
  local out; out="$(printf '%s\n' "$raw" | prod_sort_rows | cut -f1)"
  [[ "$(printf '%s\n' "$out" | head -1)" == "a/two" ]] && pass "stalest real deploy on top" || fail "top: $out"
  [[ "$(printf '%s\n' "$out" | tail -1)" == "a/none" ]] && pass "no-deploy sinks to the bottom" || fail "bottom: $out"
}

test_fetch() {
  echo "fetch (fake gh):"
  local tmp bin; tmp="$(mktemp -d)"; bin="$tmp/bin"; mkdir -p "$bin"
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal fake: a prod deploy at a known sha/date by alice, 7 ahead, 4 merged PRs.
args="$*"
case "$args" in
  *"deployments?environment=prod"*)   echo 111 ;;
  *"deployments/111/statuses"*)       echo success ;;
  *"deployments/111"*)                printf 'abc1234\t2026-09-01T10:00:00Z\talice\n' ;;
  *"repos/"*" --jq .default_branch"*) echo main ;;
  *compare*)                          echo 7 ;;
  *"pr list"*)                        echo 4 ;;  # --jq length ⇒ a count
  *)                                  : ;;
esac
EOF
  chmod +x "$bin/gh"
  local row; row="$(PATH="$bin:$PATH" PROD_ENV=prod bash -c '
    HERE="'"$HERE"'"; source "$HERE/lib.sh"; prod_load_config; prod_fetch_one vippsas/demo')"
  have "$row" $'vippsas/demo\t' && pass "emits repo row" || fail "row: $row"
  # columns: repo days ahead prs sha when deployer runstate
  local ahead prs sha deployer runstate
  IFS=$'\t' read -r _ _ ahead prs sha _ deployer runstate <<<"$row"
  [[ "$ahead" == 7 ]] && pass "commits ahead from compare" || fail "ahead=$ahead"
  [[ "$prs" == 4 ]]   && pass "merged-PR count from pr list" || fail "prs=$prs"
  [[ "$sha" == abc1234 ]] && pass "sha from last success deploy" || fail "sha=$sha"
  [[ "$deployer" == alice ]] && pass "deployer from deployment creator" || fail "deployer=$deployer"
  [[ "$runstate" == success ]] && pass "run state from latest deployment" || fail "runstate=$runstate"
  rm -rf "$tmp"
}

test_gate_url() {
  echo "gate url:"
  local tmp bin log; tmp="$(mktemp -d)"; bin="$tmp/bin"; log="$tmp/log"; mkdir -p "$bin"
  # Fake `open` captures the URL it is asked to launch.
  cat > "$bin/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$log"
EOF
  chmod +x "$bin/open"
  PATH="$bin:$PATH" bash "$HERE/open-gate.sh" vippsas/user-deletion-engine >/dev/null 2>&1
  local got; got="$(cat "$log" 2>/dev/null)"
  [[ "$got" == "https://github.com/vippsas/user-deletion-engine/deployments/approval-gate-prod" ]] \
    && pass "opens the repo's approval-gate deploys page" || fail "url: $got"
  # A custom gate env is honoured.
  : > "$log"
  PATH="$bin:$PATH" PROD_GATE_ENV=prod-gate bash "$HERE/open-gate.sh" vippsas/demo >/dev/null 2>&1
  have "$(cat "$log")" "/deployments/prod-gate" && pass "honours PROD_GATE_ENV" || fail "env: $(cat "$log")"
  rm -rf "$tmp"
}

test_seed() {
  echo "seed:"
  local tmp; tmp="$(mktemp -d)"
  printf '# src\nvippsas/alpha\nvippsas/beta\t/p/beta\n' > "$tmp/src.conf"
  prod_seed_repos "$tmp/dst.conf" "$tmp/src.conf"
  [[ -f "$tmp/dst.conf" ]] && pass "creates the watch list when missing" || fail "no dst"
  local got; got="$(prod_repos "$tmp/dst.conf")"
  have "$got" "vippsas/alpha" && have "$got" "vippsas/beta" && pass "seeds owner/repo from source" || fail "seed: $got"
  # Idempotent: a second call must not overwrite an edited file.
  echo "vippsas/only" > "$tmp/dst.conf"
  prod_seed_repos "$tmp/dst.conf" "$tmp/src.conf"
  [[ "$(cat "$tmp/dst.conf")" == "vippsas/only" ]] && pass "no-op once the list exists" || fail "clobbered: $(cat "$tmp/dst.conf")"
  rm -rf "$tmp"
}

test_lint() {
  echo "lint:"
  local ok=1
  for f in "$HERE"/*.sh; do bash -n "$f" || ok=0; done
  [[ $ok == 1 ]] && pass "all scripts parse (bash -n)" || fail "a script failed bash -n"
  grep -q 'id = "open"' "$HERE/herdr-plugin.toml" && pass "manifest declares the open action" || fail "no open action"
  grep -q 'command = \["bash", "dashboard.sh"\]' "$HERE/herdr-plugin.toml" && pass "manifest declares the dashboard pane" || fail "no dashboard pane"
}

case "${1:-all}" in
  repos) test_repos ;;
  age)   test_age ;;
  render) test_render ;;
  sort)  test_sort ;;
  fetch) test_fetch ;;
  gate)  test_gate_url ;;
  seed)  test_seed ;;
  lint)  test_lint ;;
  all)   test_repos; test_age; test_render; test_sort; test_fetch; test_gate_url; test_seed; test_lint ;;
  *) echo "usage: $0 [repos|age|render|sort|fetch|gate|seed|lint|all]" >&2; exit 2 ;;
esac

if [[ $fails -gt 0 ]]; then echo "FAIL"; exit 1; else echo "PASS"; fi
