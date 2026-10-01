# herdr-prod — production-freshness dashboard

A persistent herdr workspace that answers one question at a glance for every repo
you care about: **how long has it been since we last approved something to
production, and how much is waiting to ship?**

It is a sibling of `herdr-prs` (the open-PR dashboard) and reuses the same
`repos.conf`. Where `herdr-prs` shows *incoming* work (open PRs), `herdr-prod`
shows *outgoing* work (merged-but-undeployed changes).

## What each row shows

```
pling-backend              35d ago   ↑48    30 PR   ok       @alice             318b903
odd-offboarding             2d ago   ↑9     10 PR   running  @bob               9b1416a
risky-business-country     no prod deploy    ·         ·    ·        ·                  -------
```

- **age** — days since the repo's last *successful* production deploy. Green at or
  under `PROD_FRESH_DAYS` (2), **red** at or over `PROD_STALE_DAYS` (7), yellow in
  between. A repo with no recorded prod deploy is shown red.
- **↑N** — commits on the default branch that are ahead of what is in production.
- **N PR** — merged PRs that landed since that deploy (the backlog waiting to
  ship). Turns **red** when the backlog exceeds `PROD_WARN_PRS` (10).
- **run** — state of the *latest* prod deployment: green `ok`, **red** `failed`,
  yellow `running`/`pending`. Surfaces a broken or in-flight deploy sitting on top
  of the last good one.
- **@who** — the GitHub login that created that last successful prod deploy.
- **sha** — the short commit currently live in production.

Rows are sorted stalest-first, so the repos most overdue for a release float to
the top.

### How "production" is detected

For each repo the dashboard takes the latest GitHub **Deployment** to the
`PROD_ENV` environment (`prod` by default) whose newest status is `success`.
Approval-gate deployments (e.g. `approval-gate-prod`) sit at `waiting` until a
reviewer approves them, so they are naturally skipped — only an approved, shipped
deploy reaches `success`. The deploy's commit and finish time drive the age,
commits-ahead and merged-PR figures.

## Usage

- **Open:** `prefix + shift + p` (see the keybinding below), or the plugin's
  *Open production-freshness dashboard* action.
- **Move:** `j`/`k` or arrows, `g`/`G` for top/bottom.
- **Enter:** open the repo's **approval-gate-prod** deployments page on GitHub
  (`https://github.com/<repo>/deployments/approval-gate-prod`) so you can approve
  or review the pending production run.
- **ctrl-p:** list the merged PRs that landed since the last prod deploy for the
  selected repo; Enter again opens the chosen PR on GitHub.
- **ctrl-e:** pick which repos this dashboard watches (see below).
- **ctrl-r:** refresh now. **ctrl-o:** open the repo's GitHub deploys overview.
- **esc:** hide the dashboard (it stays live and keeps refreshing).

## Choosing which repos to watch

This dashboard keeps its **own** watch list, independent from the PR dashboard —
editing one never touches the other. On first run the list is **seeded** from
`herdr-prs/repos.conf` (so you start watching the repos you already track), then:

- Press **ctrl-e** to open the repo picker. It lists every repo your team can see,
  pre-checks the ones you already watch, and is additive: `space`/`tab` toggles,
  `ctrl-a`/`ctrl-d` select all/none, `Enter` saves, `esc` cancels.
- The pool comes from `PICK_ORG`/`PICK_TEAM` (same team as the PR dashboard by
  default). Set `PICK_TEAM=""` to offer every repo you can access in `PICK_ORG`.
- The list lives in `herdr-prod/repos.conf` (git-ignored runtime state). You can
  also edit it by hand — one `owner/repo` per line.

## Install

It is a bash plugin, linked from this working directory:

```sh
herdr plugin link ./herdr-prod
```

Because it is symlinked, code edits are the live plugin — no build, no copy.

Add a keybinding to `~/.config/herdr/config.toml`:

```toml
# Open the production-freshness dashboard (prefix = ctrl+a, then shift+p).
[[keys.command]]
key = "prefix+shift+p"
type = "plugin_action"
description = "open production-freshness dashboard"
command = "herdr-prod.open"
```

Then `herdr server reload-config`.

## Config (`config.sh`)

| Key | Default | Meaning |
|---|---|---|
| `PROD_ENV` | `prod` | GitHub environment whose last `success` deploy marks production. |
| `PROD_GATE_ENV` | `approval-gate-prod` | Environment page opened on Enter (the approval gate). |
| `INTERVAL` | `120` | Refresh cadence (seconds). Each repo costs a few `gh` calls. |
| `PROD_FRESH_DAYS` | `2` | Age at/under which the row is green. |
| `PROD_STALE_DAYS` | `7` | Age at/over which the row is red. |
| `PROD_WARN_COMMITS` | `1` | Commits-ahead at/over which the count is emphasised. |
| `PROD_WARN_PRS` | `10` | Merged-PR backlog over which the `N PR` count turns red. |
| `PROD_FETCH_PARALLEL` | `8` | Bounded parallelism for the per-repo fetch. |
| `REPOS_FILE` | `herdr-prod/repos.conf` | This dashboard's own watch list. |
| `PROD_SEED_FROM` | `../herdr-prs/repos.conf` | Seeds the watch list on first run. |
| `PICK_ORG` / `PICK_TEAM` | `vippsas` / `team-risky-business` | Pool for the ctrl-e picker. |
| `WS_LABEL` | `Prod` | Dashboard workspace label. |

`config.sh` is copied to the plugin config dir on first run; a pre-existing user
copy there overrides new defaults.

## Tests

```sh
bash test/test.sh all      # or: repos | age | render | sort | fetch | lint
```

Pure render/parse units plus a fake-`gh` fetch check and a manifest lint. No
network. Run `bash -n` on every touched script before committing.
