VERSION        ?= 0.1.0
OCM            ?= $(shell command -v ocm 2>/dev/null || echo bin/ocm)
OCM_CLI_VERSION ?= v0.17.0
GOOS           ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH_RAW     := $(shell uname -m)
GOARCH         ?= $(subst aarch64,arm64,$(subst x86_64,amd64,$(GOARCH_RAW)))

export VERSION OCM

.PHONY: help tools build sign verify publish lint test kind-config kind e2e clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

tools: ## Download the OCM CLI into bin/ocm and fetch kind binary
	@mkdir -p bin
	curl -sSfL \
		"https://github.com/open-component-model/open-component-model/releases/download/$(OCM_CLI_VERSION)/ocm-$(GOOS)-$(GOARCH)" \
		-o bin/ocm
	chmod +x bin/ocm
	@bash scripts/fetch-kind.sh

build: ## Build the OCM component archive (CTF)
	@bash scripts/build.sh

sign: ## Sign the component archive
	@bash scripts/sign.sh

verify: ## Verify signatures on the component archive
	@bash scripts/verify.sh

kind-config: ## Download the kind cluster config from the OCM component
	@bash scripts/kind-config.sh

kind: build sign ## Install the verified kind binary into build/deploy/bin/kind
	@bash scripts/kind-bin.sh

publish: ## Transfer the CTF to an OCI registry (requires OCM_REPO=...)
	@bash scripts/publish.sh

lint: ## Lint shell scripts (if shellcheck is available)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh test/run.sh; \
	else \
		echo "shellcheck not installed, skipping shell lint"; \
	fi

test: ## Run the test suite
	@bash test/run.sh

e2e: build sign ## End-to-end test using kind (requires docker)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	rm -rf build bin
