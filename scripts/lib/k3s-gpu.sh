#!/usr/bin/env bash
# =============================================================================
#  k3s-gpu.sh — the NVIDIA GPU on native k3s (1.1i), and in tracebloc's WSL distro
#
#  LINUX ONLY. Moved out of k3s.sh; install-k8s.sh sources it right
#  after k3s.sh and k3s-firewall.sh, and both bootstraps fetch it. Every function keeps the
#  `_native_k3s_` prefix, and it reads k3s.sh's constants (TB_K3S_ETC_DIR among them).
#  bash 3.2-safe; sourcing it has no side effects: constants and functions only.
# =============================================================================

# ── The NVIDIA GPU (1.1i) ─────────────────────────────────────────────────────
#
# On native k3s: the host's nvidia-container-toolkit, k3s's own `nvidia`
# runtime and RuntimeClass, and the chart's device plugin under that class. No
# k3s-cuda image, no --gpus, no Docker.
#   step b  dispatch_gpu_setup (setup-linux.sh) installs the driver, then
#           _native_k3s_gpu_prepare: the toolkit package and a CDI spec, before k3s
#           first starts, so k3s finds the runtime at its first start;
#   step c  _native_k3s_gpu_wire, after the node is Ready: TRACEBLOC_GPU_WIRED=1 only when
#           k3s's own containerd has registered the runtime;
#   step e  _native_k3s_gpu_verify (through verify_gpu), after Helm: "wired" only
#           when the node advertises at least one nvidia.com/gpu.
#
# Built to the driver-floor fallback, then measured by spike S-G (0.18)
# on 2026-10-01: a g4dn.12xlarge (4x T4, sm_75) at k3s v1.36.3
# with toolkit 1.20.1 and drivers 580, 570, 550 and 535. Each value below says
# whether S-G measured it; one still marked "floor, not measured" is a vendor-cited
# minimum nothing has tested. The driver floor itself is facts.env's
# NVIDIA_DRIVER_FLOOR_LINUX (0.11), which warns here.

# The runtime k3s's containerd must register for the GPU to count as wired, and the
# RuntimeClass the device plugin and the training jobs run under (kube.sh
# _gpu_runtime_class): k3s creates a RuntimeClass of the same name for it.
# k3s registers its NVIDIA runtimes when it finds the toolkit's binaries on its PATH
# at start, and pods ask for one with `runtimeClassName: nvidia` (docs.k3s.io/advanced,
# "NVIDIA Container Runtime Support"). MEASURED (S-G): toolkit 1.20.1 ships only
# `nvidia-container-runtime`, so k3s registers `nvidia` and no `nvidia-cdi` or
# `nvidia-experimental` handler, although it creates `nvidia` and `nvidia-experimental`
# RuntimeClasses; under `nvidia` the toolkit's default `mode = "auto"` runs as jit-CDI
# ("Auto-detected mode as 'jit-cdi'"), and GEMM, cuDNN, AMP, a 4-GPU NCCL all-reduce
# and one training per GPU family passed. The CDI path needs no `nvidia-cdi` class: a
# RuntimeClass of that name is refused ("no runtime for "nvidia-cdi" is configured").
TB_K3S_GPU_RUNTIME="nvidia"
# The CDI spec this installer writes when the host has none: where k3s's containerd
# and the toolkit read specs. MEASURED (S-G): with toolkit 1.20.1 it is never written,
# because the toolkit's own spec (below) is there first; it is the path for a toolkit
# that writes none.
TB_K3S_GPU_CDI_PATH="/etc/cdi/nvidia.yaml"
# Where the toolkit's own nvidia-cdi-refresh unit writes its spec, from toolkit 1.18.0
# on, at install, on a driver change and at boot (NVIDIA Container Toolkit docs,
# "Support for Container Device Interface"). A spec there is the toolkit's: it is
# used as it is and never recorded. MEASURED (S-G): toolkit 1.20.1 wrote
# /var/run/cdi/nvidia.yaml during its own package install, before step b looked, and
# rewrote it after each driver change.
TB_K3S_GPU_CDI_RUN_DIR="/var/run/cdi"
# The oldest NVIDIA Container Toolkit the native path is built for: 1.18.0, the first
# whose runtime uses a just-in-time CDI spec by default instead of `legacy` mode, and
# that writes its own spec (NVIDIA Container Toolkit v1.18.0 release notes). That is
# the path D8 names and S-G tests. FLOOR, NOT MEASURED: S-G ran 1.20.1, which the
# installer's repository served; nothing has measured an older toolkit on k3s.
# Below it the run WARNS and goes on, like the driver floor (W17): step c's gate
# still decides. (`nvidia-ctk cdi generate` itself exists from 1.12.0.)
TB_K3S_GPU_TOOLKIT_FLOOR="1.18.0"

