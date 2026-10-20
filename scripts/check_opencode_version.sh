#!/usr/bin/env bash
# Validate the downstream image contract using the exported installation pin.
set -euo pipefail

if [[ ! ${OPENCODE_VERSION:-} =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "OPENCODE_VERSION must export a valid pinned major.minor.patch version" >&2
  exit 1
fi
if ! actual="$(opencode --version)"; then
  echo "opencode --version failed" >&2
  exit 1
fi
if [[ "$actual" != "$OPENCODE_VERSION" ]]; then
  echo "OpenCode version mismatch: exported $OPENCODE_VERSION, CLI reported $actual" >&2
  exit 1
fi
echo "OpenCode $OPENCODE_VERSION matches the exported pin"
