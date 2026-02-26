#!/usr/bin/env bash
# =============================================================================
#  common.sh — Shared colours, logging helpers, and configuration defaults
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

# ── Configuration (overridable via env) ──────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-k3s-local}"
SERVERS="${SERVERS:-1}"
AGENTS="${AGENTS:-1}"
K8S_VERSION="${K8S_VERSION:-}"           # empty = latest stable
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/.tracebloc}"

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
