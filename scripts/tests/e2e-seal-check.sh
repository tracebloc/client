#!/usr/bin/env bash
# =============================================================================
#  e2e-seal-check.sh — live seal-check conformance probe (RFC-0003 D12, #1184)
# -----------------------------------------------------------------------------
#  The chart ships its enforcement probes as `helm.sh/hook: test` Jobs, but
#  until now `helm test` ran NOWHERE in CI. The SEAL-CHECK §8.4 status recorded
#  the k3d/k3s NetworkPolicy *substrate* as verified (client#504) while the
#  full-chart egress-enforcement probe run stayed "pending". This closes that
#  gap: install the local chart on a real k3d cluster with the egress lockdown
#  engaged, run ONLY the egress-enforcement seal-check via `helm test`, and
#  prove the probe actually fires and passes — a training-labelled pod's direct
#  TCP egress to the probe host is blocked by the CNI.
#
#  egress-enforcement is the one seal-check that needs ZERO secrets: a public
#  curl image against 1.1.1.1, no backend, no private images — so it runs on a
#  stock GitHub runner. The other probes (backend-reachability, bound-PVC
#  storage-assertions) need the dev harness with real credentials and are out
#  of scope here.
#
#  Usage:  bash scripts/tests/e2e-seal-check.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
CHART_DIR="$HERE/../../client"

# Isolated cluster + release so we never touch a real 'tracebloc' install.
export CLUSTER_NAME="${CLUSTER_NAME:-tbseal}"
NS="tbseal"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh" # provides _pf_recheck_runtime_mem (called by create_cluster)

cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Prerequisites. The sourced libs DEFINE these installers but do not call them;
# create_cluster + helm need the binaries on PATH first, and a stock GitHub
# runner ships none of k3d/helm/kubectl. Mirror e2e-auto-upgrade.sh exactly.
has docker || fail "Docker is not available on this host."
umask 022
install_kubectl
install_k3d
install_helm

echo "── create_cluster() — real k3d bring-up (k3s enforces egress NetworkPolicy) ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "── helm install (public images, egress lockdown ENGAGED) ──"
# Local working-tree chart, public images (no registry secret), local-path
# storage, and allowExternalHttps=false so the training-egress NetworkPolicy is
# rendered and the egress-enforcement-check Job renders (it is gated on the
# lockdown flag + a non-empty enforcementProbeHost, chart default 1.1.1.1).
helm install "$NS" "$CHART_DIR" --namespace "$NS" --create-namespace \
  -f "$CHART_DIR/tests/values-public-images.yaml" \
  --set clientId=ci-e2e-seal \
  --set clientPassword=ci-e2e-seal \
  --set storageClass.provisioner=rancher.io/local-path \
  --set networkPolicy.training.allowExternalHttps=false

# The one probe we exercise. Its Job is `<release>-egress-enforcement-check`
# (templates/egress-enforcement-check.yaml). The helm-unittest suite pins this
# exact name so the --filter below can never silently drift off it.
PROBE="${NS}-egress-enforcement-check"

echo "── helm test --filter name=${PROBE} ──"
# `helm test --filter` exits 0 when the filter matches NOTHING (no test runs) —
# a silent false-pass. So success requires BOTH a zero exit AND the probe's own
# marker in the logs; either one missing is a hard failure.
LOG="$(mktemp)"
if ! helm test "$NS" --namespace "$NS" --filter "name=${PROBE}" --logs >"$LOG" 2>&1; then
  cat "$LOG"
  fail "helm test reported failure for ${PROBE} — egress lockdown NOT verified"
fi
cat "$LOG"
grep -q "OK  egress lockdown verified" "$LOG" ||
  fail "no egress-enforcement success marker in helm-test logs — did --filter match the probe? (guards the filter-silent-pass trap)"

echo "PASS: live seal-check — egress-enforcement probe fired and verified the lockdown."
