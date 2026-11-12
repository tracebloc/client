#!/usr/bin/env bash
# =============================================================================
#  install-client-helm.sh — Install Tracebloc client (steps 3 & 4)
#  Generates values from defaults + user prompts (workspace, clientId, clientPassword)
#  and GPU detection. Values file is written to host_data_dir/values.yaml.
# =============================================================================

# The xtrace hold (output.sh). A no-op with an output.sh from before it, so a mixed
# set of libs runs, unheld, rather than stopping on a missing command.
declare -F _tb_trace_off >/dev/null 2>&1 || _tb_trace_off() { :; }
declare -F _tb_trace_on >/dev/null 2>&1 || _tb_trace_on() { :; }

# Stamped from scripts/spec/facts.env by scripts/check-facts.sh — do not hand-edit.
# The Windows installer waits for the same APIService with the same TB_METRICS_WAIT_S
# knob, so the two defaults are one fact, gated in CI.
METRICS_WAIT_TIMEOUT=120

TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
TRACEBLOC_HELM_REPO_NAME="tracebloc"
TRACEBLOC_CHART_NAME="client"

_ensure_helm_runnable() {
  if helm version --short &>/dev/null; then
    return 0
  fi
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -z "$helm_bin" || ! -f "$helm_bin" ]]; then
    error "Installation tools are not available. Re-run the installer."
  fi
  if [[ ! -x "$helm_bin" ]]; then
    log "Helm at $helm_bin is not executable — fixing permissions"
    if sudo chmod 755 "$helm_bin" 2>/dev/null; then
      log "Helm permissions fixed."
      return 0
    fi
    error "Could not fix tool permissions. Run manually: sudo chmod 755 $helm_bin"
  fi
  error "Installation tools could not be run. Try: sudo chmod 755 $helm_bin then re-run this script."
}

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

# _detect_device_type GPU_VAL — what kind of machine this is, for the dashboard's
# secure-environment switcher. Prints one of the backend's enum
# `workstation | gpu_server | server | cluster`, or NOTHING when the chassis
# cannot be read: jobs-manager then omits the key from its heartbeat and the
# dashboard draws its default glyph rather than a guess.
#
# The installer is the one party that can tell a laptop from a rack server — it
# runs on the host and can read the chassis — which is why this lives here and
# not in jobs-manager (which can only count nodes, and node counts cannot tell a
# workstation from a server). Sources, in order:
#
#   TRACEBLOC_DEVICE_TYPE   an explicit override, for unattended installs and
#                           for the cases no chassis read gets right (a rack
#                           server used as somebody's desk machine). A value
#                           outside the enum is IGNORED with a warning, not
#                           written: the backend would drop it on every ping.
#   Darwin                  every Mac this installer supports sits on a desk
#                           (MacBook, iMac, Mac mini, Mac Studio, Mac Pro).
#   Linux                   `hostnamectl` Chassis (systemd's own verdict:
#                           laptop / desktop / convertible / tablet / handset /
#                           server / vm / container), then the SMBIOS
#                           chassis_type number under /sys/class/dmi/id as the
#                           fallback for hosts without systemd.
#
# A server-class chassis (or a VM — a VM is a server) becomes gpu_server when
# THIS run wires a GPU request (GPU_VAL, the same value written to GPU_LIMITS),
# else server. A desk-class chassis is a workstation whether or not it has a GPU:
# the dashboard's hardware line already names the card, and the glyph is about
# where the machine sits. `cluster` is never detected here — this installer's
# cluster is one host by construction; jobs-manager derives it from SINGLE_NODE on the clusters
# this installer does not build.
# Hypervisor signatures, matched case-insensitively as substrings of the DMI
# `sys_vendor product_name` pair (Windows: `Manufacturer Model`). A match means
# this host is a virtual machine, and a VM is a server whatever enclosure number
# its firmware reports: Hyper-V and Azure guests say 3 (Desktop), VMware says 1
# (Other), so the chassis number alone files them as workstations or as nothing
# Every entry names a hypervisor or a cloud's virtual
# platform, never a hardware maker -- `Microsoft Corporation` alone is also a
# Surface laptop, so Hyper-V is matched by its model, `Virtual Machine`.
_TB_VM_SIGNATURES=("virtual machine" "vmware" "virtualbox" "innotek" "qemu" "kvm" "xen" "bochs" "parallels" "amazon ec2" "google compute engine" "openstack" "digitalocean")

# _is_vm_signature "VENDOR PRODUCT" — 0 when the pair names a hypervisor.
_is_vm_signature() {
  local hay sig
  hay="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${hay//[[:space:]]/}" ]] || return 1
  for sig in "${_TB_VM_SIGNATURES[@]}"; do  # set-u-safe: _TB_VM_SIGNATURES is a file-scope constant
    [[ "$hay" == *"$sig"* ]] && return 0
  done
  return 1
}

# _chassis_from_smbios N... — desktop | laptop | server | "" for SMBIOS System
# Enclosure type numbers (DSP0134 §7.4.1). Any desk or portable number wins over
# a server one, for Windows' ChassisTypes array as for Linux's one number;
# one list for both callers below so they cannot drift.
_chassis_from_smbios() {
  local n desk="" lap="" srv=""
  for n in "$@"; do
    case "$n" in
      3|4|5|6|7|13|15|16|24|35|36) desk=1 ;;
      8|9|10|11|12|14|30|31|32)    lap=1 ;;
      17|23|25|28|29)              srv=1 ;;
    esac
  done
  if [[ -n "$lap" ]]; then printf 'laptop'
  elif [[ -n "$desk" ]]; then printf 'desktop'
  elif [[ -n "$srv" ]]; then printf 'server'
  fi
  return 0
}

# _windows_host_identity — inside WSL2, ask the WINDOWS HOST what it is, over
# interop. Prints one line,
# `Manufacturer|Model|ChassisTypes(csv)|PCSystemType|SMBIOSAssetTag|OSCaption`,
# or returns 1 when it cannot: interop off (no powershell.exe), no `timeout` to
# bound the call with, a hang, or a failure. The distro itself cannot answer:
# its DMI is Hyper-V's (`Microsoft Corporation` / `Virtual Machine`) and
# systemd calls it a `container`, so this is the only source
# that describes the machine the user is sitting at. Bounded, because a wedged
# interop must not stall the install; the verdict is cosmetic. --kill-after as
# well as the deadline: interop does not reliably deliver a
# Unix SIGTERM to a Windows .exe, and GNU timeout without it sends TERM and then
# WAITS -- a wedged Get-CimInstance would hold the install forever. KILL ends the
# Linux-side interop process, which closes the pipe this substitution reads.
# TRACEBLOC_WINDOWS_POWERSHELL is a test seam for the fallback path.
_windows_host_identity() {
  local ps="" out="" fallback="${TRACEBLOC_WINDOWS_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
  if command -v powershell.exe >/dev/null 2>&1; then ps="powershell.exe"
  elif [[ -x "$fallback" ]]; then ps="$fallback"
  fi
  [[ -n "$ps" ]] || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016  # the $ belong to PowerShell, not to this shell
  out="$(timeout --kill-after="${TB_WSL_INTEROP_KILL_AFTER:-5}" "${TB_WSL_INTEROP_TIMEOUT:-20}" "$ps" -NoProfile -NonInteractive -Command \
    '$c = Get-CimInstance Win32_ComputerSystem; $e = @(Get-CimInstance Win32_SystemEnclosure); $o = Get-CimInstance Win32_OperatingSystem; "{0}|{1}|{2}|{3}|{4}|{5}" -f $c.Manufacturer, $c.Model, (@($e.ChassisTypes) -join ","), $c.PCSystemType, $e[0].SMBIOSAssetTag, $o.Caption' \
    2>/dev/null)" || return 1
  out="${out//$'\r'/}"
  [[ "$out" == *"|"*"|"*"|"* ]] || return 1
  printf '%s' "$out"
}

# _windows_host_identity_once — _windows_host_identity, asked at most once per
# shell. Several facts are read from the one answer (the chassis, the cloud, the
# OS), and each interop call starts a Windows PowerShell. The answer is kept in
# globals, so it is shared only by what runs AFTER a call in THIS shell: a
# verdict computed in `$( )` keeps its own copy. _prime_windows_host_identity
# makes that one call in the caller's shell first. Returns 1 when it cannot tell.
_TB_WIN_HOST_IDENT=""
_TB_WIN_HOST_IDENT_READ=""
_windows_host_identity_once() {
  if [[ -z "${_TB_WIN_HOST_IDENT_READ:-}" ]]; then
    _TB_WIN_HOST_IDENT="$(_windows_host_identity)" || _TB_WIN_HOST_IDENT=""
    _TB_WIN_HOST_IDENT_READ=1
  fi
  [[ -n "${_TB_WIN_HOST_IDENT:-}" ]] || return 1
  printf '%s' "$_TB_WIN_HOST_IDENT"
}

# _prime_windows_host_identity — inside WSL2 only, read the Windows host's
# identity once in THIS shell, so the verdicts computed after it share it.
# Outside WSL2 (or without probe.sh, which a stale bootstrap may not have
# fetched) it does nothing.
_prime_windows_host_identity() {
  if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
    _windows_host_identity_once >/dev/null || true
  fi
  return 0
}

# _chassis_from_windows_identity "Manufacturer|Model|ChassisTypes|PCSystemType[|...]"
# — the Windows host's own ladder, read from inside WSL2: hypervisor signature
# first (a Windows host that is itself a VM is `vm`), then the enclosure numbers,
# then PCSystemType (2 Mobile is a laptop, 1/3 desk, 4/5 server). Fields after
# the fourth are ignored.
_chassis_from_windows_identity() {
  local maker model types pcs _rest chassis=""
  IFS='|' read -r maker model types pcs _rest <<<"${1:-}"
  if _is_vm_signature "$maker $model"; then printf 'vm'; return 0; fi
  # shellcheck disable=SC2086  # word-split the comma list into numbers on purpose
  chassis="$(_chassis_from_smbios ${types//,/ })"
  if [[ -z "$chassis" ]]; then
    case "${pcs//[[:space:]]/}" in
      2)   chassis="laptop" ;;
      1|3) chassis="desktop" ;;
      4|5) chassis="server" ;;
    esac
  fi
  printf '%s' "$chassis"
  return 0
}

# _windows_identity_field "IDENTITY" N — field N (1-based) of a
# _windows_host_identity line, or nothing. The OS caption is the LAST field, so
# it keeps any `|` of its own.
_windows_identity_field() {
  local f1 f2 f3 f4 f5 f6
  IFS='|' read -r f1 f2 f3 f4 f5 f6 <<<"${1:-}"
  case "${2:-}" in
    1) printf '%s' "$f1" ;; 2) printf '%s' "$f2" ;; 3) printf '%s' "$f3" ;;
    4) printf '%s' "$f4" ;; 5) printf '%s' "$f5" ;; 6) printf '%s' "$f6" ;;
  esac
  return 0
}

# _linux_chassis — this Linux host's chassis word, BEFORE any verdict collapses it:
# hostnamectl's own (laptop / desktop / convertible / tablet / handset / server /
# vm / container / ...), else `vm` for a hypervisor's DMI signature, else the
# SMBIOS enclosure number's class (laptop / desktop / server), else nothing.
# Outside WSL2 only: inside it neither source describes the machine (see
# _detect_device_type). The one ladder _detect_device_type and
# _detect_machine_kind both read, so the two cannot disagree about a host.
_linux_chassis() {
  # TRACEBLOC_DMI_DIR is a test seam only; real installs read the kernel's DMI table.
  local dmi="${TRACEBLOC_DMI_DIR:-/sys/class/dmi/id}" chassis=""
  # `hostnamectl` prints "  Chassis: laptop 💻" (the icon is newer systemd);
  # the first word is the verdict. `hostnamectl chassis` alone needs v249+.
  # LC_ALL=C on hostnamectl ITSELF: systemd translates the label
  # ("Gehäuse:", "Châssis:"), and a VM whose label went unmatched fell
  # through to DMI type 1 (Other) and was reported as "" instead of server.
  # LC_ALL=C on sed/awk too, so the icon's bytes cannot make them bail
  # (BSD sed: "illegal byte sequence").
  # This runs under the caller's errexit+pipefail, so a missing or failing
  # hostnamectl (no systemd, no D-Bus in a container) must fall through to
  # the DMI read, not abort the install; awk's NR==1 reads to EOF, so no
  # reader closes the pipe early.
  if command -v hostnamectl >/dev/null 2>&1; then
    chassis="$( { LC_ALL=C hostnamectl 2>/dev/null || true; } | LC_ALL=C sed -n 's/^[[:space:]]*Chassis:[[:space:]]*//p' | LC_ALL=C awk 'NR == 1 { print $1 }')" || chassis=""
  fi
  # No verdict from hostnamectl (absent, no systemd bus, or no Chassis line):
  # read DMI. The hypervisor signature comes FIRST -- hostnamectl reports
  # `vm` for a guest from systemd-detect-virt, and without it the enclosure
  # number is the firmware's claim, which for Hyper-V is 3 (Desktop).
  if [[ -z "$chassis" ]]; then
    if _is_vm_signature "$(_dmi_value "$dmi" sys_vendor) $(_dmi_value "$dmi" product_name)"; then chassis="vm"; fi
  fi
  if [[ -z "$chassis" && -r "$dmi/chassis_type" ]]; then
    chassis="$(_chassis_from_smbios "$(tr -d '[:space:]' < "$dmi/chassis_type" 2>/dev/null || true)")"
  fi
  printf '%s' "$chassis"
  return 0
}

# _dmi_value DIR NAME — the DMI field NAME under DIR (one line, trailing newline
# dropped), or nothing when it is absent or unreadable. Never fails.
_dmi_value() {
  [[ -r "$1/$2" ]] || return 0
  cat "$1/$2" 2>/dev/null || true
}

