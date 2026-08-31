#!/usr/bin/env bash
#
#  wait-for-ingest-pod.sh — block until a DRIVEN ingestion Job pod is Running,
#  then hand off. The companion primitive to edgeuser-drop-readiness.sh.
#
#  WHY THIS EXISTS. Two of the DROP-readiness gate's three criteria read the
#  ingestion identity, and `kubectl exec` needs a running container — so the gate
#  has to be evaluated WHILE an ingestion run is in flight. Measured on a real
#  fleet (backend#2881), that window is not the minutes an operator plans around:
#
#      500 rows   (~0.5 MB)  ->  ingestion pod lives ~9 seconds
#      20,000 rows (~19 MB)  ->  tens of seconds
#
#  A human running the readiness check by hand "at the right moment" misses it
#  essentially every time. The fix is to stop timing it by hand: fire on the
#  pod's APPEARANCE. This script is that wait, factored out so every operator does
#  not re-hand-roll the `until … sleep 0.2` loop (and get the pod match subtly
#  wrong — see the two traps below). Verified against a live fleet: it caught
#  `ingest-job-5a3907a66777-fc285` on iteration 9, ~1.8 s in.
#
#  Typical use — kick off the driven ingestion, then run this so it exec's the
#  readiness tool the instant the pod goes Running, with no by-hand timing:
#
#      # start a driven ingestion first, then:
#      ./wait-for-ingest-pod.sh --context "$CTX" --namespace "$NS" --exec -- \
#        ./edgeuser-drop-readiness.sh --context "$CTX" --namespace "$NS" \
#          --baseline-datasets N --baseline-metadata N --baseline-identity root \
#          --phase pre-revoke
#
#  Without --exec it prints the pod name and exits 0, so it composes with `&&`:
#
#      ./wait-for-ingest-pod.sh -n "$NS" --context "$CTX" && ./edgeuser-drop-readiness.sh …
#
#  TWO TRAPS THIS ENCODES SO THE OPERATOR DOES NOT HIT THEM (backend#2881):
#
#    1. THE STAGING POD IS NOT THE INGESTION POD. An ingest first creates
#       `tracebloc-stage-<table>-<hash>` (file staging) and only THEN
#       `ingest-job-<digest>-<suffix>`. A naive "wait for any non-control-plane
#       pod" poll catches the stage pod and hands off too early — the readiness
#       tool then reads the wrong pod and reports a false "cannot tell" cycle.
#       Note `<table>` is the OPERATOR'S table name (lowercased, `_`->`-`), so a
#       `/ingest/` SUBSTRING is name-dependent: a table called `ingest_test` gives
#       `tracebloc-stage-ingest-test-<hash>`, which a substring match would wrongly
#       catch (LukasWodka, #924). The picker below anchors on the Job's real
#       producer-side prefix instead: `^ingest-job-` (`client-runtime/
#       submit_ingestion_run.py:358`), which no stage pod carries whatever the
#       table is named. Do NOT loosen this to a substring or to "a new pod".
#
#    2. A FINISHED JOB IS NOT EVIDENCE. Completed ingestion Jobs from earlier
#       cycles linger; a Succeeded Job pod cannot be exec'd, so it is no cover for
#       THIS evaluation. Only `Running` counts here, exactly as the readiness tool
#       ignores non-Running pods — each evaluation needs its own live run.
#
#  ANCHORED, DELIBERATELY STRICTER THAN THE TOOL. edgeuser-drop-readiness.sh keys
#  on the looser `/ingest/` substring; this picker anchors on `^ingest-job-`. The
#  difference is intentional: for the TOOL a mismatch is a wrong reading a human
#  still reviews, but here a false positive (a stage pod, or any workload on a
#  release named `…ingest…`) makes the blocking wait hand off to nothing — a
#  silent loss of the one guarantee this script exists to give. Anchoring also
#  retires the control-plane denylist the tool needs. The tool carries the same
#  `/ingest/` hole; that is tracked separately for a fix in both.
#
#  READ-ONLY. It only ever `kubectl get pods`. It changes nothing, and it does not
#  read Secrets or pod envs — the readiness tool it hands off to does that.
#
#  FAIL CLOSED. If no live ingestion pod appears within --timeout, it EXITS
#  NONZERO with a message, and (with --exec) never runs the handed-off command.
#  "The window was missed" must never read the same as "the pod was there".
#
#  USAGE
#    wait-for-ingest-pod.sh --context <kube-context> --namespace <ns> \
#      [--interval 0.2] [--timeout 120] [--exec -- <command> [args…]]
#
set -euo pipefail

