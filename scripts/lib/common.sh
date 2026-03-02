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
  local pid=$!
  if ! spin "$pid" "$msg"; then
    echo -e "${RED}[FAIL]${RESET} $msg" >&2
    echo "  Last 10 lines of log:" >&2
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
  info "This installer needs administrator privileges to set up system tools."
  echo -e "  ${BOLD}You may be prompted for your macOS/Linux password below.${RESET}"
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
    info "${label} (${total_mb} MB)"
  else
    info "$label"
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
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    warn "Installation failed (exit code: $exit_code)."
    [[ -n "${LOG_FILE:-}" ]] && warn "Check the install log: $LOG_FILE"
    warn "This installer is safe to re-run — just try again."
  fi
}

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
