# platform

A minimal but complete platform built with the [Open Component Model](https://ocm.software) (OCM v2).

## Component tree

```
github.com/lmilbaum/platform
├── kind  (executable, darwin/arm64, kind v0.33.0 binary)
└── kind-cluster  (blob, application/yaml, kind cluster config)
```

## How it works

A single OCM component with 2 direct resources (no component references):
- **kind**: kind binary (darwin/arm64 only)
- **kind-cluster**: kind cluster configuration

`make kind-config` downloads the kind cluster config from the verified component. `make kind` installs the verified kind binary. `make e2e` uses both to create and test the cluster.

## Prerequisites

- OCM CLI v2 ≥ 0.17.0 (`make tools` downloads it into `bin/`)
- `jq`
- `openssl`
- `curl` (for fetching kind binary)
- `docker` (for `make e2e` only; requires macOS 15 Apple Silicon/darwin-arm64)

## Lifecycle

```bash
make tools           # download OCM CLI and fetch kind binary
make build           # build the CTF archive in build/ctf
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make kind-config     # download the kind cluster config from the component
make kind            # install the verified kind binary
make e2e             # spin up kind cluster, verify it exists, tear down (requires build and sign)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry
```

## Real signing keys

Dev keys are generated once into `build/keys/` and are gitignored. For production:

```bash
SIGNING_KEY=/path/to/private.pem VERIFY_KEY=/path/to/public.pem make sign verify
```

## Running tests

```bash
make test  # run the test suite
```

## CI

CI runs on macOS 15 Apple Silicon (darwin/arm64). Lint and test run on every push and pull request. E2E tests require Docker and are currently not run in CI.

Dev notes: The kind binary is platform-specific and currently only built for darwin/arm64. To support other platforms, add additional fetch and build targets.
