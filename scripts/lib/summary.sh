#!/usr/bin/env bash
# =============================================================================
#  summary.sh — Final success screen + cluster verification (debug only)
# =============================================================================

# Cluster status dump (debug log only).
_log_cluster_status() {
  log "--- Cluster Status ---"
  # --request-timeout so a wedged API can't hang the final summary/diagnostics
  # (|| true only swallows the exit code, not an indefinite block).
  kubectl cluster-info --request-timeout=5s >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get nodes -o wide --request-timeout=5s >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get pods -n "${TB_NAMESPACE:-default}" -o wide --request-timeout=5s >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  log "--- End Cluster Status ---"
}

# ── Readiness gate ─────────────────────────────────────────────────
# helm install only *applies* manifests; it does not wait for pods. After it
# returns we wait for the client's workloads to actually become Ready and set
# TRACEBLOC_CLIENT_STATE so the summary reports the truth instead of an unconditional
# "installed successfully":
#   connected | starting | bad_creds | image_pull | image_pull_ca | crash
# (image_pull_ca is the TLS-inspecting-network case. It was added to
# _diagnose_not_ready and not to this list; the vocabulary-agreement
# guard derives the set from the function and caught the omission.)
# Empty until wait_for_client_ready runs — so install_cleanup can distinguish an
# early failure (before the readiness gate, TRACEBLOC_CLIENT_STATE still empty) from a
# reported outcome, and still print the "check the log / safe to re-run" hint.
TRACEBLOC_CLIENT_STATE=""
# Default raised 300 -> 600 so a slow/proxied laptop pulling several GB of
# images isn't reported "not connected" while still healthily starting. Kept in
# sync with scripts/spec/facts.env (check-facts.sh); override via
# TRACEBLOC_READY_TIMEOUT (the legacy READY_TIMEOUT still works, remove_by
# 2026-12-31; a non-empty canonical wins).
if [[ -n "${TRACEBLOC_READY_TIMEOUT:-}" ]]; then READY_TIMEOUT="$TRACEBLOC_READY_TIMEOUT"; fi
READY_TIMEOUT="${READY_TIMEOUT:-600}"
# A run that would end starting with MySQL's first boot still running then waits for
# it, up to TB_MYSQL_FIRST_BOOT_STALL_S plus two progress lines more (_mysql_first_boot_settle):
# about 660 s on top of READY_TIMEOUT. TRACEBLOC_MYSQL_FIRST_BOOT_SETTLE=0 turns that off,
# for a user who asks; CI never sets it (a CI journey always runs the code path it
# checks: the tester's hard rule).

wait_for_client_ready() {
  local ns="${TB_NAMESPACE:-default}"
  _client_ready_gate "$ns" "$READY_TIMEOUT"
  # jobs-manager's wait-for-mysql gives up and backs off before a slow first boot's
  # stall, so the gate can read crash while MySQL's first boot is still running. That
  # crash, and only that one (the first boot read as running, mysql-client not
  # looping, nothing but wait-for-mysql backing off), is still starting.
  local from_crash=""
  if [[ "$TRACEBLOC_CLIENT_STATE" == crash ]] && _mysql_first_boot_running_now "$ns" \
    && ! _mysql_client_crashlooping "$ns" && _only_wait_for_mysql_backing_off "$ns"; then
    log "first boot: still running, and only jobs-manager's wait-for-mysql is backing off: still starting"
    TRACEBLOC_CLIENT_STATE=starting from_crash=1
  fi
  # Still starting with MySQL's first boot running: wait for it to end or to stall
  # (_mysql_first_boot_settle). One that ended may have let the services come up, or
  # failed, so they are read again, briefly.
  if [[ "$TRACEBLOC_CLIENT_STATE" == starting ]] \
    && { _mysql_first_boot_settle "$ns" || { [[ -n "$from_crash" && -n "$TB_MYSQL_FIRST_BOOT_GONE" ]]; }; }; then
    log "first boot: ended after the readiness gate; reading the services again for up to ${TB_MYSQL_FIRST_BOOT_RECHECK_S}s"
    _client_ready_gate "$ns" "$TB_MYSQL_FIRST_BOOT_RECHECK_S"
    # jobs-manager's wait-for-mysql init container exits 1 after a while with MySQL
    # blocked and backs off, so right after a long first boot a crash reading can be
    # that backoff alone. Only then is it read as starting; any other crash loop, or
    # pods that can't be read, keeps the crash.
    if [[ "$TRACEBLOC_CLIENT_STATE" == crash ]] && ! _mysql_client_crashlooping "$ns" \
      && { _only_wait_for_mysql_backing_off "$ns" || { sleep 2; _only_wait_for_mysql_backing_off "$ns"; }; }; then
      log "first boot: after the wait only jobs-manager's wait-for-mysql is backing off: still starting"
      TRACEBLOC_CLIENT_STATE=starting
    fi
  elif [[ -n "$from_crash" ]] && (( ${TB_MYSQL_FIRST_BOOT_SETTLED_S:-0} < TB_MYSQL_FIRST_BOOT_STALL_S )); then
    # A crash read as starting whose wait neither saw the first boot end nor reached
    # the stall (a read that could not tell): the crash stands.
    log "first boot: the wait could not tell how the first boot went: the crash stands"
    TRACEBLOC_CLIENT_STATE=crash
  fi
  return 0
}

# _only_wait_for_mysql_backing_off NS -- the containers in NS waiting in CrashLoopBackOff,
# init and app alike, are all jobs-manager's wait-for-mysql init container (and there
# is at least one). Fails closed: pods that can't be read are not "only that".
_only_wait_for_mysql_backing_off() {
  local rows name reason seen=""
  rows="$(kubectl get pods -n "$1" --request-timeout=5s \
    -o 'jsonpath={range .items[*]}{range .status.initContainerStatuses[*]}{.name} {.state.waiting.reason}{"\n"}{end}{range .status.containerStatuses[*]}{.name} {.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null)" || return 1
  while read -r name reason; do
    [[ "$reason" == CrashLoopBackOff ]] || continue
    [[ "$name" == wait-for-mysql ]] || return 1
    seen=1
  done <<<"$rows"
  [[ -n "$seen" ]]
}

# _client_ready_gate NS SECONDS -- wait up to SECONDS for the client's workloads, then
# set TRACEBLOC_CLIENT_STATE from what they show.
_client_ready_gate() {
  local ns="$1"
  # The workloads that must be Ready are READ from the release, not rebuilt from
  # the namespace: _client_workloads (common.sh) is the one helper
  # the stop-and-check gate (assess.sh) and --diagnose use too, and the
  # PowerShell installer's Get-ClientWorkloads is its guarded twin. A read that
  # cannot resolve all three is a client that is not all there, so it takes the
  # not-Ready branch below rather than waiting on names it guessed.
  # jobs-manager is the service that signs in to tracebloc, so its rollout is the
  # connection's; the others are the services starting. One result line for both:
  # "✔ Online" once jobs-manager is up, never a line for the services alone.
  local rows="" role d jm="" all_ready=true rejected=false
  local deadline=$(( $(date +%s) + $2 ))

  tb_live "Starting your services..."
  if rows="$(_client_workloads "$ns")"; then
    while read -r role d; do
      if [[ "$role" == "jobs-manager" ]]; then jm="$d"; continue; fi
      _rollout_ready "$ns" "$d" "$deadline" || { all_ready=false; break; }
    done <<<"$rows"
    if [[ "$all_ready" == true ]]; then
      tb_live_next "Connecting your secure environment..."
      if [[ -n "$jm" ]] && _rollout_ready "$ns" "$jm" "$deadline"; then
        # A crash-looping jobs-manager is Ready between restarts: Ready alone is not "Online".
        if _jobs_manager_rejected "$ns" "$jm"; then rejected=true; else tb_live_done "Online"; fi
      else
        all_ready=false
      fi
    fi
  else
    log "Could not list the secure environment's workload Deployments in namespace ${ns} (release label app.kubernetes.io/instance=${ns}); treating it as not Ready."
    all_ready=false
  fi
  tb_live_done

  _log_cluster_status
  if [[ "$all_ready" == true ]]; then
    if [[ "$rejected" == true ]]; then
      TRACEBLOC_CLIENT_STATE="bad_creds"
    else
      TRACEBLOC_CLIENT_STATE="connected"
    fi
  else
    TRACEBLOC_CLIENT_STATE="$(_diagnose_not_ready "$ns" "$jm")"
  fi
  return 0
}

