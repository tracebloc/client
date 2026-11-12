#!/usr/bin/env bash
# =============================================================================
#  machine-facts.sh — what kind of machine this is, for the dashboard: device
#  type from the chassis (or the Windows host under WSL2), VM detection, cloud
#  provider, host CPU name, and the --set-string args that carry them.
# =============================================================================

# _detect_device_type GPU_VAL — what kind of machine this is, for the dashboard's
# secure-environment switcher. Prints one of the backend's enum
# `workstation | gpu_server | server | cluster`, or NOTHING when the chassis
# cannot be read: jobs-manager then omits the key from its heartbeat and the
# dashboard draws its default glyph rather than a guess.
#
# The installer is the one party that can tell a laptop from a rack server — it
# runs on the host and can read the chassis — which is why this lives here and
# not in jobs-manager (which can only count nodes, and node counts cannot tell a
# workstation from a server). Sources, in order:
#
#   TRACEBLOC_DEVICE_TYPE   an explicit override, for unattended installs and
#                           for the cases no chassis read gets right (a rack
#                           server used as somebody's desk machine). A value
#                           outside the enum is IGNORED with a warning, not
#                           written: the backend would drop it on every ping.
#   Darwin                  every Mac this installer supports sits on a desk
#                           (MacBook, iMac, Mac mini, Mac Studio, Mac Pro).
#   Linux                   `hostnamectl` Chassis (systemd's own verdict:
#                           laptop / desktop / convertible / tablet / handset /
#                           server / vm / container), then the SMBIOS
#                           chassis_type number under /sys/class/dmi/id as the
#                           fallback for hosts without systemd.
#
# A server-class chassis (or a VM — a VM is a server) becomes gpu_server when
# THIS run wires a GPU request (GPU_VAL, the same value written to GPU_LIMITS),
# else server. A desk-class chassis is a workstation whether or not it has a GPU:
# the dashboard's hardware line already names the card, and the glyph is about
# where the machine sits. `cluster` is never detected here — this installer's
# cluster is one host by construction; jobs-manager derives it from SINGLE_NODE on the clusters
# this installer does not build.
# Hypervisor signatures, matched case-insensitively as substrings of the DMI
# `sys_vendor product_name` pair (Windows: `Manufacturer Model`). A match means
# this host is a virtual machine, and a VM is a server whatever enclosure number
# its firmware reports: Hyper-V and Azure guests say 3 (Desktop), VMware says 1
# (Other), so the chassis number alone files them as workstations or as nothing
# Every entry names a hypervisor or a cloud's virtual
# platform, never a hardware maker -- `Microsoft Corporation` alone is also a
# Surface laptop, so Hyper-V is matched by its model, `Virtual Machine`.
_TB_VM_SIGNATURES=("virtual machine" "vmware" "virtualbox" "innotek" "qemu" "kvm" "xen" "bochs" "parallels" "amazon ec2" "google compute engine" "openstack" "digitalocean")

# _is_vm_signature "VENDOR PRODUCT" — 0 when the pair names a hypervisor.
_is_vm_signature() {
  local hay sig
  hay="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "${hay//[[:space:]]/}" ]] || return 1
  for sig in "${_TB_VM_SIGNATURES[@]}"; do  # set-u-safe: _TB_VM_SIGNATURES is a file-scope constant
    [[ "$hay" == *"$sig"* ]] && return 0
  done
  return 1
}

# _chassis_from_smbios N... — desktop | laptop | server | "" for SMBIOS System
# Enclosure type numbers (DSP0134 §7.4.1). Any desk or portable number wins over
# a server one, for Windows' ChassisTypes array as for Linux's one number;
# one list for both callers below so they cannot drift.
_chassis_from_smbios() {
  local n desk="" lap="" srv=""
  for n in "$@"; do
    case "$n" in
      3|4|5|6|7|13|15|16|24|35|36) desk=1 ;;
      8|9|10|11|12|14|30|31|32)    lap=1 ;;
      17|23|25|28|29)              srv=1 ;;
    esac
  done
  if [[ -n "$lap" ]]; then printf 'laptop'
  elif [[ -n "$desk" ]]; then printf 'desktop'
  elif [[ -n "$srv" ]]; then printf 'server'
  fi
  return 0
}

