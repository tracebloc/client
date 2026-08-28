#!/usr/bin/env bash
#
#  telemetry-token-bootstrap.sh — an operator can reach a running Collector from a
#  clean edge, without already having one (backend#2400).
#
#  WHAT SHIPPED, AND WHY NEITHER HALF WAS WRONG. The Collector's daemonset refuses
#  the release when its token Secret is absent — correct: a Collector with no
#  credential spools to every node's disk and delivers nothing, and refusing the
#  install beats CrashLoopBackOff on 200 nodes. jobs-manager writes that Secret
#  only when the chart gives it the coordinates — also correct: an edge with the
#  feature off should make no API calls for it. Composed, they were a deadlock.
#  `enabled=false` meant no env, no env meant no Secret, no Secret meant
#  `enabled=true` was refused. Every edge in the fleet auto-upgrades to the
#  published chart hourly, so every edge was in it.
#
#  Both halves were reviewed against their own descriptions and both passed. What
#  did not exist was anything that looked at the pair. That is the gap this fills.
#
#  THE PROPERTY, and it is deliberately not a checklist of resources: with the
#  Collector OFF, everything that has to be in place BEFORE it can be turned on is
#  wired EXACTLY as it is with the Collector ON. Not "a Role exists" — the same
#  Role, the same rules, the same binding, the same Secret coordinates on the same
#  container, in a namespace the chart creates.
#
#  DERIVED IN BOTH DIRECTIONS, per backend#1729 rule 1. This file names no Secret,
#  no namespace, no key, no verb and no environment variable. It renders the chart
#  twice, projects the token-bootstrap surface out of each render, and compares the
#  two projections. A check holding its own copy of the expected wiring would agree
#  with itself while the chart drifted; there is nothing here to drift from.
#
#  WHY THAT SHAPE CATCHES A PARTIAL FIX, which is the failure this ticket was one
#  `{{- if }}` away from shipping. Three separate gates read
#  `telemetryCollector.enabled`, and re-gating ANY ONE of them re-breaks the
#  bootstrap while leaving the other two looking fixed:
#    * the env vars   — jobs-manager has no coordinates, writes nothing
#    * the Role       — jobs-manager is 403'd, and the write FAILS SOFT (it logs,
#                       returns False, never raises), so the release goes out
#                       green and the Secret still never appears
#    * the namespace  — the write 404s on an edge with no other node-agent tenant
#  Equality across the whole projection reddens on any of the three. An assertion
#  per template could not: each template would still be right about itself.
#
#  THE OFF RENDER MUST STILL BE INERT. Making the two renders agree by turning the
#  Collector ON everywhere would satisfy the equality and be a far worse bug than
#  the one being fixed — a DaemonSet on every customer node, by default. So the
#  absence of the Collector's own workload in the off render is asserted here too,
#  in the same check rather than in a different file that could be deleted alone.
#
#  BOTH TENANT SETTINGS, because the namespace gate only bites when there is no
#  other tenant. `resourceMonitor` defaults to true, so testing the default alone
#  would pass with the namespace still gated — the rare configuration is exactly
#  the one the third gate governs.
#
#  FAILS CLOSED (rule 3). An empty projection compares equal to an empty
#  projection, so "found nothing" is a finding and says so, separately from
#  "found a difference".
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== telemetry token bootstrap =="

# PINNED, not inherited from the caller's kubeconfig. `helm template` with no
# --namespace takes .Release.Namespace from the active kube context, which differs
# between a laptop and a runner with no kubeconfig — and the projection below
# compares namespaces. node-agents-namespace-safety.sh was green where it was
# written and red where it ran for exactly this reason.
RELEASE_NS="bootstrap-guard-release-ns"

PROJ="$(mktemp -t tok-boot-proj.XXXXXX)"
CMP="$(mktemp -t tok-boot-cmp.XXXXXX)"
trap 'rm -f "$PROJ" "$CMP"' EXIT
cat >"$PROJ" <<'PY'
import json, sys

try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

# Projects the token-bootstrap surface out of one full-chart render.
#
# NOTHING IS SELECTED BY A NAME THIS FILE KNOWS. The Secret's namespace and name
# come out of jobs-manager's own environment; the Role is then whatever grants
# `secrets` in that namespace, and the RoleBinding is whatever points at that
# Role. Chasing the references rather than matching strings is what lets this
# compare renders it was not written against. The only literals are structural —
# Kubernetes kinds and field names — plus the variable-family prefix, which is the
# interface with the reader in client-runtime rather than a value this chart picks.
PREFIX = "TELEMETRY_TOKEN_SECRET_"
NS_SUFFIX, NAME_SUFFIX = PREFIX + "NAMESPACE", PREFIX + "NAME"

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
if not docs:
    sys.exit("[ERROR] the chart rendered nothing")

env = {}
created_namespaces = set()
roles, bindings = {}, {}
collector_workload = []

