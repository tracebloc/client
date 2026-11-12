#!/usr/bin/env bash
# =============================================================================
#  helm-progress.sh — step e's terminal and pull progress: whether there is a
#  terminal to prompt on, the no-credentials refusal, and the N-of-M count of the
#  client's images as they pull. install_client_helm (install-client-helm.sh) calls them.
# =============================================================================

# TRACEBLOC_TTY is where interactive credential prompts READ from. Under `curl … | bash`
# stdin is the piped script, not the terminal, so an unredirected `read` hits EOF
# and (under set -e) aborts the installer with an opaque failure — read the
# controlling terminal directly instead. Overridable so tests can feed canned
# input on stdin (TRACEBLOC_TTY=/dev/stdin).
: "${TRACEBLOC_TTY:=/dev/tty}"

# _tty_available: true when there's a terminal we can prompt on (TRACEBLOC_TTY readable).
# Mirrors provision.sh's _prompt_tty; defined locally because provision.sh is
# sourced conditionally and AFTER this file, so its helper may not exist when
# install_client_helm runs.
_tty_available() { [[ -r "$TRACEBLOC_TTY" ]]; }

# _no_interactive_creds_die: abort with actionable env-var guidance when we can't
# collect credentials interactively. Covers BOTH no-terminal-at-all AND a
# readable-but-dead-input tty (non-PTY ssh, an IDE terminal, a drained/queued
# tty): _tty_available only checks `-r`, so a `read <"$TRACEBLOC_TTY"` can still hit EOF
# and would otherwise abort opaquely under set -e — the
# same failure class the TRACEBLOC_TTY change set out to remove. Mirrors provision.sh,
# whose name read breaks on rc!=0 and falls through to the same guidance.
_no_interactive_creds_die() {
  error "No credentials supplied and no terminal to prompt on (under \`curl … | bash\`
  the prompt cannot read your input). In a terminal, with a current tracebloc CLI,
  this installer signs you in through your browser and needs no Client ID or
  password. For an unattended install, create the pair on a machine signed in to
  tracebloc:
    $(_credential_file_cmd)
  then copy tb.env here, load it ($(_credential_file_load_cmd)), which sets
  TRACEBLOC_CLIENT_ID and TRACEBLOC_CLIENT_PASSWORD, and re-run."
}

# _download_services_progress NS — render an honest N-of-M count bar as the
# client's container images pull onto the node (the "services download" in step
# e). The only TRUTHFUL per-unit signal is how many containers report a populated
# imageID (image present) out of the total the pods declare — never a fabricated
# aggregate percentage. Best-effort, BOUNDED, and NON-FATAL: it must never block
# or fail the install — the authoritative readiness gate is wait_for_client_ready
# (step f). Skipped entirely when TRACEBLOC_SKIP_SERVICE_PROGRESS is set (the bats suite,
# where kubectl is mocked and a poll loop would hang) or kubectl is unavailable.
# Detect a PERMANENT image-pull failure among the namespace's pods, so the progress
# copy can tell the truth instead of "still downloading". On a visible pull
# failure it prints the concrete pod status line(s) + the matching pull event and
# returns 0; when no pull failure is visible it prints nothing and returns 1.
# Bounded + non-fatal; mirrors summary.sh::_diagnose_not_ready's pull signals but is
# self-contained so it needs no cross-lib sourcing.
_pull_failure_detail() {
  local ns="$1" kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}" pods bad events pull_fail
  has kubectl || return 1
  [[ -n "$ns" ]] || return 1
  pods="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  bad="$(printf '%s\n' "$pods" | grep -iE 'ImagePullBackOff|ErrImagePull|InvalidImageName' || true)"
  [[ -n "$bad" ]] || return 1
  events="$(kubectl get events -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  # Scope to the PULL-failure events only (like summary.sh::_diagnose_not_ready) —
  # never a bare x509/TLS match: kubectl prints one event per line,
  # so an x509 on a pull-failure line is already captured here, while an UNRELATED x509
  # event elsewhere in the ns must not, via tail, displace the real reason.
  pull_fail="$(printf '%s\n' "$events" | grep -iE 'failed to pull|ErrImagePull' | tail -n 3 || true)"
  # Cap the failing-pod lines at three so a cluster with many stuck pods doesn't
  # print a wall of indented lines (reviewer).
  # Herestring, NOT `printf … | head -n 3`: under `set -o pipefail` head closes the
  # pipe after its 3rd line, so a namespace with enough stuck pods to push `$bad`
  # past the ~64KB pipe buffer makes printf take SIGPIPE → the pipeline exits 141 →
  # with errexit live this function aborts HERE and drops the scoped pull event
  # below — the one actionable line (x509 / blocked registry / auth). Measured on
  # bash 5.2.21 + coreutils 9.4: 65,622 bytes is already enough. `<<<` reads from a
  # temp file, so there is no writer left to signal and no `|| true` to mask it.
  head -n 3 <<< "$bad"
  [[ -n "$pull_fail" ]] && printf '%s\n' "$pull_fail"
  return 0
}

