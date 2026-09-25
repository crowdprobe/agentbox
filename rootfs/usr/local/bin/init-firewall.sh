#!/bin/bash
#
# init-firewall.sh - default-DENY egress for an agent container.
#
#   sudo init-firewall.sh "api.anthropic.com,github.com,10.0.0.5"
#
# Prompt injection reaches agents through content they are supposed to read.
# Whatever an injected instruction talks a model into, it still has to leave
# the container to do damage; with this applied, OUTPUT defaults to DROP and
# only the given allowlist (hostnames and/or IPv4 literals, comma or space
# separated) is reachable.
#
# The image ships NO allowlist of its own - the caller (e.g. a devcontainer's
# postStartCommand) passes it. The agent user's only sudo right is this script.
#
# It VERIFIES itself at the end and exits non-zero if the rules did not take:
# a firewall that silently failed open is worse than no firewall.
#
# --- names, not addresses ----------------------------------------------------
# iptables/ipset match addresses, not names. Resolving each name once at start
# pins whatever a CDN answered at that moment and breaks when it rotates. So
# dnsmasq runs as the container's own resolver with one `ipset=/name/allowed`
# line per allowed name: every lookup adds its answer to the ipset, and the
# enforcement never goes stale.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ "$(id -u)" -ne 0 ]]; then
  echo "init-firewall: must run as root (use: sudo init-firewall.sh <allowlist>)" >&2
  exit 1
fi

DOMAINS="${1:-${ALLOWED_DOMAINS:-}}"
if [[ -z "$DOMAINS" ]]; then
  echo "init-firewall: no allowlist given - refusing to guess." >&2
  exit 1
fi

# --- validate every entry BEFORE it reaches iptables or dnsmasq's config -----
# This runs as root with caller-supplied input. Anything but a plain hostname
# or IPv4 literal (a newline, '/', '#', '=') could inject dnsmasq directives or
# iptables arguments, so the whole list is rejected rather than sanitised.
HOST_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
IPV4_RE='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$'
if [[ "$DOMAINS" == *$'\n'* || "$DOMAINS" == *$'\r'* ]]; then
  echo "init-firewall: allowlist contains a line break - refusing." >&2
  exit 1
