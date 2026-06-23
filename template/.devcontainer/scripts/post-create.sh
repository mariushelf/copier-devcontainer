#!/bin/bash
# First-run setup: install dependencies and configure the environment.
set -e

echo "==> Fixing volume mount ownership..."
sudo /usr/local/bin/fix-volume-ownership.sh

echo "==> Configuring git to use HTTPS (host uses SSH, container uses HTTPS)..."
git config --global url."https://github.com/".insteadOf "git@github.com:"
# `gh auth setup-git` only works when gh has an authenticated GitHub host. That
# is absent for non-GitHub projects, or when no token is mounted — and under
# `set -e` its non-zero exit would abort the whole post-create. Guard it so the
# convenience is best-effort, like the custom-post-create step below.
if gh auth status >/dev/null 2>&1; then
    gh auth setup-git
else
    echo "    gh not authenticated — skipping 'gh auth setup-git'. Run it later if you push to GitHub over HTTPS."
fi

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

# ── Exclude per-developer artifacts from version control (locally) ───
# This template injects an .envrc, and custom-post-create.sh installs the
# memsearch plugin, which writes a local .memsearch index at runtime. Both are
# per-developer artifacts, not project files. To preserve the template's
# "injecting it changes zero tracked files" guarantee, list them in the repo's
# LOCAL .git/info/exclude rather than its committed .gitignore. Anything already
# tracked is left alone (a deliberate commit wins), existing entries are not
# duplicated, and the exclude path is resolved via `git rev-parse` so this also
# works inside linked worktrees — making it safe to re-run on every rebuild.
echo "==> Excluding per-developer artifacts (.envrc, .memsearch) locally..."
cd /workspace
exclude_file="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
if [ -n "$exclude_file" ]; then
    mkdir -p "$(dirname "$exclude_file")"
    for artifact in .envrc .memsearch; do
        if [ -n "$(git ls-files -- "$artifact" 2>/dev/null)" ]; then
            echo "    '$artifact' is tracked — leaving it under version control."
            continue
        fi
        if [ -f "$exclude_file" ] && grep -qxF "$artifact" "$exclude_file"; then
            continue
        fi
        printf '%s\n' "$artifact" >> "$exclude_file"
        echo "    Locally excluded '$artifact'."
    done
else
    echo "    /workspace is not a git repository — skipping local excludes."
fi

echo "==> Post-create setup complete."
