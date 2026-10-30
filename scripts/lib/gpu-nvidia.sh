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

# _nvidia_driver_not_installed REASON [COMMAND] -- the driver step put no driver in: say
# so, name the manual route. install_nvidia_drivers then returns 1, so dispatch_gpu_setup
# skips the toolkit and there is no reboot flow: the install goes on CPU-only
# (client-dev#1699). A "drivers installed, reboot" over nothing installed only led to
# a reboot, still no driver, and the same again on the next run. COMMAND, when the
# installer knows it, is the exact install to run by hand, said with sudo before it
# (client-dev#2880).
_nvidia_driver_not_installed() {
  local _rerun="this installer"
  [[ -n "${TB_PREPARE_HOST_RUN:-}" ]] && _rerun="prepare-host"
  warn "The NVIDIA driver was NOT installed: ${1}. This install continues in CPU mode."
  if [[ -n "${2:-}" ]]; then
    hint "To use the GPU, install the NVIDIA driver yourself: sudo ${2}, reboot, then re-run ${_rerun}."
  else
    hint "To use the GPU, install the NVIDIA driver for your distribution yourself, then re-run ${_rerun}."
  fi
}

# _nvidia_driver_offered_pick FLOOR_MAJOR DEVICES -- from `ubuntu-drivers devices`
# output, the driver to install for THIS machine's GPU, in ubuntu-drivers' own spelling
# (`595-open`, `580-server`), or nothing (client-dev#2880). The archive can carry a
# series ubuntu-drivers does not offer for the card, or offers only in another flavour:
# on Ubuntu 26.04 with an RTX 4050 the archive's newest was 615, offered only as
# 615-open and 615-server-open, so asking for nvidia:615-server and nvidia:615 installed
# nothing. In order, at or above the floor's series:
#   1. the driver ubuntu-drivers marks `recommended`;
#   2. else the newest -server or -server-open (-server first within a series);
#   3. else the newest of any flavour.
# Below the floor only when nothing reaches it: the newest offered. Pure.
_nvidia_driver_offered_pick() {
  printf '%s\n' "$2" | awk -v floor="$1" '
    $1 == "driver" && $3 ~ /^nvidia-driver-[0-9]+(-server)?(-open)?$/ {
      name = $3; sub(/^nvidia-driver-/, "", name)
      n = name; sub(/-.*/, "", n); n = n + 0
      tier = 0
      if (n >= floor + 0) {
        if ($0 ~ / recommended/) tier = 3
        else if (name ~ /-server/) tier = 2
        else tier = 1
      }
      key = tier * 100000 + n * 10 + (name ~ /-open$/ ? 0 : 1)
      if (pick == "" || key > best) { best = key; pick = name }
    }
    END { if (pick != "") print pick }'
}

# _nvidia_ubuntu_drivers_cmd NAME -- the ubuntu-drivers install that puts NAME in (no
# sudo): a -server driver is asked for with --gpgpu (the headless compute install),
# any other by its plain name.
_nvidia_ubuntu_drivers_cmd() {
  case "$1" in
    *-server*) printf 'ubuntu-drivers install --gpgpu nvidia:%s' "$1" ;;
    *)         printf 'ubuntu-drivers install nvidia:%s' "$1" ;;
  esac
}

# _nvidia_driver_went_in -- 0 when an NVIDIA driver is on this machine after the install
# step: dpkg holds a driver package (nvidia-driver-N*, or the nvidia-headless-N* that
# `ubuntu-drivers install --gpgpu` puts in), or the kernel has an nvidia module to load.
# `ubuntu-drivers install` exits 0 on "No drivers found for installation"
# (client-dev#2880), so its exit code alone never says a driver went in.
_nvidia_driver_went_in() {
  local pkgs=""
  if has dpkg-query; then
    # dpkg-query exits 1 when one pattern matches nothing, after printing what the other
    # matched: the output is the answer, never the code.
    pkgs="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 'nvidia-headless-*' 2>/dev/null || true)"
    if grep -Eq '^ii +nvidia-(driver|headless(-no-dkms)?)-[0-9]' <<<"$pkgs"; then return 0; fi
  fi
  has modinfo && modinfo nvidia >/dev/null 2>&1
}

