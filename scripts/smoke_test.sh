#!/usr/bin/env bash
#
# smoke_test.sh - run INSIDE an agentbox image to prove it is what README.md
# says it is.
#
#   docker run --rm -v "$PWD:/src:ro" agentbox:<target> bash /src/scripts/smoke_test.sh <target>
#
# README.md is the source of truth: every row of the `<!-- tools:core -->`
# table and of the `<!-- tools:<target> -->` table is checked. The first cell
# of a row is either a command name (`node`) - it must be on PATH - or a
# Python import (`import cv2`) - it must import. So the README cannot list a
# tool the image does not have.
#
# Also asserts the image's security properties: non-root default user, no
# npm, no Copilot, no local-training stack, and no credential-looking or
# deployment-specific values in the environment.
set -uo pipefail

target="${1:?usage: smoke_test.sh <core|cad|ml|infra>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$here/README.md"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok()  { echo "ok:   $*"; }

table_checks() {
  # Print the first-cell backtick contents of every row in the tools:<name> block.
  awk -v start="<!-- tools:$1 -->" -v stop="<!-- /tools:$1 -->" '
    index($0, start) {on=1; next}
    index($0, stop)  {on=0}
    on && /^\|/ { if (match($0, /^\|[ ]*`[^`]+`/)) { s=substr($0, RSTART, RLENGTH); sub(/^\|[ ]*`/, "", s); sub(/`$/, "", s); print s } }
  ' "$readme"
}

sections=(core)
[[ "$target" != core ]] && sections+=("$target")
for s in "${sections[@]}"; do
  mapfile -t checks < <(table_checks "$s")
  if [[ ${#checks[@]} -eq 0 ]]; then
    bad "README.md has no <!-- tools:$s --> table"
    continue
  fi
  for c in "${checks[@]}"; do
    if [[ "$c" == import\ * ]]; then
      if python3 -c "$c" 2>/dev/null; then ok "$c"; else bad "$c (README tools:$s)"; fi
    elif command -v "$c" >/dev/null 2>&1; then
      ok "$c -> $(command -v "$c")"
    else
      bad "$c not on PATH (README tools:$s)"
    fi
  done
done

# expect <description> <command...>: the command must succeed.
expect() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# refuse <description> <command...>: the command must FAIL.
refuse() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

# Tools must actually run, not just exist.
expect "claude runs" claude --version
expect "opencode runs" opencode --version
expect "gh runs" gh --version
case "$target" in
  cad)   expect "openscad-nightly runs" openscad-nightly --version ;;
  ml)    expect "gcloud runs" gcloud version
         expect "arduino:avr core installed" bash -c "arduino-cli core list | grep -q '^arduino:avr'"
         expect "AccelStepper installed" bash -c "arduino-cli lib list | grep -q '^AccelStepper'" ;;
  infra) expect "gcloud runs" gcloud version
         expect "tofu runs" tofu version ;;
esac

# --- security properties -----------------------------------------------------
refuse "default user is non-root ($(id -un))" test "$(id -u)" -eq 0
for absent in npm npx corepack copilot copilot-real wget; do
  refuse "no $absent in the image" command -v "$absent"
done
for mod in ultralytics torch; do
  refuse "no python module $mod" python3 -c "import $mod"
done
if env | grep -iE '^[^=]*(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIALS)[^=]*=' ; then
  bad "credential-looking variable in the image environment"
else
  ok "no credential-looking env vars"
fi
if env | grep -E 'VERTEX_PROJECT|GOOGLE_CLOUD_PROJECT|CLOUDSDK_CORE_PROJECT|COPILOT'; then
  bad "deployment-specific variable baked into the image"
else
  ok "no deployment-specific env vars"
fi
for f in init-firewall.sh agentbox-gh-token; do
  if [[ "$(stat -c '%U %a' "/usr/local/bin/$f")" == "root 755" ]]; then
    ok "$f root-owned 0755"
  else
    bad "$f must be root-owned 0755"
  fi
done
# With no GitHub App mounted: no token, and git's helper stays out of the way.
refuse "no GitHub token without a mounted App" agentbox-gh-token
expect "git uses the GitHub App helper for github.com" \
  test "$(git config --system --get credential.https://github.com.helper)" = agentbox
if [[ -z "$(printf 'protocol=https\nhost=github.com\n\n' | git-credential-agentbox get)" ]]; then
  ok "git credential helper silent without a mounted App"
else
  bad "git credential helper answered without a mounted App"
fi
# /etc/sudoers.d is not readable by the agent; ask sudo itself (NOPASSWD
# entries make `sudo -l` password-free).
rights="$(sudo -n -l 2>/dev/null | sed -n '/may run the following commands/,$p' | tail -n +2 | sed 's/^[[:space:]]*//' | sed '/^$/d')"
expected_rights="(root) NOPASSWD: /usr/local/bin/init-firewall.sh
(root) NOPASSWD: /usr/local/bin/agentbox-gh-token"
if [[ "$(sort <<<"$rights")" == "$(sort <<<"$expected_rights")" ]]; then
  ok "only sudo rights are the firewall script and the GitHub App token helper"
else
  bad "unexpected sudo rights: ${rights:-<none>}"
fi

echo
echo "--- versions ($target) ---"
node --version; claude --version; opencode --version; uv --version; git --version | head -1; gh --version | head -1
case "$target" in
  cad)   openscad-nightly --version 2>&1 | head -1; python3 -c 'import trimesh; print("trimesh", trimesh.__version__)' ;;
  ml)    gcloud version 2>/dev/null | head -1; arduino-cli version
         python3 -c 'import cv2, imagehash, numpy, onnxruntime; print("opencv", cv2.__version__, "imagehash", imagehash.__version__, "numpy", numpy.__version__, "onnxruntime", onnxruntime.__version__)' ;;
  infra) gcloud version 2>/dev/null | head -1; tofu version | head -1 ;;
esac

if [[ $fail -ne 0 ]]; then
  echo; echo "smoke_test: $target FAILED"; exit 1
fi
echo; echo "smoke_test: $target PASS"
