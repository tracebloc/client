#!/usr/bin/env bash
# =============================================================================
#  detect-gpu.sh — Identify GPU vendor and driver state
# =============================================================================

# ── The GPU floor (facts.env NVIDIA_DRIVER_FLOOR_LINUX / NVIDIA_COMPUTE_CAP_FLOOR) ──
# _tb_version_ge A B — 0 when dotted version A >= B. Each component is compared as
# a base-10 number (10#: a driver component like the 08 in 575.57.08 is not octal),
# and a missing component is 0, so 570 == 570.0 and 12.0 > 7.5. The caller passes
# versions _tb_is_version accepts.
_tb_version_ge() {
  local a="$1" b="$2" x y
  while [[ -n "$a" || -n "$b" ]]; do
    x="${a%%.*}"; y="${b%%.*}"
    if [[ "$a" == *.* ]]; then a="${a#*.}"; else a=""; fi
    if [[ "$b" == *.* ]]; then b="${b#*.}"; else b=""; fi
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    if (( x > y )); then return 0; fi
    if (( x < y )); then return 1; fi
  done
  return 0
}

_tb_is_version() {
  local re='^[0-9]+(\.[0-9]+)*$'
  [[ "$1" =~ $re ]]
}

# _tb_lowest_version LINES — the lowest version among LINES (one per GPU, as
# nvidia-smi prints them). Returns 1 when there is none, or when ANY line is not a
# version (empty, [N/A], an error text): one GPU that cannot be read is "cannot
# tell" for the host, never a pass on the others.
_tb_lowest_version() {
  local line v lowest=""
  while IFS= read -r line; do
    v="${line//[[:space:]]/}"
    _tb_is_version "$v" || return 1
    if [[ -z "$lowest" ]] || ! _tb_version_ge "$v" "$lowest"; then lowest="$v"; fi
  done <<<"$1"
  [[ -n "$lowest" ]] || return 1
  printf '%s\n' "$lowest"
}

# _nvidia_gpu_floor_verdict DRIVERS CAPS DRIVER_FLOOR CAP_FLOOR — pure: prints ok,
# below-driver, below-compute or unreadable. DRIVERS and CAPS are nvidia-smi's
# driver_version and compute_cap answers, one line per GPU, queried SEPARATELY. The
# lowest of each across all GPUs is what counts.
#   - The compute capability is judged before the driver: below-compute skips the
#     GPU, below-driver only warns, so a card too old for the images is never
#     reported as merely an old driver.
#   - A driver too old to know compute_cap (the query fails) still reports
#     below-driver: that is what the host tells us. A driver at or above the floor
#     always answers compute_cap, so there a failed answer is unreadable.
_nvidia_gpu_floor_verdict() {
  local drv cap cap_ok=1
  if ! _tb_is_version "$3" || ! _tb_is_version "$4"; then echo unreadable; return 0; fi
  if ! drv="$(_tb_lowest_version "$1")"; then echo unreadable; return 0; fi
  cap="$(_tb_lowest_version "$2")" || cap_ok=0
  if (( cap_ok )) && ! _tb_version_ge "$cap" "$4"; then echo below-compute; return 0; fi
  if ! _tb_version_ge "$drv" "$3"; then echo below-driver; return 0; fi
  if (( ! cap_ok )); then echo unreadable; return 0; fi
  echo ok
}

# _nvidia_gpu_floor_gate DRIVERS CAPS — judge the host against the stamped floors,
# record the verdict in TB_GPU_FLOOR_VERDICT, and say what it means, once.
#   below-driver                the floor, this driver and the upgrade; the GPU is
#                               still wired
#   below-compute, unreadable   the GPU steps install and wire nothing
#                               (_gpu_floor_skips), so the install runs CPU-only
_nvidia_gpu_floor_gate() {
  local floor="$TB_NVIDIA_DRIVER_FLOOR" cap_floor="$TB_NVIDIA_COMPUTE_CAP_FLOOR"
  local drv cap cmd
  TB_GPU_FLOOR_VERDICT="$(_nvidia_gpu_floor_verdict "$1" "$2" "$floor" "$cap_floor")"
  drv="$(_tb_lowest_version "$1")" || drv="unknown"
  cap="$(_tb_lowest_version "$2")" || cap="unknown"
  log "GPU floor: ${TB_GPU_FLOOR_VERDICT} (driver ${drv}, floor ${floor}; compute capability ${cap}, floor ${cap_floor})"
  case "$TB_GPU_FLOOR_VERDICT" in
    ok) ;;
    below-driver)
      if has ubuntu-drivers; then cmd="sudo ubuntu-drivers install --gpgpu nvidia:${floor%%.*}-server"
      elif has apt-get; then cmd="sudo apt-get install -y nvidia-driver-${floor%%.*}"
      elif has dnf; then cmd="sudo dnf module install -y nvidia-driver:latest-dkms"
      else cmd=""
      fi
      # A driver too old to answer compute_cap: the GPU is kept (the decision on
      # #1355), and the warning says the card itself could not be checked either.
      if [[ "$cap" == unknown ]]; then
        warn "NVIDIA driver ${drv} is older than ${floor}, the driver tracebloc recommends for GPU training, and it cannot report this GPU's compute capability — continuing with the GPU, but it may not work until the driver is upgraded."
      else
        warn "NVIDIA driver ${drv} is older than ${floor}, the driver tracebloc recommends for GPU training — continuing with the GPU; if GPU training fails on this machine, upgrade the driver."
      fi
      if [[ -n "$cmd" ]]; then
        hint "To upgrade: ${cmd}, reboot, then re-run the installer."
      else
        hint "To upgrade: install NVIDIA driver ${floor} or newer (https://www.nvidia.com/Download/index.aspx), reboot, then re-run the installer."
      fi
      # The measured remedy for keeping an older driver (S-G, tracebloc/backend#4830):
      # at 535 the GPUs failed to initialise and the node advertised 0, until
      # persistence mode was on from boot. A driver too old to report compute_cap is
      # older than anything S-G ran, so it gets the upgrade alone.
      if [[ "$cap" != unknown ]]; then
        hint "Or keep this driver: turn persistence mode on from boot (nvidia-persistenced, or 'sudo nvidia-smi -pm 1' before the cluster starts), reboot, then re-run the installer. Driver 535 needed it to bring the GPU up."
      fi
      ;;
    below-compute)
      warn "This NVIDIA GPU (compute capability ${cap}) is too old for tracebloc's GPU images, which need ${cap_floor} or newer — this machine will run in CPU mode."
      hint "GPU training needs a newer card (NVIDIA Turing or later). Everything else works on CPU."
      ;;
    *)
      warn "Couldn't read this NVIDIA GPU's driver version and compute capability — this machine will run in CPU mode to be safe."
      hint "Check that 'nvidia-smi --query-gpu=driver_version,compute_cap --format=csv' works, then re-run the installer."
      ;;
  esac
}

