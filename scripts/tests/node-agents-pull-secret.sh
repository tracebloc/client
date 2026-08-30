#!/usr/bin/env bash
#
#  node-agents-pull-secret.sh — every DaemonSet in the node-agents namespace can
#  actually pull its image (client#905, Bugbot High).
#
#  WHY THIS EXISTS. `tracebloc.nodeAgentsInUse` gates the pull Secret mirrored
#  into that namespace, and it asked `telemetryCollector.enabled` directly. The
#  tri-state (backend#1906) made that key stop being the answer: in FLEET MODE it
#  is ABSENT and `tracebloc.telemetryCollectorState` still returns `enabled`, so
#  the DaemonSet renders. The gate therefore said "no pod-bearing tenant" about a
#  namespace that was about to receive one — and on an edge with a mirrored
#  registry that is ImagePullBackOff on every node, in the configuration the
#  fleet default exists to create.
#
#  This is the THIRD time this shape has landed. `node-agents-tenancy.sh`'s own
#  header records the first two: "each carried its own copy of 'is
#  resource-monitor on'; when the Collector became a second tenant, two of them
#  were widened and the rest were not." Centralising into one predicate fixed the
#  copies; it did not stop the predicate itself going stale when the vocabulary
#  underneath it grew a third state.
#
#  WHY IT IS A SEPARATE FILE FROM node-agents-tenancy.sh. That one compares
#  MUTATING RBAC between two renders and deliberately says nothing about Secrets
#  — see its own header on why `secrets.yaml` must NOT be widened. The invariant
#  here is about a different resource and would have to be bolted onto a
#  comparison built to ignore it.
#
#  DERIVED FROM THE PRODUCER'S DECLARED SURFACE, not from the case that broke
#  (CLAUDE.md rule 6). `telemetryCollectorState` declares four states in its own
#  docstring; the configurations below are the ways to reach a rendering one, and
#  the assertion is made for each. A test written only against fleet mode would
#  have passed on the attended path it never exercised — and the attended path is
#  what was already correct, which is exactly how a fix gets mistaken for broad
#  coverage.
#
#  FAILS CLOSED. A configuration that renders no DaemonSet in that namespace
#  proves nothing about pulling images there, and is reported as a refusal rather
#  than skipped quietly: the states are read out of the helper's docstring, so a
#  state that stops rendering is a fact about the chart worth failing on.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }
# THE INTERPRETER IS NOT THE LIBRARY (Bugbot Medium; @saqlainsyed007 confirmed it
# against :79 and :147). Both heredocs below `import yaml`, so on a box with
# python3 and no PyYAML this guard died as a bare ModuleNotFoundError traceback
# — which reads as a broken test rather than the stated precondition the two
# checks above it already express.
#
# ONE FILE-LEVEL GATE rather than a try/except in each heredoc: this file embeds
# TWO yaml-importing snippets and will grow more, and a per-snippet guard is a
# copy that one future case forgets. It is also the shape
# scripts/tests/pyyaml-preflight.bats accepts as a whole-file refusal.
python3 -c 'import yaml' 2>/dev/null \
  || { echo "[ERROR] PyYAML required (pip install pyyaml)" >&2; exit 1; }

echo "== node-agents pull Secret =="

# PINNED, for the reason node-agents-namespace-safety.sh gives: with no
# --namespace, helm takes it from the caller's kubeconfig and "is this the
# node-agents namespace" would depend on the developer's kube context.
RELEASE_NS="ship-guard-release-ns"

# A registry that is actually mirrored — the pull Secret's OTHER gate, and the
# reason a first attempt at this check proved nothing: with `dockerRegistry`
# absent the Secret template renders nothing at all, so both sides of a
# before/after comparison were empty and compared equal. The URI is absolute
# because values.schema.json requires it.
BASE=(--namespace "$RELEASE_NS"
      --set clientId=x --set clientPassword=y --set storageClass.create=false
      --set dockerRegistry.create=true
      --set dockerRegistry.server=https://registry.invalid
      --set dockerRegistry.username=u --set dockerRegistry.password=p
      --set dockerRegistry.email=e@registry.invalid)

