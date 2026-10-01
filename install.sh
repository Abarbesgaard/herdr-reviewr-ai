#!/usr/bin/env bash
# One-command onboarding for reviewr-local-ai.
#
# Builds the herdr-reviewr binary from source, links this checkout as a herdr plugin,
# and installs the `review-herdr` Copilot skill. Optionally links the bundled companion
# plugins (herdr-projects, herdr-prs) and wires their keybindings.
#
# Usage:
#   ./install.sh                 # core: reviewr plugin + review-herdr skill
#   ./install.sh --with-projects # also link herdr-projects (prefix+p picker)
#   ./install.sh --with-prs      # also link herdr-prs (prefix+r PR dashboard)
#   ./install.sh --all           # core + both companions
#   ./install.sh --help
#
# Idempotent: safe to re-run to update after `git pull`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WITH_PROJECTS=0
WITH_PRS=0

for arg in "$@"; do
  case "$arg" in
    --with-projects) WITH_PROJECTS=1 ;;
    --with-prs)      WITH_PRS=1 ;;
    --all)           WITH_PROJECTS=1; WITH_PRS=1 ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$arg' (try --help)" >&2
      exit 2
      ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Prerequisites -----------------------------------------------------------
say "Checking prerequisites"
command -v herdr >/dev/null 2>&1 || die "herdr not found. Install herdr >= 0.7.5 first (https://herdr.dev)."
command -v cargo >/dev/null 2>&1 || die "cargo not found. Install a Rust toolchain via https://rustup.rs — this fork has no prebuilt release."
command -v git   >/dev/null 2>&1 || die "git not found."
command -v copilot >/dev/null 2>&1 || warn "GitHub Copilot CLI ('copilot') not found — needed for the review-herdr skill at runtime (https://github.com/github/copilot-cli)."

# --- Build the binary --------------------------------------------------------
say "Building herdr-reviewr (release) — first build can take a few minutes"
( cd "$ROOT" && cargo build --release )
mkdir -p "$ROOT/bin"
install -m 0755 "$ROOT/target/release/herdr-reviewr" "$ROOT/bin/herdr-reviewr"
say "Binary installed at bin/herdr-reviewr"

# --- Link a plugin idempotently ---------------------------------------------
# herdr plugin link errors if the id is already linked; treat that as success.
link_plugin() {
  local path="$1" name="$2"
  if herdr plugin link "$path" 2>/tmp/herdr-link.$$; then
    say "Linked $name"
  elif grep -qi 'already' /tmp/herdr-link.$$; then
    say "$name already linked — skipping"
  else
    cat /tmp/herdr-link.$$ >&2
    rm -f /tmp/herdr-link.$$
    die "Failed to link $name"
  fi
  rm -f /tmp/herdr-link.$$
}

say "Linking the reviewr plugin"
link_plugin "$ROOT" "reviewr"

# --- Install the Copilot skill ----------------------------------------------
say "Installing the review-herdr Copilot skill"
mkdir -p "$HOME/.copilot/skills/review-herdr"
cp "$ROOT/skills/review-herdr/SKILL.md" "$HOME/.copilot/skills/review-herdr/SKILL.md"

# --- Keybinding helper (idempotent append to ~/.config/herdr/config.toml) ----
CFG="$HOME/.config/herdr/config.toml"
add_keybind() {
  local key="$1" desc="$2" command="$3"
  mkdir -p "$(dirname "$CFG")"; touch "$CFG"
  if grep -qF "command = \"$command\"" "$CFG"; then
    say "Keybinding for $command already present — skipping"
    return
  fi
  cat >> "$CFG" <<TOML

[[keys.command]]
key = "$key"
type = "plugin_action"
description = "$desc"
command = "$command"
TOML
  say "Bound $key -> $command"
}

# --- Optional companion: herdr-projects -------------------------------------
if [[ "$WITH_PROJECTS" == 1 ]]; then
  say "Setting up herdr-projects (prefix+p project picker)"
  command -v fzf >/dev/null 2>&1 || warn "fzf not found — herdr-projects falls back to a numbered menu."
  command -v jq  >/dev/null 2>&1 || warn "jq not found — herdr-projects needs it."
  link_plugin "$ROOT/herdr-projects" "herdr-projects"
  add_keybind "prefix+p" "open project picker" "herdr-projects.open"
fi

# --- Optional companion: herdr-prs ------------------------------------------
if [[ "$WITH_PRS" == 1 ]]; then
  say "Setting up herdr-prs (prefix+r PR dashboard)"
  command -v gh  >/dev/null 2>&1 || warn "gh not found (or not authenticated) — herdr-prs needs the GitHub CLI."
  command -v fzf >/dev/null 2>&1 || warn "fzf not found — herdr-prs needs it."
  command -v jq  >/dev/null 2>&1 || warn "jq not found — herdr-prs needs it."
  link_plugin "$ROOT/herdr-prs" "herdr-prs"
  add_keybind "prefix+r" "open PR dashboard" "herdr-prs.open"
fi

# --- Reload config so keybindings take effect --------------------------------
if [[ "$WITH_PROJECTS" == 1 || "$WITH_PRS" == 1 ]]; then
  say "Reloading herdr config"
  herdr server reload-config || warn "Could not reload herdr config — restart herdr, or run 'herdr server reload-config'."
fi

# --- Done --------------------------------------------------------------------
cat <<'DONE'

Done. Next steps:
  1. Open the reviewr pane in herdr (the plugin's toggle action; default: right split).
  2. In an agent window inside your repo, type: review-herdr
     (or run: herdr-reviewr review-herdr) to review your uncommitted diff.
DONE
if [[ "$WITH_PRS" == 1 ]]; then
  echo "  3. In the PR dashboard (prefix+r), press ctrl-e to pick which repos to watch."
fi
echo
echo "To update later: git pull && ./install.sh, then close + reopen each reviewr pane."