CONTEXT="" NS="" INTERVAL="0.2" TIMEOUT="120"
EXEC_CMD=()
EXEC_REQUESTED=0

die() { printf 'wait-for-ingest-pod: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    # Guard the value BEFORE `shift 2`: a trailing flag leaves <2 positionals, and
    # `shift 2` then returns non-zero — which under `set -e` kills the script with
    # exit 1 and no message, breaking the "exits nonzero WITH a message" contract
    # right when an operator is racing the ~9s window (LukasWodka, #924).
    --context)      [ $# -ge 2 ] || die "--context needs a value"; CONTEXT="$2"; shift 2 ;;
    --namespace|-n) [ $# -ge 2 ] || die "--namespace needs a value"; NS="$2"; shift 2 ;;
    --interval)     [ $# -ge 2 ] || die "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
    --timeout)      [ $# -ge 2 ] || die "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    # `--exec --` consumes the REST of the argv as the command to run on
    # appearance. Everything after the `--` is the operator's command verbatim, so
    # no further flag of ours can appear past it — that is the point: the readiness
    # tool's own `--context/--phase/…` must not be parsed by this script.
    --exec)
      shift
      [ "${1:-}" = "--" ] || die "--exec must be followed by -- then the command, e.g. --exec -- ./edgeuser-drop-readiness.sh …"
      shift
      EXEC_REQUESTED=1
      EXEC_CMD=("$@")
      break ;;
    # Derive the header block rather than hardcode a line range that silently
    # drifts as the header is edited (LukasWodka, #924): print every `#` comment
    # line after the shebang, stop at the first non-comment line.
    -h|--help)      awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *)              die "unknown argument: $1 (did you mean to put it after --exec --?)" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required"
[ -n "$NS" ]      || die "--namespace is required"
case "$INTERVAL" in *[0-9]*) ;; *) die "--interval must be a number of seconds (e.g. 0.2)" ;; esac  # must carry a digit — `.` alone is not a number
case "$INTERVAL" in *[!0-9.]*|*.*.*) die "--interval must be a number of seconds (e.g. 0.2)" ;; esac
case "$TIMEOUT"  in ''|*[!0-9]*)     die "--timeout must be a whole number of seconds" ;; esac
# `--exec --` with nothing after it is a no-op that reads as a fused run but would
# silently degrade to "just wait" — refuse it rather than mislead.
[ "$EXEC_REQUESTED" = "1" ] && [ "${#EXEC_CMD[@]}" -eq 0 ] && die "--exec -- was given with no command after it"

command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

# Bounded kubectl, the same idiom as edgeuser-drop-readiness.sh: a --request-timeout
# on the API request plus a wall-clock `timeout`/`gtimeout` fallback, so a wedged
# apiserver cannot hang the poll on a headless operator session. Unbounded only
# where neither `timeout` nor `gtimeout` exists (stock macOS without coreutils),
# which degrades to a plain kubectl call rather than to a broken one.
KUBE_REQUEST_TIMEOUT="${KUBE_REQUEST_TIMEOUT:-20s}"
KUBE_CALL_TIMEOUT="${KUBE_CALL_TIMEOUT:-30}"

_tmout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

K() {
  _tmout "$KUBE_CALL_TIMEOUT" \
    kubectl --context "$CONTEXT" -n "$NS" \
            --request-timeout="$KUBE_REQUEST_TIMEOUT" "$@"
}

