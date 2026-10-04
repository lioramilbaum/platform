# platform

A minimal but complete platform built with the [Open Component Model](https://ocm.software) (OCM v2).

## Component tree

```
github.com/lmilbaum/platform
└── kind-cluster  (blob, application/yaml, kind cluster config)
```

## How it works

A single OCM component with 1 direct resource (no component references):
- **kind-cluster**: kind cluster configuration

`make kind-config` downloads the kind cluster config from the verified component. `make e2e` uses it to create the cluster with kind.

## Prerequisites

- OCM CLI v2 ≥ 0.17.0 (`make tools` downloads it into `bin/`)
- `jq`
- `openssl`
- `kind` (for `make e2e` only)
- `docker` (for `make e2e` only)

## Lifecycle

```bash
make build           # build the CTF archive in build/ctf
make sign            # sign with an auto-generated dev RSA key
make verify          # verify the signature
make kind-config     # download the kind cluster config from the component
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