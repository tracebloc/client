#!/usr/bin/env bash
#
#  edgeuser-drop-readiness.sh — evaluate backend#1528's DROP-readiness gate
#  against a LIVE fleet and print one machine verdict.
#
#  WHY THIS EXISTS. The gate is three criteria that each have to hold under a
#  DRIVEN workload, and it has to be evaluated three times per fleet (before
#  REVOKE, after REVOKE, after DROP) across three fleets. Evaluated by hand it is
#  nine judgement calls on prose, and the criterion that matters most -- "nothing
#  resolves to edgeuser" -- is the easiest to get wrong, because the interesting
#  answer is an env var that ISN'T there.
#
#  The criterion it REPLACED could not fail at all: a point-in-time
#  `information_schema.processlist` sample showed no edgeuser on a fleet where
#  edgeuser was still root-equivalent and in active use, because consumers connect
#  per-operation and disconnect. It would have passed before any of the work
#  started. This script is the machine form of the replacement, so the same shape
#  of mistake cannot recur silently.
#
#  WHAT IT DOES NOT DO. It changes nothing -- no REVOKE, no DROP, no writes of any
#  kind. It is read-only by construction and refuses rather than guesses.
#
#  PASSWORDS ARE NEVER PRINTED. It reads MySQL passwords out of Secrets because it
#  must connect as the data-plane identities, and passes them to the client via
#  MYSQL_PWD so they never appear in a pod's argv. Usernames and the gate booleans
#  ARE printed -- they are the finding. For every *_PASSWORD var the script asserts
#  only SET or UNSET, never the value.
#
#  FAIL CLOSED. A pod that is absent, an exec that is refused, a var that cannot be
#  read, logs that are unavailable, a baseline that was not supplied -- each is a
#  FAILURE, printed as "cannot tell", never a pass. "We could not look" must never
#  read the same as "we looked and it was clean".
#
#  USAGE
#    edgeuser-drop-readiness.sh \
#      --context <kube-context> --namespace <ns> \
#      --baseline-datasets N --baseline-metadata N \
#      --baseline-identity root|tb_ingest|tb_meta \
#      [--since 2h] [--phase pre-revoke|post-revoke|post-drop]
#
#  The baselines are the S0 silent-shrink reference for THIS fleet, and they are
#  mandatory. There is no default and no built-in table of per-fleet numbers: a
#  hardcoded copy of a measurement is the backend#1729 defect this whole ticket
#  keeps tripping over. --baseline-identity is mandatory too, because a count read
#  as root and a count read as tb_ingest are different measurements and comparing
#  them silently is how a shrink hides. backend#1528's recorded staging baseline
#  disagrees with dev's on the metadata count almost certainly for that reason.
#
set -euo pipefail

CONTEXT="" NS="" SINCE="2h" PHASE="pre-revoke"
BASE_DS="" BASE_META="" BASE_ID=""

die() { printf 'edgeuser-drop-readiness: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context)            CONTEXT="${2:-}"; shift 2 ;;
    --namespace|-n)       NS="${2:-}"; shift 2 ;;
    --baseline-datasets)  BASE_DS="${2:-}"; shift 2 ;;
    --baseline-metadata)  BASE_META="${2:-}"; shift 2 ;;
    --baseline-identity)  BASE_ID="${2:-}"; shift 2 ;;
    --since)              SINCE="${2:-}"; shift 2 ;;
    --phase)              PHASE="${2:-}"; shift 2 ;;
    -h|--help)            sed -n '2,50p' "$0"; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done

[ -n "$CONTEXT" ]  || die "--context is required"
[ -n "$NS" ]       || die "--namespace is required"
[ -n "$BASE_DS" ]  || die "--baseline-datasets is required (the S0 reference for this fleet; there is deliberately no default)"
[ -n "$BASE_META" ]|| die "--baseline-metadata is required (likewise)"
[ -n "$BASE_ID" ]  || die "--baseline-identity is required: say which identity READ the baseline (root|tb_ingest|tb_meta). A root count and a tb_ingest count are different measurements."
case "$BASE_ID" in root|tb_ingest|tb_meta) ;; *) die "--baseline-identity must be root, tb_ingest or tb_meta" ;; esac
case "$PHASE" in pre-revoke|post-revoke|post-drop) ;; *) die "--phase must be pre-revoke, post-revoke or post-drop" ;; esac
printf '%s' "$BASE_DS"   | grep -qE '^[0-9]+$' || die "--baseline-datasets must be a number"
printf '%s' "$BASE_META" | grep -qE '^[0-9]+$' || die "--baseline-metadata must be a number"

command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

K() { kubectl --context "$CONTEXT" -n "$NS" "$@"; }

