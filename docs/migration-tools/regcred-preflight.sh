#!/usr/bin/env bash
#
#  regcred-preflight.sh — refuse a dockerRegistry.existingSecret migration whose
#  target Secret is not present in EVERY namespace the chart will reference it from.
#
#  WHY (measured on a k3d rehearsal of client-1.9.86, 2026-08-31)
#  The chart references the pull Secret from TWO namespaces: the release namespace
#  and nodeAgents.namespace.name, which defaults to the FIXED string
#  `tracebloc-node-agents`. Copy the Secret into only one of them and:
#
#    * `helm upgrade` reports STATUS: deployed, exit 0
#    * the chart's own <release>-regcred is DELETED from both namespaces
#    * workloads in the missed namespace reference a Secret that does not exist
#    * nothing warns, at any layer
#
#  So the migration reports success and leaves half a cluster unable to pull. The
#  symptom arrives later, as ImagePullBackOff on the next pod start.
#
#  IT DERIVES, IT DOES NOT RESTATE. The namespace/secret pairs come from rendering
#  the chart with the VALUES YOU ARE ABOUT TO APPLY -- not from a hardcoded list of
#  two namespaces. If the chart grows a third consumer, or nodeAgents.namespace.name
#  is overridden, this follows automatically. A hand-written list would agree with
#  itself and disagree with the chart (CLAUDE.md rule 1).
#
#  FAIL CLOSED: a failed render, an unreadable cluster, or zero pairs parsed is a
#  REFUSAL, not a pass. Zero pairs compares equal to zero satisfied pairs.
#
#  usage: regcred-preflight.sh <release> <namespace> <chart-ref> <values.yaml>
#  exit 0 safe to upgrade | 1 would break | 2 cannot tell

set -uo pipefail

REL="${1:?usage: regcred-preflight.sh <release> <namespace> <chart-ref> <values.yaml>}"
NS="${2:?namespace}"; CHART="${3:?chart ref}"; VALS="${4:?values file}"

[ -r "$VALS" ] || { echo "REFUSING: cannot read $VALS" >&2; exit 2; }
command -v helm >/dev/null    || { echo "REFUSING: helm not on PATH" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "REFUSING: kubectl not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "REFUSING: python3 not on PATH" >&2; exit 2; }
# The MODULE, not just the interpreter (Bugbot on #916). This script parses the
# render with PyYAML; on a host with python3 but no PyYAML the parse would die as
# a ModuleNotFoundError traceback and be reported below as "could not parse the
# rendered manifests" -- sending the operator at their values file when the real
# fix is one pip install. Name it here instead.
python3 -c 'import yaml' 2>/dev/null || {
  echo "REFUSING: python3 is present but PyYAML is not importable by it." >&2
  echo "  Install it (python3 -m pip install pyyaml) and re-run. Nothing was changed." >&2
  exit 2; }

# Every cluster read is BOUNDED (Bugbot on #916). Without a timeout, a wedged API
# server leaves this hanging after it has printed the pair list -- and "hung with
# no verdict" is precisely the cannot-tell outcome this gate exists to refuse. The
# timeout turns it into a named exit 2 instead.
: "${TB_KUBECTL_TIMEOUT:=15s}"

render="$(helm template "$REL" "$CHART" -n "$NS" -f "$VALS" 2>&1)" || {
  echo "REFUSING: helm template failed -- cannot know what the upgrade would reference" >&2
  printf '%s\n' "$render" | head -5 >&2
  exit 2
}

pairs="$(printf '%s' "$render" | REL_NS="$NS" python3 -c '
import os, sys, yaml
ns_default = os.environ["REL_NS"]
found = set()
def walk(o, ns):
    if isinstance(o, dict):
        v = o.get("imagePullSecrets")
        if isinstance(v, list):
            for e in v:
                if isinstance(e, dict) and e.get("name"):
                    found.add((ns, e["name"]))
        for x in o.values(): walk(x, ns)
    elif isinstance(o, list):
        for x in o: walk(x, ns)
try:
    docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
except yaml.YAMLError as e:
    print("PARSE_ERROR", e, file=sys.stderr); sys.exit(3)
for d in docs:
    walk(d, (d.get("metadata") or {}).get("namespace") or ns_default)
for ns, name in sorted(found):
    print(ns, name)
')" || { echo "REFUSING: could not parse the rendered manifests" >&2; exit 2; }

if [ -z "$pairs" ]; then
  echo "REFUSING: the render references NO imagePullSecrets at all."
  echo "  Either these values do not configure a registry secret, or the parse is stale."
  echo "  Zero pairs would satisfy this check vacuously, so it refuses instead."
  exit 2
fi

echo "the upgrade would reference these (namespace, secret) pairs:"
missing=0
while read -r ns name; do
  [ -n "$ns" ] || continue
  if out=$(kubectl --request-timeout="$TB_KUBECTL_TIMEOUT" -n "$ns" get secret "$name" -o jsonpath='{.type}' 2>&1); then
    if [ "$out" = "kubernetes.io/dockerconfigjson" ]; then
      printf '  OK       %-26s %s\n' "$ns" "$name"
    else
      printf '  WRONG    %-26s %s  (type=%s, expected kubernetes.io/dockerconfigjson)\n' "$ns" "$name" "$out"
      missing=$((missing + 1))
    fi
  else
    case "$out" in
      *NotFound*|*not\ found*)
        printf '  MISSING  %-26s %s  <-- pods here could not pull\n' "$ns" "$name"
        missing=$((missing + 1)) ;;
      *)
        printf '  UNKNOWN  %-26s %s  (%s)\n' "$ns" "$name" "$(printf '%s' "$out" | head -1)"
        echo "REFUSING: cannot read the cluster -- 'cannot tell' is not 'present'." >&2
        exit 2 ;;
    esac
  fi
done <<< "$pairs"

if [ "$missing" -gt 0 ]; then
  echo
  echo "DO NOT UPGRADE: $missing referenced Secret(s) are absent or the wrong type."
  echo "  helm upgrade would still report STATUS: deployed -- it does not check this."
  echo "  Copy the Secret into every namespace listed above first."
  exit 1
fi
echo
echo "safe: every referenced pull Secret exists, in every namespace that references it."
exit 0