# The wired-pass marker: the GPU stack signature (gpu-nvidia.sh _gpu_stack_signature)
# of the last run whose gate passed; a re-run whose signature equals it restarts nothing.
# Root's in both modes and recorded as a `file`, a kind delete removes only under /etc
# (the schema's x-tracebloc-artefact-paths); k3s's own uninstall removes it too.
TB_K3S_GPU_MARKER_PATH="${TB_K3S_ETC_DIR}/tracebloc-gpu-wired"

# _native_k3s_gpu_legacy_rm -- the marker's legacy path goes, if it is there: hosts an
# older installer wired keep it unrecorded, so delete never removes it. Prepared mode:
# beside the named user's root copy, root's. Own mode: in the data dir, this user's.
_native_k3s_gpu_legacy_rm() {
  if [[ "${TB_K3S_PREPARED:-}" == 1 && -n "${TB_RECORD_FOR_USER:-}" ]]; then
    local root; root="$(_tb_record_root_path "$TB_RECORD_FOR_USER")"
    tb_root rm -f "${root%/*}/.gpu-k3s-wired" 2>/dev/null || true
    return 0
  fi
  local dir="${host_data_dir:-${HOME:+${HOME}/.tracebloc}}"
  [[ -z "$dir" ]] || rm -f "${dir}/.gpu-k3s-wired" 2>/dev/null || true
}

# _native_k3s_gpu_mark SIG -- a gate that passed: the marker holds SIG, and the record
# lists it once. Best-effort: a marker root could not write is not recorded.
_native_k3s_gpu_mark() {
  _native_k3s_gpu_legacy_rm
  { tb_root mkdir -p "${TB_K3S_GPU_MARKER_PATH%/*}" \
      && printf '%s' "$1" | tb_root tee "$TB_K3S_GPU_MARKER_PATH" >/dev/null; } 2>/dev/null || return 0
  tb_record_write file gpu-wired "$TB_K3S_GPU_MARKER_PATH"
}

# _native_k3s_gpu_unmark -- the marker goes, so the next run asks again, and its record
# line with it; a marker root could not remove stays recorded.
_native_k3s_gpu_unmark() {
  _native_k3s_gpu_legacy_rm
  tb_root rm -f "$TB_K3S_GPU_MARKER_PATH" 2>/dev/null || return 0
  tb_record_drop file gpu-wired "$TB_K3S_GPU_MARKER_PATH"
}

# _native_k3s_gpu_cpu REASON [blind] -- CPU mode for this run, said ONCE: TRACEBLOC_GPU_WIRED
# stays 0 and the wired-pass marker goes, so the next run asks again. The hint says how
# to get the GPU: fix REASON and re-run. Native k3s needs no recreate.
# `blind` marks a REASON that is k3s's container runtime itself saying it has no GPU
# for a container (no NVIDIA runtime, no CDI spec, the runtime never registered), told
# to the platform as runtime_cannot_see_gpu; a read that could not tell
# passes no flag.
_native_k3s_gpu_cpu() {
  TRACEBLOC_GPU_WIRED=0
  _native_k3s_gpu_unmark
  if [[ "${2:-}" == blind ]] && declare -F _gpu_container_blind >/dev/null; then
    _gpu_container_blind "k3s"
  fi
  [[ -z "${TB_K3S_GPU_WARNED:-}" ]] || return 0
  TB_K3S_GPU_WARNED=1
  if [[ "${TB_K3S_PREPARED:-}" == 1 ]]; then
    warn "The NVIDIA GPU is not wired into k3s: ${1}. ${TB_RECORD_FOR_USER:-The named user}'s install will run in CPU mode."
    hint "Fix that, then re-run prepare-host: it wires the GPU into the k3s already here, with no reinstall."
    return 0
  fi
  warn "The NVIDIA GPU is not wired into k3s: ${1}. This machine will run in CPU mode."
  hint "Fix that, then re-run the installer: it wires the GPU into the k3s already here, with no reinstall."
}

