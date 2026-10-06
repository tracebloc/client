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

# _NVIDIA_PRE_TURING_NAME_RE -- the GPU families below compute capability 7.5, as
# nvidia-smi names them (tracebloc/client-dev#1631): GeForce GT / GTS / GTX 4xx-10xx,
# GTX TITAN, TITAN X / Xp / V / Z / Black, MX1xx-3xx, the 6xx-9xx M / MX / A laptop
# parts, Quadro K / M / P / GP / GV, NVS, Tesla and GRID K / M / P / V, and the bare
# datacenter names (K80, M60, P100, P40, P4, V100 ...). Turing and later never match:
# GTX 16xx, RTX, TITAN RTX, MX450+, Quadro RTX / T, Tesla T4.
# Matched against the NORMALISED name (_nvidia_name_normalised): upper case, every run
# of other characters one space, one space either side, so each alternative is
# anchored on whole words. POSIX ERE, no \b (bash 3.2 on macOS has none).
# install-k8s.ps1 carries the SAME string as $NVIDIA_PRE_TURING_NAME_RE; gpu-floor.bats
# holds the two equal, and both suites walk fixtures/gpu-floor/names.tsv.
_NVIDIA_PRE_TURING_NAME_RE=' (GT|GTS) [0-9]{3,4}[A-Z]* | GTX [4-9][0-9]{2}[A-Z]* | GTX 10[0-9]{2}[A-Z]* | GTX TITAN | TITAN (X|XP|V|Z|BLACK) | MX[1-3][0-9]{2} | GEFORCE [6-9][0-9]{2}(M|MX|A) | QUADRO (K|M|G?P|GV)[0-9]+[A-Z]* | NVS [0-9]{3} | (TESLA|GRID) [KMPV][0-9]+[A-Z]* | (K80|K40M?|K20X?M?|M60|M40|M10|P100|P40|P6|P4|V100S?) '

# _nvidia_name_normalised NAME -- NAME upper-cased, every run of characters that are
# not a letter or digit one space, with one space either side.
_nvidia_name_normalised() {
  local n
  n="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c '[:upper:][:digit:]' ' ' | tr -s ' ')"
  printf ' %s ' "${n# }" | tr -s ' '
}

# _nvidia_pre_turing_name NAMES -- pure: prints the first of NAMES (nvidia-smi's name
# answer, one line per GPU) that is a known pre-Turing family, trimmed, and returns 0;
# returns 1 when none is. A name it cannot classify is not pre-Turing.
_nvidia_pre_turing_name() {
  local line
  while IFS= read -r line; do
    if [[ "$(_nvidia_name_normalised "$line")" =~ $_NVIDIA_PRE_TURING_NAME_RE ]]; then
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      printf '%s\n' "$line"; return 0
    fi
  done <<<"$1"
  return 1
}

# _nvidia_gpu_floor_verdict DRIVERS CAPS DRIVER_FLOOR CAP_FLOOR HARD_FLOOR [NAMES] -- pure:
# prints ok, below-driver, below-hard-floor, below-compute or unreadable. DRIVERS, CAPS
# and NAMES are nvidia-smi's driver_version, compute_cap and name answers, one line per
# GPU, queried SEPARATELY. The lowest driver and compute capability across all GPUs is
# what counts.
#   - The card is judged before the driver: below-compute skips the GPU, and a card too
#     old for the images is never reported as merely an old driver (an upgrade cannot
#     help it).
#   - A driver too old to know compute_cap (the query fails) is judged by the card's
#     NAME: a known pre-Turing family is below-compute (client-dev#1631, a GT 710 on
#     its last driver). A name this cannot classify is judged on the driver alone.
#   - Below HARD_FLOOR (the CUDA 12 minimum) the images cannot initialise CUDA at all:
#     below-hard-floor skips the GPU (client-dev#1632). Between it and DRIVER_FLOOR it
#     is below-driver, which only warns.
#   - A driver at or above the floor always answers compute_cap, so there a failed
#     answer is unreadable.
_nvidia_gpu_floor_verdict() {
  local drv cap cap_ok=1
  if ! _tb_is_version "$3" || ! _tb_is_version "$4" || ! _tb_is_version "${5:-}"; then echo unreadable; return 0; fi
  if ! drv="$(_tb_lowest_version "$1")"; then echo unreadable; return 0; fi
  cap="$(_tb_lowest_version "$2")" || cap_ok=0
  if (( cap_ok )) && ! _tb_version_ge "$cap" "$4"; then echo below-compute; return 0; fi
  if (( ! cap_ok )) && _nvidia_pre_turing_name "${6:-}" >/dev/null; then echo below-compute; return 0; fi
  if ! _tb_version_ge "$drv" "$5"; then echo below-hard-floor; return 0; fi
  if ! _tb_version_ge "$drv" "$3"; then echo below-driver; return 0; fi
  if (( ! cap_ok )); then echo unreadable; return 0; fi
  echo ok
}

