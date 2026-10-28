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
# install-wsl.ps1 carries the SAME string as $NVIDIA_PRE_TURING_NAME_RE; gpu-floor.bats
# holds the two equal and walks fixtures/gpu-floor/names.tsv.
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

# _NVIDIA_GPU_FLOOR_VERDICTS -- every verdict there is: the words _nvidia_gpu_floor_verdict
# prints, the words install-wsl.ps1's copy of the Windows verdict returns, and so the only
# words the Windows installer hands to the core in WSL (_nvidia_gpu_wsl_verdict). Declared
# once, here: gpu-floor.bats holds this function's echoes to it, and install-wsl.Tests.ps1
# the Windows verdict's returns.
_NVIDIA_GPU_FLOOR_VERDICTS=(ok below-hard-floor below-compute unreadable)

# _nvidia_gpu_floor_verdict DRIVERS CAPS DRIVER_FLOOR CAP_FLOOR HARD_FLOOR [NAMES] -- pure:
# prints ok, below-hard-floor, below-compute or unreadable. DRIVERS, CAPS
# and NAMES are nvidia-smi's driver_version, compute_cap and name answers, one line per
# GPU, queried SEPARATELY. The lowest driver and compute capability across all GPUs is
# what counts.
#   - The card is judged before the driver: below-compute skips the GPU, and a card too
#     old for the images is never reported as merely an old driver (an upgrade cannot
#     help it).
#   - A driver too old to know compute_cap (the query fails) is judged by the card's
#     NAME: a known pre-Turing family is below-compute (client-dev#1631, a GT 710 on
#     its last driver). A name this cannot classify is judged on the driver alone.
#   - Below HARD_FLOOR (the CUDA 13 minimum tracebloc's GPU images need) it is
#     below-hard-floor, which skips the GPU (client-dev#1632). There is no warning
#     band: every driver at or above HARD_FLOOR is judged on the card alone.
#     DRIVER_FLOOR is not compared, only read: the gate names it as the update, so a
#     floor that is not a version is unreadable, never a pass.
#   - A driver at or above the hard floor always answers compute_cap, so there a
#     failed answer is unreadable.
_nvidia_gpu_floor_verdict() {
  local drv cap cap_ok=1
  if ! _tb_is_version "$3" || ! _tb_is_version "$4" || ! _tb_is_version "${5:-}"; then echo unreadable; return 0; fi
  if ! drv="$(_tb_lowest_version "$1")"; then echo unreadable; return 0; fi
  cap="$(_tb_lowest_version "$2")" || cap_ok=0
  if (( cap_ok )) && ! _tb_version_ge "$cap" "$4"; then echo below-compute; return 0; fi
  if (( ! cap_ok )) && _nvidia_pre_turing_name "${6:-}" >/dev/null; then echo below-compute; return 0; fi
  if ! _tb_version_ge "$drv" "$5"; then echo below-hard-floor; return 0; fi
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

# _nvidia_driver_update_cmd FLOOR -- the command the hint tells the user to run to
# update the driver to FLOOR's series on this machine, or nothing. Printed, never run:
# prepare-host reaches this, and only the root executor runs sudo there.
_nvidia_driver_update_cmd() {
  if has ubuntu-drivers; then printf 'sudo ubuntu-drivers install --gpgpu nvidia:%s-server' "${1%%.*}"
  elif has apt-get; then printf 'sudo apt-get install -y nvidia-driver-%s' "${1%%.*}"
  elif has dnf; then printf 'sudo dnf module install -y nvidia-driver:latest-dkms'
  fi
  return 0
}

# _nvidia_gpu_floor_gate DRIVERS CAPS [NAMES] -- judge the host against the stamped
# floors, record the verdict in TB_GPU_FLOOR_VERDICT, and say what it means, once.
#   ok                          nothing is said; the GPU is wired
#   below-compute, below-hard-floor, unreadable
#                               the GPU steps install and wire nothing
#                               (_gpu_floor_skips), so the install runs CPU-only;
#                               below-hard-floor prints the update to the driver
#                               floor and says to re-run the installer
# below-compute and below-hard-floor also set TB_GPU_UNSUPPORTED_REASON / _NAME, which
# the chart passes to the platform (client-dev#1633), and TB_GPU_UNSUPPORTED_CODE, the
# machine-readable kind beside the sentence (compute_too_old / driver_too_old,
# backend#5296); every other verdict clears all three.
_nvidia_gpu_floor_gate() {
  local floor="$TB_NVIDIA_DRIVER_FLOOR" cap_floor="$TB_NVIDIA_COMPUTE_CAP_FLOOR"
  local hard="$TB_NVIDIA_DRIVER_HARD_FLOOR" names="${3:-}"
  local drv cap cmd old_name
  TB_GPU_FLOOR_VERDICT="$(_nvidia_gpu_floor_verdict "$1" "$2" "$floor" "$cap_floor" "$hard" "$names")"
  TB_GPU_UNSUPPORTED_REASON=""; TB_GPU_UNSUPPORTED_NAME=""
  TB_GPU_UNSUPPORTED_CODE=""
  TB_GPU_NVIDIA_NAMES="$names"
  drv="$(_tb_lowest_version "$1")" || drv="unknown"
  cap="$(_tb_lowest_version "$2")" || cap="unknown"
  log "GPU floor: ${TB_GPU_FLOOR_VERDICT} (driver ${drv}, floor ${floor}, hard floor ${hard}; compute capability ${cap}, floor ${cap_floor})"
  cmd="$(_nvidia_driver_update_cmd "$floor")"
  case "$TB_GPU_FLOOR_VERDICT" in
    ok) ;;
    below-hard-floor)
      # Below the CUDA 13 minimum tracebloc's GPU images need (torch 2.14.1+cu130,
      # tracebloc-engine#1712) the GPU would be advertised and unusable
      # (client-dev#1632), so it is left off: there is no warning band (2026-10-18).
      # The update is to the driver floor, and the GPU is set up only by a run on the
      # new driver, so the hint says to re-run the installer. Word for word what
      # install-wsl.ps1 says on Windows (install-wsl.Tests.ps1 holds it).
      warn "NVIDIA driver ${drv} is older than ${hard}, the driver tracebloc's GPU training images need (CUDA 13) — this machine will run in CPU mode."
      TB_GPU_UNSUPPORTED_REASON="The NVIDIA driver on this machine (${drv}) is older than ${hard}, the driver tracebloc's GPU training images need (CUDA 13), so this machine runs on CPU until the driver is updated to ${floor} or newer and the installer is run again."
      TB_GPU_UNSUPPORTED_CODE="driver_too_old"
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
      TB_GPU_UNSUPPORTED_CODE="compute_too_old"
      TB_GPU_UNSUPPORTED_NAME="$(_nvidia_unsupported_name "$names" "$2" "$cap_floor")"
      hint "GPU training needs a newer card (NVIDIA Turing or later). Everything else works on CPU."
      ;;
    *)
      warn "Couldn't read this NVIDIA GPU's driver version and compute capability — this machine will run in CPU mode to be safe."
      hint "Check that 'nvidia-smi --query-gpu=driver_version,compute_cap --format=csv' works, then re-run the installer."
      ;;
  esac
}

