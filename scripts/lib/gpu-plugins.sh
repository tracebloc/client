#!/usr/bin/env bash
# =============================================================================
#  gpu-plugins.sh — k8s GPU device plugin deployment + node verification
# =============================================================================

readonly NVIDIA_DEVICE_PLUGIN_VERSION="v0.14.5"
readonly NVIDIA_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
# Pin to release tag when available; fallback to master in _deploy_amd_plugin if URL fails
readonly AMD_DEVICE_PLUGIN_VERSION="v1.0.0"
readonly AMD_DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/${AMD_DEVICE_PLUGIN_VERSION}/k8s-ds-amdgpu-dp.yaml"

deploy_gpu_device_plugin() {
  case "$GPU_VENDOR" in
    nvidia) _deploy_nvidia_plugin ;;
    amd)    _deploy_amd_plugin ;;
    *)      log "No GPU device plugin needed." ;;
  esac
}

# Download manifest to temp file and apply (avoids apply -f remote URL; enables future checksum verification)
_apply_remote_manifest() {
  local url="$1" label="$2"
  local tmp_yml
  tmp_yml="$(mktemp)"
  trap "rm -f '$tmp_yml'" RETURN
  retry 3 5 curl_secure -fsSL "$url" -o "$tmp_yml" || { rm -f "$tmp_yml"; return 1; }
  [[ -s "$tmp_yml" ]] || { warn "Downloaded $label manifest is empty"; rm -f "$tmp_yml"; return 1; }
  # Raw stderr to the log; the caller surfaces a curated line on failure (#577).
  # --request-timeout bounds the API call so a wedged API server fails into that
  # curated warn instead of hanging silently behind the log redirect (Bugbot);
  # mirrors the node-probe's --request-timeout below.
  kubectl apply -f "$tmp_yml" --request-timeout=30s >> "${LOG_FILE:-/dev/null}" 2>&1
}

# Wait for a just-applied device-plugin daemonset to become Ready and gate the
# success message on it: success + return 0 when it rolls out, else warn + continue
# in CPU mode + return 1. Shared by the nvidia and amd paths (including the amd
# master fallback) so "no false enabled, no dead ~90s verify wait" behaves
# identically everywhere (reviewer). Output goes to the log; the caller surfaces
# only the curated line.
_gpu_rollout_gate() {
  local ds="$1"
  if kubectl rollout status "daemonset/$ds" -n kube-system --timeout=120s \
       >> "${LOG_FILE:-/dev/null}" 2>&1; then
    success "GPU acceleration enabled."
    return 0
  fi
  warn "Couldn't confirm GPU acceleration is ready — continuing in CPU mode. Re-run the installer later to retry."
  return 1
}

_deploy_nvidia_plugin() {
  log "Deploying NVIDIA k8s device plugin"
  # --request-timeout bounds the existence probe so a wedged API server can't hang
  # here before the bounded apply is reached (reviewer; parity with verify_gpu).
  if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset --request-timeout=5s &>/dev/null 2>&1; then
    success "GPU acceleration enabled."
    return 0
  fi

  log "Downloading and applying NVIDIA device plugin DaemonSet..."
  # GPU is OPTIONAL: a plugin download/apply failure must NOT abort the install
  # (#577 fatal-vs-recoverable). Warn and continue in CPU mode — same spirit as the
  # NVIDIA-container-toolkit timeout, which already warns and carries on. Return
  # non-zero on every CPU-mode path so the caller skips the GPU verify wait for a
  # plugin that was never deployed (Bugbot).
  if ! _apply_remote_manifest "$NVIDIA_DEVICE_PLUGIN_URL" "NVIDIA device plugin"; then
    warn "Couldn't enable GPU acceleration — continuing in CPU mode. Re-run the installer later to retry."
    return 1
  fi
  _gpu_rollout_gate nvidia-device-plugin-daemonset
}

_deploy_amd_plugin() {
  log "Deploying AMD GPU k8s device plugin"
  # --request-timeout bounds the existence probe (reviewer; parity with verify_gpu).
  if kubectl get daemonset -n kube-system amdgpu-device-plugin --request-timeout=5s &>/dev/null 2>&1; then
    success "GPU acceleration enabled."
    return 0
  fi

  # Return non-zero on every CPU-mode path so the caller skips the GPU verify wait
  # for a plugin that was never deployed (Bugbot).
  log "Downloading and applying AMD GPU device plugin DaemonSet..."
  if _apply_remote_manifest "$AMD_DEVICE_PLUGIN_URL" "AMD device plugin"; then
    _gpu_rollout_gate amdgpu-device-plugin
    return $?
  fi
  log "Pinned AMD plugin ${AMD_DEVICE_PLUGIN_VERSION} failed; trying master..."
  # Master fallback: gate on rollout too (reviewer) — a master apply that never
  # rolls out must warn + continue in CPU mode, not return success and make the
  # caller's verify poll ~90s before a vaguer "still initializing".
  if _apply_remote_manifest "https://raw.githubusercontent.com/RadeonOpenCompute/k8s-device-plugin/master/k8s-ds-amdgpu-dp.yaml" "AMD device plugin (master)"; then
    _gpu_rollout_gate amdgpu-device-plugin
    return $?
  fi
  warn "GPU acceleration setup may need manual attention — continuing in CPU mode."
  return 1
}

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
