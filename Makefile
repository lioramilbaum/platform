.PHONY: help tools fetch-image lint test kind-config kind e2e clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

tools: ## Fetch the pinned kind binary
	@bash scripts/fetch-kind.sh

fetch-image: ## Fetch and save the pinned kind node image (connected Docker required)
	@bash scripts/fetch-kind-image.sh

kind-config: ## Write the kind cluster config into build/deploy
	@bash scripts/kind-config.sh

kind: ## Install the pinned kind binary into build/deploy/bin/kind
	@bash scripts/kind-bin.sh

lint: ## Lint shell scripts (if shellcheck is available)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh test/run.sh; \
	else \
		echo "shellcheck not installed, skipping shell lint"; \
	fi

test: ## Run the test suite
	@bash test/run.sh

e2e: fetch-image ## End-to-end test using kind (requires docker)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	rm -rf build bin