# _nvidia_unsupported_name NAMES CAPS CAP_FLOOR -- pure: the name of the GPU the floor
# gate left off as unsupported (client-dev#1633), for env.GPU_UNSUPPORTED_NAME. NAMES and
# CAPS are nvidia-smi's name and compute_cap answers, one line per GPU in the same order:
#   - the first GPU whose compute capability is below CAP_FLOOR;
#   - else, the compute capability unreadable, the first pre-Turing name;
#   - else the first GPU (a driver below the hard floor is every GPU's).
# Prints nothing when NAMES has no name.
_nvidia_unsupported_name() {
  local name cap first="" caps="$2"
  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    if [[ "$caps" == *$'\n'* ]]; then cap="${caps%%$'\n'*}"; caps="${caps#*$'\n'}"; else cap="$caps"; caps=""; fi
    cap="${cap//[[:space:]]/}"
    [[ -n "$name" ]] || continue
    [[ -n "$first" ]] || first="$name"
    if _tb_is_version "$cap" && ! _tb_version_ge "$cap" "$3"; then printf '%s\n' "$name"; return 0; fi
  done <<<"$1"
  if ! _tb_lowest_version "$2" >/dev/null && _nvidia_pre_turing_name "$1"; then return 0; fi
  [[ -n "$first" ]] && printf '%s\n' "$first"
  return 0
}

# _nvidia_gpu_floor_gate DRIVERS CAPS [NAMES] -- judge the host against the stamped
# floors, record the verdict in TB_GPU_FLOOR_VERDICT, and say what it means, once.
#   below-driver                the floor, this driver and the upgrade; the GPU is
#                               still wired
#   below-compute, below-hard-floor, unreadable
#                               the GPU steps install and wire nothing
#                               (_gpu_floor_skips), so the install runs CPU-only
# below-compute and below-hard-floor also set TB_GPU_UNSUPPORTED_REASON / _NAME, which
# the chart passes to the platform (client-dev#1633); every other verdict clears them.
_nvidia_gpu_floor_gate() {
  local floor="$TB_NVIDIA_DRIVER_FLOOR" cap_floor="$TB_NVIDIA_COMPUTE_CAP_FLOOR"
  local hard="$TB_NVIDIA_DRIVER_HARD_FLOOR" names="${3:-}"
  local drv cap cmd old_name
  TB_GPU_FLOOR_VERDICT="$(_nvidia_gpu_floor_verdict "$1" "$2" "$floor" "$cap_floor" "$hard" "$names")"
  TB_GPU_UNSUPPORTED_REASON=""; TB_GPU_UNSUPPORTED_NAME=""
  drv="$(_tb_lowest_version "$1")" || drv="unknown"
  cap="$(_tb_lowest_version "$2")" || cap="unknown"
  log "GPU floor: ${TB_GPU_FLOOR_VERDICT} (driver ${drv}, floor ${floor}, hard floor ${hard}; compute capability ${cap}, floor ${cap_floor})"
  if has ubuntu-drivers; then cmd="sudo ubuntu-drivers install --gpgpu nvidia:${floor%%.*}-server"
  elif has apt-get; then cmd="sudo apt-get install -y nvidia-driver-${floor%%.*}"
  elif has dnf; then cmd="sudo dnf module install -y nvidia-driver:latest-dkms"
  else cmd=""
  fi
  case "$TB_GPU_FLOOR_VERDICT" in
    ok) ;;
    below-driver)
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
    below-hard-floor)
      # Below the CUDA 12 minimum the images' torch cannot initialise CUDA at all, so
      # the GPU would be advertised and unusable (client-dev#1632).
      warn "NVIDIA driver ${drv} is older than ${hard}, the oldest driver tracebloc's GPU images can use (CUDA 12) — this machine will run in CPU mode."
      TB_GPU_UNSUPPORTED_REASON="The NVIDIA driver on this machine (${drv}) is older than ${hard}, the oldest driver tracebloc's GPU training images can use, so this machine runs on CPU until the driver is updated."
      TB_GPU_UNSUPPORTED_NAME="$(_nvidia_unsupported_name "$names" "$2" "$cap_floor")"
      if [[ -n "$cmd" ]]; then
        hint "To use the GPU: ${cmd}, reboot, then re-run the installer."
      else
        hint "To use the GPU: install NVIDIA driver ${floor} or newer (https://www.nvidia.com/Download/index.aspx), reboot, then re-run the installer."
      fi
      ;;
    below-compute)
      if [[ "$cap" == unknown ]] && old_name="$(_nvidia_pre_turing_name "$names")"; then
        # Classified by name: the driver could not report the compute capability
        # (client-dev#1631), so the card is named instead of a number.
        warn "This NVIDIA GPU (${old_name}) is too old for tracebloc's GPU images, which need compute capability ${cap_floor} or newer — this machine will run in CPU mode."
        TB_GPU_UNSUPPORTED_REASON="This GPU is too old for tracebloc's GPU training images, which need compute capability ${cap_floor} or newer (NVIDIA Turing or later), so this machine runs on CPU."
      else
        warn "This NVIDIA GPU (compute capability ${cap}) is too old for tracebloc's GPU images, which need ${cap_floor} or newer — this machine will run in CPU mode."
        TB_GPU_UNSUPPORTED_REASON="This GPU (compute capability ${cap}) is too old for tracebloc's GPU training images, which need ${cap_floor} or newer (NVIDIA Turing or later), so this machine runs on CPU."
      fi
      TB_GPU_UNSUPPORTED_NAME="$(_nvidia_unsupported_name "$names" "$2" "$cap_floor")"
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
    _nvidia_gpu_floor_gate "$_gpu_drv" "$_gpu_cap" "$_gpu_name"
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
