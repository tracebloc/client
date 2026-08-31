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
# LOG FIRST: the parse loop below shifts every argument away, so "$*" is empty by
# the time it finishes. The first cut logged after the loop and recorded 0 calls,
# which the assertion correctly refused to read as coverage.
[ -n "${STUB_ARGV_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_ARGV_LOG"
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

echo "preflight — every cluster read is BOUNDED:"
# A read with no --request-timeout hangs forever on a wedged API server, and
# "hung with no verdict" is the cannot-tell outcome this gate exists to refuse
# (Bugbot on #916). Asserted on the stub's recorded argv, so it pins what the
# tool actually PASSES rather than that the string appears in the source.
argvlog="$TMP/argv.log"; : > "$argvlog"
STUB_RENDER_FILE="$TMP/render-both.yaml" STUB_ARGV_LOG="$argvlog" \
STUB_PRESENT="tracebloc-templates/tracebloc-ops-regcred tracebloc-node-agents/tracebloc-ops-regcred" \
  "$PREFLIGHT" tracebloc tracebloc-templates ./client "$TMP/values.yaml" >/dev/null 2>&1
if [ ! -s "$argvlog" ]; then
  bad "kubectl was invoked at all" "the stub recorded no invocation -- the check below would be vacuous"
elif grep -qv -- '--request-timeout' "$argvlog"; then
  bad "every kubectl read carries --request-timeout" "$(grep -c . "$argvlog") call(s), at least one unbounded" "$(grep -v -- '--request-timeout' "$argvlog" | head -1)"
else
  ok "every kubectl read carries --request-timeout ($(grep -c . "$argvlog") call(s))"
fi

echo "both tools — PyYAML is named, not a traceback:"
# A host with python3 but no PyYAML must get a named refusal. Simulated with a
# python3 stub whose `import yaml` fails, first on PATH.
mkdir -p "$TMP/nopyyaml"
cat > "$TMP/nopyyaml/python3" <<'PYSTUB'
#!/usr/bin/env bash
# `-c 'import yaml'` is the preflight's probe -> fail it. Everything else defers
# to the real interpreter with an import hook that hides yaml.
if [ "$1" = "-c" ] && [ "$2" = "import yaml" ]; then exit 1; fi
exec "$REAL_PYTHON3" "$@"
PYSTUB
chmod +x "$TMP/nopyyaml/python3"
out="$(REAL_PYTHON3="$(command -v python3)" PATH="$TMP/nopyyaml:$PATH" \
       STUB_RENDER_FILE="$TMP/render-both.yaml" STUB_PRESENT="" \
       "$PREFLIGHT" tracebloc tracebloc-templates ./client "$TMP/values.yaml" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "pyyaml"; then
  ok "preflight names PyYAML and refuses (exit 2)"
else
  bad "preflight names PyYAML and refuses" "exit $rc" "$(printf '%s' "$out" | head -2)"
fi

# AND THE COPIER, which is what "both tools" claims (Bugbot on client#916). The
# section said both and drove one: the stub above fails only the preflight's
# `-c 'import yaml'` probe and defers everything else to the real interpreter, so
# `python3 regcred-copy.py` still got a working yaml. The copier had no guard at
# all, and removing one that did not exist could not redden anything.
#
# The copier imports yaml itself, so the module has to be unimportable INSIDE the
# child rather than a probe being failed. PYTHONPATH shadows it with a module that
# raises ImportError, which drives the copier's real `except ImportError` branch.
mkdir -p "$TMP/yamlshadow"
printf 'raise ImportError("No module named %s")\n' "'yaml'" > "$TMP/yamlshadow/yaml.py"
out="$(printf 'apiVersion: v1\nkind: Secret\n' \
       | PYTHONPATH="$TMP/yamlshadow" python3 "$COPY" tracebloc-ops-regcred 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "pyyaml"; then
  ok "copier names PyYAML and refuses (exit $rc)"
else
  bad "copier names PyYAML and refuses" "exit $rc" "$(printf '%s' "$out" | head -2)"
fi
# A traceback is NOT a refusal, and rc alone cannot tell them apart -- an uncaught
# ModuleNotFoundError also exits non-zero. Assert the traceback is absent.
if printf '%s' "$out" | grep -q "Traceback"; then
  bad "copier refuses without a traceback" "it printed a Python traceback"
else
  ok "copier refuses without a traceback"
fi

echo "regcred-copy.py — the name collision is ENFORCED, not just documented:"
src_named() { printf 'apiVersion: v1\nkind: Secret\ntype: kubernetes.io/dockerconfigjson\nmetadata:\n  name: %s\ndata:\n  .dockerconfigjson: e30=\n' "$1"; }
out="$(src_named tracebloc-regcred | python3 "$COPY" tracebloc-regcred 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "the SOURCE's own name is refused" "exited 0 -- this would rewrite the live Helm-managed Secret in place"
elif ! printf '%s' "$out" | grep -qF "SOURCE Secret's own name"; then
  bad "the SOURCE's own name is refused" "refused for the wrong reason: $(printf '%s' "$out" | head -1)"
else
  ok "the SOURCE's own name is refused, by name"
fi
out="$(src_named tracebloc-regcred | python3 "$COPY" tracebloc-ops-regcred 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'name: tracebloc-ops-regcred'; then
  ok "a DISTINCT name is still accepted (the guard is not over-broad)"
else
  bad "a distinct name is still accepted" "exit $rc: $(printf '%s' "$out" | head -1)"
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

echo "the RUNBOOK's own commands — three findings that were in the doc, not the tools:"
# The runbook is the operator's instruction sheet, and all three of Bugbot's third
# round landed there rather than in regcred-preflight.sh or regcred-copy.py. A
# doc-only defect is still a defect: it is what somebody types on a live fleet.
RUNBOOK="$ROOT/docs/migration-tools/regcred-existing-secret.md"
if [ ! -r "$RUNBOOK" ]; then
  echo "  [bad]  cannot read $RUNBOOK -- refusing to report clean over an unread file" >&2
  fail=$((fail + 1))
else
  # The line that snapshots values and is later fed to `helm upgrade -f`.
  snap="$(grep -n 'helm get values .*> */tmp/' "$RUNBOOK" | head -1)"

  # 1. `-o yaml`, because the DEFAULT format is `table` and prefixes
  #    "COMPUTED VALUES:", which parses as a top-level key of that name. Measured on
  #    helm v4.1.1: yaml.safe_load returns ['COMPUTED VALUES', 'foo', 'nested'].
  if printf '%s' "$snap" | grep -q -- '-o yaml'; then
    pass=$((pass + 1)); echo "  [ok]   the snapshot uses -o yaml, so no COMPUTED VALUES key reaches helm upgrade"
  else
    fail=$((fail + 1)); echo "  [bad]  the snapshot omits -o yaml: $snap" >&2
  fi

  # 2. NOT `-a`, because that dumps COMPUTED values and freezes today's chart
  #    defaults as user-supplied. A later --reset-then-reuse-values tick keeps them.
  if printf '%s' "$snap" | grep -qE -- '-a( |$)'; then
    fail=$((fail + 1)); echo "  [bad]  the snapshot still passes -a, freezing chart defaults into the rollback: $snap" >&2
  else
    pass=$((pass + 1)); echo "  [ok]   the snapshot does not pass -a, so only operator-set values are captured"
  fi

  # 3. the credential file is not world-readable. It holds the live registry
  #    password in cleartext, in a predictable path, on a shared bastion.
  if grep -qE '^(umask 077|chmod 600|chmod 0600)' "$RUNBOOK"; then
    pass=$((pass + 1)); echo "  [ok]   the credential snapshot is mode-restricted before it is written"
  else
    fail=$((fail + 1)); echo "  [bad]  nothing restricts the mode of the file holding the registry password" >&2
  fi

  # 4. no verify check maps an error to its own success signal. `2>/dev/null` on a
  #    read whose empty result MEANS success is the fail-open shape: an unreachable
  #    cluster printed a clean bill of health for the whole table.
  if grep -qE 'kubectl .*-o jsonpath.*2>/dev/null' "$RUNBOOK"; then
    fail=$((fail + 1)); echo "  [bad]  a verify read still discards stderr, so an error reads as ABSENT" >&2
  else
    pass=$((pass + 1)); echo "  [ok]   verify reads keep stderr and judge on exit status"
  fi

  # 5. and the failed-read branch is DISTINGUISHABLE from the success branch.
  #
  #    KEYED ON THE DISCRIMINATOR, not on the message. Checking for the string
  #    "FAILED (" was VACUOUS: replacing the `*NotFound*)` arm with `*)` makes the
  #    first arm swallow every error and the FAILED arm unreachable -- while the
  #    string stays in the file. Its own mutation caught that. `*NotFound*` is the
  #    only thing separating "genuinely gone" (the success signal for the old name)
  #    from "the read failed".
  if grep -qE '[*]NotFound[*][)]' "$RUNBOOK" && grep -qE 'INCONCLUSIVE|FAILED [(]' "$RUNBOOK"; then
    pass=$((pass + 1)); echo "  [ok]   a failed read is discriminated from NotFound and reported as FAILED"
  else
    fail=$((fail + 1)); echo "  [bad]  nothing separates 'genuinely absent' from 'could not read'" >&2
  fi

  # 6. and check 2's read is judged on its EXIT STATUS, not piped straight into
  #    `grep -ci`. This is a SEPARATE assertion from #4 on purpose: #4 keys on the
  #    kubectl read, so it went green while check 2 -- a `helm get values` -- had
  #    gone back to counting matches in the empty output of a failed call. Two
  #    reads, two failure modes, two assertions.
  if grep -qE 'if +vals=[$][(]helm get values' "$RUNBOOK"; then
    pass=$((pass + 1)); echo "  [ok]   check 2 reads once and judges on the exit status"
  else
    fail=$((fail + 1)); echo "  [bad]  check 2 does not test whether the helm read succeeded, so a failed call counts 0 matches and reads as clean" >&2
  fi
fi

printf '\nregcred-migration-verdicts: %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