# _windows_host_identity — inside WSL2, ask the WINDOWS HOST what it is, over
# interop. Prints one line,
# `Manufacturer|Model|ChassisTypes(csv)|PCSystemType|SMBIOSAssetTag|OSCaption`,
# or returns 1 when it cannot: interop off (no powershell.exe), no `timeout` to
# bound the call with, a hang, or a failure. The distro itself cannot answer:
# its DMI is Hyper-V's (`Microsoft Corporation` / `Virtual Machine`) and
# systemd calls it a `container`, so this is the only source
# that describes the machine the user is sitting at. Bounded, because a wedged
# interop must not stall the install; the verdict is cosmetic. --kill-after as
# well as the deadline: interop does not reliably deliver a
# Unix SIGTERM to a Windows .exe, and GNU timeout without it sends TERM and then
# WAITS -- a wedged Get-CimInstance would hold the install forever. KILL ends the
# Linux-side interop process, which closes the pipe this substitution reads.
# TRACEBLOC_WINDOWS_POWERSHELL is a test seam for the fallback path.
_windows_host_identity() {
  local ps="" out="" fallback="${TRACEBLOC_WINDOWS_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
  if command -v powershell.exe >/dev/null 2>&1; then ps="powershell.exe"
  elif [[ -x "$fallback" ]]; then ps="$fallback"
  fi
  [[ -n "$ps" ]] || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016  # the $ belong to PowerShell, not to this shell
  out="$(timeout --kill-after="${TB_WSL_INTEROP_KILL_AFTER:-5}" "${TB_WSL_INTEROP_TIMEOUT:-20}" "$ps" -NoProfile -NonInteractive -Command \
    '$c = Get-CimInstance Win32_ComputerSystem; $e = @(Get-CimInstance Win32_SystemEnclosure); $o = Get-CimInstance Win32_OperatingSystem; "{0}|{1}|{2}|{3}|{4}|{5}" -f $c.Manufacturer, $c.Model, (@($e.ChassisTypes) -join ","), $c.PCSystemType, $e[0].SMBIOSAssetTag, $o.Caption' \
    2>/dev/null)" || return 1
  out="${out//$'\r'/}"
  [[ "$out" == *"|"*"|"*"|"* ]] || return 1
  printf '%s' "$out"
}

# _windows_host_identity_once — _windows_host_identity, asked at most once per
# shell. Several facts are read from the one answer (the chassis, the cloud, the
# OS), and each interop call starts a Windows PowerShell. The answer is kept in
# globals, so it is shared only by what runs AFTER a call in THIS shell: a
# verdict computed in `$( )` keeps its own copy. _prime_windows_host_identity
# makes that one call in the caller's shell first. Returns 1 when it cannot tell.
_TB_WIN_HOST_IDENT=""
_TB_WIN_HOST_IDENT_READ=""
_windows_host_identity_once() {
  if [[ -z "${_TB_WIN_HOST_IDENT_READ:-}" ]]; then
    _TB_WIN_HOST_IDENT="$(_windows_host_identity)" || _TB_WIN_HOST_IDENT=""
    _TB_WIN_HOST_IDENT_READ=1
  fi
  [[ -n "${_TB_WIN_HOST_IDENT:-}" ]] || return 1
  printf '%s' "$_TB_WIN_HOST_IDENT"
}

# _prime_windows_host_identity — inside WSL2 only, read the Windows host's
# identity once in THIS shell, so the verdicts computed after it share it.
# Outside WSL2 (or without probe.sh, which a stale bootstrap may not have
# fetched) it does nothing.
_prime_windows_host_identity() {
  if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
    _windows_host_identity_once >/dev/null || true
  fi
  return 0
}

# _chassis_from_windows_identity "Manufacturer|Model|ChassisTypes|PCSystemType[|...]"
# — the Windows host's own ladder, read from inside WSL2: hypervisor signature
# first (a Windows host that is itself a VM is `vm`), then the enclosure numbers,
# then PCSystemType (2 Mobile is a laptop, 1/3 desk, 4/5 server). Fields after
# the fourth are ignored.
_chassis_from_windows_identity() {
  local maker model types pcs _rest chassis=""
  IFS='|' read -r maker model types pcs _rest <<<"${1:-}"
  if _is_vm_signature "$maker $model"; then printf 'vm'; return 0; fi
  # shellcheck disable=SC2086  # word-split the comma list into numbers on purpose
  chassis="$(_chassis_from_smbios ${types//,/ })"
  if [[ -z "$chassis" ]]; then
    case "${pcs//[[:space:]]/}" in
      2)   chassis="laptop" ;;
      1|3) chassis="desktop" ;;
      4|5) chassis="server" ;;
    esac
  fi
  printf '%s' "$chassis"
  return 0
}

