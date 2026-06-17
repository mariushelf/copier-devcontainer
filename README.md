# copier-devcontainer

A [Copier](https://copier.readthedocs.io/) template that injects a fully
configured **Python + Claude Code devcontainer** into an existing repository —
uv, pre-commit, the GitHub CLI, a zsh/Powerlevel10k shell, a curated set of
Claude Code plugins, and a **default-deny network firewall**. The firewall is
what makes it safe to run Claude Code with `--dangerously-skip-permissions`:
outbound traffic is restricted to an explicit allow-list and credentials are
scoped.

It is designed to be applied **on top of** an existing project (not to scaffold
a new one), and to coexist with other Copier templates already used in that
project.

## Quick start

Apply the devcontainer to the current repository:

```bash
# from the root of an existing repo
uvx copier copy gh:mariushelf/copier-devcontainer "$(pwd)"
```

Copier asks three questions (all with sensible defaults — see below), writes the
`.devcontainer/` folder and an `.envrc`, and records your answers in
`.devcontainer/.copier-answers.devcontainer.yml`.

> Use `"$(pwd)"` rather than `.` so the `project_name` question is pre-filled
> with your repository's folder name. (With a bare `.`, Copier can't see the
> folder name, so you'd type it at the prompt or pass `-d project_name=...`.)

Pull later template improvements into a project you've already set up:

```bash
uvx copier update
```

> `copier update` compares **released versions**, so it only finds updates once
> this template publishes git tags (e.g. `v0.1.0`). Until a release is tagged,
> `copier copy` works but `update` reports nothing newer.

## Questions

| Question | Default | Purpose |
|----------|---------|---------|
| `project_name` | the destination folder's name | Devcontainer display name; slugified into the Docker Compose project name. |
| `allowed_domains` | Claude Code, GitHub, PyPI, npm, Context7, HuggingFace | The firewall allow-list. Remove entries to disallow them; add your project's APIs / mirrors / docs sites. |
| `gitignore_devcontainer` | `true` | Whether to keep the devcontainer out of version control as per-developer setup. |

## What you get

The rendered `.devcontainer/` is self-documenting:

- `.devcontainer/README.md` — full tour of the image, lifecycle, volume
  strategy, and the network firewall.
- `.devcontainer/HOWTOS.md` — updating the firewall allow-list and rotating the
  GitHub token.
- `.devcontainer/FUTURE_WORK.md` — known firewall limitations and candidate
  hardenings.

An `.envrc` ([direnv](https://direnv.net/)) is also written at the repo root; it
puts the host-side helper scripts (`dcc` — launch Claude Code in the container,
`dcexec`, `dcrebuild`, `dcdown`, `dczsh`) on your `PATH` and exports your UID/GID
into the Compose build.

## Design decisions

These are the choices that shape the template; they are intentional, not
incidental.

1. **Inject, don't scaffold.** The template targets *existing* repositories. It
   only adds `.devcontainer/` and `.envrc`; it never rewrites project files.

2. **Per-developer by default, via a self-contained ignore.** `.devcontainer/`
   is treated as individual dev setup. When `gitignore_devcontainer` is true the
   template writes `.devcontainer/.gitignore` containing `*`, so the folder
   ignores *itself* — including the Copier answers file — and injecting the
   devcontainer changes **zero** tracked files in the host repo (no edit to the
   repo's root `.gitignore`). When false, the devcontainer is committed and only
   `.env` stays ignored, so secrets are never tracked either way.

3. **Own answers file for multi-template coexistence.** Answers are recorded in
   `.devcontainer/.copier-answers.devcontainer.yml` (not the default
   `.copier-answers.yml`), so this template can be applied alongside a project's
   primary Copier template without their answer files colliding.

4. **Parameterized container name, derived from the environment.** The
   previously hard-coded name is now `project_name`, defaulting to the
   destination directory's basename (`_copier_conf.dst_path.name`). It feeds both
   the devcontainer display name and the slugified Docker Compose project name so
   host helpers and the devcontainer CLI converge on one project.

5. **Firewall allow-list is data, not code.** The allow-list is a Copier answer
   rendered into `init-firewall.sh`, pre-populated with only generic tooling
   hosts. Projects add their own domains at copy time instead of editing the
   script.

6. **Narrow templating surface.** `_templates_suffix: .jinja` means only the few
   files needing variables are rendered through Jinja; everything else is copied
   verbatim, so brace-heavy files (e.g. `.p10k.zsh`) pass through untouched.

7. **Update is best-effort when ignored.** With the devcontainer git-ignored
   there is no committed baseline, so `copier update`'s three-way merge degrades
   toward overwrite — local hand-edits to generated files are more fragile. This
   is an accepted trade-off for per-developer setup. Choose
   `gitignore_devcontainer: false` if you want robust team-shared updates.

8. **Project setup lives in two developer-owned hook scripts, not the
   template.** Anything project-specific — extra tools, Claude Code plugins, MCP
   servers, first-run steps — goes in one of two scripts the template renders
   once and then never overwrites (`_skip_if_exists`), so they are yours to edit
   and a `copier update` pulls wiring improvements *around* them without
   clobbering their contents:

   - **`.devcontainer/custom-build.sh`** runs at **image-build time** (the last
     `RUN`, as the `dev` user) for things worth baking into a cached layer:
     extra CLIs, language servers, the binaries your plugins expect on `PATH`.
     It is last because it churns most and Docker only rebuilds layers *after*
     the first change; `uv tool install` lands on Claude's `PATH`, while
     root-only system packages stay in the Dockerfile's apt block.
   - **`.devcontainer/custom-post-create.sh`** runs at **container-create time**
     (invoked by `post-create.sh`) for steps that need the running container —
     above all Claude Code plugins / MCP servers, which live in the `~/.claude`
     runtime volume that does not exist at build time.

   A deliberate non-goal: the template does *not* resolve or manage these for
   you (no manifest-to-installer machinery, no JSON plugin manifest). Direct
   `uv` / `claude` commands in a script you own are simpler and more transparent
   than reinventing apt/uv/npm behind a leakier interface.

## Development

The template is tested by rendering it under several answer sets and asserting
the output:

```bash
make test
```

This renders the defaults, the `gitignore_devcontainer=false` variant, a
messy `project_name` (asserting the Compose name is a valid lowercased slug),
and emptied/custom `allowed_domains` lists. For each render it checks that
`project_name` and `allowed_domains` flow into the right files, the
`.gitignore` matches the ignore choice, rendered shell passes `bash -n`,
`devcontainer.json` is valid JSONC, `docker-compose.yml` is valid YAML, and no
unrendered Jinja remains. It also runs a `copier update` round-trip.

Locally, `make test` additionally builds the rendered devcontainer image (needs
Docker). In CI that build is skipped (`$CI` is set), so a render check still
passes without a Docker runner — a passing render does not prove the image
builds, only that it renders correctly.

CI runs on [GitHub Actions](.github/workflows/ci.yaml) in two jobs:

- **`render`** — runs `make test` on every push and PR (no Docker needed).
- **`devcontainer`** — on PRs (and manual dispatch) only, renders the template
  and uses the [devcontainer CLI](https://github.com/devcontainers/cli) to
  `up` the rendered container and `exec` `claude --version` inside it. This is
  the live check `make test` skips in CI: it proves the image builds, Claude
  Code is installed, and commands can run in the container. It's slow (full
  image build plus the post-create plugin installs and model warm-up), which is
  why it doesn't run on every push. To block merges on it, mark `devcontainer`
  a required status check in the branch-protection rule for `master`.

## Requirements

- [uv](https://github.com/astral-sh/uv) (to run `uvx copier`) or Copier
  installed directly.
- To actually run the rendered devcontainer: Docker + Docker Compose and an IDE
  with devcontainer support (or the
  [devcontainer CLI](https://github.com/devcontainers/cli)).

## License

See [LICENSE](LICENSE).
