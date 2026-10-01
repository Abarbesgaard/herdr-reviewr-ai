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

The quickest path is the bundled installer, which builds the binary, links the plugin, and
installs the skill (add `--all` to also set up the `herdr-projects` and `herdr-prs` companions):

```bash
git clone https://github.com/Abarbesgaard/reviewr-local-ai
cd reviewr-local-ai
./install.sh          # or: ./install.sh --all
```

<details>
<summary>Or do it by hand</summary>

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

</details>

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

## Optional: the `herdr-projects` plugin (prefix+p project picker)

This repo also bundles a small companion herdr plugin under `herdr-projects/`. Press
**`prefix+p`** to pop up a fuzzy picker of your git projects; pick one and herdr opens a fresh
workspace with an **agent** pane (left) and a **reviewer** pane (right, the reviewr plugin above).
See `herdr-projects/README.md` for details and configuration.

> `./install.sh --with-projects` (or `--all`) does the link + keybinding + config reload below for you.

```bash
# Link it as a herdr plugin (from the repo root)
herdr plugin link ./herdr-projects

# Bind prefix+p to its picker in ~/.config/herdr/config.toml
cat >> ~/.config/herdr/config.toml <<'TOML'

[[keys.command]]
key = "prefix+p"
type = "plugin_action"
description = "open project picker"
command = "herdr-projects.open"
TOML

# Reload herdr config
herdr server reload-config
```

First run seeds a config at `$(herdr plugin config-dir herdr-projects)/config.sh` — edit that copy
to set the directories it scans (`ROOTS`), the agent command, and how the reviewer pane is opened.
Requirements: `herdr`, `fzf` (falls back to a numbered menu), and `jq`.

## Optional: the `herdr-prs` plugin (PR dashboard)

This repo also bundles `herdr-prs/`, a persistent **PR dashboard**: a dedicated `PRs` workspace
(jumped to with a hotkey) that lists every open pull request across your chosen repos, oldest
first, auto-refreshing. Press **Enter** on a PR and it runs `gh pr checkout` in your local clone
and opens the same agent + reviewer work workspace, so the reviewer's PR tab lands on it.

> `./install.sh --with-prs` (or `--all`) does the link + keybinding + config reload below for you.

```bash
# Link it as a herdr plugin (from the repo root)
herdr plugin link ./herdr-prs

# Bind prefix+r to the dashboard in ~/.config/herdr/config.toml
cat >> ~/.config/herdr/config.toml <<'TOML'

[[keys.command]]
key = "prefix+r"
type = "plugin_action"
description = "open PR dashboard"
command = "herdr-prs.open"
TOML

# Reload herdr config
herdr server reload-config
```

Choose the repos it watches by pressing **`ctrl-e`** in the dashboard to pick from your team
(`PICK_ORG`/`PICK_TEAM`), or seed `herdr-prs/repos.conf` by hand — `cp herdr-prs/repos.conf.example
herdr-prs/repos.conf` then edit (one `owner/repo` per line, optional TAB + local path). The file is
git-ignored per-machine state, so a fresh checkout starts empty. Behaviour lives in a seeded
`$(herdr plugin config-dir herdr-prs)/config.sh` (`INTERVAL`, `AGENT_CMD`, `REVIEWER`, …).
Requirements: `herdr`, `gh` (authenticated), `fzf`, `jq`, `git`. See `herdr-prs/README.md`.

## Notes

- Comments are **in-memory only**: closing the reviewr pane drops them. Re-run `review-herdr`
  to regenerate from the current diff.
- The review is strictly **read-only** — it never writes to your repository. The only side
  outputs are transient files under the temp dir (the review inbox and the resolve inbox),
  consumed on read.
- To update after pulling new changes: rebuild (`cargo build --release`), reinstall the binary
  into `bin/`, and **close + reopen** each reviewr pane (running panes keep the old binary).
