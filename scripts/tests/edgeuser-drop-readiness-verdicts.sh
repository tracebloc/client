#!/usr/bin/env bash
#
#  edgeuser-drop-readiness-verdicts.sh — prove that
#  docs/migration-tools/edgeuser-drop-readiness.sh reaches the RIGHT verdict on
#  each posture, including every "cannot tell" path.
#
#  WHY. The tool's whole value is that ops trusts its verdict before running a
#  REVOKE and a DROP on a live fleet. An unverified verifier is worse than none:
#  a false DROP-READY authorises exactly the destructive step backend#1528 spent
#  four fleets' worth of care avoiding. And the criterion this tool replaces
#  failed by PASSING -- so "it printed DROP-READY" is not evidence of anything
#  until the tool has been shown to print NOT-READY when it should.
#
#  HOW. A stub `kubectl` on PATH renders a synthetic fleet from a fixture
#  directory. Each case asserts the exit status AND a substring of the specific
#  finding -- never a bare "it failed", because any failure satisfies that and a
#  test that cannot say WHICH refusal fired is a coin toss reporting success
#  (backend#1528's own lesson, and this repo's rule 10).
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOOL="$ROOT/docs/migration-tools/edgeuser-drop-readiness.sh"
[ -x "$TOOL" ] || { echo "FAIL: $TOOL missing or not executable" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; mkdir -p "$STUB"

# The stub reads the scenario out of files, so a case is data rather than code.
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
S="$KSTUB_DIR"
args="$*"
case "$args" in
  *version*)          [ -f "$S/unreachable" ] && exit 1; exit 0 ;;
  *"get pods"*)
    # Honour the requested columns: name-only vs name+phase.
    case "$args" in
      *":status.phase"*) cat "$S/pods" 2>/dev/null ;;
      *)                 awk '{print $1}' "$S/pods" 2>/dev/null ;;
    esac
    exit 0 ;;
  *"get secret"*)     cat "$S/secrets.json" 2>/dev/null || echo '{"items":[]}'; exit 0 ;;
esac
case "$args" in
  *logs*)
    for p in $(cat "$S/pods" 2>/dev/null | awk '{print $1}'); do
      case "$args" in *"$p"*) cat "$S/logs.$p" 2>/dev/null; exit 0 ;; esac
    done
    exit 0 ;;
  *exec*)
    # which pod?
    pod=""
    for p in $(cat "$S/pods" 2>/dev/null | awk '{print $1}'); do
      case "$args" in *"$p"*) pod="$p" ;; esac
    done
    # ORDER MATTERS: the mysql queries are themselves invoked as
    # `-- env MYSQL_PWD=... mysql ...`, so the SQL cases must be tried BEFORE
    # the bare `-- env` case or every query is answered with the pod env.
    case "$args" in
      *information_schema.tables*)
        case "$args" in
          *training_test_datasets*) cat "$S/count.datasets" 2>/dev/null; exit 0 ;;
          *metadata*)               cat "$S/count.metadata" 2>/dev/null; exit 0 ;;
        esac ;;
      *processlist*) cat "$S/count.processlist" 2>/dev/null || echo 0; exit 0 ;;
      # TWO DISTINCT QUERIES against mysql.user, and the stub has to tell them
      # apart or the fixture cannot model the real thing. The verdict now asks
      # COUNT(*) WHERE user='edgeuser' (which cannot truncate); the inventory is a
      # separate row query kept only for the log. A stub answering both with one
      # canned string is how a truncation bug hides -- the COUNT would receive a
      # comma-joined list, fail closed, and look like a harness problem.
      *"COUNT(*)"*mysql.user*)
        if grep -q 'edgeuser' "$S/mysql.user" 2>/dev/null; then echo 1; else echo 0; fi
        exit 0 ;;
      # A GROUP_CONCAT ANSWER IS TRUNCATED AT 1024 BYTES, like the real server.
      # Without this the fixture cannot express the bug at all: a stub that returns
      # the whole list makes the old grep-a-string verdict pass, so a test written
      # against truncation would be vacuous and the mutation below would not redden.
      # MySQL's `group_concat_max_len` default is 1024, and it silently cuts.
      *GROUP_CONCAT*mysql.user*)
        tr ',' '\n' < "$S/mysql.user" 2>/dev/null | paste -sd, - | cut -b1-1024
        exit 0 ;;
      *mysql.user*)  tr ',' '\n' < "$S/mysql.user" 2>/dev/null || echo "root@%"; exit 0 ;;
      *"-- env"*)
        [ -f "$S/execdenied" ] && exit 1
        cat "$S/env.$pod" 2>/dev/null; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/kubectl"

