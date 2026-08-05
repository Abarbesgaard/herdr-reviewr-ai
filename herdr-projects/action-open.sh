#!/usr/bin/env bash
# Action entrypoint: opens the projects picker as a popup pane.
# herdr runs plugin commands with a minimal PATH, so make herdr resolvable.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

H="${HERDR_BIN_PATH:-herdr}"
exec "$H" plugin pane open \
  --plugin "${HERDR_PLUGIN_ID:-herdr-projects}" \
  --entrypoint picker
