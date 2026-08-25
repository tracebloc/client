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

# Capture-then-slice, not `grep ... | head -1`: piping into an early-closing
# reader under this file's `set -euo pipefail` aborts the guard on SIGPIPE, which
# scripts/tests/pipefail-early-close.bats forbids tree-wide. Same idiom as
# node-jsonpath-agreement.sh.
first_line_of() {
  local all=""
  all="$(grep -n "$1" "$2")" || true
  all="${all%%$'\n'*}"
  printf '%s' "${all%%:*}"
}

priv_line="$(first_line_of 'lookup "apiregistration.k8s.io/v1" "APIService"' "$tpl")"
[ -n "$priv_line" ] || fail \
"no APIService lookup found in $(basename "$tpl"). Either the preflight was removed -- then delete this check too, deliberately -- or it changed shape and this check can no longer see it. Not knowing is a finding."

cheap_line="$(first_line_of 'lookup "apps/v1" "Deployment" "kube-system" "metrics-server"' "$tpl")"
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
# The probe is only cheap if the caller that actually renders on every tick can
# READ it. After the cluster-admin cutover that caller is the auto-upgrade
# ServiceAccount, so a probe outside its scoped role is a 403 -> helm raises ->
# `--atomic` rolls the tick back: a lockout on the UNATTENDED path, strictly worse
# than the human-hits-it-once lockout the probe exists to fix. (@saadqbal, client#823.)
rbac="$repo_root/client/templates/auto-upgrade-rbac.yaml"
[ -f "$rbac" ] || fail "$rbac is missing -- cannot check the caller's reads, which is a finding"

grep -q 'resources: \["deployments"\]' "$rbac" || fail \
"the auto-upgrade scoped role does not grant 'deployments', but the preflight probes a metrics-server Deployment FIRST. Every hourly auto-upgrade tick would 403 on that probe and roll back under --atomic. Grant it in auto-upgrade-rbac.yaml (client#823)."

# ...but NARROWLY. The preflight reads one named object; a cluster-wide
# list/watch on every Deployment reopens the blast radius backend#953 closed.
grep -q 'resourceNames: \["metrics-server"\]' "$rbac" || fail \
"the deployments grant is not restricted with resourceNames: [\"metrics-server\"]. The preflight reads exactly one object, so a cluster-wide Deployment read buys nothing and reopens the workload-read blast radius backend#953 removed (Bugbot on client#823)."

deployments_rule="$(grep -A3 'resources: \["deployments"\]' "$rbac")" || true
if grep -qE 'verbs:.*"(list|watch)"' <<<"$deployments_rule"; then
  fail "the deployments grant includes list or watch. resourceNames does not restrict collection verbs -- Kubernetes ignores it for list/watch -- so those would grant enumeration of every Deployment in the cluster. A named get is all the preflight needs."
fi

grep -q 'resources: \["apiservices"\]' "$rbac" || fail \
"the auto-upgrade scoped role does not grant 'apiservices', so the preflight's authoritative fallback would 403 on any cluster where the Deployment probe finds nothing (backend#953)."

echo "  ok: the deciding path is recorded on the object"
echo "  ok: the auto-upgrade role grants BOTH reads the preflight can make"
echo "preflight not privilege-gated: green"
