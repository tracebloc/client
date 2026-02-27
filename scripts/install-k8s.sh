#!/usr/bin/env bash
# =============================================================================
#  install-k8s.sh  —  One-command Kubernetes + GPU installer  (macOS & Linux)
#
#  Engine  : k3d  (k3s inside Docker — lightweight, prod-topology capable)
#  GPUs    : NVIDIA (Linux)  ✓     AMD (Linux) ✓     macOS passthrough ✗
#
#  Usage (macOS / Linux):
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
#    -- OR --
#    chmod +x install-k8s.sh && ./install-k8s.sh
#
#  Windows (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
#
#  Environment variable overrides (optional):
#    CLUSTER_NAME=myapp          default: tracebloc
#    SERVERS=1                   default: 1  (control-plane nodes)
#    AGENTS=1                    default: 1  (worker nodes)
#    K8S_VERSION=v1.29.4-k3s1   default: latest stable k3s
#    HTTP_PORT=80                default: 80   (host → cluster ingress)
#    HTTPS_PORT=443              default: 443
#    HOST_DATA_DIR=~/.tracebloc  default: ~/.tracebloc
# =============================================================================

set -euo pipefail

# ── Resolve script directory (works with symlinks too) ───────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ── Source modules ───────────────────────────────────────────────────────────
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/detect-gpu.sh"
source "${LIB_DIR}/gpu-nvidia.sh"
source "${LIB_DIR}/gpu-amd.sh"
source "${LIB_DIR}/setup-macos.sh"
source "${LIB_DIR}/setup-linux.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/gpu-plugins.sh"
source "${LIB_DIR}/summary.sh"

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && print_help

  validate_config
  setup_log_file
  print_banner
  detect_gpu

  case "$OS" in
    Darwin)   install_macos ;;
    Linux)    install_linux ;;
    MINGW*|MSYS*|CYGWIN*)
      error "Windows detected. Use PowerShell instead:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex" ;;
    *)        error "Unsupported OS: $OS" ;;
  esac

  create_cluster
  deploy_gpu_device_plugin
  verify_gpu
  verify_cluster
  print_summary
}

main "$@"
