#!/bin/bash
# First-run setup: install dependencies and configure the environment.
set -e

echo "==> Fixing volume mount ownership..."
sudo /usr/local/bin/fix-volume-ownership.sh

echo "==> Configuring git to use HTTPS (host uses SSH, container uses HTTPS)..."
git config --global url."https://github.com/".insteadOf "git@github.com:"
gh auth setup-git

echo "==> Installing Python dependencies..."
cd /workspace
if [ -f pyproject.toml ]; then
    uv sync
else
    echo "    No pyproject.toml found — skipping uv sync."
fi

# ── Developer-owned create-time steps (non-fatal) ─────────────────
# Runs the developer's custom-post-create.sh: Claude Code plugins, MCP servers,
# model warm-ups, and any other steps that must run once after the volumes are
# mounted (e.g. plugins live in the ~/.claude volume, absent at image-build
# time). Kept non-fatal so a flaky install never blocks the dev environment.
# Runs BEFORE the status-line merge below, which expects a settings.json that
# the plugin setup may have written.
CUSTOM_POST_CREATE="/workspace/.devcontainer/custom-post-create.sh"
if [ -f "$CUSTOM_POST_CREATE" ]; then
    echo "==> Running custom-post-create.sh (Claude plugins, MCP servers, ...)..."
    bash "$CUSTOM_POST_CREATE" || echo "    custom-post-create.sh exited non-zero — continuing."
    echo "==> custom-post-create.sh complete."
else
    echo "==> No custom-post-create.sh found — skipping custom create-time steps."
fi

# ~/.claude is a Docker volume mounted at runtime, so the Dockerfile cannot write there.
# post-create.sh runs after the volume is mounted, making it the right place to provision
# files into ~/.claude. We use jq-merge (not overwrite) because custom-post-create.sh
# above may have already written plugin configs into settings.json.
echo "==> Configuring Claude Code status line..."
STATUSLINE_SRC="/workspace/.devcontainer/dotfiles/statusline-command.sh"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [ -f "$STATUSLINE_SRC" ]; then
    mkdir -p "$HOME/.claude"
    cp "$STATUSLINE_SRC" "$HOME/.claude/statusline-command.sh"
    chmod +x "$HOME/.claude/statusline-command.sh"
    if [ -f "$CLAUDE_SETTINGS" ]; then
        tmp=$(mktemp)
        jq '. + {"statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}}' \
            "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    else
        echo '{"statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}}' \
            > "$CLAUDE_SETTINGS"
    fi
    echo "    Status line configured."
fi

echo "==> Installing pre-commit hooks..."
cd /workspace
if [ -f .pre-commit-config.yaml ]; then
    git config --unset-all core.hooksPath 2>/dev/null || true
    pre-commit install
else
    echo "    No .pre-commit-config.yaml found — skipping pre-commit install."
fi

echo "==> Post-create setup complete."