# _nvidia_gpu_wsl_verdict NAMES -- the floor gate in tracebloc's WSL distro (3.2 part 3,
# client-dev#1810). There nvidia-smi answers for the WINDOWS driver, whose number the
# Linux floors must never judge. The Windows installer judged it against the Windows
# floors (install-wsl.ps1, Confirm-NvidiaDriver), said what it means, and hands the
# verdict to both of the core's runs on their line: TRACEBLOC_WSL_GPU_VERDICT, one of
# _NVIDIA_GPU_FLOOR_VERDICTS, and TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE / _NAME / _REASON,
# which below-compute and below-hard-floor carry to the platform as the gate's own do.
# This takes them as given and repeats nothing the host said. A verdict that is empty or
# not one of those words is cannot tell: unreadable, so the GPU steps install and wire
# nothing and the install runs CPU-only, said, never a silent GPU.
_nvidia_gpu_wsl_verdict() {
  local given="${TRACEBLOC_WSL_GPU_VERDICT:-}" v known=0
  TB_GPU_UNSUPPORTED_CODE=""; TB_GPU_UNSUPPORTED_NAME=""; TB_GPU_UNSUPPORTED_REASON=""
  TB_GPU_NVIDIA_NAMES="${1:-}"
  for v in ${_NVIDIA_GPU_FLOOR_VERDICTS[@]+"${_NVIDIA_GPU_FLOOR_VERDICTS[@]}"}; do
    if [[ "$given" == "$v" ]]; then known=1; fi
  done
  if (( ! known )); then
    TB_GPU_FLOOR_VERDICT=unreadable
    log "GPU floor: unreadable (the Windows installer handed over '${given}')"
    if [[ -z "$given" ]]; then
      warn "The Windows installer did not say whether this machine's NVIDIA driver is new enough for GPU training, so this machine will run in CPU mode to be safe."
    else
      warn "The Windows installer's check of this machine's NVIDIA driver answered '${given}', which this installer does not know, so this machine will run in CPU mode to be safe."
    fi
    hint "Re-run the installer from Windows. If this comes back, share this output with tracebloc support."
    return 0
  fi
  TB_GPU_FLOOR_VERDICT="$given"
  log "GPU floor: ${given} (the Windows installer's verdict, against the Windows floors)"
  case "$given" in
    below-compute|below-hard-floor)
      TB_GPU_UNSUPPORTED_CODE="${TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE:-}"
      TB_GPU_UNSUPPORTED_NAME="${TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME:-}"
      TB_GPU_UNSUPPORTED_REASON="${TRACEBLOC_WSL_GPU_UNSUPPORTED_REASON:-}"
      ;;
  esac
}

