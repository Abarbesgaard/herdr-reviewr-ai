# herdr-prs

A [herdr](https://herdr.dev) plugin: a **persistent PR dashboard**. One hotkey
jumps you to a dedicated `PRs` workspace that lists every open pull request across
the repos you choose — **oldest at the top** — and auto-refreshes. Press **Enter**
on a PR and it checks the branch out in your local clone and opens the usual
**agent + reviewer** work workspace, so you go from "what needs attention" to
"working on it" without leaving the terminal.

```
┌──────────────────────── workspace: PRs ─────────────────────────┐
│ PR ▸                                                            │
│   ongoing-due-diligence  #1307  Store onfido timeline…  ✓  11d  │
│ ★ pling-backend          #74    Emit DigitalServiceAct… ✓  1d   │
│ ★ terms-and-conditions   #7     Newest but pending…     •  1h   │
│  ★ = new since last visit · enter: work on it · ctrl-r: refresh │
└─────────────────────────────────────────────────────────────────┘
```

## How it works

- **The action** `herdr-prs.open` (bind it to a key, e.g. `prefix+r`) focuses the
  `PRs` workspace, creating it the first time and starting the live list in its
  pane. Re-opening re-baselines the ★ "new" markers, so a visit clears them and
  only genuinely new PRs light up.
- **The list** (`dashboard.sh`) is `fzf` fed by `gen.sh`, which fetches open,
  non-draft PRs for every repo in `repos.conf` via `gh`, sorts them oldest-first,
  and renders `repo · #num · title · @author · [review] · CI · age`. It
  auto-refreshes every `INTERVAL` seconds and on `ctrl-r`.
- **Enter** runs `open-pr.sh`: `gh pr checkout <n>` in the repo's local clone,
  then a new workspace labelled `repo #num` with an **agent** pane (left) and a
  **reviewer** pane (right, the `persiyanov.reviewr` plugin by default). Because
  the PR branch is checked out, the reviewer's **PR tab** lands right on it.

The dashboard never writes to your repos beyond `gh pr checkout`, and it refuses
to switch branches in a clone with uncommitted changes.

## Install (local / development)

```sh
# from the repo root, link this plugin directory
herdr plugin link ./herdr-prs
```

Bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+r"
type = "plugin_action"
description = "open PR dashboard"
command = "herdr-prs.open"
```

Reload herdr: `herdr server reload-config`.

**Requirements:** `herdr`, [`gh`](https://cli.github.com) (authenticated),
[`fzf`](https://github.com/junegunn/fzf), `jq`, `git`.

## Configure

### Which repos — `repos.conf`

One repo per line, `owner/repo` then an optional TAB and the local clone path.
Lines with no path are resolved by scanning `ROOTS` (see below). Comes seeded with
your locally-cloned `team-risky-business` (vippsas) repos — trim or add freely:

```
vippsas/ongoing-due-diligence	/Users/you/Development/Rider/ongoing-due-diligence
vippsas/pling-backend
```

### Behaviour — `config.sh`

First run seeds a config at `$(herdr plugin config-dir herdr-prs)/config.sh`. Edit
that copy:

| Setting     | Meaning                                                        |
| ----------- | ------------------------------------------------------------- |
| `REPOS_FILE`| Path to the repo list (default: `repos.conf` beside the plugin).|
| `ROOTS`     | Directories scanned to resolve a repo with no explicit path.  |
| `INTERVAL`  | Auto-refresh cadence in seconds (default `60`).               |
| `WS_LABEL`  | Label of the dashboard workspace (default `PRs`).            |
| `AGENT_CMD` | Command run in the left **agent** pane of the work workspace. |
| `REVIEWER`  | The right pane: `plugin:<id>:<entrypoint>`, `cmd:<line>`, or `shell`. |

## Keys

| key           | action                                             |
| ------------- | -------------------------------------------------- |
| `j` / `k`     | move down / up (or `↑` / `↓`)                       |
| `g` / `G`     | jump to top / bottom                               |
| `ctrl-d`/`ctrl-u` | half-page down / up                            |
| type text     | filter the list                                    |
| `enter`       | check out the PR and open its work workspace       |
| `ctrl-r`      | refresh now                                        |
| `ctrl-o`      | open the PR on GitHub                              |
| `esc`         | hide (the dashboard pane stays live)               |

## Test

```sh
bash test/test.sh          # all
bash test/test.sh render   # just the row renderer
```

Pure-logic tests cover the renderer and the ★ marking; the side-effecting scripts
(`open-pr.sh`, `action-open.sh`) are dry-run against fake `gh`/`herdr`/`git`.
