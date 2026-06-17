#!/usr/bin/env bash
#
# custom-post-create.sh — DEVELOPER-OWNED create-time hook. THIS FILE IS YOURS.
#
# Invoked by .devcontainer/scripts/post-create.sh once, after the container is
# created and its volumes are mounted. Put anything that must run at create
# time here — most importantly Claude Code plugins, marketplaces, and MCP
# servers, which live under $CLAUDE_CONFIG_DIR (~/.claude): that is a runtime
# volume which does not exist at image-build time, so it cannot be done in
# custom-build.sh. It is deliberately not tied to any one tool — add any
# first-run steps you need.
#
# The Copier template renders this file once and then leaves it alone
# (`_skip_if_exists` in copier.yml), so a `copier update` will NOT overwrite
# your edits.
#
# Runs as `dev`, before the network firewall is applied (open network), so
# marketplace/plugin downloads and model warm-ups work. NO `set -e` on purpose:
# steps are independent and best-effort, so one failure does not skip the rest,
# and post-create.sh treats this whole script as non-fatal — a flaky install
# never blocks your dev environment. Keep steps idempotent (they re-run if the
# container is recreated).
#
# Binaries a plugin expects on PATH (e.g. ast-grep, pyright) are installed in
# custom-build.sh — keep the two in sync.

# ── Claude Code marketplaces ────────────────────────────────────────
claude plugin marketplace add anthropics/claude-plugins-official --scope user
claude plugin marketplace add mariushelf/claude-swe-tools --scope user
claude plugin marketplace add ast-grep/agent-skill --scope user
claude plugin marketplace add zilliztech/memsearch --scope user

# ── Claude Code plugins ─────────────────────────────────────────────
claude plugin install superpowers --scope user
claude plugin install pyright-lsp --scope user
claude plugin install commit-commands --scope user
claude plugin install frontend-design --scope user
claude plugin install swe-tools --scope user
claude plugin install memsearch --scope user
claude plugin install ast-grep --scope user

# ── Claude Code MCP servers ─────────────────────────────────────────
# context7 self-installs via `npx -y` (needs only node — no custom-build.sh entry).
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp@latest

# ── Warm the memsearch ONNX embedding model cache ───────────────────
# Pre-pull the ~590MB model now (once) so the first interactive session does
# not pay the download latency; persisted by the hf-cache volume.
# HF_HUB_DISABLE_XET forces the classic single-stream LFS path (hf_xet's
# parallel download wedges behind the runtime firewall proxy).
if command -v memsearch >/dev/null 2>&1; then
    echo "    Warming memsearch ONNX model cache (one-time ~590MB download)..."
    HF_HUB_DISABLE_XET=1 memsearch search warmup >/dev/null 2>&1 || true
fi