# _native_k3s_gpu_toolkit_floor -- warn, once, when the toolkit is older than
# TB_K3S_GPU_TOOLKIT_FLOOR, or does not say its version. Never a refusal.
_native_k3s_gpu_toolkit_floor() {
  local out ver
  out="$(_bounded "${TB_PROBE_TIMEOUT:-5}" nvidia-ctk --version 2>/dev/null)" || out=""
  ver="$(printf '%s\n' "$out" | sed -n 's/^NVIDIA Container Toolkit CLI version \([0-9][0-9.]*\).*$/\1/p')"
  ver="${ver%%$'\n'*}"
  if [[ -z "$ver" ]]; then
    warn "Couldn't read the NVIDIA Container Toolkit's version ('nvidia-ctk --version'); tracebloc is tested with ${TB_K3S_GPU_TOOLKIT_FLOOR} and later."
  elif _version_lt "$ver" "$TB_K3S_GPU_TOOLKIT_FLOOR"; then
    warn "NVIDIA Container Toolkit ${ver} is older than ${TB_K3S_GPU_TOOLKIT_FLOOR}, the version tracebloc is tested with — continuing; if GPU training fails on this machine, upgrade the toolkit."
  fi
}

# _native_k3s_gpu_cdi_spec -- a CDI spec for the NVIDIA GPU, after the toolkit. One
# the host already has (TB_K3S_GPU_CDI_PATH, or a nvidia*.yaml the toolkit wrote under
# TB_K3S_GPU_CDI_RUN_DIR) is used as it is: it is not this run's, and it is not
# recorded. Otherwise `nvidia-ctk cdi generate` writes TB_K3S_GPU_CDI_PATH, bounded by
# TB_GPU_CDI_TIMEOUT, and the file is recorded the moment it exists, so delete
# removes it. Presence is the authority, never the exit code: 0 when a non-empty
# spec is in place, 1 (CPU mode, said
# once) when there is none.
_native_k3s_gpu_cdi_spec() {
  local p
  for p in "$TB_K3S_GPU_CDI_PATH" "$TB_K3S_GPU_CDI_RUN_DIR"/nvidia*.yaml; do
    tb_root test -e "$p" || continue
    if tb_root test -s "$p"; then
      log "NVIDIA CDI spec already on this machine (${p}); using it as it is."
      return 0
    fi
    # An empty spec is no spec: skip it, and regenerate below (over it, when it is
    # the one at TB_K3S_GPU_CDI_PATH), rather than staying CPU on a file nothing fills.
    log "NVIDIA CDI spec at ${p} is empty; generating one."
  done
  tb_root mkdir -p "$(dirname "$TB_K3S_GPU_CDI_PATH")" || true
  _bounded_root "${TB_GPU_CDI_TIMEOUT:-60}" nvidia-ctk cdi generate --output="$TB_K3S_GPU_CDI_PATH" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  # --print listed the generate and ran nothing, so there is no spec to read back.
  if tb_root_planning; then return 0; fi
  if tb_root test -e "$TB_K3S_GPU_CDI_PATH"; then
    tb_record_write file cdi-spec "$TB_K3S_GPU_CDI_PATH"
  fi
  if tb_root test -s "$TB_K3S_GPU_CDI_PATH"; then
    log "NVIDIA CDI spec written (${TB_K3S_GPU_CDI_PATH})."
    return 0
  fi
  _native_k3s_gpu_cpu "'nvidia-ctk cdi generate' wrote no CDI spec to ${TB_K3S_GPU_CDI_PATH}; check that 'nvidia-smi' works" blind
  return 1
}