# _rollout_ready NS DEPLOYMENT DEADLINE -- the Deployment rolled out before DEADLINE
# (epoch seconds; never less than 10 s from now). Its output goes to the log.
_rollout_ready() {
  local remaining=$(( $3 - $(date +%s) ))
  (( remaining >= 10 )) || remaining=10
  # </dev/null: a caller's loop reads its rows from stdin, and nothing here may eat them.
  kubectl rollout status "deployment/${2}" -n "$1" --timeout="${remaining}s" \
    </dev/null >> "${LOG_FILE:-/dev/null}" 2>&1
}

# True when jobs-manager's recent logs show the backend rejected its credentials
# (it authenticates on startup and crash-loops). `jm` is the Deployment the gate
# READ; empty is read here, and unresolvable means no logs, so false.
#
# Its api and pods-monitor containers log "Authentication failed: HTTP <code>: <body>"
# for EVERY answer of 400 or more, but client-runtime's auth.login retries 429 and
# 5xx and logs in on a later try (auth.py, `login`): a backend roll or the per-IP
# login limit is not a rejection, and reading it as one told a healthy install its
# credentials were wrong and skipped the example use case. So
# only a 4xx other than 429 counts, or the backend's wrong-password body
# ("Unable to log in with provided credentials", which older runtimes logged with no
# code).
_jobs_manager_rejected() {
  local ns="$1" jm="${2:-}" jm_logs=""
  [[ -n "$jm" ]] || jm="$(_client_workload_name "$ns" jobs-manager 5s)" || jm=""
  if [[ -n "$jm" ]]; then
    jm_logs="$(kubectl logs -n "$ns" "deployment/${jm}" --all-containers --tail=50 --request-timeout=5s 2>/dev/null || true)"
  fi
  grep -qiE 'unable to log in|authentication failed: http 4(0[0-9]|1[0-9]|2[0-8]|[3-9][0-9])([^0-9]|$)' <<<"$jm_logs"
}

# Classify why the client isn't Ready, for an accurate message. Echoes a state.
# Every match below reads a captured variable through a here-string, never a
# pipe: `grep -q` closes the pipe at its first hit, and under pipefail a
# SIGPIPE'd producer returns 141, which every `if` here would read as "no
# match" -- silently downgrading a real bad_creds/image_pull/crash diagnosis
# to "starting" and handing the user the wrong remedy.
_diagnose_not_ready() {
  local ns="$1" jm="${2:-}" pods
  if _jobs_manager_rejected "$ns" "$jm"; then
    printf 'bad_creds'; return
  fi
  pods="$(kubectl get pods -n "$ns" --request-timeout=5s 2>/dev/null || true)"
  if grep -qiE 'ImagePullBackOff|ErrImagePull|InvalidImageName' <<<"$pods"; then
    # On a TLS-inspecting network the pull fails x509 because the nodes don't trust
    # the corporate CA. Distinguish it from a generic pull error so the
    # remedy can name the CA + the env var, not a vague "retry".
    # Scope the x509 test to the image-pull failure event itself, not any stray
    # x509 event elsewhere in the ns — a stale/unrelated x509 event must not steer
    # the user into a delete+recreate for the wrong reason (reviewer). kubectl
    # prints one event per line, so an x509 on a pull-failure line is that pull.
    local events pull_fail
    events="$(kubectl get events -n "$ns" --request-timeout=5s 2>/dev/null || true)"
    pull_fail="$(printf '%s\n' "$events" | grep -iE 'failed to pull|ErrImagePull' || true)"
    if grep -qiE 'x509|certificate signed by unknown authority|tls: failed to verify' <<<"$pull_fail"; then
      printf 'image_pull_ca'; return
    fi
    printf 'image_pull'; return
  fi
  if grep -qiE 'CrashLoopBackOff' <<<"$pods"; then
    printf 'crash'; return
  fi
  printf 'starting'
}

# _mysql_first_boot_verdict NS -- "<verdict> <user_data>" from the last
# TRACEBLOC_MYSQL_FIRST_BOOT line the chart's mysql-first-boot init container
# printed (client/files/mysql-first-boot.sh): "never-served none", "incomplete
# present", ...; nothing when it printed none or cannot be read. Read through a
# here-string.
_mysql_first_boot_verdict() {
  local logs line v u
  logs="$(kubectl logs -n "$1" deployment/mysql-client -c mysql-first-boot --tail=50 --request-timeout=5s 2>/dev/null || true)"
  line="$(grep -E '^TRACEBLOC_MYSQL_FIRST_BOOT=[a-z-]+ user_data=[a-z]+$' <<<"$logs" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  v="${line#TRACEBLOC_MYSQL_FIRST_BOOT=}"; u="${v#* user_data=}"; v="${v%% *}"
  printf '%s %s' "$v" "$u"
}

# _mysql_client_crashlooping NS -- mysql-client's own container is crash-looping
# (waiting in CrashLoopBackOff, or restarted twice or more), so a crash outcome can
# be MySQL's and not another pod's.
_mysql_client_crashlooping() {
  local rows n reason
  rows="$(kubectl get pods -n "$1" -l app=mysql-client --request-timeout=5s \
    -o 'jsonpath={range .items[*]}{range .status.containerStatuses[?(@.name=="mysql-client")]}{.restartCount} {.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null || true)"
  while read -r n reason; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [[ "$reason" == CrashLoopBackOff ]] || (( n >= 2 )); then return 0; fi
  done <<<"$rows"
  return 1
}

# A first boot running this long at the end of the run is a stall, not a start: a whole
# first boot measured 6 s, and the one that stalled ran 128 s before it was killed. Ten
# minutes leaves room for slow hardware.
TB_MYSQL_FIRST_BOOT_STALL_S=600
# mysql-first-boot's progress line comes every tb_tick_s (client/files/mysql-first-boot.sh),
# counted from its own start.
TB_MYSQL_FIRST_BOOT_TICK_S=30
# With no count ever read, the wait ends after this many progress reads in a row that
# cannot tell (an unreadable log, the line pushed out of the tail, a restarted container).
TB_MYSQL_FIRST_BOOT_UNREAD_MAX=3
# After a first boot that ended during the wait, the services are read again this long.
TB_MYSQL_FIRST_BOOT_RECHECK_S=120
# The first boot's count when the wait ended with it still running; print_summary
# takes the larger of this and its own read, so a failed re-read cannot undo a stall.
TB_MYSQL_FIRST_BOOT_SETTLED_S=""
TB_MYSQL_FIRST_BOOT_GONE=""   # set by _mysql_first_boot_settle: the pods read fine and none was running
# Set by print_summary to the first boot's seconds when the run ends on that stall;
# install-k8s.sh then exits 1, so the run reads as failed (install.run.failed).
TB_MYSQL_FIRST_BOOT_STALLED=""

# client_outcome_ok -- whether the run's outcome exits 0: connected, or still starting
# without a stalled MySQL first boot (TB_MYSQL_FIRST_BOOT_STALLED, set by
# print_summary). Every other state is a failure.
client_outcome_ok() {
  case "${TRACEBLOC_CLIENT_STATE:-}" in
    connected) return 0 ;;
    starting) [[ -z "${TB_MYSQL_FIRST_BOOT_STALLED:-}" ]] ;;
    *) return 1 ;;
  esac
}

# _mysql_first_boot_running_s NS -- how long mysql-first-boot has been initialising,
# from its own "still initialising after Ns" lines, while it is still running; nothing
# otherwise. A first boot takes seconds (a whole first boot measured 6 s). A stall it
# cannot read is logged as "cannot tell" and reads as no stall: the run stays starting.
_mysql_first_boot_running_s() {
  local st
  st="$(_mysql_first_boot_started "$1")" || return 0
  [[ -n "$st" ]] || return 0
  _mysql_first_boot_count "$1" "$st"
}

