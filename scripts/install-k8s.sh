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
#    TB_NAMESPACE=myns           default: tracebloc  (k8s namespace + local label;
#                                not prompted — the client is identified by its credentials)
#    SERVERS=1                   default: 1  (control-plane nodes)
#    AGENTS=1                    default: 1  (worker nodes)
#    K8S_VERSION=v1.29.4-k3s1   default: latest stable k3s
#    HOST_DATA_DIR=~/.tracebloc  default: ~/.tracebloc
#    CLIENT_ENV=dev              optional; if not set, CLIENT_ENV is not added to env in values
#    TRACEBLOC_SKIP_REBOOT_PROMPT=1 (Linux) skip "Reboot now?" after NVIDIA driver install
# =============================================================================

set -euo pipefail

# ── Resolve script directory (works with symlinks and macOS BSD readlink) ────
_realpath() {
  local target="$1"
  while [[ -L "$target" ]]; do
    local dir; dir="$(cd "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" != /* ]] && target="$dir/$target"
  done
  echo "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
}
SCRIPT_DIR="$(dirname "$(_realpath "$0")")"
LIB_DIR="${SCRIPT_DIR}/lib"

# ── Source modules ───────────────────────────────────────────────────────────
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/preflight.sh"
source "${LIB_DIR}/detect-gpu.sh"
source "${LIB_DIR}/gpu-nvidia.sh"
source "${LIB_DIR}/gpu-amd.sh"
source "${LIB_DIR}/setup-macos.sh"
source "${LIB_DIR}/setup-linux.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/gpu-plugins.sh"
source "${LIB_DIR}/install-client-helm.sh"
source "${LIB_DIR}/summary.sh"
source "${LIB_DIR}/diagnose.sh"

trap install_cleanup EXIT

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && print_help
  # Support bundle: collect redacted diagnostics and exit, before any install
  # work (so it works even when the install is broken). Clear the EXIT trap so
  # the post-install cleanup message doesn't fire after a diagnose run.
  [[ "${1:-}" == "--diagnose" ]] && { trap - EXIT; run_diagnose; exit $?; }

  validate_config
  setup_log_file
  print_banner
  print_roadmap

  # ── Step 1/4: Check system requirements ──────────────────────────────────
  step 1 4 "Checking system requirements"
  run_preflight
  detect_gpu

  case "$OS" in
    Darwin)   install_macos ;;
    Linux)    install_linux ;;
    MINGW*|MSYS*|CYGWIN*)
      error "Windows detected. Use PowerShell instead:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex" ;;
    *)        error "Unsupported OS: $OS" ;;
  esac

  # ── Step 2/4: Set up secure compute environment ──────────────────────────
  step 2 4 "Setting up secure compute environment"
  create_cluster
  deploy_gpu_device_plugin
  verify_gpu

  # ── Step 3/4 + 4/4 are handled inside install_client_helm ────────────────
  install_client_helm

  # ── Verify the client actually came up before reporting anything ─────────
  wait_for_client_ready
  print_summary

  # Exit code reflects reality: connected/starting are OK; failures are non-zero
  # so re-runs and automation can tell the difference.
  case "${CLIENT_STATE:-}" in
    connected|starting) ;;
    *) exit 1 ;;
  esac
}

main "$@"
