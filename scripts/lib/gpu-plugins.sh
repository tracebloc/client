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
