# platform

A minimal platform packaged and signed with the [Open Component Model](https://ocm.software). The component contains kind and OCM binaries, a kind node image archive, cluster configuration, and deployment scripts. Supported executable platforms are Darwin ARM64 and Linux ARM64. Offline release delivery targets Linux ARM64.

## Developer lifecycle

Install Bash, curl, jq, OpenSSL, tar, a SHA256 utility, and Docker. Docker must support Linux ARM64 containers. ShellCheck is recommended.

```bash
make tools                          # fetch pinned OCM and kind binaries
make fetch-image                    # connected: pull pinned kind node image and save it
make build sign verify OCM=bin/ocm   # build local CTF, sign, verify
make package OCM=bin/ocm             # transport to fresh CTF and create release assets
make e2e OCM=bin/ocm                 # deploy, require readiness, tear down
make publish OCM=bin/ocm OCM_REPO=oci://ghcr.io/<you>/ocm
make lint test OCM=bin/ocm
```

Local signing creates development RSA keys under `build/keys/`. Production signing uses explicitly supplied files:

```bash
SIGNING_KEY=/path/to/private.pem VERIFY_KEY=/path/to/public.pem make sign verify package OCM=bin/ocm
```

Explicitly supplied missing key files fail. Never include the private key in a delivery package.

## Release workflow

`.github/workflows/release.yaml` is the connected **Release** workflow. It runs automatically for `v*.*.*` tags and can be dispatched from `main` with a component version such as `0.2.0`. The canonical repository is `lioramilbaum/platform`.

Release tests on macOS, then uses a Linux ARM64 runner to fetch pinned binaries and the pinned kind node image, build and sign the CTF, transport the component into a fresh self-contained CTF, verify it, and publish the `platform-airgap-linux-arm64` Actions artifact. Tag runs also publish the component to GHCR and create a GitHub release, including prereleases for prerelease tags. Manual runs produce the Actions artifact without creating a tag release.

Provision the private signing key as the `OCM_SIGNING_KEY` repository secret:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out private.pem
openssl pkey -in private.pem -pubout -out public.pem
gh secret set OCM_SIGNING_KEY -R lioramilbaum/platform < private.pem
```

Release assets include `platform-airgap-{VERSION}-linux-arm64.tar.gz`, the legacy CTF archive, bootstrap entrypoint, informational public key, metadata, and checksums. The offline archive contains the transported signed CTF, including the saved Docker node image, and the bootstrap executable and entrypoint needed to verify and consume it. Metadata records component version, source revision, OS, architecture, and root component. Checksums catch accidental corruption; the independently trusted public key establishes signature trust.

Actions artifacts expire after 30 days; tagged GitHub release assets provide a durable handoff.

## Offline package consumption

Provision the trusted public key independently of the downloaded archive, for example through runner configuration or an approved administrative transfer. A public key supplied alongside a package is informational and must not establish its own trust.

The offline machine needs Linux ARM64, Bash, Python 3.9 or newer, Docker with a running daemon, jq, OpenSSL, tar, a SHA256 utility, and standard system utilities. It does not need a separately installed OCM, kind, or kubectl binary. The package contains OCM and kind; readiness checks use kubectl inside the kind node.

Transfer the offline archive through your approved internal mechanism or removable media, then run:

```bash
bash scripts/offline-run.sh \
  /delivery/platform-airgap-0.2.0-linux-arm64.tar.gz \
  /etc/platform/trusted-public.pem
```

Use the trusted entrypoint from the corresponding source revision; do not execute an unverified replacement supplied by an untrusted party. The package includes the entrypoint for transferring a complete delivery. `make deploy-offline PACKAGE=/delivery/platform-airgap-0.2.0-linux-arm64.tar.gz VERIFY_KEY=/etc/platform/trusted-public.pem` is the repository convenience target; `make e2e-airgap` consumes the same inputs for deployment testing.

Offline consumption verifies the component and resources before deployment, loads the bundled node image into Docker, and creates the cluster using its saved runtime tag. Missing dependencies or package resources fail rather than trigger a download. Deployment requires node readiness and healthy Kubernetes system deployments. Optional `EXPECTED_SOURCE_REVISION` and `EXPECTED_VERSION` enforce the expected package identity; `BUILD_DIR` selects the staging directory.

The node image is baked into the signed CTF. No registry connection is needed to obtain it during deployment. Registry publication remains a separate connected operation.

## Air-gapped Deploy workflow

`.github/workflows/air-gapped-deploy.yaml` is independent of Release. Dispatch it from `main` with `package_run_id`, the numeric ID of an already successful Release run. Configure the independently provisioned public key as the `OCM_VERIFY_KEY` secret:

```bash
gh secret set OCM_VERIFY_KEY -R lioramilbaum/platform < public.pem
```

The workflow checks the selected run belongs to the canonical repository and expected Release workflow, completed successfully, and originated from `main` or a release tag. It checks out the immutable source revision, downloads that exact run's named artifact, checks Linux ARM64 metadata, and invokes the offline entrypoint with the expected source revision and version.

Isolation follows [krops' air-gapped workflow](https://github.com/polarsquad/krops/blob/main/.github/workflows/air-gapped.yml): checkout, artifact download, and capture-tool installation happen before isolation. A `DOCKER-USER` firewall rule blocks new forwarded connections leaving the kind bridge. Packet capture detects attempted public traffic on that bridge. Any such attempt fails the deployment test. Logs, readiness diagnostics, and traffic evidence are uploaded, and the cluster and firewall rule are cleaned up on failure as well as success.

The GitHub runner and host Docker daemon retain connectivity. This workflow demonstrates cluster network isolation and package consumption; bridge traffic evidence does not establish isolation of host processes. A physically disconnected machine uses the local entrypoint and an external package handoff instead of downloading GitHub artifacts.

## CI and pin maintenance

CI runs lint and the unit suite on macOS ARM64 and Linux ARM64. The separate Air-gapped Deploy workflow exercises the real saved image, Docker deployment, and readiness checks.

Binary versions and per-platform checksums are recorded in `component-constructor.yaml`; OCM checksum constants in both `scripts/bootstrap.sh` and `scripts/offline-run.sh` must remain consistent with those pins. The kind-compatible node image is pinned by digest, then saved under a stable runtime tag because Docker image loading does not reliably restore registry digests. Update the constructor image pin and cluster runtime image together when upgrading kind or Kubernetes.
