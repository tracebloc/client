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

# Isolated cluster + release so we never touch a real 'tracebloc' install, and
# opt out of autostart so create_cluster never reconfigures the host's Docker
# restart policy / runs `systemctl enable docker` (matches the sibling e2e-*.sh).
export CLUSTER_NAME="${CLUSTER_NAME:-tbseal}"
export TRACEBLOC_NO_AUTOSTART=1
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

# Guard the silent-pass trap FIRST: `helm test --filter` exits 0 when the filter
# matches NOTHING (no test runs). So confirm the probe hook is actually in the
# release before testing — a renamed/ungated probe fails here, loudly, instead
# of passing vacuously.
echo "── verify the probe hook is in the release ──"
helm get hooks "$NS" --namespace "$NS" | grep -q "name: ${PROBE}" ||
  fail "probe hook ${PROBE} not found in release hooks — --filter would match nothing"

echo "── helm test --filter name=${PROBE} ──"
# Drive off the EXIT CODE, not --logs. The probe Job exits 0 ONLY when egress is
# verified blocked, so a passing `helm test` == the lockdown is enforced. --logs
# is unreliable for a Job-type hook: it looks up the pod by the Job's bare name
# (the pod carries a generated suffix → "pods not found"), and hook-succeeded
# deletes the Job on success anyway. On FAILURE the Job persists, so dump its
# pod log for triage.
if ! helm test "$NS" --namespace "$NS" --filter "name=${PROBE}" --timeout 360s; then
  echo "── probe pod log (Job persists on failure) ──"
  kubectl logs -n "$NS" -l "job-name=${PROBE}" --tail=-1 2>/dev/null ||
    kubectl describe job -n "$NS" "${PROBE}" 2>/dev/null || true
  fail "helm test reported failure for ${PROBE} — egress lockdown NOT verified"
fi

echo "PASS: live seal-check — egress-enforcement probe passed; the CNI enforced the egress lockdown."