_detect_device_type() {
  local gpu_val="${1:-}" override="${TRACEBLOC_DEVICE_TYPE:-}" chassis=""
  if [[ -n "$override" ]]; then
    local wanted
    wanted="$(printf '%s' "$override" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$wanted" in
      workstation|gpu_server|server|cluster) printf '%s' "$wanted"; return 0 ;;
      # To stderr: callers capture this function's stdout as the verdict.
      *) warn "TRACEBLOC_DEVICE_TYPE=\"${override}\" is not one of workstation|gpu_server|server|cluster — ignoring it and reading the chassis instead." >&2 ;;
    esac
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) chassis="desktop" ;;
    Linux)
      # WSL2 FIRST. Inside WSL2 neither Linux source describes
      # the machine: systemd reports `container` and DMI is Hyper-V's, which the
      # VM check below would call a server -- so one laptop came out as nothing
      # or as a server depending on which source answered. Ask the Windows host
      # instead; when interop cannot answer, say nothing. `_probe_wsl` lives in
      # probe.sh, which a stale bootstrap may not have fetched; without it this
      # branch is skipped, the same rule cluster.sh applies.
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
        local ident=""
        if ident="$(_windows_host_identity_once)"; then
          chassis="$(_chassis_from_windows_identity "$ident")"
        fi
        case "$chassis" in
          laptop|desktop) printf 'workstation' ;;
          server|vm) if [[ -n "$gpu_val" ]]; then printf 'gpu_server'; else printf 'server'; fi ;;
          *) printf '' ;;
        esac
        return 0
      fi
      chassis="$(_linux_chassis)"
      ;;
  esac
  case "$chassis" in
    laptop|desktop|convertible|tablet|handset) printf 'workstation' ;;
    server|vm) if [[ -n "$gpu_val" ]]; then printf 'gpu_server'; else printf 'server'; fi ;;
    *) printf '' ;;   # container / embedded / unknown: say nothing
  esac
  return 0
}

# ── Machine facts for the dashboard ───────────────────────────────────────────
# What the installer reads off the host and the resource monitor cannot: a pod
# sees neither the chassis, nor the cloud's firmware strings, nor (in the macOS
# node's VM) the host's CPU name. Each is passed to the chart as one env var on the
# resource monitor (_machine_facts_set_args), which sends it on every heartbeat.
# A fact that cannot be read is EMPTY, and the chart then leaves the variable
# unset: the platform keeps what it had rather than store a guess. Each verdict
# is a word of the platform's closed vocabulary, or nothing.
#   TRACEBLOC_MACHINE_KIND    laptop | desktop | server | cloud
#   TRACEBLOC_CLOUD_PROVIDER  aws | azure | gcp
#   TRACEBLOC_HOST_CPU_NAME   macOS only ("Apple M3 Pro"); on Linux the node's
#                             own /proc/cpuinfo names the CPU.
# DEVICE_TYPE is not one of them and is unchanged: jobs-manager validates it
# against its own four words, so laptop and desktop still collapse there.
#
# Azure's virtual machines carry this fixed SMBIOS asset tag (Microsoft documents
# it as the way to tell an Azure VM from any other Hyper-V guest), which a plain
# Hyper-V guest does not.
_TB_AZURE_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"

# _cloud_from_identity VENDOR PRODUCT ASSET_TAG — aws | gcp | azure | "" from the
# firmware's strings, read on the host with no network call (no metadata
# service): "Amazon EC2" (the vendor on every Nitro instance) is aws, "Google
# Compute Engine" (the product) is gcp, and a Microsoft vendor WITH Azure's asset
# tag is azure. Matched case-insensitively.
_cloud_from_identity() {
  local hay maker tag
  hay="$(printf '%s %s' "${1:-}" "${2:-}" | tr '[:upper:]' '[:lower:]')"
  maker="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  tag="$(printf '%s' "${3:-}" | tr -d '[:space:]')"
  case "$hay" in
    *"amazon ec2"*)            printf 'aws'; return 0 ;;
    *"google compute engine"*) printf 'gcp'; return 0 ;;
  esac
  if [[ "$maker" == *microsoft* && "$tag" == "$_TB_AZURE_ASSET_TAG" ]]; then printf 'azure'; fi
  return 0
}

# _machine_kind_from_chassis CHASSIS CLOUD — laptop | desktop | server | cloud |
# "" from a chassis word (hostnamectl's, or _chassis_from_smbios /
# _chassis_from_windows_identity's) and the detected cloud. A known cloud is
# `cloud` whatever its chassis says: the cloud strings name only a cloud's own
# machines, a bare-metal instance included. Any other VM is a server.
_machine_kind_from_chassis() {
  if [[ -n "${2:-}" ]]; then printf 'cloud'; return 0; fi
  case "${1:-}" in
    laptop|convertible|tablet|handset) printf 'laptop' ;;
    desktop)   printf 'desktop' ;;
    server|vm) printf 'server' ;;
  esac
  return 0
}

# _detect_cloud_provider — aws | azure | gcp | "" for this host. Linux reads the
# DMI table; inside WSL2 the distro's DMI is Hyper-V's on every host, so the
# Windows host's own strings decide, and interop that cannot answer says
# nothing. macOS says nothing.
_detect_cloud_provider() {
  local dmi="${TRACEBLOC_DMI_DIR:-/sys/class/dmi/id}" ident=""
  [[ "$(uname -s 2>/dev/null)" == Linux ]] || return 0
  if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
    if ident="$(_windows_host_identity_once)"; then
      _cloud_from_identity "$(_windows_identity_field "$ident" 1)" "$(_windows_identity_field "$ident" 2)" \
        "$(_windows_identity_field "$ident" 5)"
    fi
    return 0
  fi
  _cloud_from_identity "$(_dmi_value "$dmi" sys_vendor)" "$(_dmi_value "$dmi" product_name)" \
    "$(_dmi_value "$dmi" chassis_asset_tag)"
  return 0
}

# _detect_machine_kind — laptop | desktop | server | cloud | "" for this host:
# the probes _detect_device_type reads, before it collapses laptop and desktop.
#   macOS   laptop when `pmset -g batt` lists an internal battery, else desktop;
#           nothing when pmset cannot answer.
#   WSL2    the Windows host's chassis (_chassis_from_windows_identity); nothing
#           when interop cannot answer.
#   Linux   _linux_chassis.
# A known cloud (_detect_cloud_provider) is `cloud` on every path.
_detect_machine_kind() {
  local chassis="" cloud="" batt="" ident=""
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      batt="$(pmset -g batt 2>/dev/null)" || return 0
      case "$batt" in
        *InternalBattery*) printf 'laptop' ;;
        *)                 printf 'desktop' ;;
      esac
      return 0
      ;;
    Linux)
      cloud="$(_detect_cloud_provider)"
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
        if ident="$(_windows_host_identity_once)"; then
          chassis="$(_chassis_from_windows_identity "$ident")"
        fi
      else
        chassis="$(_linux_chassis)"
      fi
      _machine_kind_from_chassis "$chassis" "$cloud"
      ;;
  esac
  return 0
}

# _detect_host_cpu_name — the host CPU's model name where the node cannot read it:
# macOS only, from `sysctl -n machdep.cpu.brand_string` ("Apple M3 Pro"), whose
# node VM's /proc/cpuinfo names no model on Apple silicon. Trimmed; nothing on
# any other OS, when sysctl cannot answer, or when the name is longer than the
# 200 characters the platform stores (a longer one is dropped, never cut).
_detect_host_cpu_name() {
  local name=""
  [[ "$(uname -s 2>/dev/null)" == Darwin ]] || return 0
  name="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" || return 0
  name="$(printf '%s' "$name" | LC_ALL=C tr -d '\r\n' | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "${#name}" -le 200 ]] || return 0
  printf '%s' "$name"
}

# _machine_facts_set_args -- the three machine facts above as --set-string pairs:
# env.TRACEBLOC_MACHINE_KIND, env.TRACEBLOC_CLOUD_PROVIDER and
# env.TRACEBLOC_HOST_CPU_NAME. Canonical names only: the variables are new, so
# they have no legacy spelling. ALWAYS all three keys, EMPTY when unknown, so a
# reconciled release never keeps another run's answer; the chart renders a key
# only when it is non-empty. Inside WSL2 the Windows host is asked once for all
# of them. Into _TB_MACHINE_FACTS_ARGS (an array, bash-3.2 safe, six words).
_machine_facts_set_args() {
  local kind cloud cpu
  _prime_windows_host_identity
  kind="$(_detect_machine_kind)"
  cloud="$(_detect_cloud_provider)"
  cpu="$(_detect_host_cpu_name)"
  log "Machine facts for the dashboard: kind=${kind:-unknown} cloud=${cloud:-none} cpu=${cpu:-not read}"
  _TB_MACHINE_FACTS_ARGS=(
    --set-string "env.TRACEBLOC_MACHINE_KIND=$(_helm_set_string_escape "$kind")"
    --set-string "env.TRACEBLOC_CLOUD_PROVIDER=$(_helm_set_string_escape "$cloud")"
    --set-string "env.TRACEBLOC_HOST_CPU_NAME=$(_helm_set_string_escape "$cpu")"
  )
}

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
  n="$(kubectl get pods -n "$1" --request-timeout="${2:-5s}" \
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
    pulled="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
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

# ── MySQL engine channel (decision A2 2026-08-05) ─────────────
# The chart's default is the multi-arch 8.4 engine by default; the frozen 5.7-lineage image is no longer a default anywhere,
# only an explicit pin (TB_MYSQL_57_PIN_* below) that this installer writes for
# an install it resolves to 5.7. `auto` picks 8.4 on every fresh install,
# whatever the arch: it used to pick 8.4 only on arm64 and keep
# fresh amd64 hosts on 5.7, so every new x86 install joined the 5.7 -> 8.4
# migration backlog the day it came up. Anything that smells like existing
# state stays 5.7: an existing release, or real mysql datadir content on the
# host (legacy or per-release layout). EVERY resolution is written down as an
# explicit image pin -- 8.4 as `tag "8.4"` + TB_MYSQL_84_DEFAULT_DIGEST, 5.7 as
# TB_MYSQL_57_PIN_* -- so what runs never depends on which engine a chart
# version defaults to: a 5.7 install that relied on the default would be moved
# onto 8.4 by the first chart that changed it, and 8.4 refuses a 5.7 datadir.
# A previous opt-in stays sticky across re-runs (the values file is
# regenerated every run, so it is re-derived from the old file first). The
# chart's mysql-format-guard init container backstops whatever this
# heuristic misses — a wrong pick fails loudly before mysqld starts, it
# never opens a datadir with the wrong engine.
#   TB_MYSQL_ENGINE=auto|5.7|8.4    explicit value always wins (default auto)
# Reads (bash dynamic scope, set by install_client_helm before the call):
# values_file, existing_id, host_data_dir, namespace. Not ARCH: the arch
# decides whether a 5.7 verdict can RUN here (_assert_engine_runs_on_this_arch),
# never which engine a fresh host gets.
# Sets: TB_MYSQL_ENGINE_RESOLVED.
#
# Two of those inputs are `local`s of install_client_helm, which has NOT run at
# preflight time — so the helpers below derive them, and preflight's arch gate
# calls the same helpers rather than restating the paths.
# The explicit pin for an install that stays on MySQL 5.7: the frozen
# 5.7-lineage `:prod` image the chart defaulted to until the 8.4 default switch. The
# chart's tracebloc.mysqlEngineMajor maps exactly this digest to "5.7", which
# keeps mysql-format-guard armed for these datadirs; install-client-helm.bats
# holds both values against the chart's own literal, so they cannot drift apart.
TB_MYSQL_57_PIN_TAG="prod"
TB_MYSQL_57_PIN_DIGEST="sha256:f546e47fb339e0982c902cef063b081ccf2cbbaf35b475287d583b9bf3163354"
# The chart's DEFAULT images.mysqlClient.digest (the 8.4 manifest index): the
# digest the installer's 8.4 block pins and what an absent
# digest renders for the dev-mode reader (_values_mysql_engine). Held to
# client/values.yaml by the same bats case.
TB_MYSQL_84_DEFAULT_DIGEST="sha256:31fe86bd6777894b98059c3dd3f678e8ef6f164eaa44cdcfd9b1790d7a24a470"
# The chart's earlier 8.4 defaults, newest first: PREVIOUS is the unsigned
# :8.4-ca822dea index, PRIOR is :8.4-bc3756a9. Earlier installers wrote them
# into the values file, so clients carry them: every reader below still reads
# them as 8.4, as tracebloc.mysqlEngineMajor does (held by install-client-helm.bats).
TB_MYSQL_84_PREVIOUS_DIGEST="sha256:0050bd8f38d07bed86a4f5b5791314516efd47134c98ee75a8968471aa2ebc93"
TB_MYSQL_84_PRIOR_DIGEST="sha256:f58060c5bba7e88190725c6f4c980c45bc39cad186f507dd5557522db7cda35d"

# The engine a mysql-client image reference runs: 5.7, 8.4, 8.0 or unknown. The
# same classification tracebloc.mysqlEngineMajor makes of the values that
# rendered it, applied to the rendered reference: a digest names its engine only
# when it is one of the pins above (anything else is unknown); a bare tag
# reads prod/5.7* as 5.7, 8.4* as 8.4 and 8.0* as 8.0. A reference with no tag at
# all runs `latest`, which names no engine.
_mysql_image_engine() {
  local ref="$1" digest="" last tag=""
  case "$ref" in
    *@sha256:*) digest="sha256:${ref##*@sha256:}"; ref="${ref%%@*}" ;;
  esac
  if [[ -n "$digest" ]]; then
    case "$digest" in
      "$TB_MYSQL_84_DEFAULT_DIGEST"|"$TB_MYSQL_84_PREVIOUS_DIGEST"|"$TB_MYSQL_84_PRIOR_DIGEST") echo 8.4 ;;
      "$TB_MYSQL_57_PIN_DIGEST")     echo 5.7 ;;
      *)                             echo unknown ;;
    esac
    return 0
  fi
  last="${ref##*/}"
  case "$last" in *:*) tag="${last##*:}" ;; esac
  case "$tag" in
    prod|5.7*) echo 5.7 ;;
    8.4*)      echo 8.4 ;;
    8.0*)      echo 8.0 ;;
    *)         echo unknown ;;
  esac
}

