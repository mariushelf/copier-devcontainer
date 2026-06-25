#!/usr/bin/env bash
# Render the template under several answer sets and assert the output is
# correct. This is the template's *render* test suite — it exercises Copier
# output only: no Docker, no container bring-up. The live container checks
# (build, Claude, firewall) live in scripts/test-devcontainer.sh.
#
# Stages:
#   1. Render each answer set, run scripts/check_render.py against it.
#   2. `copier update` round-trip smoke test (proves the answers file lets an
#      already-rendered project pull a later template version).
#
# Runs identically everywhere — there is no CI/local branching here. Requires
# `uv` (provides `uvx copier` and `uv run --with pyyaml python`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# copier update commits to a throwaway git repo; give it an identity that does
# not depend on the host's git config.
export GIT_AUTHOR_NAME="render-test" GIT_AUTHOR_EMAIL="render-test@example.com"
export GIT_COMMITTER_NAME="render-test" GIT_COMMITTER_EMAIL="render-test@example.com"

PY=(uv run --quiet --with pyyaml python)
COPIER=(uvx copier)
FAILED=0

# render <out-subdir> <project_name> <allowed_domains_json|-> <gitignore> [browser|-]
# Writes a spec file and runs the checker. allowed_domains "-" means "use the
# template defaults" (the checker resolves them from copier.yml). browser "-"
# (the default) leaves install_headless_browser unset so the template default
# applies; "true"/"false" force the answer and the checker asserts the
# Dockerfile's browser block is present/absent accordingly.
render() {
  local sub="$1" pname="$2" domains="$3" gitignore="$4" browser="${5:--}"
  local out="$WORK/$sub"
  echo ""
  echo "=== render: $sub ==="
  local args=(copy --defaults --trust --vcs-ref HEAD)
  [[ -n "$pname" ]] && args+=(-d "project_name=$pname")
  [[ "$domains" != "-" ]] && args+=(-d "allowed_domains=$domains")
  args+=(-d "gitignore_devcontainer=$gitignore")
  [[ "$browser" != "-" ]] && args+=(-d "install_headless_browser=$browser")
  "${COPIER[@]}" "${args[@]}" "$REPO_ROOT" "$out" >/dev/null

  # project_name "" means the defaults case: copier used dst_path.name == $sub.
  local expected_pname="${pname:-$sub}"
  local domains_field="$domains"
  [[ "$domains" == "-" ]] && domains_field="null"
  # browser "-" -> null (don't assert the block either way for this render).
  local browser_field="$browser"
  [[ "$browser" == "-" ]] && browser_field="null"

  local spec="$WORK/$sub.spec.json"
  cat >"$spec" <<JSON
{
  "label": "$sub",
  "dir": "$out",
  "project_name": "$expected_pname",
  "allowed_domains": $domains_field,
  "gitignore_devcontainer": $gitignore,
  "install_headless_browser": $browser_field,
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
# headless browser on -> Dockerfile gains the gated Chromium block
render "browser-on" "" "-" "true" "true"
# headless browser explicitly off -> block absent (defaults already cover false,
# but assert it explicitly so a flipped default can't pass silently)
render "browser-off" "" "-" "true" "false"

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
if [[ "$FAILED" -ne 0 ]]; then
  echo "RENDER TESTS FAILED"
  exit 1
fi
echo "ALL RENDER TESTS PASSED"