# _windows_identity_field "IDENTITY" N — field N (1-based) of a
# _windows_host_identity line, or nothing. The OS caption is the LAST field, so
# it keeps any `|` of its own.
_windows_identity_field() {
  local f1 f2 f3 f4 f5 f6
  IFS='|' read -r f1 f2 f3 f4 f5 f6 <<<"${1:-}"
  case "${2:-}" in
    1) printf '%s' "$f1" ;; 2) printf '%s' "$f2" ;; 3) printf '%s' "$f3" ;;
    4) printf '%s' "$f4" ;; 5) printf '%s' "$f5" ;; 6) printf '%s' "$f6" ;;
  esac
  return 0
}

# _linux_chassis — this Linux host's chassis word, BEFORE any verdict collapses it:
# hostnamectl's own (laptop / desktop / convertible / tablet / handset / server /
# vm / container / ...), else `vm` for a hypervisor's DMI signature, else the
# SMBIOS enclosure number's class (laptop / desktop / server), else nothing.
# Outside WSL2 only: inside it neither source describes the machine (see
# _detect_device_type). The one ladder _detect_device_type and
# _detect_machine_kind both read, so the two cannot disagree about a host.
_linux_chassis() {
  # TRACEBLOC_DMI_DIR is a test seam only; real installs read the kernel's DMI table.
  local dmi="${TRACEBLOC_DMI_DIR:-/sys/class/dmi/id}" chassis=""
  # `hostnamectl` prints "  Chassis: laptop 💻" (the icon is newer systemd);
  # the first word is the verdict. `hostnamectl chassis` alone needs v249+.
  # LC_ALL=C on hostnamectl ITSELF: systemd translates the label
  # ("Gehäuse:", "Châssis:"), and a VM whose label went unmatched fell
  # through to DMI type 1 (Other) and was reported as "" instead of server.
  # LC_ALL=C on sed/awk too, so the icon's bytes cannot make them bail
  # (BSD sed: "illegal byte sequence").
  # This runs under the caller's errexit+pipefail, so a missing or failing
  # hostnamectl (no systemd, no D-Bus in a container) must fall through to
  # the DMI read, not abort the install; awk's NR==1 reads to EOF, so no
  # reader closes the pipe early.
  if command -v hostnamectl >/dev/null 2>&1; then
    chassis="$( { LC_ALL=C hostnamectl 2>/dev/null || true; } | LC_ALL=C sed -n 's/^[[:space:]]*Chassis:[[:space:]]*//p' | LC_ALL=C awk 'NR == 1 { print $1 }')" || chassis=""
  fi
  # No verdict from hostnamectl (absent, no systemd bus, or no Chassis line):
  # read DMI. The hypervisor signature comes FIRST -- hostnamectl reports
  # `vm` for a guest from systemd-detect-virt, and without it the enclosure
  # number is the firmware's claim, which for Hyper-V is 3 (Desktop).
  if [[ -z "$chassis" ]]; then
    if _is_vm_signature "$(_dmi_value "$dmi" sys_vendor) $(_dmi_value "$dmi" product_name)"; then chassis="vm"; fi
  fi
  if [[ -z "$chassis" && -r "$dmi/chassis_type" ]]; then
    chassis="$(_chassis_from_smbios "$(tr -d '[:space:]' < "$dmi/chassis_type" 2>/dev/null || true)")"
  fi
  printf '%s' "$chassis"
  return 0
}

# _dmi_value DIR NAME — the DMI field NAME under DIR (one line, trailing newline
# dropped), or nothing when it is absent or unreadable. Never fails.
_dmi_value() {
  [[ -r "$1/$2" ]] || return 0
  cat "$1/$2" 2>/dev/null || true
}

