#!/usr/bin/env bash
# =============================================================================
#  gpu-nvidia.sh — NVIDIA driver installation + Container Toolkit (Linux)
# =============================================================================

# ── Drivers ──────────────────────────────────────────────────────────────────
# _nvidia_driver_pkg_pick FLOOR_MAJOR SEARCH — from `apt-cache search` output, the
# newest nvidia-driver-<N>[-flavour] package whose series N is at or above the
# floor's major, or nothing. Pass 0 as FLOOR_MAJOR for the newest of any series.
_nvidia_driver_pkg_pick() {
  local picked
  picked="$(printf '%s\n' "$2" | awk -v floor="$1" '
    $1 ~ /^nvidia-driver-[0-9]+(-[a-z]+)*$/ {
      n = $1; sub(/^nvidia-driver-/, "", n); sub(/-.*/, "", n)
      if (n + 0 >= floor + 0) print $1
    }' | sort -t- -k3 -n)" || picked=""
  printf '%s' "${picked##*$'\n'}"
}

# _nvidia_driver_not_installed REASON -- the driver step put no driver in: say so, name
# the manual route. install_nvidia_drivers then returns 1, so dispatch_gpu_setup skips
# the toolkit and there is no reboot flow: the install goes on CPU-only
# (client-dev#1699). A "drivers installed, reboot" over nothing installed only led to
# a reboot, still no driver, and the same again on the next run.
_nvidia_driver_not_installed() {
  local _rerun="this installer"
  [[ -n "${TB_PREPARE_HOST_RUN:-}" ]] && _rerun="prepare-host"
  warn "The NVIDIA driver was NOT installed: ${1}. This install continues in CPU mode."
  hint "To use the GPU, install the NVIDIA driver for your distribution yourself, then re-run ${_rerun}."
}