fi
LITERALS=()
NAMES=()
for entry in ${DOMAINS//,/ }; do
  if [[ "$entry" =~ $IPV4_RE ]]; then
    LITERALS+=("$entry")
  elif [[ ${#entry} -le 253 && "$entry" =~ $HOST_RE ]]; then
    NAMES+=("$entry")
  else
    echo "init-firewall: invalid allowlist entry '$entry' - refusing." >&2
    exit 1
  fi
done
if [[ $(( ${#LITERALS[@]} + ${#NAMES[@]} )) -eq 0 ]]; then
  echo "init-firewall: allowlist is empty after parsing - refusing." >&2
  exit 1
fi
# Canonical form, so the lock below compares lists, not formatting.
CANONICAL="$(printf '%s\n' "${LITERALS[@]}" "${NAMES[@]}" | sed '/^$/d' | sort -u | paste -sd, -)"

# --- the allowlist is set ONCE per container and cannot be widened -----------
# A sudoers rule with no argument spec accepts ANY arguments, so without this
# an agent could re-run `sudo init-firewall.sh evil.example` and grant itself
# an exit. The first successful application is recorded in a root-owned,
# read-only file; re-running with the same list is allowed (a container
# restart flushes iptables), a different list is refused.
STATE_DIR=/etc/agentbox
LOCK="$STATE_DIR/firewall-allowlist"
if [[ -f "$LOCK" ]]; then
  LOCKED="$(cat "$LOCK")"
  if [[ "$LOCKED" != "$CANONICAL" ]]; then
    echo "init-firewall: REFUSED - this container's allowlist is already set." >&2
    echo "  applied:   $LOCKED" >&2
    echo "  requested: $CANONICAL" >&2
    exit 1
  fi
fi

echo "init-firewall: applying default-deny egress"

# Reset policy to ACCEPT first: `-F` clears rules but not a previous DROP
# policy, and the resolution below needs the network.
iptables -P INPUT   ACCEPT
iptables -P OUTPUT  ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -X 2>/dev/null || true
ipset destroy allowed 2>/dev/null || true
ipset create allowed hash:net

# The container runtime's resolver(s) become dnsmasq's upstream. Captured once
# and persisted: after the first run resolv.conf points at our own dnsmasq, and
# a re-run must not configure dnsmasq to forward to itself.
mkdir -p "$STATE_DIR"
UPSTREAM_FILE="$STATE_DIR/upstream-resolvers"
UPSTREAM_NS=()
if [[ ! -f "$UPSTREAM_FILE" ]]; then
  awk '/^nameserver/ {print $2}' /etc/resolv.conf \
    | grep -E "$IPV4_RE" > "$UPSTREAM_FILE" || true
fi
while read -r ns; do
  [[ "$ns" =~ $IPV4_RE ]] && UPSTREAM_NS+=("$ns")
done < "$UPSTREAM_FILE"
if [[ ${#UPSTREAM_NS[@]} -eq 0 ]]; then
  echo "init-firewall: no IPv4 upstream resolver found in /etc/resolv.conf" >&2
  exit 1
fi
for ns in "${UPSTREAM_NS[@]}"; do
  ipset add allowed "$ns" 2>/dev/null || true
done

for ip in "${LITERALS[@]}"; do
  ipset add allowed "$ip" 2>/dev/null || true
  echo "  allow $ip (literal)"
done

# --- dnsmasq: the container's own resolver, self-updating the ipset ---------
mkdir -p /etc/dnsmasq.d
DNSMASQ_CONF=/etc/dnsmasq.d/agentbox-allowlist.conf
{
  echo "no-resolv"
  echo "no-hosts"
  echo "filter-AAAA"          # the ipset is IPv4-only (hash:net)
  # Under rootless Docker, container "root" is an unprivileged host user and
  # cannot signal a dnsmasq that dropped to `nobody`; a re-run must be able to
  # stop the previous instance, so it keeps the container's root identity.
  echo "user=root"
  echo "group=root"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "port=53"
  for ns in "${UPSTREAM_NS[@]}"; do
    echo "server=$ns"
  done
  for name in "${NAMES[@]}"; do
    echo "ipset=/$name/allowed"
  done
} > "$DNSMASQ_CONF"

DNSMASQ_PID=/run/dnsmasq-agentbox.pid
if [[ -f "$DNSMASQ_PID" ]] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
  kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
  sleep 0.5
fi
rm -f "$DNSMASQ_PID"
dnsmasq --conf-file=/dev/null --conf-dir=/etc/dnsmasq.d --pid-file="$DNSMASQ_PID"
sleep 0.5
if ! kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null; then
  echo "init-firewall: dnsmasq did not start - no allowed name would resolve." >&2
  exit 1
fi

echo "nameserver 127.0.0.1" > /etc/resolv.conf

# --- initial resolve, so the first connection does not have to wait ---------
resolved=0
for name in "${NAMES[@]}"; do
  n="$(dig +short A "$name" 2>/dev/null | grep -cE "$IPV4_RE" || true)"
  resolved=$((resolved + n))
  echo "  allow $name (${n} addresses now, self-updating)"
done
if [[ ${#LITERALS[@]} -eq 0 && $resolved -eq 0 ]]; then
  echo "init-firewall: nothing in the allowlist resolved - refusing to continue:" >&2
  echo "  a container with no egress at all looks identical to a working one." >&2
  exit 1
fi

# The container's default gateway (editor servers talk to the host through it).
GATEWAY="$(ip route | awk '/^default/ {print $3; exit}')"
if [[ "$GATEWAY" =~ $IPV4_RE ]]; then
  ipset add allowed "$GATEWAY" 2>/dev/null || true
fi

# --- policy -----------------------------------------------------------------
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -m set --match-set allowed dst -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -m set --match-set allowed dst -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT

# Blocked egress is REFUSED rather than dropped: identical on the wire (the
# reset is generated by this container's own kernel), but a missing allowlist
# entry then fails in microseconds instead of presenting as a silent hang.
# INPUT/FORWARD stay DROP. Non-fatal if the REJECT target is unavailable -
# policy DROP below still denies egress.
if iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset 2>/dev/null \
   && iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
  REJECT_MODE="refused instantly"
else
  echo "init-firewall: WARNING - REJECT target unavailable; blocked egress will hang." >&2
  REJECT_MODE="dropped (no REJECT target)"
fi

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# --- verify: something outside must FAIL, something inside must WORK --------
if curl -s --max-time 5 https://example.com >/dev/null 2>&1; then
  echo "init-firewall: VERIFICATION FAILED - example.com is still reachable." >&2
  exit 1
fi

if [[ ${#NAMES[@]} -gt 0 ]]; then
  PROBE="${NAMES[0]}"
else
  PROBE="${LITERALS[0]}"
fi
if ! curl -s --max-time 10 -o /dev/null "https://${PROBE}" 2>/dev/null; then
  # Any HTTP answer (even 4xx) proves reachability; only a failed connect is fatal.
  if ! timeout 5 bash -c "</dev/tcp/${PROBE}/443" 2>/dev/null; then
    echo "init-firewall: VERIFICATION FAILED - ${PROBE} is NOT reachable." >&2
    exit 1
  fi
fi

# Recorded only once proven to work, so a failed run cannot lock the container
# to an allowlist that was never installed.
if [[ ! -f "$LOCK" ]]; then
  printf '%s' "$CANONICAL" > "$LOCK"
  chmod 0444 "$LOCK"
fi

echo "init-firewall: OK - egress denied by default (${REJECT_MODE}); ${PROBE} reachable, example.com blocked"