_detect_device_type() {
  local gpu_val="${1:-}" override="${TRACEBLOC_DEVICE_TYPE:-}" chassis=""
  if [[ -n "$override" ]]; then
    local wanted
    wanted="$(printf '%s' "$override" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$wanted" in
      workstation|gpu_server|server|cluster) printf '%s' "$wanted"; return 0 ;;
      # To stderr: callers capture this function's stdout as the verdict.
      *) warn "TRACEBLOC_DEVICE_TYPE=\"${override}\" is not one of workstation|gpu_server|server|cluster — ignoring it and reading the chassis instead." >&2 ;;
    esac
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) chassis="desktop" ;;
    Linux)
      # WSL2 FIRST. Inside WSL2 neither Linux source describes
      # the machine: systemd reports `container` and DMI is Hyper-V's, which the
      # VM check below would call a server -- so one laptop came out as nothing
      # or as a server depending on which source answered. Ask the Windows host
      # instead; when interop cannot answer, say nothing. `_probe_wsl` lives in
      # probe.sh, which a stale bootstrap may not have fetched; without it this
      # branch is skipped, the same rule cluster.sh applies.
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
        local ident=""
        if ident="$(_windows_host_identity_once)"; then
          chassis="$(_chassis_from_windows_identity "$ident")"
        fi
        case "$chassis" in
          laptop|desktop) printf 'workstation' ;;
          server|vm) if [[ -n "$gpu_val" ]]; then printf 'gpu_server'; else printf 'server'; fi ;;
          *) printf '' ;;
        esac
        return 0
      fi
      chassis="$(_linux_chassis)"
      ;;
  esac
  case "$chassis" in
    laptop|desktop|convertible|tablet|handset) printf 'workstation' ;;
    server|vm) if [[ -n "$gpu_val" ]]; then printf 'gpu_server'; else printf 'server'; fi ;;
    *) printf '' ;;   # container / embedded / unknown: say nothing
  esac
  return 0
}

# ── Machine facts for the dashboard ───────────────────────────────────────────
# What the installer reads off the host and the resource monitor cannot: a pod
# sees neither the chassis, nor the cloud's firmware strings, nor (in the macOS
# node's VM) the host's CPU name. Each is passed to the chart as one env var on the
# resource monitor (_machine_facts_set_args), which sends it on every heartbeat.
# A fact that cannot be read is EMPTY, and the chart then leaves the variable
# unset: the platform keeps what it had rather than store a guess. Each verdict
# is a word of the platform's closed vocabulary, or nothing.
#   TRACEBLOC_MACHINE_KIND    laptop | desktop | server | cloud
#   TRACEBLOC_CLOUD_PROVIDER  aws | azure | gcp
#   TRACEBLOC_HOST_CPU_NAME   macOS only ("Apple M3 Pro"); on Linux the node's
#                             own /proc/cpuinfo names the CPU.
# DEVICE_TYPE is not one of them and is unchanged: jobs-manager validates it
# against its own four words, so laptop and desktop still collapse there.
#
# Azure's virtual machines carry this fixed SMBIOS asset tag (Microsoft documents
# it as the way to tell an Azure VM from any other Hyper-V guest), which a plain
# Hyper-V guest does not.
_TB_AZURE_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"

# _cloud_from_identity VENDOR PRODUCT ASSET_TAG — aws | gcp | azure | "" from the
# firmware's strings, read on the host with no network call (no metadata
# service): "Amazon EC2" (the vendor on every Nitro instance) is aws, "Google
# Compute Engine" (the product) is gcp, and a Microsoft vendor WITH Azure's asset
# tag is azure. Matched case-insensitively.
_cloud_from_identity() {
  local hay maker tag
  hay="$(printf '%s %s' "${1:-}" "${2:-}" | tr '[:upper:]' '[:lower:]')"
  maker="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  tag="$(printf '%s' "${3:-}" | tr -d '[:space:]')"
  case "$hay" in
    *"amazon ec2"*)            printf 'aws'; return 0 ;;
    *"google compute engine"*) printf 'gcp'; return 0 ;;
  esac
  if [[ "$maker" == *microsoft* && "$tag" == "$_TB_AZURE_ASSET_TAG" ]]; then printf 'azure'; fi
  return 0
}

# _machine_kind_from_chassis CHASSIS CLOUD — laptop | desktop | server | cloud |
# "" from a chassis word (hostnamectl's, or _chassis_from_smbios /
# _chassis_from_windows_identity's) and the detected cloud. A known cloud is
# `cloud` whatever its chassis says: the cloud strings name only a cloud's own
# machines, a bare-metal instance included. Any other VM is a server.
_machine_kind_from_chassis() {
  if [[ -n "${2:-}" ]]; then printf 'cloud'; return 0; fi
  case "${1:-}" in
    laptop|convertible|tablet|handset) printf 'laptop' ;;
    desktop)   printf 'desktop' ;;
    server|vm) printf 'server' ;;
  esac
  return 0
}

