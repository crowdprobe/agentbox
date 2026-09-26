# syntax=docker/dockerfile:1
#
# agentbox - base images for containerized Claude Code / opencode agents.
#
# One multistage Dockerfile, four published targets:
#   core   agent CLIs, git, the egress firewall - what every tier needs
#   cad    core + OpenSCAD (nightly) + trimesh
#   ml     core + OpenCV/imagehash/onnxruntime + gcloud + image/PDF tools + AVR toolchain
#   infra  core + gcloud + OpenTofu
#
# Supply-chain rules (enforced by scripts/lint_downloads.sh in CI):
#   * every downloaded artifact goes through scripts/fetch_verified.sh, which
#     checks it against the SHA-256 the upstream project publishes for that
#     exact version - nothing is ever piped into a shell;
#   * every version below carries a `# renovate:` annotation; Renovate bumps
#     them after a 5-day cool-down (claude-code and opencode excepted);
#   * download tooling (curl for fetching, xz, unzip) lives only in the fetch
#     stages and never reaches a published image.
#
# No secrets, credentials or allowlists are baked in: callers mount/pass them
# at run time.

# --- pinned versions (Renovate-managed) --------------------------------------
ARG BASE_IMAGE=debian:trixie-slim

# renovate: datasource=github-releases depName=astral-sh/uv
ARG UV_VERSION=0.12.16
# renovate: datasource=docker depName=google/cloud-sdk versioning=regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$
ARG GCLOUD_VERSION=586.0.0

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv
FROM google/cloud-sdk:${GCLOUD_VERSION}-slim AS gcloud-upstream

# =============================================================================
# base: the minimal runtime every published target starts from
# =============================================================================
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS base
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates curl git jq make ripgrep bc less procps openssl \
         python3 \
         iptables ipset dnsmasq-base iproute2 bind9-dnsutils sudo \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# fetch stages: download + verify, nothing here is published directly
# =============================================================================
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS fetch
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 scripts/fetch_verified.sh /usr/local/bin/fetch_verified

FROM fetch AS fetch-node
# renovate: datasource=node-version depName=node versioning=node
ARG NODE_VERSION=22.23.3
RUN fetch_verified \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
      /tmp/node.tar.xz \
    && mkdir -p /out/node \
    && tar -xJf /tmp/node.tar.xz -C /out/node --strip-components=1 \
         --exclude=CHANGELOG.md --exclude=README.md --exclude='*/share/doc' \
    && rm /tmp/node.tar.xz

FROM fetch AS fetch-openscad
# Nightly on purpose: its manifold backend renders in ~1s where the 2021.01
# release takes minutes. The AppImage is EXTRACTED (no FUSE, no privileges).
# renovate: datasource=custom.openscad-snapshots depName=openscad-nightly versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})(\.ai(?<build>\d+))?$
ARG OPENSCAD_VERSION=2026.01.02.ai30348
RUN url="https://files.openscad.org/snapshots/OpenSCAD-${OPENSCAD_VERSION}-x86_64.AppImage" \
    && fetch_verified "$url" "${url}.sha256" /tmp/openscad.AppImage \
    && chmod +x /tmp/openscad.AppImage
WORKDIR /tmp
RUN ./openscad.AppImage --appimage-extract >/dev/null \
    && mv /tmp/squashfs-root /out-openscad \
    && rm /tmp/openscad.AppImage

FROM fetch AS fetch-tofu
# renovate: datasource=github-releases depName=opentofu/opentofu
ARG OPENTOFU_VERSION=1.12.6
RUN base="https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}" \
    && fetch_verified "${base}/tofu_${OPENTOFU_VERSION}_linux_amd64.tar.gz" \
         "${base}/tofu_${OPENTOFU_VERSION}_SHA256SUMS" /tmp/tofu.tar.gz \
    && mkdir -p /out && tar -xzf /tmp/tofu.tar.gz -C /out tofu \
    && rm /tmp/tofu.tar.gz

FROM fetch AS fetch-arduino
# renovate: datasource=github-releases depName=arduino/arduino-cli
ARG ARDUINO_CLI_VERSION=1.5.1
# arduino-cli verifies each core/library archive against the checksum in
# Arduino's own index, for exactly the versions pinned here.
# renovate: datasource=github-tags depName=arduino/ArduinoCore-avr
ARG ARDUINO_AVR_VERSION=1.8.8
# renovate: datasource=github-tags depName=waspinator/AccelStepper versioning=loose
ARG ACCELSTEPPER_VERSION=1.64
ENV ARDUINO_DIRECTORIES_DATA=/opt/arduino/data \
    ARDUINO_DIRECTORIES_USER=/opt/arduino/user \
    ARDUINO_DIRECTORIES_DOWNLOADS=/tmp/arduino-downloads
