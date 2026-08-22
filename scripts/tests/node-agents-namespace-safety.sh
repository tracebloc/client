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
#
#  AND IT NO LONGER PRESCRIBES A FIX. The first version's message said "gate them
#  on `tracebloc.nodeAgentsInUse`", which — while it was mis-firing on the release
#  namespace — advised making the ENTIRE CHART conditional on node agents being in
#  use. A false positive that arrives with confident, specific, harmful advice is
#  worse than one that merely fails, because someone in a hurry can act on it. It
#  now states the property that was violated and names the namespace, and leaves
#  the choice of gate to the reader — there is more than one correct spelling
#  anyway. (@saadqbal, review of #787.)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== node-agents namespace safety =="

# THE RELEASE NAMESPACE IS PINNED, NOT INFERRED — and this is the bug that got
# this guard on its first CI run. `helm template` with no `--namespace` takes the
# namespace from the CALLER'S KUBECONFIG CONTEXT: `tracebloc` on the laptop this
# was written on, `default` on a runner with no kubeconfig. The comparator then
# excluded the literal "tracebloc" to find "the other namespace", so in CI it
# decided the RELEASE namespace was the node-agents one and reported all 35
# release-namespace resources as orphaned.
#
# A guard whose verdict depends on the developer's kube context is worse than no
# guard: it is green where it is written and red where it runs. Pinned here, and
# pinned to a value that is deliberately NOT any real namespace, so a literal
# creeping back in cannot silently match.
RELEASE_NS="ship-guard-release-ns"
BASE=(--namespace "$RELEASE_NS"
      --set clientId=x --set clientPassword=y --set storageClass.create=false
      --set nodeAgents.namespace.create=true)

CMP="$(mktemp -t na-safety.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys, yaml

label, release_ns = sys.argv[1], sys.argv[2]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
if not docs:
    sys.exit(f"[ERROR] {label}: rendered nothing")

# EVERY non-release namespace, as a SET rather than the first match. Two reasons,
# both @saadqbal's: `break` on the first hit lets DOCUMENT ORDER decide which
# namespace gets checked, and a set is honest about there being possibly more than
# one — today there is exactly one, and if a third ever appears it should be
# checked rather than shadowed.
#
# The names come out of the render; only the RELEASE namespace is supplied, and it
# is supplied because it was PINNED on the helm command line rather than inferred.
# The previous version derived the namespace it was thinking about and restated the
# one it was not, which is how it came to demand a `Namespace/default` object.
targets = {d.get("metadata", {}).get("namespace") for d in docs} - {None, release_ns}
if not targets:
    print(f"   {label:<34} nothing outside the release namespace")
    # Still emit the marker: every exit path must, or the caller cannot
    # distinguish "checked nothing" from "the comparator died before printing".
    print("POPULATED=0")
    sys.exit(0)

created = {d["metadata"]["name"] for d in docs if d.get("kind") == "Namespace"}

problems = []
summary = []
for ns in sorted(targets):
    inside = sorted(f"{d['kind']}/{d['metadata']['name']}" for d in docs
                    if d.get("metadata", {}).get("namespace") == ns)
    if inside and ns not in created:
        problems.append(
            f"{len(inside)} resource(s) render into {ns!r} but the chart does not "
            f"create it: {inside} — their pods and bindings target a namespace that "
            "will not exist. Whatever renders them must be gated so it cannot "
            f"render unless {ns!r} does.")
    summary.append(f"{ns}={'created' if ns in created else 'ABSENT'}({len(inside)})")

print(f"   {label:<34} " + "  ".join(summary))
# A MACHINE-READABLE COUNT, not a number scraped back out of the display line. The
# first version's vacuity check grepped `resources=N` from the formatted summary
# and broke the moment the summary was reformatted — a check coupled to a display
# string, which is the same class as everything else this file has caught.
total_inside = sum(1 for d in docs
                   if d.get("metadata", {}).get("namespace") in targets)
print(f"POPULATED={total_inside}")
if problems:
    sys.exit(f"[ERROR] {label}: " + "; ".join(problems))
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
  printed="$(printf '%s' "$out" | python3 "$CMP" "$label" "$RELEASE_NS")"
  # The POPULATED= line is the contract between the two halves; everything else is
  # for humans. Printed separately so reformatting the human part cannot break the
  # vacuity check again.
  printf '%s\n' "$printed" | grep -v '^POPULATED='
  count="$(printf '%s\n' "$printed" | sed -n 's/^POPULATED=//p')"
  [ -n "$count" ] || { echo "[ERROR] $label: the comparator emitted no POPULATED= line; cannot tell whether anything was checked" >&2; exit 2; }
  [ "$count" -gt 0 ] && populated=$((populated + 1))
done

# An inert chart in every combination would satisfy the implication vacuously.
if [ "$populated" -eq 0 ]; then
  echo "[ERROR] no tenant combination put anything in the node-agents namespace —" >&2
  echo "        the implication held only because there was nothing to check" >&2
  exit 2
fi

echo "  ok: every populated combination also creates the namespace ($populated of 4)"
echo "node-agents namespace safety: green"
