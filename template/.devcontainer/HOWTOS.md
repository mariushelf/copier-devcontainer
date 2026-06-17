# How-tos

Step-by-step guides for the two recurring devcontainer tasks: updating the
firewall allow-list and rotating the GitHub token. Each task has two paths: the
**hot path** takes effect in the running container; the **permanent path**
survives a restart. The hot path alone is reverted on the next container start,
so changes that must persist require the permanent path.

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

Inside the container, export the new token:

```bash
export GH_TOKEN=<new-token>
```

`gh` and git use the new token immediately, as does any process started from
this shell — including Claude Code launched with `claude` from the same shell.
The override is confined to the current shell: already-running sessions keep the
old token, and the value is lost when the shell exits or the container restarts.

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
