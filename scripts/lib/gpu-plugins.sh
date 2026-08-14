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

  log "Verifying GPU on node..."

  # The device plugin now rolls out with the Helm release, and `helm upgrade
  # --install` does not --wait, so give the DaemonSet a bounded chance to become
  # Ready before polling node GPU capacity. Without this the node poll can expire
  # while the plugin is still pulling and report "may still be initializing" on a
  # healthy install (client#564 / Bugbot). Best-effort: a namespace override or a
  # genuinely stuck rollout falls through to the node poll below, which is the
  # real check.
  local _gpu_ns="${GPU_DEVICE_PLUGIN_NAMESPACE:-kube-system}"
  local _gpu_ds=""
  [[ "$GPU_VENDOR" == "nvidia" ]] && _gpu_ds="nvidia-device-plugin-daemonset"
  [[ "$GPU_VENDOR" == "amd" ]] && _gpu_ds="amdgpu-device-plugin-daemonset"
  if [[ -n "$_gpu_ds" ]]; then
    kubectl rollout status "daemonset/$_gpu_ds" -n "$_gpu_ns" \
      --timeout=120s --request-timeout=10s >/dev/null 2>&1 || true
  fi

  for i in {1..18}; do
    # --request-timeout bounds the call: the 18×5s cap is only re-checked between
    # iterations, so an unbounded get-nodes against a wedged API would hang here.
    RAW=$(kubectl get nodes -o json --request-timeout=5s 2>/dev/null \
      | grep -o '"[^"]*gpu[^"]*"\s*:\s*"[^"]*"' \
      | sed 's/"//g; s/\s*:\s*/=/g' | head -5 \
      2>/dev/null || echo "")
    if [[ -n "$RAW" ]]; then
      success "GPU verified and available."
      log "GPU resource on node: $RAW"
      return
    fi
    sleep 5
  done
  warn "GPU may still be initializing. Check back shortly."
}
