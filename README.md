# agentbox

Base images for running **Claude Code** and **opencode** agents in containers.
Each image ships with a default-deny egress firewall and the tooling for one kind of work.
Images are rebuilt daily and kept current by Renovate, with no manual steps.

```
ghcr.io/crowdprobe/agentbox:<tier>                   # latest build of that tier (moving)
ghcr.io/crowdprobe/agentbox:<tier>-YYYYMMDD-HHmmss   # one specific build (UTC), never overwritten
```

> [!IMPORTANT]
> **Run agentbox under [rootless Docker](https://docs.docker.com/engine/security/rootless/). This is highly recommended.**
>
> The egress firewall needs `NET_ADMIN` and `NET_RAW`. Under rootless Docker, those
> capabilities, and the container's `root`, exist only inside a user namespace
> owned by your unprivileged user. A container escape therefore lands as that
> user, not as host root.
>
> Adding yourself to the `docker` group is **not** an equivalent alternative.
> Membership in that group is root-equivalent on the host.
>
> To check what you're running: `docker info 2>/dev/null | grep -i rootless` should print `rootless`.
> Rootful Docker works, but it is not recommended.

## Tiers

All tiers are built from one multistage [`Dockerfile`](Dockerfile), so they can't drift apart.
Every tier contains **core**; the other tiers each add only what that kind of work needs.
The default user is the unprivileged `agent` (uid 1000), with `/workspace` as the working directory.

The tables below are also the test specification.
[`scripts/smoke_test.sh`](scripts/smoke_test.sh) checks every row inside the built image,
and CI fails if a listed tool is missing.

### `core`: agents, git and the egress firewall

<!-- tools:core -->
| check | what | source / verification |
|---|---|---|
| `claude` | Claude Code CLI | npm, exact version, registry sha512 integrity |
| `opencode` | opencode CLI | npm, exact version, registry sha512 integrity |
| `node` | Node.js LTS runtime for the CLIs (**npm is not included**) | nodejs.org tarball checked against `SHASUMS256.txt` |
| `uv` | Python package and venv manager | `ghcr.io/astral-sh/uv` image |
| `python3` | Debian's Python 3 | Debian trixie |
| `git` | git | Debian trixie |
| `curl` | curl | Debian trixie |
| `jq` | jq | Debian trixie |
| `rg` | ripgrep | Debian trixie |
| `make` | GNU make | Debian trixie |
| `bc` | bc | Debian trixie |
| `iptables` | firewall rules | Debian trixie |
| `ipset` | firewall address sets | Debian trixie |
| `dnsmasq` | resolver that keeps the firewall's address set current | Debian trixie |
| `dig` | DNS lookup | Debian trixie |
| `ip` | iproute2 | Debian trixie |
| `sudo` | used **only** for `init-firewall.sh` | Debian trixie |
| `init-firewall.sh` | default-deny egress, see below | this repo |
| `ensure-claude-plugin-marketplace.sh` | registers the official Claude Code plugin marketplace | this repo |
<!-- /tools:core -->

### `cad`: 3D modelling (core + ...)

<!-- tools:cad -->
| check | what | source / verification |
|---|---|---|
| `openscad-nightly` | OpenSCAD nightly (its manifold backend renders in seconds, not minutes). The AppImage is extracted, so it needs no FUSE. | files.openscad.org, checked against the published `.sha256` |
| `openscad` | alias for the above | this repo |
| `xvfb-run` | virtual display, for PNG previews | Debian trixie |
| `magick` | ImageMagick | Debian trixie |
| `import trimesh` | mesh analysis, in `/opt/venv` (on `PATH`) | PyPI, hash-checked by uv |
<!-- /tools:cad -->

### `ml`: dataset tooling, cloud training driver and AVR firmware (core + ...)

There is **no local training stack**: no PyTorch and no ultralytics.
Training is expected to run on cloud GPUs, and inference goes through OpenCV's `cv2.dnn` with ONNX models.

<!-- tools:ml -->
| check | what | source / verification |
|---|---|---|
| `import cv2` | OpenCV (headless) | PyPI, hash-checked by uv; **frozen version** |
| `import imagehash` | perceptual hashing | PyPI, hash-checked by uv; **frozen version** |
| `import numpy` | NumPy | PyPI, hash-checked by uv |
| `import PIL` | Pillow | PyPI, hash-checked by uv |
| `gcloud` | Google Cloud CLI | `google/cloud-sdk` image, content-addressed pull |
| `gsutil` | Cloud Storage CLI | as above |
| `ssh` | OpenSSH client | Debian trixie |
| `rsync` | rsync | Debian trixie |
| `magick` | ImageMagick | Debian trixie |
| `pdftoppm` | poppler-utils (also `pdftotext` and `pdfinfo`) | Debian trixie |
| `g++` | host C++ compiler, for firmware unit tests | Debian trixie |
| `avr-gcc` | AVR cross-compiler | Debian trixie |
| `arduino-cli` | Arduino CLI, with the `arduino:avr` core and the `AccelStepper` library preinstalled in `/opt/arduino` | GitHub release checked against `checksums.txt`; the core and library are checked against Arduino's index |
<!-- /tools:ml -->

### `infra`: cloud infrastructure (core + ...)

<!-- tools:infra -->
| check | what | source / verification |
|---|---|---|
| `gcloud` | Google Cloud CLI | `google/cloud-sdk` image, content-addressed pull |
| `gsutil` | Cloud Storage CLI | as above |
| `tofu` | OpenTofu | GitHub release checked against `SHA256SUMS` |
<!-- /tools:infra -->

### Not included, on purpose

- npm and npx
- GitHub Copilot CLI
- PyTorch and ultralytics
- wget
- build-time download tools (xz, unzip)
- any credential, allowlist or project-specific setting

## Usage

```sh
docker run --rm -it \
  --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v "$PWD:/workspace" \
  ghcr.io/crowdprobe/agentbox:core \
  bash -c 'sudo init-firewall.sh "api.anthropic.com,github.com" && claude'
```

As a devcontainer (`.devcontainer/devcontainer.json`):

```jsonc
{
  "image": "ghcr.io/crowdprobe/agentbox:cad",
  "runArgs": ["--cap-drop=ALL", "--cap-add=NET_ADMIN", "--cap-add=NET_RAW"],
  "containerEnv": { "ALLOWED_DOMAINS": "api.anthropic.com,github.com" },
  "postStartCommand": "sudo -n /usr/local/bin/init-firewall.sh \"$ALLOWED_DOMAINS\""
}
```

Pass credentials at run time through bind mounts or environment variables. The images never contain any.
Running the container as `root` (for example with `remoteUser: root`) works, but it is not recommended.
The `agent` user is the default for a reason.

## Egress firewall

`sudo init-firewall.sh "<allowlist>"` takes hostnames and IPv4 literals, separated by commas or spaces.
The image ships **no allowlist of its own**.

- **Validation:** every entry is checked against a strict hostname or IPv4 pattern before it reaches iptables or dnsmasq. The whole list is rejected on any invalid entry.
- **Default deny:** `OUTPUT` defaults to `DROP`. Blocked connections are *refused* immediately, so a missing entry fails fast instead of hanging.
- **Self-updating:** dnsmasq runs as the container's resolver and adds each allowed name's current addresses to the ipset. CDN address rotation therefore never breaks the allowlist.
- **Set once:** the first successful allowlist is locked into a root-owned read-only file. A different list is refused afterwards, so an agent can't widen its own egress through its sudo right.
- **Self-check:** after applying the rules, the script verifies that `example.com` is blocked and that an allowed host is reachable. It exits non-zero otherwise.

## Security and supply chain

- **Versions are pinned.** Renovate bumps them. No checksum is committed. Every download goes through [`scripts/fetch_verified.sh`](scripts/fetch_verified.sh), which checks it against the SHA-256 the upstream project publishes **for that exact version**, and a mismatch fails the build.
- **Nothing is ever piped into a shell.** [`scripts/lint_downloads.sh`](scripts/lint_downloads.sh) fails CI on `curl … | sh`, on any direct `curl`/`wget`, and on any version without a Renovate annotation.
- **Cool-down:** Renovate only proposes a release once it is **at least 5 days old**. That covers npm, PyPI, GitHub releases and tags, container images and Actions. The one exception is **Claude Code and opencode**, which update as soon as a release is out. Python transitive dependencies get the same cool-down through `uv pip install --exclude-newer`.
- **Debian packages are not pinned.** They come from Debian trixie and trixie-security (signed repositories), and the daily build picks up security fixes without waiting for the cool-down.
- **Frozen:** `opencv-python-headless` and `imagehash` are excluded from Renovate. Downstream tooling calibrated against their exact versions.
- **Multistage:** download tools, npm and build-only packages stay in intermediate stages. A published image contains runtime tooling only.
- **Signed and attested:** each published digest is signed with cosign (keyless, GitHub OIDC) and carries SLSA build provenance and an SBOM. Verify with:

  ```sh
  cosign verify ghcr.io/crowdprobe/agentbox:core \
    --certificate-identity-regexp '^https://github.com/crowdprobe/agentbox/\.github/workflows/build\.yml@refs/heads/main$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  gh attestation verify oci://ghcr.io/crowdprobe/agentbox:core --repo crowdprobe/agentbox
  ```
- **Scanned:** every published image is scanned with Trivy, and the results go to the repository's code-scanning alerts. OpenSSF Scorecard runs weekly.
- **CI hygiene:**
  - Every Action is pinned to a full commit SHA.
  - Workflows start from `permissions: {}`, and each job adds only what it needs.
  - Pull requests build and test but never publish.
  - Publishing builds run without a shared cache.

## How updates flow

```
03:00 UTC  Renovate (daily) ──► PR per update (after the 5-day cool-down; Claude Code/opencode immediately)
                                 │
                                 ▼
           ci.yml: lint + build every tier + smoke test ──► automerge when green
                                 │
                                 ▼
           build.yml (on merge, and daily at 05:00 UTC) ──► smoke test ──► push :<tier> and :<tier>-YYYYMMDD-HHmmss
                                 │                                        ──► sign, attest, scan
                                 ▼
           failure ──► issue labelled build-failure, assigned ──► GitHub emails the assignee
                       (closed automatically by the next green run)
```

## Contributing and security

Pull requests are welcome, and CI must be green.
Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

Licensed under the [Apache License 2.0](LICENSE).
