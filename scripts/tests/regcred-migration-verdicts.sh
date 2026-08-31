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
# The REAL helm, captured BEFORE the stub goes on PATH. Assertion 8 renders the
# actual chart; without this it would invoke the stub, get nothing, and refuse.
REAL_HELM="$(command -v helm 2>/dev/null)"
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
  # The redirect target may be quoted (`> "/tmp/..."`). Matching only the bare
  # form found nothing once the path was quoted, and an empty `$snap` then failed
  # the -o yaml check below with a message about the wrong thing.
  snap="$(grep -nE 'helm get values .*> *\"?/tmp/' "$RUNBOOK" | head -1)"

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

  # 7. PRECONDITION 1 is the same shape and was missed by #6, which keys on the
  #    string `vals=$(helm get values` -- present in check 2 -- while the
  #    precondition piped its own `helm get values` straight into `grep`. A
  #    failed read there is worse than in the verify table: it tells the operator
  #    the fleet has NOTHING to migrate, so staging/prod credentials stay in
  #    release values and nobody looks again (Bugbot High on #916).
  #
  #    Keyed on the DEFECT, not on the fix: any `helm get values` whose output is
  #    piped directly into `grep` on one line is the fail-open shape, wherever in
  #    the doc it appears.
  # Comment lines dropped, for the reason kubelet-arg-map-safety.sh gives at
  # length: this doc DOCUMENTS the defect it fixed, so a check that reads prose
  # fires on its own explanation rather than on a command.
  if awk '/^[[:space:]]*```bash$/{inblk=1;next} /^[[:space:]]*```$/{inblk=0;next} inblk' "$RUNBOOK" \
       | grep -v '^[[:space:]]*#' | grep -qE 'helm get values[^|]*\| *grep'; then
    fail=$((fail + 1)); echo "  [bad]  a 'helm get values ... | grep' remains: an empty stdin from a FAILED read matches nothing, and 'nothing' is a success signal in this runbook" >&2
  else
    pass=$((pass + 1)); echo "  [ok]   no cluster read is piped straight into grep"
  fi

  # 8. THE FORCE-PULL SELECTOR MUST MATCH SOMETHING THE CHART RENDERS, and this is
  #    DERIVED from the chart rather than compared against a remembered label
  #    (CLAUDE.md rule 1). The doc used `-l app.kubernetes.io/name=tracebloc`,
  #    which matches nothing twice over: the chart's pod templates carry only
  #    `app: manager` / `app: mysql-client` / ... with no app.kubernetes.io/*
  #    identity at all, and the chart's own app.kubernetes.io/name is `client`.
  #    So the step billed as "the only proof the credential works" deleted
  #    nothing, and the events check then reported a clean pull for a restart
  #    that never happened (Bugbot High on #916).
  sel="$(grep -oE -- '-l +"?app\.kubernetes\.io/[a-z]+=[^" ]+' "$RUNBOOK" \
          | sed -E 's/^-l +"?//' | sort -u)"
  if [ -z "$sel" ]; then
    fail=$((fail + 1)); echo "  [bad]  the runbook names no app.kubernetes.io/* selector at all -- the force-pull step cannot be checked" >&2
  else
    "${REAL_HELM:-helm}" template rel "$ROOT/client" -n ns \
        -f "$ROOT/client/ci/bm-values.yaml" > "$TMP/render.yaml" 2>/dev/null
    if [ ! -s "$TMP/render.yaml" ]; then
      fail=$((fail + 1)); echo "  [bad]  could not render the chart, so the selector could not be checked -- refusing to report it valid" >&2
    else
      while IFS= read -r one; do
        [ -n "$one" ] || continue
        key="${one%%=*}"; val="${one#*=}"
        # `$REL` is whatever the operator sets; the render above uses `rel`.
        [ "$val" = '$REL' ] && val=rel
        # grep on a FILE, not a pipe: `grep -q` closes early and SIGPIPEs the
        # writer, which is the pipefail early-close shape the org checker flags.
        if grep -qE "^[[:space:]]+${key}: ${val}\$" "$TMP/render.yaml"; then
          pass=$((pass + 1)); echo "  [ok]   selector $key=$val matches labels the chart renders"
        else
          fail=$((fail + 1)); echo "  [bad]  selector $key=$val matches NOTHING the chart renders -- the force-pull step would restart nothing and still report a clean pull" >&2
        fi
      done <<EOF
$sel
EOF
    fi
  fi

  # 10. EVERY `helm get values` in a command line must be judged on its exit
  #     status, not just the two that had named assertions. The file already
  #     records "two reads, two failure modes, two assertions" -- there are now
  #     THREE, and a per-read assertion misses the next one by construction. This
  #     is the general form: any command line invoking `helm get values` that is
  #     NOT of the shape `if <var>=$(helm get values ...)` is a finding.
  #
  #     It caught its own gap: assertions 6 and 7 were both green while verify
  #     check 1 had gone back to an unjudged read, because 6 keys on check 2's
  #     variable name and 7 keys on the one-line pipe.
  unjudged=0
  while IFS= read -r line; do
    case "$line" in
      *"helm get values"*)
        # Two shapes JUDGE the read, and both are legitimate:
        #   if var=$(helm get values ...)    capture, then branch on the status
        #   if ! helm get values ... > file  redirect, then branch on the status
        # The second matters because the rollback snapshot must write to a file:
        # `>` creates it whether or not helm succeeds, so the status is the only
        # thing separating a real snapshot from an empty one.
        #
        # ANCHORED AT THE START OF THE LINE. A `case` glob of `*"if "*"=$(helm get
        # values"*` accepts `if true; then dr=$(helm get values ...)` -- the `if`
        # tests something else entirely -- and its own mutation said so by staying
        # green. The rule is that the `if` must test THIS command, so the shape has
        # to be pinned from the first token.
        # THREE shapes judge the read. The third spans a line continuation, so the
        # extractor above folds `\`-joined lines first -- without that, the
        # capture line is seen alone, its `|| { ...; exit 1; }` is on the next
        # line, and a correctly-judged read reads as unjudged.
        #   if var=$(helm get values ...)          branch on the status
        #   if ! helm get values ... > file        branch on the status
        #   var="$(helm get values ...)" || { ... exit 1; }
        # A read is JUDGED when its exit status decides what happens next. Two
        # families cover every legitimate form, and both are needed:
        #   `if ...`            the read is the if-condition (capture or redirect)
        #   `... || ... exit 1` the read aborts the block on failure
        # The second was added after the redirect form
        #   helm get values ... > file || { echo STOP; exit 1; }
        # was reported unjudged: it judges perfectly, it just is not an `if`.
        if [[ "$line" =~ ^[[:space:]]*if[[:space:]] ]] \
           || [[ "$line" =~ \|\|.*exit[[:space:]]+1 ]]; then
          :
        else
          unjudged=$((unjudged + 1)); echo "      unjudged read: $(printf '%s' "$line" | sed 's/^ *//' | cut -c1-90)" >&2
        fi ;;
    esac
  done <<EOF
