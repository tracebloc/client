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

# Shared bring-up contract (isolation env + tool-install prereqs), same as the
# sibling e2e-*.sh.
# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbseal
# NS follows CLUSTER_NAME so a CLUSTER_NAME override isolates a whole run under
# ONE name — cluster + release + namespace move together (Saqlain review).
NS="$CLUSTER_NAME"

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

# Tool prerequisites — shared with the sibling e2e-*.sh via e2e-common.sh
# (docker check + umask + install_{kubectl,k3d,helm}).
e2e_install_prereqs

echo "── create_cluster() — real k3d bring-up (k3s enforces egress NetworkPolicy) ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s
# Node-Ready is only a proxy: k3s registers the metrics.k8s.io APIService that the
# resource-monitor preflight looks up AFTER nodes go Ready, so a fast runner can
# helm-install into the gap and the preflight false-fails the release (client#863).
# Wait for the real precondition before installing. Contract + rationale in the helper.
e2e_wait_for_metrics_apiservice

# The probe host — the SINGLE source shared by the enforcement probe and the
# positive control below. Pin it explicitly on the install (rather than leaning
# on the chart default) so the two can never target different hosts (Saqlain
# nit on #541).
HOST=1.1.1.1

echo "── helm install (public images, egress lockdown ENGAGED) ──"
# Local working-tree chart, public images (no registry secret), local-path
# storage, and allowExternalHttps=false so the training-egress NetworkPolicy is
# rendered and the egress-enforcement-check Job renders (gated on the lockdown
# flag + a non-empty enforcementProbeHost, pinned to $HOST below).
# enforcementProbeTimeoutSeconds is bumped from the 60s chart default to 240s:
# on a cold GHA runner k3s's kube-router can take >60s to program the pod's
# iptables while the chart is still installing, and the probe is single-shot
# (backoffLimit 0) — 240s is well inside the 360s helm-test budget so a slow
# reconcile no longer false-fails on a cluster that DOES enforce (Saqlain review).
helm install "$NS" "$CHART_DIR" --namespace "$NS" --create-namespace \
  -f "$CHART_DIR/tests/values-public-images.yaml" \
  --set clientId=ci-e2e-seal \
  --set clientPassword=ci-e2e-seal \
  --set storageClass.provisioner=rancher.io/local-path \
  --set networkPolicy.training.allowExternalHttps=false \
  --set networkPolicy.training.enforcementProbeHost="$HOST" \
  --set networkPolicy.training.enforcementProbeTimeoutSeconds=240

# Positive control — factored into scripts/tests/lib/e2e-common.sh verbatim
# (shared with e2e-full-seal.sh); rationale + #541 review provenance live there.
e2e_egress_positive_control "$HOST"

# The one probe we exercise. Its Job is `<release>-egress-enforcement-check`
# (templates/egress-enforcement-check.yaml). The helm-unittest suite pins this
# exact name so the --filter below can never silently drift off it.
PROBE="${NS}-egress-enforcement-check"

# Guard the silent-pass trap FIRST: `helm test --filter` exits 0 when the filter
# matches NOTHING (no test runs). So confirm the probe hook is actually in the
# release before testing — a renamed/ungated probe fails here, loudly, instead
# of passing vacuously.
echo "── verify the probe hook is in the release ──"
# Capture first, then grep a here-string — piping `helm get hooks | grep -q`
# lets grep close the pipe on its first match, which SIGPIPEs helm mid-write and
# (under `set -o pipefail`) false-fails this guard even though the hook exists.
hooks="$(helm get hooks "$NS" --namespace "$NS")"
grep -q "name: ${PROBE}" <<<"$hooks" ||
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
  kubectl --request-timeout=10s logs -n "$NS" -l "job-name=${PROBE}" --tail=-1 2>/dev/null ||
    kubectl --request-timeout=10s describe job -n "$NS" "${PROBE}" 2>/dev/null || true
  fail "helm test reported failure for ${PROBE} — egress lockdown NOT verified"
fi

echo "PASS: live seal-check — egress-enforcement probe passed; the CNI enforced the egress lockdown."