# _nvidia_ubuntu_drivers_install NAME -- ubuntu-drivers installs NAME. A -server driver
# is asked for with --gpgpu first, then, when that put nothing in, by its plain name,
# which `ubuntu-drivers devices` listed. Its exit code is not the verdict: the caller
# reads _nvidia_driver_went_in.
_nvidia_ubuntu_drivers_install() {
  if [[ "$1" == *-server* ]]; then
    if tb_root ubuntu-drivers install --gpgpu "nvidia:${1}" && { tb_root_planning || _nvidia_driver_went_in; }; then
      return 0
    fi
    log "ubuntu-drivers install --gpgpu nvidia:${1} put no driver in; asking for nvidia:${1} without --gpgpu."
  fi
  tb_root ubuntu-drivers install "nvidia:${1}"
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
  # falls back to the floor's series by name. Where ubuntu-drivers lists drivers
  # for this GPU, its list decides instead (_nvidia_driver_offered_pick,
  # client-dev#2880); the archive is read only when it lists none. Whatever was
  # asked, a driver must be on the machine afterwards (_nvidia_driver_went_in).
  # if/else, never `a && b || c`: a FAILED install of the package found must
  # fail here, not quietly fall through to another driver.
  local floor_series="${TB_NVIDIA_DRIVER_FLOOR%%.*}" search pkg series failed="" offered="" devices="" cmd=""
  # Only apt-get, dnf and pacman have a driver install here. yum and zypper hosts
  # (setup-linux.sh knows both) are told so, never told a driver went in.
  if ! has apt-get && ! has dnf && ! has pacman; then
    local pm="this machine's package manager"
    if has zypper; then pm="zypper"; elif has yum; then pm="yum"; fi
    _nvidia_driver_not_installed "the installer has no automatic NVIDIA driver install for ${pm}"
    return 1
  fi
  if ! $PM_UPDATE; then
    if has ubuntu-drivers; then cmd="ubuntu-drivers install --gpgpu nvidia:${floor_series}-server"; fi
    _nvidia_driver_not_installed "the package index refresh failed" "$cmd"
    return 1
  fi
  if has apt-get; then
    $PM_INSTALL ubuntu-drivers-common 2>/dev/null || true
    # What ubuntu-drivers offers for THIS GPU decides (client-dev#2880). Its warnings go
    # to the install log, never the screen; its answer is read, never trusted blind.
    if has ubuntu-drivers; then
      devices="$(_bounded "${TRACEBLOC_UBUNTU_DRIVERS_TIMEOUT:-120}" ubuntu-drivers devices 2>>"${LOG_FILE:-/dev/null}")" || {
        # A timeout (124) is no empty list: the series below comes from the archive, unchecked against this GPU.
        (( $? == 124 )) && warn "ubuntu-drivers did not list this GPU's drivers within ${TRACEBLOC_UBUNTU_DRIVERS_TIMEOUT:-120}s — choosing the series from the package archive instead."
        devices=""
      }
      offered="$(_nvidia_driver_offered_pick "$floor_series" "$devices")"
    fi
    if [[ -n "$offered" ]]; then
      series="${offered%%-*}"
      cmd="$(_nvidia_ubuntu_drivers_cmd "$offered")"
      log "ubuntu-drivers offers nvidia:${offered} for this GPU; installing it."
      if (( series < floor_series )); then
        warn "No NVIDIA driver ${floor_series} or newer is offered for this GPU — installing nvidia:${offered}, older than the driver tracebloc's GPU training images need (CUDA 13), so GPU training will not work on it: update it to ${floor_series} or newer when one is available, then re-run the installer."
      fi
      _nvidia_ubuntu_drivers_install "$offered" || failed="'${cmd}' failed"
    else
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
        cmd="ubuntu-drivers install --gpgpu nvidia:${series}-server"
      else
        cmd="apt-get install ${pkg:-nvidia-driver-${floor_series}}"
      fi
      # The first ask's errors stay on the screen and in the log (client-dev#2880): a
      # series it does not offer is said, not swallowed.
      if has ubuntu-drivers; then
        if ! tb_root ubuntu-drivers install --gpgpu "nvidia:${series}-server"; then
          tb_root ubuntu-drivers install "nvidia:${series}"
        fi
      elif [[ -n "$pkg" ]]; then
        $PM_INSTALL "$pkg"
      else
        $PM_INSTALL "nvidia-driver-${floor_series}"
      fi || failed="the NVIDIA driver package did not install"
    fi
    # An install that "succeeded" over nothing (ubuntu-drivers exits 0 on "No drivers
    # found for installation") is no install: the GPU stays off, said, with the command.
    if [[ -z "$failed" ]] && ! tb_root_planning && ! _nvidia_driver_went_in; then
      failed="no NVIDIA driver package is installed after '${cmd}'"
    fi
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
    _nvidia_driver_not_installed "$failed" "$cmd"
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

# The toolkit's repository files. Variables, so the suite writes them in a sandbox.
TB_NVIDIA_TOOLKIT_KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
TB_NVIDIA_TOOLKIT_APT_LIST="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
TB_NVIDIA_TOOLKIT_YUM_REPO="/etc/yum.repos.d/nvidia-container-toolkit.repo"

# _nvidia_toolkit_repo_files_readable [FILE...] -- every FILE that exists and is not
# readable by all is set to 0644; with no FILE, the toolkit's three repository files
# (client-dev#2879). The core runs under `umask 077` (common.sh), which `sudo gpg -o` and
# `sudo tee` inherit, so these files came out 0600. apt reads a source list and checks
# its keyring as the unprivileged _apt user: with a 0600 keyring it refused the
# repository as "not signed" (NO_PUBKEY) and the install stopped, and the 0600 files it
# left made every later `apt-get update` fail, so each re-run fell back to CPU.
# setup-linux.sh's setup_pm runs this before the run's first package index refresh, so a
# machine an older installer left that way is repaired; the writes below run it too.
# The check reads as this user; only a repair runs as root.
_nvidia_toolkit_repo_files_readable() {
  local f
  if [[ $# -eq 0 ]]; then
    set -- "$TB_NVIDIA_TOOLKIT_KEYRING" "$TB_NVIDIA_TOOLKIT_APT_LIST" "$TB_NVIDIA_TOOLKIT_YUM_REPO"
  fi
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    [[ -n "$(find "$f" -maxdepth 0 -perm -0444 2>/dev/null)" ]] && continue
    tb_root chmod 0644 "$f" || warn "Couldn't make ${f} readable (chmod 0644): the package manager will refuse the NVIDIA repository until it is."
  done
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
      tb_root gpg --batch --yes --dearmor -o "$TB_NVIDIA_TOOLKIT_KEYRING" "$nvidia_gpg_tmp"
      rm -f "$nvidia_gpg_tmp"
      # --max-time 30 on all three fetches above/below: each is a few KB of key or
      # repo metadata, so a longer wait only means a hung mirror. They pipe into
      # sed/tee, so they can't be retry-wrapped — retry() reports attempts on
      # stdout, which here IS the file content being written.
      _nvidia_toolkit_repo_fetch https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=${TB_NVIDIA_TOOLKIT_KEYRING}] https://#g" \
        | tb_root tee "$TB_NVIDIA_TOOLKIT_APT_LIST" >/dev/null
      # 0644 before apt reads them: _apt must read both (client-dev#2879).
      _nvidia_toolkit_repo_files_readable "$TB_NVIDIA_TOOLKIT_KEYRING" "$TB_NVIDIA_TOOLKIT_APT_LIST"
      tb_root apt-get update -qq
      $PM_INSTALL nvidia-container-toolkit

    elif has dnf || has yum; then
      _nvidia_toolkit_repo_fetch https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | tb_root tee "$TB_NVIDIA_TOOLKIT_YUM_REPO" >/dev/null
      _nvidia_toolkit_repo_files_readable "$TB_NVIDIA_TOOLKIT_YUM_REPO"
      has dnf && tb_root dnf install -y nvidia-container-toolkit || tb_root yum install -y nvidia-container-toolkit

    elif has pacman; then
      if   has yay;  then yay  -S --noconfirm nvidia-container-toolkit
      elif has paru; then paru -S --noconfirm nvidia-container-toolkit
      else warn "AUR helper not found — install nvidia-container-toolkit from AUR manually."; fi
    fi
    log "NVIDIA Container Toolkit installed."
  fi
}