# _mysql_first_boot_count NS STARTED -- the running first boot's last "still initialising
# after Ns" count, from its log; nothing, logged as "cannot tell", when it has none.
_mysql_first_boot_count() {
  local st="$2" logs line
  if ! logs="$(kubectl logs -n "$1" deployment/mysql-client -c mysql-first-boot --tail=20 --request-timeout=5s 2>/dev/null)"; then
    log "first boot: cannot tell (running since ${st}, but its log could not be read)"
    return 0
  fi
  line="$(grep -E '^mysql-first-boot: still initialising after [0-9]+s$' <<<"$logs" | tail -n 1 || true)"
  if [[ "$line" =~ after\ ([0-9]+)s$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    log "first boot: cannot tell (running since ${st}, with no progress line in its last 20 log lines)"
  fi
  return 0
}

# _mysql_first_boot_running_now NS -- the pods positively say mysql-first-boot is
# running; a read that can't tell is not.
_mysql_first_boot_running_now() {
  local st
  st="$(_mysql_first_boot_started "$1")" && [[ -n "$st" ]]
}

# _mysql_first_boot_started NS -- when the running mysql-first-boot started (an RFC 3339
# time), nothing when none is running; fails, logged as "cannot tell", when the pods
# cannot be read or answer something that is not a time.
_mysql_first_boot_started() {
  local st
  if ! st="$(kubectl get pods -n "$1" -l app=mysql-client --request-timeout=5s \
    -o 'jsonpath={range .items[*]}{range .status.initContainerStatuses[?(@.name=="mysql-first-boot")]}{.state.running.startedAt}{end}{end}' 2>/dev/null)"; then
    log "first boot: cannot tell (the mysql-client pods could not be read)"
    return 1
  fi
  if [[ -n "$st" && ! "$st" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    log "first boot: cannot tell (the mysql-client pods answered no start time)"
    return 1
  fi
  printf '%s' "$st"
}

# _mysql_first_boot_settle NS -- a first boot still running when the readiness gate
# ends is waited on until it ends, or until its own count reaches the stall, so
# print_summary can tell a stall from a slow start. The gate's READY_TIMEOUT (600 s)
# starts before mysql-first-boot does, so its count is still short of the stall when
# the gate gives up. A pod read that cannot tell keeps waiting. A progress line that
# cannot be read counts on from the last one read (by SECONDS); with none ever read,
# TB_MYSQL_FIRST_BOOT_UNREAD_MAX such reads in a row end the wait. Bounded in
# rounds and in wall time: the stall left to count, plus two progress lines.
# TRACEBLOC_MYSQL_FIRST_BOOT_SETTLE=0 turns it off. Succeeds only when the first boot
# ended during the wait, so the caller reads the services again.
_mysql_first_boot_settle() {
  local st c count="" unread=0 rounds=0 max_rounds left deadline ended="" why t0=$SECONDS last_t est
  TB_MYSQL_FIRST_BOOT_SETTLED_S="" TB_MYSQL_FIRST_BOOT_GONE=""
  if [[ "${TRACEBLOC_MYSQL_FIRST_BOOT_SETTLE:-}" == 0 ]]; then
    log "first boot: no wait after the readiness gate (TRACEBLOC_MYSQL_FIRST_BOOT_SETTLE=0)"
    return 1
  fi
  st="$(_mysql_first_boot_started "$1")" || return 1
  # Read fine, none running: it ended since the caller's check. Not a wait that
  # succeeded, so the caller decides from TB_MYSQL_FIRST_BOOT_GONE.
  [[ -n "$st" ]] || { TB_MYSQL_FIRST_BOOT_GONE=1; return 1; }
  count="$(_mysql_first_boot_count "$1" "$st")"
  last_t=$SECONDS
  if (( ${count:-0} >= TB_MYSQL_FIRST_BOOT_STALL_S )); then
    TB_MYSQL_FIRST_BOOT_SETTLED_S="$count"
    return 1
  fi
  left=$(( TB_MYSQL_FIRST_BOOT_STALL_S - ${count:-0} + 2 * TB_MYSQL_FIRST_BOOT_TICK_S ))
  max_rounds=$(( (left + TB_MYSQL_FIRST_BOOT_TICK_S - 1) / TB_MYSQL_FIRST_BOOT_TICK_S ))
  deadline=$(( SECONDS + left ))
  tb_live "Waiting for MySQL's first start..."
  _tb_animate || _tb_live_hold   # plain output: the line when the wait starts
  tb_live_detail "${count:-0}s of ${TB_MYSQL_FIRST_BOOT_STALL_S}s"
  why="the wait's bound"
  while (( rounds < max_rounds && SECONDS < deadline )); do
    sleep "$TB_MYSQL_FIRST_BOOT_TICK_S"
    rounds=$(( rounds + 1 ))
    # A pod read that cannot tell is not an ended first boot: keep waiting.
    if st="$(_mysql_first_boot_started "$1")"; then
      if [[ -z "$st" ]]; then ended=1; why="it ended"; break; fi
      if c="$(_mysql_first_boot_count "$1" "$st")" && [[ -n "$c" ]]; then
        count="$c"; unread=0; last_t=$SECONDS
      elif [[ -n "$count" ]]; then
        # The pods say it still runs but its count can't be read: it counts on
        # from the last one read.
        est=$(( count + SECONDS - last_t ))
        if (( est >= TB_MYSQL_FIRST_BOOT_STALL_S )); then
          count="$est"; why="the stall (its count estimated: the progress lines could not be read)"; break
        fi
      else
        unread=$(( unread + 1 ))
        if (( unread >= TB_MYSQL_FIRST_BOOT_UNREAD_MAX )); then why="${unread} progress reads in a row could not tell"; break; fi
      fi
      if (( ${count:-0} >= TB_MYSQL_FIRST_BOOT_STALL_S )); then why="the stall"; break; fi
    fi
    tb_live_detail "${count:-0}s of ${TB_MYSQL_FIRST_BOOT_STALL_S}s"
  done
  tb_live_done
  [[ -n "$ended" ]] || TB_MYSQL_FIRST_BOOT_SETTLED_S="$count"
  log "first boot: waited $(( SECONDS - t0 ))s after the readiness gate, until ${why}; ${count:-no}${count:+s} counted (stall at ${TB_MYSQL_FIRST_BOOT_STALL_S}s)"
  [[ -n "$ended" ]]
}

# _helm_release_revision NS -- the release's newest revision (the release is
# named after its namespace), or nothing when helm cannot say. Bounded: helm has
# no request timeout, and a wedged API must not hang the summary.
_helm_release_revision() {
  local h
  h="$(_bounded 20 helm history "$1" -n "$1" --max 1 -o json 2>/dev/null || true)"
  [[ "$h" =~ \"revision\":([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# _mysql_volume_kind NS -- how mysql-client's datadir is emptied, only when it is
# the chart's own mysql-pvc (never a mysqlClaimName claim made outside the chart):
# "claim mysql-pvc" when deleting the claim deletes its data (reclaim Delete),
# "hostpath <dir>" for the chart's Retain <release>-mysql-pv at a .../mysql path,
# nothing otherwise.
_mysql_volume_kind() {
  local claim pv row path
  claim="$(kubectl get deployment mysql-client -n "$1" --request-timeout=5s \
    -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="mysql-persistent-storage")].persistentVolumeClaim.claimName}' 2>/dev/null || true)"
  [[ "$claim" == mysql-pvc ]] || return 0
  pv="$(kubectl get pvc mysql-pvc -n "$1" -o 'jsonpath={.spec.volumeName}' --request-timeout=5s 2>/dev/null || true)"
  [[ -n "$pv" ]] || return 0
  row="$(kubectl get pv "$pv" -o 'jsonpath={.spec.persistentVolumeReclaimPolicy} {.spec.hostPath.path}' --request-timeout=5s 2>/dev/null || true)"
  path="${row#* }"
  case "$row" in
    "Delete "*) printf 'claim mysql-pvc' ;;
    "Retain /"*)
      if [[ "$pv" == *-mysql-pv && "$path" == /*/mysql && "$path" != *[[:space:]\'\"\\]* ]]; then
        printf 'hostpath %s' "$path"
      fi ;;
  esac
  return 0
}

# _mysql_incomplete_summary NS VERDICT USER_DATA -- the crash outcome when MySQL's
# first start was stopped part-way and its datadir cannot start (MY-012960), which a
# re-run does not repair: mysql-pvc is kept. Reset steps only when the datadir holds
# no user data AND either its redo log says MySQL never finished creating it
# (never-served: no server ever ran on it, at any revision) or the release is at
# revision 1. Nothing is run here.
_mysql_incomplete_summary() {
  local ns="$1" verdict="$2" user_data="$3" rev kind steps=""
  echo -e "  ${TB_ERR}✖ Setup didn't finish — MySQL's first start was stopped before it finished, and its files are incomplete.${RESET}" >&2
  echo ""
  echo -e "  MySQL can't start on those files, and re-running the installer doesn't repair them."
  rev="$(_helm_release_revision "$ns")"
  kind="$(_mysql_volume_kind "$ns")"
  if [[ "$user_data" == none && -n "$kind" ]] && [[ "$verdict" == never-served || "$rev" == 1 ]]; then steps=1; fi
  if [[ -n "$steps" ]]; then
    echo -e "  MySQL never finished setting up this database, so it holds no data yet. Reset it, then re-run the installer:"
    echo -e "    ${TB_CMD}$(tb_kubectl_shown) -n ${ns} scale deploy/mysql-client --replicas=0${RESET}"
    if [[ "$kind" == claim* ]]; then
      echo -e "    ${TB_CMD}$(tb_kubectl_shown) -n ${ns} delete pvc mysql-pvc${RESET}"
    else
      echo -e "    ${TB_CMD}sudo find '${kind#hostpath }' -mindepth 1 -delete${RESET}"
    fi
  else
    echo -e "  The installer doesn't reset it, because it may hold your data. Contact tracebloc support."
  fi
  echo -e "  Logs:     ${TB_CMD}$(tb_kubectl_shown) logs -n ${ns} deploy/mysql-client -c mysql-first-boot${RESET}"
}

# _crash_or_pull_summary NS -- the image_pull and crash outcomes, but for the one
# _mysql_incomplete_summary names.
_crash_or_pull_summary() {
  local reason="a component didn't start"
  [[ "$TRACEBLOC_CLIENT_STATE" == "image_pull" ]] && reason="an image couldn't be pulled"
  [[ "$TRACEBLOC_CLIENT_STATE" == "crash" ]] && reason="a container is restarting (crash loop)"
  echo -e "  ${TB_ERR}✖ Setup didn't finish — ${reason}.${RESET}" >&2
  echo ""
  echo -e "  Inspect:  ${TB_CMD}$(tb_kubectl_shown) get pods -n ${1}${RESET}"
  echo -e "  Logs:     ${DIM}~/.tracebloc/install-*.log${RESET}"
  echo -e "  ${DIM}Re-running this installer is safe.${RESET}"
}

# Reports the outcome based on TRACEBLOC_CLIENT_STATE (set by wait_for_client_ready).
# The "secure compute environment / your data never leaves" claim is printed
# ONLY when the client is verifiably connected — never on a partial/failed run.
# One-line note in the success summary so the user knows how the client comes
# back after a reboot: the last line of the summary, in dim.
# On Linux k3s's install enables the k3s service on boot, and the node is this host.
# On a Mac the node is a VM, and the login item io.tracebloc.node brings it back at
# login (mac-container.sh, LimitLoadToSessionType Aqua).
_reboot_note() {
  if [[ "$OS" == "Darwin" ]]; then
    echo -e "  ${DIM}After a restart, tracebloc comes back when you log in: the login item ${TB_MAC_CT_AGENT_LABEL:-io.tracebloc.node} starts it.${RESET}"
  else
    echo -e "  ${DIM}After a reboot, tracebloc restarts automatically with the k3s service (check it with: systemctl status k3s).${RESET}"
  fi
}

# _summary_kubeconfig_hint -- the merged kubeconfig a native k3s user must name, with
# $HOME as ~ for them to type, or NO OUTPUT when there is none. Native k3s links
# kubectl to k3s, and with no KUBECONFIG that kubectl reads k3s's own k3s.yaml
# (context default, no namespace), never the merged file.
# _native_k3s_merge_kubeconfig sets the hint only when the user had no KUBECONFIG.
#
# It always exits 0; callers test the output (`[[ -n "$kc" ]]`). A "no hint" exit 1
# was recorded as a failure by the installer's ERR trap: `set -E` carries the trap
# into the `$(...)` of `if kc="$(...)"`, where the status is not in a condition, so
# every successful install without a hint logged `err: … summary.sh … cmd=return 1`
# after its success screen.
_summary_kubeconfig_hint() {
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && -n "${TB_K3S_KUBECONFIG_HINT:-}" ]]; then
    local kc="$TB_K3S_KUBECONFIG_HINT"
    # shellcheck disable=SC2088  # the ~ is for the user to read, as in logdisp below
    if [[ -n "${HOME:-}" && "$kc" == "$HOME"/* ]]; then kc="~${kc#"$HOME"}"; fi
    printf '%s' "$kc"
  fi
  return 0
}

# _summary_kubeconfig_lines -- the export line for _summary_kubeconfig_hint's file, or
# nothing. Callers place it, so they read it into a variable first.
_summary_kubeconfig_lines() {
  local kc
  kc="$(_summary_kubeconfig_hint)"
  [[ -n "$kc" ]] || return 0
  echo -e "  To use kubectl here, run this in your shell (add it to your profile to keep it):"
  echo -e "    ${TB_CMD}export KUBECONFIG=${kc}${RESET}"
}

# Will `tracebloc` resolve in the user's shell? Rely SOLELY on TB_CLI_USABLE_NOW,
# which install-cli.sh sets from a FRESH-shell probe (_cli_on_fresh_path). A
# `has tracebloc` fallback would be WRONG here: install.sh and provision.sh both
# prepend ~/.local/bin to THIS process's PATH, so the installer can resolve
# tracebloc even when the user's launching shell cannot — exactly the
# "command not found in a new terminal" case B2 exists to catch.
# Unset (a stale bootstrap that skipped the CLI step) → treat as not-usable and
# tell the user to open a new terminal: the safe, honest default.
_cli_runnable_now() {
  [[ "${TB_CLI_USABLE_NOW:-0}" == "1" ]]
}

# ── The training parent prepull (slim client B.13) ─────────────────────────────
#
# Every GPU training image builds FROM one shared torch parent, about 4 GiB of its
# 4.2-4.5 GiB, and on a fresh host the first GPU training pulls all of it as part of
# its own start. The chart carries a Job that pulls only that parent, as data: ConfigMap
# <release>-training-prepull (client/templates/training-prepull-configmap.yaml), which
# renders only where the chart pins the training images (tracebloc.trainingParentPin).
# This step applies that Job once the control plane is ready, so the 4 GiB pull never
# shares the link with the control plane's own pulls, and returns without waiting.
#
# It stops, with one log line naming the reason, when the host is not GPU-wired,
# TRACEBLOC_SKIP_TRAINING_PREPULL is set, the ConfigMap is absent or unreadable, the
# host's platform is not one the parent is published for, the image store's path cannot
# be told, or the disk rule (_prepull_disk_rule) fails. It never fails the install and
# never waits on the pull: a pull that cannot finish waits out the Job's own deadline.
#
# The Job lives in the release namespace and deletes itself after its TTL; the image
# lives in the substrate's store, which the substrate's own removal deletes. So the
# install record gains nothing.

# The component label the chart puts on the ConfigMap: how it is found. Its name is
# <fullname>-training-prepull, and fullname follows fullnameOverride, so the label is
# the one handle that does not move with it.
TB_PREPULL_COMPONENT="training-prepull"
# The bound on each of this step's calls: the two cluster reads, the apply, and the
# disk rule's df (a wedged mount under the store must not hang the install either).
TB_PREPULL_CALL_S=10
# The step's verdict, for print_summary: empty until it runs, then `applied` or
# `skipped` (the reason is in the install log).
TB_PREPULL_VERDICT=""

# _prepull_substrate -- the substrate key the two calls below take: mac-node for
# native k3s in its VM on a Mac (the node, not the Mac, holds the store), else
# TRACEBLOC_SUBSTRATE_RESOLVED.
_prepull_substrate() {
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == k3s && "${OS:-}" == Darwin ]]; then
    printf 'mac-node'
  else
    printf '%s' "${TRACEBLOC_SUBSTRATE_RESOLVED:-}"
  fi
}

# _prepull_store_path SUBSTRATE -- the directory whose filesystem holds SUBSTRATE's
# image store. Native k3s keeps them in its containerd root, TB_K3S_DATA_PATH/agent/containerd:
# the kubelet's image filesystem, which a mount of its own can put on another disk
# than the data path (preflight measures it there too, _pf_disk_k3s). The macOS node
# keeps its own inside the node, on the volume _mac_ct_node_argv mounts at
# /var/lib/rancher/k3s. Exit 1, printing nothing, for any other substrate (main()
# refuses every other one before this step): the caller skips it by name.
_prepull_store_path() {
  case "$1" in
    k3s) printf '%s' "${TB_K3S_DATA_PATH}/agent/containerd" ;;
    mac-node) printf '%s' "/var/lib/rancher/k3s/agent/containerd" ;;
    *) return 1 ;;
  esac
}

# _prepull_df SUBSTRATE DIR -- `df -Pk DIR`, bounded by TB_PREPULL_CALL_S. Native
# k3s's store sits below its agent/ directory, which k3s creates 0700
# (pkg/agent/run.go), so this user's df cannot reach it: it is read as root, as
# preflight reads it, and only when root answers without a password prompt -- this
# step never asks for one (exit 3). No fallback to the data path: that would measure
# another filesystem in exactly the case the store has its own, and a skipped prepull
# costs only the first training's pull. The macOS node's store is read inside the
# node (`container exec`), as the kubelet there sees it; exit 1 when the node cannot
# be named. Exit 124 when df did not answer in time.
_prepull_df() {
  local root name
  if [[ "$1" == k3s ]]; then
    _native_k3s_root_ready || return 3
    _bounded_root "$TB_PREPULL_CALL_S" df -Pk "$2"
  elif [[ "$1" == mac-node ]]; then
    declare -F _mac_ct_install_root _mac_ct_node_name >/dev/null 2>&1 || return 1
    root="$(_mac_ct_install_root 2>/dev/null)" && name="$(_mac_ct_node_name 2>/dev/null)" || return 1
    _bounded "$TB_PREPULL_CALL_S" "${root}/bin/container" exec "$name" df -Pk "$2" </dev/null
  else
    _bounded "$TB_PREPULL_CALL_S" df -Pk "$2"
  fi
}

# _prepull_disk_rule DIR [SUBSTRATE [GB [WHAT]]] -- 0 when DIR's filesystem can take GB, the
# footprint of WHAT (default: the parent's, TB_PREPULL_PARENT_DISK_GB, stamped from
# facts.env) and still hold both:
# its use stays below the kubelet's image GC threshold
# (TB_KUBELET_IMAGE_GC_HIGH_PERCENT, the value the installer writes into the kubelet
# config: past it the kubelet collects images nothing references, the parent first),
# and at least PF_WARN_DISK_GB stays free (preflight's floor). Prints one line with
# the numbers either way: the free GB now and after, the threshold, DIR. Exit 1 when
# the rule fails, 2 when df cannot tell: it did not answer in time, root could not
# be asked without a prompt (k3s), or its answer was not numbers. SUBSTRATE decides
# how DIR is read (_prepull_df).
_prepull_disk_rule() {
  local dir="$1" gb="${3:-$TB_PREPULL_PARENT_DISK_GB}" what="${4:-the parent}"
  local sizes="" total_kb="" avail_kb="" need_kb after_kb pct_after rc=0
  sizes="$(_prepull_df "${2:-}" "$dir" 2>/dev/null)" || rc=$?
  case "$rc" in
    124|137) printf 'df did not answer within %ss on %s' "$TB_PREPULL_CALL_S" "$dir"; return 2 ;;
    3) printf 'root could not be asked without a password prompt to read %s (k3s keeps it below a 0700 directory), and this step never prompts' "$dir"; return 2 ;;
  esac
  sizes="$(printf '%s\n' "$sizes" | awk 'NR==2 {print $2, $4}')"
  read -r total_kb avail_kb <<<"$sizes" || true
  case "${total_kb}${avail_kb}" in
    ''|*[!0-9]*) printf 'df could not tell the free space on %s' "$dir"; return 2 ;;
  esac
  if [[ -z "$avail_kb" || "$total_kb" -eq 0 ]]; then printf 'df could not tell the free space on %s' "$dir"; return 2; fi
  need_kb=$(( gb * 1024 * 1024 ))
  after_kb=$(( avail_kb - need_kb ))
  # The kubelet's measure: used = capacity - available, as a share of capacity,
  # rounded up so the rule never reads a filesystem as emptier than it is.
  pct_after=$(( ( (total_kb - after_kb) * 100 + total_kb - 1 ) / total_kb ))
  printf '%s GB free on %s, %s GB after %s (about %s GB): %s%% used against the kubelet image GC threshold of %s%%, with a floor of %s GB free' \
    "$(( avail_kb / 1024 / 1024 ))" "$dir" "$(( after_kb / 1024 / 1024 ))" "$what" "$gb" \
    "$pct_after" "$TB_KUBELET_IMAGE_GC_HIGH_PERCENT" "$PF_WARN_DISK_GB"
  [[ "$pct_after" -lt "$TB_KUBELET_IMAGE_GC_HIGH_PERCENT" ]] || return 1
  [[ "$after_kb" -ge $(( PF_WARN_DISK_GB * 1024 * 1024 )) ]] || return 1
  return 0
}

# _prepull_host_platform -- this host's platform as an image index spells it
# (linux/amd64).
_prepull_host_platform() {
  printf '%s/%s' "$(printf '%s' "${OS:-$(uname -s)}" | tr '[:upper:]' '[:lower:]')" "$ARCH_DL"
}

# _prepull_platform_listed PLATFORM LIST -- 0 when PLATFORM is in LIST, the
# ConfigMap's comma-joined platforms. An entry with a variant (linux/arm64/v8) lists
# the platform it is a variant of.
_prepull_platform_listed() {
  case ",$2," in
    *",$1,"*|*",$1/"*) return 0 ;;
  esac
  return 1
}

# _prepull_job_image MANIFEST -- the image of MANIFEST's container named prepull. The
# GPU pod's first container pulls the CLI's stage image (training-prepull-configmap.yaml),
# and the log names the big download, not that one. The quotes and blanks around the
# reference go by keeping only the characters a reference is made of.
_prepull_job_image() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*prepull[[:space:]]*$/ { f = 1; next }
    f && /^[[:space:]]*-[[:space:]]*name:/ { f = 0 }
    f && !done && /^[[:space:]]*image:/ { sub(/^[[:space:]]*image:[[:space:]]*/, ""); gsub(/[^A-Za-z0-9._:\/@-]/, ""); print; done = 1 }'
}

# _prepull_skip REASON -- the one log line for a stop, and the verdict.
_prepull_skip() {
  TB_PREPULL_VERDICT="skipped"
  log "training prepull: skipped: $1"
}

# _prepull_training_parent -- the step. Runs from main() after the example use case
# and before print_summary; returns 0 always.
_prepull_training_parent() {
  local ns="${TB_NAMESPACE:-default}" out rc=0 name="" platforms="" manifest host store disk image sub gb what="the parent"
  log "training prepull: start"
  if ! _gpu_wired; then _prepull_skip "not GPU-wired (only the GPU training images build FROM the torch parent)"; return 0; fi
  if [[ -n "${TRACEBLOC_SKIP_TRAINING_PREPULL:-}" ]]; then _prepull_skip "TRACEBLOC_SKIP_TRAINING_PREPULL is set"; return 0; fi
  out="$(_bounded "$TB_PREPULL_CALL_S" kubectl get configmap -n "$ns" -l "app.kubernetes.io/component=${TB_PREPULL_COMPONENT}" \
    --request-timeout="${TB_PREPULL_CALL_S}s" \
    -o 'go-template={{range .items}}{{.metadata.name}}{{"\t"}}{{index .data "platforms"}}{{"\n"}}{{end}}' 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_skip "the ${TB_PREPULL_COMPONENT} ConfigMap could not be read in namespace ${ns} (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  if [[ -z "$out" ]]; then _prepull_skip "nothing is pinned for this edge (no ${TB_PREPULL_COMPONENT} ConfigMap in namespace ${ns})"; return 0; fi
  if [[ "$out" == *$'\n'* ]]; then _prepull_skip "more than one ${TB_PREPULL_COMPONENT} ConfigMap in namespace ${ns}, so which one to apply cannot be told"; return 0; fi
  IFS=$'\t' read -r name platforms <<<"$out" || true
  if [[ -z "$name" || -z "$platforms" ]]; then
    _prepull_skip "the ${TB_PREPULL_COMPONENT} ConfigMap in namespace ${ns} names no platforms, so whether this host can run the image cannot be told"; return 0
  fi
  host="$(_prepull_host_platform)"
  if ! _prepull_platform_listed "$host" "$platforms"; then
    _prepull_skip "this host is ${host}, and the parent is published for ${platforms} only"; return 0
  fi
  sub="$(_prepull_substrate)"
  if ! store="$(_prepull_store_path "$sub")"; then
    _prepull_skip "substrate '${sub}' has no image store this step knows"; return 0
  fi
  # A CPU image the earlier step applied may still be downloading into the same store.
  gb="$TB_PREPULL_PARENT_DISK_GB"
  if [[ "${TB_PREPULL_CPU_VERDICT:-}" == applied ]]; then
    gb=$(( gb + TB_PREPULL_CPU_DISK_GB )); what="the parent and the CPU training image downloading beside it"
  fi
  rc=0; disk="$(_prepull_disk_rule "$store" "$sub" "$gb" "$what")" || rc=$?
  case "$rc" in
    0) log "training prepull: disk: $disk" ;;
    1) _prepull_skip "the disk rule fails: $disk"; return 0 ;;
    *) _prepull_skip "the disk rule cannot tell: $disk"; return 0 ;;
  esac
  rc=0
  manifest="$(_bounded "$TB_PREPULL_CALL_S" kubectl get configmap "$name" -n "$ns" --request-timeout="${TB_PREPULL_CALL_S}s" \
    -o 'go-template={{index .data "job.yaml"}}' 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 || "$manifest" != *"kind: Job"* ]]; then
    _prepull_skip "ConfigMap ${name} carries no Job manifest that could be read (kubectl exit ${rc})"; return 0
  fi
  image="$(_prepull_job_image "$manifest")"
  rc=0
  out="$(printf '%s\n' "$manifest" | _bounded "$TB_PREPULL_CALL_S" kubectl apply -n "$ns" --request-timeout="${TB_PREPULL_CALL_S}s" -f - 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_skip "the Job in ConfigMap ${name} could not be applied (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  TB_PREPULL_VERDICT="applied"
  log "training prepull: applied: ${out%%$'\n'*} (${image:-?}, about ${TB_PREPULL_PARENT_DISK_GB} GB on disk); not waiting for it"
  info "Downloading the GPU training base image in the background (${image:-?}, about ${TB_PREPULL_PARENT_DISK_GB} GB on disk)."
  return 0
}

# ── The CPU training image prepull ────────────────────────────────────────────
#
# A CPU training pod pulls its whole image as part of its start, about 0.7 GB
# compressed, so the first training on a fresh host, and the first after its
# floating tag moved, waits minutes in ContainerCreating. The chart carries a Job
# that pulls the tabular classification CPU image at the reference the jobs-manager
# spawns (client/templates/training-prepull-cpu-configmap.yaml), on every edge.
# This step applies it right after readiness, before the example use case whose first
# training runs on it, on any host, and returns without waiting. It stops, with one log line, when TRACEBLOC_SKIP_TRAINING_PREPULL is set,
# the ConfigMap is absent or unreadable, the image store's path cannot be told, or
# the disk rule fails; it never fails the install and prints nothing on the screen.
TB_PREPULL_CPU_COMPONENT="training-prepull-cpu"
# The step's verdict: `applied` or `skipped`. _prepull_training_parent reads it, since
# an applied image may still be downloading into the store the parent's would share.
TB_PREPULL_CPU_VERDICT=""

# _prepull_cpu_skip REASON -- the one log line for a stop, and the verdict.
_prepull_cpu_skip() {
  TB_PREPULL_CPU_VERDICT="skipped"
  log "training prepull (cpu): skipped: $1"
}

# _prepull_training_cpu -- the step. Runs from main() right after
# wait_for_client_ready and before setup_example_use_case. Returns 0 always.
_prepull_training_cpu() {
  local ns="${TB_NAMESPACE:-default}" out rc=0 name manifest store disk image sub job
  log "training prepull (cpu): start"
  if [[ -n "${TRACEBLOC_SKIP_TRAINING_PREPULL:-}" ]]; then _prepull_cpu_skip "TRACEBLOC_SKIP_TRAINING_PREPULL is set"; return 0; fi
  out="$(_bounded "$TB_PREPULL_CALL_S" kubectl get configmap -n "$ns" -l "app.kubernetes.io/component=${TB_PREPULL_CPU_COMPONENT}" \
    --request-timeout="${TB_PREPULL_CALL_S}s" -o 'go-template={{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_cpu_skip "the ${TB_PREPULL_CPU_COMPONENT} ConfigMap could not be read in namespace ${ns} (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  if [[ -z "$out" ]]; then _prepull_cpu_skip "no ${TB_PREPULL_CPU_COMPONENT} ConfigMap in namespace ${ns} (a chart that carries none)"; return 0; fi
  if [[ "$out" == *$'\n'* ]]; then _prepull_cpu_skip "more than one ${TB_PREPULL_CPU_COMPONENT} ConfigMap in namespace ${ns}, so which one to apply cannot be told"; return 0; fi
  name="$out"; sub="$(_prepull_substrate)"
  if ! store="$(_prepull_store_path "$sub")"; then
    _prepull_cpu_skip "substrate '${sub}' has no image store this step knows"; return 0
  fi
  rc=0; disk="$(_prepull_disk_rule "$store" "$sub" "$TB_PREPULL_CPU_DISK_GB" "the CPU training image")" || rc=$?
  case "$rc" in
    0) log "training prepull (cpu): disk: $disk" ;;
    1) _prepull_cpu_skip "the disk rule fails: $disk"; return 0 ;;
    *) _prepull_cpu_skip "the disk rule cannot tell: $disk"; return 0 ;;
  esac
  rc=0
  manifest="$(_bounded "$TB_PREPULL_CALL_S" kubectl get configmap "$name" -n "$ns" --request-timeout="${TB_PREPULL_CALL_S}s" \
    -o 'go-template={{index .data "job.yaml"}}' 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 || "$manifest" != *"kind: Job"* ]]; then
    _prepull_cpu_skip "ConfigMap ${name} carries no Job manifest that could be read (kubectl exit ${rc})"; return 0
  fi
  image="$(_prepull_job_image "$manifest")"
  job="$(printf '%s\n' "$manifest" | awk '!done && /^  name:[[:space:]]/ { sub(/^  name:[[:space:]]*/, ""); print; done = 1 }')"
  if [[ -z "$job" ]]; then _prepull_cpu_skip "the Job in ConfigMap ${name} names no Job"; return 0; fi
  # The Job's name is one for every pin and tag: the previous run's goes first, so a new
  # pin never meets an immutable template and a moved tag is pulled again (Always).
  rc=0
  _bounded "$TB_PREPULL_CALL_S" kubectl delete job "$job" -n "$ns" --ignore-not-found --request-timeout="${TB_PREPULL_CALL_S}s" >/dev/null 2>>"${LOG_FILE:-/dev/null}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_cpu_skip "the previous Job ${job} could not be deleted (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  rc=0
  out="$(printf '%s\n' "$manifest" | _bounded "$TB_PREPULL_CALL_S" kubectl apply -n "$ns" --request-timeout="${TB_PREPULL_CALL_S}s" -f - 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_cpu_skip "the Job in ConfigMap ${name} could not be applied (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  TB_PREPULL_CPU_VERDICT="applied"
  log "training prepull (cpu): applied: ${out%%$'\n'*} (${image:-?}, about ${TB_PREPULL_CPU_DISK_GB} GB on disk); not waiting for it"
  return 0
}

# _prepull_summary_line -- the GPU step's verdict, under Mode, on a GPU-wired host only:
# a CPU host has no GPU images to download ahead, and the line would be noise there.
_prepull_summary_line() {
  _gpu_wired || return 0
  case "${TB_PREPULL_VERDICT:-}" in
    applied) _summary_row "GPU images" "downloading in the background" ;;
    skipped) _summary_row "GPU images" "not downloaded yet; your first GPU training downloads them (the install log says why)" ;;
  esac
  return 0
}

# _summary_log_dir -- the folder this run's log is in (LOG_FILE), the home folder as ~;
# nothing when the run keeps no log file.
_summary_log_dir() {
  local f="${LOG_FILE:-}" d
  [[ "$f" == /* && -f "$f" ]] || return 0
  d="${f%/*}"; d="${d:-/}"
  if [[ -n "${HOME:-}" && ( "$d" == "$HOME" || "$d" == "$HOME"/* ) ]]; then d="~${d#"$HOME"}"; fi
  printf '%s' "$d"
}

# _summary_row LABEL VALUE -- one row of the connected summary, the values in a column.
_summary_row() {
  printf '  %b%-15s%b%s\n' "${TB_LABEL}" "$1" "${RESET}" "$2"
}

# _summary_machine_rows NAMESPACE VERSION MODE -- the summary's rows in the grammar
# machines read (e2e's summary questions, the Windows cell), never a person's screen.
_summary_machine_rows() {
  local ns="$1" cver="$2" mode="$3"
  echo -e "  ${TB_LABEL}Environment${RESET} : ${ns}"
  echo -e "  ${TB_LABEL}Version${RESET}     : ${cver}"
  echo -e "  ${TB_LABEL}Mode${RESET}        : ${mode}"
}

# _summary_footer LOGDISP NAMESPACE -- where the logs and the data are, and how the
# client comes back after a restart. The connected summary hands it to the log.
_summary_footer() {
  local logdisp="$1" ns="$2" kdata jdata
  # Data location depends on the storage model: hostpath names the host folder
  # the volumes use; node-local keeps them in k3s local-path,
  # on this host or in the macOS node's own volume.
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${TB_STORAGE_MODE:-node-local}" == "hostpath" ]]; then
    # Native k3s, hostpath: the PVs name the host directory itself.
    # The macOS node mounts that folder at its own path, so the same line holds there.
    kdata="$(_hostpath_root)"
    echo "Logs ${logdisp}  ·  Data ${kdata}/${ns} (hostPath)"
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "$OS" == "Darwin" ]]; then
    # The macOS node: job data in the job-data folder on this Mac when the release
    # keeps one, the rest inside the node, on its own volume.
    jdata=""
    if declare -F _mac_ct_job_data_dir >/dev/null; then jdata="$(_mac_ct_job_data_dir)"; fi
    if [[ -n "$jdata" ]]; then
      echo "Logs ${logdisp}  ·  Job data ${jdata}/${ns} (on this Mac, private to you)"
    else
      echo "Logs ${logdisp}  ·  Data in the volume of the VM that runs tracebloc on this Mac (k3s local-path)"
    fi
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    # Native k3s: the volumes are on this host, in local-path's storage path.
    # The reader answers 2 or 3 (config.yaml unreadable; sudo expired after a long
    # install) with nothing on stdout: say where the data is only when it told us.
    kdata="$(_native_k3s_storage_path)" || kdata=""
    if [[ -n "$kdata" ]]; then
      echo "Logs ${logdisp}  ·  Data ${kdata} (k3s local-path)"
    else
      echo "Logs ${logdisp}  ·  Data in k3s local-path on this host"
    fi
  fi
  _reboot_note
}

print_summary() {
  # NVIDIA "GPU mode" only when the GPU was actually WIRED into the cluster
  # (_gpu_wired) — a detected-but-not-wired GPU runs CPU-only, and printing
  # "NVIDIA GPU" there is exactly the false claim the CPU-fallback rule removes. AMD keys on
  # detection.
  # training: the summary's Training row, the device a person reads; mode: the Mode line
  # a machine reads (tb_machine_lines), which says when the Apple GPU takes a job.
  local mode="CPU" training=""
  if _gpu_wired; then
    mode="NVIDIA GPU"
    # Native k3s: the runtime is wired, but the node advertised no GPU after the
    # install (k3s.sh _native_k3s_gpu_verify, which warned with the remedy).
    [[ -z "${TB_K3S_GPU_UNCONFIRMED:-}" ]] || mode="NVIDIA GPU, not confirmed (see the GPU warning above)"
  elif [[ "$GPU_VENDOR" == "amd" ]]; then
    mode="AMD GPU"
  elif [[ "${TRACEBLOC_MAC_GPU_RUNNER_READY:-}" == 1 ]]; then
    # The runner's login item is loaded over the job-data folder (mac-container.sh
    # _mac_ct_runner_gpu_ready); a job trains on the GPU only once its check passes.
    mode="Apple GPU once it passes tracebloc's GPU check, CPU until then (tracebloc resources shows which)"
    training="Apple GPU"
  elif [[ "${TRACEBLOC_MAC_GPU_TRAINING_OFF:-}" == 1 ]]; then
    # The runner is ready, but the chart sends it no GPU training (mac-container.sh
    # _mac_ct_runner_gpu_ready, _mac_ct_runner_bundle_rendered): every training runs on the CPU.
    training="CPU (GPU training on Macs is off for now)"
  fi
  local ns="${TB_NAMESPACE:-default}"
  local cver; cver="$(_chart_version "$ns")"
  # Footer log path: HOST_DATA_DIR with $HOME collapsed to ~ (e.g. ~/.tracebloc).
  local logdisp="${HOST_DATA_DIR:-$HOME/.tracebloc}"
  local kc="" machine="${_TB_MACHINE_NAME:-}" logdir
  if [[ -n "${HOME:-}" && "$logdisp" == "$HOME"* ]]; then logdisp="~${logdisp#"$HOME"}"; fi
  logdir="$(_summary_log_dir)"
  # The machine's name as registered this run (provision.sh), else this host's.
  if [[ -z "$machine" ]] && declare -F _host_machine_name >/dev/null 2>&1; then
    machine="$(_host_machine_name)"
  fi

  echo ""
  case "$TRACEBLOC_CLIENT_STATE" in
    connected)
      tb_rule
      echo ""
      echo -e "  ${TB_GO}✔${RESET} ${BOLD}tracebloc is ready${RESET}"
      echo ""
      echo -e "  Your secure environment is running and online."
      echo ""
      _summary_row "Environment" "$ns"
      [[ -z "$machine" ]] || _summary_row "Machine" "$machine"
      [[ -z "${_TB_COMPUTE_SHOWN:-}" ]] || _summary_row "Compute" "$_TB_COMPUTE_SHOWN"
      _summary_row "Training" "${training:-$mode}"
      _summary_row "Status" "Online"
      _prepull_summary_line
      [[ -z "$logdir" ]] || _summary_row "Logs" "$logdir"
      # What machines read off this screen (e2e's summary questions): see tb_machine_lines.
      tb_machine_lines _summary_machine_rows "$ns" "${cver:-unknown}" "$mode"
      echo ""
      echo ""
      # The first-install steps are for a first install only (tb_upgrade_run).
      if tb_upgrade_run; then
        echo -e "  ${BOLD}Upgrade complete${RESET} — ${TB_DESC}your data and use cases are unchanged.${RESET}"
      else
        echo -e "  ${TB_HEADING}What's next?${RESET}"
        echo ""
        # Opened already (open_dashboard_link, before this summary), or for the person
        # to open: no browser here (SSH, a headless machine) or nobody at a terminal.
        if [[ -n "${_TB_DASHBOARD_OPENED:-}" ]]; then
          echo -e "  1. Your dashboard (opened in your browser)"
        else
          echo -e "  1. Open your dashboard"
        fi
        echo -e "     ${TB_LINK}$(_dashboard_url)${RESET}"
        echo ""
        echo -e "  2. Ingest your own data"
        echo -e "     ${TB_CMD}tracebloc data ingest${RESET}"
        echo ""
        echo -e "  3. Create a use case"
        echo -e "     ${TB_LINK}$(_dashboard_url 'use-cases?create=1')${RESET}"
        echo ""
        echo -e "  4. Invite peers"
        echo -e "     ${TB_DESC}Let others train models on your data${RESET}"
        echo -e "     ${TB_DESC}without sharing your datasets.${RESET}"
      fi
      echo ""
      echo ""
      if _cli_runnable_now; then
        echo -e "  Run ${TB_CMD}\`tracebloc\`${RESET} to manage your secure environment."
      elif [[ "${TRACEBLOC_CLI_ON_FRESH_PATH:-}" == "0" ]]; then
        # Case B: install-cli.sh RAN and set the flag to 0 — it printed the EXACT
        # PATH fix above and a new terminal won't help. The explicit "0" test matters:
        # an UNSET flag (CLI step skipped/failed → nothing printed above) must NOT
        # land here, or "see above" points at nothing.
        echo -e "  Add tracebloc to your PATH (see above), then run ${TB_CMD}\`tracebloc\`${RESET} to manage your secure environment."
      else
        # Case A (flag=1: installed to ~/.local/bin, persisted — a new terminal
        # resolves it, only this shell doesn't) OR the flag is UNSET (the CLI step
        # was skipped/failed): the safe, honest default is "open a new terminal".
        echo -e "  Open a new terminal, then run ${TB_CMD}\`tracebloc\`${RESET} to manage your secure environment."
      fi
      echo ""
      kc="$(_summary_kubeconfig_lines)"
      if [[ -n "$kc" ]]; then tb_machine_lines printf '%s\n\n' "$kc"; fi
      tb_rule
      # Where the logs and data are, and how it comes back after a restart: the log's.
      _summary_footer "$logdisp" "$ns" >>"${LOG_FILE:-/dev/null}" 2>&1
      ;;
    starting)
      # A first boot past TB_MYSQL_FIRST_BOOT_STALL_S is a stall, and the run fails on it.
      local fbs
      fbs="$(_mysql_first_boot_running_s "$ns")"
      if [[ -n "${TB_MYSQL_FIRST_BOOT_SETTLED_S:-}" ]] && (( TB_MYSQL_FIRST_BOOT_SETTLED_S > ${fbs:-0} )); then
        fbs="$TB_MYSQL_FIRST_BOOT_SETTLED_S"
      fi
      log "first boot: ${fbs:-none}${fbs:+s} running at the end of the run (stall at ${TB_MYSQL_FIRST_BOOT_STALL_S}s)"
      if [[ -n "$fbs" ]] && (( fbs >= TB_MYSQL_FIRST_BOOT_STALL_S )); then
        TB_MYSQL_FIRST_BOOT_STALLED="$fbs"
        echo -e "  ${TB_ERR}✖ Setup didn't finish — MySQL's first start has been running for $(( fbs / 60 )) minutes, and it normally takes seconds.${RESET}" >&2
        echo ""
        echo -e "  Your secure environment can't run trainings or ingest data until it finishes."
        echo -e "  If it finishes, your secure environment comes Online by itself. To see where it is:"
        echo -e "    ${TB_CMD}$(tb_kubectl_shown) logs -n ${ns} deploy/mysql-client -c mysql-first-boot${RESET}"
        echo -e "  If it doesn't, save a support bundle and email it to support@tracebloc.io:"
        echo -e "    ${TB_CMD}tracebloc doctor --diagnose${RESET}"
      else
        echo -e "  ${TB_WARN}⚠${RESET}  Almost there — tracebloc is installed but still starting."
        echo ""
        echo -e "  Components are still downloading/starting (first run can take a few minutes)."
        echo -e "  Check progress:   ${TB_CMD}$(tb_kubectl_shown) get pods -n ${ns}${RESET}"
        echo ""
        echo -e "  Your secure environment will show as ${BOLD}🟢 Online${RESET} at ${TB_LINK}$(_dashboard_url)${RESET}"
        echo -e "  once it finishes. ${DIM}Re-running this installer is safe.${RESET}"
      fi
      ;;
    bad_creds)
      echo -e "  ${TB_ERR}✖ Couldn't connect — your Client ID or password was rejected.${RESET}" >&2
      echo ""
      echo -e "  The environment installed, but tracebloc refused those credentials."
      echo -e "    1. Check them against the credential file \`tracebloc client create\` wrote"
      echo -e "    2. Re-run this installer ${DIM}(safe to re-run)${RESET}"
      ;;
    image_pull_ca)
      echo -e "  ${TB_ERR}✖ Setup didn't finish — the cluster does not trust your network's TLS-inspection CA.${RESET}" >&2
      echo ""
      echo -e "  Your network intercepts HTTPS (break-and-inspect), so the in-cluster image"
      echo -e "  pulls fail certificate validation (x509). Point the installer at your"
      if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "$OS" == "Darwin" ]]; then
        # The macOS node takes the CA's roots by path (_mac_ct_node_ca), and new roots
        # recreate it on its volume, so a re-run with the CA is the whole remedy:
        # nothing is released and nothing is deleted.
        echo -e "  corporate CA bundle so the VM that runs tracebloc on this Mac trusts it."
        echo -e "  Re-running with the CA recreates the VM with it, and keeps the VM's data:"
      else
        # Native k3s reads the CA from /etc/rancher/k3s/registries.yaml each time
        # the k3s service starts, so a re-run that writes it is the whole remedy:
        # nothing is released and nothing is deleted.
        echo -e "  corporate CA bundle so k3s trusts it. k3s reads the CA each time its"
        echo -e "  service starts, so re-running with the CA rewrites it and restarts k3s"
        echo -e "  (systemctl restart k3s):"
      fi
      echo -e "    ${TB_CMD}TRACEBLOC_CA_BUNDLE=/path/to/corporate-ca.pem ${TB_INSTALL_CMD:-./install.sh}${RESET}"
      echo -e "  ${DIM}(CURL_CA_BUNDLE is also honored.) Ask your IT team for the bundle if unsure.${RESET}"
      echo -e "  Inspect:  ${TB_CMD}$(tb_kubectl_shown) get events -n ${ns} | grep -i x509${RESET}"
      echo -e "  ${DIM}Re-running this installer is safe.${RESET}"
      ;;
    crash)
      local fb=""
      if _mysql_client_crashlooping "$ns"; then fb="$(_mysql_first_boot_verdict "$ns")"; fi
      if [[ "$fb" == "incomplete "* || "$fb" == "never-served "* ]]; then
        _mysql_incomplete_summary "$ns" "${fb%% *}" "${fb#* }"
      else
        _crash_or_pull_summary "$ns"
      fi
      ;;
    image_pull)
      _crash_or_pull_summary "$ns"
      ;;
  esac
  # A native k3s user with no KUBECONFIG reads the release only through the merged
  # file (_summary_kubeconfig_hint). Every outcome names a kubectl command or a
  # kube-context, so every outcome carries the line; the connected one inside its rules.
  if [[ "$TRACEBLOC_CLIENT_STATE" != "connected" ]]; then
    kc="$(_summary_kubeconfig_lines)"
    if [[ -n "$kc" ]]; then printf '\n%s\n' "$kc"; fi
  fi
  echo ""

  _log_advanced_info
}

# The GPU smoke test the summary prints, one vendor per call (nvidia | amd).
# `kubectl run` has no --limits (removed in kubectl 1.24: "unknown flag:
# --limits"), so the GPU limit rides in --overrides with the RuntimeClass.
# --override-type=strategic merges the container by name, so the image, the
# command and -it survive. summary.bats runs this line through
# `kubectl run --dry-run=client` -- a grep for the text could not catch a flag
# kubectl refuses.
_gpu_test_cmd() {
  local vendor="$1" image smi spec
  case "$vendor" in
    nvidia)
      # The class is the runtime step c's gate found on native k3s (common.sh
      # _gpu_runtime_class).
      image="nvidia/cuda:12.3.1-base-ubuntu22.04"; smi="nvidia-smi"
      spec="\"runtimeClassName\":\"$(_gpu_runtime_class)\"," ;;
    amd)
      image="rocm/rocm-terminal"; smi="rocm-smi"; spec='' ;;
    *) return 1 ;;
  esac
  printf "kubectl run gpu-test --rm -it --restart=Never --image=%s --override-type=strategic --overrides='{\"spec\":{%s\"containers\":[{\"name\":\"gpu-test\",\"resources\":{\"limits\":{\"%s.com/gpu\":\"1\"}}}]}}' -- %s" \
    "$image" "$spec" "$vendor" "$smi"
}

_log_advanced_info() {
  local kdata jdata
  log ""
  log "=== Advanced Info (for debugging) ==="
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${TB_STORAGE_MODE:-node-local}" == "hostpath" ]]; then
    log "Volumes: $(_hostpath_root) (hostPath, on this host)"
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "$OS" == "Darwin" ]]; then
    jdata=""
    if declare -F _mac_ct_job_data_dir >/dev/null; then jdata="$(_mac_ct_job_data_dir)"; fi
    [[ -z "$jdata" ]] || log "Job data: ${jdata} (dataset, logs and resume; on this Mac, mode 0700, mounted into the VM at the same path)"
    log "Volumes: in the volume $(_mac_ct_node_name 2>/dev/null) of the VM that runs tracebloc on this Mac (k3s local-path)"
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    kdata="$(_native_k3s_storage_path)" || kdata=""
    log "Volumes: ${kdata:-path not readable without root} (k3s local-path, on this host)"
  fi
  log ""
  log "Useful commands:"
  log "  $(tb_kubectl_shown) get nodes -o wide"
  log "  $(tb_kubectl_shown) get pods -A"
  log "  $(tb_kubectl_shown) get pods -n ${TB_NAMESPACE:-default}"
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "$OS" == "Darwin" ]]; then
    local ct node
    ct="$(_mac_ct_install_root 2>/dev/null)/bin/container"; node="$(_mac_ct_node_name 2>/dev/null)"
    log "  \"${ct}\" list --all"
    log "  \"${ct}\" logs ${node}"
    log "  launchctl print gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL:-io.tracebloc.node}"
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    log "  sudo systemctl stop k3s"
    log "  sudo systemctl start k3s"
    log "  systemctl status k3s"
    log "  journalctl -u k3s"
  fi
  if _gpu_wired; then
    # runtimeClassName: nvidia is REQUIRED — the GPU node's containerd invokes the
    # NVIDIA runtime only for that class; a plain pod gets no GPU.
    log "  GPU test: $(_gpu_test_cmd nvidia)"
  fi
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    log "  GPU test: $(_gpu_test_cmd amd)"
  fi
  log "=== End Advanced Info ==="
}