# ── The GPU that is not NVIDIA, and the NVIDIA GPU no container can see (backend#5296) ──
# TB_GPU_UNSUPPORTED_CODE is one of a CLOSED vocabulary the backend stores beside the
# sentence and the dashboard switches on: compute_too_old and driver_too_old (the floor
# gate above), not_nvidia, runtime_cannot_see_gpu and arch_unsupported (below).
# install-wsl.ps1 sets four of them on the Windows host (all but runtime_cannot_see_gpu);
# detect-gpu.bats holds its not_nvidia and arch_unsupported sentences to these.
# wsl_cannot_see_gpu is the Windows installer's alone (install-wsl.ps1,
# Confirm-NvidiaWslGpu), taken below as it reports it. A code the backend does not
# know yet is stored blank and the sentence still shows (backend#5296).
# runtime_cannot_see_gpu is the runtime-neutral name backend#5892 gave the container-blind
# code. The backend and cli-dev's doctor still read the old name, for clients installed
# before it, but nothing here writes it: detect-gpu.bats fails on any file naming it.

# _GPU_NOT_NVIDIA_VENDOR_RE -- the vendors whose GPU counts as "a GPU, but not NVIDIA",
# matched against the NORMALISED name (_nvidia_name_normalised). An allowlist, on
# purpose: a server's BMC or a VM's virtual display (ASPEED, Matrox G200, VMware SVGA,
# QXL, Cirrus, Hyper-V, bochs) is a display adapter, not a GPU, and must keep reading
# as "no GPU". Intel counts, the integrated GPU included: a machine whose ONLY GPU is
# an Intel iGPU has a GPU, and "only NVIDIA GPUs are supported" is the true answer.
# install-wsl.ps1 carries the SAME strings as $GPU_NOT_NVIDIA_VENDOR_RE and
# $GPU_NOT_NVIDIA_DISCRETE_RE (detect-gpu.bats holds each pair equal).
_GPU_NOT_NVIDIA_VENDOR_RE=' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|INTEL|APPLE) '
# _GPU_NOT_NVIDIA_DISCRETE_RE -- of those, the ones named first when a machine has
# several: a discrete AMD card or the Apple GPU over an Intel iGPU.
_GPU_NOT_NVIDIA_DISCRETE_RE=' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|APPLE) '

