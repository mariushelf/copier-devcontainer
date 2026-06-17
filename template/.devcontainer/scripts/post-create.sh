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

# ── Warm the memsearch ONNX embedding model cache ─────────────────
# Pre-pull the ~590MB model now (once) so the first interactive session
# doesn't pay the download latency. Runs pre-firewall (open network) and
# is persisted by the hf-cache volume. HF_HUB_DISABLE_XET forces the
# classic single-stream LFS path; hf_xet's parallel download wedges
# behind the runtime firewall proxy. Non-fatal: never block setup.
if command -v memsearch >/dev/null 2>&1; then
    echo "==> Warming memsearch ONNX model cache (one-time ~590MB download)..."
    HF_HUB_DISABLE_XET=1 memsearch search warmup >/dev/null 2>&1 || true
fi

# ── Claude Code plugins & MCP servers (non-fatal) ─────────────────
# Reads .devcontainer/claude-setup.json and installs plugins/MCP servers
# natively so all paths resolve correctly inside the container.
# Failures here never block the dev environment.
CLAUDE_SETUP="/workspace/.devcontainer/claude-setup.json"
if [ -f "$CLAUDE_SETUP" ] && command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "==> Setting up Claude Code plugins and MCP servers..."
    set +e

    jq -r '.marketplaces[]' "$CLAUDE_SETUP" | while read -r marketplace; do
        echo "    Adding marketplace: $marketplace"
        claude plugin marketplace add "$marketplace" --scope user 2>&1
    done

    jq -r '.plugins[]' "$CLAUDE_SETUP" | while read -r plugin; do
        echo "    Installing plugin: $plugin"
        claude plugin install "$plugin" --scope user 2>&1
    done

    while read -r server; do
        name=$(echo "$server" | jq -r '.name')
        cmd=$(echo "$server" | jq -r '.command')
        args=$(echo "$server" | jq -r '.args // [] | .[]')
        echo "    Adding MCP server: $name"
        # shellcheck disable=SC2086
        claude mcp add --scope user "$name" -- "$cmd" $args 2>&1
    done < <(jq -c '.mcp_servers[]' "$CLAUDE_SETUP")

    set -e
    echo "==> Claude Code setup complete."
else
    echo "==> Skipping Claude Code setup (claude-setup.json or claude CLI not found)."
fi

# ~/.claude is a Docker volume mounted at runtime, so the Dockerfile cannot write there.
# post-create.sh runs after the volume is mounted, making it the right place to provision
# files into ~/.claude. We use jq-merge (not overwrite) because the Claude plugin setup
# step above has already written plugin configs into settings.json.
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

# ── Verify plugin host-dependencies are present ───────────────────
# Plugins declared in claude-setup.json that expect a binary on PATH
# (provided by the Dockerfile's plugin host-dependencies block). This
# turns silent drift — add a plugin, forget its Dockerfile line — into
# a loud warning instead of a mysterious runtime failure. Self-
# bootstrapping plugins (context7 via npx) are intentionally omitted.
echo "==> Verifying plugin host-dependencies..."
declare -A PLUGIN_BIN=(
    [ast-grep]=ast-grep
    [pyright-lsp]=pyright
    [memsearch]=memsearch
)
missing=0
for plugin in "${!PLUGIN_BIN[@]}"; do
    bin="${PLUGIN_BIN[$plugin]}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "    ⚠️  plugin '$plugin' expects '$bin' on PATH — NOT FOUND" \
             "(add it to the Dockerfile plugin host-dependencies block)"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ] && echo "    All plugin host-dependencies present."

echo "==> Post-create setup complete."
