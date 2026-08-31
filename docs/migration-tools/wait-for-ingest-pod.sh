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
#       `tracebloc-stage-<name>-<hash>` (file staging) and only THEN
#       `ingest-job-<hash>-<suffix>`. A naive "wait for any non-control-plane pod"
#       poll catches the stage pod and hands off too early — the readiness tool
#       then finds no live ingestion pod and reports a false failed cycle. The
#       match below keys on `/ingest/`, which `tracebloc-stage-*` does not contain,
#       so the stage pod is skipped. Do NOT loosen this to "a new pod appeared".
#
#    2. A FINISHED JOB IS NOT EVIDENCE. Completed ingestion Jobs from earlier
#       cycles linger; a Succeeded Job pod cannot be exec'd, so it is no cover for
#       THIS evaluation. Only `Running` counts here, exactly as the readiness tool
#       ignores non-Running pods — each evaluation needs its own live run.
#
#  DELIBERATELY THE SAME MATCH AS THE TOOL. The picker below is byte-for-byte
#  edgeuser-drop-readiness.sh's ingestion picker (its `CONTROL_PLANE_RE` + awk), so
#  this wait returns exactly when the tool would find a live pod — it cannot arm a
#  microsecond before or after the thing it is arming. If that picker changes in
#  the tool, change it here too; a divergence is a silent early/late hand-off.
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
    --context)      CONTEXT="${2:-}"; shift 2 ;;
    --namespace|-n) NS="${2:-}"; shift 2 ;;
    --interval)     INTERVAL="${2:-}"; shift 2 ;;
    --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
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
    -h|--help)      sed -n '2,64p' "$0"; exit 0 ;;
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

# THE PICKER — one live ingestion pod name, or nothing. Identical match to the
# readiness tool: Running only, name contains `ingest`, and NOT one of the
# control-plane workloads whose names can also contain the substring on a release
# or namespace that happens to carry it (e.g. `tracebloc-ingest-…-jobs-manager-…`).
CONTROL_PLANE_RE='jobs-manager|requests-proxy|mysql'
ingest_pod() {
  K get pods --no-headers -o custom-columns=':metadata.name,:status.phase' 2>/dev/null \
    | awk -v skip="$CONTROL_PLANE_RE" \
          '$2=="Running" && tolower($1) ~ /ingest/ && tolower($1) !~ skip { print $1; exit }' \
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
    die "no Running ingestion pod appeared within ${TIMEOUT}s. The pod lives ~9s–tens of seconds, so this normally means the driven ingestion was not started (start it, THEN run this), or it already finished — a Succeeded Job cannot be inspected. Ingest a deliberately large dataset to widen the window."
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
