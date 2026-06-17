#!/usr/bin/env bash
# Static-analyse every shell script with ShellCheck. `bash -n` (run per render
# in scripts/check_render.py) only proves a script *parses*; ShellCheck catches
# the runtime bugs that parse fine — unquoted word-splitting (SC2046), return
# values masked by `local x=$(...)` (SC2155), subshell variable loss, and the
# `set -e` interactions these scripts lean on.
#
# Two sets are linted:
#   1. The harness scripts under scripts/ — source, never rendered.
#   2. The rendered devcontainer scripts — init-firewall.sh is templated
#      (.jinja), so it must be rendered before ShellCheck can parse it (a raw
#      `.jinja` trips on Jinja tags); the rest are copied verbatim and rendered
#      here too for one uniform sweep.
#
# Runs identically everywhere — there is no CI/local branching here. Requires
# `uv` (provides `uvx copier` and the pinned ShellCheck via shellcheck-py).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pin ShellCheck (via the shellcheck-py wheel) so the gate cannot drift when a
# new release adds checks — mirrors the SHA-pinned GitHub Actions.
SHELLCHECK=(uvx --quiet --from "shellcheck-py==0.11.0.1" shellcheck)
COPIER=(uvx --quiet copier)

echo "##### Render the template (defaults) for linting #####"
RENDER="$WORK/render"
"${COPIER[@]}" copy --defaults --trust --vcs-ref HEAD "$REPO_ROOT" "$RENDER" >/dev/null
echo "  rendered to a temp dir"

# Collect targets: harness sources + every rendered shell script (matched by a
# .sh suffix or living in a bin/ dir — the same glob scripts/check_render.py
# uses to find scripts for `bash -n`).
targets=("$REPO_ROOT"/scripts/*.sh)
while IFS= read -r -d '' f; do
  targets+=("$f")
done < <(find "$RENDER/.devcontainer" -type f \( -name '*.sh' -o -path '*/bin/*' \) -print0)

echo ""
echo "##### ShellCheck (${#targets[@]} scripts) #####"
for t in "${targets[@]}"; do
  rel="${t#"$REPO_ROOT"/}"
  rel="${rel#"$RENDER"/}"
  echo "  $rel"
done
echo ""

if "${SHELLCHECK[@]}" "${targets[@]}"; then
  echo "ALL SHELLCHECK PASSED"
else
  echo "SHELLCHECK FAILED"
  exit 1
fi