FAILURES=0
CANNOT_TELL=0
note()  { printf '    %s\n' "$1"; }
ok()    { printf '  [ok]   %s\n' "$1"; }
bad()   { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES+1)); }
untold(){ printf '  [????] %s\n' "$1"; CANNOT_TELL=$((CANNOT_TELL+1)); FAILURES=$((FAILURES+1)); }

printf '\n=== backend#1528 DROP-readiness — %s / %s — phase: %s ===\n' "$CONTEXT" "$NS" "$PHASE"

K version --request-timeout=20s >/dev/null 2>&1 \
  || die "cannot reach cluster '$CONTEXT' (fail closed: unreachable is not evidence of anything)"

# ---------------------------------------------------------------------------
#  Criterion 1 — the config assertion. THE GATE.
#
#  DERIVED FROM THE DEPLOYED SURFACE, not from a list written here. The set of
#  identity-bearing variables comes from each pod's OWN environment at runtime, so
#  a variable added to the chart after this script was written is covered the day
#  it ships, and one removed stops being demanded. A hand-written list would agree
#  with itself and disagree with the cluster -- which is the failure mode this
#  ticket's superseded criterion actually had.
# ---------------------------------------------------------------------------
printf '\nCriterion 1 — nothing resolves to edgeuser (config assertion)\n'

pod_of() {  # $1 = app label substring; prints one Running pod name, or nothing
  K get pods --no-headers -o custom-columns=':metadata.name,:status.phase' 2>/dev/null \
    | awk -v want="$1" '$2=="Running" && index($1, want) { print $1; exit }'
}

# `env` inside the pod is the resolved truth: it includes values injected via
# envFrom/secretKeyRef, which a manifest read cannot resolve.
check_workload() {  # $1 = pod-name substring, $2 = human label
  local pod vars n_user=0
  pod=$(pod_of "$1")
  if [ -z "$pod" ]; then
    untold "$2: no Running pod matching '$1' — cannot tell whether it resolves to edgeuser"
    return
  fi
  if ! vars=$(K exec "$pod" -c "$1" -- env 2>/dev/null | grep -E '^[A-Z0-9_]+=' || true); then
    vars=""
  fi
  if [ -z "$vars" ]; then
    # Retry without -c: single-container pods reject an explicit container name.
    vars=$(K exec "$pod" -- env 2>/dev/null | grep -E '^[A-Z0-9_]+=' || true)
  fi
  if [ -z "$vars" ]; then
    untold "$2 ($pod): could not read the pod environment (exec refused?) — cannot tell"
    return
  fi

  # (a) no *_USER anywhere in the resolved env may be edgeuser.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local name="${line%%=*}" value="${line#*=}"
    n_user=$((n_user+1))
    if [ "$value" = "edgeuser" ]; then
      bad "$2 ($pod): $name=edgeuser — a consumer still resolves to the root-equivalent account"
    fi
  done <<<"$(grep -E '^[A-Z0-9_]*USER=' <<<"$vars" || true)"
  [ "$n_user" -gt 0 ] || untold "$2 ($pod): the env declares no *_USER variable at all — cannot tell (a pod with no DB identity is not a pod with a safe one)"

  # (b) every *_USER that is set must have a non-empty password counterpart.
  #     SET/UNSET only — the value is never read into a printable place.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local name="${line%%=*}" value="${line#*=}" pwname
    [ -n "$value" ] || continue
    pwname="${name%USER}PASSWORD"
    if ! grep -qE "^${pwname}=." <<<"$vars"; then
      bad "$2 ($pod): $name is set but $pwname is empty or absent — that identity cannot authenticate"
    fi
  done <<<"$(grep -E '^[A-Z0-9_]*USER=' <<<"$vars" || true)"

  # (c) the three gates, by name, because their VALUES are the posture.
  local v
  v=$(grep -E '^DB_BOOTSTRAP_USER=' <<<"$vars" | head -1 | cut -d= -f2- || true)
  case "$v" in
    root) ok "$2 ($pod): DB_BOOTSTRAP_USER=root — the mint is re-parented (S3)" ;;
    "")   bad "$2 ($pod): DB_BOOTSTRAP_USER is unset — the mint falls back to edgeuser (sql_utils.py: unset means the legacy identity)" ;;
    *)    bad "$2 ($pod): DB_BOOTSTRAP_USER=$v — expected root" ;;
  esac
  for gate in SERVICE_DB_ACCOUNTS PER_EXPERIMENT_DB_CREDS; do
    v=$(grep -E "^${gate}=" <<<"$vars" | head -1 | cut -d= -f2- || true)
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
      true|1|yes) ok "$2 ($pod): $gate=$v" ;;
      "")         bad "$2 ($pod): $gate is unset — default-off means the data plane is still edgeuser" ;;
      *)          bad "$2 ($pod): $gate=$v — must be true before edgeuser can be dropped" ;;
    esac
  done
}