# _gpu_not_nvidia_name NAMES -- pure: NAMES is one GPU description per line (lspci's
# display-class devices, system_profiler's chipset models). Prints the GPU to report
# as not_nvidia and returns 0 when NAMES has a GPU of a _GPU_NOT_NVIDIA_VENDOR_RE vendor
# and NO NVIDIA one; returns 1 otherwise. Any NVIDIA line wins: NVIDIA plus an iGPU is
# an NVIDIA machine, judged by the floor gate, never not_nvidia.
_gpu_not_nvidia_name() {
  local line norm first="" discrete=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    norm="$(_nvidia_name_normalised "$line")"
    [[ "$norm" == *" NVIDIA "* ]] && return 1
    [[ "$norm" =~ $_GPU_NOT_NVIDIA_VENDOR_RE ]] || continue
    [[ -n "$first" ]] || first="$line"
    if [[ -z "$discrete" && "$norm" =~ $_GPU_NOT_NVIDIA_DISCRETE_RE ]]; then discrete="$line"; fi
  done <<<"$1"
  [[ -n "$first" ]] || return 1
  printf '%s\n' "${discrete:-$first}"
}

# _lspci_display_devices LSPCI -- pure: the description of every display-class device
# (VGA compatible / 3D / Display controller) in lspci's default output, one per line,
# without the "(rev NN)" suffix. Nothing for a listing with none.
_lspci_display_devices() {
  printf '%s\n' "$1" | sed -nE 's/^[^ ]+ (VGA compatible controller|3D controller|Display controller)[^:]*: (.*)$/\2/p' \
    | sed -E 's/ *\(rev [0-9a-fA-F]+\)$//'
}

# _macos_gpu_names PROFILE -- pure: the "Chipset Model:" of every GPU in
# `system_profiler SPDisplaysDataType` output, one per line.
_macos_gpu_names() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*Chipset Model:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p'
}

# _gpu_not_nvidia_report NAME -- the machine has a GPU and it is not NVIDIA: tell the
# platform (not_nvidia), with the card's name.
_gpu_not_nvidia_report() {
  TB_GPU_UNSUPPORTED_CODE="not_nvidia"
  TB_GPU_UNSUPPORTED_REASON="This machine's GPU is not an NVIDIA GPU, and tracebloc's GPU training images need one (NVIDIA Turing or later), so this machine runs on CPU."
  TB_GPU_UNSUPPORTED_NAME="$1"
}

# ── The GPU tracebloc has no training image for (client-dev#1697, #1698) ──
# The GPU training images are CUDA and linux/amd64 only: there is no ROCm image and no
# arm64 GPU image. So an AMD GPU, and an NVIDIA GPU on a machine that is not x86_64, are
# GPUs this installer cannot use, and it treats them as it treats an NVIDIA card below
# the compute floor: nothing is installed or requested for them (no ROCm, no NVIDIA
# driver or container toolkit, no device plugin, no GPU_REQUESTS), the install runs
# CPU-only, it says why, and the platform is told. detect_gpu gives the vendor the
# _unsupported suffix (amd_unsupported, nvidia_unsupported; install-wsl.ps1 calls a
# Windows AMD GPU amd_unsupported too), so every GPU step, which keys on exactly
# nvidia or amd, passes over it.

# _gpu_arch_supported -- 0 when this machine can run the GPU training images (x86_64).
_gpu_arch_supported() { [[ "${ARCH:-}" == x86_64 || "${ARCH:-}" == amd64 ]]; }

# _gpu_arch_label -- this machine's architecture as the reason names it: arm64 for
# uname's aarch64 too, so the sentence is the same as install-wsl.ps1's.
_gpu_arch_label() {
  case "${ARCH:-}" in
    aarch64|arm64) printf 'arm64' ;;
    *) printf '%s' "${ARCH:-unknown}" ;;
  esac
}