# ---------------------------------------------------------------------------
#  A fully clean fleet. Every other case is this, minus one thing -- so each
#  case isolates exactly one cause, and a case that fails for an unrelated
#  reason shows up as the wrong substring rather than as a pass.
# ---------------------------------------------------------------------------
clean_fleet() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/pods" <<'P'
jobs-manager-abc123 Running
requests-proxy-def456 Running
mysql-0 Running
tracebloc-ingest-xyz Running
P
  local common='MYSQL_HOST=mysql
DB_BOOTSTRAP_USER=root
DB_BOOTSTRAP_PASSWORD=x
SERVICE_DB_ACCOUNTS=true
PER_EXPERIMENT_DB_CREDS=true
TB_META_USER=tb_meta
TB_META_PASSWORD=x
TB_INGEST_USER=tb_ingest
TB_INGEST_PASSWORD=x
TB_CREDMGR_USER=tb_credmgr
TB_CREDMGR_PASSWORD=x'
  # THE FIXTURE MIRRORS THE CHART, AND THAT IS THE WHOLE POINT (Saqlain, #896).
  # Both pods used to get the identical `$common` -- including DB_BOOTSTRAP_USER
  # and PER_EXPERIMENT_DB_CREDS, which `requests-proxy-deployment.yaml` does NOT
  # render. So "a clean retired fleet is DROP-READY" passed only against a fleet
  # shape that CANNOT EXIST, and every mutation case below was differenced
  # against that fiction. The real gate was structurally always-red and the suite
  # was green -- a test that agreed with itself instead of with the chart.
  #
  # Measured from the chart at this head:
  #   requests-proxy : SERVICE_DB_ACCOUNTS + TB_META_USER, and neither mint gate
  #   jobs-manager   : both mint gates as well
  printf '%s\n' "$common" > "$d/env.jobs-manager-abc123"
  printf '%s\n' "MYSQL_HOST=mysql
SERVICE_DB_ACCOUNTS=true
TB_META_USER=tb_meta
TB_META_PASSWORD=x" > "$d/env.requests-proxy-def456"
  printf 'DB_USER=tb_ingest\nDB_PASSWORD=x\n' > "$d/env.tracebloc-ingest-xyz"
  # A DRIVEN CYCLE PRODUCES LOGS, and the fixture has to say so. These were
  # EMPTY, which under the corrected criterion-2 rule now means "we could not
  # look" rather than "we looked and it was clean" (Saqlain, #896). An empty
  # log as the happy path was the same shape as the requests-proxy fixture
  # bug: a clean verdict differenced against a fleet state that does not occur.
  # The content is deliberately benign -- neither the legacy-identity string
  # nor a 1045 -- so the two greps still score [ok] on their own terms.
  for _p in jobs-manager-abc123 requests-proxy-def456 tracebloc-ingest-xyz; do
    printf 'INFO connected to mysql as tb_ingest\nINFO run complete\n' \
      > "$d/logs.$_p"
  done
  echo 87 > "$d/count.datasets"
  echo 3  > "$d/count.metadata"
  echo 0  > "$d/count.processlist"
  echo "root@%,tb_credmgr@%,tb_ingest@%,tb_meta@%" > "$d/mysql.user"
  python3 - "$d/secrets.json" <<'PY'
import base64, json, sys
enc = lambda s: base64.b64encode(s.encode()).decode()
json.dump({"items": [{"data": {
    "TB_INGEST_USER": enc("tb_ingest"), "TB_INGEST_PASSWORD": enc("p"),
    "TB_META_USER": enc("tb_meta"),     "TB_META_PASSWORD": enc("p"),
    "MYSQL_ROOT_PASSWORD": enc("p"),
}}]}, open(sys.argv[1], "w"))
PY
}

