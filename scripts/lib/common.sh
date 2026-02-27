#!/usr/bin/env bash
# =============================================================================
#  common.sh — Shared colours, logging helpers, configuration defaults,
#              retry logic, and log-file setup
# =============================================================================

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ── Utility ──────────────────────────────────────────────────────────────────
has() { command -v "$1" &>/dev/null; }

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
  spin $! "$msg"
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
  info "This installer needs administrator privileges to set up system tools."
  echo -e "  ${BOLD}You may be prompted for your macOS/Linux password below.${RESET}"
  echo ""
  sudo -v || error "Could not obtain administrator privileges. Re-run with a user that has sudo access."
  # Keep the credential cache alive in the background for long installs
  ( while sudo -n true 2>/dev/null; do sleep 50; done ) &
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
  info "Install log: $LOG_FILE"
}

# ── Configuration (overridable via env) ──────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-tracebloc}"
SERVERS="${SERVERS:-1}"
AGENTS="${AGENTS:-1}"
K8S_VERSION="${K8S_VERSION:-}"           # empty = latest stable
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/.tracebloc}"

# ── Input validation ────────────────────────────────────────────────────────
validate_config() {
  [[ "$SERVERS" =~ ^[0-9]+$ ]] || error "SERVERS must be a positive integer (got '$SERVERS')"
  [[ "$AGENTS"  =~ ^[0-9]+$ ]] || error "AGENTS must be a positive integer (got '$AGENTS')"
  [[ "$HTTP_PORT"  =~ ^[0-9]+$ ]] || error "HTTP_PORT must be a number (got '$HTTP_PORT')"
  [[ "$HTTPS_PORT" =~ ^[0-9]+$ ]] || error "HTTPS_PORT must be a number (got '$HTTPS_PORT')"
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

# ── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "\n${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║   Kubernetes (k3d/k3s) + GPU  One-Command Installer           ║${RESET}"
  echo -e "${BOLD}║   macOS & Linux                                               ║${RESET}"
  echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
  info "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
  info "Host data dir: $HOST_DATA_DIR → /tracebloc (inside k3s nodes)"
}

# ── Help ─────────────────────────────────────────────────────────────────────
print_help() {
  cat <<'HELP'
Usage:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
  ./install-k8s.sh [--help]

Environment variable overrides:
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag (empty = latest)  (default: "")
  HTTP_PORT      Host HTTP  ingress port         (default: 80)
  HTTPS_PORT     Host HTTPS ingress port         (default: 443)
  HOST_DATA_DIR  Persistent data directory       (default: ~/.tracebloc)

Windows:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
HELP
  exit 0
}
