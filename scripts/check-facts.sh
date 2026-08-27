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
HELM_LIB="scripts/lib/install-client-helm.sh"
PS1="scripts/install-k8s.ps1"
CLUSTER="scripts/lib/cluster.sh"
# #616: the GPU node image (docker/k3s-cuda) rebuilds the SAME pinned k3s, so its
# K3S_TAG in the Dockerfile ARG, build.sh, and the workflow input default must all
# equal facts.env's K8S_VERSION — else a K8S_VERSION bump derives a GPU image tag
# that was never published and the installer pulls a missing image.
CUDA_DOCKERFILE="docker/k3s-cuda/Dockerfile"
CUDA_BUILD="docker/k3s-cuda/build.sh"
CUDA_WORKFLOW=".github/workflows/build-k3s-cuda.yaml"

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
  local key="$1" all val
  # Capture whole, then take the first line with `%%$'\n'*` — NOT `… | head -1`.
  # Under `set -o pipefail` a duplicate key makes head close the pipe after line 1,
  # sed takes SIGPIPE, and the pipeline exits 141 — aborting the facts gate before
  # any drift message prints (a crash/fail-open on duplicate input).
  all="$(sed -n "s/^${key}=\(.*\)$/\1/p" "$SPEC")"
  val="${all%%$'\n'*}"
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
  "common.sh:K8S_VERSION-help"
  "install-k8s.ps1:K3dVersion"
  "install-k8s.ps1:HelmVersion"
  "install-k8s.ps1:K8S_VERSION"
  "install-k8s.ps1:K8S_VERSION-help"
  "summary.sh:READY_TIMEOUT"
  "install-k8s.ps1:ReadyTimeout"
  "install-client-helm.sh:METRICS_WAIT_TIMEOUT"
  "install-k8s.ps1:MetricsWaitTimeout"
  "k3s-cuda/Dockerfile:K3S_TAG"
  "k3s-cuda/build.sh:K3S_TAG"
  "build-k3s-cuda.yaml:k3s_tag"
  "install-k8s.ps1:CUDA_BASE_TAG"
  "common.sh:CUDA_BASE_TAG"
  "k3s-cuda/Dockerfile:CUDA_TAG"
  "k3s-cuda/build.sh:CUDA_TAG"
  "build-k3s-cuda.yaml:cuda_tag"
)
FACT_FILES=( "$COMMON" "$COMMON" "$COMMON" "$COMMON" "$PS1" "$PS1" "$PS1" "$PS1" "$SUMMARY" "$PS1" "$HELM_LIB" "$PS1" "$CUDA_DOCKERFILE" "$CUDA_BUILD" "$CUDA_WORKFLOW" "$PS1" "$COMMON" "$CUDA_DOCKERFILE" "$CUDA_BUILD" "$CUDA_WORKFLOW" )
FACT_KEYS=( K3D_VERSION HELM_VERSION K8S_VERSION K8S_VERSION K3D_VERSION HELM_VERSION K8S_VERSION K8S_VERSION READY_TIMEOUT READY_TIMEOUT METRICS_WAIT_TIMEOUT METRICS_WAIT_TIMEOUT K8S_VERSION K8S_VERSION K8S_VERSION CUDA_TAG CUDA_TAG CUDA_TAG CUDA_TAG CUDA_TAG )
FACT_EXTRACT=(
  's/^K3D_VERSION="\${K3D_VERSION:-\(.*\)}".*/\1/p'
  's/^HELM_VERSION="\${HELM_VERSION:-\(.*\)}".*/\1/p'
  's/^K8S_VERSION="\${K8S_VERSION:-\(.*\)}".*/\1/p'
  's/^ *K8S_VERSION *k3s image tag *(default: \(.*\))$/\1/p'
  's/.*\$script:K3dVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$script:HelmVersion .*else { "\([^"]*\)" }.*/\1/p'
  's/.*\$K8S_VERSION .*else { "\([^"]*\)" }.*/\1/p'
  's/^ *K8S_VERSION *k3s image tag *(default: \(.*\))$/\1/p'
  's/^READY_TIMEOUT="\${READY_TIMEOUT:-\(.*\)}".*/\1/p'
  's/.*\$ReadyTimeout .*else { "\([^"]*\)" }.*/\1/p'
  's/^METRICS_WAIT_TIMEOUT=\([0-9]*\)$/\1/p'
  's/.*\$script:MetricsWaitTimeout = \([0-9]*\).*/\1/p'
  's/^ARG K3S_TAG="\(.*\)".*/\1/p'
  's/^K3S_TAG="\${K3S_TAG:-\(.*\)}".*/\1/p'
  's/^ *default: "\(v[0-9][^"]*\)".*/\1/p'
  's/.*\$CUDA_BASE_TAG .*else { "\([^"]*\)" }.*/\1/p'
  's/^TB_CUDA_BASE_TAG="\${TRACEBLOC_CUDA_BASE_TAG:-\(.*\)}".*/\1/p'
  's/^ARG CUDA_TAG="\(.*\)".*/\1/p'
  's/^CUDA_TAG="\${CUDA_TAG:-\(.*\)}".*/\1/p'
  's/^ *default: "\([0-9][^"]*ubuntu[^"]*\)".*/\1/p'
)
# For --write: an sed program that substitutes the OLD value with @@VAL@@ (replaced with
# the spec value below). Anchored the same way as the extractor so only the pinned token
# changes. \& / @@VAL@@ placeholder avoids re-escaping the value into a sed replacement.
FACT_REWRITE=(
  's|^\(K3D_VERSION="${K3D_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(HELM_VERSION="${HELM_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(K8S_VERSION="${K8S_VERSION:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\( *K8S_VERSION *k3s image tag *(default: \)[^)]*\()\)|\1@@VAL@@\2|'
  's|\(\$script:K3dVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$script:HelmVersion .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|\(\$K8S_VERSION .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\( *K8S_VERSION *k3s image tag *(default: \)[^)]*\()\)|\1@@VAL@@\2|'
  's|^\(READY_TIMEOUT="${READY_TIMEOUT:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(\$ReadyTimeout .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\(METRICS_WAIT_TIMEOUT=\)[0-9]*$|\1@@VAL@@|'
  's|\(\$script:MetricsWaitTimeout = \)[0-9]*|\1@@VAL@@|'
  's|^\(ARG K3S_TAG="\)[^"]*\("\)|\1@@VAL@@\2|'
  's|^\(K3S_TAG="${K3S_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(default: "\)v[0-9][^"]*\("\)|\1@@VAL@@\2|'
  's|\(\$CUDA_BASE_TAG .*else { "\)[^"]*\(" }\)|\1@@VAL@@\2|'
  's|^\(TB_CUDA_BASE_TAG="${TRACEBLOC_CUDA_BASE_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|^\(ARG CUDA_TAG="\)[^"]*\("\)|\1@@VAL@@\2|'
  's|^\(CUDA_TAG="${CUDA_TAG:-\)[^}]*\(}"\)|\1@@VAL@@\2|'
  's|\(default: "\)[0-9][^"]*ubuntu[^"]*\("\)|\1@@VAL@@\2|'
)