PASSED=0; FAILED=0
run_case() {  # $1 label, $2 fixture dir, $3 expected exit, $4 expected substring, 5.. extra args
  local label="$1" dir="$2" want_rc="$3" want_sub="$4"; shift 4
  local out rc=0
  out=$(PATH="$STUB:$PATH" KSTUB_DIR="$dir" "$TOOL" \
          --context c --namespace n \
          --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root \
          "$@" 2>&1) || rc=$?
  local why=""
  [ "$rc" = "$want_rc" ] || why="exit $rc, wanted $want_rc"
  if [ -n "$want_sub" ] && ! grep -qF "$want_sub" <<<"$out"; then
    why="${why:+$why; }missing expected finding: $want_sub"
  fi
  if [ -z "$why" ]; then
    printf '  [ok]   %s\n' "$label"; PASSED=$((PASSED+1))
  else
    printf '  [FAIL] %s -- %s\n' "$label" "$why"; FAILED=$((FAILED+1))
    # Capture-then-slice: `| head -30` closes the pipe after 30 lines, so under
    # errexit+pipefail the upstream SIGPIPE can become the pipeline's status and
    # fail the suite while printing the excerpt it was asked for. The file
    # already uses here-strings (see the grep above), so this stays one idiom.
    excerpt=$(head -30 <<<"$out")
    sed 's/^/         | /' <<<"$excerpt"
  fi
}

echo "edgeuser-drop-readiness verdicts:"

# 1. the happy path must actually pass -- otherwise every refusal below is vacuous
D="$TMP/clean"; clean_fleet "$D"
run_case "a clean retired fleet is DROP-READY" "$D" 0 "DROP-READY"

# 2. the finding this tool exists for
D="$TMP/edgeuser"; clean_fleet "$D"
sed -i.bak 's/^TB_INGEST_USER=.*/TB_INGEST_USER=edgeuser/' "$D/env.jobs-manager-abc123"
run_case "a *_USER resolving to edgeuser is caught by NAME" "$D" 1 "TB_INGEST_USER=edgeuser"

# 3. unset bootstrap user == silent fallback to edgeuser
D="$TMP/nobootstrap"; clean_fleet "$D"
sed -i.bak '/^DB_BOOTSTRAP_USER=/d' "$D/env.jobs-manager-abc123"
run_case "DB_BOOTSTRAP_USER unset is a finding (it FALLS BACK to edgeuser)" "$D" 1 "DB_BOOTSTRAP_USER is unset"

# 4. each gate, separately -- default-off is the dangerous value
D="$TMP/gate1"; clean_fleet "$D"
sed -i.bak 's/^SERVICE_DB_ACCOUNTS=.*/SERVICE_DB_ACCOUNTS=false/' "$D/env.jobs-manager-abc123"
run_case "SERVICE_DB_ACCOUNTS=false is a finding" "$D" 1 "SERVICE_DB_ACCOUNTS=false"
# THIS CASE USED TO ASSERT THE DEFECT (Saqlain, #896). It deleted
# PER_EXPERIMENT_DB_CREDS from REQUESTS-PROXY and demanded a finding -- but the
# chart never renders it there, so it was requiring the tool to fail on a
# correctly-retired fleet. That is what made the gate structurally always-red,
# and the case that should have caught it was the case demanding it.
#
# The gate belongs to the workload that CARRIES it, so that is where its absence
# must be a finding:
D="$TMP/gate2"; clean_fleet "$D"
sed -i.bak '/^PER_EXPERIMENT_DB_CREDS=/d' "$D/env.jobs-manager-abc123"
run_case "PER_EXPERIMENT_DB_CREDS unset on jobs-manager is a finding" "$D" 1 "PER_EXPERIMENT_DB_CREDS is unset"

# And the other half, which is the regression guard for the always-red bug: a
# CONSUMER that renders neither mint gate is not a finding, because there is
# nothing there to be wrong. Without this, restoring the unconditional check
# would go unnoticed again -- case 1 alone cannot say WHY it is ready.
D="$TMP/gate2b"; clean_fleet "$D"
run_case "requests-proxy without the mint gates is NOT a finding" "$D" 0 \
  "requests-proxy (requests-proxy-def456): SERVICE_DB_ACCOUNTS=true"

