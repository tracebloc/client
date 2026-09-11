#!/usr/bin/env bash
#
#  auto-upgrade-telemetry-reconcile-mutations.sh — prove the backend#3550 gates
#  can actually FAIL on the regressions they were written for.
#
#  A guard that has never been seen red is a claim, not a check (repo CLAUDE.md
#  rule 5). Each case below COPIES the chart and the gate into a throwaway tree,
#  breaks ONE thing in the copy, and asserts the gate reddens WITH THE SPECIFIC
#  FINDING for that break (rule 10) — a gate failing for an unrelated reason and
#  a gate that works produce the same exit status, so only the message can tell
#  them apart. The real tree is never written to. Baseline first: a copy that
#  was already red would make every mutation meaningless.
#
#  Mutations, and what each must redden:
#    (a) drop the DaemonSet-absent check          -> the contradictory case reconciles
#    (b) let the dry-run's skipped-no-token pass  -> the Secret-still-absent case reconciles
#    (c) unhook the reconcile from the tick       -> the Secret-arrived case does not reconcile
#    (d) restore "this resolves itself" wording   -> the status-record unit test reddens
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GATE="$ROOT/scripts/tests/auto-upgrade-telemetry-reconcile.sh"
CRONJOB="client/templates/auto-upgrade-cronjob.yaml"
STATUS="client/templates/telemetry-collector-status.yaml"
SUITE="tests/telemetry_collector_test.yaml"
[ -r "$GATE" ] || { echo "FAIL: $GATE missing" >&2; exit 2; }
[ -r "$ROOT/$CRONJOB" ] || { echo "FAIL: $CRONJOB missing" >&2; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }

pass=0; fail=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkfixture() {                       # $1 = destination root
  mkdir -p "$1/scripts/tests"
  cp -R "$ROOT/client" "$1/client"
  cp "$GATE" "$1/scripts/tests/"
}

# mutate FILE OLD NEW — exact, unique anchor, or the mutation is inert and the
# case would pass by accident (an inert mutation and good coverage look alike).
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
if n != 1:
    sys.exit("FAIL: mutation anchor matched %d times in %s, not exactly 1 -- inert or ambiguous:\n%s" % (n, p, old))
open(p, "w").write(s.replace(old, new))
PY
}

run_gate_case() {                   # $1 label, $2 want rc, $3 want substring, $4 fixture root
  local label="$1" want_rc="$2" want="$3" d="$4" out rc
  set +e
  out=$(cd "$d" && bash scripts/tests/auto-upgrade-telemetry-reconcile.sh 2>&1); rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    printf '  [FAIL] %s -- exit %s, wanted %s\n' "$label" "$rc" "$want_rc"
    printf '%s\n' "$out" | sed 's/^/         | /'; fail=$((fail+1)); return
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    printf '  [FAIL] %s -- exit %s as expected but the finding did not name it\n' "$label" "$rc"
    printf '         wanted substring: %s\n' "$want"
    printf '%s\n' "$out" | sed 's/^/         | /'; fail=$((fail+1)); return
  fi
  printf '  [ok]   %s\n' "$label"; pass=$((pass+1))
}

echo "== auto-upgrade-telemetry-reconcile: can it fail? =="

# ---- 0. baseline: the tree as shipped is green ------------------------------
D="$TMP/base"; mkfixture "$D"
run_gate_case "the tree as shipped passes the gate" 0 "all 23 cases" "$D"

# ---- (a) the DaemonSet-absent check is load-bearing --------------------------
D="$TMP/no-ds-check"; mkfixture "$D"
mutate "$D/$CRONJOB" \
'      if printf '"'"'%s\n'"'"' "$_manifest" | telemetry_manifest_has_collector; then' \
'      if false; then'
run_gate_case "(a) dropping the DaemonSet-absent check reddens on the contradictory case" 1 \
  "contradictory: record says skipped but the DaemonSet is deployed -> no upgrade, said loudly: an upgrade RAN" "$D"

# ---- (b) the dry-run verdict is load-bearing ---------------------------------
D="$TMP/no-would-check"; mkfixture "$D"
mutate "$D/$CRONJOB" \
'        enabled) echo "token Secret is now present, a re-render of $CURRENT enables the Collector"; return 0 ;;' \
'        enabled|skipped-no-token) echo "token Secret is now present, a re-render of $CURRENT enables the Collector"; return 0 ;;'
run_gate_case "(b) accepting a skipped-no-token dry-run reddens on the Secret-still-absent case" 1 \
  "Secret still absent: dry-run still skipped-no-token -> no upgrade: an upgrade RAN" "$D"

# ---- (c) the tick actually calls the reconcile -------------------------------
D="$TMP/unhooked"; mkfixture "$D"
mutate "$D/$CRONJOB" \
'      log "already at latest; nothing to upgrade"
      telemetry_reconcile_if_needed' \
'      log "already at latest; nothing to upgrade"'
run_gate_case "(c) unhooking the reconcile from the at-latest branch reddens on the Secret-arrived case" 1 \
  "Secret arrived: stored skipped-no-token, no DaemonSet, dry-run enabled -> reconcile: expected a same-version reconcile, no upgrade ran" "$D"

# ---- (d) the status record's honesty is pinned by the chart unit tests -------
# The old sentence, byte for byte, back in the no-token branch. The unit suite
# for the Collector must name the record as the failing test.
D="$TMP/old-wording"; mkfixture "$D"
mutate "$D/$STATUS" \
'The Secret appearing triggers nothing by itself — the Collector renders on the next helm upgrade of this release: %s. Set telemetryCollector.enabled: false to opt out permanently." .Values.nodeAgents.namespace.name (include "tracebloc.telemetryTokenSecretName" .) (include "tracebloc.telemetryTokenLegacyName" .) $trigger | quote }}' \
'this resolves itself once it does. Set telemetryCollector.enabled: false to opt out permanently." .Values.nodeAgents.namespace.name (include "tracebloc.telemetryTokenSecretName" .) (include "tracebloc.telemetryTokenLegacyName" .) | quote }}'
set +e
out=$(cd "$D" && helm unittest ./client -f "$SUITE" 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  printf '  [FAIL] (d) restoring "this resolves itself" left the Collector unit suite GREEN\n'; fail=$((fail+1))
elif ! grep -qF -- "names the trigger that actually re-renders it, not a self-resolution" <<<"$out"; then
  printf '  [FAIL] (d) suite reddened, but not on the honest-record test\n'
  printf '%s\n' "$out" | sed 's/^/         | /'; fail=$((fail+1))
else
  printf '  [ok]   (d) restoring "this resolves itself" reddens the honest-record unit test\n'; pass=$((pass+1))
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "[ERROR] $fail mutation(s) did not redden their gate ($pass did): a guard here is decorative (backend#3550)" >&2
  exit 1
fi
[ "$pass" -gt 0 ] || { echo "[ERROR] zero mutations ran — refusing to report green" >&2; exit 2; }
echo "  [OK] all $pass cases: every backend#3550 gate has been seen red on its own regression"
