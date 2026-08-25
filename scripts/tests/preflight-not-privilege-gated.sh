#!/usr/bin/env bash
# The metrics-server preflight must not require cluster-scope RBAC to RENDER.
#
# client#2469. `lookup` has three outcomes, not two: it sees the cluster, it
# returns empty (offline), or it RAISES on forbidden -- and helm cannot catch the
# third. `APIService` is cluster-scoped and Kubernetes' built-in `admin`
# ClusterRole excludes it, so an unconditional lookup meant a namespace admin
# could not `helm upgrade` this chart AT ALL -- the whole release, not just this
# DaemonSet -- with an error that blamed metrics-server.
#
# WHY A SOURCE CHECK AND NOT A CHART TEST. helm-unittest renders offline, where
# every `lookup` returns empty, so it never reaches the privileged call and cannot
# tell a guarded lookup from an unguarded one. Mutation-proved: disabling the guard
# leaves all 566 chart tests green. The ordering is only observable in the template
# text, which is what this parses.
#
# FAILS CLOSED: a missing file, or a guard shape it cannot recognise, is an ERROR.
# "Could not tell" is a finding, not a pass.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
tpl="$repo_root/client/templates/resource-monitor-daemonset.yaml"

fail() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "$tpl" ] || fail "$tpl is missing -- cannot check, which is a finding"

echo "== preflight is not privilege-gated =="

priv_line="$(grep -n 'lookup "apiregistration.k8s.io/v1" "APIService"' "$tpl" | head -1 | cut -d: -f1 || true)"
[ -n "$priv_line" ] || fail \
"no APIService lookup found in $(basename "$tpl"). Either the preflight was removed -- then delete this check too, deliberately -- or it changed shape and this check can no longer see it. Not knowing is a finding."

cheap_line="$(grep -n 'lookup "apps/v1" "Deployment" "kube-system" "metrics-server"' "$tpl" | head -1 | cut -d: -f1 || true)"
[ -n "$cheap_line" ] || fail \
"the APIService lookup at line $priv_line is not preceded by a metrics-server Deployment probe. A caller with only namespace-scoped admin cannot read APIServices, so helm RAISES and the entire upgrade dies. Probe something the caller can read first (client#2469)."

if [ "$cheap_line" -ge "$priv_line" ]; then
  fail "the metrics-server Deployment probe (line $cheap_line) must come BEFORE the APIService lookup (line $priv_line), or the privileged call is still reached first and the ordering buys nothing."
fi

grep -q 'metricsServerPreflight' "$tpl" || fail \
"no nodeAgents.metricsServerPreflight opt-out in $(basename "$tpl"). Without it, a caller who can neither read APIServices nor match the Deployment probe cannot render the chart at all."

grep -q 'tracebloc.io/metrics-server-preflight' "$tpl" || fail \
"the render does not record which preflight path decided. A skip indistinguishable from a pass is the failure this check exists to prevent."

echo "  ok: metrics-server Deployment probe (line $cheap_line) precedes the APIService lookup (line $priv_line)"
echo "  ok: nodeAgents.metricsServerPreflight opt-out present"
echo "  ok: the deciding path is recorded on the object"
echo "preflight not privilege-gated: green"