# 5. a set user with no password cannot authenticate
D="$TMP/nopw"; clean_fleet "$D"
sed -i.bak 's/^TB_META_PASSWORD=.*/TB_META_PASSWORD=/' "$D/env.jobs-manager-abc123"
run_case "a *_USER with an empty *_PASSWORD is a finding" "$D" 1 "TB_META_PASSWORD is empty or absent"

# 6. the spawned ingestion Job is stamped at runtime, not by the chart
D="$TMP/ingest"; clean_fleet "$D"
echo 'DB_USER=edgeuser' > "$D/env.tracebloc-ingest-xyz"
printf 'DB_PASSWORD=x\n' >> "$D/env.tracebloc-ingest-xyz"
run_case "an ingestion Job on edgeuser is a finding" "$D" 1 "DB_USER=edgeuser"

# 7. FAIL CLOSED: no driven cycle means we cannot tell, and that is a failure
D="$TMP/nodriven"; clean_fleet "$D"
grep -v ingest "$D/pods" > "$D/pods.new" && mv "$D/pods.new" "$D/pods"
run_case "no RUNNING ingestion pod => cannot tell, NOT a pass" "$D" 1 "no RUNNING ingestion pod"

# BLOCKER 2 (Saqlain, #896): the case that would have caught the false-PASS.
# The ingestion cases only ever set DB_USER, so a pod with a PASSWORD and NO
# DB_USER shipped green -- `$ivars` was non-empty, the edgeuser grep missed,
# and the tool printed DROP-READY for the criterion that authorizes an
# irreversible DROP. Prod's digest-pinned 0.7 ingestor is exactly this shape.
D="$TMP/ing-nouser"; clean_fleet "$D"
printf 'DB_PASSWORD=x\n' > "$D/env.tracebloc-ingest-xyz"
run_case "ingestion with a PASSWORD but no DB_USER is cannot-tell, NOT a pass" \
  "$D" 1 "DB_USER is absent or empty"

# The other half of the same doctrine, on criterion 2: a `kubectl logs` that
# SUCCEEDS with no output used to score both checks [ok]. "Could not look" must
# not read as "looked and clean".
D="$TMP/emptylog"; clean_fleet "$D"
: > "$D/logs.tracebloc-ingest-xyz"
: > "$D/logs.jobs-manager-abc123"
: > "$D/logs.requests-proxy-def456"
run_case "an EMPTY log is cannot-tell, not a clean cycle" \
  "$D" 1 "the log is empty over --since"

# 8. FAIL CLOSED: missing workload
D="$TMP/nopod"; clean_fleet "$D"
grep -v 'jobs-manager' "$D/pods" > "$D/pods.new" && mv "$D/pods.new" "$D/pods"
run_case "a missing jobs-manager => cannot tell, NOT a pass" "$D" 1 "no Running pod matching 'jobs-manager'"

# 9. FAIL CLOSED: exec refused
D="$TMP/denied"; clean_fleet "$D"; : > "$D/execdenied"
run_case "exec refused => cannot tell, NOT a pass" "$D" 1 "could not read the pod environment"

# 10. FAIL CLOSED: unreachable cluster must not be a clean bill of health
D="$TMP/unreach"; clean_fleet "$D"; : > "$D/unreachable"
run_case "an unreachable cluster exits 2, never 0" "$D" 2 "cannot reach cluster"

# 11. criterion 2: the exact producer string from tracebloc-engine
D="$TMP/legacy"; clean_fleet "$D"
echo 'WARNING Using the legacy shared MySQL identity for metadata' > "$D/logs.jobs-manager-abc123"
run_case "a legacy-identity warning in the cycle is a finding" "$D" 1 "legacy-identity warning(s)"
D="$TMP/denied1045"; clean_fleet "$D"
echo 'ERROR 1045 (28000): Access denied for user' > "$D/logs.requests-proxy-def456"
run_case "a 1045 in the cycle is a finding" "$D" 1 "access-denied event(s)"

# 12. criterion 3: the silent shrink -- the whole reason the criterion exists
D="$TMP/shrink"; clean_fleet "$D"; echo 40 > "$D/count.datasets"
run_case "a shrunk table count is a finding, with the delta" "$D" 1 "SILENT SHRINK of 47"
D="$TMP/grew"; clean_fleet "$D"; echo 99 > "$D/count.datasets"
run_case "a GROWN count is not a shrink (new datasets are fine)" "$D" 0 "grew by 12"

