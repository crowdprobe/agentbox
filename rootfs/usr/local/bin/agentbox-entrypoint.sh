#!/usr/bin/env bash
set -euo pipefail

# Projects supplying their own reviewed plugin or read-only configuration can
# opt out explicitly; otherwise an initialization failure stops startup.
if [[ "${RTK_AUTO_INIT:-1}" != 0 ]]; then
  /usr/local/bin/agentbox-init-rtk.sh
fi
exec "$@"