$(awk '/^[[:space:]]*```bash$/{inblk=1;next} /^[[:space:]]*```$/{inblk=0;next} inblk' "$RUNBOOK" \
    | grep -v '^[[:space:]]*#' \
    | awk '{ while (sub(/\\$/, "")) { if ((getline nxt) > 0) $0 = $0 nxt; else break } print }' \
    | grep 'helm get values')
EOF
  if [ "$unjudged" -eq 0 ]; then
    pass=$((pass + 1)); echo "  [ok]   every 'helm get values' is judged on its exit status"
  else
    fail=$((fail + 1)); echo "  [bad]  $unjudged 'helm get values' read(s) are not judged on their exit status -- a failed call produces empty output, which every check here reads as good news" >&2
  fi

  # 11. "STOP" MUST ACTUALLY STOP. The previous revision printed STOP and carried
  #     on: a failed snapshot said STOP, then the rewrite truncated the new values
  #     file and preflight ran on it; a failed restart said STOP, then `rollout
  #     status` and the events read ran and printed "no pull failures" for a pull
  #     that never happened (Bugbot High + Medium on #916). A runbook is pasted, so
  #     the fix is a subshell with `set -e` and a real `exit` -- which leaves the
  #     subshell, never the operator's terminal.
  #
  #     Keyed on the shape: every `echo "STOP` must carry `exit` on the same line.
  stopless=0
  while IFS= read -r line; do
    case "$line" in
      *'echo "STOP'*)
        case "$line" in
          *"exit 1"*) ;;
          *) stopless=$((stopless + 1)); echo "      STOP with no abort: $(printf '%s' "$line" | sed 's/^ *//' | cut -c1-80)" >&2 ;;
        esac ;;
    esac
  done <<EOF