# 13. a live edgeuser connection IS evidence (unlike its absence)
D="$TMP/straggler"; clean_fleet "$D"; echo 2 > "$D/count.processlist"
run_case "a non-empty processlist is real evidence of a straggler" "$D" 1 "live edgeuser connection(s) right now"

# 14. post-drop: edgeuser must be gone from mysql.user
D="$TMP/postdrop"; clean_fleet "$D"
run_case "post-drop passes when edgeuser is absent" "$D" 0 "edgeuser is absent from mysql.user" --phase post-drop
D="$TMP/postdrop2"; clean_fleet "$D"
echo "root@%,edgeuser@%,tb_meta@%" > "$D/mysql.user"
run_case "post-drop FAILS when edgeuser survives" "$D" 1 "still present in mysql.user" --phase post-drop

# 14b. THE TRUNCATION CASE, which the two above could never see (Bugbot).
# `group_concat_max_len` defaults to 1024 bytes. The old verdict grepped a
# GROUP_CONCAT of every non-system account, so on a fleet carrying per-experiment
# users -- required before this phase is reachable -- the list truncated and
# `edgeuser` fell off the END. A truncated-but-non-empty string was then reported
# as "edgeuser is absent": the tool saying "gone" about an account it never saw,
# in front of an irreversible DROP.
#
# The fixture plants 100 per-experiment users AHEAD of edgeuser alphabetically --
# 100 x ~14 bytes = ~1400, comfortably past the 1024 cut, which 60 was NOT (~860:
# the first version of this test could not truncate and so proved nothing) -- so
# any length-limited concatenation drops it. The verdict is a COUNT now, which
# cannot truncate, so this must still report edgeuser present.
D="$TMP/postdrop-truncating"; clean_fleet "$D"
{ for i in $(seq -w 1 100); do printf 'exp_user_%s@%%,' "$i"; done; printf 'edgeuser@%%,zz_last@%%\n'; } > "$D/mysql.user"
run_case "post-drop sees edgeuser even when the inventory would truncate" "$D" 1 \
  "still present in mysql.user" --phase post-drop

# ...and the control: the same long fleet WITHOUT edgeuser must still pass, or a
# check that simply failed on long lists would satisfy the case above.
D="$TMP/postdrop-truncating-clean"; clean_fleet "$D"
{ for i in $(seq -w 1 100); do printf 'exp_user_%s@%%,' "$i"; done; printf 'zz_last@%%\n'; } > "$D/mysql.user"
run_case "a long clean fleet still passes post-drop (control)" "$D" 0 \
  "edgeuser is absent from mysql.user" --phase post-drop

# 15. the mandatory baselines: refusing to guess is the point
for bad_args in "--baseline-datasets" "--baseline-metadata" "--baseline-identity"; do
  out=""; rc=0
  case "$bad_args" in
    --baseline-datasets)  set -- --context c --namespace n --baseline-metadata 3 --baseline-identity root ;;
    --baseline-metadata)  set -- --context c --namespace n --baseline-datasets 87 --baseline-identity root ;;
    --baseline-identity)  set -- --context c --namespace n --baseline-datasets 87 --baseline-metadata 3 ;;
  esac
  out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$TOOL" "$@" 2>&1) || rc=$?
  if [ "$rc" = 2 ] && grep -qF -- "$bad_args is required" <<<"$out"; then
    printf '  [ok]   a missing %s is refused, not defaulted\n' "$bad_args"; PASSED=$((PASSED+1))
  else
    printf '  [FAIL] a missing %s should exit 2 with "is required" (got %s)\n' "$bad_args" "$rc"; FAILED=$((FAILED+1))
  fi
done

# 16. a wrong-identity baseline must not be silently comparable
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$TOOL" --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity nonsense 2>&1) || rc=$?
if grep -qF "must be root, tb_ingest or tb_meta" <<<"$out"; then
  printf '  [ok]   an unlabelled/unknown baseline identity is refused\n'; PASSED=$((PASSED+1))
else
  printf '  [FAIL] an unknown --baseline-identity should be refused\n'; FAILED=$((FAILED+1))
fi

