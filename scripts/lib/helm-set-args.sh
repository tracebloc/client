#!/usr/bin/env bash
# =============================================================================
#  helm-set-args.sh — the --set / --set-string arguments install_client_helm
#  hands helm: value escaping, host OS / SELinux / Mac node profile and runner,
#  the GPU decision and request, the collector choice, and Mac node storage.
# =============================================================================

# _helm_set_string_escape VALUE -- VALUE as one `helm --set-string key=VALUE` value:
# helm splits --set on an unescaped comma and reads a backslash as an escape, so both
# are escaped: a backslash becomes two, then a comma becomes backslash-comma.
# Everything else, apostrophes and = included, is literal there. Pure.
_helm_set_string_escape() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//,/\\,}"
}

# _gpu_unsupported_set_args -- the three --set-string pairs that tell the chart why the
# GPU was left off as unsupported (the contract shared with
# the other installers): env.GPU_UNSUPPORTED_REASON (one sentence),
# env.GPU_UNSUPPORTED_NAME (the card) and env.GPU_UNSUPPORTED_CODE (the kind the
# dashboard switches on), from detect-gpu.sh. ALWAYS all three keys,
# empty when the GPU is supported or absent, so a reconciled release never keeps a
# stale reason. Into _TB_GPU_UNSUPPORTED_ARGS (an array, bash-3.2 safe).
_gpu_unsupported_set_args() {
  _TB_GPU_UNSUPPORTED_ARGS=(
    --set-string "env.GPU_UNSUPPORTED_REASON=$(_helm_set_string_escape "${TB_GPU_UNSUPPORTED_REASON:-}")"
    --set-string "env.GPU_UNSUPPORTED_NAME=$(_helm_set_string_escape "${TB_GPU_UNSUPPORTED_NAME:-}")"
    --set-string "env.GPU_UNSUPPORTED_CODE=$(_helm_set_string_escape "${TB_GPU_UNSUPPORTED_CODE:-}")"
  )
}

# _host_os_set_args -- the host's OS for the dashboard, as one
# --set-string pair: env.TRACEBLOC_HOST_OS from _host_os_label (host.sh). The
# canonical name only: the variable is new, so it has no legacy spelling.
# ALWAYS passed, empty when the host cannot be read, so a reconciled release never
# keeps another machine's answer. Into _TB_HOST_OS_ARGS (an array, bash-3.2 safe).
# Inside WSL2 the label is the Windows host's, and the host is asked once for it
# and the machine facts alike (_prime_windows_host_identity).
_host_os_set_args() {
  _prime_windows_host_identity
  _TB_HOST_OS_ARGS=(
    --set-string "env.TRACEBLOC_HOST_OS=$(_helm_set_string_escape "$(_host_os_label)")"
  )
}

# _selinux_set_args -- selinux.confine as one --set pair, into _TB_SELINUX_ARGS: true
# only when native k3s on this Linux host runs confined, as its config.yaml says
# (_native_k3s_selinux_confined), so the chart's level and k3s's --selinux never
# disagree. false everywhere else. A config.yaml that cannot be read passes nothing,
# which keeps the release's stored value.
_selinux_set_args() {
  local rc=0
  _TB_SELINUX_ARGS=()
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" != "Darwin" ]] \
     && declare -F _native_k3s_selinux_confined >/dev/null 2>&1; then
    _native_k3s_selinux_confined || rc=$?
  else
    rc=1
  fi
  case "$rc" in
    0) _TB_SELINUX_ARGS=(--set "selinux.confine=true") ;;
    1) _TB_SELINUX_ARGS=(--set "selinux.confine=false") ;;
  esac
}

# TB_MAC_NODE_PROFILE -- the macOS node's values profile (one KEY=VALUE a word): the one declaration of it. The walls a Mac's
# cluster keeps, whatever runs in it, CPU pods today and the Apple GPU runner's jobs later:
#   restrictedDns.enabled=true  training and ingestion pods resolve the cluster's own names
#                               only, through the chart's restricted resolver, and reach
#                               the backend through the egress gateway, which resolves for
#                               them (values.yaml `restrictedDns`): a pod cannot carry data
#                               out in a DNS query's name (D10 item 6).
# The local API (the chart's one NodePort) is not a wall, so it is not here. It rides
# TB_LOCAL_API_MAPPED: on, with the four --set pairs, when this run's node
# publishes it on 127.0.0.1 and its packet filter lets this Mac alone to its NodePort
# (mac-container.sh, _mac_ct_local_api; which amends D10 item 4 by
# Lukas's decision of 2026-10-19); off when the user opted out or the port was refused.
# The filter, not the chart, keeps every other VM on this Mac off every NodePort.
TB_MAC_NODE_PROFILE=(restrictedDns.enabled=true)

