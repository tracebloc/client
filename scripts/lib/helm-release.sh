#!/usr/bin/env bash
# =============================================================================
#  helm-release.sh — the live tracebloc Helm release: the helm lock, the
#  recovery of a release left pending, and the in-place reconcile of an
#  adopted client. install_client_helm (install-client-helm.sh) calls them.
# =============================================================================

# _last_deployed_helm_revision — the highest revision whose status is `deployed`
# in a `helm history -o json` body ($1), or nothing when there is none
# jq-free, the same parse as the auto-upgrade cronjob's
# last_deployed_revision: split the body on each record's leading
# `{"revision":`, so a description (helm escapes its quotes) cannot forge one.
_last_deployed_helm_revision() {
  printf '%s' "$1" | tr -d '\n' | awk '{
    n = split($0, recs, /\{[ ]*"revision":[ ]*/)
    best = ""
    for (i = 2; i <= n; i++) {
      r = recs[i]
      if (match(r, /^[0-9][0-9]*/) == 0) continue
      rev = substr(r, 1, RLENGTH) + 0
      if (r ~ /"status":[ ]*"deployed"/ && (best == "" || rev > best)) best = rev
    }
    if (best != "") print best
  }'
}

# ── The host's helm lock ─────────────────────────────────
# On the macOS node the Apple-GPU runner's idle restart stops the node and holds
# ~/.tracebloc/helm.lock until it is Ready again, and the tracebloc CLI's helm commands
# take the same lock (cli-dev internal/helmlock). So each helm call here that changes the
# release takes it too, around that call alone: a restart then waits for one helm call,
# never for the rest of the installer, and never stops the node under one. The recovery
# of an interrupted release holds it across the read it decides on and its act
# (_tb_recover_locked), since the wait for the lock can change what that read says.
#   - It is flock(2), exclusive. macOS's /usr/bin/lockf (FreeBSD's) takes the same lock;
#     cli-dev's TestTheInstallersLockfIsTheSameLock holds that.
#   - -k keeps the file. Without it lockf unlinks the file on exit, and a process that
#     opened the old file could lock it while another locks a new one: both would hold it.
#   - The kernel drops the lock when its holder exits, so a holder that died leaves it free.
#   - Exit 75 (EX_TEMPFAIL) is lockf's: the wait ran out and helm never ran.
#   - spin's deadline (_tb_helm_deadline_s) is helm's budget plus the lock's wait, so the
#     wait never takes helm's time and lockf's 75 comes first. At it spin TERMs and KILLs
#     the whole tree (_tb_spin_reap), so a timed-out call leaves no helm without the lock.
# Elsewhere (Linux, WSL) no runner restarts a node, and the prefix is empty.
_TB_HELM_LOCK=()
_TB_HELM_LOCKF=/usr/bin/lockf