# 17. A NON-NUMERIC baseline is refused. The suite covered MISSING baselines and an
# unknown identity, but never a present-and-malformed count -- so the numeric
# validation itself was untested, and the pipefail fix rewrote exactly that line
# (`printf | grep -qE` -> `case`). A mechanism change under an untested assertion is
# how a validation quietly stops validating, so the input is written down here.
#
# Both keys, and a NEGATIVE control: a real number must still be accepted, or a
# validation that refused everything would satisfy the two cases above.
for bad_num in "abc" "8.7" "" "12x" "-4"; do
  for key in --baseline-datasets --baseline-metadata; do
    out=""; rc=0
    case "$key" in
      --baseline-datasets) set -- --context c --namespace n --baseline-datasets "$bad_num" --baseline-metadata 3  --baseline-identity root ;;
      --baseline-metadata) set -- --context c --namespace n --baseline-datasets 87        --baseline-metadata "$bad_num" --baseline-identity root ;;
    esac
    out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$TOOL" "$@" 2>&1) || rc=$?
    # An empty value trips the earlier "is required" guard rather than the numeric
    # one; either refusal is correct, so accept both messages but demand a refusal.
    if [ "$rc" != 0 ] && { grep -qF -- "$key must be a number" <<<"$out" || grep -qF -- "$key is required" <<<"$out"; }; then
      printf '  [ok]   %s=%s is refused, not treated as a count\n' "$key" "${bad_num:-<empty>}"; PASSED=$((PASSED+1))
    else
      printf '  [FAIL] %s=%s should be refused (rc=%s)\n' "$key" "${bad_num:-<empty>}" "$rc"; FAILED=$((FAILED+1))
    fi
  done
done

# ...and the control: a plain integer still gets through the numeric guard. Without
# this, a `case` pattern that rejected every value would pass every case above.
out=""; rc=0
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$TOOL" --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root 2>&1) || rc=$?
if grep -qF "must be a number" <<<"$out"; then
  printf '  [FAIL] a valid integer baseline was refused as non-numeric (control)\n'; FAILED=$((FAILED+1))
else
  printf '  [ok]   a valid integer baseline passes the numeric guard (control)\n'; PASSED=$((PASSED+1))
fi

# A WRONG bootstrap identity, not just an absent one. The empty and `root` cases
# were covered; a third value was not, so the `*)` arm could be turned into an
# `ok` with every case still green.
D="$TMP/bootwrong"; clean_fleet "$D"
sed -i.bak 's/^DB_BOOTSTRAP_USER=.*/DB_BOOTSTRAP_USER=someoneelse/' "$D/env.jobs-manager-abc123"
run_case "a DB_BOOTSTRAP_USER that is neither root nor empty is a finding" "$D" 1 "DB_BOOTSTRAP_USER=someoneelse"

# The plain Unix USER is not a database identity. `^[A-Z0-9_]*USER=` matched it,
# so a container with USER=nobody had a "DB identity" with no password
# counterpart and produced a false finding (@saqlainsyed007, #896 low note).
D="$TMP/bareuser"; clean_fleet "$D"
printf 'USER=nobody\n' >> "$D/env.jobs-manager-abc123"
printf 'USER=nobody\n' >> "$D/env.requests-proxy-def456"
run_case "a bare USER= env is not treated as a DB identity" "$D" 0 "DROP-READY"

# FAIL CLOSED when the chart is not beside the tool: the declared role is
# cross-checked against the template, so a copy without the chart must refuse
# rather than silently trust the label.
ORPHAN="$TMP/orphan/docs/migration-tools"; mkdir -p "$ORPHAN"
cp "$TOOL" "$ORPHAN/edgeuser-drop-readiness.sh"
# `rc=0; out=$(...) || rc=$?` -- the assignment form aborts the harness under
# `set -e` the moment the tool exits non-zero, which is what this asserts.
rc=0
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$ORPHAN/edgeuser-drop-readiness.sh" \
        --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'could not be checked against the chart' <<<"$out"; then
  printf '  [ok]   the chart being absent is a FINDING, not a trusted label\n'; PASSED=$((PASSED+1))
else
  printf '  [FAIL] a tool copied away from the chart must refuse (rc=%s)\n' "$rc"; FAILED=$((FAILED+1))
