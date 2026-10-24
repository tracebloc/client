{{/*
  tracebloc.trainingGateSh -- the shell both periodic jobs that replace the
  jobs-manager or requests-proxy pods run before doing so: auto-upgrade-cronjob.yaml
  (a `helm upgrade`) and image-refresh-cronjob.yaml (a `kubectl set image`). A
  replaced jobs-manager starts the next training cycle late, and a multi-edge run
  then averages that cycle without this edge, so the job waits while the edge
  trains. ONE copy, included into both scripts, so the two cannot disagree about
  what "training" means.

  The caller defines, before calling training_gate:
    log MSG                 its own log line
    kube_raw_get PATH       GET PATH on the Kubernetes API, the body on stdout
    gate_streak_read        the recorded deferral count (empty: none); non-zero
                            when it cannot be read
    gate_streak_write N     record N; non-zero on failure
    gate_streak_clear       drop the record; non-zero on failure
  and sets TRACEBLOC_RELEASE_NAMESPACE (or the legacy RELEASE_NAMESPACE, read only
  under a blank canonical) plus the three values tracebloc.trainingGateEnv renders.
*/}}
{{- define "tracebloc.trainingGateSh" -}}
# --- defer while training: begin (tracebloc.trainingGateSh) -----------------
# The label jobs-manager stamps on every pod it runs from the training image
# (training, inference and the scoring of a trained cycle), URL-encoded. The
# GPU probe carries another value of the same key and is not training.
TRAINING_POD_SELECTOR="tracebloc.io%2Fworkload%3Dtraining"

# The first item of a PodList body on stdin, as `NAME PHASE`; `empty` for a
# list with no item; nothing for a body that is not a PodList. `"items":` first
# occurs at the list's own key: kind, apiVersion and metadata precede it, and
# an item's metadata.name and status.phase are the first of their keys inside it.
training_pod_list_first() {
  tr -d '\n' | awk '{
    if ($0 !~ /"kind":[ ]*"PodList"/) exit
    i = index($0, "\"items\":"); if (i == 0) exit
    s = substr($0, i + 8)
    if (s ~ /^[ ]*(\[[ ]*\]|null)/) { print "empty"; exit }
    name = "?"; phase = "?"
    if (match(s, /"name":[ ]*"[^"]*"/)) { name = substr(s, RSTART, RLENGTH); sub(/^"name":[ ]*"/, "", name); sub(/"$/, "", name) }
    if (match(s, /"phase":[ ]*"[^"]*"/)) { phase = substr(s, RSTART, RLENGTH); sub(/^"phase":[ ]*"/, "", phase); sub(/"$/, "", phase) }
    print name " " phase
  }'
}

# Seconds since the newest container `finishedAt` in the PodList on stdin, or
# nothing when it carries none. The API writes these as UTC RFC3339 with a `Z`;
# a stamp of any other shape, or out of range, is skipped, never guessed at.
training_newest_finish_age() {
  _tf_now="$(date -u +%s 2>/dev/null || true)"
  [ -n "$_tf_now" ] || return 0
  tr -d '\n' | awk -v now="$_tf_now" '{
    s = $0; best = ""
    while (match(s, /"finishedAt":[ ]*"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z"/)) {
      ts = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      sub(/^"finishedAt":[ ]*"/, "", ts)
      y = substr(ts, 1, 4) + 0; mo = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
      hh = substr(ts, 12, 2) + 0; mi = substr(ts, 15, 2) + 0; ss = substr(ts, 18, 2) + 0
      if (y < 2000 || mo < 1 || mo > 12 || d < 1 || d > 31 || hh > 23 || mi > 59 || ss > 60) continue
      if (mo <= 2) y = y - 1
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      t = (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mi * 60 + ss
      if (best == "" || t > best) best = t
    }
    if (best != "") print now - best
  }'
}

# Is the edge training? Prints one reason line; returns 0 training, 1 idle,
# 2 cannot tell. Training is a training pod that has not finished, or one that
# finished inside TRAINING_FINISHED_WINDOW_SECONDS: between two cycles of a run
# no pod runs, and jobs-manager starts the next one as soon as the cycle closes.
training_activity_verdict() {
  case "${TRAINING_FINISHED_WINDOW_SECONDS:-}" in
    ''|*[!0-9]*) echo "the finished-pod window reads '${TRAINING_FINISHED_WINDOW_SECONDS:-}', not a number of seconds"; return 2 ;;
  esac
  _tv_ns="${TRACEBLOC_RELEASE_NAMESPACE:-${RELEASE_NAMESPACE:-}}"
  [ -n "$_tv_ns" ] || { echo "neither TRACEBLOC_RELEASE_NAMESPACE nor RELEASE_NAMESPACE names the release namespace"; return 2; }
  _tv_pods="/api/v1/namespaces/${_tv_ns}/pods?labelSelector=${TRAINING_POD_SELECTOR}"
  _tv_body="$(kube_raw_get "${_tv_pods}&fieldSelector=status.phase%21%3DSucceeded%2Cstatus.phase%21%3DFailed&limit=1" 2>&1)" \
    || { echo "cannot list the training pods: $(printf '%s\n' "$_tv_body" | tail -n 1)"; return 2; }
  _tv_first="$(printf '%s' "$_tv_body" | training_pod_list_first)"
  case "$_tv_first" in
    "") echo "the training pod list read back is not a PodList"; return 2 ;;
    empty) ;;
    *) echo "training pod ${_tv_first% *} is ${_tv_first##* }"; return 0 ;;
  esac
  _tv_body="$(kube_raw_get "$_tv_pods" 2>&1)" \
    || { echo "cannot list the finished training pods: $(printf '%s\n' "$_tv_body" | tail -n 1)"; return 2; }
  [ -n "$(printf '%s' "$_tv_body" | training_pod_list_first)" ] \
    || { echo "the finished training pod list read back is not a PodList"; return 2; }
  _tv_age="$(printf '%s' "$_tv_body" | training_newest_finish_age)"
  case "$_tv_age" in ''|*[!0-9-]*) _tv_age="" ;; esac
  if [ -n "$_tv_age" ] && [ "$_tv_age" -lt "$TRAINING_FINISHED_WINDOW_SECONDS" ]; then
    echo "a training pod finished ${_tv_age}s ago, inside the ${TRAINING_FINISHED_WINDOW_SECONDS}s window (a run between two cycles)"
    return 0
  fi
  echo "no training pod is running or pending, and none finished in the last ${TRAINING_FINISHED_WINDOW_SECONDS}s"
  return 1
}

