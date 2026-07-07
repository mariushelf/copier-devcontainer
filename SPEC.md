# Spec: Activate agent teams by default (issue #16)

## Source

GitHub issue #16: "Activate agent teams by default. Ship a `.env` file with
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`."

## Clarification

`.devcontainer/.env` is always gitignored in this template (either via a
blanket `*` when the devcontainer folder itself is untracked, or via an
explicit `.env` rule otherwise — see `template/.devcontainer/.gitignore.jinja`),
and nothing in the template auto-copies `.env.example` to `.env`. Shipping the
flag only in `.env`/`.env.example` would therefore require every downstream
project to manually create `.env` before the flag takes effect, which does not
satisfy "by default".

Decision (confirmed with the repo owner): set the flag in `containerEnv` in
`template/.devcontainer/devcontainer.json.jinja`, alongside the other
unconditional container environment variables (`TZ`, `HISTFILE`, etc.). This
is committed template output, applies to every generated devcontainer without
any manual step, and is a non-secret feature flag so there is no reason to
route it through the gitignored `.env` mechanism reserved for credentials.

## Requirements

1. `template/.devcontainer/devcontainer.json.jinja`'s `containerEnv` block
   gains `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"`.
2. `scripts/check_render.py` asserts the rendered `devcontainer.json` sets
   this value, for every answer set exercised by `scripts/test-render.sh`
   (so the default can't silently regress).
3. No changes to `.env`/`.env.example` — those remain reserved for secrets,
   per the existing file header comment.

## Out of scope

- Making the flag configurable via a Copier question (issue doesn't ask for
  this; can be a follow-up if someone wants to opt out).
- Any documentation beyond what's needed to explain the containerEnv entry in
  place, since the file has no per-key documentation for `TZ`/`HISTFILE` either.
