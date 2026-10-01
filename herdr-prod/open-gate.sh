#!/usr/bin/env bash
# Open a repo's production approval-gate deployments page on GitHub, e.g.
#   https://github.com/vippsas/user-deletion-engine/deployments/approval-gate-prod
# Called on Enter from the dashboard with the selected row's owner/repo ({1}).
set -uo pipefail
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
prod_load_config

repo="${1:-}"
[[ -z "$repo" ]] && exit 0
url="https://github.com/${repo}/deployments/${PROD_GATE_ENV:-approval-gate-prod}"

if command -v open >/dev/null 2>&1; then
  open "$url"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url"
else
  python3 -m webbrowser "$url" >/dev/null 2>&1 || printf '%s\n' "$url"
fi
