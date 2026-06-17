#!/usr/bin/env bash
#
# custom-build.sh — DEVELOPER-OWNED build-time hook. THIS FILE IS YOURS.
#
# Runs as the LAST `RUN` in the devcontainer image build, as the `dev` user.
# Put anything you want baked into the image here — extra CLI tools, language
# servers, linters, the binaries your Claude plugins expect on PATH, etc. It is
# deliberately not tied to any one tool.
#
# The Copier template renders this file once and then leaves it alone
# (`_skip_if_exists` in copier.yml), so a `copier update` will NOT overwrite
# your edits.
#
# Build-time vs custom-post-create.sh — which hook do I use?
#   * HERE (build time): things that can be baked into a cached image layer —
#     paid once at build, adding nothing to container start. Runs as `dev`, so
#     `uv tool install` lands on the dev user's PATH. This user has no general
#     sudo: system packages that need root (apt) belong in the system-packages
#     block near the top of the Dockerfile, not here.
#   * NOT here: Claude Code plugins/MCP servers. Those live under
#     $CLAUDE_CONFIG_DIR (~/.claude), a runtime volume that does not exist at
#     build time — install them in custom-post-create.sh instead.
#
# Keep entries idempotent. `set -euo pipefail` makes a failed install fail the
# image build loudly rather than ship an image with a silently-missing tool.
set -euo pipefail

# Tools the bundled Claude plugins expect on PATH:
# ast-grep / sg — structural AST search (`ast-grep` plugin).
uv tool install ast-grep-cli
# pyright — language server (`pyright-lsp` plugin).
uv tool install pyright
# memsearch — semantic memory search (`memsearch` plugin). Baked here so the
# first session is fast and offline-safe; the plugin can also self-bootstrap
# via `uvx --from memsearch[onnx]`.
uv tool install 'memsearch[onnx]'