# _gpu_arch_unsupported_report NAME -- an NVIDIA GPU on a machine that is not x86_64:
# leave it off (nvidia_unsupported), say why, and tell the platform (arch_unsupported),
# with the card's name. Never judged by the floor gate: no driver or card can help.
_gpu_arch_unsupported_report() {
  local arch
  arch="$(_gpu_arch_label)"
  GPU_VENDOR="nvidia_unsupported"; NVIDIA_DRIVER_OK=false; TB_GPU_FLOOR_VERDICT=""
  TB_GPU_UNSUPPORTED_CODE="arch_unsupported"
  TB_GPU_UNSUPPORTED_REASON="This machine is ${arch}, and tracebloc's GPU training images are built for x86_64 machines only, so this machine runs on CPU."
  TB_GPU_UNSUPPORTED_NAME="$1"
  warn "tracebloc's GPU training images are built for x86_64 machines only, and this machine is ${arch} — the NVIDIA GPU is not set up, and this machine will run in CPU mode."
  hint "Everything else works on CPU. GPU training needs an x86_64 machine with an NVIDIA GPU."
}

# TB_WSL_GPU_LIB_DIR -- where WSL mounts the Windows driver's user-space half in a
# distro: nvidia-smi, libcuda and libdxcore (NVIDIA's CUDA on WSL guide).
TB_WSL_GPU_LIB_DIR="/usr/lib/wsl/lib"

# _gpu_wsl_lib_on_path -- tracebloc's WSL distro (S-W row 13): the core's runs start
# from `wsl --exec env ... bash`, and nothing in the distro puts TB_WSL_GPU_LIB_DIR on
# PATH, so the Windows driver's nvidia-smi could go unseen and a GPU the host judged
# would read as "does not answer". Appended once, after the distro's own directories,
# when nvidia-smi is there. Nothing else changes: the GPU itself reaches k3s's pods
# through the spec tracebloc-cdi writes (k3s.sh, _native_k3s_gpu_wsl_prepare).
_gpu_wsl_lib_on_path() {
  [[ -x "${TB_WSL_GPU_LIB_DIR}/nvidia-smi" ]] || return 0
  case ":${PATH:-}:" in *":${TB_WSL_GPU_LIB_DIR}:"*) return 0 ;; esac
  PATH="${PATH:+${PATH}:}${TB_WSL_GPU_LIB_DIR}"
  export PATH
  log "GPU detection in the WSL distro: ${TB_WSL_GPU_LIB_DIR} put on PATH for the Windows driver's nvidia-smi"
}

# _gpu_smi ARGS... -- nvidia-smi, bounded in tracebloc's WSL distro. There it is the
# Windows driver's (_gpu_wsl_lib_on_path), reached over WSL's GPU bridge, and a
# wedged bridge would hang the install with no further output. TB_WSL_INTEROP_TIMEOUT
# bounds it, as it bounds the distro's other calls into Windows
# (install-client-helm.sh). Outside the distro it is nvidia-smi, as before.
_gpu_smi() {
  if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
    _bounded "${TB_WSL_INTEROP_TIMEOUT:-20}" nvidia-smi "$@"
  else
    nvidia-smi "$@"
  fi
}

# _gpu_wsl_cannot_see_report -- the Windows installer's wsl_cannot_see_gpu
# (install-wsl.ps1, Confirm-NvidiaWslGpu, S-W row 13): an NVIDIA GPU that WSL cannot
# give this distro, in the TCC driver model or a Tesla part. Taken as Find-Gpu's other
# reports are: the GPU is left out (nvidia_unsupported, no driver step and no wiring),
# and the platform is told the host's code, card and sentence. The host said it on
# Windows, so this logs and says nothing again.
_gpu_wsl_cannot_see_report() {
  GPU_VENDOR="nvidia_unsupported"; NVIDIA_DRIVER_OK=false; TB_GPU_FLOOR_VERDICT=""
  TB_GPU_UNSUPPORTED_CODE="wsl_cannot_see_gpu"
  TB_GPU_UNSUPPORTED_NAME="${TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME:-}"
  TB_GPU_UNSUPPORTED_REASON="${TRACEBLOC_WSL_GPU_UNSUPPORTED_REASON:-}"
  log "GPU: the Windows installer left out '${TB_GPU_UNSUPPORTED_NAME}': WSL cannot give this distro that GPU (wsl_cannot_see_gpu)"
}

