#!/usr/bin/env bash
#
#  node-agents-tenancy.sh — the RBAC that MUTATES DaemonSets in the node-agents
#  namespace does not depend on WHICH DaemonSet is there (backend#1906).
#
#  WHY THIS EXISTS. Five templates put something in `nodeAgents.namespace`, and
#  each carried its own copy of the gate "is resource-monitor on". When the edge
#  Collector became a second tenant, two of those gates were widened and the rest
#  were not — so with `resourceMonitor: false` and `telemetryCollector.enabled:
#  true`, the exact configuration the Collector exists to make possible, the
#  namespace was created and the DaemonSet landed while the RBAC that manages it
#  stayed behind. The next `helm upgrade --atomic --wait` would 403 and ROLL BACK
#  (backend#953's failure mode, in its expensive form), and image-refresh would
#  silently stop refreshing pull secrets until an image needed re-pulling.
#
#  Bugbot found one instance. @saadqbal found two more by hand and asked for the
#  gate to be centralised rather than copied a fourth time. A render comparison
#  then found a fourth he had not listed. That progression is the argument for a
#  machine check: three careful readings produced three different counts.
#
#  WHY *MUTATING* VERBS, AND NOT "THE TWO RENDERS MUST MATCH". Two things in that
#  namespace SHOULD differ with resource-monitor off, and a stricter check would
#  have to be wrong about them:
#
#    * `secrets.yaml` mirrors CLIENT_ID/CLIENT_PASSWORD there so the
#      resource-monitor DaemonSet can read them via secretKeyRef. The Collector
#      authenticates with its own telemetry token instead, so widening that gate
#      would copy customer credentials into a namespace for a workload that never
#      reads them — a regression, not a fix.
#    * `rbac.yaml`'s jobs-manager Role grants daemonsets get/list/watch so
#      jobs-manager can read resource-monitor's version for the heartbeat
#      inventory. Nothing asks it for the Collector's version, so it is READ-ONLY
#      and correctly absent. (backend#2274 will need this Role widened when
#      jobs-manager starts writing the Collector's token Secret there — a Secret
#      write, not a daemonset read.)
#
#  So the invariant is narrower and truer: a controller that MUTATES DaemonSets in
#  that namespace must be able to see every DaemonSet in it. Read-only access to a
#  specific workload may come and go with that workload.
#
#  DERIVED IN BOTH DIRECTIONS. No list of templates, Roles, verbs-per-controller
#  or gate spellings lives here. It renders the chart twice, reads the Roles out of
#  each render, and compares. A hand-written expectation would agree with whichever
#  side it was copied from.
#
#  FAILS CLOSED. A render with no DaemonSet in that namespace proves nothing about
#  who may mutate DaemonSets in it, and neither does a render that produced no
#  Roles at all.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== node-agents tenancy =="

# Release namespace PINNED for the same reason as
# node-agents-namespace-safety.sh: with no `--namespace`, helm takes it from the
# caller's kubeconfig, so the "which namespace is the node-agents one" test below
# would depend on the developer's kube context. This guard passed in CI only
# because the chart happens to put no DaemonSet in the release namespace — luck,
# not design.
RELEASE_NS="ship-guard-release-ns"
BASE=(--namespace "$RELEASE_NS"
      --set clientId=x --set clientPassword=y --set storageClass.create=false)

# Two configurations, each of which puts at least one DaemonSet in the namespace.
# The SECOND is the one the Collector exists to enable and the one that was broken.
A="$(mktemp -t na-both.XXXXXX)"; B="$(mktemp -t na-collector-only.XXXXXX)"
CMP="$(mktemp -t na-cmp.XXXXXX)"
trap 'rm -f "$A" "$B" "$CMP"' EXIT

helm template t "$CHART" "${BASE[@]}" \
  --set resourceMonitor=true  --set telemetryCollector.enabled=true >"$A" 2>/dev/null
helm template t "$CHART" "${BASE[@]}" \
  --set resourceMonitor=false --set telemetryCollector.enabled=true >"$B" 2>/dev/null

cat >"$CMP" <<'PY'
import sys, yaml

MUTATING = {"create", "update", "patch", "delete", "deletecollection"}

release_ns = sys.argv[3]


def read(path):
    with open(path) as fh:
        docs = [d for d in yaml.safe_load_all(fh) if d]
    if not docs:
        sys.exit(f"[ERROR] {path} rendered nothing — the comparison would be between "
                 "two empty sets, which compare equal")
    # The namespace is chart-configurable, so it is read out of the render rather
    # than written down: whatever namespace the DaemonSets went to is the subject.
    ns = None
    for d in docs:
        if d.get("kind") == "DaemonSet":
            n = d["metadata"].get("namespace", "")
            if n and n != release_ns:
                ns = n
    if ns is None:
        sys.exit(f"[ERROR] {path} places no DaemonSet outside the release namespace — "
                 "this check cannot say anything about who may mutate DaemonSets there")
    daemonsets = {d["metadata"]["name"] for d in docs
                  if d.get("kind") == "DaemonSet"
                  and d["metadata"].get("namespace") == ns}
    mutators = set()
    for d in docs:
        if d.get("kind") != "Role" or d["metadata"].get("namespace") != ns:
            continue
        for rule in d.get("rules") or []:
            groups = set(rule.get("apiGroups") or [])
            res = set(rule.get("resources") or [])
            verbs = set(rule.get("verbs") or [])
            # WILDCARDS COUNT. The first version of this matched the literals
            # "apps"/"daemonsets"/a mutating verb and therefore missed
            # auto-upgrade's Role — which is `apiGroups: ["*"], resources: ["*"],
            # verbs: ["*"]` and is the very Role Bugbot flagged. A guard that
            # cannot see the finding it was written for is worse than none.
            if (({"apps", "*"} & groups)
                    and ({"daemonsets", "*"} & res)
                    and (verbs & MUTATING or "*" in verbs)):
                mutators.add(d["metadata"]["name"])
    return ns, daemonsets, mutators

ns_a, ds_a, mut_a = read(sys.argv[1])
ns_b, ds_b, mut_b = read(sys.argv[2])

if ns_a != ns_b:
    sys.exit(f"[ERROR] the two renders used different namespaces ({ns_a} vs {ns_b}); "
             "not comparable")
if not mut_a:
    sys.exit("[ERROR] found no Role granting a mutating verb on apps/daemonsets in "
             f"{ns_a} even with every tenant enabled — the parse is inert, so this "
             "check proves nothing")

print(f"   namespace           {ns_a}")
print(f"   both tenants        daemonsets={sorted(ds_a)} mutators={sorted(mut_a)}")
print(f"   collector only      daemonsets={sorted(ds_b)} mutators={sorted(mut_b)}")

missing = sorted(mut_a - mut_b)
if missing:
    sys.exit("[ERROR] with resourceMonitor off and the Collector on, "
             f"{ns_b} still holds {sorted(ds_b)} but these DaemonSet-mutating Roles "
             f"are gone: {missing}. The next `helm upgrade --atomic --wait` 403s and "
             "rolls back, and image refresh stops silently. Whichever gate dropped "
             "them has to cover every tenant of that namespace; there is more than "
             "one correct spelling and this check deliberately does not pick one.")

print(f"  ok: all {len(mut_a)} DaemonSet-mutating Role(s) survive with "
      "resource-monitor off")
PY

python3 "$CMP" "$A" "$B" "$RELEASE_NS"

echo "node-agents tenancy: green"
