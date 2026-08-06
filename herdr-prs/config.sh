#!/usr/bin/env bash
# herdr-prs configuration. Copied to the plugin config dir on first run; edit that
# copy. Every value has a safe default, so an empty file is fine.

# Where the repo list lives. Defaults to repos.conf next to the plugin.
: "${REPOS_FILE:=$HERE/repos.conf}"

# Directories scanned to resolve a repo's local path when repos.conf gives none.
# A repo is matched by its origin remote ending in owner/repo(.git).
ROOTS=(
  "$HOME/Development/Rider"
  "$HOME/Development/pyCharm"
  "$HOME/Development/frontend"
  "$HOME/Development"
)

# Auto-refresh cadence for the live list, in seconds.
: "${INTERVAL:=60}"

# Label of the persistent dashboard workspace.
: "${WS_LABEL:=PRs}"

# The work workspace opened when you pick a PR:
#   AGENT_CMD  runs in the left "agent" pane
#   REVIEWER   the right pane — a herdr plugin pane, a command, or a shell:
#                plugin:<id>:<entrypoint>   e.g. plugin:persiyanov.reviewr:pane
#                cmd:<command line>
#                shell                       (a plain shell)
: "${AGENT_CMD:=command copilot}"
: "${REVIEWER:=plugin:persiyanov.reviewr:pane}"
