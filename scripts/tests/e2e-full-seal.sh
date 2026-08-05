#!/usr/bin/env bash
# =============================================================================
#  e2e-full-seal.sh — the FULL seal suite vs the dev backend (backend#1184 residual)
# -----------------------------------------------------------------------------
#  e2e-seal-check.sh proves the egress-enforcement probe alone — deliberately
#  the one check that needs zero secrets. This script closes the deferred
#  fast-follow recorded when backend#1184 closed: run the WHOLE conformance
#  suite — egress-enforcement + backend-reachability + bound-PVC
#  storage-assertions — on a real k3d cluster installed with the dev-env
#  e2e-test-agent's REAL credentials, so every `helm.sh/hook: test` seal-check
#  in the chart is exercised live, not just the secret-free one.
#
#  Why real credentials change what is verifiable:
#    • backend-reachability round-trips to the real dev API from a non-training
#      pod (the required-egress complement of the enforcement probe).
#    • jobs-manager genuinely authenticates, consumers start, and the release
#      PVCs BIND — so storage-assertions verifies bound storage on the expected
#      class instead of failing on Pending WaitForFirstConsumer claims.
#
#  Credentials contract (the CI job provides both from repo Actions secrets,
#  and skips green with a notice when they are absent):
#    TB_E2E_CLIENT_ID / TB_E2E_CLIENT_PASSWORD — a DEDICATED dev-platform test
#    client ("e2e-test-agent"), never a real customer identity. jobs-manager
#    authenticates against the dev backend as this client for the lifetime of
#    the run; the cluster is deleted on exit either way.
#
#  Usage:
#    TB_E2E_CLIENT_ID=… TB_E2E_CLIENT_PASSWORD=… bash scripts/tests/e2e-full-seal.sh
# =============================================================================
set -euo pipefail

