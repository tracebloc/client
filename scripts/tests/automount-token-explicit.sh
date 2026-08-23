#!/usr/bin/env bash
#
#  automount-token-explicit.sh — every pod spec the charts render STATES
#  `automountServiceAccountToken`, in one direction or the other (backend#2345).
#
#  WHY THIS EXISTS. The telemetry Collector DaemonSet named a ServiceAccount and
#  no automount key, so it inherited the Kubernetes default of `true` and mounted
#  an unused API credential onto every node of every customer cluster
#  (backend#2344). The defect was not a wrong choice — it was that NOBODY CHOSE,
#  and nothing asked. Seven of the charts' thirteen pod specs were in that state;
#  a reader could not tell a mounted token from an inherited one.
#
#  So the rule this enforces is presence, not a value. `true` is right for
#  jobs-manager, resource-monitor and the two CronJobs, which hold real RBAC;
#  `false` is right for the proxies, the checks, mysql and the device plugins.
#  What is never right is silence.
#
#  DERIVED, NOT RESTATED (backend#1729 rule 1). The pod specs are read out of
#  RENDERED manifests, so a template added tomorrow is checked tomorrow. This file
#  holds no list of workloads and no list of expected values — a hand-written list
#  agrees with itself and goes stale on the first new template, which is the exact
#  case the guard exists to catch.
#
#  AND ONE DERIVED VALUE CHECK, IN THE ONE DIRECTION THAT HAS NO EXCEPTIONS.
#  Presence alone would let someone flip jobs-manager to `false` and stay green
#  while it lost the API access it exists to use. So: a pod spec whose
#  ServiceAccount IS the subject of a rendered RoleBinding or ClusterRoleBinding
#  may not set `false` — the chart would be granting permissions the pod cannot
#  reach, which is either a broken workload or dead RBAC, and both are findings.
#
#  The MIRROR of that rule is deliberately NOT enforced, because it has a real
#  counter-example: `ingestor/templates/post-install-job.yaml` sets `true` with no
#  binding at all, and correctly — it presents the token to jobs-manager as a
#  credential to be TokenReview'd, never to the API server. "Bound to a Role" and
#  "needs its token" are therefore not the same predicate, and a guard that
#  assumed they were would have to carry an exception list, which is the restating
#  this file exists to avoid.
#
#  FAILS CLOSED TWICE (rule 3). Zero pod specs found is a finding, not agreement.
#  And because a pod spec can only be inspected if some value combination renders
#  it, the matrix below is checked FOR COVERAGE against the template files that
#  declare a pod-bearing kind: a template no combination reaches is reported as
#  UNREACHED and fails, rather than passing silently as "nothing to check". That
#  is the failure mode a matrix-driven guard has, and it is the one that would
#  make this file lie.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== automount token stated explicitly =="

BASE=(--set clientId=x --set clientPassword=y --set storageClass.create=false)

# Value combinations, each chosen to render pod specs the others gate off. This
# list is ALLOWED to be incomplete — the coverage check below turns an omission
# into a failure with the name of the unreached template, instead of a pass.
render_all() {
  helm template t client "${BASE[@]}"
  helm template t client "${BASE[@]}" --set telemetryCollector.enabled=true
  helm template t client "${BASE[@]}" \
    --set gpu.devicePlugin.enabled=true --set gpu.devicePlugin.vendor=nvidia
  helm template t client "${BASE[@]}" \
    --set gpu.devicePlugin.enabled=true --set gpu.devicePlugin.vendor=amd
  helm template t client "${BASE[@]}" --show-only templates/egress-enforcement-check.yaml \
    --set networkPolicy.training.enabled=true \
    --set networkPolicy.training.allowExternalHttps=false
  # The ingest chart refuses to render without a config; the CONTENT is
  # irrelevant here, only that the hook Job renders so its pod spec is seen.
  helm template t ingestor --set ingestConfig=placeholder
}

# The source-side denominator: every template declaring a kind that carries a pod
# spec. Read from the files, so it grows with the chart.
EXPECTED="$(grep -rlE '^kind: (Deployment|DaemonSet|StatefulSet|Job|CronJob|Pod|ReplicationController)$' \
  --include='*.yaml' client/templates ingestor/templates | sort)"

CHK="$(mktemp -t automount.XXXXXX)"
trap 'rm -f "$CHK"' EXIT
cat >"$CHK" <<'PY'
import sys, yaml

KINDS = {"Deployment", "DaemonSet", "StatefulSet", "ReplicaSet",
         "Job", "CronJob", "Pod", "ReplicationController"}
