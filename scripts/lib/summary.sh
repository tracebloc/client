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

# ── Readiness gate (#716) ─────────────────────────────────────────────────
# helm install only *applies* manifests; it does not wait for pods. After it
# returns we wait for the client's workloads to actually become Ready and set
# TRACEBLOC_CLIENT_STATE so the summary reports the truth instead of an unconditional
# "installed successfully":
#   connected | starting | bad_creds | image_pull | image_pull_ca | crash
# (image_pull_ca is the TLS-inspecting-network case, #424. It was added to
# _diagnose_not_ready and not to this list; backend#1907's vocabulary-agreement
# guard derives the set from the function and caught the omission.)
# Empty until wait_for_client_ready runs — so install_cleanup can distinguish an
# early failure (before the readiness gate, TRACEBLOC_CLIENT_STATE still empty) from a
# reported outcome, and still print the "check the log / safe to re-run" hint.
TRACEBLOC_CLIENT_STATE=""
# #562: default raised 300 -> 600 so a slow/proxied laptop pulling several GB of
# images isn't reported "not connected" while still healthily starting. Kept in
# sync with scripts/spec/facts.env (check-facts.sh); override via
# TRACEBLOC_READY_TIMEOUT (the legacy READY_TIMEOUT still works, remove_by
# 2026-12-31; a non-empty canonical wins).
if [[ -n "${TRACEBLOC_READY_TIMEOUT:-}" ]]; then READY_TIMEOUT="$TRACEBLOC_READY_TIMEOUT"; fi
READY_TIMEOUT="${READY_TIMEOUT:-600}"

wait_for_client_ready() {
  local ns="${TB_NAMESPACE:-default}"
  # The workloads that must be Ready are READ from the release, not rebuilt from
  # the namespace (backend#2888): _client_workloads (common.sh) is the one helper
  # the stop-and-check gate (assess.sh) and --diagnose use too, and the
  # PowerShell installer's Get-ClientWorkloads is its guarded twin. A read that
  # cannot resolve all three is a client that is not all there, so it takes the
  # not-Ready branch below rather than waiting on names it guessed.
  local rows="" role d jm="" remaining all_ready=true
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))

  echo ""
  info "Connecting to the tracebloc network — waiting for your services to come online…"
  if rows="$(_client_workloads "$ns")"; then
    while read -r role d; do
      [[ "$role" == "jobs-manager" ]] && jm="$d"
      remaining=$(( deadline - $(date +%s) )); (( remaining < 10 )) && remaining=10
      # </dev/null: the loop reads its rows from stdin, and nothing in it may eat them.
      if kubectl rollout status "deployment/${d}" -n "$ns" --timeout="${remaining}s" \
          </dev/null >> "${LOG_FILE:-/dev/null}" 2>&1; then
        success "${role} ready"
      else
        all_ready=false; break
      fi
    done <<<"$rows"
  else
    log "Could not list the client's workload Deployments in namespace ${ns} (release label app.kubernetes.io/instance=${ns}); treating the client as not Ready."
    all_ready=false
  fi

  _log_cluster_status
  if [[ "$all_ready" == true ]]; then
    TRACEBLOC_CLIENT_STATE="connected"
  else
    TRACEBLOC_CLIENT_STATE="$(_diagnose_not_ready "$ns" "$jm")"
  fi
  return 0
}

