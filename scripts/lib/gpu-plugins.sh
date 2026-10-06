#!/usr/bin/env bash
# =============================================================================
#  gpu-plugins.sh — node-level GPU verification
# =============================================================================
# The GPU device plugin is no longer applied imperatively here (client#564).
# It is now a Helm-managed DaemonSet rendered by the chart
# (client/templates/gpu-device-plugin.yaml), gated on gpu.devicePlugin.enabled,
# which lib/install-client-helm.sh sets from GPU_VENDOR. Moving it into the
# release means it is reconciled on upgrade and removed on `helm uninstall`,
# and the manifest is baked into the chart instead of downloaded from
# raw.githubusercontent.com at install time.
#
# What remains here is the node-level verification, which now runs AFTER the
# Helm install (install-k8s.sh step e) since the plugin rolls out with the
# release rather than before it.

# ── Node-level GPU verification ─────────────────────────────────────────────
verify_gpu() {
  [[ "$GPU_VENDOR" != "nvidia" && "$GPU_VENDOR" != "amd" ]] && return

  # nvidia CPU-fallback (client#835): a reused CPU-only cluster or a failed node
  # CDI-gen leaves GPU_VENDOR=nvidia but no GPU wired in. There is then nothing for
  # the 18×5s node poll below to find, and running it would just stall the finish
  # with a misleading "could not read / advertises no GPU" warning. Skip it when we know the GPU
  # wasn't wired. Guarded with `declare -F` so gpu-plugins.sh can still be sourced
  # standalone (its bats suite does) without common.sh's _gpu_wired. amd has no
  # wiring flag, so it keeps verifying on detection as before.
  if [[ "$GPU_VENDOR" == "nvidia" ]] && declare -F _gpu_wired >/dev/null 2>&1 && ! _gpu_wired; then
    log "NVIDIA GPU detected but not wired into the cluster — skipping node GPU verification (CPU mode)."
    return
  fi

  # Native k3s counts the GPUs through the same reader (_gpu_alloc_count, below), and
  # says what a count of 0 means there: k3s.sh _native_k3s_gpu_verify (1.1i) names the
  # remedy S-G measured and marks the summary "not confirmed".
  if [[ "$GPU_VENDOR" == "nvidia" && "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    _native_k3s_gpu_verify
    return
  fi

  log "Verifying GPU on node..."

  # The device plugin now rolls out with the Helm release, and `helm upgrade
  # --install` does not --wait, so give the DaemonSet a bounded chance to become
  # Ready before polling node GPU capacity. Without this the node poll can expire
  # while the plugin is still pulling and report "advertises no GPU" on a
  # healthy install (client#564 / Bugbot). Best-effort: a namespace override or a
  # genuinely stuck rollout falls through to the node poll below, which is the
  # real check.
  local _gpu_ns="${GPU_DEVICE_PLUGIN_NAMESPACE:-kube-system}"
  local _gpu_ds=""
  [[ "$GPU_VENDOR" == "nvidia" ]] && _gpu_ds="nvidia-device-plugin-daemonset"
  [[ "$GPU_VENDOR" == "amd" ]] && _gpu_ds="amdgpu-device-plugin-daemonset"
  if [[ -n "$_gpu_ds" ]]; then
    # --timeout is the explicit bound for the whole wait; do NOT add
    # --request-timeout — on a watch it caps the underlying request and would
    # cut this wait to a few seconds, defeating the 120s (client#564 / Bugbot).
    kubectl rollout status "daemonset/$_gpu_ds" -n "$_gpu_ns" \
      --timeout=120s >/dev/null 2>&1 || true
  fi

  # The node poll reads the advertised COUNT, never the mere presence of a
  # `…gpu…` key (client-dev#1555): a device plugin that registered but found no
  # usable device advertises `nvidia.com/gpu: "0"`, and a presence test read that
  # as "GPU verified" while every GPU pod stayed Pending. Only a count above 0 is
  # success; a 0 (or no key) and an unreadable count each say what they are. The
  # last poll's answer decides the message.
  local _gpu_res="${GPU_VENDOR}.com/gpu" _gpu_count="" _gpu_read=0
  for i in {1..18}; do
    if _gpu_count=$(_gpu_alloc_count "$GPU_VENDOR"); then
      _gpu_read=1
      if [[ "$_gpu_count" -gt 0 ]]; then
        success "GPU verified and available: the node advertises ${_gpu_count} ${_gpu_res}."
        return
      fi
    else
      _gpu_read=0
    fi
    sleep 5
  done
  if [[ "$_gpu_read" -eq 1 ]]; then
    warn "The node advertises no GPU (${_gpu_res}: ${_gpu_count}) — GPU jobs will wait until it does."
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
      hint "Enable persistence mode from boot (nvidia-persistenced, or 'sudo nvidia-smi -pm 1' before the cluster starts), reboot, and re-run the installer — or upgrade to NVIDIA driver 550 or later."
    else
      hint "Check that the AMD GPU device plugin found the GPU, then re-run the installer."
    fi
  else
    warn "Could not read the node's GPU count (${_gpu_res}) — the GPU is not verified."
  fi
}

# _gpu_alloc_count VENDOR — print the allocatable GPU count summed over the
# nodes, as a whole number (client-dev#1555). A node without the vendor key
# counts 0. Returns 1 — "cannot tell", never a count — when the read failed, no
# node came back, or a node's value is not a whole number. jsonpath keeps the
# output to one short line per node, so nothing is piped through a slicer that
# could truncate it (the backend#1778 SIGPIPE trap). --request-timeout bounds the
# call: the 18×5s cap is only re-checked between polls.
_gpu_alloc_count() {
  local _key _out _line _val _total=0 _nodes=0
  case "$1" in
    nvidia) _key='nvidia\.com/gpu' ;;
    amd) _key='amd\.com/gpu' ;;
    *) return 1 ;;
  esac
  _out=$(kubectl get nodes --request-timeout=5s \
    -o "jsonpath={range .items[*]}{.metadata.name}={.status.allocatable.${_key}}{\"\n\"}{end}" 2>/dev/null) || return 1
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    _nodes=$((_nodes + 1))
    _val="${_line#*=}"
    [[ -n "$_val" ]] || continue
    [[ "$_val" =~ ^[0-9]+$ ]] || return 1
    _total=$((_total + 10#$_val))
  done <<<"$_out"
  [[ "$_nodes" -gt 0 ]] || return 1
  echo "$_total"
}
