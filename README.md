# Hokeka Edge (public releases)

Public install scripts and versioned Edge Node binaries for PSP / bank clients.

**Source code stays private** (`kevshake/Hokeka-AML-Tool`). This repository only publishes:

- `install-edge.sh` — bootstrap one-liner (deps, download, checksums, enrol, systemd)
- Release assets per tag `v*` — `edge-host.jar`, native libraries, `SHA256SUMS`, `install.sh` / `install.ps1`
- This README and `LICENSE` / terms

Clients **never need a GitHub token**.

## Install (Linux)

From the Hokeka Console → **Edge Nodes** → **Generate install token**, copy the one-liner:

```bash
curl -fsSL https://hokeka.com/install-edge.sh | sudo bash -s -- --enrol-token <token>
```

Same script (raw from this repo):

```bash
curl -fsSL https://raw.githubusercontent.com/kevshake/hokeka-edge/main/install-edge.sh | sudo bash -s -- --enrol-token <token>
```

Default Control Plane: `https://aml.hokeka.com` (override with `--control-plane <url>`).

### Common flags

| Flag | Purpose |
|------|---------|
| `--enrol-token <token>` | One-time token from the Console (required on first install) |
| `--control-plane <url>` | Control Plane base URL |
| `--version <semver>` | Pin a release (default: latest GitHub Release) |
| `--upgrade` | Re-download and reinstall without a new token |
| `--uninstall` | Stop the service and remove binaries (`--purge` also deletes data) |
| `--native` | Prefer JVM + native core instead of containers |

### Requirements

- Ubuntu/Debian or RHEL/Rocky (amd64 or arm64)
- Outbound HTTPS to `aml.hokeka.com` (or your Control Plane) and `github.com` / `objects.githubusercontent.com`
- Optional: `HTTPS_PROXY` / `HTTP_PROXY` for corporate proxies
- Recommended: ≥ 2 GiB RAM, ≥ 10 GiB free disk

### Windows

Keep using `install.ps1` from the release assets (or the Console’s Windows command). Enrolment still uses a Console install token / enrollment code — see the [Edge public install guide](https://docs.hokeka.com/docs/06-edge-public-install).

## Verify downloads

Every release includes `SHA256SUMS` and its detached signature `SHA256SUMS.asc`. The bootstrap verifies the signature against the release key pinned in the script, then the digests. It is fail-closed: a bootstrap without a pinned key, a missing `.asc` or a bad signature stops the install. `--insecure-skip-signature` bypasses this and is only for a mirror you already trust by other means.

## Support

- Console docs: Edge Nodes → Help → Edge install guide  
- Troubleshooting: common redeem / proxy / SELinux errors are listed in the public install guide  

## License / terms

See [`LICENSE`](./LICENSE). Use of Hokeka Edge software is subject to your organisation’s agreement with Hokeka.
