#!/usr/bin/env bash
#
#  collector-class-a-agreement.sh — every filelog glob targets a container the
#  chart actually deploys (backend#1906).
#
#  WHY THIS EXISTS. The first version of `telemetryCollector.classAContainers`
#  listed `tracebloc-jobs-manager`, `egress-proxy` and `requests-proxy`. None of
#  those are container names — they are workload names — and `filelog`'s include
#  globs match the kubelet's on-disk path, which carries the CONTAINER name. It
#  also scoped every path to `.Release.Namespace`, while resource-monitor runs in
#  `nodeAgents.namespace`. So all four globs matched nothing: the Collector would
#  have started, reported healthy, and shipped zero records.
#
#  Bugbot caught it. Nothing in the repo could have.
#
#  WHY A SHELL TEST AND NOT helm-unittest. This is a CROSS-DOCUMENT agreement —
#  the ConfigMap's globs against the container names in every other rendered
#  workload. helm-unittest asserts within one template at a time and has no way
#  to compare two documents from one render, so the check is only expressible
#  from outside the plugin.
#
#  DERIVED IN BOTH DIRECTIONS, never restated. This script holds NO list of
#  container names: it renders the chart, reads the containers out of the
#  workloads, reads the globs out of the ConfigMap, and compares. A hand-written
#  expectation here would agree with whichever side it was copied from — which is
#  exactly how the original defect passed review.
#
#  FAILS CLOSED. Zero globs or zero containers is a finding, not agreement: two
#  empty sets compare equal, and "I could not tell" must never read as green.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== collector Class A agreement =="

render() {
  helm template t "$CHART" \
    --set clientId=x --set clientPassword=y \
    --set storageClass.create=false \
    --set telemetryCollector.enabled=true 2>/dev/null
}

# The comparison lives in a temp file rather than a heredoc on the same command
# as the pipe: `render | python3 - <<'PY'` makes the HEREDOC stdin and silently
# discards the render, so the script read an empty document set. It failed closed
# — "found 0 Collector ConfigMaps" — which is the design working, but shellcheck
# named it directly (SC2259).
CMP="$(mktemp -t collector-class-a.XXXXXX)"
trap 'rm -f "$CMP"' EXIT
cat >"$CMP" <<'PY'
import sys, re, yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

# Side 1: the containers the chart really deploys, as (namespace, container).
real = set()
for d in docs:
    if d.get("kind") in ("Deployment", "DaemonSet", "StatefulSet"):
        ns = d["metadata"].get("namespace", "")
        for c in d["spec"]["template"]["spec"].get("containers", []):
            real.add((ns, c["name"]))

# Side 2: the filelog include globs out of the Collector's own config.
cms = [d for d in docs
       if d.get("kind") == "ConfigMap" and "telemetry-collector" in d["metadata"]["name"]]
if len(cms) != 1:
    sys.exit(f"[ERROR] expected exactly one Collector ConfigMap, found {len(cms)} "
             "— cannot compare what cannot be located")
cfg = yaml.safe_load(cms[0]["data"]["config.yaml"])
includes = cfg["receivers"]["filelog"]["include"]
globs = [re.match(r"^.*/pods/([^_]+)_\*/([^/]+)/\*\.log$", g) for g in includes]

if not includes:
    sys.exit("[ERROR] filelog has no include globs — a Collector that collects "
             "nothing is not agreement")
if not real:
    sys.exit("[ERROR] no workload containers found in the render — the chart did "
             "not render, so this comparison proves nothing")
if any(m is None for m in globs):
    bad = [g for g, m in zip(includes, globs) if m is None]
    sys.exit(f"[ERROR] include globs not in the expected "
             f"<logs>/pods/<ns>_*/<container>/*.log shape: {bad}")

targets = {(m.group(1), m.group(2)) for m in globs}
missing = sorted(t for t in targets if t not in real)

for ns, c in sorted(targets):
    print(f"   {'ok  ' if (ns, c) in real else 'MISS'}  ns={ns:<24} container={c}")

if missing:
    sys.exit("[ERROR] these globs match no container the chart deploys: "
             + ", ".join(f"{ns}/{c}" for ns, c in missing)
             + " — the Collector would run, report healthy, and ship nothing")

print(f"  ok: all {len(targets)} Class A glob(s) target a real container "
      f"({len(real)} containers in the render)")
PY

render | python3 "$CMP"

echo "collector Class A agreement: green"
