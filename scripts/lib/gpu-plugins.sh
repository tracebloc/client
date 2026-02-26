#!/usr/bin/env bash
# =============================================================================
#  gpu-plugins.sh — k8s GPU device plugin deployment + node verification
# =============================================================================

readonly NVIDIA_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"
readonly AMD_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml"

deploy_gpu_device_plugin() {
  case "$GPU_VENDOR" in
    nvidia) _deploy_nvidia_plugin ;;
    amd)    _deploy_amd_plugin ;;
    *)      info "No GPU device plugin needed." ;;
  esac
}

_deploy_nvidia_plugin() {
  step "Deploying NVIDIA k8s Device Plugin"
  if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null 2>&1; then
    success "NVIDIA device plugin already present."
    return
  fi

  info "Applying NVIDIA device plugin DaemonSet..."
  kubectl apply -f "$NVIDIA_DEVICE_PLUGIN_URL"
  kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
    -n kube-system --timeout=120s \
    || warn "Rollout timed out — plugin may still be pulling. Check: kubectl get pods -n kube-system"
  success "NVIDIA device plugin deployed."
}

_deploy_amd_plugin() {
  step "Deploying AMD GPU k8s Device Plugin"
  if kubectl get daemonset -n kube-system amdgpu-device-plugin &>/dev/null 2>&1; then
    success "AMD device plugin already present."
    return
  fi

  info "Applying AMD GPU device plugin DaemonSet..."
  kubectl apply -f "$AMD_DEVICE_PLUGIN_URL"
  sleep 5
  success "AMD device plugin deployed."
}

# ── Node-level GPU verification ─────────────────────────────────────────────
verify_gpu() {
  [[ "$GPU_VENDOR" != "nvidia" && "$GPU_VENDOR" != "amd" ]] && return

  step "Verifying GPU on Node"
  info "Waiting up to 90s for GPU to appear as allocatable resource..."

  for i in {1..18}; do
    RAW=$(kubectl get nodes -o json 2>/dev/null \
      | grep -o '"[^"]*gpu[^"]*"\s*:\s*"[^"]*"' \
      | sed 's/"//g; s/\s*:\s*/=/g' | head -5 \
      2>/dev/null || echo "")
    if [[ -n "$RAW" ]]; then
      success "GPU visible on node: $RAW"
      return
    fi
    sleep 5; printf "."
  done
  echo ""
  warn "GPU resource not yet visible. The device plugin may still be initialising."
  warn "Re-check with: kubectl describe node | grep -A5 Allocatable"
}