# install_nvidia_drivers -- returns 0 when the driver is loaded or went in (then the
# reboot flow), 1 when it did not (_nvidia_driver_not_installed). Its caller runs it as
# an `if` condition, where `set -e` is off, so every install below is checked by hand.
install_nvidia_drivers() {
  if $NVIDIA_DRIVER_OK; then
    success "NVIDIA drivers loaded."
    return
  fi

  log "Installing NVIDIA drivers..."
  warn "NVIDIA GPU detected but drivers are missing — installing now..."

  # The floor's series (facts.env NVIDIA_DRIVER_FLOOR_LINUX). The package is the
  # newest the archive lists at or above it; when it lists none, the newest it
  # does list, said: naming a series the archive does not carry would abort the
  # install. A driver installed here below the hard floor is judged on the next
  # run, which leaves the GPU off (_nvidia_gpu_floor_gate). Only an empty listing
  # falls back to the floor's series by name. ubuntu-drivers is asked for the
  # chosen series.
  # if/else, never `a && b || c`: a FAILED install of the package found must
  # fail here, not quietly fall through to another driver.
  local floor_series="${TB_NVIDIA_DRIVER_FLOOR%%.*}" search pkg series failed=""
  # Only apt-get, dnf and pacman have a driver install here. yum and zypper hosts
  # (setup-linux.sh knows both) are told so, never told a driver went in.
  if ! has apt-get && ! has dnf && ! has pacman; then
    local pm="this machine's package manager"
    if has zypper; then pm="zypper"; elif has yum; then pm="yum"; fi
    _nvidia_driver_not_installed "the installer has no automatic NVIDIA driver install for ${pm}"
    return 1
  fi
  if ! $PM_UPDATE; then
    _nvidia_driver_not_installed "the package index refresh failed"
    return 1
  fi
  if has apt-get; then
    $PM_INSTALL ubuntu-drivers-common 2>/dev/null || true
    search="$(apt-cache search "^nvidia-driver-[0-9]" 2>/dev/null || true)"
    pkg="$(_nvidia_driver_pkg_pick "$floor_series" "$search")"
    if [[ -z "$pkg" ]]; then
      pkg="$(_nvidia_driver_pkg_pick 0 "$search")"
      if [[ -n "$pkg" ]]; then
        warn "No NVIDIA driver ${floor_series} or newer is available from this machine's package sources — installing ${pkg}, older than the driver tracebloc's GPU training images need (CUDA 13), so GPU training will not work on it: update it to ${floor_series} or newer when one is available, then re-run the installer."
      fi
    fi
    series="${pkg#nvidia-driver-}"; series="${series%%-*}"; series="${series:-$floor_series}"
    if has ubuntu-drivers; then
      if ! tb_root ubuntu-drivers install --gpgpu "nvidia:${series}-server" 2>/dev/null; then
        tb_root ubuntu-drivers install "nvidia:${series}"
      fi
    elif [[ -n "$pkg" ]]; then
      $PM_INSTALL "$pkg"
    else
      $PM_INSTALL "nvidia-driver-${floor_series}"
    fi || failed="the NVIDIA driver package did not install"
  elif has dnf; then
    tb_root dnf install -y epel-release 2>/dev/null || true
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
    tb_root dnf config-manager --add-repo \
      "https://developer.download.nvidia.com/compute/cuda/repos/rhel${rhel_major}/${rhel_arch}/cuda-rhel${rhel_major}.repo" 2>/dev/null || true
    # The akmod package is the fallback; when both fail, that is a failed install.
    tb_root dnf module install -y nvidia-driver:latest-dkms 2>/dev/null || \
      tb_root dnf install -y akmod-nvidia || \
      failed="neither 'dnf module install nvidia-driver:latest-dkms' nor 'dnf install akmod-nvidia' succeeded"
  elif has pacman; then
    $PM_INSTALL nvidia nvidia-utils || failed="'pacman -S nvidia nvidia-utils' failed"
  fi
  if [[ -n "$failed" ]]; then
    _nvidia_driver_not_installed "$failed"
    return 1
  fi

  # --print installed nothing, so there is nothing to reboot for.
  if tb_root_planning; then return 0; fi
  local _rerun="the installer"
  [[ -n "${TB_PREPARE_HOST_RUN:-}" ]] && _rerun="prepare-host"
  warn "GPU drivers installed — a reboot is likely required."
  hint "After rebooting, re-run ${_rerun}. Driver steps will be skipped."
  if [[ -n "${TRACEBLOC_SKIP_REBOOT_PROMPT:-}" ]]; then
    log "TRACEBLOC_SKIP_REBOOT_PROMPT set — skipping reboot prompt."
    # DECLARE THE HANDOFF, then exit. This is the installer's "complete this step
    # and re-run" stop — the drivers went in fine and the machine needs a reboot —
    # and telemetry keys `install.run.cancelled` on this marker rather than on the
    # number 2, because grep/curl/tar all exit 2 too and one of those escaping
    # under `set -e` must be counted as the failure it is. Without this line the
    # run books itself as `unexpected_exit_2`, which is the safe direction to be
    # wrong in but still wrong. Guarded for a stale bootstrap that did not fetch
    # telemetry.sh (same shape as install_cleanup's emit call).
    if declare -F telemetry_rerun_handoff >/dev/null 2>&1; then telemetry_rerun_handoff; fi
    exit 2
  fi
  # Read the terminal directly: the main install path is `curl … | bash`, where
  # this shell's stdin is the (EOF) install pipe — a bare `read` there returns
  # non-zero and, with `set -e` active in this code path, would ABORT the whole
  # installer right after a successful driver install. No tty (unattended) => treat
  # as "no reboot" (same as TRACEBLOC_SKIP_REBOOT_PROMPT).
  local _choice=""
  if [[ -r /dev/tty ]]; then read -r -p "  Reboot now? [y/N]: " _choice </dev/tty || _choice=""; fi
  [[ "$_choice" =~ ^[Yy]$ ]] && tb_root reboot
  warn "Skipping reboot. GPU may not be available until you restart."
}

