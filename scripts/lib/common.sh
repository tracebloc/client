#!/usr/bin/env bash
# =============================================================================
#  common.sh — Shared colours, logging helpers, configuration defaults,
#              retry logic, and log-file setup
# =============================================================================

# ── Security hardening ───────────────────────────────────────────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
umask 077
readonly CURL_SECURE="--tlsv1.2"

# ── Colours ──────────────────────────────────────────────────────────────────
# One brand-grounded palette (design-system tokens): cyan #01a5cc = structure,
# lime #91e947 = action — mirrors the Go CLI's internal/ui engine. Each tone
# renders as exact 24-bit hex on a truecolor terminal, the nearest ANSI-16
# elsewhere, its deep shade on a light background, and nothing at all when colour
# is off (NO_COLOR / not a TTY / TERM=dumb / TB_PLAIN=1). Meaning never rests on
# hue alone — headings/commands also carry bold and alerts a distinct glyph.
#
# Decided ONCE here, at source time: common.sh is sourced before setup_log_file
# redirects stdout through `tee`, so the `-t 1` test sees the real terminal.
if [[ -n "${NO_COLOR:-}" || "${TB_PLAIN:-}" == "1" || "${TERM:-}" == "dumb" || ! -t 1 ]]; then
  _tb_mode=none
elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
  _tb_mode=true
else
  _tb_mode=16
fi
_tb_bg=dark
if [[ -n "${COLORFGBG:-}" ]]; then
  _tb_last="${COLORFGBG##*;}"           # "fg;bg" → a trailing 7/15 is a light bg
  [[ "$_tb_last" == "7" || "$_tb_last" == "15" ]] && _tb_bg=light
fi

# _sgr DARK_RGB LIGHT_RGB ANSI16 BOLD UNDERLINE → the opening escape for a tone
# (empty when colour is off). RGB args are "R;G;B"; emits the literal \033[…m form
# so both `echo -e` and printf format strings interpret it, matching legacy usage.
_sgr() {
  [[ "$_tb_mode" == "none" ]] && return 0
  local codes
  if [[ "$_tb_mode" == "true" ]]; then
    if [[ "$_tb_bg" == "light" ]]; then codes="38;2;$2"; else codes="38;2;$1"; fi
  else
    codes="$3"
  fi
  [[ "$4" == "1" ]] && codes="${codes};1"
  [[ "$5" == "1" ]] && codes="${codes};4"
  printf '\\033[%sm' "$codes"
}

# Semantic tones (the same table as internal/ui/ui.go).
TB_HEADING="$(_sgr '1;165;204'  '1;99;122'   36 1 0)"  # cyan bold — structure/headings
TB_CMD="$(_sgr     '145;233;71' '87;140;43'  32 1 0)"  # lime bold — the thing to run
TB_DESC="$(_sgr    '167;237;108' '87;140;43' 32 0 0)"  # soft lime — supporting text
TB_LINK="$(_sgr    '1;165;204'  '1;99;122'   36 0 1)"  # cyan underline — destinations
TB_ACCENT="$(_sgr  '1;165;204'  '1;99;122'   36 0 0)"  # cyan — prompt guidance
TB_GO="$(_sgr      '145;233;71' '87;140;43'  32 0 0)"  # lime — ✔ / ● (good/go)
TB_WARN="$(_sgr    '255;198;43' '138;106;0'  33 0 0)"  # amber — ⚠
TB_ERR="$(_sgr     '246;76;76'  '192;39;31'  31 1 0)"  # red bold — ✖
TB_ERRSOFT="$(_sgr '246;76;76'  '192;39;31'  31 0 0)"  # red — ✗ offline
TB_LABEL="$(_sgr   '142;142;142' '107;107;107' 2 0 0)" # dim neutral — labels

# Structural (weight only) + reset — also honour the off switch.
if [[ "$_tb_mode" == "none" ]]; then
  BOLD=''; DIM=''; WHITE=''; RESET=''
