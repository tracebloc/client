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
# The pod portion is `*` in the release namespace and `<release>-*` in the shared
# node-agents namespace — see the ConfigMap's comment for why the second must be
# scoped. Captured so the scoping itself can be checked below.
GLOB = re.compile(r"^.*/pods/([^_]+)_([^/]*)/([^/]+)/\*\.log$")
globs = [GLOB.match(g) for g in includes]

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

targets = {(m.group(1), m.group(3)) for m in globs}

# THE SHARED NAMESPACE MUST BE RELEASE-SCOPED. Container names are identical
# across releases by design (resource-monitor's is `tracebloc-resource-monitor`
# everywhere), and `nodeAgents.namespace` is deliberately shareable — so a bare
# pod wildcard there matches every release's containers, and one edge's Collector
# ingests another edge's logs and ships them under its own token. A cross-tenant
# leak, and invisible: both Collectors look healthy. (Bugbot on #779.)
#
# DERIVED: the namespaces come out of the render, and "shared" means "not the
# release namespace", which is read off the workloads rather than written down.
release_ns = {d["metadata"].get("namespace", "") for d in docs
              if d.get("kind") in ("Deployment", "StatefulSet")
              and d["metadata"].get("namespace")}
unscoped = sorted({m.group(1) for m in globs
                   if m.group(2) == "*" and m.group(1) not in release_ns})
if unscoped:
    sys.exit("[ERROR] these globs use a bare pod wildcard in a namespace that is "
             f"NOT the release namespace: {unscoped}. That namespace is shareable "
             "and container names are identical across releases, so this Collector "
             "would ingest another release's logs and ship them under its own "
             "ingest token. Scope the pod portion to the release.")
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

# ── the lists cannot silently shrink ─────────────────────────────────────────
#
#  backend#2341, Bugbot High on the client#789 promotion. A list set to null is
#  DELETED by helm, and a deleted key does not coalesce back from values.yaml —
#  so the include list shrinks with no error. `minItems: 1` in values.schema.json
#  rejects an EMPTY list and says nothing about an absent one.
#
#  THE QUIET CASE IS ONE LIST, NOT BOTH. Nulling both empties the include, which
#  filelog refuses on its own — loud. Nulling ONE leaves a valid config with a
#  shorter list: the Collector starts, reports Ready, and silently omits three of
#  the four Class A containers. Both are checked, but that is the one this exists
#  for.
#
#  TWO LAYERS, BOTH EXERCISED. The schema rejects it first; the template `fail`
#  is what survives `--skip-schema-validation`, so each is driven through the path
#  that reaches it rather than assumed.
echo
echo "== Class A lists cannot silently shrink =="

refuses() { # DESCRIPTION  EXPECT_IN_STDERR  EXTRA_ARGS...
  local desc="$1" expect="$2"; shift 2
  local out
  if out="$(helm template t "$CHART" \
      --set clientId=x --set clientPassword=y --set storageClass.create=false \
      "$@" 2>&1 >/dev/null)"; then
    echo "[ERROR] $desc: the render SUCCEEDED — a Collector that collects less than" >&2
    echo "        it should must not render. This is the healthy-but-blind shape." >&2
    return 1
  fi
  case "$out" in
    *"$expect"*) printf '   ok    %s\n' "$desc" ;;
    *) echo "[ERROR] $desc: refused, but not for the expected reason." >&2
       echo "        wanted to see: $expect" >&2
       # HERE-STRING, not `printf | head`: under `set -euo pipefail` head closes
       # the pipe, the producer takes SIGPIPE, and the pipeline returns 141 —
       # aborting this script from inside its own error path. The house idiom,
       # and the shared `early-close` gate in tracebloc/.github's code-quality.yml
       # enforces it (backend#1778).
       echo "        got: $(head -2 <<<"$out")" >&2
       return 1 ;;
  esac
}

na_status=0
# Schema layer. MATCHED ON THE PREAMBLE, NOT THE PER-PROPERTY WORDING: helm 3 says
# "<prop> is required" and helm 4 "missing property '<prop>'", and CI pins v3.15.4
# while this was written against v4 — the first version of this guard asserted the
# v4 phrasing and failed on CI for a reason that had nothing to do with the chart.
# The preamble is identical in both, and pairing it with the property name still
# tells the schema refusal apart from the template one below.
SCHEMA_REFUSAL="don't meet the specifications"
refuses "schema rejects a null classAContainers" "$SCHEMA_REFUSAL" \
  --set-json 'telemetryCollector={"enabled":true,"classAContainers":null}' || na_status=1
refuses "schema rejects a null classANodeAgentContainers" "$SCHEMA_REFUSAL" \
  --set-json 'telemetryCollector={"enabled":true,"classANodeAgentContainers":null}' || na_status=1

# Template layer: the same inputs with validation skipped must still refuse.
#
# NEEDS helm >= 3.16 for --skip-schema-validation, and CI pins 3.15.4 — so this
# half is SKIPPED there, loudly, rather than silently passing. The guard still
# earns its place: the flag is what a real operator would reach for, and on any
# helm that has it these two cases run. Detected rather than assumed from the
# version string, because the flag's introduction is what matters, not the number.
# Captured then matched with `case`, NOT `helm ... | grep -q`: grep -q closes the
# pipe on its first hit, helm takes SIGPIPE, and the pipeline returns 141 under
# `set -euo pipefail`. Same class as the `head` above, and the shared
# `early-close` gate in tracebloc/.github's code-quality.yml catches it — it
# caught this very line.
helm_help="$(helm template --help 2>&1 || true)"
case "$helm_help" in
  *--skip-schema-validation*)
    refuses "template refuses a null classAContainers (schema skipped)" "classAContainers resolved to nothing" \
      --skip-schema-validation --set-json 'telemetryCollector={"enabled":true,"classAContainers":null}' || na_status=1
    refuses "template refuses a null classANodeAgentContainers (schema skipped)" "classANodeAgentContainers resolved to nothing" \
      --skip-schema-validation --set-json 'telemetryCollector={"enabled":true,"classANodeAgentContainers":null}' || na_status=1
    ;;
  *)
    printf '   SKIP  template fail-closed: this helm (%s) has no --skip-schema-validation;\n' "$(helm version --short 2>/dev/null)"
    printf '         the schema layer above is what is exercised here.\n'
    ;;
esac

# And the control: the ordinary partial-map shape must still render everything,
# because chart defaults coalesce. This is the mechanism the finding assumed was
# broken; pinning it means a change that really did break coalescing is caught.
partial="$(helm template t "$CHART" \
  --set clientId=x --set clientPassword=y --set storageClass.create=false \
  --set telemetryCollector.enabled=true 2>/dev/null | grep -c '  - "/var/log/pods/')"
if [ "$partial" -ne 4 ]; then
  echo "[ERROR] a partial telemetryCollector map rendered $partial include globs, want 4 —" >&2
  echo "        chart defaults are no longer coalescing, which is the failure the" >&2
  echo "        original finding described." >&2
  na_status=1
else
  printf '   ok    a partial map still coalesces all 4 Class A globs\n'
fi

[ "$na_status" -eq 0 ] || exit 1

echo "collector Class A agreement: green"
