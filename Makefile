VERSION        ?= 0.1.0
OCM            ?= $(shell command -v ocm 2>/dev/null || echo bin/ocm)
OCM_CLI_VERSION ?= $(shell awk '/name: ocm$$/{f=1} f && /version:/{gsub(/.*: /, ""); print; exit}' component-constructor.yaml)
GOOS           ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH_RAW     := $(shell uname -m)
GOARCH         ?= $(subst aarch64,arm64,$(subst x86_64,amd64,$(GOARCH_RAW)))

export VERSION OCM

.PHONY: help tools fetch-image build sign verify publish package lint test kind-config kind e2e deploy-offline e2e-airgap clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

tools: ## Download the OCM CLI into bin/ocm and fetch kind binary
	@bash scripts/fetch-ocm.sh
	@mkdir -p bin
	cp bin/dist/ocm-$(OCM_CLI_VERSION)-$(GOOS)-$(GOARCH) bin/ocm
	chmod +x bin/ocm
	@bash scripts/fetch-kind.sh

fetch-image: ## Fetch and save the pinned kind node image (connected Docker required)
	@bash scripts/fetch-kind-image.sh

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

package: ## Transport and package signed CTF with offline bootstrap into build/release
	@bash scripts/package.sh

lint: ## Lint shell scripts (if shellcheck is available)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh test/run.sh; \
	else \
		echo "shellcheck not installed, skipping shell lint"; \
	fi

test: ## Run the test suite
	@bash test/run.sh

e2e: fetch-image build sign ## End-to-end test using kind (requires docker)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	rm -rf build bin

deploy-offline: ## Deploy PACKAGE using independently trusted VERIFY_KEY
	@bash scripts/offline-run.sh "$(PACKAGE)" "$(VERIFY_KEY)"

e2e-airgap: ## Consume PACKAGE without rebuilding or signing; verify readiness and clean up
	@KEEP_CLUSTER=0 bash scripts/offline-run.sh "$(PACKAGE)" "$(VERIFY_KEY)"
