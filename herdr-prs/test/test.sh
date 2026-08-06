#!/usr/bin/env bash
# herdr-prs test suite. Pure-logic tests (render, new) plus dry-run tests of the
# side-effecting scripts (openpr, action) via fake `gh`/`herdr`/`git` on PATH.
#   Usage: bash test/test.sh [render|new|openpr|action|lint|all]
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # plugin dir
FIX="$HERE/test/fixtures"
FAILED=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }
have() { grep -Fq -- "$2" <<<"$1"; }

# Deterministic "now" for stable ages.
NOW_EPOCH="$(jq -n '"2026-08-06T07:00:00Z" | fromdateiso8601')"
export NOW_EPOCH

# --- pure: render_rows -------------------------------------------------------
test_render() {
  echo "render:"
  # shellcheck source=../lib.sh
  source "$HERE/lib.sh"
  local out; out="$(prs_render_rows < "$FIX/prs.json")"
  local n; n="$(wc -l <<<"$out" | tr -d ' ')"
  [[ "$n" == 3 ]] && pass "three rows" || fail "expected 3 rows, got $n"

  # Oldest first: pling-backend #42, then ongoing #1317, then terms #7.
  local c1 c2 c3
  c1="$(sed -n 1p <<<"$out" | cut -f1,2)"
  c2="$(sed -n 2p <<<"$out" | cut -f1,2)"
  c3="$(sed -n 3p <<<"$out" | cut -f1,2)"
  [[ "$c1" == $'vippsas/pling-backend\t42' ]] && pass "oldest row first (#42)" || fail "row1 was '$c1'"
  [[ "$c2" == $'vippsas/ongoing-due-diligence\t1317' ]] && pass "middle row (#1317)" || fail "row2 was '$c2'"
  [[ "$c3" == $'vippsas/terms-and-conditions\t7' ]] && pass "newest row last (#7)" || fail "row3 was '$c3'"

  # Localpath carried in column 3.
  local p1; p1="$(sed -n 1p <<<"$out" | cut -f3)"
  [[ "$p1" == "/tmp/clones/pling-backend" ]] && pass "localpath in column 3" || fail "path was '$p1'"

  # Display column: CI glyphs, review labels, ages.
  local d1 d2 d3
  d1="$(sed -n 1p <<<"$out" | cut -f5)"; d2="$(sed -n 2p <<<"$out" | cut -f5)"; d3="$(sed -n 3p <<<"$out" | cut -f5)"
  have "$d1" "✓" && have "$d1" "approved"      && have "$d1" "4d" && pass "row1 ✓/approved/4d"      || fail "row1 display: $d1"
  have "$d2" "✗" && have "$d2" "review-needed" && have "$d2" "1d" && pass "row2 ✗/review-needed/1d" || fail "row2 display: $d2"
  have "$d3" "•" && have "$d3" "changes"       && have "$d3" "1h" && pass "row3 •/changes/1h"       || fail "row3 display: $d3"
}

# --- pure: NEW marking -------------------------------------------------------
test_new() {
  echo "new:"
  # shellcheck source=../lib.sh
  source "$HERE/lib.sh"
  local seen; seen="$(mktemp)"
  printf '%s\n' "vippsas/pling-backend#42" "vippsas/ongoing-due-diligence#1317" > "$seen"
  local out; out="$(prs_render_rows "$seen" < "$FIX/prs.json")"
  rm -f "$seen"

  # #7 (terms) is not in the seen set → starred; the other two are not.
  local s1 s2 s3
  s1="$(sed -n 1p <<<"$out" | cut -f5 | cut -c1)"
  s2="$(sed -n 2p <<<"$out" | cut -f5 | cut -c1)"
  s3="$(sed -n 3p <<<"$out" | cut -f5 | cut -c1)"
  [[ "$s1" != "★" ]] && pass "seen #42 not starred"   || fail "row1 unexpectedly starred"
  [[ "$s2" != "★" ]] && pass "seen #1317 not starred" || fail "row2 unexpectedly starred"
  [[ "$s3" == "★" ]] && pass "unseen #7 starred"      || fail "row3 not starred: '$(sed -n 3p <<<"$out" | cut -f5)'"

  # With no seen file, everything is NEW.
  local all; all="$(prs_render_rows < "$FIX/prs.json")"
  local stars; stars="$(cut -f5 <<<"$all" | cut -c1 | grep -c '★' || true)"
  [[ "$stars" == 3 ]] && pass "no baseline ⇒ all new" || fail "expected 3 stars, got $stars"

  # Fast mode: PRs missing reviewDecision/statusCheckRollup must render, not crash.
  local lean; lean='[{"number":9,"title":"lean","author":{"login":"z"},"createdAt":"2026-08-01T00:00:00Z","isDraft":false,"repo":"vippsas/lean","localpath":"/tmp/l"}]'
  local lout rc
  lout="$(prs_render_rows <<<"$lean" 2>&1)"; rc=$?
  if [[ $rc == 0 ]] && have "$lout" "[—]" && have "$lout" "·"; then
    pass "renders PRs with no CI/review fields (fast mode)"
  else
    fail "fast-mode render failed (rc=$rc): $lout"
  fi
}