RUN base="https://github.com/arduino/arduino-cli/releases/download/v${ARDUINO_CLI_VERSION}" \
    && fetch_verified "${base}/arduino-cli_${ARDUINO_CLI_VERSION}_Linux_64bit.tar.gz" \
         "${base}/${ARDUINO_CLI_VERSION}-checksums.txt" /tmp/arduino-cli.tar.gz \
    && mkdir -p /out && tar -xzf /tmp/arduino-cli.tar.gz -C /out arduino-cli \
    && rm /tmp/arduino-cli.tar.gz \
    && /out/arduino-cli core update-index \
    && /out/arduino-cli core install "arduino:avr@${ARDUINO_AVR_VERSION}" \
    && /out/arduino-cli lib update-index \
    && /out/arduino-cli lib install "AccelStepper@${ACCELSTEPPER_VERSION}" \
    && rm -rf /tmp/arduino-downloads

# gcloud comes out of Google's own image (content-addressed registry pull, no
# unverifiable tarball). Its bundled Python is dropped; the system python3 runs it.
# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS fetch-gcloud
COPY --from=gcloud-upstream /usr/lib/google-cloud-sdk /opt/google-cloud-sdk
RUN rm -rf /opt/google-cloud-sdk/platform/bundledpythonunix \
           /opt/google-cloud-sdk/.install/.backup \
           /opt/google-cloud-sdk/help \
    && find /opt/google-cloud-sdk -name '__pycache__' -type d -prune -exec rm -rf {} +

# =============================================================================
# agent CLIs: installed with npm here; npm itself never reaches a target
# =============================================================================
FROM fetch AS agent-clis
COPY --from=fetch-node /out/node /usr/local
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.282
# renovate: datasource=npm depName=opencode-ai
ARG OPENCODE_VERSION=1.18.32
# npm verifies each tarball against the sha512 integrity in the registry.
RUN npm install -g --prefix /opt/agents --no-fund --no-audit \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
    && /opt/agents/bin/claude --version \
    && /opt/agents/bin/opencode --version \
    && rm -rf /root/.npm

# =============================================================================
# Python venvs (built against the same base python3 as the runtime)
# =============================================================================
FROM base AS venv-build
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_NO_CACHE=1 UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy

FROM venv-build AS venv-cad
COPY python/cad/requirements.txt /tmp/requirements.txt
RUN uv venv /opt/venv \
    && uv pip install --python /opt/venv/bin/python \
         --exclude-newer "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
         -r /tmp/requirements.txt \
    && /opt/venv/bin/python -c "import trimesh; print('cad venv OK')"

FROM venv-build AS venv-ml
COPY python/ml/requirements.txt /tmp/requirements.txt
RUN uv venv /opt/venv \
    && uv pip install --python /opt/venv/bin/python \
         --exclude-newer "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
         -r /tmp/requirements.txt \
    && /opt/venv/bin/python -c "import cv2, imagehash, numpy, PIL, onnxruntime; print('ml venv OK')"

# =============================================================================
# core
# =============================================================================
FROM base AS core
ARG AGENT_NAME=agent
ARG USER_UID=1000
ARG USER_GID=1000

COPY --from=fetch-node /out/node/bin/node /usr/local/bin/node
COPY --from=agent-clis /opt/agents /opt/agents
COPY --from=uv /uv /usr/local/bin/uv
COPY --chmod=0755 rootfs/usr/local/bin/ /usr/local/bin/

# The agent CLIs must not update themselves: that is a guaranteed-failing
# network call behind the firewall at best, an unpinned binary swap at worst.
# There is no npm in the image, and npm/bun registries point at a closed port
# so any runtime install attempt fails in microseconds instead of hanging.
ENV PATH="/opt/agents/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    npm_config_registry=http://127.0.0.1:1/ \
    npm_config_offline=true \
    BUN_CONFIG_REGISTRY=http://127.0.0.1:1/ \
    UV_PYTHON_DOWNLOADS=never

