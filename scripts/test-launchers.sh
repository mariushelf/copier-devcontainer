#!/usr/bin/env bash
# Prove the host-side launcher scripts (.devcontainer/bin/*) resolve the project
# root WITHOUT git and WITHOUT being run from inside the repo.
#
# They used to start with `root="$(git rev-parse --show-toplevel)"`, which made a
# git binary AND a git working tree a hard precondition for even starting the
# container: outside a repo (fresh dir, exported tarball) the launchers aborted
# under `set -e` before ever calling `devcontainer`. They now self-locate from
# their own path, so this suite renders the template and drives each launcher
# with git shimmed to fail-loud, from a non-repo CWD, asserting:
#   (a) the launcher never invokes git,
#   (b) it still points devcontainer/docker at the rendered root, and
#   (c) the same holds when the launcher is invoked through a symlink (so the
#       root must be resolved from the real file, not the symlink's location).
#
# Fast and Docker-free (the devcontainer/docker/git binaries are shimmed) — the
# real bring-up lives in scripts/test-devcontainer.sh. Requires `uv` (uvx copier).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

COPIER=(uvx --quiet copier)
FAILED=0

echo "##### Render the template (defaults) #####"
RENDERED="$WORK/rendered"
"${COPIER[@]}" copy --defaults --trust --vcs-ref HEAD "$REPO_ROOT" "$RENDERED" >/dev/null
BIN="$RENDERED/.devcontainer/bin"
echo "  rendered to a temp dir"

# ── Shims: git fails loudly and records that it was called at all; devcontainer
# and docker are recorded no-ops that capture the CWD they ran in. Putting these
# first on PATH lets us detect any git use and inspect where the launcher ended
# up without a real Docker/devcontainer toolchain. ──
SHIM="$WORK/shim"
mkdir -p "$SHIM"
GIT_CALLED="$WORK/git-called"
CALL_LOG="$WORK/calls"

cat >"$SHIM/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$GIT_CALLED"
exit 1
EOF
# `exec` in the launchers replaces the shell with these, so recording here proves
# the launcher reached the bring-up step — and from which directory.
for tool in devcontainer docker; do
  cat >"$SHIM/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$* @ \$PWD" >> "$CALL_LOG"
EOF
done
chmod +x "$SHIM"/*

# A CWD that is not a git repo — combined with the fail-loud git shim, this is
# the "no git available / not a repo" condition the launchers must survive.
NONREPO="$WORK/not-a-repo"
mkdir -p "$NONREPO"

# run_launcher <label> <script-path> <expected-fixed-string> [-- launcher-args...]
# Runs the launcher from $NONREPO with the shims on PATH and asserts it (a) exits
# 0, (b) never called git, and (c) recorded a devcontainer/docker call containing
# <expected-fixed-string> (proving the root resolved to the rendered dir).
run_launcher() {
  local label="$1" script="$2" expected="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  : > "$GIT_CALLED"; : > "$CALL_LOG"
  echo ""
  echo "=== $label ==="
  if ( cd "$NONREPO" && PATH="$SHIM:$PATH" "$script" "$@" ) >/dev/null 2>&1; then
    echo "  [PASS] exited 0 without git or a repo"
  else
    echo "  [FAIL] launcher exited non-zero outside a git repo"; FAILED=1
  fi
  if [[ -s "$GIT_CALLED" ]]; then
    echo "  [FAIL] launcher invoked git: $(tr '\n' ';' < "$GIT_CALLED")"; FAILED=1
  else
    echo "  [PASS] git never invoked"
  fi
  if grep -qF "$expected" "$CALL_LOG"; then
    echo "  [PASS] resolved the rendered root"
  else
    echo "  [FAIL] did not resolve the rendered root"
    echo "         expected to find: $expected"
    echo "         recorded calls:   $(cat "$CALL_LOG")"
    FAILED=1
  fi
}

echo ""
echo "##### Launchers resolve the root without git #####"
# dcexec / dcrebuild cd into the root, so the recorded CWD IS the rendered root.
run_launcher "dcexec"   "$BIN/dcexec"   "@ $RENDERED"
run_launcher "dcrebuild" "$BIN/dcrebuild" "@ $RENDERED"
# dcdown does not cd; it passes the compose file path built from the root.
run_launcher "dcdown"   "$BIN/dcdown"   "$RENDERED/.devcontainer/docker-compose.yml"

echo ""
echo "##### Launchers resolve the root through a symlink #####"
# The documented install puts the bin/ dir on PATH (so ${BASH_SOURCE[0]} is the
# real file), but a hand-rolled symlink to a single launcher must also work: the
# root must come from the real file's location, not the symlink's directory.
LINKDIR="$WORK/linkdir"
mkdir -p "$LINKDIR"
ln -s "$BIN/dcexec" "$LINKDIR/dcexec"
run_launcher "dcexec via symlink" "$LINKDIR/dcexec" "@ $RENDERED"

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "LAUNCHER TESTS FAILED"
  exit 1
fi
echo "ALL LAUNCHER TESTS PASSED"