for d in docs:
    kind = d.get("kind")
    meta = d.get("metadata") or {}
    name, ns = meta.get("name"), meta.get("namespace")
    if kind == "Deployment":
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            vals = {e["name"]: e.get("value")
                    for e in (c.get("env") or [])
                    if str(e.get("name", "")).startswith(PREFIX)}
            if vals:
                # KEYED BY CONTAINER. The two containers in this Deployment have
                # byte-identical `env:` openings and only one of them runs the
                # writer, so a block that lands on the wrong one has to read as a
                # difference, not as a match.
                env[f"{ns}/{name}/{c['name']}"] = vals
    elif kind == "Role":
        roles[(ns, name)] = d.get("rules")
    elif kind == "RoleBinding":
        bindings[(ns, name)] = {"subjects": d.get("subjects"),
                                "roleRef": d.get("roleRef")}
    elif kind == "Namespace":
        created_namespaces.add(name)
    if kind in ("DaemonSet", "ConfigMap") and "telemetry-collector" in (name or ""):
        collector_workload.append(f"{kind}/{name}")

# The Secret's coordinates, as the WRITER was told them. Every selection below
# hangs off this, so a render with no env projects an empty surface — which the
# caller treats as a finding rather than as agreement.
targets = {(v.get(NS_SUFFIX), v.get(NAME_SUFFIX)) for v in env.values()}
target_ns = sorted({t[0] for t in targets if t[0]})

def grants_secrets(rules):
    return any("secrets" in (r.get("resources") or []) for r in (rules or []))

token_roles = {f"{ns}/{n}": rules for (ns, n), rules in roles.items()
               if ns in target_ns and grants_secrets(rules)}
token_role_names = {k.split("/", 1)[1] for k in token_roles}
token_bindings = {f"{ns}/{n}": b for (ns, n), b in bindings.items()
                  if ns in target_ns and (b["roleRef"] or {}).get("name") in token_role_names}

print(json.dumps({
    "projection": {
        "env": env,
        "roles": token_roles,
        "bindings": token_bindings,
        # A BOOLEAN PER TARGET NAMESPACE, not the whole Namespace list: which
        # OTHER namespaces the chart creates is a different question and one the
        # Collector legitimately changes.
        "namespace_created": {ns: (ns in created_namespaces) for ns in target_ns},
    },
    "collector_workload": sorted(collector_workload),
}))
PY

cat >"$CMP" <<'PY'
import json, sys

label = sys.argv[1]
off, on = (json.loads(line) for line in sys.stdin.read().splitlines() if line.strip())
problems = []

# 1. VACUITY FIRST. Two empty projections are equal, and an equality between two
#    absences is the check reporting success for having found nothing.
p = on["projection"]
empty = [k for k in ("env", "roles", "bindings", "namespace_created")
         if not p[k] or (k == "namespace_created" and not all(p[k].values()))]
if empty:
    problems.append(
        f"the ENABLED render has nothing to compare for: {', '.join(empty)} — this "
        "check cannot tell agreement from having found nothing, so it refuses to "
        "pass. With the Collector ON the writer's env, the Role that grants it "
        "`secrets`, the binding and the namespace must all be present")

# 2. THE COMPOSED PROPERTY: the bootstrap surface does not depend on the flag.
if not problems and off["projection"] != on["projection"]:
    for key in ("env", "roles", "bindings", "namespace_created"):
        a, b = off["projection"][key], on["projection"][key]
        if a != b:
            problems.append(
                f"{key}: with the Collector OFF the chart renders {a!r}, with it ON "
                f"{b!r} — an operator on a clean edge cannot reach the ON state, "
                "because the daemonset refuses to enable until the Secret this "
                "wiring writes already exists")

# 3. AND THE OFF RENDER IS STILL INERT, so the equality above can never be
#    satisfied by shipping the Collector to every node by default.
if off["collector_workload"]:
    problems.append(
        "the Collector's own workload renders with enabled=false: "
        f"{off['collector_workload']} — the bootstrap wiring must precede the flag, "
        "the DaemonSet must not")

if problems:
    sys.exit(f"[ERROR] {label}: " + "; ".join(problems))

env_containers = len(p["env"])
env_vars = sum(len(v) for v in p["env"].values())
print(f"   {label:<24} identical off/on: {env_vars} env var(s) on "
      f"{env_containers} container(s), {len(p['roles'])} Role(s), "
      f"{len(p['bindings'])} RoleBinding(s), ns {sorted(p['namespace_created'])}")
PY

render() {
  helm template t "$CHART" \
    --namespace "$RELEASE_NS" \
    --set clientId=x --set clientPassword=y \
    --set storageClass.create=false \
    --set "resourceMonitor=$1" \
    --set "telemetryCollector.enabled=$2"
}

fail=0
for rm_val in true false; do
  label="resourceMonitor=$rm_val"

  off="$(render "$rm_val" false 2>/dev/null)" || {
    echo "[ERROR] $label tc=false: the chart failed to render" >&2; exit 1; }
  on="$(render "$rm_val" true 2>/dev/null)" || {
    echo "[ERROR] $label tc=true: the chart failed to render" >&2; exit 1; }

  off_proj="$(printf '%s' "$off" | python3 "$PROJ")"
  on_proj="$(printf '%s' "$on" | python3 "$PROJ")"

  printf '%s\n%s\n' "$off_proj" "$on_proj" | python3 "$CMP" "$label" || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo "telemetry token bootstrap: FAILED" >&2
  exit 1
fi

echo "  ok: the token bootstrap is wired the same whether the Collector is on or off"
echo "telemetry token bootstrap: green"
