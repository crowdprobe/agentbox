#!/usr/bin/env bash
# Initialize after runtime config mounts are attached, as the current user.
set -euo pipefail
rtk telemetry disable >&2
rtk init --global --opencode --auto-patch --no-trust-filters </dev/null >&2
