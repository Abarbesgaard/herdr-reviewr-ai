# herdr-projects configuration (sourced by bash).
#
# This file is copied to your plugin config dir on first run:
#   $(herdr plugin config-dir herdr-projects)/config.sh
# Edit THAT copy; changes here (in the plugin source) only affect the seed.

# Directories scanned for git projects. A "project" is any directory that
# contains a .git entry (repo root or worktree). Tilde is expanded.
ROOTS=(
  "$HOME/Development"
)

# How deep to search below each root for .git.
SCAN_DEPTH=4

# Command run in the left "agent" pane after the workspace opens.
# Leave empty ("") to just get a shell.
# NOTE: `command copilot` bypasses your copilot()/claude() zsh wrappers so they
# don't ALSO auto-open a reviewr pane — this plugin already opens the reviewer.
AGENT_CMD="command copilot"

# How to populate the right "reviewer" pane:
#   plugin:<plugin_id>:<entrypoint>  -> open a herdr plugin pane (your reviewr)
#   cmd:<shell command>              -> split right and run a command
#   shell                            -> split right, just a shell
REVIEWER="plugin:persiyanov.reviewr:pane"