[ -n "${TB_E2E_CLIENT_ID:-}" ] && [ -n "${TB_E2E_CLIENT_PASSWORD:-}" ] || {
  echo "TB_E2E_CLIENT_ID / TB_E2E_CLIENT_PASSWORD are required (dev e2e-test-agent" >&2
  echo "credentials; the CI job skips with a notice instead when they are absent)." >&2
  exit 2
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
CHART_DIR="$HERE/../../client"

# Shared bring-up contract (isolation env + tool-install prereqs) + the shared
# egress positive control, same as the sibling e2e-*.sh.
# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbfullseal
# NS follows CLUSTER_NAME so a CLUSTER_NAME override isolates a whole run under
# ONE name — cluster + release + namespace move together (same as the sibling).
NS="$CLUSTER_NAME"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh" # provides _pf_recheck_runtime_mem (called by create_cluster)

# The credentials travel in a mode-0600 values file, never on argv (a shared
# runner's process list is world-readable, and helm --set mangles commas/
# braces a password may contain) — same stance as the installer's generated
# values.yaml. Removed on every exit path together with the cluster.
CREDS_FILE=""
cleanup() {
  [ -n "$CREDS_FILE" ] && rm -f "$CREDS_FILE"
  k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

e2e_install_prereqs

echo "── create_cluster() — real k3d bring-up ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# The probe host — pinned on the install so the enforcement probe and the
# positive control can never target different hosts (same stance as the
# sibling, from the Saqlain nit on #541).
HOST=1.1.1.1

echo "── helm install (dev backend, REAL credentials, lockdown ENGAGED — full suite renders) ──"
# Same base profile as e2e-seal-check.sh (local working-tree chart, public
# images, local-path storage, lockdown on with the 240s probe budget), plus the
# real credentials and CLIENT_ENV=dev: the backend the reachability check must
# round-trip to, and the login that makes the release come up for real.
# Single-quoted YAML scalars with the standard '' escape, matching the
# installer's _yaml_sq_escape treatment of the same two values.
# pvcAccessMode=ReadWriteOnce: the chart's PVC default is ReadWriteMany, which
# local-path never provisions — claims would sit Pending forever and both the
# Bound pre-wait and storage-assertions would fail (Bugbot). The installer
# writes exactly this value for the same storage path.
_sq() { printf %s "$1" | sed "s/'/''/g"; }
CREDS_FILE="$(mktemp)"
chmod 600 "$CREDS_FILE"
{
  printf "clientId: '%s'\n" "$(_sq "$TB_E2E_CLIENT_ID")"
  printf "clientPassword: '%s'\n" "$(_sq "$TB_E2E_CLIENT_PASSWORD")"
} > "$CREDS_FILE"
helm install "$NS" "$CHART_DIR" --namespace "$NS" --create-namespace \
  -f "$CHART_DIR/tests/values-public-images.yaml" \
  -f "$CREDS_FILE" \
  --set env.CLIENT_ENV=dev \
  --set storageClass.provisioner=rancher.io/local-path \
  --set pvcAccessMode=ReadWriteOnce \
  --set networkPolicy.training.allowExternalHttps=false \
  --set networkPolicy.training.enforcementProbeHost="$HOST" \
  --set networkPolicy.training.enforcementProbeTimeoutSeconds=240

echo "── wait: every release PVC Bound (storage-assertions' precondition, asserted crisply first) ──"
# storage-assertions itself waits sealCheck.storageAssertions.timeoutSeconds
# (120s default) — pre-asserting here with a longer budget separates "the
# cluster was slow to bind" from "the assertions are wrong", and names the
# offending claim in the failure instead of a generic helm-test error.
total=0
deadline=$(( $(date +%s) + 300 ))
while :; do
  # One guarded fetch per iteration: a transient kubectl failure yields an
  # empty snapshot (total=0, keep waiting) instead of aborting the script
  # under set -euo pipefail mid-wait (Bugbot).
  pvcs="$(kubectl --request-timeout=10s get pvc -n "$NS" --no-headers 2>/dev/null || true)"
  unbound="$(awk '$2 != "Bound" {print $1" ("$2")"}' <<<"$pvcs")"
  total="$(grep -c . <<<"$pvcs" || true)"
  [ "$total" -gt 0 ] && [ -z "$unbound" ] && break
  [ "$(date +%s)" -ge "$deadline" ] &&
    fail "release PVCs not all Bound after 300s (total=${total}): ${unbound:-none listed} — storage-assertions would fail; failing here with the crisper reason."
  sleep 5
done
echo "all ${total} release PVCs Bound"

echo "── wait: the deployments that hold the real backend session ──"
kubectl -n "$NS" rollout status deploy/mysql-client --timeout=300s
kubectl -n "$NS" rollout status "deploy/${NS}-jobs-manager" --timeout=300s

e2e_egress_positive_control "$HOST"

# Guard the silent-pass trap for the FULL suite: assert every expected hook is
# in the release BEFORE `helm test`. The sibling guards its single --filter for
# the same reason — and an UNFILTERED helm test equally "passes" a release
# whose hooks silently stopped rendering (a regated check just vanishes from
# the run). The three names below are pinned by the helm-unittest suites.
echo "── verify all three seal-check hooks are in the release ──"
hooks="$(helm get hooks "$NS" --namespace "$NS")"
for check in egress-enforcement-check egress-reachability-check storage-assertions-check; do
  grep -q "name: ${NS}-${check}" <<<"$hooks" ||
    fail "expected hook ${NS}-${check} not found in the release — the full suite would run incomplete"
done

echo "── helm test (unfiltered — the whole seal suite) ──"
# Drive off the EXIT CODE, not --logs (same rationale as the sibling: hook pods
# carry generated suffixes and hook-succeeded deletes passing Jobs). On failure
# the failed Jobs persist — dump every seal-check pod log via the enumeration
# label contract (RFC-0003 §8.2) for triage.
if ! helm test "$NS" --namespace "$NS" --timeout 600s; then
  echo "── seal-check job logs (failed hooks persist) ──"
  kubectl --request-timeout=10s logs -n "$NS" -l "tracebloc.io/seal-check=true" --tail=-1 --prefix 2>/dev/null || true
  kubectl --request-timeout=10s get jobs -n "$NS" 2>/dev/null || true
  fail "helm test reported failure — the full seal suite did NOT pass against the dev backend"
fi

echo "PASS: full seal suite — egress-enforcement + backend-reachability + storage-assertions all green vs the dev backend."