# Classify why the client isn't Ready, for an accurate message. Echoes a state.
# Every match below reads a captured variable through a here-string, never a
# pipe: `grep -q` closes the pipe at its first hit, and under pipefail a
# SIGPIPE'd producer returns 141, which every `if` here would read as "no
# match" -- silently downgrading a real bad_creds/image_pull/crash diagnosis
# to "starting" and handing the user the wrong remedy (backend#1778).
_diagnose_not_ready() {
  local ns="$1" jm="${2:-}" pods jm_logs=""
  # Wrong credentials: jobs-manager authenticates to the backend on startup and
  # crash-loops when rejected — surfaced as an auth error in its logs. The
  # Deployment's name is the one the readiness gate already READ (backend#2888),
  # or read here when this is called without it; unresolvable means no logs to
  # classify, which falls through to the pod-state checks below.
  [[ -n "$jm" ]] || jm="$(_client_workload_name "$ns" jobs-manager 5s)" || jm=""
  if [[ -n "$jm" ]]; then
    jm_logs="$(kubectl logs -n "$ns" "deployment/${jm}" --all-containers --tail=50 --request-timeout=5s 2>/dev/null || true)"
  fi
  if grep -qiE 'authentication failed|unable to log in' <<<"$jm_logs"; then
    printf 'bad_creds'; return
  fi
  pods="$(kubectl get pods -n "$ns" --request-timeout=5s 2>/dev/null || true)"
  if grep -qiE 'ImagePullBackOff|ErrImagePull|InvalidImageName' <<<"$pods"; then
    # On a TLS-inspecting network the pull fails x509 because the nodes don't trust
    # the corporate CA (#424). Distinguish it from a generic pull error so the
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

# Reports the outcome based on TRACEBLOC_CLIENT_STATE (set by wait_for_client_ready).
# The "secure compute environment / your data never leaves" claim is printed
# ONLY when the client is verifiably connected — never on a partial/failed run.
# One-line note in the success summary so the user knows how the client comes
# back after a reboot. Linux with docker.service enabled on boot → automatic;
# Linux without it (Tier 0's zero-privilege path, or opted out) → the user has to
# start Docker first; macOS/Windows → Docker Desktop must be launched.
_reboot_note() {
  # Single dim footer line — the LAST line of the summary.
  # Native k3s (TRACEBLOC_SUBSTRATE_RESOLVED=k3s) has no Docker: k3s's install enables the k3s
  # service on boot, and the node is this host, so the cluster returns with it.
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    echo -e "  ${DIM}After a reboot, tracebloc restarts automatically with the k3s service (check it with: systemctl status k3s).${RESET}"
  elif [[ "$OS" != "Linux" ]]; then
    if [[ "${TB_MACOS_AUTOSTART:-0}" == "1" ]]; then
      # macOS autostart configured (_install_macos_autostart, #430): the runtime starts on
      # boot/login and the k3d --restart policy brings the cluster back → zero action. Don't
      # name a specific mechanism here — GUI installs a LaunchAgent (login item) but headless
      # installs a system LaunchDaemon (not a login item), so "login item" would mislead IT
      # on a headless box (#430 Bugbot).
      echo -e "  ${DIM}After a reboot, tracebloc restarts automatically.${RESET}"
    elif [[ "${TB_MACOS_HEADLESS_NO_AUTOSTART:-0}" == "1" ]]; then
      # Headless Tier 0 skipped the boot LaunchDaemon rather than prompt for a
      # password (setup-macos.sh, client#704). The generic branch below is the
      # GUI fallback and would say "open Docker Desktop" — a runtime that is not
      # what runs here and an action there is no desktop to perform, directly
      # contradicting the hint the skip already printed.
      #
      # The COMMAND comes from the skip site, which resolved it against this
      # host, rather than being hardcoded here: on a headless Mac the runtime is
      # usually colima but not always, and naming a binary that is not installed
      # is the same defect in the opposite direction (Bugbot, client#704).
      if [[ -n "${TB_MACOS_MANUAL_RUNTIME_CMD:-}" ]]; then
        echo -e "  ${DIM}After a reboot, run '${TB_MACOS_MANUAL_RUNTIME_CMD}' to bring tracebloc back.${RESET}"
      else
        echo -e "  ${DIM}After a reboot, start your Docker runtime to bring tracebloc back.${RESET}"
      fi
    else
      # macOS/Windows fallback: Docker Desktop owns boot autostart and must be launched.
      echo -e "  ${DIM}After a reboot, open Docker Desktop to bring tracebloc back.${RESET}"
    fi
  elif [[ "${TB_DOCKER_AUTOSTART:-0}" == "1" ]]; then
    # docker.service is enabled on boot (ensure_cluster_autostart) and the k3d
    # nodes carry --restart unless-stopped → the cluster returns on its own.
    echo -e "  ${DIM}After a reboot, tracebloc restarts automatically.${RESET}"
  else
    # We did NOT enable docker.service (Tier 0, or the user opted out): the k3d
    # restart policy still brings the cluster back, but only once Docker itself is
    # running — so be honest and don't promise it happens automatically.
    echo -e "  ${DIM}After a reboot, start Docker to bring tracebloc back.${RESET}"
  fi
}

# _summary_kubeconfig_hint -- the merged kubeconfig a native k3s user must name, with
# $HOME as ~ for them to type, or NO OUTPUT when there is none. Native k3s links
# kubectl to k3s, and with no KUBECONFIG that kubectl reads k3s's own k3s.yaml
# (context default, no namespace), never the merged file.
# _native_k3s_merge_kubeconfig sets the hint only when the user had no KUBECONFIG;
# k3d never needs it.
#
# It always exits 0; callers test the output (`[[ -n "$kc" ]]`). A "no hint" exit 1
# was recorded as a failure by the installer's ERR trap: `set -E` carries the trap
# into the `$(...)` of `if kc="$(...)"`, where the status is not in a condition, so
# every successful k3d install logged `err: … summary.sh … cmd=return 1` after its
# success screen (backend#5025 O-103).
_summary_kubeconfig_hint() {
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && -n "${TB_K3S_KUBECONFIG_HINT:-}" ]]; then
    local kc="$TB_K3S_KUBECONFIG_HINT"
    # shellcheck disable=SC2088  # the ~ is for the user to read, as in logdisp below
    if [[ -n "${HOME:-}" && "$kc" == "$HOME"/* ]]; then kc="~${kc#"$HOME"}"; fi
    printf '%s' "$kc"
  fi
  return 0
}

# The installer switched kubectl's current context to this cluster (it must: the
# secure environment is registered against the current context), and a user who
# also works on other clusters needs to hear that, with the way back, or their
# next kubectl lands here (backend#5025 O-19). _merge_kubeconfig sets
# TB_PREV_KUBE_CONTEXT only when a DIFFERENT context was selected before, so a
# fresh machine and a re-run print nothing.
#
# On native k3s with no KUBECONFIG, the user's kubectl is k3s's, which reads k3s.yaml
# and never the merged file that holds the previous context, so a bare `use-context`
# would not reach it; the command names that file (_summary_kubeconfig_hint).
_kube_context_note() {
  [[ -n "${TB_PREV_KUBE_CONTEXT:-}" ]] || return 0
  local kc="" kcflag=""
  kc="$(_summary_kubeconfig_hint)"
  if [[ -n "$kc" ]]; then kcflag="--kubeconfig ${kc} "; fi
  echo -e "  kubectl now points at ${TRACEBLOC_KUBE_CONTEXT:-${TB_KUBE_CONTEXT:-k3d-${CLUSTER_NAME:-tracebloc}}} (it pointed at ${TB_PREV_KUBE_CONTEXT} before). To switch back:"
  echo -e "    ${TB_CMD}kubectl ${kcflag}config use-context ${TB_PREV_KUBE_CONTEXT}${RESET}"
  echo ""
}

# Will `tracebloc` resolve in the user's shell? Rely SOLELY on TB_CLI_USABLE_NOW,
# which install-cli.sh sets from a FRESH-shell probe (_cli_on_fresh_path). A
# `has tracebloc` fallback would be WRONG here: install.sh and provision.sh both
# prepend ~/.local/bin to THIS process's PATH, so the installer can resolve
# tracebloc even when the user's launching shell cannot — exactly the
# "command not found in a new terminal" case B2 exists to catch (Bugbot #371).
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
# install record gains nothing. The k3d node-image prepull (k3d.sh) is a different
# pull, with its own switch (TRACEBLOC_SKIP_GPU_IMAGE_PREPULL).

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

# _prepull_store_path SUBSTRATE -- the directory whose filesystem holds SUBSTRATE's
# image store. k3d's node keeps its images inside its container, under Docker's data
# root. Native k3s keeps them in its containerd root, TB_K3S_DATA_PATH/agent/containerd:
# the kubelet's image filesystem, which a mount of its own can put on another disk
# than the data path (preflight measures it there too, _pf_disk_k3s). Exit 1, printing
# nothing, for a substrate this step does not know: the caller skips it by name.
_prepull_store_path() {
  case "$1" in
    k3d) _pf_docker_root ;;
    k3s) printf '%s' "${TB_K3S_DATA_PATH}/agent/containerd" ;;
    *) return 1 ;;
  esac
}

# _prepull_df SUBSTRATE DIR -- `df -Pk DIR`, bounded by TB_PREPULL_CALL_S. Native
# k3s's store sits below its agent/ directory, which k3s creates 0700
# (pkg/agent/run.go), so this user's df cannot reach it: it is read as root, as
# preflight reads it, and only when root answers without a password prompt -- this
# step never asks for one (exit 3). No fallback to the data path: that would measure
# another filesystem in exactly the case the store has its own, and a skipped prepull
# costs only the first training's pull. Exit 124 when df did not answer in time.
_prepull_df() {
  if [[ "$1" == k3s ]]; then
    _native_k3s_root_ready || return 3
    _bounded_root "$TB_PREPULL_CALL_S" df -Pk "$2"
  else
    _bounded "$TB_PREPULL_CALL_S" df -Pk "$2"
  fi
}

# _prepull_disk_rule DIR [SUBSTRATE] -- 0 when DIR's filesystem can take the parent's unpacked
# footprint (TB_PREPULL_PARENT_DISK_GB, stamped from facts.env) and still hold both:
# its use stays below the kubelet's image GC threshold
# (TB_KUBELET_IMAGE_GC_HIGH_PERCENT, the value the installer writes into the kubelet
# config: past it the kubelet collects images nothing references, the parent first),
# and at least PF_WARN_DISK_GB stays free (preflight's floor). Prints one line with
# the numbers either way: the free GB now and after, the threshold, DIR. Exit 1 when
# the rule fails, 2 when df cannot tell: it did not answer in time, root could not
# be asked without a prompt (k3s), or its answer was not numbers. SUBSTRATE decides
# how DIR is read (_prepull_df).
_prepull_disk_rule() {
  local dir="$1" sizes="" total_kb="" avail_kb="" need_kb after_kb pct_after rc=0
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
  need_kb=$(( TB_PREPULL_PARENT_DISK_GB * 1024 * 1024 ))
  after_kb=$(( avail_kb - need_kb ))
  # The kubelet's measure: used = capacity - available, as a share of capacity,
  # rounded up so the rule never reads a filesystem as emptier than it is.
  pct_after=$(( ( (total_kb - after_kb) * 100 + total_kb - 1 ) / total_kb ))
  printf '%s GB free on %s, %s GB after the parent (about %s GB): %s%% used against the kubelet image GC threshold of %s%%, with a floor of %s GB free' \
    "$(( avail_kb / 1024 / 1024 ))" "$dir" "$(( after_kb / 1024 / 1024 ))" "$TB_PREPULL_PARENT_DISK_GB" \
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

# _prepull_skip REASON -- the one log line for a stop, and the verdict.
_prepull_skip() {
  TB_PREPULL_VERDICT="skipped"
  log "training prepull: skipped: $1"
}

# _prepull_training_parent -- the step. Runs from main() after wait_for_client_ready
# and before print_summary; returns 0 always.
_prepull_training_parent() {
  local ns="${TB_NAMESPACE:-default}" out rc=0 name="" platforms="" manifest host store disk image
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
  if ! store="$(_prepull_store_path "${TRACEBLOC_SUBSTRATE_RESOLVED:-}")"; then
    _prepull_skip "substrate '${TRACEBLOC_SUBSTRATE_RESOLVED:-}' has no image store this step knows"; return 0
  fi
  rc=0; disk="$(_prepull_disk_rule "$store" "${TRACEBLOC_SUBSTRATE_RESOLVED:-}")" || rc=$?
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
  image="$(printf '%s\n' "$manifest" | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p')"
  image="${image%%$'\n'*}"
  rc=0
  out="$(printf '%s\n' "$manifest" | _bounded "$TB_PREPULL_CALL_S" kubectl apply -n "$ns" --request-timeout="${TB_PREPULL_CALL_S}s" -f - 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then _prepull_skip "the Job in ConfigMap ${name} could not be applied (kubectl exit ${rc}; its error is above in the log)"; return 0; fi
  TB_PREPULL_VERDICT="applied"
  log "training prepull: applied: ${out%%$'\n'*} (${image:-?}, about ${TB_PREPULL_PARENT_DISK_GB} GB on disk); not waiting for it"
  info "Downloading the GPU training base image in the background (${image:-?}, about ${TB_PREPULL_PARENT_DISK_GB} GB on disk)."
  return 0
}

# _prepull_summary_line -- the step's verdict, under Mode, on a GPU-wired host only:
# a CPU host has nothing to download ahead, and the line would be noise there.
_prepull_summary_line() {
  _gpu_wired || return 0
  case "${TB_PREPULL_VERDICT:-}" in
    applied) echo -e "  ${TB_LABEL}GPU images${RESET}  : downloading in the background" ;;
    skipped) echo -e "  ${TB_LABEL}GPU images${RESET}  : not downloaded yet; your first GPU training downloads them (the install log says why)" ;;
  esac
  return 0
}

print_summary() {
  # NVIDIA "GPU mode" only when the GPU was actually WIRED into the cluster
  # (_gpu_wired) — a detected-but-not-wired GPU runs CPU-only, and printing
  # "NVIDIA GPU" there is exactly the false claim client#835 removes. AMD keys on
  # detection (it has no k3d wiring step).
  local mode="CPU"
  if _gpu_wired; then
    mode="NVIDIA GPU"
    # Native k3s: the runtime is wired, but the node advertised no GPU after the
    # install (k3s.sh _native_k3s_gpu_verify, which warned with the remedy).
    [[ -z "${TB_K3S_GPU_UNCONFIRMED:-}" ]] || mode="NVIDIA GPU, not confirmed (see the GPU warning above)"
  elif [[ "$GPU_VENDOR" == "amd" ]]; then
    mode="AMD GPU"
  fi
  local ns="${TB_NAMESPACE:-default}"
  local cver; cver="$(_chart_version "$ns")"
  # Footer log path: HOST_DATA_DIR with $HOME collapsed to ~ (e.g. ~/.tracebloc).
  local logdisp="${HOST_DATA_DIR:-$HOME/.tracebloc}"
  local kdata
  if [[ -n "${HOME:-}" && "$logdisp" == "$HOME"* ]]; then logdisp="~${logdisp#"$HOME"}"; fi

  echo ""
  case "$TRACEBLOC_CLIENT_STATE" in
    connected)
      echo -e "  ${TB_GO}✔${RESET} ${BOLD}Connected to tracebloc${RESET}"
      echo ""
      echo -e "  ${TB_LABEL}Environment${RESET} : ${ns}"
      echo -e "  ${TB_LABEL}Version${RESET}     : ${cver:-unknown}"
      echo -e "  ${TB_LABEL}Mode${RESET}        : ${mode}"
      _prepull_summary_line
      echo ""
      echo -e "  ${TB_HEADING}Your secure environment is live${RESET} 🟢"
      echo -e "    See it on your dashboard:  ${TB_LINK}$(_dashboard_url)${RESET}"
      echo ""
      # "What's next" is a heading (cyan) — the primary call to action, not dim.
      echo -e "  ${TB_HEADING}What's next${RESET}"
      echo -e "    1. Ingest your data       ${TB_CMD}tracebloc data ingest${RESET}"
      echo -e "    2. Create a use case      ${TB_LINK}$(_dashboard_url my-use-cases)${RESET}"
      echo -e "    3. Invite collaborators — ${TB_DESC}they train on your data; it never leaves this machine${RESET}"
      echo ""
      if _cli_runnable_now; then
        echo -e "  ${BOLD}Run  ${TB_CMD}tracebloc${RESET}${BOLD}  to get started.${RESET}"
      elif [[ "${TRACEBLOC_CLI_ON_FRESH_PATH:-}" == "0" ]]; then
        # Case B: install-cli.sh RAN and set the flag to 0 — it printed the EXACT
        # PATH fix above and a new terminal won't help. Point at that fix, not a
        # useless "open a new terminal" (Bugbot #371). The explicit "0" test matters:
        # an UNSET flag (CLI step skipped/failed → nothing printed above) must NOT
        # land here, or "see above" points at nothing.
        echo -e "  ${BOLD}Add tracebloc to your PATH (see above), then run  ${TB_CMD}tracebloc${RESET}${BOLD}  to get started.${RESET}"
      else
        # Case A (flag=1: installed to ~/.local/bin, persisted — a new terminal
        # resolves it, only this shell doesn't) OR the flag is UNSET (the CLI step
        # was skipped/failed, so no PATH-fix guidance exists): the safe, honest
        # default is "open a new terminal" (Bugbot #371).
        echo -e "  ${BOLD}Open a new terminal, then run  ${TB_CMD}tracebloc${RESET}${BOLD}  to get started.${RESET}"
      fi
      echo ""
      _kube_context_note
      echo -e "  ${DIM}────────────────────────────────────────${RESET}"
      # Data location depends on the storage model: hostpath binds /tracebloc on
      # the host; node-local (RFC-0003 Option C) keeps datasets inside the node on
      # k3s local-path, so there is no host /tracebloc to point the user at.
      if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
        # Native k3s: the volumes are on this host, in local-path's storage path.
        # The reader answers 2 or 3 (config.yaml unreadable; sudo expired after a long
        # install) with nothing on stdout: say where the data is only when it told us.
        kdata="$(_native_k3s_storage_path)" || kdata=""
        if [[ -n "$kdata" ]]; then
          echo -e "  ${DIM}Logs ${logdisp}  ·  Data ${kdata} (k3s local-path)${RESET}"
        else
          echo -e "  ${DIM}Logs ${logdisp}  ·  Data in k3s local-path on this host${RESET}"
        fi
      elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        echo -e "  ${DIM}Logs ${logdisp}  ·  Data in-node (k3s local-path)${RESET}"
      else
        echo -e "  ${DIM}Logs ${logdisp}  ·  Data /tracebloc/${ns}${RESET}"
      fi
      _reboot_note
      ;;
    starting)
      echo -e "  ${TB_WARN}⚠${RESET}  Almost there — tracebloc is installed but still starting."
      echo ""
      echo -e "  Components are still downloading/starting (first run can take a few minutes)."
      echo -e "  Check progress:   ${TB_CMD}kubectl get pods -n ${ns}${RESET}"
      echo ""
      echo -e "  Your client will show as ${BOLD}🟢 Online${RESET} at ${TB_LINK}$(_dashboard_url)${RESET}"
      echo -e "  once it finishes. ${DIM}Re-running this installer is safe.${RESET}"
      ;;
    bad_creds)
      echo -e "  ${TB_ERR}✖ Couldn't connect — your Client ID or password was rejected.${RESET}" >&2
      echo ""
      echo -e "  The environment installed, but tracebloc refused those credentials."
      echo -e "    1. Re-check them at ${TB_LINK}$(_dashboard_url)${RESET}"
      echo -e "    2. Re-run this installer ${DIM}(safe to re-run)${RESET}"
      ;;
    image_pull_ca)
      echo -e "  ${TB_ERR}✖ Setup didn't finish — the cluster does not trust your network's TLS-inspection CA.${RESET}" >&2
      echo ""
      echo -e "  Your network intercepts HTTPS (break-and-inspect), so the in-cluster image"
      echo -e "  pulls fail certificate validation (x509). Point the installer at your"
      if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
        # Native k3s reads the CA from /etc/rancher/k3s/registries.yaml each time
        # the k3s service starts, so a re-run that writes it is the whole remedy:
        # nothing is released and nothing is deleted.
        echo -e "  corporate CA bundle so k3s trusts it. k3s reads the CA each time its"
        echo -e "  service starts, so re-running with the CA rewrites it and restarts k3s"
        echo -e "  (systemctl restart k3s):"
      else
        echo -e "  corporate CA bundle so the nodes trust it. CA trust is baked in at"
        echo -e "  cluster-create, so release this machine's secure environment and delete the"
        echo -e "  cluster first, then re-run with the CA. Releasing comes FIRST: the record is tied"
        echo -e "  to the cluster, so deleting the cluster alone strands it on your dashboard:"
        echo -e "    ${TB_CMD}tracebloc delete --keep-data${RESET}   ${DIM}(releases it; keeps your local data)${RESET}"
        echo -e "    ${TB_CMD}k3d cluster delete ${CLUSTER_NAME:-tracebloc}${RESET}"
      fi
      echo -e "    ${TB_CMD}TRACEBLOC_CA_BUNDLE=/path/to/corporate-ca.pem ${TB_INSTALL_CMD:-./install.sh}${RESET}"
      echo -e "  ${DIM}(CURL_CA_BUNDLE is also honored.) Ask your IT team for the bundle if unsure.${RESET}"
      echo -e "  Inspect:  ${TB_CMD}kubectl get events -n ${ns} | grep -i x509${RESET}"
      echo -e "  ${DIM}Re-running this installer is safe.${RESET}"
      ;;
    image_pull|crash)
      local reason="a component didn't start"
      [[ "$TRACEBLOC_CLIENT_STATE" == "image_pull" ]] && reason="an image couldn't be pulled"
      [[ "$TRACEBLOC_CLIENT_STATE" == "crash" ]] && reason="a container is restarting (crash loop)"
      echo -e "  ${TB_ERR}✖ Setup didn't finish — ${reason}.${RESET}" >&2
      echo ""
      echo -e "  Inspect:  ${TB_CMD}kubectl get pods -n ${ns}${RESET}"
      echo -e "  Logs:     ${DIM}~/.tracebloc/install-*.log${RESET}"
      echo -e "  ${DIM}Re-running this installer is safe.${RESET}"
      ;;
  esac
  # A native k3s user with no KUBECONFIG reads the release only through the merged
  # file (_summary_kubeconfig_hint). Every outcome above names a kubectl command, so
  # every outcome ends with the line.
  local kc=""
  kc="$(_summary_kubeconfig_hint)"
  if [[ -n "$kc" ]]; then
    echo ""
    echo -e "  To point kubectl at tracebloc, run this in your shell (add it to your profile to keep it):"
    echo -e "    ${TB_CMD}export KUBECONFIG=${kc}${RESET}"
  fi
  echo ""
  # Every other outcome sends the user to kubectl too; the connected one says it
  # above its footer, so the reboot note stays its last line.
  if [[ "$TRACEBLOC_CLIENT_STATE" != "connected" ]]; then _kube_context_note; fi

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
      # The class is `nvidia` on k3d, and the runtime step c's gate found on native
      # k3s (common.sh _gpu_runtime_class).
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
  local kdata
  log ""
  log "=== Advanced Info (for debugging) ==="
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    kdata="$(_native_k3s_storage_path)" || kdata=""
    log "Volumes: ${kdata:-path not readable without root} (k3s local-path, on this host)"
  else
    log "Volume mount: $HOST_DATA_DIR → /tracebloc"
  fi
  log ""
  log "Useful commands:"
  log "  kubectl get nodes -o wide"
  log "  kubectl get pods -A"
  log "  kubectl get pods -n ${TB_NAMESPACE:-default}"
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    log "  sudo systemctl stop k3s"
    log "  sudo systemctl start k3s"
    log "  systemctl status k3s"
    log "  journalctl -u k3s"
  else
    log "  k3d cluster stop $CLUSTER_NAME"
    log "  k3d cluster start $CLUSTER_NAME"
    log "  k3d cluster delete $CLUSTER_NAME"
  fi
  if _gpu_wired; then
    # runtimeClassName: nvidia is REQUIRED — the GPU node's containerd invokes the
    # NVIDIA runtime only for that class (client#835); a plain pod gets no GPU.
    log "  GPU test: $(_gpu_test_cmd nvidia)"
  fi
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    log "  GPU test: $(_gpu_test_cmd amd)"
  fi
  log "=== End Advanced Info ==="
}