# ── The GPU in tracebloc's WSL distro (S-W row 13) ──────────────
# The device WSL gives a distro for the Windows host's GPUs (NVIDIA's CUDA on WSL guide).
TB_WSL_DXG_PATH="/dev/dxg"
# The unit the distro's image runs at each start, before k3s, to write the WSL spec at
# TB_K3S_GPU_CDI_PATH: `nvidia-ctk cdi generate --mode=wsl`, then libdxcore into its
# mounts (wsl-distro.sh, gpu_files).
TB_K3S_GPU_WSL_CDI_UNIT="tracebloc-cdi.service"
# The bound on restarting it, in seconds: above the unit's own TimeoutStartSec, so
# systemd, not this bound, ends a start that hangs (wsl-distro.bats holds the two).
TB_K3S_GPU_WSL_CDI_BOUND=150
# What a whole WSL spec names: the GPU, /dev/dxg and libdxcore. The same three
# tracebloc-cdi holds its own spec to before it keeps it (wsl-distro.bats reads them out
# of wsl-distro.sh and holds this list to them). Without libdxcore, libcuda loads but
# never reaches /dev/dxg, and CUDA blames the driver: the PowerShell core's live box
# saw exactly that from a spec that existed.
TB_K3S_GPU_WSL_SPEC_NEEDLES=(nvidia.com/gpu /dev/dxg libdxcore.so)

# _native_k3s_gpu_wsl_spec_lacks -- what the spec at TB_K3S_GPU_CDI_PATH lacks of
# TB_K3S_GPU_WSL_SPEC_NEEDLES, space-separated, or "a spec" when there is no non-empty
# one. Empty output: it is whole.
_native_k3s_gpu_wsl_spec_lacks() {
  local n lacks=""
  if ! tb_root test -s "$TB_K3S_GPU_CDI_PATH"; then printf 'a spec'; return 0; fi
  for n in "${TB_K3S_GPU_WSL_SPEC_NEEDLES[@]}"; do  # set-u-safe: TB_K3S_GPU_WSL_SPEC_NEEDLES is a literal list
    tb_root grep -qF -- "$n" "$TB_K3S_GPU_CDI_PATH" 2>/dev/null || lacks="${lacks:+${lacks} }${n}"
  done
  printf '%s' "$lacks"
}

# _native_k3s_gpu_wsl_prepare -- step b's NVIDIA half in tracebloc's WSL distro. The
# distro's image carries what this run could not install there: NVIDIA's container
# toolkit, pinned and set to CDI mode, and tracebloc-cdi (wsl-distro.sh). So nothing is
# installed and nothing generated here (a plain `nvidia-ctk cdi generate` knows nothing
# of WSL). It checks the outcome, and each miss is CPU mode, said by name:
#   - TB_WSL_DXG_PATH, the device the GPU reaches the distro by;
#   - an nvidia-ctk that answers, and its version floor (a warning, as on Linux);
#   - a whole spec. One that is not is asked for again, once, by restarting
#     TB_K3S_GPU_WSL_CDI_UNIT, then read again. It is the image's, never recorded.
# Past it the path is Linux's: k3s registers the NVIDIA runtime from the toolkit (step
# c's gate), and the chart's device plugin, under that runtime, finds WSL by /dev/dxg
# and advertises one shared device, `all` (W26, measured on v0.20.1 by spike S-W).
_native_k3s_gpu_wsl_prepare() {
  local lacks state
  if ! tb_root test -e "$TB_WSL_DXG_PATH"; then
    _native_k3s_gpu_cpu "WSL gives the tracebloc WSL distro no GPU device (${TB_WSL_DXG_PATH} is not there), so no container here can use the GPU" blind
    return 1
  fi
  if ! { has nvidia-ctk && _bounded "${TB_PROBE_TIMEOUT:-5}" nvidia-ctk --version >/dev/null 2>&1; }; then
    _native_k3s_gpu_cpu "the tracebloc WSL distro has no NVIDIA Container Toolkit that answers ('nvidia-ctk --version'), and this installer installs none there: its image carries it" blind
    return 1
  fi
  _native_k3s_gpu_toolkit_floor
  lacks="$(_native_k3s_gpu_wsl_spec_lacks)"
  if [[ -n "$lacks" ]]; then
    log "WSL GPU spec ${TB_K3S_GPU_CDI_PATH} lacks: ${lacks}; restarting ${TB_K3S_GPU_WSL_CDI_UNIT} once."
    _bounded_root "$TB_K3S_GPU_WSL_CDI_BOUND" systemctl restart "$TB_K3S_GPU_WSL_CDI_UNIT" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    lacks="$(_native_k3s_gpu_wsl_spec_lacks)"
  fi
  if [[ -n "$lacks" ]]; then
    state="$(_bounded_root "${TB_PROBE_TIMEOUT:-5}" systemctl is-active "$TB_K3S_GPU_WSL_CDI_UNIT" 2>/dev/null)" || true
    state="${state%%$'\n'*}"
    _native_k3s_gpu_cpu "the tracebloc WSL distro's GPU spec, ${TB_K3S_GPU_CDI_PATH}, lacks ${lacks}, and ${TB_K3S_GPU_WSL_CDI_UNIT}, which writes it, did not fix that (it is ${state:-in a state systemctl did not say}; 'systemctl status ${TB_K3S_GPU_WSL_CDI_UNIT%.service}' says why)" blind
    return 1
  fi
  log "WSL GPU spec ${TB_K3S_GPU_CDI_PATH} names the GPU, /dev/dxg and libdxcore; using it as it is."
  return 0
}