# Capture whole, then take the first line with `%%$'\n'*` — NOT `… | head -1`, which
# SIGPIPEs sed (exit 141) under `set -o pipefail` when a file has a second match.
_extract() { local all; all="$(sed -n "$2" "$1")"; printf '%s' "${all%%$'\n'*}"; }

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

# Structural guard (#547 / F4): the fact table above only compares the pinned
# VERSION STRINGS — it does NOT verify the create command actually WIRES the k3s
# pin into the cluster. #547 drifted precisely because `--image rancher/k3s:<ver>`
# can be dropped/gated while the version string stays correct and CI stays green.
# Assert the create-time wiring is present in both installers so a refactor can't
# silently unpin k3s. Fixed-string (grep -F): these are literal shell/PS tokens.
_check_wiring() {  # name  file  literal
  if [[ ! -f "$2" ]]; then
    echo "  ✖ ${1}: ${2} not found" >&2; return 1
  fi
  if grep -qF "$3" "$2"; then
    echo "  ✔ ${1}: k3s --image pin present in ${2}"; return 0
  fi
  echo "  ✖ ${1}: create-time '${3}' not found in ${2} — k3s could float (#547)" >&2; return 1
}
# Wiring failures are tracked SEPARATELY from version drift: `--write` restamps
# version strings but CANNOT restore create-time wiring, so a wiring gap must not
# emit the "run --write" hint (Bugbot #565) — it needs a hand-fix.
wiring_fail=0
if [[ "$MODE" == "check" ]]; then
  _check_wiring "cluster.sh:k3s-image-pin"      "$CLUSTER" 'rancher/k3s:${K8S_VERSION}' || wiring_fail=$(( wiring_fail + 1 ))
  _check_wiring "install-k8s.ps1:k3s-image-pin" "$PS1"     'rancher/k3s:$K8S_VERSION'    || wiring_fail=$(( wiring_fail + 1 ))
  # GPU node image (client#835): the create path must derive the k3s-cuda tag from
  # BOTH pins, or a GPU cluster would pull a stale/never-built image after a bump.
  # Each shell spells the derivation its own way (braces vs none).
  _check_wiring "cluster.sh:gpu-image-pin"      "$CLUSTER" 'tracebloc/k3s-cuda:${K8S_VERSION}-cuda-${TB_CUDA_BASE_TAG}' || wiring_fail=$(( wiring_fail + 1 ))
  _check_wiring "install-k8s.ps1:gpu-image-pin" "$PS1"     'tracebloc/k3s-cuda:$K8S_VERSION-cuda-$CUDA_BASE_TAG'        || wiring_fail=$(( wiring_fail + 1 ))
fi

if [[ "$MODE" == "check" ]]; then
  rc=0
  if [[ "$drift" -ne 0 ]]; then
    echo "" >&2
    echo "check-facts: ${drift} fact(s) drifted from ${SPEC}. Run 'scripts/check-facts.sh --write' and commit." >&2
    rc=1
  fi
  if [[ "$wiring_fail" -ne 0 ]]; then
    echo "" >&2
    echo "check-facts: the k3s / GPU --image pin is missing from the create path in ${wiring_fail} file(s) (see ✖ above)." >&2
    echo "check-facts: this is a WIRING gap, not a version bump — '--write' cannot fix it. Restore the create-time" >&2
    echo "             --image pin by hand using the EXACT literal each ✖ line above shows — the two shells differ:" >&2
    echo "             bash cluster.sh uses '\${K8S_VERSION}' (braces); PowerShell install-k8s.ps1 uses" >&2
    echo "             '\$K8S_VERSION' (no braces). So k3s (and the GPU node image) can't float (#547/#835)." >&2
    rc=1
  fi
  [[ "$rc" -eq 0 ]] || exit 1
  echo "check-facts: all installer facts match ${SPEC}."
else
  [[ "$drift" -eq 0 ]] || { echo "check-facts: ${drift} consumer(s) could not be stamped (see above)." >&2; exit 1; }
  echo "check-facts: ${SPEC} stamped into all consumers."
fi