# _tb_helm_lock -- set _TB_HELM_LOCK to the prefix the next release-changing helm call runs
# under: `lockf -k -t WAIT LOCK` on the macOS node (native k3s on a Mac, as
# _mac_node_profile_set_args reads it), empty anywhere else. WAIT is
# TRACEBLOC_HELM_LOCK_WAIT_S whole seconds, 300 by default. LOCK sits beside the install
# record's user copy, as cli-dev's helmlock.Path does. A lock this run cannot take (no
# home, no folder, no lockf) stops the run: helm never runs without it on the Mac.
_tb_helm_lock() {
  local _rec _w
  _TB_HELM_LOCK=()
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]] || return 0
  [[ -n "${TRACEBLOC_RECORD_HOME:-${HOME:-}}" ]] \
    || error "HOME is not set, so this run cannot tell where the helm lock (~/.tracebloc/helm.lock) is. Re-run the installer from your own login."
  _rec="$(tb_record_path)"
  mkdir -p "${_rec%/*}" \
    || error "Couldn't create ${_rec%/*}, which holds the helm lock the tracebloc runner shares with this installer. Check that you own it, then re-run."
  [[ -x "$_TB_HELM_LOCKF" ]] \
    || error "${_TB_HELM_LOCKF} is missing, so this installer cannot take the helm lock the tracebloc runner shares with it. It ships with macOS; check this Mac's system files, then re-run."
  case "${TRACEBLOC_HELM_LOCK_WAIT_S:-}" in
    ''|*[!0-9]*) _w=300 ;;
    *) _w=$(( 10#$TRACEBLOC_HELM_LOCK_WAIT_S )) ;;
  esac
  _TB_HELM_LOCK=("$_TB_HELM_LOCKF" -k -t "$_w" "${_rec%/*}/helm.lock")
}

# _tb_helm_lock_timed_out RC -- stop the run by name when RC is lockf's "the wait ran out"
# (75) under a lock prefix: something else held the lock, and helm did not run. Any other
# RC returns, for the caller's own helm failure.
_tb_helm_lock_timed_out() {
  [[ "$1" -eq 75 && "${#_TB_HELM_LOCK[@]}" -eq 5 ]] || return 0
  error "A tracebloc node restart or helm command on this Mac held ${_TB_HELM_LOCK[4]} for ${_TB_HELM_LOCK[3]} s, so this installer did not change the secure environment. Re-run the installer once it has ended."
}

# _tb_wait_auto_upgrade_job NS -- wait for the chart's own auto-upgrade Job in NS to end.
# Its `helm upgrade` holds the release in pending-upgrade while it runs, and the host's
# helm lock cannot see an in-cluster Job, so acting on the release then races a live
# upgrade. The wait is bounded by the Job's activeDeadlineSeconds, past which Kubernetes
# kills it and what it leaves is a real wedge. The first list is tried three times, a slow
# API being the likely reason it fails. Jobs are told apart by their pod template's
# component label, since the CronJob sets no labels on the Jobs themselves. Returns 1 when
# the Jobs could not be listed, first or on the wait's last poll (nothing is known about an
# upgrade), else 0.
_tb_wait_auto_upgrade_job() {
  local _ns="$1" _out _name="" _dl="" _deadline _poll="${TRACEBLOC_AUTO_UPGRADE_POLL_S:-10}" _said="" _try _listed="" _unread=""
  local _tmpl='{{range $j := .items}}{{if $j.status.active}}{{with $j.spec.template.metadata.labels}}{{with index . "app.kubernetes.io/component"}}{{if eq . "auto-upgrade"}}{{$j.metadata.name}}{{"\t"}}{{$j.spec.activeDeadlineSeconds}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}'
  for _try in 1 2 3; do
    if _out="$(_bounded 20 kubectl get jobs -n "$_ns" \
      --request-timeout=15s -o "go-template=$_tmpl" 2>>"${LOG_FILE:-/dev/null}")"; then _listed=1; break; fi
    (( _try < 3 )) && sleep "$_poll"
  done
  [[ -n "$_listed" ]] || { log "auto-upgrade Jobs in '$_ns' could not be listed."; return 1; }
  read -r _name _dl <<<"$_out" || true
  [[ -n "$_name" ]] || return 0
  [[ "$_dl" =~ ^[0-9]+$ ]] || _dl=1500   # the chart's floor at the default upgrade timeout
  _deadline=$(( SECONDS + _dl ))
  while [[ -n "$_name" ]] && (( SECONDS < _deadline )); do
    if [[ -z "$_said" ]]; then
      info "The hourly auto-upgrade ($_name) is updating your secure environment now; waiting for it to finish (at most ${_dl}s)…"
      log "auto-upgrade Job $_name active in '$_ns'; waiting up to ${_dl}s before touching the release."
      _said=1
    fi
    sleep "$_poll"
    _out="$(_bounded 20 kubectl get jobs -n "$_ns" \
      --request-timeout=15s -o "go-template=$_tmpl" 2>>"${LOG_FILE:-/dev/null}")" || { _unread=1; continue; }
    _unread=""; _name=""; read -r _name _dl <<<"$_out" || true
  done
  if [[ -n "$_unread" ]]; then
    log "auto-upgrade Jobs in '$_ns' could not be listed again while $_name was active."
    return 1
  elif [[ -n "$_name" ]]; then
    log "auto-upgrade Job $_name in '$_ns' still active after its deadline; going on."
  elif [[ -n "$_said" ]]; then
    info "The auto-upgrade finished."
  fi
  return 0
}

# _tb_helm_deadline_s MINUTES -- print spin's deadline, in seconds, for a helm call run
# under _TB_HELM_LOCK: helm's MINUTES plus the lock's wait, or MINUTES alone with no lock.
_tb_helm_deadline_s() {
  local _w=0
  [[ "${#_TB_HELM_LOCK[@]}" -eq 5 ]] && _w="${_TB_HELM_LOCK[3]}"
  printf '%s' "$(( $1 * 60 + _w ))"
}

# _recover_pending_helm_release — auto-clear a wedged pending-* release before a
# helm upgrade/install. A helm process killed mid-operation (Ctrl-C, OOM,
# host reboot, laptop sleep) leaves the release stuck in a transient state; every
# subsequent `helm upgrade --install` then fails with "another operation is in
# progress" — exit 1, NOT 124 — a permanent wedge that no re-run can clear on its
# own. Detect that state and clear it so the caller's helm op can proceed.
#
#   $1 = release name   $2 = namespace
#   $3 = mode: "full" (default) or "no-destroy" (see below)
#
# Reads the STATUS: line of `helm status` once any active auto-upgrade Job has ended
# (_tb_wait_auto_upgrade_job) — jq-free on purpose, parsed the same way the
# auto-upgrade cronjob does, whose alpine/helm image ships without jq — and
# again under the host's helm lock, where what to do is decided (_tb_recover_locked):
#   deployed / failed / superseded / uninstalled / not found → healthy or absent; no-op
#   no status (a timeout, an API error) → no-op, except under the host's helm lock,
#     where its holder may be what the read timed out on: there it is read again
#   pending-upgrade / pending-rollback → roll back to the last deployed revision,
#                                        named from `helm history`;
#                                        none in the history → refuse (return 1);
#                                        auto-upgrade Jobs that could not be listed
#                                        → no rollback, said on screen; left to the
#                                        bounded upgrade (return 0)
#   pending-install                    → revision 1 never deployed; there is no
#                                        good revision to roll back to, so remove
#                                        the half-installed release (matches the
#                                        first-install manual remedy we already
#                                        print). Safe for data: the chart renders
#                                        helm.sh/resource-policy: keep on every
#                                        PVC/namespace, and helm reads that from
#                                        the STORED rev-1 manifest, so uninstall
#                                        leaves the PVCs in place (docs/MIGRATIONS).
#   uninstalling                       → a killed `helm uninstall`; finish it.
#
# mode="no-destroy" (the adopt/reconcile path): rollback is still
# performed (non-destructive — it restores a deployed revision, so the reconcile's
# --reuse-values stays valid), but the destructive uninstall branch is REFUSED
# (returns 1). Adopt reuses the release's STORED credential (the account password
# is write-only on the backend and lives only in that release); uninstalling a
# pending-install there would silently drop it. Better to fail closed with a
# manual remedy than to auto-destroy the sole copy of the credential.
#
# Returns 0 when the release is clear (or was already), non-zero when recovery was
# attempted and FAILED, or was refused under no-destroy — the caller must fail
# closed rather than march into the same wedge.
_recover_pending_helm_release() {
  local _rel="$1" _ns="$2" _mode="${3:-full}" _status _rc _verdict _script _unread="" _jobs_unread=""
  # A pending-upgrade the chart's auto-upgrade Job is applying is in flight, not
  # wedged; and a release it is about to upgrade rejects the caller's helm op.
  _tb_wait_auto_upgrade_job "$_ns" || _jobs_unread=1
  # Bound the status READ: every helm/kubectl probe in this installer
  # must be bounded so a wedged/unreachable API can't hang a headless run — and
  # this read gates everything below, so bounding it bounds the recovery. A
  # timeout (or any error) yields an empty status → no-op → we hand off to the
  # bounded upgrade, which surfaces the API failure with its own deadline — unless
  # the host's helm lock is in force, whose holder (the runner's node restart) can
  # be what the read timed out on: then it is read again under the lock. The
  # mutating ops (_tb_recover_locked) are NOT wrapped in a kill-based bound on
  # purpose: SIGKILLing a helm rollback/uninstall midway would recreate the very
  # pending-* wedge we are clearing. They are bounded gracefully by helm's own
  # --wait --timeout (and only run once this read has proven the API responsive).
  # Capture the whole `helm status`, then parse it from a here-string — NEVER
  # through an early-exit awk pipeline. Under `set -o pipefail` awk's `exit`
  # SIGPIPEs helm (rc 141) as it writes the rest of the status body, and the
  # `|| _status=""` guard would then WIPE a perfectly good parse, silently
  # skipping recovery (same SIGPIPE-under-pipefail lesson as
  # _extract_yaml_value). Here-string parsing can't signal anything.
  local _status_out
  _status_out="$(_bounded 30 helm status "$_rel" -n "$_ns" 2>&1)" || :
  _status="$(awk '/^STATUS:/ {print $2; exit}' <<<"$_status_out")"
  if [[ -z "$_status" && "$_status_out" != *"not found"* ]]; then
    _tb_helm_lock
    [[ "${#_TB_HELM_LOCK[@]}" -gt 0 ]] || return 0
    _unread=1
  fi
  case "$_status" in
    pending-upgrade|pending-rollback|pending-install|uninstalling) ;;
    '') [[ -n "$_unread" ]] || return 0 ;;  # absent, or unread off the lock
    deployed|failed|superseded|uninstalled)
      return 0 ;;  # healthy — nothing to recover
    *)
      log "helm status of '$_rel' is '$_status'; no pending-state recovery needed."
      return 0 ;;
  esac
  if [[ -n "$_unread" ]]; then
    log "helm status of '$_rel' gave no status outside the helm lock; reading it again under the lock."
  else
    tb_machine_lines warn "A previous helm operation on '$_rel' was interrupted (status: $_status)."
    info "Clearing an update that was interrupted..."
  fi
  # The read above only says whether to recover. What to do is decided under the
  # host's helm lock, by a read made there: the lock can wait up to
  # 300 s for the runner's node restart or the CLI's helm command, which can finish
  # this very release meanwhile, and a rollback or uninstall decided before that wait
  # would undo a release that is healthy again. lockf runs a program, never a shell
  # function, so on the macOS node the locked section is a bash of its own, handed
  # _tb_recover_locked and what it calls; elsewhere there is no lock, and it runs here.
  _tb_helm_lock
  local _sec=("$_rel" "$_ns" "$_mode" "${LOG_FILE:-/dev/null}" "$_jobs_unread")
  _rc=0
  if [[ "${#_TB_HELM_LOCK[@]}" -gt 0 ]]; then
    _script="$(declare -f has _bounded _tb_bounded_bg _tb_bounded_wait _last_deployed_helm_revision _tb_recover_locked)" \
      || error "The installer is missing a function its helm lock's recovery runs. Re-download the installer, then re-run."
    _verdict="$(${_TB_HELM_LOCK[@]+"${_TB_HELM_LOCK[@]}"} "$BASH" -c "${_script}"$'\n''_tb_recover_locked "$@"' tb-helm-recover "${_sec[@]}" 2>>"${LOG_FILE:-/dev/null}")" || _rc=$?  # set-u-safe: _sec holds the five words assigned above
  else
    _verdict="$(_tb_recover_locked "${_sec[@]}")" || _rc=$?  # set-u-safe: _sec holds the five words assigned above
  fi
  if [[ "$_rc" -ne 0 ]]; then
    _tb_helm_lock_timed_out "$_rc"
    warn "The recovery of '$_rel' ended with exit $_rc before it said what it did."
    return 1
  fi
  local _v="" _vs="" _vt=""
  read -r _v _vs _vt <<<"$_verdict" || true
  case "$_v" in
    clear)
      if [[ -n "$_unread" ]]; then
        log "No recovery of '$_rel': it was $_vs when read again under the helm lock."
        return 0
      fi
      info "'$_rel' is no longer interrupted (status: $_vs): it finished before this installer acted, so it is left as it is."
      log "No recovery of '$_rel': it was $_status, and $_vs when read again under the helm lock."
      ;;
    unreadable)
      if [[ -n "$_unread" ]]; then
        log "helm status of '$_rel' gave no status under the helm lock either; leaving it to the bounded upgrade."
        return 0
      fi
      warn "This installer could not read '$_rel' again under the helm lock, so it cannot tell whether it is still interrupted, and left it as it is."
      hint "Check it, then re-run:  $(tb_helm_shown) -n $_ns status $_rel"
      return 1
      ;;
    jobs-unread)
      tb_machine_lines warn "This installer could not check whether the hourly auto-upgrade is running in '$_ns', so it did not roll '$_rel' back and left it as it is."
      info "The hourly auto-upgrade may still be running, so it is left as it is."
      log "No rollback of '$_rel' ($_vs): the auto-upgrade Jobs in '$_ns' could not be listed; leaving it to the bounded upgrade."
      return 0
      ;;
    rolled-back)
      info "Rolled '$_rel' back to its last deployed revision ($_vt)."
      log "Recovered '$_rel' from $_vs via helm rollback to revision $_vt."
      ;;
    uninstalled)
      info "Cleared the half-finished release '$_rel'."
      log "Recovered '$_rel' from $_vs via helm uninstall."
      ;;
    no-target)
      warn "The history of '$_rel' names no deployed revision to roll back to — refusing an automatic rollback."
      hint "Inspect it and roll back by hand to a revision you trust:"
      hint "  $(tb_helm_shown) -n $_ns history $_rel"
      hint "  $(tb_helm_shown) -n $_ns rollback $_rel <revision> --wait"
      return 1
      ;;
    refused)
      # Clearing pending-install/uninstalling can only be done by uninstalling
      # (a never-deployed revision can't be rolled back), which would drop this
      # client's stored credential — refuse on the reconcile path.
      # rollback is NOT a remedy for these states, so print the credential-safe
      # manual path instead.
      warn "Clearing '$_rel' (status: $_vs) needs an uninstall, which would drop this secure environment's write-only stored credential — refusing to auto-recover it here."
      hint "Recover by hand without losing the credential:"
      hint "  $(tb_helm_shown) -n $_ns get values $_rel   # save clientPassword first — it can't be re-fetched"
      hint "  $(tb_helm_shown) -n $_ns uninstall $_rel    # then re-run the installer"
      return 1
      ;;
    rollback-failed)
      warn "Automatic rollback of '$_rel' to revision $_vt failed."
      return 1
      ;;
    uninstall-failed)
      warn "Automatic cleanup of '$_rel' failed."
      return 1
      ;;
    *)
      warn "The recovery of '$_rel' gave no answer this installer reads ('${_verdict}'), so it cannot tell whether the release changed."
      return 1
      ;;
  esac
  return 0
}

