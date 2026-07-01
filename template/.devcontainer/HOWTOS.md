# How-tos

Step-by-step guides for the recurring devcontainer tasks: updating the firewall
allow-list, rotating the GitHub token, and customizing the image and Claude
plugins. Each task has two paths: the **hot path** takes effect in the running
container; the **permanent path** survives a restart. The hot path alone is
reverted on the next container start, so changes that must persist require the
permanent path.

## Updating the firewall allow-list

The allow-list is the `ALLOWED_HOSTS` array in
`.devcontainer/init-firewall.sh`. Add or remove domains there first.

Two copies of the script exist: the bind-mounted source under `/workspace`, and
a snapshot baked into the image at `/usr/local/bin/init-firewall.sh`.
`postStartCommand` runs the baked snapshot on every start, so an edit to the
source does not take effect until the snapshot is rebuilt. The script is
idempotent — it flushes the ipset and the `OUTPUT` chain and restarts dnsmasq —
so re-running it at any time is safe.

### Hot path — apply edits to the running container

Requires Docker access on the host. Run from the repository root:

```bash
docker compose -f .devcontainer/docker-compose.yml exec -u root dev \
    bash /workspace/.devcontainer/init-firewall.sh
```

This runs the edited source directly as root, bypassing the baked snapshot. The
new rules apply immediately. The container's `dev` user cannot perform this step
itself — its sudo grant is scoped to the baked path only.

### Permanent path — bake edits into the image

```bash
dcrebuild
```

`dcrebuild` re-copies `init-firewall.sh` into the image and recreates the
container; `postStartCommand` then applies the updated rules. A script-only
change rebuilds in seconds because the Docker layer cache is reused. Named
volumes (`.venv`, Claude config, shell history) are preserved.

## Rotating the GitHub token

`GH_TOKEN` authenticates `gh` and git (via `gh auth setup-git`). It is supplied
by `.devcontainer/.env` and resolved into the container environment at container
creation. `gh` reads `GH_TOKEN` from the environment on every invocation and
prefers it over any stored credential.

### Hot path — use a new token in the current session

Two options, depending on how far the new token needs to reach.

**Just this shell.** Export it:

```bash
export GH_TOKEN=<new-token>
```

`gh` and git use the new token immediately in this shell, and in anything
started from it (including `claude` launched from the same shell). It does
*not* reach other shells: one already open, or one you `dcexec`/`dczsh` into
afterward, still inherits the old token from the container's environment. The
export is also lost when this shell exits.

**Every shell in the container.** `gh` checks the `GH_TOKEN` environment
variable on every invocation and prefers it over any stored credential, so it
has to be out of the way first:

```bash
unset GH_TOKEN
```

Do this in every shell that currently has it set (`gh auth status` shows
whether a shell is still using `GH_TOKEN` as its token source) — otherwise
that shell keeps using the old token no matter what you do next. Then
re-authenticate `gh` itself, which writes to `gh`'s own config file rather
than to one shell's environment, so every shell in the container reads the
same file:

```bash
gh auth login
```

- Choose **GitHub.com**
- Choose **HTTPS**
- Answer **No** to "Authenticate Git with your GitHub credentials?"
- Choose **Paste an authentication token**, then paste the new token

Then point git's credential helper at it:

```bash
gh auth setup-git
```

Both commands land immediately in every shell in the container that doesn't
have `GH_TOKEN` set — nothing to re-export per-shell, and no restart needed.

### Permanent path — replace the token for all sessions

Edit `GH_TOKEN` in `.devcontainer/.env`, then recreate the container from the
repository root:

```bash
devcontainer up --workspace-folder . --remove-existing-container
```

The recreate reloads `.env`, re-applies the firewall, and preserves named
volumes; the image is not rebuilt. A plain restart (stop and start of the same
container) does not reload `.env` — the environment is fixed when the container
is created, so a recreate is required.

## Customizing the image and Claude plugins

Project-specific setup lives in two scripts you own (see
[Customization hooks](README.md#customization-hooks) for what each is for):

- `.devcontainer/custom-build.sh` — runs at **image-build time** (the last
  `RUN`). Edit it to bake in extra tools / the binaries your plugins expect on
  `PATH`.
- `.devcontainer/custom-post-create.sh` — runs at **container-create time**.
  Edit it to install Claude Code plugins / MCP servers and other first-run
  steps.

How a change takes effect differs by script, and the create-time hook has a
persistence gotcha worth knowing.

### `custom-build.sh` — rebuild the image

A build-hook edit is only baked in by a rebuild:

```bash
dcrebuild
```

Because `custom-build.sh` is the last image layer, a change to it rebuilds in
seconds — the system/Python/Claude layers above are reused from cache. Named
volumes (`.venv`, Claude config, shell history) are preserved.

### `custom-post-create.sh` — recreate the container

The create hook runs on every container *creation*, so recreating re-runs it:

```bash
dcrebuild
```

`dcrebuild` recreates the container (`--remove-existing-container`), which fires
`postCreateCommand` → your `custom-post-create.sh` again. Keep the steps
idempotent (e.g. `claude plugin install` is safe to re-run) so a recreate is
always clean.

> **Hot path** — to try a step without recreating, run it directly in the
> container: `dcexec bash` then `claude plugin install <name> --scope user` (or
> `bash .devcontainer/custom-post-create.sh` to re-run all of it). This affects
> the running container immediately; persist it by also adding the line to
> `custom-post-create.sh`.

### Gotcha: removing a plugin doesn't uninstall it

Claude plugins live under `$CLAUDE_CONFIG_DIR` (`~/.claude`), which is a **named
volume that persists across rebuilds** — that is the whole reason plugins are
installed at create time rather than baked into the image. The flip side: the
volume keeps state you may want gone.

- **Adding** a plugin works as expected — add the `claude plugin install` line,
  `dcrebuild`, and the recreate installs it into the existing volume.
- **Removing** a plugin needs an explicit step. Deleting the line from
  `custom-post-create.sh` does *not* uninstall it, because the recreate never
  drops the volume that still holds it. Either uninstall it directly:

  ```bash
  dcexec bash -lc 'claude plugin uninstall <name> --scope user'
  ```

  or rebuild from a clean Claude config (this also re-downloads the memsearch
  model and any other volume-cached state):

  ```bash
  dcrebuild --wipe   # removes named volumes, then rebuilds and recreates
  ```
