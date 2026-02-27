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