# _gpu_wsl_host_report -- tracebloc's WSL distro, past the nvidia-smi path. WSL shows a
# distro no PCI device and no NVIDIA kernel module, so lspci and /proc/driver/nvidia
# cannot see this machine's GPUs; the Windows installer's Find-Gpu did, and has said
# what it found. Its reports reach this run on its line (install-wsl.ps1,
# New-CoreRunArguments): not_nvidia and arch_unsupported as
# TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE, with the card as _NAME, and set here by this
# file's own reports, the same sentences, without saying them again; wsl_cannot_see_gpu
# with the host's own sentence as _REASON (_gpu_wsl_cannot_see_report). A verdict on the
# line is an NVIDIA GPU the host judged, taken as _nvidia_gpu_wsl_verdict takes it; one
# the host let through (ok) whose driver does not answer in here, and a
# code this installer does not know, run CPU-only, said.
_gpu_wsl_host_report() {
  local code="${TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE:-}"
  log "GPU detection in the WSL distro, no nvidia-smi: the Windows installer reported '${code}', verdict '${TRACEBLOC_WSL_GPU_VERDICT:-}'"
  case "$code" in
    not_nvidia)
      _gpu_not_nvidia_report "${TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME:-}"
      return 0
      ;;
    arch_unsupported)
      _gpu_arch_unsupported_report "${TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME:-}" >/dev/null
      return 0
      ;;
    wsl_cannot_see_gpu)
      _gpu_wsl_cannot_see_report
      return 0
      ;;
  esac
  if [[ -n "${TRACEBLOC_WSL_GPU_VERDICT:-}" ]]; then
    _nvidia_gpu_wsl_verdict ""
    case "$TB_GPU_FLOOR_VERDICT" in
      ok)
        warn "The Windows installer found an NVIDIA GPU, but its driver does not answer inside the tracebloc WSL distro, so this machine will run in CPU mode."
        hint "Re-run the installer from Windows. If this comes back, share this output with tracebloc support."
        ;;
    esac
  elif [[ -n "$code" ]]; then
    warn "The Windows installer's GPU check answered '${code}', which this installer does not know, so this machine will run in CPU mode to be safe."
    hint "Re-run the installer from Windows; if this comes back, share this output with tracebloc support."
  fi
}

# _gpu_container_blind RUNTIME -- the container runtime's own GPU probe has just said it
# cannot give a container this machine's NVIDIA GPU: k3s's containerd not registering
# the NVIDIA runtime (k3s.sh). RUNTIME names it in the sentence ("k3s"). Reports
# runtime_cannot_see_gpu ONLY for a GPU the floor gate let through (ok, with a driver
# that answered nvidia-smi): a card or driver already reported unsupported
# keeps that reason, and a GPU this run could not read is "cannot tell", never blind.
_gpu_container_blind() {
  [[ "${GPU_VENDOR:-}" == nvidia && "${NVIDIA_DRIVER_OK:-false}" == true ]] || return 0
  case "${TB_GPU_FLOOR_VERDICT:-}" in ok) ;; *) return 0 ;; esac
  [[ -z "${TB_GPU_UNSUPPORTED_CODE:-}" ]] || return 0
  local name="${TB_GPU_NVIDIA_NAMES:-}"
  name="${name%%$'\n'*}"; name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  TB_GPU_UNSUPPORTED_CODE="runtime_cannot_see_gpu"
  TB_GPU_UNSUPPORTED_REASON="${1} can't see this machine's NVIDIA GPU, so this machine runs on CPU until containers can use the GPU."
  TB_GPU_UNSUPPORTED_NAME="$name"
}

