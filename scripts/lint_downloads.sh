#!/usr/bin/env bash
#
# lint_downloads.sh - enforce the supply-chain rules on the Dockerfile.
#
#   scripts/lint_downloads.sh [Dockerfile...]
#
# Fails if:
#   1. anything fetched from the network is piped into an interpreter
#      (curl ... | sh, wget -O- ... | bash, ... | python)
#   2. the Dockerfile calls curl or wget directly - every download must go
#      through fetch_verified (which checks the upstream-published SHA-256)
#   3. a version ARG has no `# renovate:` annotation on the line(s) above it,
#      so Renovate could not keep it current.
set -uo pipefail

files=("$@")
[[ ${#files[@]} -eq 0 ]] && files=(Dockerfile)
fail=0

for f in "${files[@]}"; do
  # Join backslash-continued lines so a pipe on the next line is still caught.
  joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$f")"

  if grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(env[^|]*[[:space:]])?(ba|z|da|k)?sh\b|(curl|wget)[^|]*\|[[:space:]]*python' <<<"$joined"; then
    echo "$f: network download piped into an interpreter (rule 1)"; fail=1
  fi

  if grep -nE '^[^#]*\b(curl|wget)[[:space:]]+(-|"?https?://|"?\$)' <<<"$joined"; then
    echo "$f: direct curl/wget - use fetch_verified (rule 2)"; fail=1
  fi

  awk -v f="$f" '
    /^[[:space:]]*# renovate:/ { annotated=1; next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*ARG[[:space:]]+[A-Z0-9_]*_VERSION=/ {
      if (!annotated) { print f ":" NR ": " $0 "  <- no # renovate: annotation (rule 3)"; bad=1 }
    }
    { annotated=0 }
    END { exit bad }
  ' "$f" || fail=1
done

if [[ $fail -ne 0 ]]; then
  echo "lint_downloads: FAILED"; exit 1
fi
echo "lint_downloads: OK (${files[*]})"