# training_gate WHAT VALUES -- 0: go ahead with WHAT; 1: WHAT is deferred and
# the caller ends the tick with exit 0, so the next scheduled tick retries.
# It defers only on training it SAW and a deferral it RECORDED: a deferral it
# cannot count is one it cannot bound, so every "cannot tell" goes ahead, as the
# job did before this gate. After VALUES.maxDeferrals in a row it goes ahead anyway.
training_gate() {
  _tg_what="$1"; _tg_values="$2"
  if [ "${TRAINING_DEFER_ENABLED:-}" != "true" ]; then
    log "${_tg_values}.enabled is not true: going ahead with $_tg_what without checking for training"
    return 0
  fi
  case "${TRAINING_DEFER_MAX:-}" in
    ''|*[!0-9]*|0)
      log "WARNING: ${_tg_values}.maxDeferrals reads '${TRAINING_DEFER_MAX:-}', not a whole number above 0, so a deferral could not be bounded: going ahead with $_tg_what"
      return 0 ;;
  esac
  _tg_rc=0
  _tg_why="$(training_activity_verdict)" || _tg_rc=$?
  case "$_tg_rc" in
    0) ;;
    1)
      log "not training ($_tg_why): going ahead with $_tg_what"
      gate_streak_clear || log "WARNING: could not clear the recorded deferral count; a stale count only brings the next backstop forward"
      return 0 ;;
    *)
      log "WARNING: cannot tell whether the edge is training ($_tg_why): going ahead with $_tg_what"
      return 0 ;;
  esac
  _tg_n=""
  if ! _tg_n="$(gate_streak_read)"; then
    log "WARNING: the edge is training ($_tg_why), but the deferral count cannot be read, so a deferral could not be bounded: going ahead with $_tg_what"
    return 0
  fi
  case "$_tg_n" in ''|*[!0-9]*) _tg_n=0 ;; esac
  if [ "$_tg_n" -ge "$TRAINING_DEFER_MAX" ]; then
    log "BACKSTOP: $_tg_what has waited $_tg_n ticks in a row for training to stop (${_tg_values}.maxDeferrals=$TRAINING_DEFER_MAX): going ahead now, although $_tg_why"
    gate_streak_clear || log "WARNING: could not clear the recorded deferral count; a stale count only brings the next backstop forward"
    return 0
  fi
  _tg_n=$((_tg_n + 1))
  if ! gate_streak_write "$_tg_n"; then
    log "WARNING: the edge is training ($_tg_why), but deferral $_tg_n could not be recorded, so it could not be bounded: going ahead with $_tg_what"
    return 0
  fi
  log "DEFERRED: $_tg_what waits, because $_tg_why (deferral $_tg_n of $TRAINING_DEFER_MAX; then it goes ahead anyway). The next tick retries."
  return 1
}
# --- defer while training: end ----------------------------------------------
{{- end -}}

{{/*
  tracebloc.trainingGateEnv -- the env tracebloc.trainingGateSh reads, from one
  `deferWhileTraining` values block. Takes (dict "gate" <block> "maxDefault" N).
*/}}
{{- define "tracebloc.trainingGateEnv" -}}
{{- $g := .gate | default dict -}}
- name: TRACEBLOC_TRAINING_DEFER_ENABLED
  value: {{ ternary "true" "false" (dig "enabled" true $g | toString | eq "true") | quote }}
- name: TRACEBLOC_TRAINING_DEFER_MAX
  value: {{ dig "maxDeferrals" .maxDefault $g | int | toString | quote }}
- name: TRACEBLOC_TRAINING_FINISHED_WINDOW_SECONDS
  value: {{ include "tracebloc.durationSeconds" (dig "finishedWithin" "10m" $g) | quote }}
{{- end -}}
