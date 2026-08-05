---
Status: Current
Created: 2026-08-04
Last edited: 2026-08-04
---

# AI review

An out-of-process review pass: a coding agent (or the user) triggers `review-herdr`, which runs
the Copilot CLI over the uncommitted changeset and drops its findings into an inbox. A running
reviewr pane picks them up and shows them inline, alongside the reviewer's own comments.

The point is a GitHub-PR feel without a PR: line comments on the local diff, before a commit or a
push, requested from the agent window rather than typed in the pane.

## Shape

```
agent window:  /review-herdr
        │  runs
        ▼
herdr-reviewr review-herdr          (a transient, non-UI process)
   • git diff of the uncommitted scope, per changed file
   • Copilot CLI reviews each file's diff, read-only
   • findings anchored to (file, new-side line) → inbox comments
   • written to the worktree inbox
        │
        ▼
reviewr pane (watching the same worktree)
   • each poll, takes the inbox → adds the comments to the store → paints
```

## The subcommand

`herdr-reviewr review-herdr`, run anywhere inside a worktree, reviews the **uncommitted** scope
(the same changeset the `Changes` tab shows under `scope-uncommitted`): staged and unstaged
changes against `HEAD`, plus untracked files.

- It is a non-UI process. Like `--resolve-plugin-config`, it never counts as a reviewr pane —
  the dispatch in `src/main.rs` and the `is_reviewr_pane` exclusion in `herdr/pane.sh` are the
  two halves of that contract (specs/herdr-host.md, Pane identity).
- For each changed file it sends the new-side diff lines — additions and context, each with its
  line number — to the engine. Deletions carry no new-side line and are not reviewed. Untracked
  files read as all-additions.
- The engine is asked for a strict JSON array of `{line, comment}`, and reports only real defects
  (bugs, logic errors, security issues, resource leaks, missing error handling), never style.
- Each finding anchors to the exact new-side line it cites, as a single-line `new` comment. A
  finding citing a line that was not sent is dropped.
- It prints a one-line summary. A per-file engine failure is reported and skipped, never fatal.

### Read-only

The subcommand reads the repo but never writes to it. The diff is computed with git; the engine
runs with **no tool permissions**, its working directory an isolated temp dir (never the
worktree), and its stdin closed — so it can neither edit the repository nor block on an approval
prompt. This keeps the **No writes** invariant (specs/overview.md): the only output is the inbox,
under the temp dir.

## The inbox

The handoff between the subcommand and the pane is one file per worktree, under the temp dir,
keyed by the worktree (so a run anywhere in the tree and the pane watching it agree on one path,
and nothing is written inside the repo).

- It holds **one** pending batch. A re-run replaces it whole; an unread batch is superseded.
- It is consumed on read: the pane reads it, deletes it, and never re-adds the same batch.
- It is **not** a durable comment store. It carries a batch in flight and no more — the
  **Comments survive** / in-memory-only model is untouched (specs/review-model.md). A poisoned or
  wrong-version file is deleted on read so it can't wedge the pane.
- Its comments are a stable JSON contract (`file, side, start, end, lines, text`), versioned, so
  the subcommand and the pane can change independently.

## Ingestion

A reviewr pane auto-ingests: on each poll it takes any pending batch for its worktree, maps each
inbox comment onto the review model, and adds it to the same in-memory store the reviewer's own
comments live in.

- Ingested comments are ordinary comments from that point on: they render inline on their file's
  diff, list and navigate with the rest, and `send`/`copy`/`export` alike (specs/review-model.md).
- They land the moment the batch is written, without a keystroke in the pane, and paint within one
  poll interval.
- An unknown anchor `side` is dropped; a comment for a file not currently open still lands and
  shows when that file is opened, exactly like any comment on another file.

## The comments rail

A reviewr pane docks a comments rail under the file list: a scrollable list of every comment in
the store, each row its `file:line` and text. The reviewer pages the review's findings there, the
way a pull request lists its comments beside the files changed. The rejected fork is a modal
overlay as the only list surface, which shows the comments over the page rather than beside it.

- The rail shows only on a diff tab, with the navigator live, and with at least one comment in the
  store. It shares the navigator's rect, sitting below the file list on a floor of a third of the
  navigator's height (capped at half), so even a one-comment rail rises off the bottom corner into
  the eye's middle band rather than clinging to the edge. An empty store shows no rail, so the file
  list keeps the whole rect.
- The rail is a third focus target after the file list and the diff (`Focus::Comments`). `tab`
  cycles into it only while it shows.
- Moving the cursor with the rail focused steps its highlight and opens the highlighted comment in
  the diff, landing the diff cursor on the comment's line. The rejected fork is a display-only
  rail, which would make the reviewer find the line by hand.
- A click on a rail row selects it and reveals it the same way. Editing, deleting, and sending act
  on the highlighted row, as they do in the overlay.
- Emptying the store returns focus to the diff, since a rail with no rows has nothing to hold.

## Addressing and discarding a comment

The reviewer works a comment two ways, from the rail, the overlay, or the diff cursor:

- **Address (`a`)** drafts a prompt into the adjacent agent pane and hands it focus, but does not
  submit — the reviewer adds their instruction and sends it themselves. The prompt is
  `@file (line N): <comment text>` (a range reads `N-M`) with a trailing blank line for the cursor
  to land under. The `@file` is the bare path so Copilot resolves the mention; the line goes in the
  prose after it, never as a `:line` suffix that would break the mention. The comment is consumed
  only on a successful hand-off; a closed pane keeps it. When several agent panes exist the picker
  resolves which one, carrying the drafted prompt across the choice. This reuses the send-to-pane
  path (fill-and-focus, no submit), one comment instead of the whole set.
- **Discard (`d`)** deletes the targeted comment outright — the reviewer's judgement that a finding
  is irrelevant. Emptying the store this way returns focus to the diff.

## Non-goals

- No forge write. The pass is local; it never posts to a pull request.
- No durable store, severities, or threads — an ingested comment is just a comment (text only).
- No engine other than the Copilot CLI, and no in-pane trigger — the pass is requested from the
  agent window, out of process.

## Related specs

- [overview](./overview.md)
- [review-model](./review-model.md)
- [herdr-host](./herdr-host.md)
