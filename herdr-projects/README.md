# herdr-projects

A [herdr](https://herdr.dev) plugin: press **`prefix+p`** to pop up a fuzzy
picker of your git projects. Choose one and herdr opens a fresh **workspace**
named after the project, with a left **agent** pane and a right **reviewer**
pane.

```
┌─────────────── workspace: <project name> ───────────────┐
│                         │                               │
│   agent  (copilot)      │   reviewer (persiyanov.reviewr)│
│                         │                               │
└─────────────────────────┴───────────────────────────────┘
```

## How it works

- **`prefix+p`** is bound (in `config.toml`) to the plugin action
  `herdr-projects.open`.
- The action opens the `picker` entrypoint as a **popup** pane running
  `projects.sh`.
- `projects.sh` scans the configured `ROOTS` for git repos (any dir with a
  `.git`) and shows them in `fzf`.
- On selection it runs `open.sh`, which:
  1. `herdr workspace create --cwd <project> --label <name> --focus`
  2. renames the root pane to **agent** and runs `AGENT_CMD`
  3. opens the **reviewer** on the right (your `persiyanov.reviewr` plugin
     pane by default)

## Install (local / development)

```sh
# from the repo root, link this plugin directory
herdr plugin link ./herdr-projects
```

Then add the keybinding to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
description = "open project picker"
command = "herdr-projects.open"
```

Reload herdr: `herdr server reload-config` (or `reload config` from the menu).

## Configuration

First run seeds a config at:

```
$(herdr plugin config-dir herdr-projects)/config.sh
```

Edit that file:

| Setting      | Meaning                                                                 |
| ------------ | ----------------------------------------------------------------------- |
| `ROOTS`      | Bash array of directories to scan for git projects (tilde expanded).    |
| `SCAN_DEPTH` | Max depth below each root to search for `.git`.                         |
| `AGENT_CMD`  | Command run in the left pane. Empty = shell. Default `command copilot`. |
| `REVIEWER`   | `plugin:<id>:<entrypoint>`, `cmd:<command>`, or `shell`.                |

`AGENT_CMD` defaults to `command copilot` (not `copilot`) so it bypasses the
`copilot()`/`claude()` zsh wrappers — otherwise they would *also* auto-open a
reviewr pane, and you'd get two.

## Requirements

`herdr`, `fzf` (falls back to a numbered menu), and `jq`.

## Uninstall

```sh
herdr plugin unlink herdr-projects
```