# _tb_recover_locked REL NS MODE LOG JOBS -- _recover_pending_helm_release's decision and its
# act, as one piece that runs under the host's helm lock. It reads REL's status again
# and acts on that read alone; helm's output goes to LOG. Prints one verdict line,
# which the caller turns into messages:
#   clear STATUS              not interrupted (any more), or absent (helm: not found):
#                             nothing done
#   unreadable                helm status gave no status and did not say not found
#                             (a timeout, an API error): nothing done
#   jobs-unread STATUS        pending-upgrade/-rollback, but JOBS is set: the auto-upgrade
#                             Jobs could not be listed, so a live upgrade may hold it:
#                             nothing done
#   rolled-back STATUS REV    pending-upgrade/-rollback, rolled back to the last
#                             deployed revision REV, named from `helm history`
#   no-target STATUS          ... but the history names no deployed revision: refused
#   rollback-failed STATUS REV
#   uninstalled STATUS        pending-install (revision 1 never deployed: there is no
#                             good revision, so the half-install goes; the chart's
#                             resource-policy: keep leaves the PVCs, docs/MIGRATIONS)
#                             or uninstalling (a killed `helm uninstall`, finished)
#   refused STATUS            ... but MODE is no-destroy
#   uninstall-failed STATUS
# On the macOS node it runs in the bash lockf starts, so it uses only what
# _recover_pending_helm_release hands that bash: no messages, no other globals.
_tb_recover_locked() {
  local out s hist target
  # helm's own words are kept: a release helm cannot find is absent, but a read that
  # timed out or met an API error says nothing about it, and a release the caller
  # saw interrupted must not pass for finished on that.
  out="$(_bounded 30 helm status "$1" -n "$2" 2>&1)" || :
  s="$(awk '/^STATUS:/ {print $2; exit}' <<<"$out")"
  if [ -z "$s" ]; then
    case "$out" in
      *"not found"*) echo "clear absent" ;;
      *) echo "unreadable" ;;
    esac
    return 0
  fi
  case "$s" in
    pending-upgrade|pending-rollback)
      if [ -n "${5:-}" ]; then echo "jobs-unread $s"; return 0; fi
      hist="$(_bounded 30 helm history "$1" -n "$2" -o json 2>/dev/null)" || hist=""
      target="$(_last_deployed_helm_revision "$hist")"
      if [ -z "$target" ]; then echo "no-target $s"
      elif helm rollback "$1" "$target" -n "$2" --wait --timeout 5m >>"$4" 2>&1; then echo "rolled-back $s $target"
      else echo "rollback-failed $s $target"; fi
      ;;
    pending-install|uninstalling)
      if [ "$3" = no-destroy ]; then echo "refused $s"
      elif helm uninstall "$1" -n "$2" --wait --timeout 5m >>"$4" 2>&1; then echo "uninstalled $s"
      else echo "uninstall-failed $s"; fi
      ;;
    *) echo "clear $s" ;;
  esac
  return 0
}

