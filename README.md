# platform

A minimal but complete platform built with the [Open Component Model](https://ocm.software) (OCM v2).

## Component tree

```
github.com/lioramilbaum/platform
├── kind  (executable, darwin/arm64, kind v0.33.0 binary)
├── ocm  (executable, darwin/arm64, OCM CLI binary)
├── kind-cluster  (blob, application/yaml, kind cluster config)
├── component-constructor  (blob, application/yaml, OCM component descriptor)
├── script-lib  (blob, text/x-shellscript, shared script functions)
├── script-verify  (blob, text/x-shellscript, signature verification)
├── script-kind-config  (blob, text/x-shellscript, generate kind cluster config)
├── script-kind-bin  (blob, text/x-shellscript, extract and verify kind binary)
├── script-deploy  (blob, text/x-shellscript, deploy kind cluster)
└── script-bootstrap  (blob, text/x-shellscript, consumer entrypoint reference copy)
```

## How it works

A single OCM component with 10 direct resources (no component references):
- **kind**: kind binary (darwin/arm64 only)
- **ocm**: OCM CLI binary (darwin/arm64 only)
- **kind-cluster**: kind cluster configuration
- **component-constructor**: OCM component descriptor (for bundled deployments)
- **script-lib, script-verify, script-kind-config, script-kind-bin, script-deploy, script-bootstrap**: deployment and bootstrap scripts

`make kind-config` downloads the kind cluster config from the verified component. `make kind` installs the verified kind binary. `make e2e` calls `deploy.sh` to create the cluster, verifies it is healthy, then tears it down. Consumers can also download the full deployment bundle for self-contained execution.

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
make package         # package signed CTF, public key and bootstrap.sh into build/release
make e2e             # spin up kind cluster, verify it exists, tear down (requires build and sign)
make publish OCM_REPO=ghcr.io/<you>/ocm  # transfer to an OCI registry
```

## Consuming the component

A consumer who has pulled the component into a local CTF can download the full
deployment bundle:

```sh
REF="ctf::./build/ctf//github.com/lioramilbaum/platform:0.1.0"

# Verify the component signature before downloading anything
OCM verify cv --config /path/to/verify.ocmconfig "$REF"

# Download scripts and constructor into a bundle directory
mkdir -p bundle/scripts
for s in lib verify kind-config kind-bin deploy; do
  rm -f "bundle/scripts/$s.sh"
  ocm download resource "$REF" --identity name=script-$s \
    --output bundle/scripts/$s.sh
done
rm -f bundle/component-constructor.yaml
ocm download resource "$REF" --identity name=component-constructor \
  --output bundle/component-constructor.yaml
```

Notes:
- Downloaded files are mode 0600. Run them with `bash`, not `./`.
- OCM 0.17 appends to an existing `--output` file. Always download into a clean directory.
- Set `CTF`, `BUILD_DIR`, and `VERIFY_CONFIG` to match your layout, then run:
  `CTF=./build/ctf BUILD_DIR=/tmp/deploy VERIFY_CONFIG=/path/to/verify.ocmconfig bash bundle/scripts/deploy.sh`
- `deploy.sh` creates the cluster but does not tear it down. The cluster stays running so you can interact with it using kubeconfig context `kind-ocm-platform`. To delete: `build/deploy/bin/kind delete cluster --name ocm-platform`

## Bootstrapping from nothing

For zero-to-cluster deployment, use the standalone `bootstrap.sh` script from the component bundle:

```sh
OCM_REPO=ghcr.io/lioramilbaum/ocm \
VERIFY_CONFIG=/path/to/verify.ocmconfig \
bash bootstrap.sh
```

`bootstrap.sh` is a standalone entrypoint (no dependencies beyond curl, jq, openssl, and docker) that:
1. Downloads bootstrap OCM binary (pinned in the script)
2. Pulls the signed component from `OCM_REPO`
3. Verifies the component signature
4. Extracts all resources (kind binary, OCM binary, and scripts) with digest verification
5. Hands off to `deploy.sh` to create the cluster

Optional environment variables:
- `BUILD_DIR`: Build directory (default: `$PWD/build`)
- `VERSION`: Component version (default: `0.1.0`)
- `OCM_BOOTSTRAP_BASE_URL`: Bootstrap OCM download URL (default: GitHub releases; use `file://` for offline testing)

Note: `bootstrap.sh` only supports darwin/arm64. For other platforms, use the standard `make build` and `deploy.sh` workflow with pre-downloaded binaries.

## Real signing keys

Dev keys are generated once into `build/keys/` and are gitignored. For production:

```bash
SIGNING_KEY=/path/to/private.pem VERIFY_KEY=/path/to/public.pem make sign verify
```

## Version management

When Renovate bumps the OCM CLI version, the sha256 must be updated in two places:
- `component-constructor.yaml`: the `ocm.lioramilbaum.github.com/sha256sum-darwin-arm64` label
- `scripts/bootstrap.sh`: the `OCM_BOOTSTRAP_SHA256_DARWIN_ARM64` constant

The Makefile and `lib.sh` automatically derive the version from the constructor, so no other manual updates are needed.

## Running tests

```bash
make test  # run the test suite
```

## CI

CI runs on macOS 15 Apple Silicon (darwin/arm64). Lint and test run on every push and pull request. E2E tests require Docker and are currently not run in CI.

Dev notes: The kind binary is platform-specific and currently only built for darwin/arm64. To support other platforms, add additional fetch and build targets.

## Releases

### One-time setup

Generate a signing key and store it as a GitHub secret:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out private.pem
gh secret set OCM_SIGNING_KEY -R lioramilbaum/platform < private.pem
```

### Cutting a release

Push a tag matching `v*.*.*`:

```bash
git tag v0.2.0 && git push upstream v0.2.0
```

Tags with a pre-release suffix (e.g., `v0.2.0-rc.1`) are published as GitHub pre-releases.

### Release assets

Each release includes four assets:

- **platform-ctf-{VERSION}.tar.gz**: Signed component CTF (verify before extracting)
- **platform-signing-key.pub.pem**: Public signing key (for verification config)
- **bootstrap.sh**: Zero-to-cluster deployment script
- **SHA256SUMS**: SHA256 checksums for the above assets

### Consuming a release

#### Option 1: Verify and extract CTF locally

```bash
# Verify checksums
shasum -a 256 -c SHA256SUMS

# Extract archive
tar -xzf platform-ctf-0.2.0.tar.gz

# Create a verify config pointing at the downloaded public key
cat > verify.ocmconfig <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $PWD/platform-signing-key.pub.pem
EOF

# Deploy with signature verification
OCM_REPO=ctf://$PWD/ctf VERSION=0.2.0 VERIFY_CONFIG=$PWD/verify.ocmconfig bash bootstrap.sh
```

#### Option 2: Deploy directly from GitHub Container Registry

```bash
OCM_REPO=oci://ghcr.io/lioramilbaum/ocm VERSION=0.2.0 bash bootstrap.sh
```

Note: In this case, verification is implicit (you're trusting the registry and container image signature).