# The engine the release in namespace <ns> RUNS, read from the image of its live
# mysql Deployment (the chart names it mysql-client). Echoes
#   5.7 | 8.4  the image names that engine
#   unknown    the image was read and names neither (a custom pin, the 8.0
#              transit hop)
#   (nothing)  it could not be read: no namespace, no Deployment, an API that
#              did not answer
# What RUNS, not what the release's values say: since chart 1.10.0 a release that
# carries no image keys runs whatever its chart version defaults to, 5.7 before
# 1.10.0 and 8.4 from it, so the values alone cannot tell.
# Bounded (--request-timeout), and never logs: _mysql_engine_decision calls it.
_release_mysql_engine() {
  local ns="$1" img eng
  [[ -n "$ns" ]] || return 0
  img="$(kubectl get deployment mysql-client -n "$ns" --request-timeout=10s \
    -o 'jsonpath={.spec.template.spec.containers[?(@.name=="mysql-client")].image}' 2>/dev/null)" || return 0
  [[ -n "$img" ]] || return 0
  eng="$(_mysql_image_engine "$img")"
  case "$eng" in 5.7|8.4) echo "$eng" ;; *) echo unknown ;; esac
  return 0
}

# The format of a host mysql datadir, by the marker the chart's format guard
# reads: `mysql.ibd` (the 8.0+ data dictionary) present = an 8.x datadir, which
# 8.4 opens; real content without it = 5.7-format, which only 5.7 opens. Echoes
#   (nothing)  absent, a symlink (never trusted as data, the leftover guard's
#              stance), or empty: the dirs _ensure_tracebloc_dirs creates
#   8.x        mysql.ibd is there
#   5.7        content, and no mysql.ibd
#   unknown    the host user cannot list it (a uid-999/root-owned dir): it
#              cannot be proven empty or read, so it counts as content whose
#              format is unknown. FAIL CLOSED (mirrors _leftover_data_dirs and
#              the same ownership case), never an 8.4 opt-in by default.
_mysql_datadir_format() {
  local d="$1"
  [[ -d "$d" && ! -L "$d" ]] || return 0
  [[ -r "$d" && -x "$d" ]] || { echo unknown; return 0; }
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || return 0
  if [[ -e "$d/mysql.ibd" ]]; then echo 8.x; else echo 5.7; fi
}

# The format of this install's host datadirs, both layouts (legacy
# host_data_dir/mysql and per-release host_data_dir/<namespace>/mysql) in one
# word, the most conservative first: unknown, then 5.7, then 8.x; nothing when
# neither holds data. 5.7 beats 8.x because any 5.7 data here may be what the
# release mounts, and only 5.7 opens it.
_host_mysql_datadir_format() {
  local legacy perrel
  legacy="$(_mysql_datadir_format "${host_data_dir:-/nonexistent}/mysql")"
  perrel="$(_mysql_datadir_format "${host_data_dir:-/nonexistent}/${namespace:-}/mysql")"
  case " $legacy $perrel " in
    *" unknown "*) echo unknown ;;
    *" 5.7 "*)     echo 5.7 ;;
    *" 8.x "*)     echo 8.x ;;
  esac
}

# The generated values file install_client_helm reads (for the sticky 8.4
# check) and writes. Factored out of the `local values_file=…` it used to be so
# a caller running BEFORE install_client_helm — preflight's arch gate — resolves
# the same file instead of restating the path. A restated path would silently
# stop seeing an existing 8.4 opt-in the day this one moves.
_client_values_file() { echo "${TRACEBLOC_VALUES_FILE:-${host_data_dir}/values.yaml}"; }

# The namespace this install will use when nothing else has determined one yet
# (an existing release can override it later — see install_client_helm). Same
# reason as above: preflight needs the per-release datadir path, which is
# host_data_dir/<namespace>/mysql.
_client_default_namespace() { _sanitize_workspace_name "${namespace:-tracebloc}"; }

# Whether the values on STDIN pin the MySQL 8.4 engine — i.e. the engine that will
# ACTUALLY run is 8.4. Reads STDIN so a caller streams a file (`< values.yaml`)
# rather than slurping it (a 60k-line fixture). The ONE
# reader three callers share so they cannot drift on what "pins 8.4" means: the
# sticky rule below, the dev-mode TRACEBLOC_VALUES_FILE arch gate, and the
# adopt-reconcile arch gate.
#
# STRUCTURAL, not a fixed line window. The chart's own
# client/values.yaml documents the 8.4 opt-in in a COMMENT several lines below the
# real `tag:` — literally `#   tag: "8.4"` — so a `grep -A N` is wrong in BOTH
# directions: too narrow misses the real tag and refuses a legitimate 8.4 opt-in on
# arm64; too wide reads that DECOY comment as the pin and skips the gate on a 5.7
# default (fail OPEN). So walk the indent-delimited mysqlClient block, drop comment
# and blank lines (the decoy goes with them), and read the real `tag:`/`digest:` by
# EXACT value — "8.40"/"8.4.1" are not 8.4. Handles the quoted form our heredoc
# writes (tag: "8.4") and the unquoted form `helm get values` re-serializes
# (tag: 8.4).
#
# DIGEST WINS OVER TAG. tracebloc.image renders
# repository@<digest> when a digest is set and ignores the tag entirely. So
# `tag: "8.4"` with a NON-empty digest actually runs whatever that (opaque sha256)
# digest is — which we cannot decode — not 8.4. Report 8.4 ONLY when tag is 8.4
# AND the digest is one that provably runs 8.4: TB_MYSQL_84_DEFAULT_DIGEST, the
# chart's own 8.4 pin and what our heredoc writes, the
# earlier defaults an installer wrote (TB_MYSQL_84_PREVIOUS_DIGEST and
# TB_MYSQL_84_PRIOR_DIGEST), or
# AFFIRMATIVELY empty, the documented opt-in (`tag: "8.4"` + `digest: ""`) and
# what the heredoc wrote before it pinned — so a client installed then stays 8.4
# sticky and its re-run writes the pinned block. Any other set digest is treated
# as "not provably 8.4" so the 5.7 arch gate runs — fail closed, refuse rather
# than CrashLoop.
#
# AN ABSENT DIGEST IS NOT AN EMPTY ONE.
# This reader is fed PARTIAL views: `_release_pins_mysql_84` reads `helm get values`
# WITHOUT `--all`, which omits chart defaults, and a dev-mode overlay can carry only
# `mysqlClient.tag`. In both, the chart-default `digest` (the amd64-only 5.7 pin) is
# still what renders — `tracebloc.image` makes it win over the tag — yet the digest
# line is nowhere on STDIN. Treating that missing line as `digest: ""` reported a
# real 8.4 pin, skipped the 5.7 arch gate, and CrashLooped the amd64-only image on
# arm64. So we require the digest key to actually APPEAR and be empty (`sawdigest`);
# a digest we never saw is "not provably cleared" → not 8.4 → the 5.7 gate runs.
# (We deliberately do NOT switch the caller to `helm get values --all`: coalescing
# can re-default an operator's explicit `digest: ""` back to the chart's 5.7 pin,
# which would false-REFUSE a genuine 8.4 reconcile. Reading only supplied values and
# demanding an explicit known digest is the fail-closed direction that costs nothing
# real — our heredoc always writes the digest key explicitly.)
#
# Reads to EOF and decides in END — it never exits on first match, so a producer
# piping in (helm get values) is never SIGPIPE'd (the trap an early
# `exit`/`grep -q` would spring).
_values_pin_mysql_84() {
  awk -v d84="$TB_MYSQL_84_DEFAULT_DIGEST" -v d84p="$TB_MYSQL_84_PRIOR_DIGEST" -v d84q="$TB_MYSQL_84_PREVIOUS_DIGEST" '
    # 8.4 iff tag is 8.4 AND the digest was SEEN and is empty or an 8.4 pin.
    # sawdigest guards the "absent digest is not an empty one" rule:
    # a digest we never saw on STDIN may still be a non-empty default that wins.
    function flush() { if (inblk && tag == "8.4" && sawdigest && (digest == "" || digest == d84 || digest == d84p || digest == d84q)) found = 1 }
    /^[[:space:]]*#/ { next }                      # comment line — drops the decoy
    /^[[:space:]]*$/ { next }                      # blank line
    { match($0, /^[[:space:]]*/); indent = RLENGTH }
    !inblk {
      if ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/) { inblk=1; base=indent; tag=""; digest=""; sawdigest=0 }
      next
    }
    {
      if (indent <= base) {                        # dedented out of the block
        flush()                                    # decide this block before leaving it
        inblk = ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/)
        if (inblk) { base=indent; tag=""; digest=""; sawdigest=0 }
        next
      }
      if ($0 ~ /^[[:space:]]*tag:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*tag:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)             # strip an inline comment
        gsub(/"/, "", v)                           # strip quotes (quoted or not)
        sub(/[[:space:]]+$/, "", v)
        tag = v
      } else if ($0 ~ /^[[:space:]]*digest:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*digest:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/"/, "", v)
        sub(/[[:space:]]+$/, "", v)
        digest = v
        sawdigest = 1                              # the key is present (empty or not)
      }
    }
    END { flush(); exit(found ? 0 : 1) }
  '
}

# Whether the live Helm release <rel> in namespace <ns> runs the MySQL 8.4 engine,
# read from its STORED values — adopt/reconcile keeps those via --reuse-values, so
# this is the engine that will actually run, not a fresh resolution. Bounded the
# way _existing_training_values bounds its read: `helm get values` has no request
# timeout, so gate it behind a bounded namespace probe and let a wedged API degrade
# to "not 8.4" (→ the 5.7 arch gate) instead of hanging. Unreadable is deliberately
# fail-closed: refuse an arm64 reconcile we cannot prove is 8.4 rather than report
# success and CrashLoop (the same stance as the adopt-reconcile arch gate).
_release_pins_mysql_84() {
  local _rel="$1" _ns="$2"
  [[ -n "$_rel" && -n "$_ns" ]] || return 1
  kubectl get namespace "$_ns" --request-timeout=5s >/dev/null 2>&1 || return 1
  # The stored values hold clientPassword and the chart's other secrets: piped
  # straight into the reader, never held, so a trace shows no value. A helm that
  # fails is read as empty values (`|| :`), "not 8.4", whatever pipefail says.
  { helm get values "$_rel" -n "$_ns" 2>/dev/null </dev/null || :; } | _values_pin_mysql_84
}

