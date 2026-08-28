#!/usr/bin/env bash
#
#  openshift-scc-coverage.sh — on OpenShift, every hostPath workload the chart
#  deploys is admitted by a chart-managed SCC, under a run-as policy that permits
#  the user the pod actually asks for (backend#1906).
#
#  WHY THIS EXISTS. The chart's SCCs gated on `resourceMonitor` alone and bound
#  only that ServiceAccount. When the edge Collector landed — a second DaemonSet
#  with two hostPath mounts and its own ServiceAccount — nothing granted it an
#  SCC, so on any cluster with `openshift.scc.enabled` its pods would have been
#  refused admission outright. The chart rendered clean, 519 unit tests passed,
#  and no guard in the repo could see it, because the defect is the ABSENCE of a
#  relationship between two documents.
#
#  Bugbot caught it. That is twice on this PR that a cross-document gap got
#  through a green suite (see collector-class-a-agreement.sh) — hence a guard
#  rather than another one-off fix.
#
#  IT CHECKS TWO THINGS, because fixing only the first is a live trap. Adding the
#  Collector's ServiceAccount to resource-monitor's existing SCC would satisfy
#  "is it covered" while still failing at admission: that SCC declares
#  `runAsUser: MustRunAsNonRoot`, and the Collector must run as UID 0 to write
#  its `file_storage` queue to a root-owned hostPath. So coverage is only real if
#  the covering SCC's run-as policy admits the user the pod pins. A guard that
#  checked only membership would have gone green on the wrong fix.
#
#  DERIVED IN BOTH DIRECTIONS, never restated. No list of workloads, ServiceAccounts
#  or SCC names lives here. It renders the chart with OpenShift on, reads the
#  hostPath workloads and their ServiceAccounts out of the render, reads the SCCs
#  and their `users:` out of the same render, and compares. A hand-written
#  expectation would agree with whichever side it was copied from.
#
#  FAILS CLOSED. Zero hostPath workloads or zero SCCs is a finding, not agreement:
#  two empty sets compare equal, and "I could not tell" must never read as green.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== OpenShift SCC coverage =="

render() {
  helm template t "$CHART" \
    --set clientId=x --set clientPassword=y \
    --set storageClass.create=false \
    --set telemetryCollector.enabled=true \
    --set openshift.scc.enabled=true 2>/dev/null
}

# Temp file, not a heredoc on the pipe: `render | python3 - <<'PY'` makes the
# heredoc stdin and silently discards the render (shellcheck SC2259).
CMP="$(mktemp -t openshift-scc-coverage.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

# Side 1: every workload that mounts a hostPath, with its SA and pinned run-as.
workloads = []
for d in docs:
    if d.get("kind") not in ("Deployment", "DaemonSet", "StatefulSet"):
        continue
    spec = d["spec"]["template"]["spec"]
    if not any("hostPath" in v for v in spec.get("volumes") or []):
        continue
    workloads.append({
        "name": d["metadata"]["name"],
        "kind": d.get("kind"),
        "ns": d["metadata"].get("namespace", ""),
        # An unset serviceAccountName means `default`, which no chart SCC binds —
        # so it must read as uncovered, not be silently skipped.
        "sa": spec.get("serviceAccountName") or "default",
        "runAsUser": (spec.get("securityContext") or {}).get("runAsUser"),
    })

# Side 2: the chart-managed SCCs that permit hostPath, and who may use them.
sccs = [d for d in docs if d.get("kind") == "SecurityContextConstraints"]
host_sccs = [s for s in sccs if s.get("allowHostDirVolumePlugin") is True]

if not workloads:
    sys.exit("[ERROR] no hostPath workloads found in the render — the chart did "
             "not render, so this comparison proves nothing")
if not sccs:
    sys.exit("[ERROR] no SecurityContextConstraints in the render, yet "
             "openshift.scc.enabled=true — nothing to be covered by")

def permits_root(scc):
    """Does this SCC's run-as policy admit UID 0?"""
    t = (scc.get("runAsUser") or {}).get("type", "")
    if t == "RunAsAny":
        return True
    if t == "MustRunAs":
        return (scc.get("runAsUser") or {}).get("uid") == 0
    # MustRunAsNonRoot, MustRunAsRange, and anything unrecognised: treat as a
    # refusal. Unknown policies fail closed by design.
    return False

failures = []
for w in workloads:
    principal = f"system:serviceaccount:{w['ns']}:{w['sa']}"
    covering = [s for s in host_sccs if principal in (s.get("users") or [])]
    if not covering:
        failures.append(
            f"{w['kind']}/{w['name']} (sa={principal}) mounts a hostPath but no "
            f"chart SCC with allowHostDirVolumePlugin lists it — its pods are "
            f"refused at admission on OpenShift")
        print(f"   MISS  {w['kind']}/{w['name']:<26} sa={w['sa']:<24} no SCC")
        continue
    if w["runAsUser"] == 0 and not any(permits_root(s) for s in covering):
        names = ", ".join(s["metadata"]["name"] for s in covering)
        failures.append(
            f"{w['kind']}/{w['name']} pins runAsUser: 0, but its only SCC(s) "
            f"({names}) refuse root — covered on paper, refused at admission")
        print(f"   MISS  {w['kind']}/{w['name']:<26} sa={w['sa']:<24} "
              f"root refused by {names}")
        continue
    print(f"   ok    {w['kind']}/{w['name']:<26} sa={w['sa']:<24} "
          f"scc={covering[0]['metadata']['name']}")

if failures:
    sys.exit("[ERROR] " + "; ".join(failures))

print(f"  ok: all {len(workloads)} hostPath workload(s) covered by "
      f"{len(host_sccs)} hostPath-permitting SCC(s)")
PY

render | python3 "$CMP"

echo "OpenShift SCC coverage: green"
