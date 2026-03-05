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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'
WHITE='\033[1;37m'; RESET='\033[0m'

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
success()        { echo -e "  ${GREEN}✔${RESET} $*"; }
warn()           { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error()          { echo -e "  ${RED}${BOLD}✖ $*${RESET}" >&2; exit 1; }
step()           { echo -e "\n${BOLD}${CYAN}Step $1/$2${RESET}  ${BOLD}$3${RESET}"; }
log()            { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null; return 0; }
prompt_header()  { echo -e "\n  ${BOLD}${WHITE}$*${RESET}"; }
hint()           { echo -e "  ${DIM}$*${RESET}"; }

# ── Utility ──────────────────────────────────────────────────────────────────
has() { command -v "$1" &>/dev/null; }

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
  echo ""
  prompt_header "Tracebloc needs administrator permissions to install"
  hint "Docker and system dependencies."
  echo ""
  hint "You may be asked for your password once."
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
  total_bytes=$(curl -fsSLI "$url" 2>/dev/null \
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

  curl -fSL -o "$dest" "$url" >> "$logfile" 2>&1 &
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
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/.tracebloc}"

# ── Input validation ────────────────────────────────────────────────────────
validate_config() {
  [[ -n "${HOME:-}" ]]  || error "\$HOME is not set — cannot determine user home directory"
  [[ -n "${USER:-}" ]]  || USER="$(whoami)" || error "Cannot determine current user"

  [[ "$CLUSTER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,62}$ ]] \
    || error "CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '$CLUSTER_NAME')"

  [[ "$SERVERS" =~ ^[1-9][0-9]*$ ]] || error "SERVERS must be a positive integer >= 1 (got '$SERVERS')"
  [[ "$AGENTS"  =~ ^[0-9]+$ ]]     || error "AGENTS must be a non-negative integer (got '$AGENTS')"

  [[ "$HTTP_PORT" =~ ^[0-9]+$ ]]  || error "HTTP_PORT must be a number (got '$HTTP_PORT')"
  [[ "$HTTPS_PORT" =~ ^[0-9]+$ ]] || error "HTTPS_PORT must be a number (got '$HTTPS_PORT')"
  (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 ))   || error "HTTP_PORT must be 1-65535 (got '$HTTP_PORT')"
  (( HTTPS_PORT >= 1 && HTTPS_PORT <= 65535 )) || error "HTTPS_PORT must be 1-65535 (got '$HTTPS_PORT')"
  (( HTTP_PORT != HTTPS_PORT )) || error "HTTP_PORT and HTTPS_PORT must be different (both set to $HTTP_PORT)"

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
  if [[ $exit_code -eq 2 ]]; then
    echo ""
    if [[ -n "${TRACEBLOC_DOCKER_FIRST_RUN_EXIT:-}" ]]; then
      hint "Docker first-time setup: complete the steps above, then run the script again."
    else
      hint "Re-run required. Complete the step above, then run the script again."
    fi
    [[ -n "${LOG_FILE:-}" ]] && hint "Logs: $LOG_FILE"
  elif [[ $exit_code -ne 0 ]]; then
    echo ""
    warn "Installation did not complete."
    [[ -n "${LOG_FILE:-}" ]] && hint "Check the install log: $LOG_FILE"
    hint "This installer is safe to re-run — just try again."
  fi
}

# ── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
  echo ""
  echo -e "  ${BOLD}${CYAN}tracebloc${RESET} — client setup"
  echo -e "  ${DIM}────────────────────────────────────────${RESET}"
  echo ""
  echo -e "  Test AI models from external vendors on your"
  echo -e "  infrastructure — without exposing your data."
  echo ""
  echo -e "  ${DIM}This installer sets up a secure compute environment${RESET}"
  echo -e "  ${DIM}on your machine and connects it to the tracebloc network.${RESET}"
  echo ""
  echo -e "  ${DIM}Nothing will be modified outside:${RESET}"
  echo -e "  ${DIM}  ~/.tracebloc/    (data and config)${RESET}"
  echo -e "  ${DIM}  Docker           (container runtime)${RESET}"
  echo ""
  log "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
  log "Host data dir: $HOST_DATA_DIR → /tracebloc (inside k3s nodes)"
}

# ── Step roadmap — printed once before install begins ─────────────────────────
print_roadmap() {
  echo -e "  ${BOLD}Steps${RESET}"
  echo -e "  ${DIM}─────${RESET}"
  echo -e "  ${DIM}1. Check system requirements${RESET}"
  echo -e "  ${DIM}2. Set up secure compute environment${RESET}"
  echo -e "  ${DIM}3. Install tracebloc client${RESET}"
  echo -e "  ${DIM}4. Connect to tracebloc network${RESET}"
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
  ./install-k8s.sh [--help]

Advanced configuration (environment variables):
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag                   (default: v1.29.4-k3s1)
  HTTP_PORT      Host HTTP  port                 (default: 80)
  HTTPS_PORT     Host HTTPS port                 (default: 443)
  HOST_DATA_DIR  Persistent data directory       (default: ~/.tracebloc)

Windows:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex

Learn more: https://docs.tracebloc.io
HELP
  exit 0
}
