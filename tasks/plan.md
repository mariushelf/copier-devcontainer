# Plan: issue #16 — activate agent teams by default

- [x] Task 1: Add `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to `containerEnv`
  in `template/.devcontainer/devcontainer.json.jinja`, and assert it in
  `scripts/check_render.py` so `make test-render` covers the default.
  - Acceptance: `check_render.py` fails without the containerEnv entry (RED),
    passes with it (GREEN); `make test-render` passes end to end.
  - Verified: RED confirmed manually, then GREEN; `make test-render` and
    `scripts/shellcheck.sh` both pass. `make test-devcontainer` (live
    Docker boot) could not be run — no Docker in this sandbox.