# A function so bats can model the /proc path (same idiom as common.sh's
# amd64_emulation_available).
_nvidia_kernel_module_loaded() { [[ -d /proc/driver/nvidia ]]; }

detect_gpu() {
  log "GPU detection starting — OS=$OS ARCH=$ARCH"

  if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      GPU_VENDOR="apple_silicon"
    fi
    echo ""
    warn "GPU training isn't supported on macOS yet — this machine will run in CPU mode."
    hint "For GPU-accelerated training, deploy on a Linux machine with NVIDIA GPUs."
    return
  fi

  if has nvidia-smi && nvidia-smi &>/dev/null 2>&1; then
    GPU_VENDOR="nvidia"
    NVIDIA_DRIVER_OK=true
    # Capture-then-slice, not `nvidia-smi … | head -1` (backend#1778). These run
    # under install.sh's `set -euo pipefail` by inheritance, and head closes the
    # pipe after line 1 — one line per GPU is small today, but the shape is the
    # one being retired fleet-wide and the slice costs nothing.
    #
    # `|| _x=""` is NOT decoration (Bugbot). These were argument-position
    # substitutions, where a failing nvidia-smi could not trip errexit; moving
    # them into assignments puts them where it can, so a driver that answers
    # `nvidia-smi` but fails --query-gpu would abort the install with 2>/dev/null
    # hiding the reason. Same neutralisation gpu-nvidia.sh:126 already uses for
    # this exact query, and the lspci capture below.
    # compute_cap is its own query: a driver too old to know it fails that query
    # alone, and the floor gate still reads its driver version.
    local _gpu_name _gpu_drv _gpu_cap
    _gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)" || _gpu_name=""
    _gpu_drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)" || _gpu_drv=""
    _gpu_cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)" || _gpu_cap=""
    success "NVIDIA GPU detected: ${_gpu_name%%$'\n'*}"
    log "Driver: ${_gpu_drv%%$'\n'*}"
    _nvidia_gpu_floor_gate "$_gpu_drv" "$_gpu_cap"
    return
  fi

  if has lspci; then
    # Capture ONCE, then match the captured value. `lspci | grep -qi` lets grep
    # close the pipe on its first hit; lspci takes SIGPIPE and pipefail makes the
    # pipeline 141, which the `if` reads as "no such GPU" — a CPU-mode cluster on
    # a GPU host. lspci streams device-per-line, so an NVIDIA/AMD card early in
    # the enumeration is exactly the case that loses the race (backend#1778).
    local lspci_out amd_line
    lspci_out="$(lspci 2>/dev/null || true)"
    if grep -qi "NVIDIA" <<<"$lspci_out"; then
      GPU_VENDOR="nvidia"
      NVIDIA_DRIVER_OK=false
      warn "NVIDIA GPU detected — drivers not yet installed."
      return
    fi
    if grep -qi "AMD.*VGA\|Advanced Micro Devices.*VGA\|Radeon" <<<"$lspci_out"; then
      GPU_VENDOR="amd"
      amd_line="$(grep -i 'Radeon\|AMD.*VGA' <<<"$lspci_out" || true)"
      success "AMD GPU detected: ${amd_line%%$'\n'*}"
      return
    fi
  fi

  # The kernel module is loaded but there is no nvidia-smi to read a version or a
  # compute capability from: the floor gate calls that unreadable.
  if _nvidia_kernel_module_loaded; then
    GPU_VENDOR="nvidia"; NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU detected."
    _nvidia_gpu_floor_gate "" ""
    return
  fi

  info "No GPU detected. Your environment will run in CPU mode."
}