# _values_hostpath_storage -- the top-level hostPath block of `helm get values` on
# STDIN, and the macOS node's jobData.path, as four lines:
# enabled=<v>, root=<v>, datasetPath=<v>, jobDataPath=<v> (absent is empty; null and ~
# are empty too). Values are unquoted the way helm serializes them:
# plain, '...' with '' for a quote, or "..." without escapes. Anything else -- a
# "..." holding a backslash, a block scalar, a flow-style hostPath or jobData mapping, a root, datasetPath or jobData path folded
# onto a second line -- prints the single word `unreadable`: a path read half-right is
# worse than none. Reads to EOF (no early exit, so a producer is never SIGPIPE'd).
_values_hostpath_storage() {
  awk -v sq="'" '
    function unq(v,   dq) {
      dq = "\""
      if (v == "null" || v == "~") return ""
      if (length(v) >= 2 && substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq) {
        v = substr(v, 2, length(v) - 2); gsub(sq sq, sq, v); return v
      }
      if (length(v) >= 2 && substr(v, 1, 1) == dq && substr(v, length(v), 1) == dq) {
        v = substr(v, 2, length(v) - 2)
        if (index(v, "\\")) bad = 1
        return v
      }
      if (substr(v, 1, 1) == sq || substr(v, 1, 1) == dq || v ~ /^[|>&*!%@`]/) bad = 1
      return v
    }
    /^[[:space:]]*$/ { next }
    { match($0, /^ */); ind = RLENGTH }
    ind == 0 {
      inblk = ($0 ~ /^hostPath:[[:space:]]*(#.*)?$/); injd = ($0 ~ /^jobData:[[:space:]]*(#.*)?$/); child = -1; last = ""
      if (!inblk && !injd && $0 ~ /^(hostPath|jobData):/) {
        rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest); sub(/[[:space:]]+#.*$/, "", rest); sub(/[[:space:]]+$/, "", rest)
        if (rest != "null" && rest != "~" && rest != "{}") bad = 1
      }
      next
    }
    !inblk && !injd { next }
    child < 0 { child = ind }
    ind > child { if (last == "root" || last == "datasetPath" || last == "jobData.path") bad = 1; next }
    {
      line = $0; sub(/^ */, "", line)
      key = line; sub(/:.*/, "", key)
      v = line; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      last = key
      if (injd) { if (key == "path") { last = "jobData.path"; jd = unq(v) }; next }
      if (key == "enabled") en = v
      else if (key == "root") root = unq(v)
      else if (key == "datasetPath") ds = unq(v)
    }
    END {
      if (bad) { print "unreadable"; exit 0 }
      print "enabled=" en; print "root=" root; print "datasetPath=" ds; print "jobDataPath=" jd
    }
  '
}

# _native_k3s_release_storage -- native k3s only: keep the storage
# an installed release was made with. Native k3s has no node to inspect, so
# the answer is the release's own stored hostPath values. A release's volumes cannot
# change in place -- a PV's path and a PVC's class are immutable, so a re-run that
# rendered the other mode, or another root, would fail the upgrade.
#   - a hostpath release, this run's node-local only the default: hostpath is kept,
#     in this shell, for the values and the dirs below (every bare re-run and
#     `tracebloc upgrade`, which passes no storage mode and no data dir);
#   - an explicit mode that differs from the release's: refused by name;
#   - a hostpath release's root and datasetPath are kept (TB_HOSTPATH_KEPT, read by
#     _hostpath_paths_block), with one warning when this run asked for others --
#     as config.yaml's storage path is kept for node-local
#     (_native_k3s_storage_drift_warn, k3s.sh).
# No namespace, or no release in it, is a fresh install. A read that does not answer
# is "cannot tell" and stops the run by name, never "no release".
#
# TWICE, ONE READ. install-k8s.sh calls it EARLY, right after validate_config, so
# every pre-install reader of TB_STORAGE_MODE -- the pre-log guard, preflight's disk
# and storage-type checks, guard_leftover_data -- judges the release's storage, not
# the default's. Before the create path nothing
# else has set the cluster up for this run, so the early read only acts when it can
# see the release: a k3s this installer recorded (`k3s-install`), the tracebloc
# context in the kubeconfig, an API that answers, and the release in the namespace.
# Anything short of that is a fresh install, or a k3s the create path is about to
# start, and the call returns without deciding; install_client_helm's call then
# reads it once the cluster is up, as before. When the record lists this installer's
# k3s, that return marks the release unread (TB_RELEASE_STORAGE_UNREAD), so the
# create path's config.yaml does not newly confine k3s over what may be hostPath
# volumes (_native_k3s_selinux_deferred, k3s.sh). Once a read has decided
# (TB_RELEASE_STORAGE_READ), the second call returns at once.
# Both calls name the kubeconfig the merge writes and the tracebloc context: before
# the create path, the current context can be any cluster the user works with.
_native_k3s_release_storage() {
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] || return 0
  [[ "${TB_RELEASE_STORAGE_READ:-}" != 1 ]] || return 0
  local early="" ns="${namespace:-}" out rc=0 line enabled="" root="" ds="" jd="" want="${TB_STORAGE_MODE:-node-local}" kc ctx rec
  if [[ "${1:-}" == early ]]; then early=1; ns="$(_client_default_namespace)"; fi
  [[ -n "$ns" ]] || return 0
  kc="$(_native_k3s_kubeconfig_target)"; ctx="$(_native_k3s_context)"
  if [[ -n "$early" ]]; then
    rec="$(tb_record_path)"
    if [[ ! -r "$rec" ]] || ! grep -qF '"kind": "k3s-install"' "$rec" 2>/dev/null; then return 0; fi
    # This installer set a k3s up here, so a release may be on it: until its API
    # answers, the release's storage is unread, and config.yaml, written before k3s
    # is up, is not newly confined (_native_k3s_selinux_deferred, k3s.sh).
    TB_RELEASE_STORAGE_UNREAD=1
    if ! has kubectl || ! has helm; then return 0; fi
    out="$(kubectl --kubeconfig "$kc" config get-contexts -o name 2>/dev/null)" || out=""
    grep -qxF -- "$ctx" <<<"$out" || return 0
    if ! kubectl --kubeconfig "$kc" --context "$ctx" get --raw /readyz --request-timeout=5s >/dev/null 2>&1; then
      log "Storage mode: this machine's k3s API is not answering yet, so its release's storage is read once k3s is up."
      return 0
    fi
    TB_RELEASE_STORAGE_UNREAD=""
  fi
  local cant="native k3s: couldn't read this machine's tracebloc release '${ns}', so which storage its volumes use can't be told"
  out="$(kubectl --kubeconfig "$kc" --context "$ctx" get namespace "$ns" --ignore-not-found -o name --request-timeout=5s 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'kubectl --context ${ctx} get namespace ${ns}' answers, then re-run."
  if [[ -z "$out" ]]; then [[ -n "$early" ]] || TB_RELEASE_STORAGE_READ=1; return 0; fi
  out="$(_bounded "${TB_HELM_LIST_TIMEOUT:-20}" helm --kubeconfig "$kc" --kube-context "$ctx" list -n "$ns" -q --deployed --failed --pending --uninstalling 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'helm --kube-context ${ctx} list -n ${ns}' answers, then re-run."
  if ! grep -qxF -- "$ns" <<<"$out"; then [[ -n "$early" ]] || TB_RELEASE_STORAGE_READ=1; return 0; fi
  TB_RELEASE_STORAGE_READ=1
  # The stored values hold clientPassword and the chart's other secrets: piped
  # straight into the reader, never held, so a trace shows only its four lines.
  # pipefail: a helm that fails stops the run as before. The reader reads to EOF
  # (it decides in END), so helm is never SIGPIPE'd.
  out="$(set -o pipefail; _bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm --kubeconfig "$kc" --kube-context "$ctx" get values "$ns" -n "$ns" 2>/dev/null </dev/null | _values_hostpath_storage)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'helm --kube-context ${ctx} get values ${ns} -n ${ns}' answers, then re-run."
  [[ "$out" != unreadable ]] \
    || error "${cant}: its stored hostPath values are in a form this installer does not read. Check them with 'helm --kube-context ${ctx} get values ${ns} -n ${ns}', then re-run."
  while IFS= read -r line; do
    case "$line" in
      enabled=*)     enabled="${line#enabled=}" ;;
      root=*)        root="${line#root=}" ;;
      datasetPath=*) ds="${line#datasetPath=}" ;;
      jobDataPath=*) jd="${line#jobDataPath=}" ;;
    esac
  done <<<"$out"

  if [[ "$enabled" != true ]]; then
    [[ "$want" != hostpath ]] \
      || error "TRACEBLOC_STORAGE_MODE=hostpath, but this machine's tracebloc release '${ns}' keeps its data in k3s's local-path volumes (node-local), and an installed release can't change its storage in place. Unset TRACEBLOC_STORAGE_MODE to keep node-local, or remove tracebloc from this machine and install again with hostpath."
    # The macOS node's job-data folder: the release keeps the one its
    # claims' PVs name, or keeps having none (a v1.11 Mac's release: its claims are in
    # the node and cannot move). _mac_ct_job_data_dir reads the two.
    if [[ -n "$jd" ]]; then TRACEBLOC_JOB_DATA_KEPT=1; TRACEBLOC_JOB_DATA_KEPT_DIR="$jd"; else TRACEBLOC_JOB_DATA_KEPT=0; fi
    return 0
  fi
  root="${root:-/tracebloc}"   # the chart's default, which is what rendered
  if [[ "$want" == node-local ]]; then
    [[ "${TB_STORAGE_MODE_SOURCE:-default}" != explicit ]] \
      || error "TRACEBLOC_STORAGE_MODE=node-local, but this machine's tracebloc release '${ns}' keeps its data in hostPath volumes under ${root}, and an installed release can't change its storage in place. Unset TRACEBLOC_STORAGE_MODE to keep hostpath, or remove tracebloc from this machine and install again with node-local."
    TB_STORAGE_MODE=hostpath
    log "Storage mode: hostpath — kept from the release '${ns}' (node-local is only the default, and the release was installed with hostpath)."
    info "Keeping hostpath storage: this machine's tracebloc release was installed with it, and its data stays in ${root}."
  fi
  TB_HOSTPATH_KEPT=1
  TB_HOSTPATH_ROOT="$root"
  TB_HOSTPATH_DATASET="$ds"
  if [[ "$root" != "${host_data_dir:-}" || "${ds:-$root}" != "${HOST_DATASET_DIR:-${host_data_dir:-}}" ]]; then
    warn "This machine's tracebloc release keeps its data in ${root}${ds:+ (datasets in ${ds})}; this run asked for ${host_data_dir:-}${HOST_DATASET_DIR:+ (datasets in ${HOST_DATASET_DIR})}, which is not used."
    hint "hostPath volumes can't move: to use the new directory, remove tracebloc from this machine, then install again with it."
  fi
  return 0
}

# _hostpath_paths_block -- the hostPath keys after `enabled: true` in the values file.
# The node is the host, so the PVs name the host's own directories:
# root is host_data_dir, datasetPath HOST_DATASET_DIR when one is set (unset, the
# chart follows root). An installed release keeps the two it was made with
# (_native_k3s_release_storage).
# Single-quoted (_yaml_sq_escape): a data dir is a path the operator chose.
_hostpath_paths_block() {
  local ds="${HOST_DATASET_DIR:-}"
  [[ "${TB_HOSTPATH_KEPT:-}" != 1 ]] || ds="${TB_HOSTPATH_DATASET:-}"
  printf "  root: '%s'\n" "$(_yaml_sq_escape "$(_hostpath_root)")"
  [[ -z "$ds" ]] || printf "  datasetPath: '%s'\n" "$(_yaml_sq_escape "$ds")"
}

# The engine decision itself, with NO logging and NO globals set, so a second
# caller can ask this rule a question instead of restating it:
# preflight's arch gate refused a fresh arm64 install that this rule was about
# to serve natively. Echoes "<engine> <reason>" — always exit 0, the reason
# carries the verdict:
#   5.7|8.4 explicit      an explicit TB_MYSQL_ENGINE=<value>
#   invalid <value>        TB_MYSQL_ENGINE is not auto|5.7|8.4
#   8.4 sticky             this machine already opted into 8.4 (its values.yaml)
#   8.4 existing-release   this machine's live release runs 8.4
#   8.4 existing-datadir   this host's mysql datadir is 8.x-format (mysql.ibd)
#   5.7 existing-datadir   this host holds mysql data that is 5.7-format, or that
#                          cannot be read (fail closed)
#   5.7 existing-release   this machine's live release runs 5.7, or runs an engine
#                          that cannot be read, and no host datadir says more
#   8.4 fresh              fresh install, on every arch — native multi-arch engine
_mysql_engine_decision() {
  local requested="${TB_MYSQL_ENGINE:-auto}"
  case "$requested" in
    5.7|8.4) echo "${requested} explicit"; return 0 ;;
    auto) ;;
    *) echo "invalid ${requested}"; return 0 ;;
  esac
  # Sticky: an edge that opted into 8.4 stays there on every later re-run.
  # _values_pin_mysql_84 streams the file (never slurps it), skips comments, and
  # reads to EOF — it owns the structural-vs-window and SIGPIPE reasoning
  if [[ -f "${values_file:-}" ]] && _values_pin_mysql_84 < "${values_file}"; then
    echo "8.4 sticky"; return 0
  fi
  # Existing state keeps the engine it RUNS (since the 8.4 default switch):
  # since chart 1.10.0 the chart's default is 8.4, so a 5.7 client must be pinned
  # to 5.7 explicitly and an 8.4 client must not be. Read from the state itself,
  # most authoritative first:
  #
  #   the live release: the image of its mysql Deployment
  #     (_release_mysql_engine). It is what runs on the release's datadir, and the
  #     format guard admitted that pairing at its last start. Its values cannot
  #     say: a release with no image keys runs its chart version's default.
  #
  #   the host datadir: its format marker (_host_mysql_datadir_format), for a
  #     host with data and no readable release (a reinstall over kept data, an
  #     API that would not answer). 8.x-format opens on 8.4; 5.7-format only on
  #     5.7; an UNLISTABLE dir counts as content of unknown format and keeps 5.7
  #     (fail closed; see the helper).
  #
  # Reason 'existing-datadir' whenever there IS 5.7 (or unreadable) data on this
  # host, release or not: a clean start then means clearing the data dir, and a
  # release-only "uninstall" remedy would leave those files to re-pin 5.7 on the
  # next run. 'existing-release' for a release with no host
  # datadir files (TB_STORAGE_MODE=node-local, where both probes are empty): 5.7
  # when it runs 5.7 or cannot be read, because 8.4 cannot open a 5.7-format
  # datadir and an existing one is never flipped automatically; "uninstall the
  # release" is then a COMPLETE fresh-start remedy, as no files remain to
  # re-trigger the gate.
  #
  # The empty dirs _ensure_tracebloc_dirs just created don't count — only files.
  local fmt live=""
  fmt="$(_host_mysql_datadir_format)"
  if [[ -n "${existing_id:-}" ]]; then
    live="$(_release_mysql_engine "${existing_ns:-${namespace:-}}")"
  fi
  if [[ "$live" == "8.4" ]]; then
    echo "8.4 existing-release"; return 0
  fi
  if [[ "$live" != "5.7" && "$fmt" == "8.x" ]]; then
    echo "8.4 existing-datadir"; return 0
  fi
  if [[ -n "$fmt" ]]; then
    echo "5.7 existing-datadir"; return 0
  fi
  if [[ -n "${existing_id:-}" ]]; then
    echo "5.7 existing-release"; return 0
  fi
  # Fresh: nothing here is 5.7-format, so the multi-arch 8.4 engine, on every
  # arch. A fresh amd64 host used to answer "5.7 amd64" and keep the chart's 5.7
  # pin, which made each new x86 install a later 5.7 -> 8.4 migration.
  echo "8.4 fresh"
}

# Dev-mode (TRACEBLOC_VALUES_FILE) engine resolution — DELIBERATELY not the auto
# rule above. When the caller supplies a values file, install_client_helm deploys
# it as-is (only this run's GPU decision rides on top) and never
# generates the mysqlClient pin the normal path writes, so the engine that RUNS is
# what the file's images.mysqlClient block renders over THIS chart's defaults
# (_values_mysql_engine) — since the 8.4 default switch that is the multi-arch 8.4 engine
# unless the file pins the 5.7-lineage image. _mysql_engine_decision answers for
# the normal path, whose pin dev-mode never writes; consulting it for a dev-mode
# install is what let a past case pass preflight and then refuse after the
# cluster was already up. This helper is the ONE reader both the step-e install
# path and preflight's early arch gate share, so the two cannot drift.
# Fail-closed: a missing/unreadable file, or an engine the reader cannot name (a
# custom digest), reads as 5.7 — the answer that keeps the arch gate armed,
# refusing rather than false-passing. Echoes "<engine> values-file".
_devmode_engine_decision() {
  local vf="${TRACEBLOC_VALUES_FILE:-}" engine=""
  if [[ -n "$vf" && -f "$vf" && -r "$vf" ]]; then
    engine="$(_values_mysql_engine < "$vf")"
  fi
  if [[ "$engine" == "8.4" ]]; then
    echo "8.4 values-file"
  else
    echo "5.7 values-file"
  fi
}

# _values_mysql_engine -- the MySQL engine a values file (on STDIN) runs on THIS
# chart: its images.mysqlClient block laid over the chart's defaults, then
# tracebloc.mysqlEngineMajor's own rule. Prints 5.7, 8.4, 8.0 or unknown.
#   digest absent   -> the chart default, TB_MYSQL_84_DEFAULT_DIGEST -> 8.4
#   digest = that, TB_MYSQL_84_PREVIOUS_DIGEST or TB_MYSQL_84_PRIOR_DIGEST -> 8.4
#   digest = TB_MYSQL_57_PIN_DIGEST -> 5.7
#   other digest    -> unknown (a custom pin; the guard stands down)
#   digest ""       -> the tag (absent = the chart default "8.4"):
#                      ""/prod/5.7* -> 5.7, 8.4* -> 8.4, 8.0* -> 8.0, else unknown
#   `mysqlClient: null` / `images: null` -> the template fallbacks, tag prod -> 5.7
# It RESTATES the chart's helper, so install-client-helm.bats renders the chart on
# every input shape above and holds this reader to the guard's own answer.
# Unlike _values_pin_mysql_84 an ABSENT key here means the default of the chart
# being installed: right for a dev-mode file, which is deployed against this
# chart, and wrong for a values file a 5.7 release stored under an older one
# (there an absent digest was the 5.7 pin) -- so the sticky and release reads
# keep _values_pin_mysql_84. Reads to EOF and decides in END (no SIGPIPE on a
# producer).
_values_mysql_engine() {
  awk -v d57="$TB_MYSQL_57_PIN_DIGEST" -v d84="$TB_MYSQL_84_DEFAULT_DIGEST" -v d84p="$TB_MYSQL_84_PRIOR_DIGEST" -v d84q="$TB_MYSQL_84_PREVIOUS_DIGEST" -v sq="'" '
    function val(line,   v) {
      v = line
      sub(/^[[:space:]]*[A-Za-z]+:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/"/, "", v)
      gsub(sq, "", v)
      sub(/[[:space:]]+$/, "", v)
      return v
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(images|mysqlClient):[[:space:]]*(null|~)[[:space:]]*$/ { nil = 1; next }
    { match($0, /^[[:space:]]*/); indent = RLENGTH }
    !inblk {
      if ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/) { inblk = 1; base = indent; tag = ""; sawtag = 0; digest = ""; sawdigest = 0 }
      next
    }
    {
      if (indent <= base) {
        inblk = ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/)
        if (inblk) { base = indent; tag = ""; sawtag = 0; digest = ""; sawdigest = 0 }
        next
      }
      if ($0 ~ /^[[:space:]]*tag:/)         { tag = val($0); sawtag = 1 }
      else if ($0 ~ /^[[:space:]]*digest:/) { digest = val($0); sawdigest = 1 }
    }
    END {
      if (nil) { print "5.7"; exit 0 }
      if (!sawdigest) digest = d84
      if (!sawtag) tag = "8.4"
      if (digest == d84 || digest == d84p || digest == d84q) e = "8.4"
      else if (digest == d57)  e = "5.7"
      else if (digest != "")   e = "unknown"
      else if (tag == "" || tag == "prod" || tag ~ /^5\.7/) e = "5.7"
      else if (tag ~ /^8\.4/) e = "8.4"
      else if (tag ~ /^8\.0/) e = "8.0"
      else e = "unknown"
      print e
    }
  '
}

# The logging wrapper around the rule above: sets TB_MYSQL_ENGINE_RESOLVED and
# narrates the choice. Kept separate so the rule can be consulted without
# emitting an install-time log line (preflight would otherwise log the engine
# choice minutes before the engine is chosen).
_resolve_mysql_engine() {
  local decision engine reason
  decision="$(_mysql_engine_decision)"
  engine="${decision%% *}"; reason="${decision#* }"
  if [[ "$engine" == "invalid" ]]; then
    error "TB_MYSQL_ENGINE must be 'auto', '5.7' or '8.4' (got '${reason}')"
  fi
  TB_MYSQL_ENGINE_RESOLVED="$engine"
  # WHY, not just what: the arch gate below needs to name the real cause, and
  # "existing datadir" vs "you asked for 5.7" are different fixes.
  TB_MYSQL_ENGINE_REASON="$reason"
  case "${engine} ${reason}" in
    *" explicit")           log "MySQL engine: ${engine} (explicit TB_MYSQL_ENGINE)" ;;
    "8.4 sticky")           log "MySQL engine: 8.4 (kept from this machine's existing values.yaml)" ;;
    "8.4 fresh")            log "MySQL engine: 8.4 (fresh install on ${ARCH:-$(uname -m)} — native multi-arch engine)" ;;
    "8.4 existing-release") log "MySQL engine: 8.4 (this machine's tracebloc release runs it)" ;;
    "8.4 existing-datadir") log "MySQL engine: 8.4 (this host's MySQL data is 8.x-format)" ;;
    "5.7 existing-release") log "MySQL engine: 5.7, pinned explicitly (this machine's tracebloc release runs 5.7, or its engine could not be read; the chart's default, 8.4, cannot open 5.7 data)" ;;
    "5.7 existing-datadir") log "MySQL engine: 5.7, pinned explicitly (this host holds MySQL data that is 5.7-format or could not be read; the chart's default, 8.4, cannot open 5.7 data)" ;;
  esac
}

# ── The arch gate, asked where the engine is actually known ────
# preflight's _pf_arch asks the same question early (that is the fast-fail), but
# it runs before the Helm release and the per-release namespace are known — so an
# existing edge can still look fresh there and only resolve to the amd64-only 5.7
# image here. Without this second ask, letting the fresh case through preflight
# would let that edge proceed to an exec-format CrashLoop with no earlier signal.
# Same conditions as _pf_arch: non-amd64, no emulation, no escape hatch — with a
# PER-OS emulation probe (binfmt on Linux, the macOS node's Rosetta on a Mac).
#
# macOS IS covered here. This comment used to say the opposite —
# "this gate is Linux-only … deliberately out of scope" — and stayed behind when
# the Darwin arm landed below, which reads as "macOS is ungated" to anyone who
# trusts the prose over the code. On macOS this is the ONLY gate:
# preflight only notes Rosetta on the macOS node (_pf_arch), before the engine is
# known; here the engine is resolved for real, and this refuses fail-closed.
#
# It probes the real host, so anything calling install_client_helm under test
# must declare OS/ARCH rather than inherit the machine — see install-client-helm.bats::setup.
_assert_engine_runs_on_this_arch() {
  [[ "${TB_MYSQL_ENGINE_RESOLVED:-}" == "5.7" ]] || return 0
  [[ -z "${TRACEBLOC_ALLOW_ARM64:-}" ]] || return 0
  case "${ARCH:-$(uname -m)}" in x86_64|amd64) return 0 ;; esac
  # arm64 + 5.7 needs amd64 emulation. Check it PER OS — binfmt on Linux; on a Mac,
  # whether the macOS node runs amd64 images under Rosetta (binfmt does not exist
  # there). This gate runs on macOS too: here the engine is resolved
  # for real, so an arm64 Mac that resolved to 5.7 (an existing release) without
  # Rosetta is refused.
  case "${OS:-}" in
    Linux)
      amd64_emulation_available && return 0
      ;;  # fall through to the Linux (binfmt) reason-messages below
    Darwin)
      declare -F _macos_amd64_emulation_ok >/dev/null 2>&1 && _macos_amd64_emulation_ok && return 0
      # Emulation missing (or the helper somehow absent): the macOS Rosetta
      # remedy, then exit. Do NOT fall through to the binfmt messages below.
      declare -F _macos_amd64_refusal >/dev/null 2>&1 && _macos_amd64_refusal
      error "MySQL 5.7 is required here, but amd64 emulation could not be verified on this Apple Silicon Mac — enable Rosetta and re-run (or set TRACEBLOC_ALLOW_ARM64=1 to override)." ;;
    *)
      return 0 ;;  # unknown OS: no emulation model — do not gate
  esac
  # LINUX ONLY past here. Name the actual cause, matched rather than assumed: `explicit`,
  # `existing-release`, `existing-datadir` and dev mode's `values-file` (the `*)` arm) reach
  # here, and a future reason must not inherit a false claim about this machine's data.
  # The remedy is the one preflight gives: amd64_emulation_remedy.
  local remedy; remedy="$(amd64_emulation_remedy)"
  case "${TB_MYSQL_ENGINE_REASON:-}" in
    explicit)
      warn "TB_MYSQL_ENGINE=5.7 was requested, and the MySQL 5.7 image is amd64-only — it cannot run on ${ARCH}."
      hint "Drop TB_MYSQL_ENGINE (or set TB_MYSQL_ENGINE=8.4) to use the native multi-arch 8.4 engine — fresh data directories only."
      hint "To keep 5.7, enable amd64 emulation and re-run:"
      hint "  ${remedy}"
      error "MySQL 5.7 was requested explicitly and cannot run on ${ARCH} without amd64 emulation." ;;
    existing-release)
      warn "An existing tracebloc release is installed here, so the install keeps the MySQL 5.7 engine as a data-safety default — and that image is amd64-only."
      hint "Whether this release's data is actually 5.7-format cannot be told from here: the release is detected via 'helm list', not the data directory. 5.7 is kept because 8.4 cannot open a 5.7-format datadir if one exists."
      hint "Keep the existing release — enable amd64 emulation, then re-run:"
      hint "  ${remedy}"
      hint "Or start fresh on the native 8.4 engine — this needs BOTH the release AND its retained data removed. 'helm uninstall' alone is not enough: the MySQL volume is annotated 'helm.sh/resource-policy: keep', so it survives the uninstall, and 8.4 cannot open a 5.7-format datadir, which that retained volume may be (the next run resolves to 8.4 and fails the format guard after cluster setup). Delete the retained MySQL PVC (and any host data directory) as well before re-running."
      error "MySQL 5.7 (kept for the existing release) cannot run on ${ARCH} without amd64 emulation." ;;
    existing-datadir)
      warn "This host holds existing MySQL 5.7 data, so the install must keep the MySQL 5.7 engine — and that image is amd64-only."
      hint "This is a data-format constraint, not an architecture one: MySQL 8.4 runs natively on ${ARCH}, but it cannot open a 5.7-format datadir (MySQL upgrades only in stages, 5.7 → 8.0 → 8.4)."
      hint "Keep this data — enable amd64 emulation, then re-run:"
      hint "  ${remedy}"
      hint "Or start fresh on the native 8.4 engine — uninstall any existing release, then install into an empty data directory (the existing files keep the install on 5.7):"
      hint "  --data-dir=/path/to/new/empty/dir"
      error "MySQL 5.7 is required by the existing data on this host and cannot run on ${ARCH} without amd64 emulation." ;;
    *)
      warn "This install resolved to the MySQL 5.7 engine (${TB_MYSQL_ENGINE_REASON:-unknown reason}), and that image is amd64-only — it cannot run on ${ARCH}."
      hint "Enable amd64 emulation and re-run:"
      hint "  ${remedy}"
      error "MySQL 5.7 cannot run on ${ARCH} without amd64 emulation." ;;
  esac
}

# give the bundled metrics-server APIService a bounded window to register
# before helm renders. On a freshly created cluster k3s applies its bundled
# metrics-server (and the v1beta1.metrics.k8s.io APIService) shortly AFTER the
# API server is ready, and the API wait gates on the API, not bundled addons. The resource-monitor DaemonSet template calls
# `{{ fail }}` at render time if that APIService isn't registered yet, so on a
# slow WSL2/laptop helm can render in that window and abort the WHOLE install.
# Best-effort: if the APIService never registers here we fall through and let
# the chart's render-time guard produce its actionable error, so a genuinely
# missing metrics-server is still caught (issue's preferred option (a)).
_wait_for_metrics_apiservice() {
  # Skipped entirely under the bats suite (TRACEBLOC_SKIP_SERVICE_PROGRESS, set in setup())
  # or when kubectl is unavailable — same guard the neighbouring network-y step
  # _download_services_progress uses. Without this the poll loop below would
  # `sleep 3` up to the full ${TB_METRICS_WAIT_S:-120}s in every mocked
  # install_client_helm test (kubectl absent on the CI runner just makes each
  # `kubectl get` fail instantly, so the loop still burns its whole deadline),
  # blowing the job's 10-min deadline. Real installs never set the flag and
  # always have kubectl, so the wait is unchanged for them.
  [[ -n "${TRACEBLOC_SKIP_SERVICE_PROGRESS:-}" ]] && return 0
  has kubectl || return 0
  local _timeout_s="${TB_METRICS_WAIT_S:-}"
  case "$_timeout_s" in ''|*[!0-9]*) _timeout_s="$METRICS_WAIT_TIMEOUT" ;; *) _timeout_s=$((10#$_timeout_s)) ;; esac
  local _deadline=$(( SECONDS + _timeout_s ))
  while (( SECONDS < _deadline )); do
    if kubectl get apiservice v1beta1.metrics.k8s.io --request-timeout=10s >/dev/null 2>&1; then
      # Registered — give it a moment to also report Available, but don't fail
      # the install if it's merely slow to become ready; the DaemonSet only
      # needs the APIService present at render time.
      kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
        --timeout=30s >/dev/null 2>&1 || true
      log "metrics.k8s.io APIService registered — proceeding with helm install."
      return 0
    fi
    sleep 3
  done
  log "metrics.k8s.io APIService not registered after ${_timeout_s}s — proceeding; the chart guards if metrics-server is genuinely absent."
  return 0
}

# label + annotate a pre-existing, Helm-unowned GPU device-plugin
# DaemonSet (left by the old imperative `kubectl apply`) so `helm upgrade
# --install` adopts it in place instead of failing with "exists and cannot be
# imported into the current release". Best-effort, bounded, idempotent, and
# gated on the GPU path — GPU is optional, so nothing here may abort the install.
_adopt_orphaned_gpu_device_plugin() {
  [[ "${GPU_VENDOR:-}" == "nvidia" || "${GPU_VENDOR:-}" == "amd" ]] || return 0
  local ns="kube-system" ds
  case "${GPU_VENDOR}" in
    nvidia) ds="nvidia-device-plugin-daemonset" ;;
    amd)    ds="amdgpu-device-plugin-daemonset" ;;
  esac
  # Probe for a pre-chart imperative leftover. Distinguish "absent" (fresh host —
  # the chart just creates it) from a live API error: a wedged/slow API must NOT
  # be read as "absent", because a leftover-but-unadopted DaemonSet then makes
  # `helm upgrade --install` die with "exists and cannot be imported" and abort
  # the whole (otherwise GPU-optional) install. --request-timeout bounds the probe.
  # `|| rc=$?` (not `; rc=$?`): under set -e a bare assignment from a non-zero
  # command substitution aborts the script before the branch below runs — a
  # NotFound on a fresh GPU host would kill step e.
  local probe rc=0
  probe=$(kubectl get daemonset "$ds" -n "$ns" -o name --request-timeout=5s 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    case "$probe" in
      ""|*NotFound*|*"not found"*) return 0 ;;  # absent — nothing to adopt
      *) warn "Could not check for a pre-existing GPU device plugin ${ds} (API error); skipping adoption. If a non-Helm ${ds} exists in ${ns}, remove it before install: $(tb_kubectl_shown) delete daemonset ${ds} -n ${ns}"
         return 0 ;;
    esac
  fi
  log "Adopting pre-existing GPU device plugin ${ds} into the Helm release (migrating from the standalone install)"
  # Adoption must actually succeed — a swallowed label/annotate failure leaves an
  # unowned DS that collides with the release. If it fails, remove the orphan so
  # the chart recreates a clean Helm-owned copy (the plugin is stateless; a brief
  # re-roll is fine and keeps GPU optional) rather than bricking the install.
  if kubectl label daemonset "$ds" -n "$ns" \
       app.kubernetes.io/managed-by=Helm --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1 \
     && kubectl annotate daemonset "$ds" -n "$ns" \
       "meta.helm.sh/release-name=${namespace}" \
       "meta.helm.sh/release-namespace=${namespace}" \
       --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1; then
    return 0
  fi
  warn "Could not adopt ${ds} into the Helm release; removing the orphan so the chart can recreate it."
  kubectl delete daemonset "$ds" -n "$ns" --timeout=30s --ignore-not-found \
    >> "${LOG_FILE:-/dev/null}" 2>&1 \
    || warn "Failed to remove orphaned ${ds}; if the install aborts with 'exists and cannot be imported', delete it manually: $(tb_kubectl_shown) delete daemonset ${ds} -n ${ns}"
  return 0
}