# _native_k3s_gpu_prepare -- step b's NVIDIA half on native k3s: the toolkit package
# (gpu-nvidia.sh's package half), its version floor, and a CDI spec. It
# touches no Docker and no host containerd, and leaves TRACEBLOC_GPU_WIRED at 0: step c's
# gate sets it. TB_K3S_GPU_PREPARED=1 tells that gate the toolkit and a spec are here.
# In tracebloc's WSL distro the image's toolkit and spec, checked
# (_native_k3s_gpu_wsl_prepare).
_native_k3s_gpu_prepare() {
  TB_K3S_GPU_PREPARED=""
  if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
    _native_k3s_gpu_wsl_prepare || return 0
    TB_K3S_GPU_PREPARED=1
    return 0
  fi
  _nvidia_container_toolkit_package
  _native_k3s_gpu_toolkit_floor
  _native_k3s_gpu_cdi_spec || return 0
  TB_K3S_GPU_PREPARED=1
}

# _native_k3s_cri_handlers -- the runtime handlers in `k3s crictl info`'s output on
# stdin, one name per line: the `name` of each entry of the top-level
# `runtimeHandlers` list, which is the CRI's own list of the handlers containerd
# registered (containerd 2.x's Status). crictl prints it with two-space json.Indent
# and sorted keys (cri-tools cmd/crictl/util.go, outputStatusData), so each entry's
# keys sit six spaces in. jq-free, like the rest of the installer. MEASURED at the
# pinned k3s (S-G): a GPU node printed that shape, with the default handler as an
# entry with no `name`; k3s-gpu.bats holds this parser to that output
# (crictl-info-measured-g4dn.12xlarge.json) and to the hand-built ones. 0 with the names
# (none, for an empty list); 1 when the input carries no runtimeHandlers list
# (cannot tell).
_native_k3s_cri_handlers() {
  awk '
    /^  "runtimeHandlers": \[\],?$/ { seen = 1; next }
    /^  "runtimeHandlers": \[$/     { seen = 1; inside = 1; next }
    inside && /^  [^ ]/             { inside = 0; next }
    inside && /^      "name": "[a-z0-9][-a-z0-9]*",?$/ {
      v = $0; sub(/^      "name": "/, "", v); sub(/",?$/, "", v); print v
    }
    END { exit(seen ? 0 : 1) }'
}

# _native_k3s_gpu_handler -- has k3s's own containerd registered TB_K3S_GPU_RUNTIME?
# The runtime's own answer, `k3s crictl info`, bounded by TB_K3S_CRI_TIMEOUT
# (seconds, default 15). Never the RuntimeClass list: k3s creates the `nvidia` class
# on a fresh node with no GPU and no toolkit, so a class is no
# evidence. 0 = registered, 1 = not registered, 2 = cannot tell (the read failed or
# timed out, or named no handler list), with the read in TB_K3S_GPU_READ.
_native_k3s_gpu_handler() {
  local out names rc=0
  TB_K3S_GPU_READ=""
  out="$(_bounded_root "${TB_K3S_CRI_TIMEOUT:-15}" "$TB_K3S_BIN_PATH" crictl info 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    TB_K3S_GPU_READ="'k3s crictl info' did not answer (exit ${rc})"
    return 2
  fi
  if ! names="$(_native_k3s_cri_handlers <<<"$out")"; then
    TB_K3S_GPU_READ="'k3s crictl info' listed no runtime handlers"
    return 2
  fi
  case $'\n'"$names"$'\n' in *$'\n'"${TB_K3S_GPU_RUNTIME}"$'\n'*) return 0 ;; esac
  return 1
}