# --- fetch: prs_fetch_all combines all repos (guards parallel fetch) ---------
test_fetch() {
  echo "fetch:"
  # shellcheck source=../lib.sh
  source "$HERE/lib.sh"
  local tmp bin repos; tmp="$(mktemp -d)"; bin="$tmp/bin"; mkdir -p "$bin"
  # A gh stub that returns one open PR per repo, echoing the repo in the title
  # so we can prove each configured repo was fetched and merged.
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
repo=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--repo" ]] && { repo="$2"; shift; }; shift; done
n=$(( ( ${#repo} % 900 ) + 1 ))
printf '[{"number":%d,"title":"from %s","author":{"login":"x"},"createdAt":"2026-01-01T00:00:00Z","isDraft":false,"reviewDecision":null,"statusCheckRollup":[]}]\n' "$n" "$repo"
EOF
  chmod +x "$bin/gh"
  repos="$tmp/repos.conf"
  printf 'vippsas/alpha\t/tmp/a\nvippsas/beta\t/tmp/b\nvippsas/gamma\t/tmp/c\n' > "$repos"

  local out cnt
  out="$(PATH="$bin:$PATH" REPOS_FILE="$repos" HERE="$HERE" bash -c 'source "$HERE/lib.sh"; prs_load_config; prs_fetch_all')"
  cnt="$(jq 'length' <<<"$out")"
  [[ "$cnt" == 3 ]] && pass "three repos merged into one array" || fail "expected 3 PRs, got $cnt"
  for r in alpha beta gamma; do
    if jq -e --arg r "$r" 'any(.title == "from vippsas/\($r)")' <<<"$out" >/dev/null; then
      pass "includes $r"
    else
      fail "missing $r in merged output"
    fi
  done
  rm -rf "$tmp"
}

# --- build a temp dir of fake gh/herdr/git that log their args ---------------
make_fakes() {   # $1 = bindir, $2 = logfile
  local bin="$1" log="$2"
  mkdir -p "$bin"
  cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$log"
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then echo "[]"; fi
exit 0
EOF
  cat > "$bin/herdr" <<EOF
#!/usr/bin/env bash
echo "herdr \$*" >> "$log"
if [[ "\$1" == "workspace" && "\$2" == "create" ]]; then
  echo '{"result":{"root_pane":{"pane_id":"pane-1"}}}'
elif [[ "\$1" == "workspace" && "\$2" == "list" ]]; then
  if [[ "\${FAKE_WS_HAS_PRS:-0}" == "1" ]]; then
    echo '{"result":{"workspaces":[{"label":"PRs","workspace_id":"w9"}]}}'
  else
    echo '{"result":{"workspaces":[{"label":"Herdr","workspace_id":"w5"}]}}'
  fi
elif [[ "\$1" == "pane" && "\$2" == "split" ]]; then
  echo '{"result":{"pane":{"pane_id":"pane-2"}}}'
fi
exit 0
EOF
  chmod +x "$bin/gh" "$bin/herdr"
}

# --- dry-run: open-pr.sh -----------------------------------------------------
test_openpr() {
  echo "openpr:"
  local tmp bin log clone; tmp="$(mktemp -d)"; bin="$tmp/bin"; log="$tmp/log"
  make_fakes "$bin" "$log"
  clone="$tmp/pling-backend"; mkdir -p "$clone"
  ( cd "$clone" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1

  PATH="$bin:$PATH" HERDR_BIN_PATH="$bin/herdr" \
    bash "$HERE/open-pr.sh" vippsas/pling-backend 42 "$clone" >/dev/null 2>&1
  local out; out="$(cat "$log")"

  have "$out" "gh pr checkout 42 --repo vippsas/pling-backend" && pass "checks out the PR branch" || fail "no checkout in log"
  have "$out" "herdr workspace create --cwd $clone --label pling-backend #42 --focus" && pass "creates labelled workspace" || fail "no workspace create"
  # Perceived-latency fix: the workspace must be created BEFORE the slow checkout.
  local ws_ln co_ln
  ws_ln="$(grep -n 'workspace create' <<<"$out" | head -1 | cut -d: -f1)"
  co_ln="$(grep -n 'pr checkout' <<<"$out" | head -1 | cut -d: -f1)"
  if [[ -n "$ws_ln" && -n "$co_ln" && "$ws_ln" -lt "$co_ln" ]]; then
    pass "workspace opens before checkout (instant window)"
  else
    fail "workspace ($ws_ln) not before checkout ($co_ln)"
  fi
  have "$out" "herdr pane rename pane-1 agent" && pass "left pane is agent" || fail "no agent rename"
  have "$out" "plugin pane open --plugin persiyanov.reviewr" && pass "reviewer pane on the right" || fail "no reviewer pane"
  have "$out" "herdr pane run pane-1 command copilot" && pass "agent command launched" || fail "no agent run"
  rm -rf "$tmp"
}

# --- dry-run: action-open.sh (create + focus) --------------------------------
test_action() {
  echo "action:"
  local tmp bin log; tmp="$(mktemp -d)"; bin="$tmp/bin"; log="$tmp/log"
  make_fakes "$bin" "$log"

  # Case A: no PRs workspace ⇒ create it and run the dashboard in its pane.
  : > "$log"
  PATH="$bin:$PATH" HERDR_BIN_PATH="$bin/herdr" REPOS_FILE="$FIX/repos.conf" \
    HERDR_PLUGIN_STATE_DIR="$tmp/state" FAKE_WS_HAS_PRS=0 \
    bash "$HERE/action-open.sh" >/dev/null 2>&1
  local a; a="$(cat "$log")"
  have "$a" "herdr workspace create --label PRs --focus" && pass "creates PRs workspace" || fail "no create"
  have "$a" "herdr pane run pane-1 exec bash $HERE/dashboard.sh" && pass "runs dashboard in its pane" || fail "no dashboard run"
  ! have "$a" "workspace focus" && pass "does not focus when creating" || fail "unexpected focus on create"

  # Case B: PRs workspace present ⇒ focus it, do not create.
  : > "$log"
  PATH="$bin:$PATH" HERDR_BIN_PATH="$bin/herdr" REPOS_FILE="$FIX/repos.conf" \
    HERDR_PLUGIN_STATE_DIR="$tmp/state" FAKE_WS_HAS_PRS=1 \
    bash "$HERE/action-open.sh" >/dev/null 2>&1
  local b; b="$(cat "$log")"
  have "$b" "herdr workspace focus w9" && pass "focuses existing workspace" || fail "no focus"
  ! have "$b" "workspace create" && pass "does not create when present" || fail "unexpected create"
  rm -rf "$tmp"
}

# --- lint --------------------------------------------------------------------
test_lint() {
  echo "lint:"
  local f ok=1
  for f in "$HERE"/*.sh "$HERE"/test/*.sh; do
    if bash -n "$f" 2>/dev/null; then :; else fail "bash -n $f"; ok=0; fi
  done
  [[ "$ok" == 1 ]] && pass "all scripts parse (bash -n)"
  grep -Fq 'id = "open"' "$HERE/herdr-plugin.toml" && pass "manifest declares the open action" || fail "no open action"
  grep -Fq 'id = "dashboard"' "$HERE/herdr-plugin.toml" && pass "manifest declares the dashboard pane" || fail "no dashboard pane"
}

case "${1:-all}" in
  render) test_render ;;
  new)    test_new ;;
  openpr) test_openpr ;;
  action) test_action ;;
  fetch)  test_fetch ;;
  lint)   test_lint ;;
  all)    test_render; test_new; test_fetch; test_openpr; test_action; test_lint ;;
  *) echo "unknown: $1" >&2; exit 2 ;;
esac

[[ "$FAILED" == 0 ]] && echo "PASS" || { echo "FAIL"; exit 1; }