# _detect_cloud_provider — aws | azure | gcp | "" for this host. Linux reads the
# DMI table; inside WSL2 the distro's DMI is Hyper-V's on every host, so the
# Windows host's own strings decide, and interop that cannot answer says
# nothing. macOS says nothing.
_detect_cloud_provider() {
  local dmi="${TRACEBLOC_DMI_DIR:-/sys/class/dmi/id}" ident=""
  [[ "$(uname -s 2>/dev/null)" == Linux ]] || return 0
  if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
    if ident="$(_windows_host_identity_once)"; then
      _cloud_from_identity "$(_windows_identity_field "$ident" 1)" "$(_windows_identity_field "$ident" 2)" \
        "$(_windows_identity_field "$ident" 5)"
    fi
    return 0
  fi
  _cloud_from_identity "$(_dmi_value "$dmi" sys_vendor)" "$(_dmi_value "$dmi" product_name)" \
    "$(_dmi_value "$dmi" chassis_asset_tag)"
  return 0
}

# _detect_machine_kind — laptop | desktop | server | cloud | "" for this host:
# the probes _detect_device_type reads, before it collapses laptop and desktop.
#   macOS   laptop when `pmset -g batt` lists an internal battery, else desktop;
#           nothing when pmset cannot answer.
#   WSL2    the Windows host's chassis (_chassis_from_windows_identity); nothing
#           when interop cannot answer.
#   Linux   _linux_chassis.
# A known cloud (_detect_cloud_provider) is `cloud` on every path.
_detect_machine_kind() {
  local chassis="" cloud="" batt="" ident=""
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      batt="$(pmset -g batt 2>/dev/null)" || return 0
      case "$batt" in
        *InternalBattery*) printf 'laptop' ;;
        *)                 printf 'desktop' ;;
      esac
      return 0
      ;;
    Linux)
      cloud="$(_detect_cloud_provider)"
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
        if ident="$(_windows_host_identity_once)"; then
          chassis="$(_chassis_from_windows_identity "$ident")"
        fi
      else
        chassis="$(_linux_chassis)"
      fi
      _machine_kind_from_chassis "$chassis" "$cloud"
      ;;
  esac
  return 0
}

# _detect_host_cpu_name — the host CPU's model name where the node cannot read it:
# macOS only, from `sysctl -n machdep.cpu.brand_string` ("Apple M3 Pro"), whose
# node VM's /proc/cpuinfo names no model on Apple silicon. Trimmed; nothing on
# any other OS, when sysctl cannot answer, or when the name is longer than the
# 200 characters the platform stores (a longer one is dropped, never cut).
_detect_host_cpu_name() {
  local name=""
  [[ "$(uname -s 2>/dev/null)" == Darwin ]] || return 0
  name="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" || return 0
  name="$(printf '%s' "$name" | LC_ALL=C tr -d '\r\n' | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "${#name}" -le 200 ]] || return 0
  printf '%s' "$name"
}

# _machine_facts_set_args -- the three machine facts above as --set-string pairs:
# env.TRACEBLOC_MACHINE_KIND, env.TRACEBLOC_CLOUD_PROVIDER and
# env.TRACEBLOC_HOST_CPU_NAME. Canonical names only: the variables are new, so
# they have no legacy spelling. ALWAYS all three keys, EMPTY when unknown, so a
# reconciled release never keeps another run's answer; the chart renders a key
# only when it is non-empty. Inside WSL2 the Windows host is asked once for all
# of them. Into _TB_MACHINE_FACTS_ARGS (an array, bash-3.2 safe, six words).
_machine_facts_set_args() {
  local kind cloud cpu
  _prime_windows_host_identity
  kind="$(_detect_machine_kind)"
  cloud="$(_detect_cloud_provider)"
  cpu="$(_detect_host_cpu_name)"
  log "Machine facts for the dashboard: kind=${kind:-unknown} cloud=${cloud:-none} cpu=${cpu:-not read}"
  _TB_MACHINE_FACTS_ARGS=(
    --set-string "env.TRACEBLOC_MACHINE_KIND=$(_helm_set_string_escape "$kind")"
    --set-string "env.TRACEBLOC_CLOUD_PROVIDER=$(_helm_set_string_escape "$cloud")"
    --set-string "env.TRACEBLOC_HOST_CPU_NAME=$(_helm_set_string_escape "$cpu")"
  )
}