# _native_k3s_gpu_wire NAME -- step c's GPU gate on native k3s, after node NAME is
# Ready. TRACEBLOC_GPU_WIRED becomes 1 here and nowhere else on k3s: only when step b put the
# toolkit and a CDI spec in place (TB_K3S_GPU_PREPARED) and k3s's own containerd has
# registered TB_K3S_GPU_RUNTIME. k3s registers it only when it finds the toolkit at
# start (docs.k3s.io: "restart it if already installed"), so a k3s that started
# without it -- a host installed CPU-only before this, or a toolkit installed after
# k3s -- is restarted ONCE and asked again; no recreate. The node half of
# D11: a re-run whose GPU stack signature equals the last wired pass's restarts
# nothing, and a changed signature restarts once. Every other outcome is CPU mode,
# with one warning that names why; it is never a guess at GPU. MEASURED (S-G): a fresh
# install registered the handler at k3s's first start (step b put the toolkit in
# first), a no-change re-run left k3s's start time alone, and each driver change
# (580 -> 570 -> 550 -> 535) restarted k3s exactly once. And the restart is needed:
# with the toolkit removed and k3s restarted, the CRI listed no nvidia handler; the
# re-run reinstalled the toolkit, k3s still listed none until this gate's one restart,
# and then it did.
_native_k3s_gpu_wire() {
  local name="$1" sig last="" rc=0 why=""
  [[ "${GPU_VENDOR:-}" == "nvidia" && -n "${TB_K3S_GPU_PREPARED:-}" ]] || return 0
  # --print (prepare-host): k3s never started, so there is no runtime to ask about.
  if tb_root_planning; then return 0; fi
  sig="$(_gpu_stack_signature)"
  if tb_root test -f "$TB_K3S_GPU_MARKER_PATH" 2>/dev/null; then
    last="$(tb_root cat "$TB_K3S_GPU_MARKER_PATH" 2>/dev/null)" || last=""
  fi
  _native_k3s_gpu_handler || rc=$?
  case "$rc" in
    0)
      if [[ -n "$last" && -n "$sig" && "$last" != "$sig" ]]; then
        why="the NVIDIA driver or toolkit changed since the last GPU run"
      fi
      ;;
    1)
      if ! has nvidia-container-runtime; then
        _native_k3s_gpu_cpu "the NVIDIA container runtime (nvidia-container-runtime) is not on PATH, so k3s cannot register it" blind
        return 0
      fi
      why="k3s has not registered its '${TB_K3S_GPU_RUNTIME}' runtime"
      ;;
    *)
      _native_k3s_gpu_cpu "$TB_K3S_GPU_READ"
      return 0
      ;;
  esac
  if [[ -n "$why" ]]; then
    log "native k3s: ${why}; restarting k3s once so it finds the NVIDIA runtime."
    tb_root systemctl restart k3s || error "k3s did not restart to pick up the NVIDIA runtime. 'sudo journalctl -u k3s' says why; it's safe to re-run this installer."
    # A second start of k3s, made on purpose: it gets the one wait budget again.
    TB_K3S_WAITED_S=0; TB_K3S_WAIT_T0="$(date +%s)"
    _native_k3s_wait_for_api
    _native_k3s_wait_for_node_ready "$name"
    rc=0
    _native_k3s_gpu_handler || rc=$?
    case "$rc" in
      0) ;;
      1) _native_k3s_gpu_cpu "k3s did not register its '${TB_K3S_GPU_RUNTIME}' runtime, even after a restart" blind; return 0 ;;
      *) _native_k3s_gpu_cpu "$TB_K3S_GPU_READ"; return 0 ;;
    esac
  fi
  # shellcheck disable=SC2034  # consumed cross-file by kube.sh (_gpu_wired)
  TRACEBLOC_GPU_WIRED=1
  if [[ -n "$sig" ]]; then
    _native_k3s_gpu_mark "$sig"
  else
    _native_k3s_gpu_unmark
  fi
  # Not "wired" yet: the runtime is registered, and the GPUs are counted after the
  # install, once the device plugin runs (_native_k3s_gpu_verify).
  success "k3s registered the NVIDIA runtime (${TB_K3S_GPU_RUNTIME}); the GPUs are counted after the install."
}

