#!/usr/bin/env bash
# Render the template under several answer sets and assert the output is
# correct. This is the template's test suite: there is no application code, so
# "does it work" means "does it render correctly".
#
# Stages:
#   1. Render each answer set, run scripts/check_render.py against it.
#   2. `copier update` round-trip smoke test (proves the answers file lets an
#      already-rendered project pull a later template version).
#   3. Docker build of the rendered devcontainer — LOCAL ONLY. Skipped when
#      $CI is set (GitHub runners set CI=true) or Docker is unavailable.
#   4. Firewall enforcement — LOCAL ONLY. Start the built container, apply its
#      default-deny firewall, and assert out-of-allowlist destinations are
#      blocked (with an allowed-host control). Gated like stage 3.
#
# CI runs stages 1-2; a local `make test` additionally runs stages 3-4.
#
# Requires `uv` (provides `uvx copier` and `uv run --with pyyaml python`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
# Set once the firewall-probe container is up so cleanup can tear it down (and
# its named volumes) even if a probe aborts the script under `set -e`.
FW_COMPOSE_FILE=""
cleanup() {
  [[ -n "$FW_COMPOSE_FILE" ]] && docker compose -f "$FW_COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# copier update commits to a throwaway git repo; give it an identity that does
# not depend on the host's git config.
export GIT_AUTHOR_NAME="render-test" GIT_AUTHOR_EMAIL="render-test@example.com"
export GIT_COMMITTER_NAME="render-test" GIT_COMMITTER_EMAIL="render-test@example.com"

PY=(uv run --quiet --with pyyaml python)
COPIER=(uvx copier)
FAILED=0
BUILT=0  # set in stage 3 once the image builds; gates the stage 4 firewall probe

# render <out-subdir> <project_name> <allowed_domains_json|-> <gitignore> [extra -d args...]
# Writes a spec file and runs the checker. allowed_domains "-" means "use the
# template defaults" (the checker resolves them from copier.yml).
render() {
  local sub="$1" pname="$2" domains="$3" gitignore="$4"; shift 4
  local out="$WORK/$sub"
  echo ""
  echo "=== render: $sub ==="
  local args=(copy --defaults --trust --vcs-ref HEAD)
  [[ -n "$pname" ]] && args+=(-d "project_name=$pname")
  [[ "$domains" != "-" ]] && args+=(-d "allowed_domains=$domains")
  args+=(-d "gitignore_devcontainer=$gitignore")
  "${COPIER[@]}" "${args[@]}" "$REPO_ROOT" "$out" >/dev/null

  # project_name "" means the defaults case: copier used dst_path.name == $sub.
  local expected_pname="${pname:-$sub}"
  local domains_field="$domains"
  [[ "$domains" == "-" ]] && domains_field="null"

  local spec="$WORK/$sub.spec.json"
  cat >"$spec" <<JSON
{
  "label": "$sub",
  "dir": "$out",
  "project_name": "$expected_pname",
  "allowed_domains": $domains_field,
  "gitignore_devcontainer": $gitignore,
  "copier_yml": "$REPO_ROOT/copier.yml",
  "template_dir": "$REPO_ROOT/template"
}
JSON

  if "${PY[@]}" "$REPO_ROOT/scripts/check_render.py" "$spec"; then :; else FAILED=1; fi
}

echo "##### Stage 1: render answer sets #####"
# defaults
render "defaults" "" "-" "true"
# devcontainer tracked in git (gitignore_devcontainer=false)
render "tracked" "" "-" "false"
# messy project name -> assert a valid lowercased Compose slug
render "messy-name" "My Cool Project 2!" "-" "true"
# emptied allowed_domains
render "no-domains" "" "[]" "true"
# small custom allowed_domains
render "custom-domains" "" '["example.com","api.example.com"]' "true"

echo ""
echo "##### Stage 2: copier update smoke test #####"
# Build a two-version history in a throwaway clone, render the old version into
# a git project, then `copier update` it to the new version and assert clean.
TPL="$WORK/tpl"; PROJ="$WORK/update-proj"
ANSWERS_FILE=".devcontainer/.copier-answers.devcontainer.yml"
git clone --quiet "$REPO_ROOT" "$TPL"
git -C "$TPL" tag render-test-base
"${COPIER[@]}" copy --defaults --trust --vcs-ref render-test-base "$TPL" "$PROJ" >/dev/null
git -C "$PROJ" init --quiet
git -C "$PROJ" add -A
git -C "$PROJ" commit --quiet -m "rendered base"
# A real (if trivial) template change so the update has something to apply.
printf '\n# copier-update smoke-test marker\n' >> "$TPL/template/.envrc"
git -C "$TPL" commit --quiet -am "chore: marker for update test"
git -C "$TPL" tag render-test-next
( cd "$PROJ" && "${COPIER[@]}" update --defaults --trust \
    --vcs-ref render-test-next --answers-file "$ANSWERS_FILE" >/dev/null )
if grep -q "copier-update smoke-test marker" "$PROJ/.envrc"; then
  echo "  [PASS] update applied the new template version"
else
  echo "  [FAIL] update did not apply the template change"; FAILED=1
fi
if find "$PROJ" -name '*.rej' | grep -q .; then
  echo "  [FAIL] update produced .rej conflict files"; FAILED=1
else
  echo "  [PASS] update produced no .rej conflict files"
fi

echo ""
echo "##### Stage 3: docker build of rendered devcontainer (local only) #####"
if [[ -n "${CI:-}" ]]; then
  echo "  [SKIP] \$CI is set — docker build is a local-only check"
elif ! docker info >/dev/null 2>&1; then
  echo "  [SKIP] Docker not available"
else
  if docker compose -f "$WORK/defaults/.devcontainer/docker-compose.yml" build; then
    echo "  [PASS] rendered devcontainer image builds"; BUILT=1
  else
    echo "  [FAIL] rendered devcontainer image failed to build"; FAILED=1
  fi
fi

echo ""
echo "##### Stage 4: firewall enforcement (local only) #####"
# Bring the rendered devcontainer up, apply its default-deny firewall, and
# assert that out-of-allowlist destinations are actually blocked. Gated like
# stage 3: needs Docker and a successfully built image, so it is skipped in CI.
#
# All probes force IPv4 (-4): the firewall is an IPv4 ipset/iptables allowlist
# and IPv6 egress is intentionally unfiltered (see init-firewall.sh "Known
# limitation"), so a v6-capable curl could otherwise slip past it and make a
# blocked target look reachable.
if [[ -n "${CI:-}" ]]; then
  echo "  [SKIP] \$CI is set — firewall probe is a local-only check"
elif [[ "$BUILT" -ne 1 ]]; then
  echo "  [SKIP] image not built (see stage 3) — nothing to probe"
else
  COMPOSE=(docker compose -f "$WORK/defaults/.devcontainer/docker-compose.yml")
  if ! "${COMPOSE[@]}" up -d >/dev/null 2>&1; then
    echo "  [FAIL] could not start the devcontainer for firewall probing"; FAILED=1
  else
    FW_COMPOSE_FILE="$WORK/defaults/.devcontainer/docker-compose.yml"
    # Apply the firewall (the dev user has a NOPASSWD sudoers entry for exactly
    # this path; the container carries NET_ADMIN/NET_RAW).
    if ! "${COMPOSE[@]}" exec -T dev sudo /usr/local/bin/init-firewall.sh \
         >"$WORK/firewall.log" 2>&1; then
      echo "  [FAIL] init-firewall.sh did not run cleanly:"
      sed 's/^/      /' "$WORK/firewall.log"; FAILED=1
    else
      # probe_blocked <url-or-ip>: a blocked destination makes curl exit
      # non-zero — the firewall REJECTs with icmp-port-unreachable, so this
      # fails fast (connection refused) rather than hanging to --max-time.
      probe_blocked() {
        local target="$1"
        if "${COMPOSE[@]}" exec -T dev curl -4 -sS --max-time 10 -o /dev/null "$target" 2>/dev/null; then
          echo "  [FAIL] $target was reachable but the firewall should block it"; FAILED=1
        else
          echo "  [PASS] $target blocked as expected"
        fi
      }
      # Three out-of-allowlist destinations: two domains and one bare IP.
      probe_blocked "https://example.com"
      probe_blocked "https://www.wikipedia.org"
      probe_blocked "https://1.1.1.1"

      # Control: an allowed host MUST stay reachable. Without it, all three
      # "blocked" checks would also pass if the container simply had no egress
      # at all — this proves the firewall is selective, not globally broken.
      # api.github.com is pre-seeded into the ipset from published GitHub CIDRs,
      # making it the most robust allowed target.
      if "${COMPOSE[@]}" exec -T dev curl -4 -sS --max-time 20 -o /dev/null https://api.github.com 2>/dev/null; then
        echo "  [PASS] allowed host api.github.com reachable"
      else
        echo "  [FAIL] allowed host api.github.com unreachable — firewall too strict or no egress at all"; FAILED=1
      fi
    fi
  fi
fi

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "RENDER TESTS FAILED"
  exit 1
fi
echo "ALL RENDER TESTS PASSED"
