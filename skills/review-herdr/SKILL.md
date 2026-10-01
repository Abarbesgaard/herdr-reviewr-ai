---
name: review-herdr
description: Use when the user types "/review-herdr", "review-herdr", or asks for a local AI/Copilot review of their uncommitted changes shown inside the reviewr TUI. Runs the herdr-reviewr AI review over the current repo's uncommitted diff and drops inline comments into the running reviewr pane.
---

# review-herdr — local AI review into reviewr

When invoked, run the review of the current repository's **uncommitted** changes and hand the
findings to any running `reviewr` pane. Do exactly this:

1. Confirm you are inside a git worktree (the user's current repo). If not, tell the user to `cd`
   into the repo first and stop.
2. Run the review command from the repo root:

   ```bash
   herdr-reviewr review-herdr
   ```

   - It reviews only uncommitted changes (working tree vs. index/HEAD), read-only.
   - It writes findings to the transient inbox that a running reviewr pane auto-ingests.
3. Report the one-line summary it prints (e.g. `AI review: N comments across M files.`).
4. Remind the user the comments appear inline in the reviewr pane within ~1–2s, and that they can
   press `l` (or use the comments list) to page through them. If the reviewr pane shows nothing,
   the pane needs to be reopened so it runs the current binary.

Do not pass `--allow-all-tools` or write to the repo — the review is strictly read-only.