# _native_k3s_gpu_verify -- after Helm (install-k8s.sh step e, through verify_gpu):
# the GPU is wired only when the node advertises at least one nvidia.com/gpu. Step
# c's gate proves k3s runs the NVIDIA runtime, not that the GPUs are healthy.
# MEASURED (S-G): driver 535 on T4s, handler registered, and 0 GPUs allocatable,
# because the GPUs failed when the device plugin re-initialised them (Xid 140, then
# "RmInitAdapter failed"); persistence mode from boot cured it, and 550 and newer
# never needed it. So a count of 0 after the plugin's rollout and the poll is a
# warning that names that remedy, and an unreadable count is a warning too: neither
# is ever "wired". TB_K3S_GPU_UNCONFIRMED tells the summary.
_native_k3s_gpu_verify() {
  local tries=0 n="" rc=0 ns="${GPU_DEVICE_PLUGIN_NAMESPACE:-kube-system}"
  log "Counting the GPUs the node advertises..."
  # The plugin rolls out with the release, and `helm upgrade --install` does not
  # wait: give it the same bounded chance verify_gpu does, then poll.
  kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n "$ns" --timeout=120s >/dev/null 2>&1 || true
  while [[ "$tries" -lt 18 ]]; do
    tries=$((tries + 1))
    # The one count reader, shared with verify_gpu's own poll (gpu-plugins.sh
    # _gpu_alloc_count): a node without the key counts 0, and a read
    # that fails, lists no node or is not a number is "cannot tell", never a count.
    rc=0; n="$(_gpu_alloc_count nvidia)" || rc=$?
    if [[ "$rc" -eq 0 && "$n" -gt 0 ]]; then
      TB_K3S_GPU_UNCONFIRMED=""
      success "NVIDIA GPU wired into k3s: ${n} GPU(s) allocatable (runtime ${TB_K3S_GPU_RUNTIME})."
      return 0
    fi
    sleep 5
  done
  # shellcheck disable=SC2034  # consumed cross-file by summary.sh (print_summary)
  TB_K3S_GPU_UNCONFIRMED=1
  if [[ "$rc" -ne 0 ]]; then
    warn "Couldn't read how many GPUs the node advertises ('kubectl get nodes' did not answer), so the NVIDIA GPU is not confirmed."
    hint "Check with: $(tb_kubectl_shown) get nodes -o jsonpath='{..allocatable.nvidia\\.com/gpu}'"
    return 0
  fi
  warn "k3s runs the NVIDIA runtime, but the node advertises no GPU (allocatable nvidia.com/gpu = 0), so GPU trainings will wait."
  # An adopted user has no sudo for dmesg or a reboot: the remedy is the administrator's.
  if [[ "${TB_K3S_ADOPTED:-}" == 1 ]]; then
    hint "Ask the administrator to check 'sudo dmesg | grep -iE \"xid|RmInitAdapter\"': on Xid 140 or 'RmInitAdapter failed', persistence mode from boot (nvidia-persistenced, or 'nvidia-smi -pm 1' before k3s starts), a reboot and a re-run of prepare-host bring the GPUs up. Drivers 550 and newer did not need it."
    return 0
  fi
  if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
    hint "In the tracebloc WSL distro the device plugin finds the GPU through ${TB_WSL_DXG_PATH}: '$(tb_kubectl_shown) -n ${ns} logs daemonset/nvidia-device-plugin-daemonset' says what it found. Then re-run the installer from Windows."
    return 0
  fi
  hint "If 'sudo dmesg | grep -iE \"xid|RmInitAdapter\"' shows Xid 140 or 'RmInitAdapter failed', the GPUs failed when they re-initialised: turn persistence mode on from boot (nvidia-persistenced, or 'nvidia-smi -pm 1' before k3s starts), reboot, then re-run this installer. Drivers 550 and newer did not need it."
}
