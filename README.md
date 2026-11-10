# platform

A minimal kind platform: a checksum-pinned kind binary, a digest-pinned kind node image, and a kind cluster configuration. Supported platforms are Darwin ARM64 and Linux ARM64.

## Developer lifecycle

Install Bash, curl, jq, a SHA256 utility, and Docker. Docker must support Linux ARM64 containers. ShellCheck is recommended.

```bash
make tools          # fetch the pinned kind binary
make fetch-image    # connected: pull the pinned kind node image and save it
make e2e            # deploy, require readiness, tear down (KEEP_CLUSTER=1 keeps the cluster)
make lint test      # lint shell scripts and run the test suite
```

`make kind-config` writes the cluster configuration to `build/deploy/kind-cluster.yaml`. `make kind` installs the pinned kind binary into `build/deploy/bin/kind`.

## Pin maintenance

- The kind version and per-platform SHA256 checksums are pinned in `scripts/lib.sh`. Renovate proposes kind version bumps; update the matching SHA256 checksums by hand in the same change.
- The kind node image and its digest are pinned in `components/kind/cluster.yaml`. Update them by hand when upgrading kind or Kubernetes. The image is saved under its stable runtime tag because Docker image loading does not reliably restore registry digests.

## CI

CI runs `make lint` and `make test` on macOS ARM64 and Linux ARM64. See `.github/workflows/ci.yaml`.
