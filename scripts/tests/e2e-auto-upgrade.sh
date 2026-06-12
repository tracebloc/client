#!/usr/bin/env bash
# =============================================================================
#  e2e-auto-upgrade.sh — fleet auto-upgrade non-regression gate
# -----------------------------------------------------------------------------
#  The fleet self-upgrades hourly via auto-upgrade-cronjob.yaml:
#      helm upgrade <rel> tracebloc/client --version <latest> --reset-then-reuse-values
#  and operators habitually run `helm upgrade --reuse-values` by hand. Both
#  replay OLD stored values against the NEW chart — the failure mode that has
#  repeatedly bitten this chart (nil-pointer templating on keys the stored
#  values predate; see requests_proxy_test.yaml / resource_monitor_test.yaml).
#
#  This gate installs the LAST PUBLISHED chart from gh-pages on a real k3d
#  cluster, then upgrades to the LOCAL working-tree chart through both flag
#  paths and asserts the contract that keeps the fleet safe:
#    1. `--reuse-values`            -> upgrade succeeds (nil-guards hold) and the
#                                      egress lockdown does NOT engage by accident.
#    2. `--reset-then-reuse-values` -> upgrade succeeds, new defaults flow in
#                                      (egress gateway deploys, inert), and
#                                      out-of-band image-refresh annotations survive.
#    3. flip the #102 lockdown flags -> rule 2 drops, jobs-manager routes pods
#                                      at the gateway.
#    4. the next plain auto-upgrade  -> the operator's flip PERSISTS.
#
#  Pods are NEVER waited on: the published images need real credentials to go
#  healthy, and the regression class this guards lives entirely in Helm
#  templating / values semantics. No secrets; stock GitHub runners.
#
#  Usage:  bash scripts/tests/e2e-auto-upgrade.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
CHART_DIR="$HERE/../../client"

# Isolated cluster + release so we never touch a real 'tracebloc' install; opt
# out of autostart so we don't reconfigure docker.service on the host.
export USER="${USER:-$(id -un)}"
export CLUSTER_NAME="${CLUSTER_NAME:-tbupg}"
export TRACEBLOC_NO_AUTOSTART=1
NS="tbupg"
REPO_NAME="tracebloc"
REPO_URL="https://tracebloc.github.io/client"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh"   # provides _pf_recheck_runtime_mem (called by create_cluster)

cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- assertion helpers (read live cluster state, not helm output) -----------
netpol_has_external_443() {
  kubectl get networkpolicy "${NS}-training-egress" -n "$NS" -o yaml \
    | grep -q 'cidr: 0.0.0.0/0'
}

jm_deploy() {
  kubectl get deploy -n "$NS" -o name | grep -m1 'jobs-manager'
}

jm_egress_proxy_url() {
  kubectl get -n "$NS" "$(jm_deploy)" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EGRESS_PROXY_URL")].value}'
}

echo "═══════════════════════════════════════════════════════════════════════"
echo "  E2E auto-upgrade gate   arch: $(uname -m)   kernel: $(uname -r)"
echo "═══════════════════════════════════════════════════════════════════════"

has docker || error "Docker is not available on this host."
umask 022
install_kubectl
install_k3d
install_helm

echo "── create_cluster() — the installer's real cluster-bring-up path ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "── install the LAST PUBLISHED chart (what the fleet runs today) ──"
helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null
helm repo update >/dev/null
# Same idiom the auto-upgrade cronjob uses to pick the newest version.
PREV="$(helm search repo "${REPO_NAME}/client" -o yaml \
  | awk '/^[[:space:]]*version:/ {print $2; exit}')"
[ -n "$PREV" ] || fail "could not resolve the latest published chart version from $REPO_URL"
LOCAL_VERSION="$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")"
echo "   published: $PREV   local working tree: $LOCAL_VERSION"

helm install "$NS" "${REPO_NAME}/client" --version "$PREV" \
  --namespace "$NS" --create-namespace \
  --set clientId=ci-e2e-upgrade \
  --set clientPassword=ci-e2e-upgrade \
  --set storageClass.provisioner=rancher.io/local-path

echo "── simulate an image-refresh-managed annotation (must survive upgrades) ──"
kubectl annotate -n "$NS" "$(jm_deploy)" \
  "tracebloc.io/last-refreshed-jobs-manager-digest=sha256:e2e-sentinel" --overwrite

echo "── path 1: manual-operator habit — helm upgrade --reuse-values ──"
# Old stored values replayed against the new chart: every new key is absent.
# The nil-guards must hold, and the lockdown must NOT engage by accident.
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reuse-values
netpol_has_external_443 || fail "--reuse-values upgrade dropped the external 443 rule (lockdown engaged by accident)"
[ -z "$(jm_egress_proxy_url)" ] || fail "--reuse-values upgrade injected EGRESS_PROXY_URL (routing engaged by accident)"
echo "   OK: upgrade succeeded, lockdown stayed off"

echo "── path 2: the fleet auto-upgrade — helm upgrade --reset-then-reuse-values ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values
netpol_has_external_443 || fail "auto-upgrade dropped the external 443 rule (allowExternalHttps default did not flow)"
[ -z "$(jm_egress_proxy_url)" ] || fail "auto-upgrade injected EGRESS_PROXY_URL (routeWorkloads should default false)"
kubectl get deploy "${NS}-egress-proxy" -n "$NS" >/dev/null \
  || fail "auto-upgrade did not deploy the egress gateway (new defaults did not flow)"
ANNOT="$(kubectl get -n "$NS" "$(jm_deploy)" \
  -o jsonpath='{.metadata.annotations.tracebloc\.io/last-refreshed-jobs-manager-digest}')"
[ "$ANNOT" = "sha256:e2e-sentinel" ] || fail "image-refresh annotation was clobbered by the upgrade"
DEPLOYED="$(helm list -n "$NS" --filter "^${NS}\$" -o yaml \
  | awk '/^[[:space:]]*chart:/ {print $2; exit}')"
[ "$DEPLOYED" = "client-${LOCAL_VERSION}" ] || fail "deployed chart is $DEPLOYED, expected client-${LOCAL_VERSION}"
echo "   OK: new defaults flowed in (gateway deployed, inert), annotations survived"

echo "── path 3: operator flips the #102 lockdown ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values \
  --set egressProxy.routeWorkloads=true \
  --set networkPolicy.training.allowExternalHttps=false
netpol_has_external_443 && fail "lockdown flip did NOT drop the external 443 rule"
[ "$(jm_egress_proxy_url)" = "http://egress-proxy-service:3128" ] \
  || fail "lockdown flip did not point jobs-manager at the egress gateway"
echo "   OK: rule 2 dropped, training pods route via the gateway"

echo "── path 4: the NEXT hourly auto-upgrade must preserve the flip ──"
helm upgrade "$NS" "$CHART_DIR" --namespace "$NS" --reset-then-reuse-values
netpol_has_external_443 && fail "auto-upgrade after the flip re-opened the external 443 rule (override lost)"
[ "$(jm_egress_proxy_url)" = "http://egress-proxy-service:3128" ] \
  || fail "auto-upgrade after the flip lost EGRESS_PROXY_URL (override lost)"
echo "   OK: the operator's lockdown persists across auto-upgrades"

echo ""
echo "E2E PASS: ${PREV} -> ${LOCAL_VERSION} upgrades safe on both flag paths; #102 flip engages and persists."
