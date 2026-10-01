#!/usr/bin/env bash
# herdr-prod user config. Copied to the plugin config dir on first run; your copy
# there wins over these defaults. All keys are overridable from the environment.

# How the dashboard finds "production" for each repo: the latest GitHub Deployment
# to this environment whose newest status is `success`. Gate deployments (e.g.
# approval-gate-prod) sit at `waiting` and are naturally skipped — only an
# approved, shipped deploy reaches `success`.
: "${PROD_ENV:=prod}"

# Refresh cadence (seconds). Each repo costs a handful of `gh` calls, so a lower
# value means more API load; the fetch is bounded-parallel across repos.
: "${INTERVAL:=120}"

# approval gate (environment with required reviewers). Enter on a repo opens
# https://github.com/<repo>/deployments/<PROD_GATE_ENV> so you can approve/review
# the pending production run.
: "${PROD_GATE_ENV:=approval-gate-prod}"

# Age thresholds (days). At/under FRESH_DAYS the age is green; at/over STALE_DAYS
# it is red; in between it is yellow.
: "${PROD_FRESH_DAYS:=2}"
: "${PROD_STALE_DAYS:=7}"

# Bounded parallelism for the per-repo fetch.
: "${PROD_FETCH_PARALLEL:=8}"

# Commits-ahead at/over which the count is emphasised in the row.
: "${PROD_WARN_COMMITS:=1}"

# Merged-PR backlog over which the "N PR" count turns red (a large undeployed
# backlog is a release risk, like a stale age).
: "${PROD_WARN_PRS:=10}"

# Dashboard workspace label.
: "${WS_LABEL:=Prod}"

# The repo list this dashboard watches. It is independent from the PR dashboard:
# on first run we SEED it from herdr-prs/repos.conf (so it starts with the repos
# you already track), then the ctrl-e picker edits this file alone. Point
# REPOS_FILE elsewhere to override. Only the owner/repo column is read.
: "${REPOS_FILE:=$HERE/repos.conf}"
: "${PROD_SEED_FROM:=$HERE/../herdr-prs/repos.conf}"

# The pool the ctrl-e picker offers (same team as the PR dashboard by default).
# PICK_TEAM empty ⇒ every repo you can access in PICK_ORG.
: "${PICK_ORG:=vippsas}"
: "${PICK_TEAM:=team-risky-business}"
