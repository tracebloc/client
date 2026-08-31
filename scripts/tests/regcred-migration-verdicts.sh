#!/usr/bin/env bash
#
#  regcred-migration-verdicts.sh — docs/migration-tools/regcred-preflight.sh and
#  regcred-copy.py must reach the RIGHT verdict, and must REFUSE rather than guess
#  (backend#2571).
#
#  WHY THESE TOOLS EXIST, measured on a k3d rehearsal of client-1.9.86 (2026-08-31)
#  --------------------------------------------------------------------------------
#  The chart references the registry pull Secret from TWO namespaces: the release
#  namespace and `nodeAgents.namespace.name`, whose default is the FIXED string
#  `tracebloc-node-agents`. Migrating `dockerRegistry.create: true` to
#  `existingSecret` while copying the Secret into only ONE of them produces:
#
#      helm upgrade  ->  STATUS: deployed, exit 0
#      the chart's own <release>-regcred  ->  DELETED from BOTH namespaces
#      workloads in the missed namespace  ->  reference a Secret that is not there
#
#  Nothing warns at any layer. The migration is recorded as complete and half the
#  cluster cannot pull. `regcred-preflight.sh` is the gate that makes that a
#  refusal instead of a silent success.
#
#  Two more things the rehearsal established, both encoded as cases below:
#    * Helm DELETES the chart's Secret on migration -- it is not left as an orphan,
#      so flipping the values before copying leaves NO pull Secret at all.
#    * `<release>-regcred` is the chart's own name. On a release called `tracebloc`
#      the obvious operator name `tracebloc-regcred` collides and rewriting it in
#      place strips Helm's ownership metadata.
#
#  DRIVES THE REAL TOOLS (CLAUDE.md rule 9). Every case below invokes the shipped
#  script against a fixture; nothing here re-implements a rule. An inline copy
#  drifts from the tool and then proves a regex nobody runs would have caught it.
#
#  A STUB `kubectl` AND `helm` ON PATH, so the subprocess seam, the exit codes and
#  the parsing are all covered rather than being the part nobody tests. No cluster,
#  no network.
#
#  FAIL CLOSED. Exit 0 all verdicts correct, 1 a wrong verdict.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/../.." && pwd)"
PREFLIGHT="$ROOT/docs/migration-tools/regcred-preflight.sh"
COPY="$ROOT/docs/migration-tools/regcred-copy.py"

for f in "$PREFLIGHT" "$COPY"; do
  [ -r "$f" ] || { echo "ERROR: cannot read ${f#"$ROOT"/} -- refusing to report a clean sweep" >&2; exit 2; }
done

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [ok]   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; shift; for l in "$@"; do printf '         %s\n' "$l"; done; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/regcred-verdicts-XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- stub cluster
# STUB_PRESENT is a space-separated list of "<namespace>/<secret>" that exist.
# Anything else answers NotFound, exactly as kubectl does.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# usage seen from the tool: kubectl -n <ns> get secret <name> -o jsonpath={.type}
ns=""; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) ns="$2"; shift 2 ;;
    secret) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${STUB_UNREACHABLE:-0}" = "1" ] && { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
for p in ${STUB_PRESENT:-}; do
  if [ "$p" = "$ns/$name" ]; then printf 'kubernetes.io/dockerconfigjson'; exit 0; fi
  if [ "$p" = "$ns/$name:wrongtype" ]; then printf 'Opaque'; exit 0; fi
done
echo "Error from server (NotFound): secrets \"$name\" not found" >&2
exit 1
STUB
cat > "$TMP/bin/helm" <<'STUB'
#!/usr/bin/env bash
# usage seen from the tool: helm template <rel> <chart> -n <ns> -f <values>
[ "${STUB_RENDER_FAILS:-0}" = "1" ] && { echo "Error: execution error at (client/templates/x.yaml): required value" >&2; exit 1; }
cat "${STUB_RENDER_FILE:?STUB_RENDER_FILE unset}"
STUB
chmod +x "$TMP/bin/kubectl" "$TMP/bin/helm"
PATH="$TMP/bin:$PATH"; export PATH

# A render referencing the pull Secret from BOTH namespaces -- the real shape.
cat > "$TMP/render-both.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: manager
spec:
  template:
    spec:
      imagePullSecrets:
        - name: tracebloc-ops-regcred
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
  namespace: tracebloc-node-agents
spec:
  template:
    spec:
      imagePullSecrets:
        - name: tracebloc-ops-regcred
YAML
# A render referencing nothing -- must REFUSE, not pass vacuously.
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n' > "$TMP/render-none.yaml"
echo "not: [valid" > "$TMP/render-bad.yaml"
: > "$TMP/values.yaml"

run_preflight() {  # <expected-exit> <label>; env supplies STUB_*
  local want="$1" label="$2"; shift 2
  local out rc
  out="$("$PREFLIGHT" tracebloc tracebloc-templates ./client "$TMP/values.yaml" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else bad "$label" "expected exit $want, got $rc" "$(printf '%s' "$out" | head -3)"; fi
}

echo "preflight — the verdicts:"
STUB_RENDER_FILE="$TMP/render-both.yaml" \
STUB_PRESENT="tracebloc-templates/tracebloc-ops-regcred tracebloc-node-agents/tracebloc-ops-regcred" \
  run_preflight 0 "both namespaces have it -> safe"

STUB_RENDER_FILE="$TMP/render-both.yaml" \
STUB_PRESENT="tracebloc-templates/tracebloc-ops-regcred" \
  run_preflight 1 "the node-agents copy is MISSING -> refuse (the silent-success case)"

