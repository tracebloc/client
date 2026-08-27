#!/usr/bin/env bash
#
#  telemetry-token-migration.sh — an edge already collecting under the LEGACY fixed
#  Secret name upgrades WITHOUT the daemonset's pre-flight `fail` tripping
#  (backend#2625, acceptance b — "the acceptance line that matters").
#
#  WHY THIS ONE NEEDS A CLUSTER, AND NO OTHER TELEMETRY CHECK DOES. The pre-flight is
#  a `lookup`-backed `fail`: it asks the API server whether the token Secret exists,
#  and `lookup` returns empty under `helm template`. So every offline check renders
#  with the guard inert and can never watch it fire — telemetry_collector_test.yaml
#  says exactly this ("the `lookup`-based `fail` is inherently un-pinnable here").
#  The property that matters — that the guard ACCEPTS the legacy name, so renaming to
#  a release-scoped Secret does not wedge the one edge already collecting (the
#  backend#2400 deadlock in a new costume) — is therefore only observable against a
#  live cluster, via `helm install --dry-run=server`, which performs the lookups.
#
#  SELF-SKIPS with no reachable cluster, the same way the offline checks skip with no
#  helm. It runs wherever a cluster exists: an e2e leg, or a reviewer with k3d.
#
#  THREE CASES, because "accepts legacy" only means something beside "still refuses
#  when nothing exists":
#    * no Secret at all           -> the guard FAILS  (the pre-flight still bites)
#    * only the legacy fixed name -> the guard PASSES  (acceptance b)
#    * only the release-scoped    -> the guard PASSES  (the post-migration steady state)
#
#  DERIVED WHERE IT CAN BE. The release-scoped name is read out of the chart's own
#  render, not reconstructed here. The LEGACY name is the one literal, and rightly:
#  it is a fixed historical constant this check exists to exercise — the subject of
#  the test, like a canary, not a value that drifts.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client
LEGACY_NAME="tracebloc-telemetry-token"   # the pre-backend#2625 fixed name; the subject here
REL="tok-mig-$$"                           # unique; never asserted on
REL_NS="tok-mig-rel-$$"
# FULLY ISOLATED node-agents namespace, so this is safe to run alongside a live
# release (e.g. from within e2e-auto-upgrade.sh): `--set nodeAgents.namespace.name`
# points the guard's lookup at a namespace this check owns and reaps, never the real
# `tracebloc-node-agents`; `create=false` keeps the chart from trying to own it.
TOKEN_NS="tok-mig-na-$$"

command -v helm    >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v kubectl >/dev/null 2>&1 || { echo "[SKIP] kubectl not installed"; exit 0; }
kubectl cluster-info >/dev/null 2>&1 \
  || { echo "[SKIP] no reachable cluster — the pre-flight lookup needs one"; exit 0; }

echo "== telemetry token migration (live) =="

# The isolated-namespace values every render below shares. The guard looks its Secret
# up in nodeAgents.namespace.name, so pointing that at $TOKEN_NS scopes the whole
# check to a namespace this file created.
NA=(--set "nodeAgents.namespace.name=$TOKEN_NS" --set nodeAgents.namespace.create=false)

# The release-scoped name the chart resolves to for $REL — read out of the chart's
# OWN render, so this file restates no name pattern. Read from the token RBAC's
# resourceNames with the Collector OFF: that template renders unconditionally
# (backend#2400) and, with the DaemonSet unrendered, the `lookup`-backed pre-flight
# is never evaluated — so this name read needs no cluster and cannot itself trip the
# guard, whatever a given helm does with `lookup` under `template`. Grep, not a YAML
# parser: the e2e runner is not guaranteed PyYAML, and a hard dependency would turn a
# missing library into a spurious acceptance-(b) failure.
SCOPED_NAME="$(helm template "$REL" "$CHART" \
  --set clientId=x --set clientPassword=y --set storageClass.create=false \
  --show-only templates/telemetry-token-rbac.yaml 2>/dev/null \
  | awk '/resourceNames:/ {gsub(/[]["]/, "", $2); print $2; exit}')"
[ -n "$SCOPED_NAME" ] \
  || { echo "[ERROR] could not read the token name out of the render" >&2; exit 1; }
[ "$SCOPED_NAME" != "$LEGACY_NAME" ] \
  || { echo "[ERROR] the release-scoped name equals the legacy name for $REL — pick a different release" >&2; exit 1; }

cleanup() {
  kubectl delete ns "$TOKEN_NS" "$REL_NS" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create ns "$TOKEN_NS" >/dev/null
kubectl create ns "$REL_NS"   >/dev/null

# The pre-flight is a TEMPLATE-TIME `fail`, so its own message — not helm's overall
# exit — is the verdict. `--dry-run=server` renders server-side (so `lookup` runs)
# and may then trip on live-cluster checks that have nothing to do with the token (an
# unowned namespace, a missing metrics API), which would misread as the guard firing
# if we only watched the exit code. So watch for the guard's words. `resourceMonitor`
# is off so its own metrics-API `fail` cannot pre-empt the render before this one.
GUARD_SIG='token Secret does not exist'   # the guard's own message; the subject here
guard_refused() {   # 0 = the telemetry pre-flight refused the render; 1 = it did not
  # Captured to a variable, not piped: under `pipefail` a failing `helm` (dry-run
  # trips on unrelated live checks routinely) would mask `grep`'s answer.
  local out
  out="$(helm install "$REL" "$CHART" --dry-run=server -n "$REL_NS" "${NA[@]}" \
    --set clientId=x --set clientPassword=y --set storageClass.create=false \
    --set resourceMonitor=false --set telemetryCollector.enabled=true 2>&1 || true)"
  printf '%s\n' "$out" | grep -q "$GUARD_SIG"
}

put()  { kubectl create secret generic "$1" -n "$TOKEN_NS" --from-literal=token=x >/dev/null; }
drop() { kubectl delete secret "$1" -n "$TOKEN_NS" --ignore-not-found >/dev/null 2>&1 || true; }

fail=0

# 1. no Secret -> the pre-flight must still bite.
if guard_refused; then
  echo "   no Secret            -> refused (pre-flight still bites)"
else
  echo "[ERROR] the pre-flight did NOT refuse with no token Secret present — the guard is inert, so the two cases below prove nothing" >&2
  fail=1
fi

# 2. only the LEGACY fixed name -> the guard must accept it (acceptance b).
put "$LEGACY_NAME"
if guard_refused; then
  echo "[ERROR] the pre-flight REFUSED with only the legacy Secret $LEGACY_NAME present — this is the wedge backend#2625 exists to avoid" >&2
  fail=1
else
  echo "   legacy $LEGACY_NAME -> accepted (acceptance b: the upgrade is not wedged)"
fi
drop "$LEGACY_NAME"

# 3. only the RELEASE-SCOPED name -> the guard must accept it (steady state).
put "$SCOPED_NAME"
if guard_refused; then
  echo "[ERROR] the pre-flight REFUSED with the release-scoped Secret $SCOPED_NAME present — the name the writer/reader/RBAC all use" >&2
  fail=1
else
  echo "   scoped $SCOPED_NAME -> accepted (post-migration steady state)"
fi
drop "$SCOPED_NAME"

[ "$fail" -eq 0 ] || { echo "telemetry token migration: FAILED" >&2; exit 1; }
echo "telemetry token migration: green"