# _reconcile_override_args REL NS PIN57 — the --set words the adopt reconcile forces over the
# release's reused values, in order, into _TB_RECONCILE_ARGS. PIN57=1 pins the 5.7 image.
_reconcile_override_args() {
  # GPU keys are NOT --reuse-values-safe: it carries forward a prior release's GPU keys and
  # device-plugin block, so FORCE them to THIS run's decision, as dev mode does (_gpu_decision_set_args).
  _gpu_decision_set_args
  _TB_RECONCILE_ARGS=("${_TB_GPU_DECISION_ARGS[@]}")  # set-u-safe: _gpu_decision_set_args always assigns
  # The host's OS too: --reuse-values would keep whatever an earlier run, or no run, wrote.
  _host_os_set_args
  _TB_RECONCILE_ARGS+=("${_TB_HOST_OS_ARGS[@]}")  # set-u-safe: _host_os_set_args always assigns two words
  # A release that runs 5.7 keeps 5.7: the chart now defaults to 8.4, and --reuse-values /
  # --reset-then-reuse-values keep only what the release STORED, which for a 5.7 release is usually
  # no image key at all. Without this pin the reconcile would render 8.4 over its 5.7 datadir,
  # mysql-format-guard would refuse, and --atomic would roll the reconcile back. A custom pin (_live
  # unknown) is left to its own stored values.
  if [[ "$3" == 1 ]]; then
    _TB_RECONCILE_ARGS+=(--set "images.mysqlClient.tag=${TB_MYSQL_57_PIN_TAG}"
                         --set "images.mysqlClient.digest=${TB_MYSQL_57_PIN_DIGEST}")
  fi
  # The machine facts ride it too, for the same reason.
  _machine_facts_set_args
  _TB_RECONCILE_ARGS+=("${_TB_MACHINE_FACTS_ARGS[@]}")  # set-u-safe: _machine_facts_set_args always assigns six words
  # And whether k3s runs the pods confined: the chart's level must follow config.yaml.
  _selinux_set_args
  _TB_RECONCILE_ARGS+=(${_TB_SELINUX_ARGS[@]+"${_TB_SELINUX_ARGS[@]}"})
  # The log Collector: the stored choice stands, else an opt-out of usage events.
  _collector_set_args reuse "$1" "$2"
  _TB_RECONCILE_ARGS+=(${_TB_COLLECTOR_ARGS[@]+"${_TB_COLLECTOR_ARGS[@]}"})
  # The local API rides the same reconcile, for the same reason: a release from before localApi
  # existed reuses the chart default, off, while the macOS node's publish (_mac_ct_ensure_node) has
  # just mapped 127.0.0.1 to its NodePort. Force THIS run's decision, the one
  # _local_api_values_block writes on a fresh install: on with the two ports the node mapped, else
  # off, so a mapping that is gone (opted out, port busy) can't leave a stale "on".
  if [[ "${TB_LOCAL_API_MAPPED:-0}" == "1" ]]; then
    # singleMachine: this run just mapped the port on this machine, and a release from the window
    # when node-local was opt-in stores neither singleNode nor hostPath.enabled=true, so without it
    # the chart's guard would refuse the upgrade.
    _TB_RECONCILE_ARGS+=(--set "localApi.enabled=true"
                         --set "localApi.nodePort=$TRACEBLOC_LOCAL_API_NODE_PORT"
                         --set "localApi.hostPort=$TRACEBLOC_LOCAL_API_HOST_PORT"
                         --set "localApi.singleMachine=true")
  else
    _TB_RECONCILE_ARGS+=(--set "localApi.enabled=false")
  fi
  # The macOS node's values profile, last, so its --set words win over stored values predating it.
  _mac_node_profile_set_args
  _TB_RECONCILE_ARGS+=(${_TB_MAC_PROFILE_ARGS[@]+"${_TB_MAC_PROFILE_ARGS[@]}"})
  _mac_runner_set_args
  _TB_RECONCILE_ARGS+=(${_TB_MAC_RUNNER_ARGS[@]+"${_TB_MAC_RUNNER_ARGS[@]}"})
}