# THE PICKER — one live ingestion Job pod name, or nothing. Anchored on the Job's
# producer-side prefix `^ingest-job-` (`client-runtime/submit_ingestion_run.py:358`),
# NOT a loose `/ingest/` substring (see Trap 1): anchoring skips the file-staging
# pod whatever the operator's table is named, and needs no control-plane denylist —
# no jobs-manager / requests-proxy / mysql / egress-proxy pod carries the prefix,
# even on a release named `…ingest…`.
INGEST_JOB_RE='^ingest-job-'
ingest_pod() {
  # `!seen++ { print $1 }`, NOT `{ print $1; exit }`: awk must DRAIN the pod list,
  # not close the pipe early. An early `exit` sends SIGPIPE (141) upstream while
  # kubectl is still writing a long list, and `|| true` papering over the 141 is
  # not a reason to reintroduce the shape the tool avoids (cursor Bugbot, #924).
  # stderr is suppressed here on purpose so a transient blip during the ~9s window
  # does not abort the wait; a PERSISTENT failure is surfaced by the timeout
  # re-probe below (LukasWodka, #924).
  K get pods --no-headers -o custom-columns=':metadata.name,:status.phase' 2>/dev/null \
    | awk -v want="$INGEST_JOB_RE" \
          '$2=="Running" && tolower($1) ~ want && !seen++ { print $1 }' \
    || true
}

# PREFLIGHT — surface a broken --context / --namespace / credentials up front,
# distinctly from "the pod is not up yet". The poll loop below suppresses kubectl
# stderr on purpose (a transient blip during the ~9s window must not abort the
# wait), so a typo'd context would otherwise make every poll fail silently, run
# the full --timeout, and then misreport as "the ingestion was never started".
# One unsuppressed list call turns that into an immediate, correct error.
if ! preflight_err="$(K get pods --no-headers -o name 2>&1 >/dev/null)"; then
  die "cannot list pods in ${CONTEXT}/${NS}: ${preflight_err:-kubectl get pods failed}. Check --context, --namespace, and that your credentials are valid."
fi

printf 'wait-for-ingest-pod: watching %s/%s for a Running ingestion pod (timeout %ss)…\n' \
  "$CONTEXT" "$NS" "$TIMEOUT" >&2

SECONDS=0
POD=""
while :; do
  POD="$(ingest_pod)"
  [ -n "$POD" ] && break
  if [ "$SECONDS" -ge "$TIMEOUT" ]; then
    # Distinguish "we could not look" from "nothing was there" (the sibling tool's
    # own rule): re-probe once, unsuppressed. A failure here means the wait went
    # BLIND — a context/token that broke mid-wait, after the preflight passed — not
    # that the ingestion is absent, so don't tell the operator to re-drive one
    # (LukasWodka, #924).
    if ! probe_err="$(K get pods --no-headers -o name 2>&1 >/dev/null)"; then
      die "no ingestion pod seen within ${TIMEOUT}s AND pod listing is now failing (${probe_err:-kubectl error}) — the wait went blind, not empty. Fix cluster access and re-run; the ingestion may well have been running."
    fi
    die "no Running ingestion pod (\`^ingest-job-\`) appeared within ${TIMEOUT}s. The pod lives ~9s–tens of seconds, so the driven ingestion was probably not started (start it, THEN run this) or already finished — a Succeeded Job cannot be inspected. Ingest a deliberately large dataset to widen the window."
  fi
  sleep "$INTERVAL"
done

printf 'wait-for-ingest-pod: ingestion pod is Running: %s (after %ss)\n' "$POD" "$SECONDS" >&2

if [ "${#EXEC_CMD[@]}" -gt 0 ]; then
  # Hand off IN THIS PROCESS so nothing races the pod between detection and the
  # readiness tool's own lookup. The tool re-derives the pod itself; passing the
  # name is not possible (it takes none), so the widest lever on the remaining
  # gap is a larger dataset, per the header.
  exec "${EXEC_CMD[@]}"
fi

# Composable mode: emit the name on stdout for `$(…)` capture; the human-readable
# lines above went to stderr so they do not pollute it.
printf '%s\n' "$POD"
