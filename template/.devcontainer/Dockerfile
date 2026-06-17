FROM ghcr.io/astral-sh/uv:latest AS uv

# Ubuntu 26.04 LTS ships git 2.53, which supports relative worktrees
# (worktree.useRelativePaths, added in git 2.48). Debian bookworm (2.39) and
# even Ubuntu 24.04 (2.43) / trixie (2.47) predate it, so they would need a
# git-core PPA or a source build; 26.04's stock apt git is enough on its own.
FROM ubuntu:26.04

# ── Build args ──────────────────────────────────────────────────────
ARG PYTHON_VERSION=3.13
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

# ── Layer 1: System packages (changes very rarely) ──────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Dev tools
    git zsh fzf jq ripgrep vim sudo less curl ca-certificates gpg make \
    # Firewall
    iptables ipset iproute2 dnsutils dnsmasq \
    # Claude Code dependencies
    sox socat \
    && rm -rf /var/lib/apt/lists/*

# ── Relative worktrees ──────────────────────────────────────────────
# Make `git worktree add` (including Claude Code's worktree creation) emit
# relative paths instead of absolute ones, so worktrees survive the repo
# being mounted at a different path. Requires git >= 2.48 (satisfied by the
# Ubuntu 26.04 base above). Set system-wide so it applies to every user.
RUN git config --system worktree.useRelativePaths true

# ── Layer 2: GitHub CLI (not in default Ubuntu repos) ───────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Layer 3: uv binary (Python itself is installed later as dev) ────
COPY --from=uv /uv /usr/local/bin/uv
COPY --from=uv /uvx /usr/local/bin/uvx

# ── Layer 4: Non-root user + firewall sudo ──────────────────────────
# Ubuntu 24.04+ ships a stock `ubuntu` user at UID/GID 1000. Reclaim that
# id so our `dev` user can own it (bind-mount/volume ownership assumes 1000).
RUN userdel -r ubuntu 2>/dev/null || true; groupdel ubuntu 2>/dev/null || true

RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/zsh ${USERNAME} \
    && echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/fix-volume-ownership.sh" \
        > /etc/sudoers.d/${USERNAME}-firewall \
    && chmod 0440 /etc/sudoers.d/${USERNAME}-firewall

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/fix-volume-ownership.sh /usr/local/bin/fix-volume-ownership.sh
RUN printf '#!/bin/sh\nexec claude --dangerously-skip-permissions "$@"\n' > /usr/local/bin/claudesp \
    && chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/fix-volume-ownership.sh /usr/local/bin/claudesp

# Pre-create directories that will be volume mount targets so they're
# owned by dev, not root (Docker creates missing mount targets as root).
# .cache/huggingface is volume-mounted to persist the memsearch ONNX model.
RUN mkdir -p /home/${USERNAME}/.claude /commandhistory /workspace/.venv \
        /home/${USERNAME}/.cache/huggingface \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.claude /commandhistory /workspace/.venv \
        /home/${USERNAME}/.cache

USER ${USERNAME}

# ── Oh My Zsh + Powerlevel10k (installed as dev) ────────────────────
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

COPY --chown=${USERNAME}:${USERNAME} dotfiles/.zshrc dotfiles/.p10k.zsh /home/${USERNAME}/

# ── Python (installed as dev into uv's default ~/.local/share/uv/python) ──
RUN uv python install ${PYTHON_VERSION}

# ── Claude Code (native binary) ────────────────────────────────────
WORKDIR /tmp
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

# ── pre-commit (project dev tool, installed via uv) ─────────────────
RUN uv tool install pre-commit

# ── Developer-owned build-time hook (last layer) ───────────────────
# custom-build.sh is where you bake project-specific tools into the image —
# extra CLIs, language servers, and the binaries your Claude plugins expect on
# PATH. The Copier template renders it ONCE and then leaves it alone
# (`_skip_if_exists`), so it is yours to edit and a `copier update` will not
# clobber it. (Claude plugins themselves install in custom-post-create.sh, not
# here — they live in a runtime volume absent at build time.)
#
# Deliberately the last RUN: this hook churns more often than anything above,
# and Docker invalidates every layer after the first change — so keeping it
# last leaves the expensive system/Python/Claude layers cached when only the
# hook changes. The COPY sits immediately above the RUN (not with the earlier
# bulk COPYs) for the same reason: editing the script then invalidates just
# this COPY+RUN pair. It runs as ${USERNAME}, so `uv tool install` lands on the
# dev user's PATH; root-only system packages belong in the apt block up top.
COPY --chown=${USERNAME}:${USERNAME} custom-build.sh /tmp/custom-build.sh
RUN bash /tmp/custom-build.sh

WORKDIR /workspace
