#!/usr/bin/env bash
#
# fetch_verified.sh - the ONLY way the Dockerfile downloads anything.
#
#   fetch_verified.sh <artifact-url> <checksum-url> <output-path>
#
# Downloads the artifact and the SHA-256 checksum file the upstream project
# publishes for that exact version, then verifies one against the other.
# Exits non-zero - failing the build - if either download fails, if the
# checksum file has no entry for the artifact, or if the digest does not match.
#
# No checksum is ever committed to this repo: versions are pinned (and bumped
# by Renovate), checksums are whatever upstream publishes for that version.
# Nothing downloaded is ever piped into a shell.
#
# Understood checksum-file formats:
#   * a multi-line SHA256SUMS list:  "<hex>  <filename>"  (also "<hex> *<filename>")
#   * a single-artifact file:        "<hex>"  or  "<hex>  <filename>"
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: fetch_verified.sh <artifact-url> <checksum-url> <output-path>" >&2
  exit 2
fi
url="$1" sum_url="$2" out="$3"
name="$(basename "${url%%\?*}")"

curl_opts=(--fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl "${curl_opts[@]}" -o "$tmp/artifact" "$url"
curl "${curl_opts[@]}" -o "$tmp/sums" "$sum_url"

# A line naming this artifact wins; otherwise accept a file that holds exactly
# one digest (a per-artifact .sha256 file).
expected="$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f)} f==n {print tolower($1); exit}' "$tmp/sums")"
if [[ -z "$expected" ]]; then
  mapfile -t digests < <(grep -oiE '\b[0-9a-f]{64}\b' "$tmp/sums" || true)
  if [[ ${#digests[@]} -eq 1 ]]; then
    expected="${digests[0],,}"
  fi
fi
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
  echo "fetch_verified: no SHA-256 for '$name' in $sum_url - refusing to use it" >&2
  exit 1
fi

actual="$(sha256sum "$tmp/artifact" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  echo "fetch_verified: CHECKSUM MISMATCH for $name" >&2
  echo "  expected $expected (from $sum_url)" >&2
  echo "  got      $actual" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
mv "$tmp/artifact" "$out"
echo "fetch_verified: $name OK ($actual)"