# Unprivileged by default. The ONLY sudo rights are the firewall script and the
# GitHub App token helper (it reads a key the agent itself cannot read), both
# root-owned and not writable by the agent user. git uses the token helper for
# https://github.com when a GitHub App is mounted, and stays silent otherwise.
RUN groupadd --gid "$USER_GID" "$AGENT_NAME" \
    && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$AGENT_NAME" \
    && printf '%s ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' "$AGENT_NAME" \
         > /etc/sudoers.d/init-firewall \
    && printf '%s ALL=(root) NOPASSWD: /usr/local/bin/agentbox-gh-token\n' "$AGENT_NAME" \
         > /etc/sudoers.d/agentbox-gh-token \
    && chmod 0440 /etc/sudoers.d/init-firewall /etc/sudoers.d/agentbox-gh-token \
    && chown root:root /usr/local/bin/init-firewall.sh /usr/local/bin/agentbox-gh-token \
    && git config --system credential.https://github.com.helper agentbox \
    && mkdir -p /workspace && chown "$USER_UID:$USER_GID" /workspace

LABEL org.opencontainers.image.source="https://github.com/crowdprobe/agentbox" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="agentbox core: Claude Code + opencode with a default-deny egress firewall"

USER ${USER_UID}:${USER_GID}
WORKDIR /workspace

# =============================================================================
# cad
# =============================================================================
FROM core AS cad
USER 0
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         libglu1-mesa libgl1 libegl1 libxi6 libxrender1 libxcursor1 libxrandr2 \
         libxinerama1 libfontconfig1 libharfbuzz0b libdouble-conversion3 \
         libxkbcommon0 libgpg-error0 libasound2t64 xvfb xauth imagemagick \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch-openscad /out-openscad /opt/openscad-nightly
COPY --from=venv-cad /opt/venv /opt/venv
# A wrapper, not a symlink: AppRun locates its hooks via `dirname "$0"`.
RUN printf '#!/bin/sh\nexec /opt/openscad-nightly/AppRun "$@"\n' > /usr/local/bin/openscad-nightly \
    && chmod 0755 /usr/local/bin/openscad-nightly \
    && ln -s /usr/local/bin/openscad-nightly /usr/local/bin/openscad \
    && mkdir -p /home/agent/.config/OpenSCAD && chown -R agent:agent /home/agent/.config
ENV PATH="/opt/venv/bin:${PATH}" \
    OPENSCAD=/usr/local/bin/openscad-nightly
LABEL org.opencontainers.image.description="agentbox cad: core + OpenSCAD nightly + trimesh"
USER 1000:1000

# =============================================================================
# ml
# =============================================================================
FROM core AS ml
USER 0
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         openssh-client rsync imagemagick poppler-utils \
         g++ gcc-avr avr-libc arduino-core-avr \
    && rm -rf /var/lib/apt/lists/*
COPY --from=venv-ml /opt/venv /opt/venv
COPY --from=fetch-gcloud /opt/google-cloud-sdk /opt/google-cloud-sdk
COPY --from=fetch-arduino /out/arduino-cli /usr/local/bin/arduino-cli
COPY --from=fetch-arduino /opt/arduino /opt/arduino
ENV PATH="/opt/venv/bin:/opt/google-cloud-sdk/bin:${PATH}" \
    CLOUDSDK_PYTHON=/usr/bin/python3 \
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
    CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=true \
    ARDUINO_DIRECTORIES_DATA=/opt/arduino/data \
    ARDUINO_DIRECTORIES_USER=/opt/arduino/user \
    ARDUINO_DIRECTORIES_DOWNLOADS=/tmp/arduino-downloads
LABEL org.opencontainers.image.description="agentbox ml: core + OpenCV/imagehash/onnxruntime + gcloud + AVR toolchain"
USER 1000:1000

# =============================================================================
# infra
# =============================================================================
FROM core AS infra
USER 0
COPY --from=fetch-gcloud /opt/google-cloud-sdk /opt/google-cloud-sdk
COPY --from=fetch-tofu /out/tofu /usr/local/bin/tofu
ENV PATH="/opt/google-cloud-sdk/bin:${PATH}" \
    CLOUDSDK_PYTHON=/usr/bin/python3 \
    CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
    CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=true
LABEL org.opencontainers.image.description="agentbox infra: core + gcloud + OpenTofu"
USER 1000:1000