# ── Container Toolkit ────────────────────────────────────────────────────────
# Signature of the installed GPU stack (toolkit + driver versions). Empty when it
# can't be determined -> the caller then never caches, so it always re-verifies.
# k3s.sh's GPU gate (_native_k3s_gpu_wire) compares it with the last wired run's.
_gpu_stack_signature() {
  local ctk drv ctk_out drv_out
  # BOUNDED (#431 Bugbot): a half-ready driver or a stuck device node can make these
  # hang; this runs at the GPU gate on every re-run. On timeout the value is empty,
  # which already means "don't cache".
  #
  # Capture whole, then take the first line with `%%$'\n'*` — NOT `… | head -1`.
  # Under `set -o pipefail` head closes the pipe after line 1, so a chatty/wedged
  # probe whose output passes the ~64KB pipe buffer makes the producer take SIGPIPE
  # and the pipeline exit 141. That used to be papered over by a trailing `|| true`,
  # which is a fail-open: it swallowed the 141 AND every real failure code alike.
  # `|| …_out=""` keeps the documented contract (absent tool / timeout ⇒ empty ⇒
  # don't cache) explicit and set -e safe, with no pipe left to break.
  ctk_out="$(_bounded "${TB_PROBE_TIMEOUT:-5}" nvidia-ctk --version 2>/dev/null)" || ctk_out=""
  drv_out="$(_bounded "${TB_PROBE_TIMEOUT:-5}" nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)" || drv_out=""
  ctk="${ctk_out%%$'\n'*}"
  drv="${drv_out%%$'\n'*}"
  [[ -n "${ctk}${drv}" ]] && printf '%s|%s' "$ctk" "$drv"
  # Always succeed: the installer runs under `set -e`, and the caller assigns this via
  # `$(...)` — an empty signature means "don't cache", not "abort the install" (#431 Bugbot).
  return 0
}

# _nvidia_toolkit_repo_fetch URL -- the toolkit's repository file from URL, on stdout.
# --print downloads nothing, so it prints nothing there: the write it feeds is listed.
_nvidia_toolkit_repo_fetch() {
  if tb_root_planning; then return 0; fi
  curl_secure -fsSL --max-time 30 "$1"
}

# _nvidia_container_toolkit_package -- nvidia-container-toolkit from NVIDIA's
# repository, unless an nvidia-ctk that answers is already here. It touches no
# container runtime: k3s.sh's _native_k3s_gpu_prepare runs it, then writes the CDI
# spec (slim client 1.1i).
_nvidia_container_toolkit_package() {
  log "Setting up NVIDIA container toolkit"

  if has nvidia-ctk && nvidia-ctk --version &>/dev/null 2>&1; then
    log "NVIDIA Container Toolkit already installed."
  else
    log "Installing nvidia-container-toolkit..."

    if has apt-get; then
      local nvidia_gpg_tmp
      nvidia_gpg_tmp="$(mktemp)"
      # --print downloads nothing (prepare-host's plan): it lists the writes the
      # downloads feed.
      if ! tb_root_planning; then
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
      fi
      tb_root gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$nvidia_gpg_tmp"
      rm -f "$nvidia_gpg_tmp"
      # --max-time 30 on all three fetches above/below: each is a few KB of key or
      # repo metadata, so a longer wait only means a hung mirror. They pipe into
      # sed/tee, so they can't be retry-wrapped — retry() reports attempts on
      # stdout, which here IS the file content being written.
      _nvidia_toolkit_repo_fetch https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tb_root tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
      tb_root apt-get update -qq
      $PM_INSTALL nvidia-container-toolkit

    elif has dnf || has yum; then
      _nvidia_toolkit_repo_fetch https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | tb_root tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
      has dnf && tb_root dnf install -y nvidia-container-toolkit || tb_root yum install -y nvidia-container-toolkit

    elif has pacman; then
      if   has yay;  then yay  -S --noconfirm nvidia-container-toolkit
      elif has paru; then paru -S --noconfirm nvidia-container-toolkit
      else warn "AUR helper not found — install nvidia-container-toolkit from AUR manually."; fi
    fi
    log "NVIDIA Container Toolkit installed."
  fi
}