check_workload jobs-manager    "jobs-manager"
check_workload requests-proxy  "requests-proxy"

# Spawned ingestion Jobs are stamped at submit time, not by the chart, so they are
# checked separately -- and their ABSENCE is "cannot tell", never a pass. The gate
# requires a DRIVEN cycle: an ingestion run must have happened.
ing=$(K get pods --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep -i 'ingest' | head -1 || true)
if [ -z "$ing" ]; then
  untold "ingestion: no ingestion pod found — the gate requires a DRIVEN cycle (one experiment + one ingestion run). Drive one, then re-run."
else
  ivars=$(K exec "$ing" -- env 2>/dev/null | grep -E '^DB_USER=|^DB_PASSWORD=' || true)
  if [ -z "$ivars" ]; then
    untold "ingestion ($ing): could not read DB_USER — cannot tell"
  elif grep -q '^DB_USER=edgeuser$' <<<"$ivars"; then
    bad "ingestion ($ing): DB_USER=edgeuser — the spawned Job still authenticates as the root-equivalent account"
  else
    ok "ingestion ($ing): DB_USER=$(grep '^DB_USER=' <<<"$ivars" | cut -d= -f2-)"
  fi
fi

# ---------------------------------------------------------------------------
#  Criterion 2 — cumulative corroboration over the cycle.
# ---------------------------------------------------------------------------
printf '\nCriterion 2 — zero legacy-identity warnings and zero 1045 across the cycle (--since %s)\n' "$SINCE"

scan_logs() {  # $1 = pod substring, $2 = label
  local pods hits1045 hitslegacy any=0
  pods=$(K get pods --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep -i "$1" || true)
  if [ -z "$pods" ]; then
    untold "$2: no pod to read logs from — cannot tell"
    return
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local log
    if ! log=$(K logs "$p" --all-containers --since="$SINCE" 2>/dev/null); then
      untold "$2 ($p): logs unavailable — cannot tell"
      continue
    fi
    any=1
    # The exact producer string, from tracebloc-engine core/utils/database.py.
    hitslegacy=$(grep -c 'legacy shared MySQL identity' <<<"$log" || true)
    hits1045=$(grep -cE '\b1045\b|Access denied for user' <<<"$log" || true)
    [ "${hitslegacy:-0}" -eq 0 ] \
      && ok "$2 ($p): no legacy-identity warnings" \
      || bad "$2 ($p): $hitslegacy legacy-identity warning(s) — a consumer fell back to edgeuser during the cycle"
    [ "${hits1045:-0}" -eq 0 ] \
      && ok "$2 ($p): no 1045 / access-denied" \
      || bad "$2 ($p): $hits1045 access-denied event(s) — an identity is misconfigured"
  done <<<"$pods"
  [ "$any" -eq 1 ] || untold "$2: no logs read at all — cannot tell"
}

scan_logs jobs-manager   "jobs-manager"
scan_logs requests-proxy "requests-proxy"
scan_logs ingest         "ingestion"

# ---------------------------------------------------------------------------
#  Criterion 3 — no silent shrink.
#
#  Counted AS THE DATA-PLANE IDENTITY, deliberately. information_schema is
#  privilege-filtered, so a count read as root is the total and can never reveal a
#  shrink -- root sees everything by definition. Reading as tb_ingest / tb_meta is
#  the only way the question can be answered, which is also why the baseline has to
#  say which identity produced it.
# ---------------------------------------------------------------------------
printf '\nCriterion 3 — the privilege-filtered enumeration still matches the S0 baseline\n'

mysql_pod=$(pod_of mysql)
if [ -z "$mysql_pod" ]; then
  untold "no Running mysql pod — cannot count tables, so cannot tell whether the enumeration shrank"
