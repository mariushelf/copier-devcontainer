# Template test harness. There is no application to build here — `make test`
# renders the template under several answer sets and asserts the output.
.PHONY: test help

help:
	@echo "make test   Render the template under several answer sets and assert correctness."
	@echo "            Locally this also builds the rendered devcontainer image (needs Docker);"
	@echo "            in CI (\$$CI set) the Docker build is skipped."

test:
	./scripts/test-render.sh