# _mac_node_profile_set_args -- TB_MAC_NODE_PROFILE as --set pairs, and jobData.path when
# the release keeps its job data on this Mac (_mac_ct_job_data_dir), into
# _TB_MAC_PROFILE_ARGS, on the macOS node (native k3s on a Mac); empty anywhere else, which
# keeps an operator's own choice of the same keys. Every helm call this installer makes
# on the Mac passes them: the fresh install, dev mode and the adopt reconcile. --set
# outranks --values whatever their order, so neither the values file the installer writes,
# nor a caller's own (TRACEBLOC_VALUES_FILE), nor a release's stored values turns a wall
# off, as with the GPU decision (_gpu_decision_set_args); --reset-then-reuse-values, the
# reconcile's and the hourly auto-upgrade's, keeps them in the release.
_mac_node_profile_set_args() {
  _TB_MAC_PROFILE_ARGS=()
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]] || return 0
  local kv
  local jd
  for kv in "${TB_MAC_NODE_PROFILE[@]}"; do  # set-u-safe: TB_MAC_NODE_PROFILE is declared non-empty above
    _TB_MAC_PROFILE_ARGS+=(--set "$kv")
  done
  log "The macOS node's values profile: ${TB_MAC_NODE_PROFILE[*]}."  # set-u-safe: declared non-empty above
  # The job-data folder, when the release keeps its job data on this
  # Mac: the chart puts the dataset, logs and resume claims there. A string, so a path
  # is never read as a number or a list (_helm_set_string_escape).
  jd="$(_mac_ct_job_data_dir)"
  [[ -n "$jd" ]] || return 0
  _TB_MAC_PROFILE_ARGS+=(--set-string "jobData.path=$(_helm_set_string_escape "$jd")")
  log "The macOS node's job data: ${jd}."
}

# _gpu_decision_set_args -- THIS run's GPU decision as helm args, for the two paths that
# install over values the installer did not just write: the adopt reconcile (a release's
# stored values, --reuse-values) and dev mode (the caller's TRACEBLOC_VALUES_FILE).
# Both would otherwise keep a GPU decision this run did not make: a
# vendor-changed edge training on the wrong resource, an NVIDIA edge dropped to CPU (step c
# left TRACEBLOC_GPU_WIRED=0) still requesting a GPU and stranding jobs
# Pending, or a wired GPU host with every key empty and no device plugin, so the node
# advertises 0 GPUs. The values are the SAME the fresh write
# chooses (_gpu_request_value, _gpu_runtime_class, _detect_device_type), each as
# --set-string:
#   env.GPU_REQUESTS, env.GPU_LIMITS, env.RUNTIME_CLASS_NAME: --set-string, so helm does
#     not type-infer the value's '='/'/' or read dots as key navigation; empty
#     deliberately clears a stale request ("" means "no GPU here");
#   env.DEVICE_TYPE: the chassis verdict; empty when unreadable, which the
#     chart skips, so jobs-manager omits the key;
#   the unsupported reason (_gpu_unsupported_set_args), empty clears it;
#   the device-plugin block: nvidia only when wired (it needs the NVIDIA RuntimeClass:
#     on native k3s the one k3s creates for the runtime step c's gate found; kube.sh's
#     _gpu_runtime_class), amd on detection, else disabled.
# --set and --set-string outrank --values in helm whatever their order, so this run's
# decision wins over a values file's own GPU keys, an explicit "" included. Into
# _TB_GPU_DECISION_ARGS (an array, bash-3.2 safe, never empty).
_gpu_decision_set_args() {
  local gpu_val rtc=""
  gpu_val="$(_gpu_request_value)"
  if _gpu_wired; then rtc="$(_gpu_runtime_class)"; fi
  _TB_GPU_DECISION_ARGS=(
    --set-string "env.GPU_REQUESTS=$gpu_val"
    --set-string "env.GPU_LIMITS=$gpu_val"
    --set-string "env.RUNTIME_CLASS_NAME=$rtc"
    --set-string "env.DEVICE_TYPE=$(_detect_device_type "$gpu_val")"
  )
  _gpu_unsupported_set_args
  _TB_GPU_DECISION_ARGS+=("${_TB_GPU_UNSUPPORTED_ARGS[@]}")  # set-u-safe: _gpu_unsupported_set_args always assigns six words
  if _gpu_wired; then
    _TB_GPU_DECISION_ARGS+=(--set "gpu.devicePlugin.enabled=true"
                            --set "gpu.devicePlugin.vendor=nvidia"
                            --set-string "gpu.devicePlugin.nvidia.runtimeClassName=$rtc")
  elif [[ "${GPU_VENDOR:-}" == "amd" ]]; then
    _TB_GPU_DECISION_ARGS+=(--set "gpu.devicePlugin.enabled=true" --set "gpu.devicePlugin.vendor=amd")
  else
    _TB_GPU_DECISION_ARGS+=(--set "gpu.devicePlugin.enabled=false")
  fi
}

