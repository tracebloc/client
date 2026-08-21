#!/usr/bin/env bash
#
#  node-agents-namespace-safety.sh — nothing lands in the node-agents namespace
#  unless the chart also creates it (backend#1906, backend#2274).
#
#  WHY THIS EXISTS. #779's first Bugbot finding was a DaemonSet targeting a
#  namespace the chart never created: `telemetryCollector.enabled: true` with
#  `resourceMonitor: false` produced pods with nowhere to go. The fix was a
#  `tracebloc.nodeAgentsInUse` helper and five gates — and the gates are the part
#  that rots, because a NEW template putting something in that namespace has to
#  remember to carry one.
#
#  So this asserts the PROPERTY rather than the gates: for every tenant
#  combination, if any rendered resource declares the node-agents namespace, the
#  Namespace object must render too. A template that forgets its gate fails here
#  without anyone having to notice it was added.
#
#  NO LIST OF TEMPLATES, GATES OR HELPERS. Three hand-maintained lists have gone
#  stale in this area in a week — most recently a comment in
#  telemetry-token-rbac.yaml that named four `nodeAgentsInUse` consumers, included
#  one that does not gate on it and omitted one that does, and was "right" only
#  because the two errors cancelled. Everything here comes out of the render.
#
#  WHY IT DOES NOT CHECK THE GATE EXPRESSION. Two spellings are both correct:
#  `nodeAgentsInUse` (resource-monitor OR the Collector) and a bare
#  `telemetryCollector.enabled`, which IMPLIES the helper and so is not looser.
#  Asserting one spelling would flag correct code; asserting the outcome cannot.
#
#  SCOPED TO `namespace.create: true`, the default. An operator may pre-create the
#  namespace and set `create: false`, and then the chart legitimately populates a
#  namespace it does not render — so that configuration is out of scope here rather
#  than silently mis-asserted.
#
#  FAILS CLOSED. If no configuration puts anything in that namespace, the check
#  proved nothing and says so.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== node-agents namespace safety =="

BASE=(--set clientId=x --set clientPassword=y --set storageClass.create=false
      --set nodeAgents.namespace.create=true)

CMP="$(mktemp -t na-safety.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys, yaml

label = sys.argv[1]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
if not docs:
    sys.exit(f"[ERROR] {label}: rendered nothing")

# The namespace NAME comes out of the render, not from this file: it is
# chart-configurable, and hardcoding it here would be the very thing this guard
# exists to avoid.
target = None
for d in docs:
    ns = d.get("metadata", {}).get("namespace")
    if ns and ns != "tracebloc":
        target = ns
        break
if target is None:
    print(f"   {label:<34} nothing outside the release namespace")
    sys.exit(0)

created = any(d.get("kind") == "Namespace" and d["metadata"]["name"] == target
              for d in docs)
inside = [f"{d['kind']}/{d['metadata']['name']}" for d in docs
          if d.get("metadata", {}).get("namespace") == target]

if inside and not created:
    sys.exit(f"[ERROR] {label}: these render into {target!r} but the chart does "
             f"not create it: {sorted(inside)} — their pods and bindings target a "
             "namespace that will not exist. Gate them on "
             "`tracebloc.nodeAgentsInUse` (or on a condition that implies it).")

print(f"   {label:<34} ns={'created' if created else 'absent  '}  "
      f"resources={len(inside)}")
PY

populated=0
for combo in "true true" "true false" "false true" "false false"; do
  set -- $combo
  rm_val="$1"; tc_val="$2"
  label="resourceMonitor=$rm_val tc=$tc_val"
  out="$(helm template t "$CHART" "${BASE[@]}" \
    --set "resourceMonitor=$rm_val" \
    --set "telemetryCollector.enabled=$tc_val" 2>/dev/null)" || {
      echo "[ERROR] $label: the chart failed to render" >&2; exit 1; }
  printed="$(printf '%s' "$out" | python3 "$CMP" "$label")"
  echo "$printed"
  case "$printed" in *"resources="[1-9]*) populated=$((populated + 1)) ;; esac
done

# An inert chart in every combination would satisfy the implication vacuously.
if [ "$populated" -eq 0 ]; then
  echo "[ERROR] no tenant combination put anything in the node-agents namespace —" >&2
  echo "        the implication held only because there was nothing to check" >&2
  exit 2
fi

echo "  ok: every populated combination also creates the namespace ($populated of 4)"
echo "node-agents namespace safety: green"