# _refuse_other_client_id ID NS -- this machine runs the secure environment ID (in
# namespace NS), and this run was given another Client ID (TB_CLIENT_ID).
_refuse_other_client_id() {
  _refuse_foreign_client "This machine runs another secure environment" \
    "To keep it, run the installer again with its Client ID." \
    "To use this Client ID instead, sign in as the account that owns it and delete it first:" \
    "This machine already runs the secure environment '${1}' (namespace '${2}'), and the Client ID given is '${TB_CLIENT_ID:-}'. tracebloc runs one secure environment per machine: it shares this cluster and the machine's resources, and tracebloc counts each one as separate capacity, so this run does not replace it."
}

# The `localApi` block of the generated values: present only when the macOS node
# (_mac_ct_ensure_node) recorded the
# mapping (TB_LOCAL_API_MAPPED=1, with the two ports it mapped), because the chart
# opens the NodePort only when it exists. An existing release gets the same decision as --set args in
# _reconcile_adopted_client.
_local_api_values_block() {
  [[ "${TB_LOCAL_API_MAPPED:-0}" == "1" ]] || return 0
  printf '\n# The local API the dashboard reaches on this machine: on, because the cluster maps\n'
  printf '# 127.0.0.1:%s to its NodePort (the macOS node: _mac_ct_ensure_node).\n' "$TRACEBLOC_LOCAL_API_HOST_PORT"
  printf 'localApi:\n  enabled: true\n  nodePort: %s\n  hostPort: %s\n  singleMachine: true\n' "$TRACEBLOC_LOCAL_API_NODE_PORT" "$TRACEBLOC_LOCAL_API_HOST_PORT"
}