# Each way to reach a RENDERING Collector, plus the resource-monitor tenant on
# its own. `fleet` is `telemetryCollector.enabled` left ABSENT, which is the
# whole point of the tri-state and the case that broke.
run_case() {  # name, extra --set args...
  local name="$1"; shift
  local out; out="$(mktemp -t na-pull.XXXXXX)"
  if ! helm template t "$CHART" "${BASE[@]}" "$@" >"$out" 2>/dev/null; then
    rm -f "$out"
    echo "[FAIL] $name: the chart did not render, so this case asserts nothing" >&2
    return 1
  fi
  RELEASE_NS="$RELEASE_NS" CASE="$name" python3 - "$out" <<'PY'
import os, sys, yaml

release_ns = os.environ["RELEASE_NS"]
case = os.environ["CASE"]
with open(sys.argv[1]) as fh:
    docs = [d for d in yaml.safe_load_all(fh) if d]

# The namespace is chart-configurable, so it is READ OUT of the render rather
# than written down here: whatever namespace the DaemonSets went to is the
# subject of the assertion.
tenants = {}
for d in docs:
    if d.get("kind") != "DaemonSet":
        continue
    ns = (d["metadata"] or {}).get("namespace") or ""
    if ns and ns != release_ns:
        tenants.setdefault(ns, []).append(d["metadata"]["name"])

if not tenants:
    sys.exit(f"[FAIL] {case}: no DaemonSet outside the release namespace, so this "
             "case cannot say whether its images are pullable. The configuration "
             "was chosen to produce one — if the chart no longer does, that is the "
             "finding.")

for ns, names in sorted(tenants.items()):
    pull = [d["metadata"]["name"] for d in docs
            if d.get("kind") == "Secret"
            and (d["metadata"] or {}).get("namespace") == ns
            and d.get("type") == "kubernetes.io/dockerconfigjson"]
    if not pull:
        sys.exit(f"[FAIL] {case}: {ns} gets DaemonSet(s) {sorted(names)} and NO "
                 "dockerconfigjson Secret. With a mirrored registry every node "
                 "hits ImagePullBackOff (client#905).")
    print(f"  [OK] {case}: {ns} -> {sorted(names)} pull via {sorted(pull)}")
PY
  local rc=$?
  rm -f "$out"
  return $rc
}

fail=0
# Collector reached through the FLEET default: `enabled` absent entirely.
run_case "collector-only, fleet default" --set resourceMonitor=false || fail=1
# Collector reached through an OPERATOR's explicit yes.
run_case "collector-only, attended" \
  --set resourceMonitor=false --set telemetryCollector.enabled=true || fail=1
# Both tenants, so the assertion is not accidentally about "the only DaemonSet".
run_case "both tenants" \
  --set resourceMonitor=true --set telemetryCollector.enabled=true || fail=1
# resource-monitor alone — the original tenant, and the one whose gate was right
# all along. Without it a fix that broke this path would still look green.
run_case "resource-monitor only" \
  --set resourceMonitor=true --set telemetryCollector.enabled=false || fail=1

# AND THE CONVERSE, because "when a DaemonSet renders, the Secret is there" is
# satisfied by a gate that is constantly true -- measured: that mutation went
# UNCAUGHT against the four cases above, since over-rendering is invisible to an
# assertion that only looks for something missing.
#
# Over-rendering is a documented harm, not a tidiness point: the helper's own
# docstring records that widening it to a constant grants auto-upgrade and
# image-refresh DaemonSet rights "in a namespace that has no DaemonSets (4 extra
# RBAC objects)". So with BOTH tenants off there must be no pull Secret there.
no_tenant="$(mktemp -t na-none.XXXXXX)"
if helm template t "$CHART" "${BASE[@]}" \
     --set resourceMonitor=false --set telemetryCollector.enabled=false \
     >"$no_tenant" 2>/dev/null; then
  RELEASE_NS="$RELEASE_NS" python3 - "$no_tenant" <<'NEG' || fail=1
import os, sys, yaml

release_ns = os.environ["RELEASE_NS"]
with open(sys.argv[1]) as fh:
    docs = [d for d in yaml.safe_load_all(fh) if d]

# Namespace names are read from the render rather than written down, so this
# stays correct if the chart's default node-agents namespace is renamed.
ns_names = {(d["metadata"] or {}).get("namespace") for d in docs}
ns_names -= {release_ns, None, ""}

stray = [(d["metadata"].get("namespace"), d["metadata"]["name"]) for d in docs
         if d.get("kind") == "Secret"
         and d.get("type") == "kubernetes.io/dockerconfigjson"
         and (d["metadata"] or {}).get("namespace") in ns_names]
if stray:
    sys.exit("[FAIL] both tenants off: a pull Secret is still mirrored to "
             f"{stray} for a namespace with no DaemonSet. The gate is answering "
             "yes unconditionally, which also grants DaemonSet RBAC where there "
             "are none (see tracebloc.nodeAgentsInUse's docstring).")
print("  [OK] both tenants off: nothing mirrored to a namespace with no DaemonSet")
NEG
else
  echo "[FAIL] both tenants off: the chart did not render" >&2; fail=1
fi
rm -f "$no_tenant"

[ "$fail" -eq 0 ] || { echo "[FAIL] node-agents pull Secret" >&2; exit 1; }
echo "[OK] every node-agents tenant renders with a pull Secret, and only those"