fi

# A ROLE THAT DISAGREES WITH THE CHART is a finding. This is what keeps the
# `mint`/`consumer` labels from drifting: the label is readable, the derivation
# is what makes it honest.
MISLABEL="$TMP/mislabel"; mkdir -p "$MISLABEL/docs/migration-tools" "$MISLABEL/client/templates"
cp "$TOOL" "$MISLABEL/docs/migration-tools/edgeuser-drop-readiness.sh"
# jobs-manager's template stripped of both mint gates => the chart says
# "consumer" while the call site still declares "mint".
grep -v -E 'name: (DB_BOOTSTRAP_USER|PER_EXPERIMENT_DB_CREDS)' \
  "$ROOT/client/templates/jobs-manager-deployment.yaml" > "$MISLABEL/client/templates/jobs-manager-deployment.yaml"
cp "$ROOT/client/templates/requests-proxy-deployment.yaml" "$MISLABEL/client/templates/"
rc=0
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$TMP/clean" "$MISLABEL/docs/migration-tools/edgeuser-drop-readiness.sh" \
        --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && grep -qF "disagrees with the chart" <<<"$out"; then
  printf '  [ok]   a declared role that disagrees with the chart is a finding\n'; PASSED=$((PASSED+1))
else
  printf '  [FAIL] a mislabelled workload role must be caught (rc=%s)\n' "$rc"; FAILED=$((FAILED+1))
fi

# THE FIXTURE MIRRORS THE CHART, asserted rather than described in a comment.
# The fixture is now correct; nothing held it that way, and a fixture that drifts
# back re-hides the very bug this suite was extended for.
mirror_fail=0
for pair in "jobs-manager:env.jobs-manager-abc123" "requests-proxy:env.requests-proxy-def456"; do
  wl="${pair%%:*}"; envf="${pair##*:}"
  tpl="$ROOT/client/templates/$wl-deployment.yaml"
  if [ ! -r "$tpl" ]; then
    printf '  [FAIL] cannot read %s -- the mirror check cannot tell, which is a finding\n' "$tpl"; mirror_fail=1; continue
  fi
  want=$(grep -oE 'name: (DB_BOOTSTRAP_USER|SERVICE_DB_ACCOUNTS|PER_EXPERIMENT_DB_CREDS)' "$tpl" | sed 's/name: //' | sort -u)
  have=$(grep -oE '^(DB_BOOTSTRAP_USER|SERVICE_DB_ACCOUNTS|PER_EXPERIMENT_DB_CREDS)=' "$TMP/clean/$envf" | tr -d '=' | sort -u)
  if [ "$want" != "$have" ]; then
    printf '  [FAIL] fixture for %s does not mirror its template.\n    template renders: %s\n    fixture has:      %s\n' \
      "$wl" "$(tr '\n' ' ' <<<"$want")" "$(tr '\n' ' ' <<<"$have")"; mirror_fail=1
  fi
done
if [ "$mirror_fail" -eq 0 ]; then
  printf '  [ok]   the fixture mirrors each workload template exactly\n'; PASSED=$((PASSED+1))
else
  FAILED=$((FAILED+1))
fi

# A SUCCEEDED ingestion pod is not usable evidence, and must not be picked.
# kubectl exec needs a running container, so exec'ing a finished Job pod yields an
# empty env and an unexplained "cannot tell". The selector filters to Running so
# the message can name the real precondition instead (@aptracebloc, #896).
D="$TMP/ingestdone"; clean_fleet "$D"
sed -i.bak 's/^tracebloc-ingest-xyz Running$/tracebloc-ingest-xyz Succeeded/' "$D/pods"
run_case "a Succeeded ingestion pod is not accepted as the driven cycle" "$D" 1 "no RUNNING ingestion pod"