$(awk '/^[[:space:]]*```bash$/{inblk=1;next} /^[[:space:]]*```$/{inblk=0;next} inblk' "$RUNBOOK")
EOF
  if [ "$stopless" -eq 0 ]; then
    pass=$((pass + 1)); echo "  [ok]   every STOP aborts rather than printing and continuing"
  else
    fail=$((fail + 1)); echo "  [bad]  $stopless STOP message(s) do not abort -- the block runs on and a later step reports success for work that never happened" >&2
  fi

  # 12. and a block that can say STOP must run under `set -e`, or the `exit` in
  #     the middle of a `&&`/`||` chain is the only thing stopping it.
  unguarded=0
  blk=""; n=0
  while IFS= read -r line; do
    case "$line" in
      '```bash'|'   ```bash') n=$((n+1)); blk="" ;;
      '```'|'   ```')
        case "$blk" in
          *'echo "STOP'*)
            case "$blk" in *"set -euo pipefail"*) ;; *) unguarded=$((unguarded+1)) ;; esac ;;
        esac
        blk="" ;;
      *) blk="$blk
$line" ;;
    esac
  done < "$RUNBOOK"
  if [ "$unguarded" -eq 0 ]; then
    pass=$((pass + 1)); echo "  [ok]   every block that can STOP runs under set -euo pipefail"
  else
    fail=$((fail + 1)); echo "  [bad]  $unguarded block(s) can print STOP without running under set -e" >&2
  fi

  # 13. THE EMPTY-MATCH TEST MUST NOT READ `rollout restart` OUTPUT. Over a
  #     selector that matches nothing it prints "No resources found" and exits 0 --
  #     NOT empty, so an emptiness test on it never fires. That is what made the
  #     previous fix fail open in the same way it was fixing.
  if grep -qE 'restarted=\$\(kubectl.*rollout restart' "$RUNBOOK"; then
    fail=$((fail + 1)); echo "  [bad]  the empty-match test reads 'rollout restart' output, which is non-empty ('No resources found') on a no-match" >&2
  else
    pass=$((pass + 1)); echo "  [ok]   the empty-match test does not read 'rollout restart' output"
  fi

  # 14. EVERY /tmp FILE THIS RUNBOOK WRITES MUST BE EMPTINESS-CHECKED before
  #     anything consumes it, and the list is DERIVED from the redirects rather
  #     than naming the two files (CLAUDE.md rule 1) -- a third file added later
  #     is covered without touching this.
  #
  #     `>` truncates the target before the writer runs, so a failed write leaves
  #     a ZERO-BYTE file. This runbook's own text says an empty `-f` resets every
  #     value to the chart default. Judging the writer's exit status is not enough
  #     on its own: by then the file is already truncated, and the emptiness test
  #     is what stops it reaching `helm upgrade` (Bugbot Medium on #916).
  unchecked=0
  written="$(awk '/^[[:space:]]*```bash$/{inblk=1;next} /^[[:space:]]*```$/{inblk=0;next} inblk' "$RUNBOOK" \
              | grep -oE '> *"?/tmp/[^" ]+' | sed -E 's/^> *"?//' | sort -u)"
  if [ -z "$written" ]; then
    fail=$((fail + 1)); echo "  [bad]  parsed NO /tmp redirects from the runbook -- this check would pass vacuously" >&2
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if grep -qF -- "[ -s \"$f\" ]" "$RUNBOOK" || grep -qF -- "[ -s $f ]" "$RUNBOOK"; then
        pass=$((pass + 1)); echo "  [ok]   $f is checked for emptiness before use"
      else
        unchecked=$((unchecked + 1))
        fail=$((fail + 1)); echo "  [bad]  $f is written but never checked for emptiness -- a failed write leaves a truncated file that resets every value" >&2
      fi
    done <<EOF
$written
EOF
  fi

  # 9. and the step must NOTICE an empty match, because `rollout restart` over a
  #    selector that hits nothing prints nothing and exits 0.
  if grep -qE 'matched NO workloads' "$RUNBOOK"; then
    pass=$((pass + 1)); echo "  [ok]   the force-pull step refuses an empty selector match"
  else
    fail=$((fail + 1)); echo "  [bad]  nothing checks that the restart actually matched a workload -- a no-op restart reads as a successful pull" >&2
  fi
fi

echo "the values rewrite — EXECUTED, not grepped (Bugbot on client#916):"
# The runbook tells operators to run this heredoc, so the suite runs the same text.
# A grep would only pin its shape; the bug was in what it DID to the bytes.
#
# The bug, measured through helm rather than reasoned about: safe_load + safe_dump
# round-trips every scalar, and PyYAML emits the string "1e5" UNQUOTED because its
# own loader needs a decimal point for a float. helm's Go YAML does not, so it reads
# `1e5` as float64 100000. A clientPassword of 1e5 reached the chart as the number
# 100000 -- an unexplained auth failure in the middle of a credential migration.
# Thirteen other ambiguous forms round-trip correctly, so this is one narrow
# cross-parser disagreement, which is exactly the kind a grep cannot see.
rw="$TMP/rewrite.py"
python3 - "$RUNBOOK" "$rw" "$TMP" <<'EXTRACT' || { echo "  [bad]  could not extract the rewrite script from the runbook" >&2; fail=$((fail+1)); }
import re, sys
md = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"python3 - > \"/tmp/\$REL-values-new\.yaml\" <<'PY'.*?\n(.*?)\nPY\n", md, re.S)
if not m:
    sys.exit("no rewrite heredoc found")