else
  BOLD='\033[1m'; DIM='\033[2m'; WHITE='\033[1;37m'; RESET='\033[0m'
fi

# Legacy names, kept so untouched call sites still render on-brand AND honour the
# off switch: CYAN → cyan accent, GREEN → go/lime, YELLOW → warn, RED → error.
CYAN="$TB_ACCENT"; GREEN="$TB_GO"; YELLOW="$TB_WARN"; RED="$TB_ERRSOFT"

# ── Logging ──────────────────────────────────────────────────────────────────
#  info()          — supplementary detail shown to user (dim bullet)
#  success()       — completed item (green checkmark)
#  warn()          — non-blocking warning (yellow triangle)
#  error()         — fatal error (bold red cross, exits)
#  step()          — major step header: step <n> <total> "label"
#  log()           — debug only, writes to LOG_FILE, never shown to user
#  prompt_header() — bold label before user input prompts
#  hint()          — dim contextual help text
info()           { echo -e "  ${DIM}·${RESET} $*"; }
success()        { echo -e "  ${TB_GO}✔${RESET} $*"; }
warn()           { echo -e "  ${TB_WARN}⚠${RESET}  $*"; }
error()          { echo -e "  ${TB_ERR}✖ $*${RESET}" >&2; exit 1; }
step()           { echo -e "\n${TB_HEADING}Step $1/$2${RESET}  ${BOLD}$3${RESET}"; }
log()            { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null; return 0; }
prompt_header()  { echo -e "\n  ${BOLD}${WHITE}$*${RESET}"; }
hint()           { echo -e "  ${DIM}$*${RESET}"; }

# step_header LETTER TITLE — bold running header for one of the six install steps
# (a–f) in the first-run run-through, e.g. `step_header a "Checking your machine"`
# → "  a) Checking your machine". Prints the header + a single trailing blank; the
# blank-line gap BETWEEN steps comes from each step body ending with a blank line
# (main() adds it), matching the run-through's spacing.
step_header()    { echo -e "  ${TB_HEADING}$1) $2${RESET}"; echo ""; }

# ── Utility ──────────────────────────────────────────────────────────────────
has() { command -v "$1" &>/dev/null; }