# _reconcile_adopted_client — adopt path. provision_client (Step 3)
# sets TRACEBLOC_CLIENT_ADOPTED=1 when `tracebloc client create` matched this cluster
# to an EXISTING client on the account (get-or-create keyed on the cluster). Adopt
# issues no new password — the existing one stands (write-only on the backend) — so
# there is nothing to prompt for or verify. Reconcile the live release in place,
# reusing its stored credential, and heal the stored clientId to the adopted UUID:
# installs from an older installer stored the numeric dashboard id, which can't
# authenticate. Returns 0 on a successful reconcile; non-zero (caller falls back to
# the normal connect flow) when no live tracebloc release is found to reconcile.
_reconcile_adopted_client() {
  # provision_client (Step 3) hands over the adopted client id (UUID) + the marker on
  # adopt (no password — the existing credential stands). Find the live client release
  # and reconcile it in place. Enumerate it the same jq-free way the one-per-machine
  # guard does — the full deployed/failed/pending-*/uninstalling set, so a
  # release wedged by a killed helm op is discovered instead of adopt falling through
  # to a password prompt it can't satisfy. One client per machine, so take the first.
  local _rel="" _ns="" _r _n
  while read -r _r _n; do
    [[ -n "$_r" ]] && { _rel="$_r"; _ns="$_n"; break; }
  done < <(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  if [[ -z "$_rel" ]]; then
    warn "This secure environment is already registered, but no live tracebloc release was found here to reconcile — continuing with a normal connect."
    return 1
  fi

  namespace="$_ns"
  info "This machine already runs a secure environment — reconciling '${_rel}' (namespace '${_ns}') in place."

  _ensure_helm_runnable

  # the arch gate belongs on the adopt path too, BEFORE the engine is
  # deployed. Reconcile keeps the release's engine — read THAT (never a fresh
  # resolution, which could pick 8.4 for a release whose data is 5.7) and ask the
  # same question the normal install path asks. Without it, an arm64 host with no
  # amd64 emulation adopting a 5.7 release reported success and then CrashLooped:
  # preflight had classified the machine as fresh-8.4, so its early gate waved it
  # through. existing-release is the accurate reason (a live Helm release, not host
  # files — see _assert_engine_runs_on_this_arch).
  #
  # What the release RUNS (_release_mysql_engine); when that cannot be read, an
  # 8.x-format host datadir (_host_mysql_datadir_format) or its stored values'
  # explicit 8.4 opt-in (_release_pins_mysql_84); else 5.7, the data-safety
  # default. A release running an image that names
  # neither engine (a custom pin) keeps its own values: no 5.7 pin below, and 5.7
  # for the arch gate, which cannot prove it runs natively.
  local _live _fmt _pin57=0
  _live="$(_release_mysql_engine "$_ns")"
  _fmt="$(_host_mysql_datadir_format)"
  if [[ "$_live" == "8.4" ]] \
     || { [[ -z "$_live" ]] && { [[ "$_fmt" == "8.x" ]] || _release_pins_mysql_84 "$_rel" "$_ns"; }; }; then
    TB_MYSQL_ENGINE_RESOLVED="8.4"
  else
    TB_MYSQL_ENGINE_RESOLVED="5.7"
    [[ "$_live" == "unknown" ]] || _pin57=1
  fi
  TB_MYSQL_ENGINE_REASON="existing-release"
  _assert_engine_runs_on_this_arch

  local chart_ref=""
  _resolve_chart_ref

  # Reconcile in place, reusing the release's stored values (clientPassword +
  # install-time config). Prefer --reset-then-reuse-values (Helm >= 3.14: reset to
  # chart defaults, then re-apply the stored user values, picking up new chart
  # defaults); fall back to --reuse-values on older Helm.
  local _reuse="--reuse-values" _upgrade_help
  # Capture-then-match: `helm upgrade --help | grep -q` lets grep
  # close the pipe on its first hit, helm takes SIGPIPE and pipefail makes the
  # pipeline 141 — the `&&` then reads that as "flag unsupported" and the
  # reconcile silently keeps --reuse-values, so new chart defaults are never
  # picked up. helm's help is several KB written in chunks, and the flag sorts
  # early in the list, so this is the losing shape. `case` also drops the
  # `A && B` set -e subtlety this line used to carry.
  _upgrade_help="$(helm upgrade --help 2>/dev/null || true)"
  case "$_upgrade_help" in
    *'--reset-then-reuse-values'*) _reuse="--reset-then-reuse-values" ;;
  esac

  # Heal the stored clientId to the adopted UUID when provision_client handed one
  # over (export TRACEBLOC_CLIENT_ID on the adopt path): an older install stored
  # the numeric dashboard id, which can't authenticate, and --reuse-values alone
  # would preserve it (the reused password is still correct). With no id (rebuilt
  # host / R7 orphan) reconcile WITHOUT a heal rather than bail — the existing
  # credential stands. Built as an array so the optional --set is bash-3.2 safe.
  local _args=(upgrade "$_rel" "$chart_ref" --namespace "$_ns" "$_reuse" --cleanup-on-fail)
  local _uuid; _uuid="$(_sanitize_credential "${TRACEBLOC_CLIENT_ID:-}")"
  [[ -n "$_uuid" ]] && _args+=(--set "clientId=$_uuid")

  _reconcile_override_args "$_rel" "$_ns" "$_pin57"
  _args+=("${_TB_RECONCILE_ARGS[@]}")  # set-u-safe: always holds the GPU and host-OS words

  # node-local (node-local storage) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-node-local}" != "node-local" ]] && _ensure_release_dirs "$_ns"

  # clear any pending-* wedge left by a previously killed helm op before we
  # upgrade — otherwise this reconcile just fails with "another operation is in
  # progress". no-destroy: reconcile REUSES the release's stored credential (the
  # account password is write-only on the backend and lives only here), so only a
  # non-destructive rollback is allowed; a pending-install/uninstalling wedge is
  # refused rather than auto-uninstalled, which would drop that sole copy (the
  # sole copy). Fail closed with a manual remedy if recovery couldn't clear it.
  if ! _recover_pending_helm_release "$_rel" "$_ns" no-destroy; then
    # For a refused pending-install/uninstalling wedge the helper already printed
    # the credential-safe manual path; add a generic pointer for the other cases.
    hint "Confirm the release state, then re-run:  $(tb_helm_shown) -n $_ns status $_rel"
    error "Reconcile blocked by an interrupted previous helm operation. Check the log for details: ${LOG_FILE:-}"
  fi

  # Reconcile blocks too — same spinner treatment (progress on every wait), bounded so a
  # wedged kube-apiserver can't hang it forever.
  local _helm_timeout_min
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"
  local _helm_rc=0
  _tb_helm_lock
  spin_cmd_bounded "$(_tb_helm_deadline_s "$_helm_timeout_min")" "Reconciling the existing secure environment…" \
    ${_TB_HELM_LOCK[@]+"${_TB_HELM_LOCK[@]}"} helm "${_args[@]}" || _helm_rc=$?  # set-u-safe: assigned the upgrade verb at its declaration
  if [[ "$_helm_rc" -ne 0 ]]; then
    _tb_helm_lock_timed_out "$_helm_rc"
    # A helm op killed partway (timeout=124, or an in-progress wedge=exit 1) can
    # leave the release pending-*. The next run auto-recovers
    # (_recover_pending_helm_release), but name the manual unwedge too — on exit
    # 1, not only the 124 timeout.
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  $(tb_helm_shown) -n $_ns rollback $_rel    (returns to the previous, working release)"
    error "Reconcile of the existing secure environment failed. Check the log for details: ${LOG_FILE:-}"
  fi
  # The release offboarding removes, by its own name: an adopted
  # release need not be named after its namespace. The record's namespace is
  # namespace, set to this release's above.
  tb_record_write helm-release "$_rel" ""

  tb_kube_set_namespace "$_ns"
  return 0
}
