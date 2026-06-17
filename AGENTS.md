# Project Guidelines

You are an honest advisor, not a cheerleader.
You are also an experienced software engineer.

## What this repository is

This is a **Copier template**, not an application. It renders a Python +
Claude Code devcontainer into an existing repository. There is no application
code to build or run here — the "product" is the generated `.devcontainer/`
and `.envrc`.

The core design decisions (inject-don't-scaffold, per-developer self-contained
ignore, dedicated answers file, parameterized container name, firewall
allow-list as data, narrow `.jinja` templating surface, best-effort update)
are documented in [README.md](README.md) § Design decisions. Read that before
changing template behavior, and keep it in sync when a decision changes.

## This is a PUBLIC repository

Never commit secrets or anything that identifies a specific downstream
project:

- No real tokens, API keys, or credentials — `.env` is git-ignored everywhere;
  only `.env.example` with placeholders is committed.
- No private project's name, domains, hostnames, internal URLs, or
  domain-specific vocabulary leaking in from a repository this template was
  copied into. Keep everything generic.
- Before pushing, scan the diff for the above. When in doubt, redact.

## Template structure

- `copier.yml` — questions and Copier config. Keep questions minimal and
  well-defaulted.
- `template/` — the `_subdirectory` rendered into the destination. Only files
  ending in `.jinja` are processed by Jinja (`_templates_suffix`); everything
  else is copied verbatim. To parameterize a new value, give the file a
  `.jinja` suffix and reference the answer; don't broaden the suffix.
- Answers are recorded in
  `.devcontainer/.copier-answers.devcontainer.yml` so the template coexists
  with other Copier templates in the same project.

## Working on the template

- **Render before claiming it works.** Unit-style checks aren't enough for a
  template — generate it and inspect the output. `make test-render` automates
  this across several answer sets (spaces/uppercase in `project_name`, emptied
  and custom `allowed_domains`, both values of `gitignore_devcontainer`),
  asserting the answers flow into the right files, rendered shell passes
  `bash -n`, JSON/YAML parse, and no unrendered Jinja remains — run it after any
  template change. To eyeball a single render by hand:
  ```bash
  uvx copier copy --defaults --trust . /tmp/render-check
  ```
- A genuine live run means actually building and booting the rendered
  devcontainer — passing a render check does not prove the container builds.
  `make test-devcontainer` does this via the devcontainer CLI: it renders the
  template, `devcontainer up`s it (full real-session lifecycle, including the
  post-start firewall), execs `claude --version`, and probes that the firewall
  blocks out-of-allowlist egress. It needs Docker, node/npx, and a GitHub token
  (`$GH_TOKEN` or `gh auth`). The **same** target runs in the CI `devcontainer`
  job on PRs — there is no separate CI code path. `make test` runs both suites.
- Keep the rendered tree generic: no vocabulary or hosts tied to any one
  project belong in the defaults.

## Git Conventions

Use semantic commit messages:

- `feat:` new feature
- `fix:` bug fix (something was actually broken)
- `docs:` documentation changes
- `style:` formatting (no behavior change)
- `refactor:` restructuring without changing behavior
- `test:` adding or updating tests
- `chore:` maintenance, dependency/CI/config changes, cleanup