# Strip ANSI escape sequences and C0 control characters from a value. A raw
# `read` captures whatever the terminal sends — this can include:
#   • bracketed-paste wrappers:  ESC[200~ ... ESC[201~
#   • arrow keys / cursor moves: ESC[A/B/C/D, ESC[1;5C, ESC[3~ (Delete), …
#   • function keys, modifier combos, mode-switch sequences
# All follow the ANSI CSI shape:  ESC '[' <params> <final-byte>
# where params ∈ [0-9;] and final ∈ [A-Za-z~]. Strip them iteratively to
# handle consecutive sequences (e.g. paste-wrappers).
#
# Also handles the post-corruption case where ESC was stripped by an earlier
# (buggy) sanitizer but the literal `[200~`/`[201~` markers survived. Only
# self-heals the two well-defined bracketed-paste markers — generic `[X]`
# shapes could plausibly be real password content.
#
# UTF-8 bytes (0x80+) preserved so international characters survive. Lives here
# (shared) so BOTH the credential path (install-client-helm.sh) and the client-
# name prompt (provision.sh) sanitize identically (customer-reported 2026-07-20).
_strip_paste_garbage() {
  local s="$1"
  local esc=$'\e'
  local csi_pattern="${esc}\\[[0-9;]*[A-Za-z~]"
  while [[ "$s" =~ $csi_pattern ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//\[200\~/}"
  s="${s//\[201\~/}"
  printf '%s' "$s" | tr -d '\000-\037\177'
}

# Best-effort chart version of the installed client release in namespace $1
# (e.g. "1.4.4"); empty if not found / cluster unreachable. Greps helm's CHART
# column ("client-<ver>"), so it needs no jq.
_chart_version() {
  local ns="${1:-${TB_NAMESPACE:-tracebloc}}"
  has helm || return 0
  # Trailing `|| true`: when no client-* release exists, `grep` exits 1 and, under
  # `set -o pipefail`, the pipeline (this function's last command) returns 1 —
  # which would abort callers that assign it under `set -e` (e.g. diagnose.sh).
  # The version (or empty) has already been emitted to stdout regardless.
  helm list -n "$ns" 2>/dev/null | grep -oE 'client-[0-9][^[:space:]]*' | head -1 | sed 's/^client-//' || true
}

# The client's core workload Deployments in namespace $1 — the set whose
# readiness DEFINES "the client is up". SINGLE SOURCE OF TRUTH: both
# wait_for_client_ready (summary.sh, the post-install readiness gate) and the
# installer's stop-and-check gate (assess.sh) consume this, so the two can never
# drift on what "ready" / "healthy" means. Echoes one Deployment name per line;
# `mysql-client` is fixed, the other two are release-namespace-prefixed.
_client_workload_deployments() {
  local ns="${1:-${TB_NAMESPACE:-default}}"
  printf '%s\n' "mysql-client" "${ns}-jobs-manager" "${ns}-requests-proxy"
}

# ── macOS: Docker Desktop architecture vs machine (for wrong-arch UX) ────────
#  Call early on macOS to fail fast with clear instructions if Docker.app
#  is for the wrong architecture (e.g. Intel Docker on Apple Silicon).
#  Returns 0 if OK or not applicable; returns 1 and prints message if mismatch.
check_docker_arch_mac() {
  [[ "$(uname -s)" != "Darwin" ]] && return 0
  [[ ! -d "/Applications/Docker.app" ]] && return 0

  local real_arch
  if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
    real_arch="arm64"
  else
    real_arch="amd64"
  fi

  # Main executable is com.docker.backend (CFBundleExecutable), not "Docker"
  local docker_bin_path="/Applications/Docker.app/Contents/MacOS/com.docker.backend"
  [[ ! -x "$docker_bin_path" ]] && docker_bin_path="/Applications/Docker.app/Contents/MacOS/Docker"
  local docker_bin_arch
  docker_bin_arch="$(file "$docker_bin_path" 2>/dev/null || true)"
  local docker_is_arm=false
  local docker_is_intel=false
  echo "$docker_bin_arch" | grep -q 'arm64' && docker_is_arm=true
  echo "$docker_bin_arch" | grep -q 'x86_64' && docker_is_intel=true

  if [[ "$real_arch" == "arm64" ]] && [[ "$docker_is_intel" == true ]] && [[ "$docker_is_arm" != true ]]; then
    echo ""
    warn "Docker is installed for the wrong chip (Intel instead of Apple Silicon)."
    hint "This can cause slow performance or prevent Docker from starting."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Re-run the installer — it will replace Docker with the correct version."
    echo ""
    return 1
  fi

  if [[ "$real_arch" == "amd64" ]] && [[ "$docker_is_arm" == true ]]; then
    echo ""
    warn "Docker is installed for the wrong chip (Apple Silicon instead of Intel)."
    hint "Docker may not work correctly."
    echo ""
    echo -e "  ${BOLD}Fix:${RESET} Re-run the installer — it will replace Docker with the correct version."
    echo ""
    return 1
  fi

  return 0
}

# ── Spinner — hides noisy command output behind an animated status line ──────
#  Usage:  spin <pid> "Installing foo…"
#  The background process's stdout/stderr should already be redirected to a file
#  before calling spin. spin waits for the PID to exit and returns its exit code.
spin() {
  local pid="$1" msg="$2"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0

  tput civis 2>/dev/null || true          # hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}%s${RESET} %s" "${frames[i]}" "$msg"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.12
  done

  wait "$pid"
  local rc=$?
  printf "\r\033[K"                       # clear the spinner line
  tput cnorm 2>/dev/null || true          # restore cursor
  return $rc
}

# ── Convenience wrapper: run a command quietly behind a spinner ───────────────
#  Usage:  spin_cmd "Installing foo…" brew install --cask docker
#  stdout/stderr are captured in the LOG_FILE (if set) or /tmp/tracebloc-spin.log
spin_cmd() {
  local msg="$1"; shift
  local logfile="${LOG_FILE:-/tmp/tracebloc-spin.log}"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  if ! spin "$pid" "$msg"; then
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    return 1
  fi
}

# ── Sudo preflight — warm the credential cache before spinners hide prompts ──
#  Call once at the start of install_macos / install_linux.  sudo -v caches
#  credentials for the default timeout (usually 5–15 min), so subsequent sudo
#  calls inside spin_cmd won't prompt interactively.
preflight_sudo() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # Step b intro copy (first-run run-through): one line, then the system's own
  # "Password:" prompt from `sudo -v`. Kept generic so it reads correctly on both
  # macOS (Docker Desktop) and Linux (Docker Engine + system packages).
  hint "tracebloc needs your password once to set up Docker and a few tools."
  echo ""
  sudo -v || error "Could not obtain administrator privileges. Re-run with a user that has sudo access."
  ( while sudo -n true 2>/dev/null; do sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}

# ── Download with live progress bar ───────────────────────────────────────────
#  Usage:  download_with_progress "https://…/file.dmg" "/tmp/file.dmg" "Downloading Docker Desktop"
#  Probes total size via HEAD, downloads in background, and monitors the growing
#  file to render a visual bar with percentage and MB counters.  Works on both
#  macOS and Linux without stdbuf or GNU coreutils.
download_with_progress() {
  local url="$1" dest="$2" label="$3"

  local total_bytes
  # -m bounds the HEAD probe so a stalled server can't hang it (it's not
  # retry-wrapped and its failure just means "no total" -> indeterminate bar).
  total_bytes=$(curl -fsSLI -m 15 "$url" 2>/dev/null \
    | awk 'tolower($0) ~ /content-length/ {gsub(/[^0-9]/,"",$2); print $2}' \
    | tail -1)

  local total_mb=""
  if [[ -n "$total_bytes" ]] && (( total_bytes > 0 )) 2>/dev/null; then
    total_mb=$(awk "BEGIN {printf \"%.0f\", $total_bytes / 1048576}")
    hint "${label} (${total_mb} MB)"
  else
    hint "$label"
    total_bytes=0
  fi

  local logfile="${LOG_FILE:-/tmp/tracebloc-spin.log}"
  rm -f "$dest"

  # --connect-timeout bounds the dial; --speed-limit/--speed-time abort a STALLED
  # transfer (<1 KB/s for 60s) without capping a legitimately slow-but-progressing
  # large download. Without these the backgrounded curl is monitored only by
  # `kill -0` (no deadline, no kill), so a slow-loris / mid-stream stall would
  # hang the progress loop forever.
  curl -fSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
    -o "$dest" "$url" >> "$logfile" 2>&1 &
  local curl_pid=$!

  local bar_width=30
  tput civis 2>/dev/null || true

  while kill -0 "$curl_pid" 2>/dev/null; do
    if [[ -f "$dest" ]] && (( total_bytes > 0 )); then
      local cur_bytes
      cur_bytes=$(wc -c < "$dest" 2>/dev/null || echo 0)
      cur_bytes=${cur_bytes// /}

      local pct=$(( cur_bytes * 100 / total_bytes ))
      (( pct > 100 )) && pct=100
      local filled=$(( pct * bar_width / 100 ))
      local empty=$(( bar_width - filled ))
      local cur_mb=$(awk "BEGIN {printf \"%.0f\", $cur_bytes / 1048576}")

      local bar=""
      for (( j=0; j<filled; j++ )); do bar+="█"; done
      for (( j=0; j<empty;  j++ )); do bar+="░"; done

      printf "\r  ${CYAN}%s${RESET} %3d%%  %s / %s MB" "$bar" "$pct" "$cur_mb" "$total_mb"
    fi
    sleep 0.4
  done

  wait "$curl_pid"
  local rc=$?

  if [[ $rc -eq 0 ]] && [[ -n "$total_mb" ]]; then
    local bar=""
    for (( j=0; j<bar_width; j++ )); do bar+="█"; done
    printf "\r  ${CYAN}%s${RESET} 100%%  %s / %s MB\n" "$bar" "$total_mb" "$total_mb"
  fi
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true
  return $rc
}

# ── Count bar — honest N-of-M progress for things pulled in discrete units ────
#  Usage:  count_bar <current> <total> [noun]      (renders ONE frame)
#  Draws a bar plus an "N of M <noun>" counter and NO newline, so a caller loop
#  can overwrite it in place (with \r) and clear it at the end via printf "\r\033[K".
#  Use this — never a fabricated aggregate percentage — for multi-image pulls
#  (e.g. the client's container images), where the only honest signal is how many
#  of a known count have completed. The %-by-bytes bar (download_with_progress) is
#  reserved for a single-file curl download, where a true byte percentage exists.
count_bar() {
  local cur="$1" total="$2" noun="${3:-items}" w=24 filled j bar=""
  [[ "$cur"   =~ ^[0-9]+$ ]] || cur=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=1
  (( total < 1 ))     && total=1
  (( cur > total ))   && cur=$total
  (( cur < 0 ))       && cur=0
  filled=$(( cur * w / total ))
  for (( j=0; j<filled; j++ )); do bar+="█"; done
  for (( j=filled; j<w;   j++ )); do bar+="░"; done
  printf "\r  ${CYAN}%s${RESET}  %d of %d %s" "$bar" "$cur" "$total" "$noun"
}

# ── Retry wrapper for flaky network calls ────────────────────────────────────
#  Usage:  retry 3 5 curl -fsSL https://example.com -o /tmp/file
#          retry <max_attempts> <delay_seconds> <command...>
retry() {
  local max_attempts="$1" delay="$2"; shift 2
  local attempt=1
  while true; do
    if "$@"; then return 0; fi
    if [[ $attempt -ge $max_attempts ]]; then
      warn "Command failed after $max_attempts attempts: $*"
      return 1
    fi
    warn "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
    sleep "$delay"
    ((attempt++))
  done
}

# ── Log file — captures all stdout/stderr alongside the terminal ─────────────
setup_log_file() {
  mkdir -p "$HOST_DATA_DIR"
  LOG_FILE="${HOST_DATA_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Install log: $LOG_FILE"
}

# ── Configuration (overridable via env) ──────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-tracebloc}"
SERVERS="${SERVERS:-1}"
AGENTS="${AGENTS:-1}"
# Pinned default; set K8S_VERSION="" to use latest (may break on new k3s releases)
K8S_VERSION="${K8S_VERSION:-v1.29.4-k3s1}"
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/.tracebloc}"
# Optional separate host dir for the big DATASET volume (backend#743). Empty
# (default) keeps datasets under HOST_DATA_DIR. When set — e.g. a network/NFS
# mount like /data01/tracebloc — the installer bind-mounts it into the cluster
# at /tracebloc-data and the chart's dataset PV points there, while mysql + logs
# stay on the local HOST_DATA_DIR (InnoDB over NFS is unsafe).
HOST_DATASET_DIR="${HOST_DATASET_DIR:-}"

# ── Input validation ────────────────────────────────────────────────────────
validate_config() {
  [[ -n "${HOME:-}" ]]  || error "\$HOME is not set — cannot determine user home directory"
  [[ -n "${USER:-}" ]]  || USER="$(whoami)" || error "Cannot determine current user"

  [[ "$CLUSTER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,62}$ ]] \
    || error "CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '$CLUSTER_NAME')"

  [[ "$SERVERS" =~ ^[1-9][0-9]*$ ]] || error "SERVERS must be a positive integer >= 1 (got '$SERVERS')"
  [[ "$AGENTS"  =~ ^[0-9]+$ ]]     || error "AGENTS must be a non-negative integer (got '$AGENTS')"

  # HOST_DATA_DIR must be under $HOME and must not be a system path (security)
  local dir="$HOST_DATA_DIR"
  [[ "$dir" != /* ]] && dir="$HOME/$dir"
  # Resolve via parent directory — the target itself may not exist yet on first run
  local parent
  parent="$(cd -P "$(dirname "$dir")" 2>/dev/null && pwd)" || true
  [[ -z "$parent" ]] && error "HOST_DATA_DIR parent directory could not be resolved: $(dirname "$dir")"
  dir="$parent/$(basename "$dir")"
  case "$dir" in
    /) error "HOST_DATA_DIR cannot be root (/)"
      ;;
    /etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64)
      error "HOST_DATA_DIR cannot be a system path: $dir"
      ;;
  esac
  [[ "$dir" != "$HOME" && "${dir#$HOME/}" == "$dir" ]] && \
    error "HOST_DATA_DIR must be under \$HOME (got: $HOST_DATA_DIR)"
  HOST_DATA_DIR="$dir"

  # Optional dataset dir (backend#743): unlike HOST_DATA_DIR it MAY live outside
  # $HOME (a mounted network volume like /data01). It must already EXIST and be
  # WRITABLE as the host user — we never mkdir a network-share root — and is
  # barred from system paths. The HOST_DATA_DIR rules above are unchanged.
  if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
    local ddir="$HOST_DATASET_DIR" rddir
    [[ "$ddir" == /* ]] || error "HOST_DATASET_DIR must be an absolute path (got '$HOST_DATASET_DIR')"
    [[ -d "$ddir" ]]    || error "HOST_DATASET_DIR does not exist: $ddir (mount the dataset volume before installing)"
    [[ -w "$ddir" ]]    || error "HOST_DATASET_DIR is not writable by $(id -un) (uid $(id -u)): $ddir"
    rddir="$(cd -P "$ddir" 2>/dev/null && pwd)" || error "HOST_DATASET_DIR could not be resolved: $ddir"
    case "$rddir" in
      /) error "HOST_DATASET_DIR cannot be root (/)" ;;
      /etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64)
        error "HOST_DATASET_DIR cannot be a system path: $rddir" ;;
    esac
    HOST_DATASET_DIR="$rddir"
  fi
}

# ── Runtime globals ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
# On macOS, override ARCH with real hardware to avoid Rosetta misdetection
if [[ "$OS" == "Darwin" ]] && sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
  ARCH="arm64"
fi
[[ "$ARCH" == "x86_64" ]] && ARCH_DL="amd64" || ARCH_DL="arm64"

GPU_VENDOR="none"          # nvidia | amd | apple_silicon | none
NVIDIA_DRIVER_OK=false
K3D_GPU_FLAGS=()           # extra flags appended to k3d cluster create
PM_INSTALL=""
PM_UPDATE=""

# ── Cleanup on exit ──────────────────────────────────────────────────────────
install_cleanup() {
  local exit_code=$?
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  # Never leave the transient machine credential on disk (#838): provision.sh sets
  # _PROVISION_CRED_FILE before minting and removes it after sourcing — this is the
  # backstop for an error/signal between mint and that cleanup.
  [[ -n "${_PROVISION_CRED_FILE:-}" ]] && rm -f "$_PROVISION_CRED_FILE" 2>/dev/null || true
  if [[ $exit_code -eq 2 ]]; then
    echo ""
    if [[ -n "${TRACEBLOC_DOCKER_FIRST_RUN_EXIT:-}" ]]; then
      hint "Docker first-time setup: complete the steps above, then run the script again."
    else
      hint "Re-run required. Complete the step above, then run the script again."
    fi
    [[ -n "${LOG_FILE:-}" ]] && hint "Logs: $LOG_FILE"
  elif [[ $exit_code -ne 0 ]]; then
    # If print_summary already reported a specific outcome (CLIENT_STATE set),
    # don't tack on a second, generic "did not complete" message.
    if [[ -z "${CLIENT_STATE:-}" ]]; then
      echo ""
      warn "Installation did not complete."
      [[ -n "${LOG_FILE:-}" ]] && hint "Check the install log: $LOG_FILE"
      hint "This installer is safe to re-run — just try again."
    fi
  fi
}

# Installer version shown in the banner's title (" · <version>"). The curl|bash
# bootstrap (install.sh) exports TRACEBLOC_INSTALL_REF — the immutable release tag
# it pinned to, e.g. v1.9.3 — so the title states exactly what is being installed.
# On the direct ./install-k8s.sh path it's unset and the title drops the suffix.
TB_VERSION="${TB_VERSION:-${TRACEBLOC_INSTALL_REF:-}}"

# ── Banner ───────────────────────────────────────────────────────────────────
#  The first-run title: "Setting up tracebloc on your machine · <version>".
#  In the curl|bash path the bootstrap (install.sh) already drew this above its
#  "1. Downloading" section and exported TRACEBLOC_BANNER_SHOWN, so we don't draw
#  a second one; on the direct ./install-k8s.sh path we draw it here.
print_banner() {
  if [[ -n "${TRACEBLOC_BANNER_SHOWN:-}" ]]; then
    log "Banner already shown by the bootstrap — not redrawing."
    log "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
    return 0
  fi
  echo ""
  echo ""
  if [[ -n "${TB_VERSION:-}" ]]; then
    echo -e "  Setting up ${BOLD}${CYAN}tracebloc${RESET} on your machine${DIM} · ${TB_VERSION}${RESET}"
  else
    echo -e "  Setting up ${BOLD}${CYAN}tracebloc${RESET} on your machine"
  fi
  echo ""
  echo -e "  ${DIM}────────────────────────────────────────${RESET}"
  echo ""
  log "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
  log "Host data dir: $HOST_DATA_DIR → /tracebloc (inside k3s nodes)"
}

# ── Step roadmap — the "2. Installing" plan, printed once before install begins ─
#  Section 1 ("1. Downloading") is the bootstrap's download+verify; this is the
#  a–f plan for everything install-k8s.sh does. The running steps use the gerund
#  form ("Checking your machine", …) via step_header.
print_roadmap() {
  echo -e "  ${BOLD}2. Installing${RESET}"
  echo ""
  echo -e "  ${DIM}a) Check your machine${RESET}"
  echo -e "  ${DIM}b) Install what tracebloc needs${RESET}"
  echo -e "  ${DIM}c) Create your secure environment${RESET}"
  echo -e "  ${DIM}d) Register this machine${RESET}"
  echo -e "  ${DIM}e) Install tracebloc${RESET}"
  echo -e "  ${DIM}f) Connect to the tracebloc network${RESET}"
  echo ""
  echo ""
}

# ── Help ─────────────────────────────────────────────────────────────────────
print_help() {
  cat <<'HELP'
tracebloc — client setup

  Set up a secure compute environment on your machine
  and connect it to the tracebloc network.

Usage:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
  ./install-k8s.sh [--help] [--diagnose] [--force]

Commands:
  --diagnose     Collect a redacted support bundle (logs + cluster/host status)
                 into ~/.tracebloc/tracebloc-diagnose-<timestamp>.tgz and exit.
                 Run this if something went wrong, then send the file to support
                 (passwords and proxy credentials are removed before it is written).
  --force        Skip the "already set up" check and re-run every step. Use this
  --reinstall    to force a full reinstall on a machine that is already set up.
                 (Same effect as TRACEBLOC_FORCE_REINSTALL=1 for curl | bash.)

Advanced configuration (environment variables):
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  TB_NAMESPACE   Namespace / workspace label    (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag                   (default: v1.29.4-k3s1)
  HOST_DATA_DIR  Persistent data directory       (default: ~/.tracebloc)
                 Must be on a LOCAL disk — NFS/CIFS/SMB is rejected (the database
                 corrupts on network storage). TRACEBLOC_ALLOW_NETWORK_FS=1 overrides.

Windows:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex

Learn more: https://docs.tracebloc.io
HELP
  exit 0
}
