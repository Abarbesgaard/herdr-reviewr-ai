# Setup — local AI review in reviewr

This fork of [reviewr](https://github.com/persiyanov/herdr-reviewr) adds a local, pre-commit
Copilot review: `review-herdr` reviews your **uncommitted** changes and shows the findings as
GitHub-PR-style comments inside the reviewr pane — before you commit or push. You can then
**address** a comment (`a`, drafts an `@file` prompt into the agent pane), **discard** it (`d`),
or let the agent **resolve** it (`herdr-reviewr resolve-herdr <id>`), which clears it from the
review. See `specs/ai-review.md` for the full behaviour.

## Prerequisites

- **herdr** ≥ 0.7.5
- **GitHub Copilot CLI**
- **Rust toolchain** (`rustup`) — this fork has no prebuilt release, so you build from source

## Install

```bash
# 1. Clone this repo (default branch is `ai-review`, so you land on it directly)
git clone https://github.com/Abarbesgaard/reviewr-local-ai
cd reviewr-local-ai

# 2. Build the binary into the plugin's bin/ dir
cargo build --release
mkdir -p bin
install -m 0755 target/release/herdr-reviewr bin/herdr-reviewr

# 3. Register this checkout as a herdr plugin (uses its own herdr/ scripts + bin)
herdr plugin link .

# 4. Install the Copilot skill so "review-herdr" triggers the review
mkdir -p ~/.copilot/skills/review-herdr
cp skills/review-herdr/SKILL.md ~/.copilot/skills/review-herdr/SKILL.md
```

## Use

1. In herdr, open the **reviewr** pane (the plugin's toggle action; default: right split).
2. In an agent window in the repo you're working on, type **`review-herdr`** (the skill), or run
   `herdr-reviewr review-herdr` directly. It reviews the uncommitted diff, read-only, and the
   comments appear in the pane within ~1–2s.
3. In the pane, `tab` to the comments rail and step through findings:
   - **`a`** — address: drafts `@file (line N): …` plus a `resolve-herdr <id>` hint into the
     adjacent agent pane (not submitted, comment kept). Add your instruction and send.
   - **`d`** — discard a comment you consider irrelevant.
   - **`s`** — send the whole comment set to the agent at once.
   - The agent clears a fixed comment by running `herdr-reviewr resolve-herdr <id>`.

## Notes

- Comments are **in-memory only**: closing the reviewr pane drops them. Re-run `review-herdr`
  to regenerate from the current diff.
- The review is strictly **read-only** — it never writes to your repository. The only side
  outputs are transient files under the temp dir (the review inbox and the resolve inbox),
  consumed on read.
- To update after pulling new changes: rebuild (`cargo build --release`), reinstall the binary
  into `bin/`, and **close + reopen** each reviewr pane (running panes keep the old binary).