# install_client_helm's stages, in the order it runs them. Each runs inside it and
# reads and sets its locals (values_file, chart_ref, ...) through bash dynamic scope.

# ── Dev-mode override: caller-supplied values file ───────────────────────
# When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
# and use the provided file as-is, except that the helm call below sets this
# run's GPU decision over it (_gpu_decision_set_args). Used for
# local testing against an unreleased chart (pair with TRACEBLOC_CHART_PATH).
_client_helm_dev_mode() {
  [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
  values_file="$TRACEBLOC_VALUES_FILE"
  namespace="${namespace:-tracebloc}"
  info "Dev mode: using caller-provided values file"
  log "Using values file: $values_file (namespace: $namespace)"
  # Gate the arch here too, before helm deploys: read the engine the caller's file
  # declares (never re-resolve: that could pick 8.4 where the file pins the
  # amd64-only 5.7 image). Preflight's early arch gate uses the same helper.
  local _dm_decision; _dm_decision="$(_devmode_engine_decision)"
  TB_MYSQL_ENGINE_RESOLVED="${_dm_decision%% *}"
  TB_MYSQL_ENGINE_REASON="${_dm_decision#* }"
  _assert_engine_runs_on_this_arch
  # The macOS node's storage steps, as the normal path takes them below: dev mode
  # installs the job-data folder too (_mac_node_profile_set_args), so it records it
  _mac_node_storage_steps
}

# Env or prompted credentials, and the previous values file's defaults for the prompt.
_client_helm_previous_config() {
  # Non-interactive credentials (non-interactive): set TRACEBLOC_CLIENT_ID +
  # TRACEBLOC_CLIENT_PASSWORD to provision without typing the secret inline
  # (CI / automation / golden images). Verified the same way as the prompt.
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  if [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -n "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]; then
    _noninteractive_creds=1
  fi
  _tb_trace_on

  if [[ "$_noninteractive_creds" == 0 && -f "$values_file" && "${TRACEBLOC_CLIENT_ADOPTED:-}" != 1 ]] && _tty_available; then
    hint "Previous configuration found."
    local _answer
    while true; do
      read -r -p "  Use previous settings as defaults? [Y/n]: " _answer <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      use_existing="$(echo "${_answer}" | tr '[:upper:]' '[:lower:]')"
      [[ "$use_existing" == "y" || "$use_existing" == "yes" || "$use_existing" == "n" || "$use_existing" == "no" || -z "$use_existing" ]] && break
      tb_choice_refused "$_answer" y/n y
    done
    if [[ "$use_existing" == "y" || "$use_existing" == "yes" || -z "$use_existing" ]]; then
      default_client_id=$(_extract_yaml_value "$values_file" "clientId")
      # The password stays out of bash -x's trace (_tb_trace_off, output.sh).
      { _tb_trace_off; } 2>/dev/null
      default_client_password=$(_extract_yaml_value "$values_file" "clientPassword")
      [[ -z "$default_client_password" ]] || log "Using existing clientPassword as default."
      _tb_trace_on
      [[ -n "$default_client_id" ]] && log "Using existing clientId as default."
    fi
  fi
  return 0
}

# The credentials: from TRACEBLOC_CLIENT_ID/PASSWORD, or the prompt; verified.
_client_helm_credentials() {
  # Every line from here to the end of the credential prompt holds the password,
  # so it runs with bash -x held off (_tb_trace_off, output.sh).
  { _tb_trace_off; } 2>/dev/null
  if [[ "$_noninteractive_creds" == 1 ]]; then
    # Credentials supplied via env — verify once, no prompt, no re-prompt.
    TB_CLIENT_ID=$(_sanitize_credential "$TRACEBLOC_CLIENT_ID")
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TRACEBLOC_CLIENT_PASSWORD")
    [[ -n "$TB_CLIENT_ID" && -n "$TB_CLIENT_PASSWORD" ]] || \
      error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD must be non-empty."
    tb_live "Verifying credentials..."
    case "$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")" in
      valid)      tb_live_done "Credentials verified" ;;
      invalid)    error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD was rejected by tracebloc. Check them against the credential file \`tracebloc client create\` wrote, or create a new pair ($(_credential_file_cmd)), load it ($(_credential_file_load_cmd)) and re-run." ;;
      inactive)   error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified) tb_live_done; warn "Couldn't reach tracebloc to verify credentials right now — continuing (the secure environment will stay offline if they are wrong)." ;;
    esac
  else

  # We must prompt for credentials, but there may be no terminal to prompt on
  # (typically `curl … | bash`, where stdin is the piped script). Fail here with
  # an actionable message rather than aborting opaquely under set -e. The
  # per-read `|| _no_interactive_creds_die` guards below catch the harder case
  # this cheap check can't: a tty that is readable (`-r`) but yields no input.
  if ! _tty_available; then
    _no_interactive_creds_die
  fi

  prompt_header "Connect this machine with a Client ID."
  hint "A Client ID links your secure environment to tracebloc"
  hint "so peers can upload models for evaluation."
  echo ""
  hint "Already have one? Enter its credentials below — or set"
  hint "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD to skip this prompt."
  hint "Need one? With a current tracebloc CLI, this installer signs you in through"
  hint "your browser and needs no Client ID or password. For an unattended install,"
  hint "create the pair (free) on a machine signed in to tracebloc; it writes tb.env:"
  echo -e "    ${TB_CMD}$(_credential_file_cmd)${RESET}"
  echo ""

  # Collect + verify credentials. The entered Client ID / password are checked
  # against the backend (the same api-token-auth/ call jobs-manager makes)
  # before we deploy, so a wrong credential is caught here and asked for again, with
  # no cap (Ctrl-C stops), instead of surfacing later as a silently crash-looping pod.
  local _cred_status _cred_file_line="Use the one in the credential file \`tracebloc client create\` wrote."
  while true; do
    if [[ -n "$default_client_id" ]]; then
      read -r -p "  Client ID [${default_client_id}]: " TRACEBLOC_CLIENT_ID_INPUT <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      TB_CLIENT_ID="${TRACEBLOC_CLIENT_ID_INPUT:-$default_client_id}"
    else
      read -r -p "  Client ID: " TB_CLIENT_ID <"$TRACEBLOC_TTY" || _no_interactive_creds_die
    fi
    TB_CLIENT_ID=$(_sanitize_credential "$TB_CLIENT_ID")
    if [[ -z "$TB_CLIENT_ID" ]]; then tb_refused "A Client ID is required." "$_cred_file_line"; continue; fi

    if [[ -n "$default_client_password" ]]; then
      read -r -s -p "  Client password [press Enter to keep existing]: " TRACEBLOC_CLIENT_PASSWORD_INPUT <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      echo ""
      TB_CLIENT_PASSWORD="${TRACEBLOC_CLIENT_PASSWORD_INPUT:-$default_client_password}"
    else
      read -r -s -p "  Client password: " TB_CLIENT_PASSWORD <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      echo ""
    fi
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TB_CLIENT_PASSWORD")
    if [[ -z "$TB_CLIENT_PASSWORD" ]]; then tb_refused "A password is required." "$_cred_file_line"; continue; fi

    tb_live "Verifying credentials..."
    _cred_status=$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")
    case "$_cred_status" in
      valid)
        tb_live_done "Credentials verified"
        break ;;
      invalid)
        tb_live_done
        tb_refused "tracebloc didn't accept this Client ID and password." \
          "Use the pair in the credential file \`tracebloc client create\` wrote." ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified)
        tb_live_done
        warn "Couldn't reach tracebloc to verify your credentials right now — continuing."
        hint "If they are wrong, your secure environment will stay offline at $(_dashboard_url) after install."
        break ;;
    esac

    # Force an active re-entry on retry (don't silently reuse a rejected default).
    default_client_id=""; default_client_password=""
  done
  fi
  _tb_trace_on
}

# ── One-client-per-machine guard ─────────────────────────────────────────
# A machine runs exactly one tracebloc client, so a DIFFERENT client installed in
# ANY namespace stops the install for the operator to decide; the same clientId is
# a re-run and passes. detect_installed_client, shared with the pre-flight, finds it.
# Then both credentials are escaped for the values file.
_client_helm_one_client_guard() {
  detect_installed_client
  existing_id="$INSTALLED_CLIENT_ID"; existing_ns="$INSTALLED_CLIENT_NS"
  # Fail CLOSED when we couldn't enumerate what's here (API/helm failure): refuse
  # rather than risk overwriting a client the guard simply couldn't see.
  if [[ "${INSTALLED_CLIENT_UNKNOWN:-0}" == 1 ]]; then
    echo ""
    warn "Couldn't determine which secure environment (if any) is already installed here."
    hint "tracebloc runs one secure environment per machine, so the installer won't risk overwriting"
    hint "an existing secure environment it can't see — usually the cluster API is briefly unreachable."
    hint "Check it and re-run:"
    hint "  $(tb_kubectl_shown) cluster-info"
    hint "  $(tb_helm_shown) list -A"
    echo ""
    error "Refusing to install without verifying what's already on this machine."
  fi
  if [[ -n "$existing_id" && "$existing_id" != "$TB_CLIENT_ID" ]]; then
    _refuse_other_client_id "$existing_id" "$existing_ns"
  fi

  # Same client under a DIFFERENT namespace (an older installer's fixed `tracebloc`):
  # upgrade THAT release in place. A second release would double-book this host's
  # capacity and orphan the first; moving namespaces is a delete-then-reinstall.
  if [[ -n "$existing_id" && "$existing_id" == "$TB_CLIENT_ID" && -n "$existing_ns" && "$existing_ns" != "$namespace" ]]; then
    log "Client '${existing_id}' already installed in namespace '${existing_ns}'; upgrading it in place instead of creating '${namespace}'."
    info "Updating the existing secure environment (namespace '${existing_ns}')."
    namespace="$existing_ns"
  fi

  # Both credentials go into SINGLE-quoted YAML scalars through the shared escaper,
  # so no character in them can corrupt the values file (_sanitize_credential
  # strips only paste/non-printable characters).
  TB_CLIENT_ID_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_ID")"
  { _tb_trace_off; } 2>/dev/null
  TB_CLIENT_PASSWORD_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_PASSWORD")"
  _tb_trace_on
}

# ── GPU request + runtime class ───────────────
# Training jobs request the vendor's GPU (_gpu_request_value: nvidia.com/gpu /
# amd.com/gpu, empty = CPU); NVIDIA's only once the GPU is WIRED into the cluster,
# as a node advertising 0 strands every job Pending. NVIDIA pods also run under the
# NVIDIA RuntimeClass (_gpu_runtime_class). SINGLE_NODE below has jobs-manager
# downgrade a GPU pod this single node can't satisfy to CPU.
# Then the device plugin, the engine, and (once the values write is logged) proxy and mirror.
_client_helm_runtime_values() {
  gpu_val="$(_gpu_request_value)"
  if _gpu_wired; then runtime_class="$(_gpu_runtime_class)"; fi
  device_type="$(_detect_device_type "$gpu_val")"
  log "Device type for the dashboard: ${device_type:-unknown (not reported)}"
  if [[ -n "$gpu_val" ]]; then
    log "${GPU_VENDOR} GPU wired — GPU_LIMITS/GPU_REQUESTS=${gpu_val}${runtime_class:+, RUNTIME_CLASS_NAME=${runtime_class}}"
  elif [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    warn "NVIDIA GPU detected but not wired into this cluster — running CPU-only (GPU_LIMITS/GPU_REQUESTS left empty)."
  else
    log "No GPU wired for training jobs — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # ── GPU device plugin ────────────────────────────────────────
  # The chart's device-plugin DaemonSet, enabled when a GPU vendor is detected, so
  # it's reconciled on upgrade and removed on `helm uninstall`; CPU-only installs
  # keep the chart default (disabled). NVIDIA's runs under the NVIDIA RuntimeClass
  # (without it NVML sees no GPU and it registers 0), so it's enabled only when the
  # GPU is wired: a stock CPU node has no `nvidia` RuntimeClass. AMD's needs none
  # and stays gated on bare detection.
  local rtc
  if _gpu_wired; then
    rtc="$(_gpu_runtime_class)"
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: nvidia\n    nvidia:\n      runtimeClassName: %s\n' "$rtc")"
    log "Helm-managed GPU device plugin enabled (vendor=nvidia, runtimeClassName=${rtc})"
  elif [[ "${GPU_VENDOR:-}" == "amd" ]]; then
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: amd\n')"
    log "Helm-managed GPU device plugin enabled (vendor=amd)"
  fi

  # Pick the MySQL engine for this install (before the heredoc
  # below is rendered; see _resolve_mysql_engine for the full decision rules).
  _resolve_mysql_engine
  # and only now is it knowable whether this host can run the
  # engine that rule picked. Ordering, not duplication — the arch question is
  # asked against the resolved engine, never ahead of it.
  _assert_engine_runs_on_this_arch

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"

  # Translate a corporate proxy on the host into the chart's split proxy keys so
  # every egress-needing workload inherits it (see _chart_proxy_env_yaml). Empty
  # when the host has no proxy — the env: block is then unchanged.
  # The proxy's password and the mirror's are held with bash -x off (output.sh).
  { _tb_trace_off; } 2>/dev/null
  proxy_env_yaml="$(_chart_proxy_env_yaml)"
  [[ -z "$proxy_env_yaml" ]] || log "Corporate proxy detected on host — propagating to client workloads via chart values."
  _tb_trace_on

  # Private registry mirror: re-home every image onto TRACEBLOC_IMAGE_REGISTRY
  # for restricted-network / air-gapped installs. Empty when unset (values unchanged).
  { _tb_trace_off; } 2>/dev/null
  image_mirror_yaml="$(_image_mirror_yaml)"
  _tb_trace_on
  if [[ -n "${TRACEBLOC_IMAGE_REGISTRY:-}" ]]; then
    log "Image registry mirror configured — pulling all images from ${TRACEBLOC_IMAGE_REGISTRY}."
    [[ -n "${TRACEBLOC_REGISTRY_USERNAME:-}" ]] && log "Mirror credentials provided — minting an imagePullSecret for the mirror."
  fi
  return 0
}

# Option A: size the default training budget to this machine.
# One pass, both answers — the probes are bounded but not free,
# and calling the two wrappers separately would run them twice.
_client_helm_training_fit() {
  _resolve_training_size
  # and only now, is what was chosen schedulable HERE -- beside the
  # chart's control plane and the system pods already on the node? Ours gets
  # reduced or refused; a human's gets warned. The arithmetic is printed in every
  # case that changes or blocks anything, because an operator reading `Pending /
  # Insufficient memory` later needs the numbers, not the verdict.
  _fit_training_envelope
  case "$_TB_FIT_VERDICT" in
    refused)
      _print_fit_refusal \
        "This machine cannot schedule a training beside the platform, so no training envelope is written:" \
        "$_TB_FIT_LINES" \
        "Refusing to write a training envelope that cannot be scheduled on this machine." \
        "$_TB_FIT_CAUSE"
      ;;
    reduced)
      # The size it was reduced to is the summary's Compute row. The arithmetic is e2e's
      # (O-108): on stdout when nobody watches it, in the log when a person does.
      if [[ -n "${_TB_STDOUT_TTY:-}" ]]; then
        log "Training envelope reduced to fit beside the platform on this machine:"
        _print_fit_lines log
      else
        info "Training envelope reduced to fit beside the platform on this machine:"
        _print_fit_lines hint
      fi
      ;;
    pinned-over)
      warn "The chosen training size does not fit beside the platform on this machine; training pods will stay Pending until it is lowered:"
      _print_fit_lines hint
      ;;
    unverified)
      warn "Training envelope UNVERIFIED: ${_TB_FIT_LINES}"
      hint "  Grant the installer 'get nodes' and 'list pods' to have it checked, or set TRACEBLOC_TRAINING_RESOURCES to a size you know fits."
      ;;
    *)
      # Fits: the arithmetic goes to the log file only, so a re-read later can
      # still see what was checked without it cluttering a clean install.
      _print_fit_lines log
      ;;
  esac
  training_size="$_TB_TRAINING_SIZE"
  training_provenance="$_TB_TRAINING_PROVENANCE"
  if [[ "$_TB_FIT_VERDICT" != refused ]] && (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 0 )); then
    _TB_COMPUTE_SHOWN="$(_envelope_display "$training_size")"
  fi
  log "Training size: ${training_size} (adjust any time with 'tracebloc resources set')"
  # The warning belongs HERE, not in the resolver: the resolver's output is
  # captured with $(...) by _training_resources / _training_provenance, so a warn
  # emitted there would end up inside the value.
  if (( ${_TB_TRAINING_UNDERSIZED:-0} == 1 )); then
    warn "This machine is below the size a training wants: ${training_size} is all that is left after the platform's reservation."
    hint "The secure environment will install and run, but trainings may be killed for memory. ~16 GB of RAM is the recommendation for training locally."
  elif (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 1 )); then
    warn "This machine is too small to host a training at all; keeping the default ${training_size}."
    hint "Trainings will wait for room until this machine has more memory — the secure environment itself will still run, ingest and report."
  fi
  # The ingestion Job did not fit beside the size written (_fit_verdict): the run
  # was kept at no less than the floor, so an upload queues behind it.
  if (( ${_TB_FIT_INGEST_WAITS:-0} == 1 )); then
    warn "A data ingest started while a training is using this machine waits until the training ends."
    hint "  An ingest needs $(( _TB_ENVELOPE_INGESTION_MEM_BYTES / 1024 / 1024 )) MiB / ${_TB_ENVELOPE_INGESTION_CPU_MILLI} m free beside ${training_size}; ingest between trainings, or give this machine more CPU and memory."
  fi
}

