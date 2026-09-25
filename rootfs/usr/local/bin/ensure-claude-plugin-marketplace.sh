#!/usr/bin/env bash
#
# ensure-claude-plugin-marketplace.sh - register the official Claude Code
# plugin marketplace in this container if it is not registered yet.
#
# Claude Code's automatic install of the marketplace is gated by a flag in
# ~/.claude.json. When that file is seeded from another machine, the flag can
# say "already installed" while this container's ~/.claude/plugins/ is empty,
# and Claude Code never retries. Idempotent: does nothing once registered.
# Needs github.com reachable (e.g. on the firewall allowlist).
set -uo pipefail

if claude plugin marketplace list 2>/dev/null | grep -q "claude-plugins-official"; then
  exit 0
fi

if claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1; then
  echo "ensure-claude-plugin-marketplace: registered claude-plugins-official" >&2
else
  echo "NOTE: could not register the official Claude Code plugin marketplace;" \
       "run 'claude plugin marketplace add anthropics/claude-plugins-official' to see why" >&2
fi