# _mac_runner_set_args -- appleGpuRunner.enabled=true as a --set pair, into
# _TB_MAC_RUNNER_ARGS, when this run sets up the Apple-GPU runner (_mac_ct_runner_on,
# mac-container.sh): the chart then renders the runner's ServiceAccount and its rights
# Empty otherwise, which keeps the release's stored value, as the macOS
# node's profile does. Every helm call that passes the profile passes this after it.
_mac_runner_set_args() {
  _TB_MAC_RUNNER_ARGS=()
  declare -F _mac_ct_runner_on >/dev/null 2>&1 || return 0
  _mac_ct_runner_on || return 0
  _TB_MAC_RUNNER_ARGS+=(--set "appleGpuRunner.enabled=true")
  log "The tracebloc runner: on (this tracebloc CLI carries it)."
  # The runner trains on this Mac's GPU only over the job-data folder the install record
  # names (_mac_ct_job_data_record): cli-dev's runner refuses the GPU without it, and the
  # training runs on the CPU. A run that keeps none says why, in the copy
  # catalog's words (scripts/testdata/golden/03-mac-gpu-no-training-folder.golden).
  local why
  if why="$(_mac_ct_job_data_none_why)"; then
    tb_machine_lines warn "This machine keeps no folder for training data, so training here can't use this Mac's GPU and will run on the CPU: ${why}."
    tb_machine_lines hint "To train on the GPU, run tracebloc delete, then install again with the default storage."
    warn_note "Training here will use the CPU, not this Mac's GPU." "$(_mac_ct_job_data_none_said "$why")" \
      "For the GPU, run \`tracebloc delete\`, then install again" "with the default storage."
    return 0
  fi
  # The runner takes this Mac's GPU jobs, so detect_gpu's not_nvidia, which the platform
  # reads as "CPU only" (no GPU in the training limit), is withdrawn: empty pairs after
  # the GPU decision's, so helm's last --set-string wins.
  [[ "${TB_GPU_UNSUPPORTED_CODE:-}" == not_nvidia ]] || return 0
  TB_GPU_UNSUPPORTED_CODE=""; TB_GPU_UNSUPPORTED_REASON=""; TB_GPU_UNSUPPORTED_NAME=""
  _gpu_unsupported_set_args
  _TB_MAC_RUNNER_ARGS+=("${_TB_GPU_UNSUPPORTED_ARGS[@]}")  # set-u-safe: _gpu_unsupported_set_args always assigns six words
}

# What the log Collector's opt-out says on the terminal (_collector_set_args), in the
# copy catalog's words (scripts/testdata/golden/09-usage-events-off.golden).
_TB_COLLECTOR_OFF_LINE="You turned off usage events, so tracebloc's services in your secure environment report none."
_TB_COLLECTOR_UNREAD_LINE="Couldn't read the settings this secure environment was installed with. If you had turned off the usage events of tracebloc's services, run the installer again with DO_NOT_TRACK=1 to keep them off."
_TB_COLLECTOR_UNAPPLIED_LINE="You turned off usage events, but the settings this secure environment was installed with couldn't be read, so this run leaves the usage events of tracebloc's services as they were. Run the installer again to turn them off."
_TB_COLLECTOR_KEPT_ON_LINE="You turned off usage events, but your Helm values set telemetryCollector.enabled: true, so the usage events of tracebloc's services still leave your secure environment."

