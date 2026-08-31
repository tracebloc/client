#!/usr/bin/env bash
#
#  kubelet-config-mutations.sh — proves kubelet-config-agreement.sh actually
#  catches things (backend#2634).
#
#  Rule 5: break the thing, watch the guard redden, restore. Rule 9: each case
#  copies the real installers into a fixture tree and drives the REAL guard via
#  TB_KUBELET_CFG_ROOT. Nothing here re-implements the rule -- an inline copy
#  drifts from production and then proves that a regex nobody runs would have
#  caught the bug.
#
#  ANCHORS ARE ASSERTED APPLIED. A mutation whose anchor no longer matches is a
#  hard failure, not a skip: an inert mutation and real coverage look identical
#  in a log, which is the whole shape backend#1729 catalogued.
#
#  The fixture tree is a COPY, so a case that would corrupt an installer cannot.
#  Read-only with respect to the repo.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$here/../.." && pwd)"
GUARD="$SRC/scripts/tests/kubelet-config-agreement.sh"

[ -r "$GUARD" ] || { printf 'ERROR: cannot read %s\n' "$GUARD" >&2; exit 2; }

pass=0; fail=0

# want: expected exit status. 0 clean, 1 violation, 2 cannot tell.
run_case() {
  local label="$1" file="$2" old="$3" new="$4" want="$5" chmod_target="${6:-}"
  local td; td="$(mktemp -d "${TMPDIR:-/tmp}/kcg-mut-XXXXXX")" || { printf 'ERROR: mktemp\n' >&2; exit 2; }
  mkdir -p "$td/scripts/lib" "$td/scripts/tests"
  cp "$SRC/scripts/lib/cluster.sh" "$td/scripts/lib/" 2>/dev/null
  cp "$SRC/scripts/install-k8s.ps1" "$td/scripts/" 2>/dev/null

  if [ -n "$file" ]; then
    local target="$td/$file" n
    n="$(grep -cF -- "$old" "$target" 2>/dev/null)" || n=0
    if [ "$n" -ne 1 ]; then
      printf '  %-54s ANCHOR MATCHED %sx (INERT MUTATION)\n' "$label" "$n"
      fail=$((fail + 1)); rm -rf "$td"; return
    fi
    TB_M_TARGET="$target" TB_M_OLD="$old" TB_M_NEW="$new" python3 - <<'PY'
import os
p, o, n = os.environ["TB_M_TARGET"], os.environ["TB_M_OLD"], os.environ["TB_M_NEW"]
s = open(p, encoding="utf-8").read()
assert s.count(o) == 1, "anchor drifted between check and write"
open(p, "w", encoding="utf-8").write(s.replace(o, n, 1))
PY
  fi
  # Fail-closed cases: make a file unreadable, or remove it outright.
  case "$chmod_target" in
    unreadable) chmod 000 "$td/scripts/lib/cluster.sh" ;;
    missing)    rm -f "$td/scripts/install-k8s.ps1" ;;
  esac

  TB_KUBELET_CFG_ROOT="$td" bash "$GUARD" >/dev/null 2>&1
  local rc=$?
  chmod 700 "$td/scripts/lib/cluster.sh" 2>/dev/null
  if [ "$rc" -eq "$want" ]; then
    printf '  %-54s rc=%s (want %s)  caught\n' "$label" "$rc" "$want"; pass=$((pass + 1))
  else
    printf '  %-54s rc=%s (want %s)  VACUOUS\n' "$label" "$rc" "$want"; fail=$((fail + 1))
  fi
  rm -rf "$td"
}

CS="scripts/lib/cluster.sh"
PS="scripts/install-k8s.ps1"

printf 'baseline — an unmutated copy of the real tree must be clean:\n'
run_case "unmutated tree" "" "" "" 0

printf '\nthe values:\n'
run_case "high raised ABOVE the stock 85 it replaces" "$CS" \
  "TB_KUBELET_IMAGE_GC_HIGH_PERCENT=75" "TB_KUBELET_IMAGE_GC_HIGH_PERCENT=90" 1
run_case "band narrowed to 5 points (the stock failure)" "$CS" \
  "TB_KUBELET_IMAGE_GC_LOW_PERCENT=60" "TB_KUBELET_IMAGE_GC_LOW_PERCENT=70" 1
run_case "low raised above high (kubelet refuses to start)" "$CS" \
  "TB_KUBELET_IMAGE_GC_LOW_PERCENT=60" "TB_KUBELET_IMAGE_GC_LOW_PERCENT=80" 1
run_case "a threshold renamed away, so nothing sets it" "$CS" \
  "TB_KUBELET_IMAGE_GC_HIGH_PERCENT=75" "TB_KUBELET_IMAGE_GC_HIGH_PERCENT_X=75" 1

printf '\ntwin divergence — the gap client#772 records five real bugs in:\n'
run_case "twins diverge on high" "$PS" \
  '$TB_KUBELET_IMAGE_GC_HIGH_PERCENT = 75' '$TB_KUBELET_IMAGE_GC_HIGH_PERCENT = 70' 1
run_case "twins diverge on the minimum GC age" "$PS" \
  '$TB_KUBELET_IMAGE_MIN_GC_AGE      = "2m"' '$TB_KUBELET_IMAGE_MIN_GC_AGE      = "9m"' 1
run_case "twins diverge on the in-node config path" "$PS" \
  '$TB_KUBELET_CONFIG_NODE_PATH      = "/etc/tracebloc/kubelet.yaml"' \
  '$TB_KUBELET_CONFIG_NODE_PATH      = "/etc/tracebloc/other.yaml"' 1

printf '\nthe silent no-op — a drop-in nothing reads:\n'
run_case "ps1 stops passing --kubelet-arg=config" "$PS" \
  '"--kubelet-arg=config=${TB_KUBELET_CONFIG_NODE_PATH}@all"' \
  '"--kubelet-arg=fail-cgroupv1=false@all"' 1
run_case "bash mounts the file but never points the kubelet at it" "$CS" \
  '  K3D_ARGS+=(--k3s-arg "--kubelet-arg=config=${TB_KUBELET_CONFIG_NODE_PATH}@all")' \
  '  :' 1

printf '\nfail closed — "cannot tell" must never read as agreement:\n'
run_case "cluster.sh unreadable" "" "" "" 2 unreadable
run_case "install-k8s.ps1 absent" "" "" "" 2 missing

printf '\nkubelet-config-mutations: %d caught, %d vacuous\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