expected = {l.strip() for l in open(sys.argv[1]) if l.strip()}

# `# Source:` precedes each document helm renders; it is how a pod spec is
# attributed back to the template that produced it.
raw = sys.stdin.read()
src_of, cur = {}, None
chunks = []
for block in raw.split("\n---\n"):
    m = [l for l in block.splitlines() if l.startswith("# Source: ")]
    chunks.append((m[0][len("# Source: "):].strip() if m else None, block))

def pod_spec(d):
    k = d.get("kind")
    if k == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    if k == "Pod":
        return d["spec"]
    return d["spec"]["template"]["spec"]

# Subjects of every rendered binding: the derived denominator for the value check.
bound = set()
for _, block in chunks:
    try:
        d = yaml.safe_load(block)
    except yaml.YAMLError:
        continue  # reported below, where the source is known
    if not d or d.get("kind") not in ("RoleBinding", "ClusterRoleBinding"):
        continue
    for subj in d.get("subjects") or []:
        if subj.get("kind") == "ServiceAccount":
            bound.add(subj["name"])

seen, offenders, stated, contradictions = set(), [], [], []
for source, block in chunks:
    try:
        d = yaml.safe_load(block)
    except yaml.YAMLError as e:
        sys.exit(f"[ERROR] unparseable rendered document from {source}: {e}")
    if not d or d.get("kind") not in KINDS:
        continue
    if source is None:
        sys.exit("[ERROR] a rendered pod spec carries no `# Source:` line, so it "
                 "cannot be attributed to a template — refusing to report "
                 "coverage that cannot be computed")
    seen.add(source)
    ps = pod_spec(d)
    name = d["metadata"]["name"]
    if "automountServiceAccountToken" not in ps:
        offenders.append((source, d["kind"], name))
    else:
        val = ps["automountServiceAccountToken"]
        stated.append((source, d["kind"], name, val))
        sa = ps.get("serviceAccountName")
        if val is False and sa and sa in bound:
            contradictions.append((source, d["kind"], name, sa))

if not stated and not offenders:
    sys.exit("[ERROR] no pod specs found in any rendered manifest — the render "
             "produced nothing to check, which is a broken guard, not agreement")

unreached = sorted(expected - seen)

by_source = {}
for source, kind, name, val in stated:
    by_source.setdefault((source, kind, name), set()).add(val)
for (source, kind, name), vals in sorted(by_source.items()):
    # A template rendering DIFFERENT values under different value combinations is
    # itself a finding: the key would then be conditional, and "stated" would
    # depend on which combination a reader happened to look at.
    if len(vals) > 1:
        sys.exit(f"[ERROR] {source} renders {kind} {name} with conflicting "
                 f"automountServiceAccountToken values {sorted(map(str, vals))} "
                 "across value combinations")
    print(f"   {str(next(iter(vals))).lower():5}  {kind:10} {name:35} {source}")

fail = False
if offenders:
    fail = True
    print("\n[ERROR] these pod specs state no `automountServiceAccountToken`, so "
          "they inherit the Kubernetes default of `true` — a token mounted by "
          "omission rather than by decision:", file=sys.stderr)
    for source, kind, name in sorted(set(offenders)):
        print(f"          {kind} {name}  ({source})", file=sys.stderr)
if contradictions:
    fail = True
    print("\n[ERROR] these pod specs refuse the token while the chart binds their "
          "ServiceAccount to a Role or ClusterRole — the workload cannot use the "
          "permissions it was granted:", file=sys.stderr)
    for source, kind, name, sa in sorted(set(contradictions)):
        print(f"          {kind} {name} (sa {sa})  ({source})", file=sys.stderr)
if unreached:
    fail = True
    print("\n[ERROR] these templates declare a pod-bearing kind but NO value "
          "combination in this guard renders them, so their pod specs were never "
          "inspected. Add a combination to render_all() — an unchecked template "
          "must not read as a passing one:", file=sys.stderr)
    for source in unreached:
        print(f"          {source}", file=sys.stderr)
if fail:
    sys.exit(1)

print(f"  ok: all {len(by_source)} distinct pod spec(s) state it, "
      f"across all {len(expected)} pod-bearing template(s); "
      f"no RBAC-bound pod spec refuses its token "
      f"({len(bound)} bound ServiceAccount(s))")
PY

EXP="$(mktemp -t automount-exp.XXXXXX)"
trap 'rm -f "$CHK" "$EXP"' EXIT
printf '%s\n' "$EXPECTED" >"$EXP"

render_all 2>/dev/null | python3 "$CHK" "$EXP"

echo "automount token stated explicitly: green"