# _values_collector_choice -- telemetryCollector.enabled in the values YAML on STDIN:
# true or false (any case), `other` for any other value, nothing when the key is absent
# or null. Reads to EOF, never exiting early, so a producer piping in is never SIGPIPE'd.
_values_collector_choice() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { match($0, /^ */); ind = RLENGTH }
    ind == 0 {
      inblk = ($0 ~ /^telemetryCollector:[[:space:]]*(#.*)?$/)
      if ($0 ~ /^telemetryCollector:[[:space:]]*[^[:space:]#]/ && $0 ~ /enabled[[:space:]]*:/) v = "other"
      child = -1
      next
    }
    !inblk { next }
    child < 0 { child = ind }
    ind == child && $0 ~ /^ *enabled:/ {
      v = $0
      sub(/^ *enabled:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
      lv = tolower(v)
      if (lv == "true" || lv == "false") v = lv
      else if (lv == "" || lv == "null" || lv == "~") v = ""
      else v = "other"
    }
    END { if (v != "") print v }
  '
}

# _release_collector_choice REL NS -- the release's stored telemetryCollector.enabled,
# true or false (a bool, the only value the chart reads as a choice); nothing when it
# stores none or there is no namespace or release (each read said "not found"). Exit 2,
# printing nothing, when a read failed for any other reason: whether it stores a choice
# cannot be told, and a failed read is never taken for a first install.
# THE STORED VALUES HOLD SECRETS (clientPassword and the rest): helm's
# output goes straight into the one-key reader in the same pipe and is never held in a
# variable, and its stderr is dropped, so only the choice and helm's exit status are
# ever seen, logged or traced. Whether a failed read means "no release" is asked of
# `helm list -q`, which prints release names only (_helm_release_listed).
_release_collector_choice() {
  local rel="$1" ns="$2" choice out rc=0
  [[ -n "$rel" && -n "$ns" ]] || return 0
  out="$(kubectl get namespace "$ns" --request-timeout=5s 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    case "$out" in *NotFound*|*"not found"*) return 0 ;; esac
    log "The log collector: whether namespace '$ns' exists cannot be told (kubectl exit $rc): ${out%%$'\n'*}"
    return 2
  fi
  rc=0
  choice="$(set -o pipefail
            _bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm get values "$rel" -n "$ns" 2>/dev/null </dev/null \
              | _values_collector_choice)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    case "$(_helm_release_listed "$rel" "$ns")" in
      no) log "The log collector: no release '$rel' in '$ns', so no stored choice."; return 0 ;;
    esac
    log "The log collector: the stored values of release '$rel' in '$ns' cannot be read (helm exit $rc)."
    return 2
  fi
  case "$choice" in
    true)  printf true ;;
    false) printf false ;;
  esac
}

# _helm_release_listed REL NS -- whether helm lists release REL in namespace NS, in
# any state: `yes`, `no`, or `unknown` when helm cannot list. Reads release names only
# (`helm list -q`), never a release's values. The states are named, as the one-client
# guard names them (_detect_installed_client): Helm 3 lists only deployed by default,
# and Helm 4 (the pinned v4.2.3) has no `-a`.
_helm_release_listed() {
  local rel="$1" ns="$2" names rc=0
  names="$(_bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm list -n "$ns" -q \
    --deployed --failed --pending --uninstalling --superseded --filter "^${rel}\$" 2>/dev/null </dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf unknown; return 0; fi
  if awk -v r="$rel" '$1 == r { f = 1 } END { exit !f }' <<<"$names"; then printf yes; else printf no; fi
}