body = "\n".join(l for l in m.group(1).split("\n") if not l.lstrip().startswith("|| {"))
# ONE DECLARED DEVIATION: the runbook reads /tmp/$REL-values-before.yaml by
# absolute path, which is its contract with the operator. Pointing the EXTRACTED
# copy at the suite's own mktemp -d (mode 0700) instead of world-writable /tmp is
# a security fix, not a change to the logic under test: a PID-predictable name in
# /tmp can be pre-empted by a symlink that the `>` then follows and truncates.
# Flagged on 4f920bb by the commit security review -- and the other 38 temp files
# in this suite already do it this way, so my three were the outlier.
# Only the DIRECTORY changes; the regex, the assertions and the refusals are the
# real text.
body = body.replace('f"/tmp/{os.environ[', 'f"' + sys.argv[3] + '/{os.environ[')
open(sys.argv[2], "w").write(body)
EXTRACT

if [ -s "$rw" ]; then
  # A snapshot in the shape `helm get values -o yaml` actually produces: Go YAML
  # QUOTES "1e5", because its own loader would read it bare as a float.
  # In $TMP (mktemp -d, 0700), not /tmp: see the deviation note in EXTRACT above.
  RW_REL="rwfix"
  rw_before="$TMP/${RW_REL}-values-before.yaml"
  printf 'clientId: abc\nclientPassword: "1e5"\nmysqlRootPassword: "yes"\ndockerRegistry:\n  create: true\n  server: https://x/\n  username: u\n  password: p\n  email: e@x.io\nstorageClass:\n  create: false\n' \
    > "$rw_before"
  out="$(REL="$RW_REL" NEW=tracebloc-ops-regcred python3 "$rw" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "the rewrite runs on a well-formed snapshot" "exit $rc: $(printf '%s' "$out" | head -1)"
  else
    ok "the rewrite runs on a well-formed snapshot"
    # 1. the credential's QUOTING is preserved -- this is the whole finding.
    if printf '%s' "$out" | grep -qF 'clientPassword: "1e5"'; then
      ok "an ambiguous credential keeps its quotes (helm reads a string, not 100000)"
    else
      bad "an ambiguous credential keeps its quotes" "$(printf '%s' "$out" | grep -i clientPassword || echo '<absent>')"
    fi
    # 2. dockerRegistry really was replaced.
    if printf '%s' "$out" | grep -qF 'existingSecret: tracebloc-ops-regcred' \
       && ! printf '%s' "$out" | grep -qE '^  (username|password|server|email):'; then
      ok "dockerRegistry is replaced and its credential keys are gone"
    else
      bad "dockerRegistry is replaced and its credential keys are gone" "$(printf '%s' "$out" | sed -n '/^dockerRegistry:/,/^[a-z]/p' | head -4)"
    fi
    # 3. EVERY other line is byte-identical -- the assertion a round-trip cannot make.
    before_others="$(grep -vE '^dockerRegistry:|^  ' "$rw_before")"
    after_others="$(printf '%s' "$out" | grep -vE '^dockerRegistry:|^  ')"
    if [ "$before_others" = "$after_others" ]; then
      ok "no byte outside dockerRegistry changed"
    else
      bad "no byte outside dockerRegistry changed" "$(diff <(printf '%s' "$before_others") <(printf '%s' "$after_others") | head -4)"
    fi
  fi
  # 4. a snapshot with NO dockerRegistry block still gets one appended.
  rw_add="$TMP/${RW_REL}add-values-before.yaml"; printf 'clientId: abc\n' > "$rw_add"
  out2="$(REL="${RW_REL}add" NEW=tracebloc-ops-regcred python3 "$rw" 2>&1)"
  if printf '%s' "$out2" | grep -qF 'existingSecret: tracebloc-ops-regcred'; then
    ok "a snapshot with no dockerRegistry block gets one appended"
  else
    bad "a snapshot with no dockerRegistry block gets one appended" "$(printf '%s' "$out2" | head -2)"
  fi
  # 5. a non-mapping snapshot is refused, not silently rewritten.
  rw_bad="$TMP/${RW_REL}bad-values-before.yaml"; printf -- '- not\n- a\n- mapping\n' > "$rw_bad"
  # ASSERTS THE NAMED REFUSAL, not a bare non-zero exit (CLAUDE.md rule 10). The
  # first version checked only the status, and removing the isinstance guard stayed
  # GREEN: a list input then reached `.get()` on a list, raised AttributeError, and
  # exited non-zero. A crash satisfied a test named for a refusal.
  out3="$(REL="${RW_REL}bad" NEW=x python3 "$rw" 2>&1)"; rc3=$?
  if [ "$rc3" -ne 0 ] && printf '%s' "$out3" | grep -qF "did not parse as a mapping" \
     && ! printf '%s' "$out3" | grep -q "Traceback"; then
    ok "a non-mapping snapshot is refused BY NAME (not a traceback)"
  else
    bad "a non-mapping snapshot is refused BY NAME" "exit $rc3: $(printf '%s' "$out3" | head -1)"
  fi
  # No rm needed: $TMP is removed wholesale by the suite's own trap.
fi

echo "the copy loop — a partial copy must not look finished:"
# Requires the SUBSHELL form `( set -euo pipefail`, not a bare one. My first version
# grepped `^set -euo pipefail` anchored at column 0 and so rejected the correct
# shape -- a runbook is PASTED, so a top-level `set -e` changes the operator's
# session and the `exit 1` closes their terminal. Every other block here uses the
# subshell; the check now demands it rather than merely tolerating it.
if grep -B8 'for n in <each namespace' "$RUNBOOK" | grep -qE '^\( set -euo pipefail'; then
  ok "the copy loop runs in a subshell under set -euo pipefail"
else
  fail=$((fail+1)); echo "  [bad]  the copy loop is not in a '( set -euo pipefail' subshell -- either a failed namespace is discarded, or the exit closes the operator's terminal" >&2
fi
if sed -n '/for n in <each namespace/,/^done/p' "$RUNBOOK" | grep -qE 'STOP: the copy into'; then
  ok "a failed namespace STOPS the loop and says which one"
else
  fail=$((fail+1)); echo "  [bad]  a failed copy does not abort the loop, so a partial copy prints nothing" >&2
fi

printf '\nregcred-migration-verdicts: %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
