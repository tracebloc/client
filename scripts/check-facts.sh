#!/usr/bin/env bash
# =============================================================================
#  check-facts.sh — keep cross-OS installer FACTS in lockstep with the single
#                   source of truth, scripts/spec/facts.env (#435, RFC D3/D4).
#
#  The costliest drift class of the installer sweep was facts diverging between the
#  three OS implementations — the #410 incident (k3d/helm pins bumped in bash but not
#  PowerShell) failed a real customer install. facts.env is the authoritative spec; its
#  values are STAMPED into each consumer (bash common.sh, PowerShell install-k8s.ps1) so
#  the bootstrap stays a single verified file (R8) — nothing is sourced at runtime.
#
#  Usage:
#    scripts/check-facts.sh            # --write: stamp facts.env into every consumer
#    scripts/check-facts.sh --write    # (same)
#    scripts/check-facts.sh --check    # verify every consumer matches facts.env
#                                      #   (CI gate; non-zero on drift — the #410 guard)
#
#  Mirrors gen-manifest.sh's write/check split; safe to run anywhere (no secrets).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SPEC="scripts/spec/facts.env"
COMMON="scripts/lib/common.sh"
SUMMARY="scripts/lib/summary.sh"
PS1="scripts/install-k8s.ps1"

MODE="write"
case "${1:-}" in
  --check) MODE="check" ;;
  --write | "") MODE="write" ;;
  *) echo "usage: $0 [--write|--check]" >&2; exit 2 ;;
esac

[[ -f "$SPEC" ]] || { echo "check-facts: spec not found: $SPEC" >&2; exit 2; }

# Read a bare KEY=value from the spec (comments/blank lines ignored). Fails closed:
# a missing/empty key is a spec error, not a silent pass.
_spec_get() {
  local key="$1" val
  val="$(sed -n "s/^${key}=\(.*\)$/\1/p" "$SPEC" | head -1)"
  [[ -n "$val" ]] || { echo "check-facts: '${key}' missing from ${SPEC}" >&2; exit 2; }
  printf '%s' "$val"
}

# Each consumer fact: a stable NAME, the FILE, a sed EXTRACTOR that echoes the currently
# stamped value, and the spec KEY it must equal. Kept as parallel arrays (bash 3.2 — no
# associative arrays). To cover a new fact/consumer, add a row here.
FACT_NAMES=(
  "common.sh:K3D_VERSION"
  "common.sh:HELM_VERSION"
  "common.sh:K8S_VERSION"
  "install-k8s.ps1:K3dVersion"
  "install-k8s.ps1:HelmVersion"
  "install-k8s.ps1:K8S_VERSION"
  "summary.sh:READY_TIMEOUT"
  "install-k8s.ps1:ReadyTimeout"
)
FACT_FILES=( "$COMMON" "$COMMON" "$COMMON" "$PS1" "$PS1" "$PS1" "$SUMMARY" "$PS1" )
FACT_KEYS=( K3D_VERSION HELM_VERSION K8S_VERSION K3D_VERSION HELM_VERSION K8S_VERSION READY_TIMEOUT READY_TIMEOUT )
FACT_EXTRACT=(
  's/^K3D_VERSION="\${K3D_VERSION:-\(.*\)}".*/\1/p'
  's/^HELM_VERSION="\${HELM_VERSION:-\(.*\)}".*/\1/p'
  's/^K8S_VERSION="\${K8S_VERSION:-\(.*\)}".*/\1/p'
  's/.*\$script:K3dVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$script:HelmVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$K8S_VERSION .*else { "\([^"]*\)" }.*/\1/p'
  's/^READY_TIMEOUT="\${READY_TIMEOUT:-\(.*\)}".*/\1/p'
  's/.*\$ReadyTimeout .*else { "\([^"]*\)" }.*/\1/p'
)
# For --write: an sed program that substitutes the OLD value with @@VAL@@ (replaced with
# the spec value below). Anchored the same way as the extractor so only the pinned token
# changes. \& / @@VAL@@ placeholder avoids re-escaping the value into a sed replacement.
FACT_REWRITE=(
  's|^\(K3D_VERSION="${K3D_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(HELM_VERSION="${HELM_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(K8S_VERSION="${K8S_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(\$script:K3dVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$script:HelmVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$K8S_VERSION .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\(READY_TIMEOUT="${READY_TIMEOUT:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(\$ReadyTimeout .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
)

_extract() { sed -n "$2" "$1" | head -1; }

drift=0
i=0
while [ "$i" -lt "${#FACT_NAMES[@]}" ]; do
  name="${FACT_NAMES[$i]}"; file="${FACT_FILES[$i]}"; key="${FACT_KEYS[$i]}"
  want="$(_spec_get "$key")"
  if [[ ! -f "$file" ]]; then
    echo "  ✖ ${name}: ${file} not found" >&2; drift=$(( drift + 1 )); i=$(( i + 1 )); continue
  fi
  got="$(_extract "$file" "${FACT_EXTRACT[$i]}")"
  if [[ -z "$got" ]]; then
    echo "  ✖ ${name}: no pinned value found in ${file} (pattern moved?)" >&2; drift=$(( drift + 1 )); i=$(( i + 1 )); continue
  fi
  if [[ "$MODE" == "check" ]]; then
    if [[ "$got" != "$want" ]]; then
      echo "  ✖ ${name} = ${got}  ≠  ${SPEC} (${key} = ${want})" >&2
      drift=$(( drift + 1 ))
    else
      echo "  ✔ ${name} = ${got}"
    fi
  else
    if [[ "$got" == "$want" ]]; then
      echo "  ✔ ${name} already ${want}"
    else
      prog="${FACT_REWRITE[$i]/@@VAL@@/$want}"
      tmp="$(mktemp)"
      sed "$prog" "$file" > "$tmp" && mv "$tmp" "$file"
      echo "  ↻ ${name}: ${got} → ${want}"
    fi
  fi
  i=$(( i + 1 ))
done

if [[ "$MODE" == "check" ]]; then
  if [[ "$drift" -ne 0 ]]; then
    echo "" >&2
    echo "check-facts: ${drift} fact(s) drifted from ${SPEC}. Run 'scripts/check-facts.sh --write' and commit." >&2
    exit 1
  fi
  echo "check-facts: all installer facts match ${SPEC}."
else
  [[ "$drift" -eq 0 ]] || { echo "check-facts: ${drift} consumer(s) could not be stamped (see above)." >&2; exit 1; }
  echo "check-facts: ${SPEC} stamped into all consumers."
fi