# ...AND A FINISHED JOB ALONGSIDE A LIVE ONE MUST NOT FAIL THE GATE (Bugbot, High).
# `scan_logs` matched on pod NAME alone, so completed ingestion Jobs from earlier
# cycles were scanned too. Their logs fall outside `--since`, the empty-log rule
# scores that `untold` -- a cannot-tell, counted as a failure -- and a fleet that
# had EVER ingested could therefore never print DROP-READY. The gate could not
# authorise the DROP it exists to gate.
#
# Note this is the empty-log rule (correct, and kept) meeting a population it was
# not written for, not a wrong rule.
D="$TMP/stale-ingest-jobs"; clean_fleet "$D"
cat > "$D/pods" <<'P'
jobs-manager-abc123 Running
requests-proxy-def456 Running
mysql-0 Running
tracebloc-ingest-xyz Running
tracebloc-ingest-old1 Succeeded
tracebloc-ingest-old2 Succeeded
P
cp "$D/env.tracebloc-ingest-xyz" "$D/env.tracebloc-ingest-old1" 2>/dev/null || true
cp "$D/env.tracebloc-ingest-xyz" "$D/env.tracebloc-ingest-old2" 2>/dev/null || true
: > "$D/logs.tracebloc-ingest-old1"   # aged out of --since, as a finished Job is
: > "$D/logs.tracebloc-ingest-old2"
run_case "finished ingestion Jobs do not fail a clean in-flight cycle" "$D" 0 \
  "all three criteria hold" --phase pre-revoke

# The control: the LIVE pod's log still has to be read. If skipping non-Running
# pods had been implemented as "skip every ingest pod", this would pass too.
D="$TMP/stale-plus-dirty-live"; clean_fleet "$D"
cat > "$D/pods" <<'P'
jobs-manager-abc123 Running
requests-proxy-def456 Running
mysql-0 Running
tracebloc-ingest-xyz Running
tracebloc-ingest-old1 Succeeded
P
cp "$D/env.tracebloc-ingest-xyz" "$D/env.tracebloc-ingest-old1" 2>/dev/null || true
: > "$D/logs.tracebloc-ingest-old1"
echo "legacy shared MySQL identity in use" > "$D/logs.tracebloc-ingest-xyz"
run_case "a dirty RUNNING ingestion pod is still caught beside finished Jobs" "$D" 1 \
  "legacy-identity warning" --phase pre-revoke

# edgeuser inside a DSN on the INGESTION pod, under a name that is not DB_USER.
# The DB_USER checks match that name exactly, so a connection string elsewhere in
# the env would have gone unseen -- a gap against "nothing resolves to edgeuser".
D="$TMP/ingestdsn"; clean_fleet "$D"
printf 'DATASET_DSN=mysql://edgeuser:secret@mysql:3306/training_test_datasets\n' >> "$D/env.tracebloc-ingest-xyz"
run_case "edgeuser in an ingestion DSN is caught, by NAME" "$D" 1 "DATASET_DSN"

# ... and that value is never echoed, because it carries a password.
D="$TMP/ingestdsnquiet"; clean_fleet "$D"
printf 'DATASET_DSN=mysql://edgeuser:SUPERSECRET@mysql:3306/training_test_datasets\n' >> "$D/env.tracebloc-ingest-xyz"
rc=0
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$D" "$TOOL" --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root 2>&1) || rc=$?
if grep -qF 'SUPERSECRET' <<<"$out"; then
  printf '  [FAIL] an ingestion DSN value must never be printed -- it carries a password\n'; FAILED=$((FAILED+1))
else
  printf '  [ok]   the ingestion DSN value is withheld from the output\n'; PASSED=$((PASSED+1))
fi

# A correct DB_USER does NOT excuse a stale DSN beside it: both are reported.
D="$TMP/ingestboth"; clean_fleet "$D"
printf 'DATASET_DSN=mysql://edgeuser:x@mysql:3306/training_test_datasets\n' >> "$D/env.tracebloc-ingest-xyz"
rc=0
out=$(PATH="$STUB:$PATH" KSTUB_DIR="$D" "$TOOL" --context c --namespace n \
        --baseline-datasets 87 --baseline-metadata 3 --baseline-identity root 2>&1) || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'DB_USER=tb_ingest' <<<"$out" && grep -q 'DATASET_DSN' <<<"$out"; then
  printf '  [ok]   a good DB_USER does not excuse a stale DSN -- both are reported\n'; PASSED=$((PASSED+1))
else
  printf '  [FAIL] the DSN scan must run regardless of the DB_USER verdict (rc=%s)\n' "$rc"; FAILED=$((FAILED+1))
fi

printf '\nedgeuser-drop-readiness-verdicts: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