# Write generated values.yaml from what the stages above set.
_client_helm_write_values() {
  # CREATE IT EMPTY AND 0600 *BEFORE* THE CREDENTIAL GOES IN: the heredoc alone
  # would create it at the process umask, readable while clientPassword goes in.
  # `>` on an EXISTING file truncates without touching its mode, so the heredoc
  # writes into a file already 0600. Only the GENERATED file: dev mode
  # (TRACEBLOC_VALUES_FILE) never runs this stage.
  : > "$values_file" || error "Could not create $values_file"
  chmod 600 "$values_file" 2>/dev/null || true
  # The stage, read from the shell's TRACEBLOC_ENV as tb_client_env reads it,
  # and written under env.TRACEBLOC_ENV only: every reader of these values (the
  # chart's tracebloc.clientEnv, assess.sh's _assess_release_client_env, the
  # CLI) reads that key first.
  local _tb_stage_raw="${TRACEBLOC_ENV:-}" _tb_stage_resolved=""
  [ -n "$_tb_stage_raw" ] && _tb_stage_resolved="$(tb_client_env "$_tb_stage_raw")"
  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "$_tb_stage_resolved" ] && printf '  TRACEBLOC_ENV: "%s"\n' "$_tb_stage_resolved")${proxy_env_yaml}
  # Training size: how much CPU/RAM each training run gets. Sized to this
  # machine at install — largest node minus ~1 CPU / 3 GiB platform overhead —
  # unless TRACEBLOC_TRAINING_RESOURCES is set or the installed release already
  # carries a choice (option A).
  #
  # THE TWO HALVES ARE NOT THE SAME STRING any more (L0.2):
  # requests carries cpu AND memory, limits carries memory ONLY. CPU is
  # time-shared, so a request with no limit is a share weight rather than a
  # quota that throttles on an idle machine; memory is not time-shared, so
  # requests == limits stays. See _training_limits for the full reasoning and
  # for the ordering constraint.
  RESOURCE_LIMITS: "$(_training_limits "${training_size}")"
  RESOURCE_REQUESTS: "${training_size}"
  # Who chose the pair above. Bookkeeping only — it never changes
  # the envelope. "unknown" means the value was carried forward from before this
  # key existed and is genuinely unattributable, so consumers treat it as "user".
  RESOURCE_PROVENANCE: "${training_provenance}"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  # nvidia when the GPU is wired: jobs-manager threads it into every
  # spawned pod so the node's containerd invokes the NVIDIA runtime; "" on CPU.
  RUNTIME_CLASS_NAME: "$runtime_class"
  # an installer-provisioned cluster is a fixed single host
  # that cannot autoscale, so jobs-manager applies the hard CPU-or-GPU rule —
  # a Pending GPU pod is downgraded to CPU rather than waiting for a GPU node
  # that will never arrive.
  SINGLE_NODE: "true"
  # what kind of machine this is, for the dashboard's switcher —
  # the chassis this installer read (TRACEBLOC_DEVICE_TYPE overrides), or ""
  # when it could not tell, which the chart drops and jobs-manager then omits.
  DEVICE_TYPE: "${device_type}"
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  HOST_UID: "%s"\n  HOST_GID: "%s"\n' "$(id -u)" "$(id -g)")
$(if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
cat <<'STORAGE'
# Node-local: use k3s's built-in local-path StorageClass.
# No hostPath PVs, so dataset volumes are provisioned in k3s's local-path
# storage on the node rather than in host folders the chart names.
storageClass:
  create: false
  name: local-path

hostPath:
  enabled: false

# node-local is a single schedulable node (native k3s is one server),
# so the single-replica PDBs would be undrainable here. hostPath.enabled=false
# would otherwise misclassify this as multi-node, so declare the topology
# explicitly to skip those PDBs and keep the node drainable.
singleNode: true
STORAGE
else
cat <<'STORAGE'
storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true
STORAGE
_hostpath_paths_block
fi)
$(_local_api_values_block)
$(if [[ "${TB_MYSQL_ENGINE_RESOLVED:-5.7}" == "8.4" ]]; then
cat <<MYSQL84

# MySQL engine: the multi-arch 8.4 engine (the chart default
# since the 8.4 default switch). Stated explicitly rather than left to the chart
# default, so the sticky read finds it on every re-run and no later chart
# default can move this datadir. Pinned by the chart's own 8.4 digest, so it
# renders the same image the chart default does, never the moving 8.4 tag.
# Override with TB_MYSQL_ENGINE=5.7|8.4.
images:
  mysqlClient:
    tag: "8.4"
    digest: "${TB_MYSQL_84_DEFAULT_DIGEST}"
MYSQL84
else
cat <<MYSQL57

# MySQL engine: this install stays on the 5.7 engine (an existing release or
# datadir, or TB_MYSQL_ENGINE=5.7), pinned to the frozen 5.7-lineage image.
# EXPLICIT since the 8.4 default switch made 8.4 the chart default: left to the default,
# the next upgrade would render 8.4 over this 5.7 datadir, which 8.4 refuses to
# open. Move it to 8.4 with the 8.4 migration, never by editing this pin.
images:
  mysqlClient:
    tag: "${TB_MYSQL_57_PIN_TAG}"
    digest: "${TB_MYSQL_57_PIN_DIGEST}"
MYSQL57
fi)
${gpu_block:+$gpu_block
}pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true
${image_mirror_yaml}
clientId: '$TB_CLIENT_ID_ESCAPED'
clientPassword: '$TB_CLIENT_PASSWORD_ESCAPED'

EOF
}