else
  secret_val() {  # $1 = secret key; prints the value, never logged
    K get secret -o json 2>/dev/null \
      | python3 -c '
import base64, json, sys
key = sys.argv[1]
for item in json.load(sys.stdin).get("items", []):
    data = item.get("data") or {}
    if key in data:
        sys.stdout.write(base64.b64decode(data[key]).decode()); break
' "$1" 2>/dev/null || true
  }

  count_as() {  # $1 = mysql user, $2 = password, $3 = schema; prints a count or nothing
    [ -n "$2" ] || return 0
    K exec "$mysql_pod" -- env MYSQL_PWD="$2" mysql -u "$1" -N -B \
      -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$3';" 2>/dev/null \
      | tr -d '[:space:]'
  }

  compare() {  # $1 = label, $2 = observed, $3 = baseline, $4 = identity used
    if [ -z "$2" ]; then
      untold "$1: could not enumerate as $4 — cannot tell (fail closed; an unreadable count is not a matching count)"
    elif [ "$2" -eq "$3" ]; then
      ok "$1: $2 tables as $4, baseline $3 — no shrink"
    elif [ "$2" -lt "$3" ]; then
      bad "$1: $2 tables as $4 but baseline is $3 — SILENT SHRINK of $(( $3 - $2 )). Over-revoked: the enumeration is privilege-filtered, so this does not raise an error, it just stops returning datasets."
    else
      ok "$1: $2 tables as $4, baseline $3 — grew by $(( $2 - $3 )) (new datasets; not a shrink)"
    fi
  }

  ing_pw=$(secret_val TB_INGEST_PASSWORD); ing_u=$(secret_val TB_INGEST_USER)
  met_pw=$(secret_val TB_META_PASSWORD);   met_u=$(secret_val TB_META_USER)
  [ -n "$ing_u" ] || ing_u=tb_ingest
  [ -n "$met_u" ] || met_u=tb_meta

  if [ "$BASE_ID" != "root" ] && [ "$BASE_ID" != "$ing_u" ] && [ "$BASE_ID" != "$met_u" ]; then
    note "note: baseline identity '$BASE_ID' matches neither deployed data-plane user — comparing anyway, but treat the result as indicative."
  fi
  [ "$BASE_ID" = "root" ] && note "note: the baseline was read as root (the TOTAL). Comparing a tb_* count against it is the correct test — the data-plane identity must still see every table root could."

  compare "training_test_datasets" "$(count_as "$ing_u" "$ing_pw" training_test_datasets)" "$BASE_DS"   "$ing_u"
  compare "metadata"               "$(count_as "$met_u" "$met_pw" metadata)"               "$BASE_META" "$met_u"

  # Labelled smoke test only. An EMPTY result is not evidence of absence --
  # consumers connect per-operation and disconnect, which is precisely why the
  # processlist criterion was retired. A NON-empty result is real evidence.
  root_pw=$(secret_val MYSQL_ROOT_PASSWORD)
  if [ -n "$root_pw" ]; then
    live=$(K exec "$mysql_pod" -- env MYSQL_PWD="$root_pw" mysql -u root -N -B \
             -e "SELECT COUNT(*) FROM information_schema.processlist WHERE user='edgeuser';" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "${live:-0}" != "0" ] && [ -n "${live:-}" ]; then
      bad "smoke test: $live live edgeuser connection(s) right now — a real straggler (a non-empty result IS evidence)"
    else
      note "smoke test: no live edgeuser connection at this instant — NOT evidence of absence, recorded only for the log."
    fi
    if [ "$PHASE" = "post-drop" ]; then
      remaining=$(K exec "$mysql_pod" -- env MYSQL_PWD="$root_pw" mysql -u root -N -B \
                    -e "SELECT GROUP_CONCAT(CONCAT(user,'@',host) ORDER BY user) FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema');" 2>/dev/null || true)
      note "post-drop account inventory: ${remaining:-<unreadable>}"
      if grep -q 'edgeuser' <<<"${remaining:-edgeuser}"; then
        bad "post-drop: edgeuser is still present in mysql.user (or the inventory was unreadable — fail closed)"
      else
        ok "post-drop: edgeuser is absent from mysql.user"
      fi
    fi
  else
    untold "could not read MYSQL_ROOT_PASSWORD from any Secret — the smoke test and post-drop inventory were skipped"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n=== VERDICT ===\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 'DROP-READY (%s): all three criteria hold.\n' "$PHASE"
  case "$PHASE" in
    pre-revoke) printf 'Next: REVOKE ALL PRIVILEGES, GRANT OPTION FROM edgeuser, then re-run with --phase post-revoke.\n' ;;
    post-revoke) printf 'Next: observe, then DROP USER edgeuser@%% and @localhost, then re-run with --phase post-drop.\n' ;;
    post-drop)  printf 'Next: dispatch an experiment AFTER the drop and confirm it reaches RUNNING.\n' ;;
  esac
  exit 0
fi
printf 'NOT DROP-READY: %d finding(s)' "$FAILURES"
[ "$CANNOT_TELL" -gt 0 ] && printf ', of which %d are "cannot tell" (counted as failures on purpose)' "$CANNOT_TELL"
printf '.\nDo NOT revoke or drop. Resolve every finding above and re-run.\n'
exit 1
