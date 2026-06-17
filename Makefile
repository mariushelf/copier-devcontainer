# Template test harness. There is no application to build here — the tests
# render the template and assert the output, and (for the devcontainer suite)
# build and boot the rendered container. Both suites run identically locally
# and in CI; the only difference is which target you run.
.PHONY: test shellcheck test-render test-devcontainer help

help:
	@echo "make test               Run all checks (shellcheck + render + devcontainer)."
	@echo "make shellcheck         ShellCheck the harness + rendered devcontainer scripts (fast, no Docker)."
	@echo "make test-render        Render answer sets + copier update smoke test (fast, no Docker)."
	@echo "make test-devcontainer  Build & boot the rendered devcontainer; verify Claude + firewall."
	@echo "                        Requires Docker, node/npx, and a GitHub token (\$$GH_TOKEN or gh auth)."

test: shellcheck test-render test-devcontainer

shellcheck:
	./scripts/shellcheck.sh

test-render:
	./scripts/test-render.sh

test-devcontainer:
	./scripts/test-devcontainer.sh