# values.yaml's mode, checked after the write.
_client_helm_check_values_mode() {
  # DEFENCE IN DEPTH, AND THEN A CHECK -- not a silent best-effort: a chmod that
  # did not apply would leave clientPassword world-readable and say nothing.
  #
  # POSIX `ls -ldn`, NEVER GNU-only `stat -c` -- BSD rejects `-c` silently.
  # install-client-helm.bats' "the values.yaml mode is read with POSIX ls -ldn,
  # never GNU-only stat -c" holds this block to it.
  #
  # WARN RATHER THAN error, deliberately. chmod genuinely cannot apply on a
  # host_data_dir living on a filesystem without POSIX modes (exFAT, some
  # Windows/WSL mounts), and refusing to install there would trade a readable file
  # for no tracebloc at all. So it names the mode it actually found and continues:
  # an operator can act on "-rw-r--r--", not on silence; a failing ls must reach "" under pipefail.
  chmod 600 "$values_file" 2>/dev/null || true
  local _vf_mode; _vf_mode="$(ls -ldn "$values_file" 2>/dev/null | awk 'NR==1{print $1}')" || _vf_mode=""
  case "$_vf_mode" in
    -rw-------*) : ;;
    "")          warn "Could not read the mode of $values_file -- it holds a live credential; check that other users cannot read it." ;;
    *)           warn "$values_file is $_vf_mode, not -rw------- . It holds your clientPassword in cleartext; restrict it with: chmod 600 $values_file" ;;
  esac
  log "Values file written to $values_file"
}

# Before the helm apply: helm, the chart, the metrics API, a pending release, the --set-string words.
_client_helm_prepare_apply() {
  _ensure_helm_runnable

  # ── Resolve chart reference: local path (dev) or remote repo (default) ──
  _resolve_chart_ref

  # Said before the download line starts; rides _gpu_args below.
  _collector_set_args fresh "$namespace" "$namespace"

  log "Installing $namespace from $chart_ref in namespace '$namespace'..."
  # One line from here to the images on the node: the metrics wait, the chart and the
  # pulls (_download_services_progress ends it).
  tb_live "Downloading tracebloc services..."

  # Pre-create per-release hostPath dirs so they're owned by the host user, not
  # root:root from kubelet's DirectoryOrCreate. See _ensure_release_dirs.
  # node-local (node-local storage) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-node-local}" != "node-local" ]] && _ensure_release_dirs "$namespace"

  # wait out the metrics-server APIService registration race before helm
  # renders the resource-monitor DaemonSet (whose template hard-fails if the
  # metrics API isn't registered yet). Bounded + best-effort. The outer spinner
  # deadline must never truncate the configured inner wait, so derive it from
  # TB_METRICS_WAIT_S (same parse as _wait_for_metrics_apiservice) plus slack for
  # the post-registration `kubectl wait --for=Available` (30s) and jitter.
  local _metrics_wait_s="${TB_METRICS_WAIT_S:-}"
  case "$_metrics_wait_s" in ''|*[!0-9]*) _metrics_wait_s="$METRICS_WAIT_TIMEOUT" ;; *) _metrics_wait_s=$((10#$_metrics_wait_s)) ;; esac
  spin_cmd_bounded "$(( _metrics_wait_s + 60 ))" "Waiting for the metrics API to register…" \
    _wait_for_metrics_apiservice || true

  # The chart install blocks ~10-15s (render + apply + image pull), so run it
  # behind a spinner instead of a frozen terminal — spin_cmd_bounded streams
  # helm output to $LOG_FILE and, on failure, tails the log to stderr. Gives
  # progress on every wait; the deadline stops a wedged
  # kube-apiserver from hanging the install forever.
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"

  # clear any pending-* wedge left by a previously killed helm op (Ctrl-C,
  # OOM, reboot) before we upgrade — otherwise this run just fails with "another
  # operation is in progress" (exit 1) and the machine stays wedged across every
  # re-run. The release name equals the namespace on the normal install path.
  # Fail closed if recovery itself couldn't clear it.
  if ! _recover_pending_helm_release "$namespace" "$namespace"; then
    hint "Couldn't automatically clear the interrupted release. Recover it by hand, then re-run:"
    hint "  first install:  $(tb_helm_shown) -n $namespace uninstall $namespace    (removes only the half-installed release)"
    hint "  upgrade:        $(tb_helm_shown) -n $namespace rollback $namespace     (returns to the previous release)"
    error "Client installation blocked by an interrupted previous helm operation. Check the log for details: ${LOG_FILE:-}"
  fi

  # migration: an earlier install applied the GPU device plugin with
  # an imperative `kubectl apply` (unowned by Helm). If that DaemonSet survived a
  # `helm uninstall` — the exact litter this migration is about — this fresh install would
  # now fail with "exists and cannot be imported into the current release". Label
  # + annotate any such orphan for Helm adoption so the chart takes it over IN
  # PLACE (no GPU blip), instead of colliding. Best-effort + bounded + idempotent:
  # a missing DS or a kubectl hiccup must never block the install (GPU is
  # optional). Only runs on the GPU path; a no-op everywhere else.
  _adopt_orphaned_gpu_device_plugin

  # the unsupported-GPU reason and card ride --set-string, not the
  # values heredoc: the sentence is free text (apostrophes, commas), and
  # _helm_set_string_escape is the one quoting rule both install paths share.
  # dev mode installs a values file the installer did not write, so
  # it gets THIS run's whole GPU decision, the adopt reconcile's: the caller's file
  # supplies everything else, the GPU keys and the device plugin stay the installer's.
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    _gpu_decision_set_args
    _gpu_args=("${_TB_GPU_DECISION_ARGS[@]}")  # set-u-safe: _gpu_decision_set_args always assigns
    log "Dev mode: this run's GPU decision overrides the values file's GPU keys: ${_gpu_args[*]}"  # set-u-safe: _gpu_decision_set_args always assigns
  else
    _gpu_unsupported_set_args
    _gpu_args=("${_TB_GPU_UNSUPPORTED_ARGS[@]}")  # set-u-safe: _gpu_unsupported_set_args always assigns six words
  fi
  # The host's OS, on both branches: not a GPU word, but the
  # same --set-string route, so it rides this array into the one helm call.
  _host_os_set_args
  _gpu_args+=("${_TB_HOST_OS_ARGS[@]}")  # set-u-safe: _host_os_set_args always assigns two words
  # The machine facts (kind, cloud, CPU name), the same way.
  _machine_facts_set_args
  _gpu_args+=("${_TB_MACHINE_FACTS_ARGS[@]}")  # set-u-safe: _machine_facts_set_args always assigns six words
  # Whether k3s runs the pods confined (_selinux_set_args), the same way.
  _selinux_set_args
  _gpu_args+=(${_TB_SELINUX_ARGS[@]+"${_TB_SELINUX_ARGS[@]}"})
  # The macOS node's values profile, on both branches: over the values
  # file this run wrote, and over a caller's own in dev mode.
  _mac_node_profile_set_args
  _gpu_args+=(${_TB_MAC_PROFILE_ARGS[@]+"${_TB_MAC_PROFILE_ARGS[@]}"})
  _mac_runner_set_args
  _gpu_args+=(${_TB_MAC_RUNNER_ARGS[@]+"${_TB_MAC_RUNNER_ARGS[@]}"})
  _gpu_args+=(${_TB_COLLECTOR_ARGS[@]+"${_TB_COLLECTOR_ARGS[@]}"})
}

# The helm apply, its record, and a restart of pods a changed credential left on the old one.
_client_helm_upgrade() {
  local _helm_rc=0
  # The password the running pods started on, read before helm overwrites it, so
  # the restart below can see a credential that changed under them.
  # A read that CANNOT TELL (rc 2) is not a first install: when the Secret holds a
  # password after helm, the pods may have started on a different one, so that
  # restarts below.
  local _prev_password _prev_unreadable=0
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  _prev_password="$(_client_password_from_secret "$namespace" "$namespace")" \
    || _prev_unreadable=1
  _tb_trace_on
  # The lock's prefix has a line of its own, so the call still starts its line, where
  # release-name-equals-namespace.sh reads the release's name from.
  _tb_helm_lock
  spin_cmd_bounded "$(_tb_helm_deadline_s "$_helm_timeout_min")" "Installing your secure environment…" \
    ${_TB_HELM_LOCK[@]+"${_TB_HELM_LOCK[@]}"} \
    helm upgrade --install "$namespace" "$chart_ref" \
    --namespace "$namespace" \
    --create-namespace \
    --cleanup-on-fail \
    --values "$values_file" \
    "${_gpu_args[@]}" || _helm_rc=$?  # set-u-safe: both branches above assign at least six words
  if [[ "$_helm_rc" -ne 0 ]]; then
    _tb_helm_lock_timed_out "$_helm_rc"
    # A helm op killed partway (timeout=124, or an in-progress wedge=exit 1) can
    # leave the release pending-*. The next run auto-recovers
    # (_recover_pending_helm_release), but name the manual unwedge too — on exit
    # 1, not only the 124 timeout.
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  first install:  $(tb_helm_shown) -n $namespace uninstall $namespace    (removes only the half-installed release)"
    hint "  upgrade:        $(tb_helm_shown) -n $namespace rollback $namespace     (returns to the previous release)"
    error "Client installation failed. Check the log for details: ${LOG_FILE:-}"
  fi
  # The release offboarding removes: named after its namespace on
  # this path, which is the record's namespace field.
  tb_record_write helm-release "$namespace" ""

  # kubectl and the tracebloc CLI default to the client namespace, with no -n flag.
  tb_kube_set_namespace "$namespace"

  # A credential issued to a client that is already running here (the
  # credential-rejected repair), or any other new password written
  # over a running release's (a preset), is in the Secret now,
  # but the pods read it from their environment at start and the chart doesn't
  # roll them on a Secret change. Restart the ones that authenticate so they use it.
  # An unreadable read before helm with one that reads after it is "cannot tell",
  # and restarts; unreadable on both sides is a cluster nothing here can roll.
  local _now_password _changed=0
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  _now_password="$(_client_password_from_secret "$namespace" "$namespace")" || _now_password=""
  if [[ "${TRACEBLOC_CREDENTIAL_REISSUED:-0}" == 1 ]] \
     || [[ "$_prev_unreadable" == 1 && -n "$_now_password" ]] \
     || _credential_changed_under_pods "$_prev_password" "$_now_password"; then
    _changed=1
  fi
  _prev_password=""; _now_password=""
  _tb_trace_on
  if [[ "$_changed" == 1 ]]; then
    _restart_credential_consumers "$namespace" \
      || error "This machine's new credential is in place, but its services are still on the old one."
  fi
}

install_client_helm() {
  # Step e (Install tracebloc) — main() prints the "e) Installing tracebloc"
  # header. The credential + namespace were provisioned in step d
  # (provision_client) or supplied via dual-mode (TRACEBLOC_CLIENT_ID/PASSWORD or
  # TRACEBLOC_VALUES_FILE). This step renders the values, runs Helm, and shows the
  # services download; the final connect + summary is step f.
  # node-local (node-local storage): data lives inside the node, so skip the
  # world-writable ~/.tracebloc/{data,logs,mysql} dirs; just ensure the base dir
  # exists for values.yaml + the install log.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    mkdir -p "$host_data_dir"
  else
    _ensure_tracebloc_dirs
  fi
  local values_file; values_file="$(_client_values_file)"

  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    _client_helm_dev_mode
  else
  local use_existing="" default_client_id="" default_client_password="" _noninteractive_creds=0
  _client_helm_previous_config

  # ── Namespace (fixed; not prompted) ──────────────────────────────────────
  # The on-prem client is one-per-machine and is identified to the backend by
  # its credentials (clientId), not by this name — so we don't ask the user to
  # invent one. It's just the local k8s namespace / Helm release name.
  # Advanced / GitOps setups can override with namespace=<name>.
  namespace=$(_client_default_namespace)

  # Native k3s: an installed release keeps the storage it was made with, before the
  # reconcile and the values below read TB_STORAGE_MODE.
  _native_k3s_release_storage
  _mac_node_storage_steps

  # A re-run on an already-connected client must reconcile in place,
  # not re-provision. Step 3 marks that case with TRACEBLOC_CLIENT_ADOPTED=1 (+ the
  # UUID, no password). Honor it: reconcile the live release silently — no credential
  # prompt, no verify, no duplicate. Only if there's no live release to reconcile do
  # we fall through to the normal connect flow below.
  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == 1 ]] && _reconcile_adopted_client; then
    # What helm did, as the fresh path says it below; no "installed" claim here,
    # whether the install succeeded is step f's.
    tb_live "Installing services..."
    _installed_services_line "$namespace"
    log "Reconciled adopted client in namespace '$namespace'"
    return 0
  fi

  _client_helm_credentials
  local existing_id="" existing_ns=""
  _client_helm_one_client_guard
  local gpu_val runtime_class="" device_type="" gpu_block="" proxy_env_yaml image_mirror_yaml
  _client_helm_runtime_values
  local training_size training_provenance
  _client_helm_training_fit
  _client_helm_write_values
  _client_helm_check_values_mode
  fi

  local chart_ref="" _helm_timeout_min _gpu_args
  _client_helm_prepare_apply
  _client_helm_upgrade

  # Honest N-of-M count as the service images pull onto the node. Best-effort +
  # bounded + non-fatal — the real readiness gate is step f (wait_for_client_ready).
  _download_services_progress "$namespace"
  tb_live_done

  tb_live "Installing services..."
  _installed_services_line "$namespace"
  log "Values file: $values_file"
}

# _installed_services_line NS -- step e's "Installing services..." ends with how many
# services the release installed, the count its "Downloaded" line gave
# (_release_service_count). With no count it stays "· Installing services...".
# Step e ends on this line: it says what helm did, never that tracebloc is installed.
# Whether the install succeeded is step f's (wait_for_client_ready), and the summary
# says it: a refused install must never have said "installed" first.
_installed_services_line() {
  local n
  if n="$(_release_service_count "$1" 10s)"; then
    tb_live_done "Installed · ${n} services"
  else
    log "The release in $1 has no service this run could count."
    tb_live_done
  fi
}