# _GPU_CONTAINER_BLIND_RE -- the container runtime's own words for "I cannot give this
# container a GPU": no NVIDIA runtime at all, the toolkit's CLI failing, NVML refused
# (WSL2 passthrough off). A pull or network failure prints none of them, so it is never
# read as a blind runtime.
_GPU_CONTAINER_BLIND_RE='could not select device driver|nvidia-container-cli|Failed to initialize NVML|no adapters were found|capabilities: \[\[gpu\]\]'

# A function so bats can model the /proc path (same idiom as common.sh's
# amd64_emulation_available).
_nvidia_kernel_module_loaded() { [[ -d /proc/driver/nvidia ]]; }

detect_gpu() {
  log "GPU detection starting — OS=$OS ARCH=$ARCH"
  TB_GPU_NVIDIA_NAMES=""
  local lspci_out="" amd_line not_nvidia

  if [[ "$OS" == "Darwin" ]]; then
    TB_GPU_UNSUPPORTED_REASON=""; TB_GPU_UNSUPPORTED_NAME=""; TB_GPU_UNSUPPORTED_CODE=""
    if [[ "$ARCH" == "arm64" ]]; then
      GPU_VENDOR="apple_silicon"
    fi
    # No line on the screen: the summary's "Training" row names what this Mac trains on.
    # Apple silicon on the macOS node gets the Apple-GPU runner in step e
    # (_mac_ct_runner_host, the half of _mac_ct_runner_on known now).
    if [[ "${GPU_VENDOR:-}" == apple_silicon ]] && declare -F _mac_ct_runner_host >/dev/null 2>&1 && _mac_ct_runner_host; then
      log "GPU: step e sets up training on this Mac's GPU. Training uses the GPU while macOS has its latest update and there is memory for it; otherwise it uses the CPU."
    else
      log "GPU: this Mac trains on the CPU: training on this Mac's GPU needs Apple silicon on a machine that runs tracebloc in Apple's container runtime."
    fi
    # The Mac's GPU (Apple, AMD or Intel) is not NVIDIA: say so to the platform, by
    # name. Bounded: system_profiler is slow on a busy Mac, and an unreadable answer
    # is no report, never a guess.
    local profile=""
    if has system_profiler; then
      profile="$(_bounded "${TB_GPU_PROFILER_TIMEOUT:-20}" system_profiler SPDisplaysDataType 2>/dev/null)" || profile=""
    fi
    if not_nvidia="$(_gpu_not_nvidia_name "$(_macos_gpu_names "$profile")")"; then
      _gpu_not_nvidia_report "$not_nvidia"
    fi
    return
  fi

  # In tracebloc's WSL distro the Windows driver's nvidia-smi is WSL's (_gpu_wsl_lib_on_path).
  if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
    _gpu_wsl_lib_on_path
  fi
  if has nvidia-smi && _gpu_smi &>/dev/null 2>&1; then
    # In tracebloc's WSL distro a GPU the Windows installer left out because WSL
    # cannot give it to the distro stays out (_gpu_wsl_cannot_see_report): before
    # any line says it was detected, and without asking nvidia-smi anything more.
    if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
      if [[ "${TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE:-}" == wsl_cannot_see_gpu ]]; then
        _gpu_wsl_cannot_see_report
        return
      fi
    fi
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
    _gpu_name="$(_gpu_smi --query-gpu=name --format=csv,noheader 2>/dev/null)" || _gpu_name=""
    _gpu_drv="$(_gpu_smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)" || _gpu_drv=""
    _gpu_cap="$(_gpu_smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)" || _gpu_cap=""
    success "NVIDIA GPU detected: ${_gpu_name%%$'\n'*}"
    log "Driver: ${_gpu_drv%%$'\n'*}"
    if ! _gpu_arch_supported; then
      _gpu_name="${_gpu_name%%$'\n'*}"; _gpu_name="${_gpu_name#"${_gpu_name%%[![:space:]]*}"}"
      _gpu_arch_unsupported_report "${_gpu_name%"${_gpu_name##*[![:space:]]}"}"
      return
    fi
    # In tracebloc's WSL distro the Windows installer's verdict decides, never the
    # Linux floors (_nvidia_gpu_wsl_verdict).
    if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
      _nvidia_gpu_wsl_verdict "$_gpu_name"
      return
    fi
    _nvidia_gpu_floor_gate "$_gpu_drv" "$_gpu_cap" "$_gpu_name"
    return
  fi

  # Past the nvidia-smi path, which the floor gate clears and judges: what follows
  # reports a GPU that is not NVIDIA, or nothing.
  TB_GPU_UNSUPPORTED_REASON=""; TB_GPU_UNSUPPORTED_NAME=""; TB_GPU_UNSUPPORTED_CODE=""
  # In tracebloc's WSL distro the GPUs are the Windows host's (_gpu_wsl_host_report).
  if declare -F tb_in_wsl_distro >/dev/null 2>&1 && tb_in_wsl_distro; then
    _gpu_wsl_host_report
    return
  fi
  if has lspci; then
    # Capture ONCE, then match the captured value. `lspci | grep -qi` lets grep
    # close the pipe on its first hit; lspci takes SIGPIPE and pipefail makes the
    # pipeline 141, which the `if` reads as "no such GPU" — a CPU-mode cluster on
    # a GPU host. lspci streams device-per-line, so an NVIDIA/AMD card early in
    # the enumeration is exactly the case that loses the race (backend#1778).
    lspci_out="$(lspci 2>/dev/null || true)"
    if grep -qi "NVIDIA" <<<"$lspci_out"; then
      GPU_VENDOR="nvidia"
      NVIDIA_DRIVER_OK=false
      if ! _gpu_arch_supported; then
        _gpu_arch_unsupported_report "$(_lspci_display_devices "$lspci_out" | grep -i -m1 'NVIDIA' || true)"
        return
      fi
      warn "NVIDIA GPU detected — drivers not yet installed."
      return
    fi
    if grep -qi "AMD.*VGA\|Advanced Micro Devices.*VGA\|Radeon" <<<"$lspci_out"; then
      # No ROCm image exists (client-dev#1697): the AMD GPU is left off, like any other
      # GPU that is not NVIDIA. No ROCm, no AMD device plugin, no amd.com/gpu request.
      GPU_VENDOR="amd_unsupported"
      amd_line="$(grep -i 'Radeon\|AMD.*VGA' <<<"$lspci_out" || true)"
      success "AMD GPU detected: ${amd_line%%$'\n'*}"
      warn "tracebloc's GPU training images need an NVIDIA GPU, so the AMD GPU is not set up — this machine will run in CPU mode."
      hint "Everything else works on CPU. GPU training needs an NVIDIA GPU (Turing or later) on an x86_64 machine."
      if not_nvidia="$(_gpu_not_nvidia_name "$(_lspci_display_devices "$lspci_out")")"; then
        _gpu_not_nvidia_report "$not_nvidia"
      fi
      return
    fi
  fi

  # The kernel module is loaded but there is no nvidia-smi to read a version or a
  # compute capability from: the floor gate calls that unreadable.
  if _nvidia_kernel_module_loaded; then
    GPU_VENDOR="nvidia"; NVIDIA_DRIVER_OK=true
    success "NVIDIA GPU detected."
    if ! _gpu_arch_supported; then _gpu_arch_unsupported_report ""; return; fi
    _nvidia_gpu_floor_gate "" ""
    return
  fi

  # A GPU that is not NVIDIA (an Intel GPU, the integrated one included) is a GPU
  # this machine cannot train on: named, not "no GPU".
  if not_nvidia="$(_gpu_not_nvidia_name "$(_lspci_display_devices "$lspci_out")")"; then
    _gpu_not_nvidia_report "$not_nvidia"
    info "This machine's GPU (${not_nvidia}) is not an NVIDIA GPU. Your environment will run in CPU mode."
    return
  fi

  info "No GPU detected. Your environment will run in CPU mode."
}