# Pure: pick the honest end-of-progress outcome. Prints one token:
#   done       — every container has an image (pulled >= total)
#   failed     — a permanent pull failure is visible (has_fail non-empty)
#   downloading— no failure, but pulls demonstrably progressed (max_pulled > 0)
#   stalled    — nothing pulled and no failure signal yet (pods stuck Pending, etc.)
# A permanent failure NEVER maps to "downloading", so it can't be sold as background
# progress. Kept pure so the decision is unit-testable without a live cluster.
_progress_end_message() {
  local pulled="$1" total="$2" max_pulled="$3" has_fail="$4"
  if (( pulled >= total )); then printf 'done'; return; fi
  if [[ -n "$has_fail" ]];  then printf 'failed'; return; fi
  if (( max_pulled > 0 ));   then printf 'downloading'; return; fi
  printf 'stalled'
}

# _release_service_count NS [TIMEOUT] -- how many services (containers) the client's
# pods run: the number step e's "Downloaded" and "Installed" lines give. Fails when it
# cannot be read or is none.
_release_service_count() {
  local n
  n="$( set -o pipefail; kubectl get pods -n "$1" --request-timeout="${2:-5s}" \
    -o jsonpath='{range .items[*].spec.containers[*]}{"x"}{end}' 2>/dev/null \
    | tr -cd 'x' | wc -c | tr -d ' ')" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || return 1
  printf '%s' "$n"
}

_download_services_progress() {
  local ns="$1"
  if [[ -n "${TRACEBLOC_SKIP_SERVICE_PROGRESS:-}" ]]; then return 0; fi
  has kubectl || return 0
  [[ -n "$ns" ]] || return 0

  # Every kubectl call is bounded with --request-timeout so a wedged/unreachable
  # API can never make the poll BLOCK — the between-iteration deadline check below
  # only fires if kubectl actually returns, so an unbounded call would hang step e
  # forever despite TB_PULL_TIMEOUT. Overridable; mirrors assess.sh's bounded probe.
  local kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}"

  # Establish the total container count once the pods are scheduled (bounded).
  local total=0 tries=0
  while (( tries < 15 )); do
    total="$(_release_service_count "$ns" "$kube_timeout")" || total=0
    if (( total > 0 )); then break; fi
    tries=$(( tries + 1 )); sleep 2
  done
  if (( total < 1 )); then return 0; fi   # never saw pods — skip the bar silently

  local deadline pulled=0 max_pulled=0
  deadline=$(( $(date +%s) + ${TB_PULL_TIMEOUT:-300} ))
  while :; do
    pulled="$( set -o pipefail; kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null \
      | grep -c '.')" || pulled=0
    [[ "$pulled" =~ ^[0-9]+$ ]] || pulled=0
    if (( pulled > total )); then pulled=$total; fi
    if (( pulled > max_pulled )); then max_pulled=$pulled; fi
    tb_live_detail "${pulled} of ${total}"
    if (( pulled >= total )); then break; fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 2
  done

  # Tell the truth on timeout: a permanent pull failure (x509/blocked registry/auth)
  # must NOT be sold as "downloading in the background". Classify, then print
  # copy that matches reality; the authoritative diagnosis still follows in the
  # readiness gate + summary.
  local fail_detail="" outcome
  if (( pulled < total )); then fail_detail="$(_pull_failure_detail "$ns" || true)"; fi
  outcome="$(_progress_end_message "$pulled" "$total" "$max_pulled" "$fail_detail")"
  case "$outcome" in
    done)
      tb_live_done "Downloaded · ${total} services" ;;
    failed)
      tb_live_done
      # Soften the wording (reviewer): ImagePullBackOff can also be a transient blip /
      # registry 429 that kubelet keeps retrying, so wait_for_client_ready may still
      # reach "connected" — don't state an absolute that a later ✔ could contradict.
      warn "Some images look stuck pulling — this usually needs action, not just more time:"
      printf '%s\n' "$fail_detail" | sed 's/^/      /'
      info "Likely a blocked registry, an untrusted TLS-inspection CA, or auth — see the diagnosis below." ;;
    downloading)
      tb_live_done
      info "Services are still downloading — they'll finish starting in the background." ;;
    stalled)
      tb_live_done
      info "Services haven't started pulling yet — see the diagnosis below if this persists." ;;
  esac
  return 0
}
