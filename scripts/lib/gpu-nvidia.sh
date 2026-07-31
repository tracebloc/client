#!/usr/bin/env bash
# =============================================================================
#  gpu-nvidia.sh — NVIDIA driver installation + Container Toolkit (Linux)
# =============================================================================

# ── Drivers ──────────────────────────────────────────────────────────────────
install_nvidia_drivers() {
  if $NVIDIA_DRIVER_OK; then
    success "NVIDIA drivers loaded."
    return
  fi

  log "Installing NVIDIA drivers..."
  warn "NVIDIA GPU detected but drivers are missing — installing now..."

  $PM_UPDATE
  if has apt-get; then
    $PM_INSTALL ubuntu-drivers-common 2>/dev/null || true
    if has ubuntu-drivers; then
      sudo ubuntu-drivers install --gpgpu 2>/dev/null || sudo ubuntu-drivers autoinstall
    else
      LATEST_PKG=$(apt-cache search "^nvidia-driver-[0-9]" 2>/dev/null \
        | awk '{print $1}' | sort -t- -k3 -n | tail -1)
      [[ -n "$LATEST_PKG" ]] && $PM_INSTALL "$LATEST_PKG" || $PM_INSTALL nvidia-driver-535
    fi
  elif has dnf; then
    sudo dnf install -y epel-release 2>/dev/null || true
    # Detect RHEL/CentOS major and arch for correct NVIDIA repo (rhel8/rhel9, x86_64/aarch64)
    local rhel_major rhel_arch
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      rhel_major="${VERSION_ID%%.*}"
      rhel_major="${rhel_major:-9}"
    else
      rhel_major="9"
    fi
    case "$(uname -m)" in
      x86_64)  rhel_arch="x86_64" ;;
      aarch64|arm64) rhel_arch="sbsa" ;;
      *)       rhel_arch="x86_64" ;;
    esac
    sudo dnf config-manager --add-repo \
      "https://developer.download.nvidia.com/compute/cuda/repos/rhel${rhel_major}/${rhel_arch}/cuda-rhel${rhel_major}.repo" 2>/dev/null || true
    sudo dnf module install -y nvidia-driver:latest-dkms 2>/dev/null || \
      sudo dnf install -y akmod-nvidia || true
  elif has pacman; then
    $PM_INSTALL nvidia nvidia-utils
  fi

  warn "GPU drivers installed — a reboot is likely required."
  hint "After rebooting, re-run the installer. Driver steps will be skipped."
  if [[ -n "${TRACEBLOC_SKIP_REBOOT_PROMPT:-}" ]]; then
    log "TRACEBLOC_SKIP_REBOOT_PROMPT set — skipping reboot prompt."
    exit 2
  fi
  # Read the terminal directly: the main install path is `curl … | bash`, where
  # this shell's stdin is the (EOF) install pipe — a bare `read` there returns
  # non-zero and, with `set -e` active in this code path, would ABORT the whole
  # installer right after a successful driver install. No tty (unattended) => treat
  # as "no reboot" (same as TRACEBLOC_SKIP_REBOOT_PROMPT).
  local _choice=""
  if [[ -r /dev/tty ]]; then read -r -p "  Reboot now? [y/N]: " _choice </dev/tty || _choice=""; fi
  [[ "$_choice" =~ ^[Yy]$ ]] && sudo reboot
  warn "Skipping reboot. GPU may not be available until you restart."
}

# ── Container Toolkit ────────────────────────────────────────────────────────
# Does the RUNNING Docker daemon already default to the NVIDIA runtime? Authoritative
# live check (reflects the daemon, not just daemon.json), so a re-run can skip the
# reconfigure + restart that would otherwise bounce a live cluster (#431).
_docker_default_runtime_is_nvidia() {
  has docker || return 1
  # BOUNDED (#431 Bugbot): a wedged Docker daemon must not hang a headless re-run at
  # this skip gate. _bounded runs under timeout(1)/gtimeout(1) when available.
  local rt
  rt="$(_bounded "${TB_PROBE_TIMEOUT:-5}" docker info --format '{{.DefaultRuntime}}' 2>/dev/null || true)"
  [[ "$rt" == "nvidia" ]]
}

# Is our k3d cluster currently running (>=1 server up)? jq-free (jq is optional here);
# parses the SERVERS "running/total" column, mirroring _cluster_exists' awk approach.
# Bounded too, so a wedged daemon can't hang the probe (#431 Bugbot).
_k3d_cluster_running() {
  has k3d || return 1
  # Decide only in END: an `exit` inside a main rule still runs END, so a per-row
  # `exit 0` would be overridden by an END `exit 1`. Set a flag, exit once.
  _bounded "${TB_PROBE_TIMEOUT:-5}" k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '
    $1 == n { split($2, s, "/"); running = (s[1] + 0 > 0) } END { exit(running ? 0 : 1) }'
}

# Signature of the installed GPU stack (toolkit + driver versions). Empty when it
# can't be determined -> the caller then never caches, so it always re-verifies.
_gpu_stack_signature() {
  local ctk drv
  ctk="$(nvidia-ctk --version 2>/dev/null | head -1 || true)"
  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
  [[ -n "${ctk}${drv}" ]] && printf '%s|%s' "$ctk" "$drv"
}