# _collector_set_args MODE REL NS -- telemetryCollector.enabled for this run's helm call,
# into _TB_COLLECTOR_ARGS (an array, bash-3.2 safe). A choice already made wins: the
# caller's values file (TRACEBLOC_VALUES_FILE), which reaches helm as it is, else the
# release's stored bool, which MODE `reuse` (--reset-then-reuse-values) keeps by itself
# and MODE `fresh` (a call that replaces the stored values) carries forward, so a re-run
# never turns a choice back. With none made, an opt-out of usage events, by telemetry.sh's
# own rule (telemetry_enabled), passes false; else nothing is passed and the chart decides.
_collector_set_args() {
  local mode="$1" rel="$2" ns="$3" mine="" kept="" off=0 krc=0
  _TB_COLLECTOR_ARGS=()
  if declare -F telemetry_enabled >/dev/null 2>&1; then
    telemetry_enabled || off=1
  else
    log "The log collector: telemetry.sh is not loaded, so no opt-out of usage events is read; the chart decides."
  fi
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" && -r "${TRACEBLOC_VALUES_FILE}" ]]; then
    mine="$(_values_collector_choice < "$TRACEBLOC_VALUES_FILE")"
  fi
  if [[ -n "$mine" ]]; then
    log "The log collector: the values file sets telemetryCollector.enabled ($mine); this run passes nothing over it."
    if [[ "$off" == 1 && "$mine" == false ]]; then info "$_TB_COLLECTOR_OFF_LINE"; fi
    if [[ "$off" == 1 && "$mine" == true ]]; then info "$_TB_COLLECTOR_KEPT_ON_LINE"; fi
    return 0
  fi
  kept="$(_release_collector_choice "$rel" "$ns")" || krc=$?
  # The fresh call replaces the stored values, so a stored opt-out it could not read is
  # dropped there: said on the terminal, unless an opt-out set now passes false below.
  if [[ "$krc" -ne 0 && "$mode" == fresh && "$off" != 1 ]]; then
    warn "$_TB_COLLECTOR_UNREAD_LINE"
  fi
  # The reconcile keeps the stored values by itself, so an opt-out set now passes nothing
  # over a choice it could not read: an operator's stored true is never overwritten unseen.
  if [[ "$krc" -ne 0 && "$mode" == reuse ]]; then
    if [[ "$off" == 1 ]]; then warn "$_TB_COLLECTOR_UNAPPLIED_LINE"; fi
    return 0
  fi
  if [[ -n "$kept" ]]; then
    [[ "$mode" == reuse ]] || _TB_COLLECTOR_ARGS=(--set "telemetryCollector.enabled=$kept")
    log "The log collector: release '$rel' stores telemetryCollector.enabled=$kept, which this run keeps."
    if [[ "$off" == 1 && "$kept" == false ]]; then info "$_TB_COLLECTOR_OFF_LINE"; fi
    if [[ "$off" == 1 && "$kept" == true ]]; then info "$_TB_COLLECTOR_KEPT_ON_LINE"; fi
    return 0
  fi
  [[ "$off" == 1 ]] || return 0
  _TB_COLLECTOR_ARGS=(--set "telemetryCollector.enabled=false")
  log "The log collector: off, as usage events are turned off."
  info "$_TB_COLLECTOR_OFF_LINE"
}

# _mac_node_storage_steps -- on the macOS node (native k3s on a Mac), before helm: the
# folders the release's PVs will name must be ones the node mounts, or the PVs would put
# the data inside its VM (mac-container.sh, _mac_ct_hostpath_mounted); then the job-data
# folder, when this run keeps one (_mac_ct_job_data_dir), is recorded
# (_mac_ct_job_data_record), the entry the Apple-GPU runner reads to train on the GPU.
# Both install paths run it: the normal one once _native_k3s_release_storage has read the
# release, and dev mode over the caller's file, which installs the folder too
# (_mac_node_profile_set_args) and once recorded nothing. A no-op anywhere
# else.
_mac_node_storage_steps() {
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]] || return 0
  _mac_ct_hostpath_mounted
  _mac_ct_job_data_record
}

# _gpu_request_value — the GPU resource a spawned training pod should request,
# keyed to the vendor. Each vendor advertises its card as a different
# Kubernetes resource, so the request key must match: nvidia.com/gpu for nvidia,
# amd.com/gpu for amd, empty (→ CPU) otherwise. Single source of truth so the
# values-write path (install_client_helm) and the adopt/reconcile path
# (_reconcile_adopted_client) can never disagree — the reconcile path reused the
# release's stored values and kept an AMD edge on an empty request, training on
# CPU while the node's GPU read "verified".
#
# NVIDIA is additionally gated on the GPU being WIRED into the cluster
# (_gpu_wired): requesting nvidia.com/gpu on a node that advertises 0 GPUs strands
# every job Pending, so a detected-but-not-wired NVIDIA host requests nothing (CPU).
# AMD has no wiring step (it uses the device plugin only), so it stays keyed on
# detection.
_gpu_request_value() {
  case "${GPU_VENDOR:-}" in
    nvidia) if _gpu_wired; then printf 'nvidia.com/gpu=1'; fi ;;
    amd)    printf 'amd.com/gpu=1' ;;
    *)      printf '' ;;
  esac
  return 0
}