STUB_RENDER_FILE="$TMP/render-both.yaml" \
STUB_PRESENT="tracebloc-node-agents/tracebloc-ops-regcred" \
  run_preflight 1 "the RELEASE-namespace copy is missing -> refuse"

STUB_RENDER_FILE="$TMP/render-both.yaml" STUB_PRESENT="" \
  run_preflight 1 "neither namespace has it -> refuse"

STUB_RENDER_FILE="$TMP/render-both.yaml" \
STUB_PRESENT="tracebloc-templates/tracebloc-ops-regcred:wrongtype tracebloc-node-agents/tracebloc-ops-regcred" \
  run_preflight 1 "present but type Opaque, not dockerconfigjson -> refuse"

echo "preflight — fail closed ('cannot tell' is never 'present'):"
STUB_RENDER_FILE="$TMP/render-none.yaml" STUB_PRESENT="" \
  run_preflight 2 "a render referencing NO pull Secret -> refuse, not vacuous pass"

STUB_RENDER_FAILS=1 STUB_RENDER_FILE="$TMP/render-both.yaml" \
  run_preflight 2 "helm template fails -> refuse"

STUB_RENDER_FILE="$TMP/render-bad.yaml" STUB_PRESENT="" \
  run_preflight 2 "the render is unparseable YAML -> refuse"

STUB_UNREACHABLE=1 STUB_RENDER_FILE="$TMP/render-both.yaml" \
  run_preflight 2 "the cluster is unreachable -> refuse"

out="$("$PREFLIGHT" tracebloc tracebloc-templates ./client "$TMP/does-not-exist.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "an unreadable values file -> refuse" || bad "an unreadable values file -> refuse" "got exit $rc"

# ------------------------------------------------------------------ copy tool
echo "regcred-copy.py — what it strips and what it keeps:"
cat > "$TMP/src.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: tracebloc-regcred
  namespace: tracebloc-templates
  uid: 11111111-2222-3333-4444-555555555555
  resourceVersion: "12345"
  creationTimestamp: "2026-08-31T00:00:00Z"
  labels:
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/instance: tracebloc
    helm.sh/chart: client-1.9.86
    app.kubernetes.io/name: tracebloc
  annotations:
    meta.helm.sh/release-name: tracebloc
    meta.helm.sh/release-namespace: tracebloc-templates
    tracebloc.io/keep: "yes"
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: eyJhdXRocyI6e319
YAML
copied="$(python3 "$COPY" tracebloc-ops-regcred < "$TMP/src.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  bad "a valid Secret is copied" "exit $rc: $copied"
else
  check() { printf '%s' "$copied" | grep -q "$1" && return 0 || return 1; }
  check 'name: tracebloc-ops-regcred' && ok "renamed" || bad "renamed"
  check 'type: kubernetes.io/dockerconfigjson' && ok "type preserved" || bad "type preserved"
  check 'eyJhdXRocyI6e319' && ok "payload passes through byte for byte (never decoded)" || bad "payload preserved"
  check 'tracebloc.io/keep' && ok "unrelated annotations kept" || bad "unrelated annotations kept"
  check 'app.kubernetes.io/name' && ok "unrelated labels kept" || bad "unrelated labels kept"
  for k in 'managed-by' 'helm.sh/chart' 'meta.helm.sh' 'app.kubernetes.io/instance' 'uid:' 'resourceVersion' 'creationTimestamp' 'namespace:'; do
    check "$k" && bad "STRIPPED: $k" "still present in the copy -- Helm would adopt and later delete it" || ok "stripped: $k"
  done
fi

echo "regcred-copy.py — refusals:"
# ASSERTS THE SPECIFIC REFUSAL, never a bare non-zero (CLAUDE.md rule 10). Caught
# here in the act: the Opaque fixture below carries no `.dockerconfigjson`, so a
# rc-only check passed while the PAYLOAD refusal fired instead of the TYPE one --
# and a mutation that deleted the type check entirely stayed green. A refusal test
# that cannot say WHICH refusal is a coin toss reporting success.
refuse() {  # <label> <expected-substring> <stdin> [args...]
  local label="$1" want="$2" body="$3"; shift 3
  local out rc; out="$(printf '%s' "$body" | python3 "$COPY" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label" "exited 0; output: $(printf '%s' "$out" | head -2)"
  elif ! printf '%s' "$out" | grep -qF -- "$want"; then
    bad "$label" "refused, but for the wrong reason" "wanted: $want" "got:    $(printf '%s' "$out" | head -1)"
  else
    ok "$label"
  fi
}
refuse "a ConfigMap is refused, as NOT-A-SECRET" "not a Secret" 'apiVersion: v1
kind: ConfigMap
metadata:
  name: x' new
# Carries a VALID .dockerconfigjson deliberately, so the only thing wrong with it
# is the type. Without that, this fixture is refused by the payload check and says
# nothing about the type check at all.
refuse "an Opaque Secret is refused ON ITS TYPE" "Secret type is" 'apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: x
data:
  .dockerconfigjson: e30=' new
refuse "a dockerconfigjson with no payload is refused ON THE PAYLOAD" "no .dockerconfigjson payload" 'apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: x
data: {}' new
refuse "a missing new-name argument is refused ON USAGE" "usage:" 'apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: x
data:
  .dockerconfigjson: e30='

printf '\nregcred-migration-verdicts: %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
