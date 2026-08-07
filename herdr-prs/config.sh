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

# Auto-refresh cadence for the live list, in seconds. Also the CI re-fetch floor:
# enrich.sh only re-queries statusCheckRollup once the cache is this old, so this
# is how quickly a pipeline glyph can flip colour on its own. Lower = snappier but
# more `gh` load (statusCheckRollup cost scales with your open-PR count).
: "${INTERVAL:=30}"

# CI pipeline glyph (green ✓ / yellow ● / red ✗ / grey ·) from statusCheckRollup.
# On by default and loaded LAZILY: the list appears at once with a dim placeholder
# where CI isn't known yet, and a background job fills it in (its glyphs land on
# the next refresh). Set to 0 to drop it.
: "${PRS_CI:=1}"

# Review-decision label ([approved] / [changes] / [review-needed]). On by
# default. Unlike CI it's fetched INLINE, so it can slow the first paint on repos
# with many open PRs — set to 0 to drop it (rows then show [—]).
: "${PRS_REVIEW:=1}"

# Legacy master switch — 1 forces both PRS_CI and PRS_REVIEW on.
: "${PRS_RICH:=0}"
if [[ "$PRS_RICH" == 1 ]]; then PRS_CI=1; PRS_REVIEW=1; fi

# How many repos to query in parallel. Higher = faster, more concurrent gh calls.
: "${PRS_FETCH_PARALLEL:=8}"

# Background watcher: a detached poller (watch.sh) that pings GitHub
# /notifications for your configured repos and, on a change, (a) raises a herdr
# toast for new PR comments/reviews and (b) nudges the list to repaint so the CI
# glyphs refresh on their own — no manual ctrl-r. On by default. Set to 0 to
# disable entirely: no poller, no toasts, and no fzf --listen socket; the
# dashboard then refreshes only on its INTERVAL loop and ctrl-r, exactly as before.
: "${PRS_WATCH:=1}"

# Which GitHub notification reasons raise a toast (comma-separated). CI activity
# (ci_activity) always triggers a silent refresh; it only pops a toast if listed.
: "${PRS_NOTIFY_REASONS:=comment,mention,review_requested,review,state_change,author}"

# Sound for a new-notification toast: none | done | request.
: "${PRS_NOTIFY_SOUND:=request}"

# The repo picker (pick-repos.sh) pool: the org, and an optional team. With a
# team set, the pool is that team's repos; empty team = every repo you can see.
: "${PICK_ORG:=vippsas}"
: "${PICK_TEAM:=team-risky-business}"

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
