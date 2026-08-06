# reviewr — local AI review

A fork of [reviewr](https://github.com/persiyanov/herdr-reviewr) that adds a **local,
pre-commit Copilot review**. Run `review-herdr` and it reviews your **uncommitted** changes,
then shows the findings as GitHub-PR-style comments inside the reviewr pane — beside your agent,
in the terminal, before you commit or push. Address a comment straight into the agent, discard
the noise, and let the agent resolve what it fixes.

<p align="center">
  <a href="#install">install</a> · <a href="#use">use</a> · <a href="#controls">controls</a> · <a href="#herdr-projects">projects picker</a> · <a href="#herdr-prs">PR dashboard</a> · <a href="#how-it-works">how it works</a> · <a href="#notes--limitations">notes</a>
</p>

## Install

This fork has **no prebuilt release** — you build it from source and link the checkout as a
herdr plugin.

**Prerequisites:** herdr ≥ 0.7.5 · [GitHub Copilot CLI](https://github.com/github/copilot-cli) ·
a Rust toolchain (`rustup`) · git · a truecolor terminal.

```bash
# 1. Clone (default branch is `ai-review`, so you land on it directly)
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

**To update after pulling:** rebuild (`cargo build --release`), reinstall the binary into
`bin/`, and **close + reopen** each reviewr pane — a running pane keeps the old binary until you
toggle it off and on.

## Use

1. In herdr, open the **reviewr** pane (the plugin's toggle action; default: right split).
2. In an agent window inside the repo you're working on, type **`review-herdr`** (the skill), or
   run `herdr-reviewr review-herdr` directly. It reviews the uncommitted diff, read-only, and the
   comments appear in the pane within ~1–2s.
3. `tab` to the comments rail and step through the findings with the [controls](#controls) below.

The review never writes to your repository. It runs Copilot over your local diff and streams the
findings back into the pane — nothing is committed, pushed, or posted anywhere.

## Controls

On the comments rail (local AI review):

| key | action |
| --- | --- |
| `a` | **address** — drafts `@file (line N): …` plus a `resolve-herdr <id>` hint into the adjacent agent pane. Not submitted, comment kept — add your instruction and send. |
| `d` | **discard** — drop a comment you consider irrelevant. |
| `s` | **send** — hand the whole comment set to the agent at once. |
| `r` | **resolve** — clear a comment yourself. |

The agent clears a comment it has fixed by running `herdr-reviewr resolve-herdr <id>`, which
removes it from the review — so findings vanish as they're actually resolved, not the moment you
hand them off.

### On the PR tab

The **PR** tab mirrors the branch's real pull request (GitHub / GitLab / Azure DevOps),
read-only. There too you can press **`a`** on a selected comment to draft it into the agent pane
— an anchored finding as `@path (line N): body`, an unanchored review as `PR comment from
author: body`. It's address-only: nothing is consumed, resolved, or posted back to the forge.

## herdr-projects

This repo also bundles a small companion herdr plugin under [`herdr-projects/`](herdr-projects/).
Press **`prefix+p`** to pop up a fuzzy picker of your git projects; pick one and herdr opens a
fresh workspace with an **agent** pane (left) and a **reviewer** pane (right, the reviewr plugin
above).

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
Requirements: `herdr`, `fzf` (falls back to a numbered menu), and `jq`. See
[`herdr-projects/README.md`](herdr-projects/README.md) for the full reference.

## herdr-prs

Also bundled: [`herdr-prs/`](herdr-prs/), a **persistent PR dashboard**. One hotkey jumps you to a
dedicated `PRs` workspace listing every open pull request across your chosen repos, **oldest at
the top**, auto-refreshing. Press **Enter** on a PR and it runs `gh pr checkout` in your local
clone and opens the same **agent + reviewer** work workspace — so the reviewer's PR tab lands
right on it and you can start working.

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

The repos it watches live in [`herdr-prs/repos.conf`](herdr-prs/repos.conf) (one `owner/repo` per
line, optional TAB + local path), seeded with your locally-cloned team repos. Behaviour
(`INTERVAL`, `AGENT_CMD`, `REVIEWER`, …) is a seeded `config.sh` in the plugin config dir.
Requirements: `herdr`, `gh` (authenticated), `fzf`, `jq`, `git`. See
[`herdr-prs/README.md`](herdr-prs/README.md) for the full reference.

## How it works

- **`review-herdr`** (Copilot skill → `herdr-reviewr review-herdr`) runs Copilot over your
  uncommitted diff and writes the findings to a transient review inbox under the temp dir. The
  running pane polls that inbox and ingests the comments, each stamped with a stable id.
- **`a` (address)** exports one comment's prompt into the agent pane and focuses it, without
  submitting — you stay in control of what's sent.
- **`resolve-herdr <id>`** writes to a resolve inbox the pane polls; the matching comment is
  dropped from the review. This is how the agent clears what it fixes.
- Everything is **read-only** against your repo. The only side outputs are transient files under
  the temp dir (the review inbox and the resolve inbox), consumed on read.

See [`specs/ai-review.md`](specs/ai-review.md) for the full behaviour and
[`SETUP.md`](SETUP.md) for the same steps in prose.

## Notes & limitations

- Comments are **in-memory only**: closing the reviewr pane drops them. Re-run `review-herdr` to
  regenerate from the current diff.
- Comment ids are **per-session** — resolving an id that no longer exists is a silent no-op.
- The upstream reviewr features are all still here (diff review, line comments, file viewer,
  search, PR view, markdown preview, themes). This fork only *adds* the local AI review and the
  PR-tab `a` hand-off; it changes none of the read-only guarantees.

---

Upstream: [persiyanov/herdr-reviewr](https://github.com/persiyanov/herdr-reviewr) ·
License: see [LICENSE](LICENSE).
