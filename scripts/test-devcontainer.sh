#!/usr/bin/env bash
# Build and boot the rendered devcontainer with the devcontainers/cli, then
# assert the live container works: Claude Code is installed, commands run, and
# the default-deny firewall blocks out-of-allowlist egress.
#
# This is the real-session check: `up` runs post-create (plugins, MCP, ~590MB
# model warm-up) and the post-start firewall, exactly as an interactive session
# would. It is intentionally heavy — run scripts/test-render.sh for the fast,
# Docker-free render checks.
#
# Runs identically locally and in CI (there is no CI/local branching here; CI
# simply exports GH_TOKEN). Requires Docker, node/npx (for the devcontainers
# CLI), uv (`uvx copier`), and a GitHub token via $GH_TOKEN or `gh auth token`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Preflight: hard-require the toolchain (no silent skips) ───────────
missing=()
command -v docker >/dev/null 2>&1 || missing+=("docker")
command -v npx    >/dev/null 2>&1 || missing+=("npx (node)")
command -v uvx    >/dev/null 2>&1 || missing+=("uvx (uv)")
if [ "${#missing[@]}" -ne 0 ]; then
  echo "ERROR: test-devcontainer.sh needs: ${missing[*]}" >&2
  echo "       (run 'make test-render' for the Docker-free render checks)" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: the Docker daemon is not running." >&2
  exit 1
fi

# ── Resolve a GitHub token (env wins, else host gh auth) ─────────────
# post-create.sh runs `gh auth setup-git` under `set -e`; without a token it
# exits non-zero and sinks `devcontainer up` (waitFor blocks on the full
# lifecycle). CI exports GH_TOKEN=github.token; locally we fall back to the
# host's gh credentials so the same script works either way.
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
if [ -z "$GH_TOKEN" ]; then
  echo "ERROR: no GitHub token available. Set \$GH_TOKEN or run 'gh auth login'." >&2
  exit 1
fi

WORK="$(mktemp -d)"
RENDERED="$WORK/rendered"
COMPOSE_FILE="$RENDERED/.devcontainer/docker-compose.yml"
cleanup() {
  # Tear down the container and its named volumes, then the temp render.
  [ -f "$COMPOSE_FILE" ] && docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

DEVCONTAINER=(npx -y @devcontainers/cli)
FAILED=0

echo "##### Render the template (defaults) #####"
# An explicit target path makes project_name default to its basename, so
# --defaults needs no interactive answer.
uvx copier copy --defaults --trust "$REPO_ROOT" "$RENDERED" >/dev/null

# The compose service loads .devcontainer/.env via env_file, so the token
# reaches gh inside the container exactly as real gh auth would.
echo "GH_TOKEN=$GH_TOKEN" > "$RENDERED/.devcontainer/.env"

echo ""
echo "##### Build and start the devcontainer #####"
# Full bring-up: runs post-create (plugins, MCP, model warm-up) and the
# post-start firewall, just like a real session. A failure here leaves nothing
# to probe, so bail early (the cleanup trap still tears things down).
if ! "${DEVCONTAINER[@]}" up --workspace-folder "$RENDERED"; then
  echo "DEVCONTAINER TESTS FAILED (bring-up failed)"
  exit 1
fi

echo ""
echo "##### Verify Claude is installed and commands run #####"
# A successful exec of `claude --version` proves both claims at once: the
# binary is present AND commands execute inside the container.
# shellcheck disable=SC2016  # $(...) is meant to expand inside the container
if "${DEVCONTAINER[@]}" exec --workspace-folder "$RENDERED" \
     bash -lc 'set -euo pipefail; echo "claude at: $(command -v claude)"; claude --version; echo "exec OK"'; then
  echo "  [PASS] claude installed and commands run in the container"
else
  echo "  [FAIL] claude check failed"; FAILED=1
fi

echo ""
echo "##### Probe the firewall blocks out-of-allowlist egress #####"
# The firewall is already active — postStartCommand ran init-firewall.sh and
# `waitFor: postStartCommand` blocked `up` until it finished — so this just
# execs curl. Three out-of-allowlist destinations (two domains + one bare IP)
# must be blocked; an allowed-host control must stay reachable, proving the
# firewall is selective rather than the container simply having no egress.
# Probes force IPv4 (-4): the allowlist is an IPv4 ipset and IPv6 egress is
# intentionally unfiltered (see init-firewall.sh "Known limitation"), so a
# v6-capable curl could otherwise slip past it. Blocked connections fail fast —
# the firewall REJECTs with icmp-port-unreachable — so --max-time is a backstop.
# shellcheck disable=SC2016  # $1/$failed are meant to expand inside the container
if "${DEVCONTAINER[@]}" exec --workspace-folder "$RENDERED" bash -lc '
    set -uo pipefail
    failed=0
    probe_blocked() {
      if curl -4 -sS --max-time 10 -o /dev/null "$1" 2>/dev/null; then
        echo "  [FAIL] $1 was reachable but the firewall should block it"; failed=1
      else
        echo "  [PASS] $1 blocked as expected"
      fi
    }
    probe_blocked https://example.com
    probe_blocked https://www.wikipedia.org
    probe_blocked https://1.1.1.1
    if curl -4 -sS --max-time 20 -o /dev/null https://api.github.com 2>/dev/null; then
      echo "  [PASS] allowed host api.github.com reachable"
    else
      echo "  [FAIL] allowed host api.github.com unreachable — firewall too strict or no egress at all"; failed=1
    fi
    exit "$failed"
  '; then :; else FAILED=1; fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "DEVCONTAINER TESTS FAILED"
  exit 1
fi
echo "ALL DEVCONTAINER TESTS PASSED"