install_nvidia_container_toolkit() {
  log "Setting up NVIDIA container toolkit"

  if has nvidia-ctk && nvidia-ctk --version &>/dev/null 2>&1; then
    log "NVIDIA Container Toolkit already installed."
  else
    log "Installing nvidia-container-toolkit..."

    if has apt-get; then
      local nvidia_gpg_tmp
      nvidia_gpg_tmp="$(mktemp)"
      curl_secure -fsSL --max-time 30 https://nvidia.github.io/libnvidia-container/gpgkey \
        -o "$nvidia_gpg_tmp"
      local nvidia_fp
      nvidia_fp=$(gpg --with-colons --import-options show-only --import "$nvidia_gpg_tmp" 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}')
      if [[ -n "$nvidia_fp" ]]; then
        log "NVIDIA GPG key fingerprint: $nvidia_fp"
      else
        log "Could not extract GPG key fingerprint — verify manually after install."
      fi
      sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$nvidia_gpg_tmp"
      rm -f "$nvidia_gpg_tmp"
      # --max-time 30 on all three fetches above/below: each is a few KB of key or
      # repo metadata, so a longer wait only means a hung mirror. They pipe into
      # sed/tee, so they can't be retry-wrapped — retry() reports attempts on
      # stdout, which here IS the file content being written.
      curl_secure -fsSL --max-time 30 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      sudo apt-get update -qq
      $PM_INSTALL nvidia-container-toolkit

    elif has dnf || has yum; then
      curl_secure -fsSL --max-time 30 https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
      has dnf && sudo dnf install -y nvidia-container-toolkit || sudo yum install -y nvidia-container-toolkit

    elif has pacman; then
      if   has yay;  then yay  -S --noconfirm nvidia-container-toolkit
      elif has paru; then paru -S --noconfirm nvidia-container-toolkit
      else warn "AUR helper not found — install nvidia-container-toolkit from AUR manually."; fi
    fi
    log "NVIDIA Container Toolkit installed."
  fi

  log "Setting NVIDIA as the default Docker runtime..."
  # Skip-when-satisfied (#431): restarting Docker takes a live k3d cluster down, so
  # only reconfigure + restart when Docker isn't ALREADY defaulting to the NVIDIA
  # runtime. A re-run on a configured host does nothing here — no restart, no bounce.
  local reconfigured=0
  if _docker_default_runtime_is_nvidia; then
    log "Docker already defaults to the NVIDIA runtime — skipping reconfigure + restart (no cluster bounce)."
  else
    reconfigured=1
    sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
    local cluster_was_running=0
    if _k3d_cluster_running; then
      cluster_was_running=1
      warn "Applying the NVIDIA runtime needs a Docker restart — the '${CLUSTER_NAME}' cluster will restart with it."
    fi
    sudo systemctl restart docker
    sleep 3
    # Bring the cluster back deterministically rather than relying only on the nodes'
    # restart policy, so a re-run that DID change the runtime doesn't leave it down.
    # Surface a bring-up failure (don't `|| true` it away) so the operator isn't told
    # the cluster is back when it isn't (#431 Bugbot).
    if (( cluster_was_running )) && has k3d; then
      log "Restarting the '${CLUSTER_NAME}' cluster after the Docker restart..."
      local start_out
      if ! start_out="$(k3d cluster start "$CLUSTER_NAME" 2>&1)"; then
        warn "Couldn't restart the '${CLUSTER_NAME}' cluster automatically: ${start_out}"
        hint "Start it manually:  k3d cluster start ${CLUSTER_NAME}"
      fi
    fi
  fi

  log "Configuring containerd NVIDIA runtime..."
  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>/dev/null || true

  # Cache the smoke test (#431): re-pulling nvidia/cuda on every re-run is wasteful,
  # and a pass won't change while the toolkit + driver are unchanged. The marker
  # records the signature of the last PASSING test. BUT if we actually reconfigured
  # the runtime + restarted Docker this run, the cache is stale — re-verify the GPU
  # path always, so a broken post-restart runtime can't be reported as verified
  # (#431 Bugbot).
  local gpu_marker="${HOST_DATA_DIR:-$HOME/.tracebloc}/.gpu-smoke-ok"
  local gpu_sig
  gpu_sig="$(_gpu_stack_signature)"
  if (( ! reconfigured )) && [[ -n "$gpu_sig" && -f "$gpu_marker" && "$(cat "$gpu_marker" 2>/dev/null)" == "$gpu_sig" ]]; then
    log "Docker GPU smoke-test skipped — toolkit + driver unchanged since last pass."
  elif docker run --rm --gpus all nvidia/cuda:12.3.1-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    log "Docker GPU smoke-test passed"
    mkdir -p "$(dirname "$gpu_marker")" 2>/dev/null || true
    [[ -n "$gpu_sig" ]] && printf '%s' "$gpu_sig" > "$gpu_marker" 2>/dev/null || true
  else
    log "Docker GPU smoke-test skipped (image may need pulling). Continuing..."
  fi

  K3D_GPU_FLAGS=("--gpus=all")
}
