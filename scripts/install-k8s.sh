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
#    TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"  CPU/RAM each training run
#                                may use (default cpu=2,memory=8Gi; sets requests==limits)
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
# install-cli.sh may be absent if an older bootstrap copy (e.g. a not-yet-
# updated tracebloc.io/i.sh, whose FILES list is hand-maintained) didn't fetch
# it. Guard the source so a stale bootstrap degrades gracefully (Step 5 is
# skipped) instead of aborting the whole installer under `set -e`. Use an `if`
# block, NOT `[[ -f … ]] && source` — a false `&&` test trips `set -e`.
if [[ -f "${LIB_DIR}/install-cli.sh" ]]; then
  source "${LIB_DIR}/install-cli.sh"
fi
# provision.sh (the #838 sign-in + client-create-before-Helm step) likewise may be
# absent under a stale bootstrap — guard so the installer degrades to the dual-mode
# credential path rather than aborting under `set -e`.
if [[ -f "${LIB_DIR}/provision.sh" ]]; then
  source "${LIB_DIR}/provision.sh"
fi
source "${LIB_DIR}/summary.sh"
source "${LIB_DIR}/diagnose.sh"

trap install_cleanup EXIT
# Route SIGINT/SIGTERM through a normal exit so the EXIT trap (install_cleanup)
# always runs — it shreds the transient machine credential (#838). Without these,
# a Ctrl-C in the brief mint→source window could leave the 0600 secret on disk.
trap 'exit 130' INT
trap 'exit 143' TERM

# ── Main ─────────────────────────────────────────────────────────────────────
#  Structured as the six-step first-run run-through (a–f). Each step prints a
#  gerund header via step_header and a trailing blank-line pair (the run-through's
#  spacing); print_roadmap lists the plan up front. Step b owns the prerequisites
#  AND the tracebloc CLI (moved out of provisioning — step d needs it to sign in).
main() {
  [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && print_help
  # Support bundle: collect redacted diagnostics and exit, before any install
  # work (so it works even when the install is broken). Clear the EXIT trap so
  # the post-install cleanup message doesn't fire after a diagnose run.
  [[ "${1:-}" == "--diagnose" ]] && { trap - EXIT; run_diagnose; exit $?; }

  validate_config
  setup_log_file
  print_banner

  # ── Stop-and-check gate — SLOT for client#339 (do NOT implement here) ─────
  # After the banner, before the roadmap: client#339 adds a READ-ONLY assessment
  # (assess.sh::assess_existing_install) that short-circuits an already-healthy
  # machine straight to the `tracebloc` home screen and exits 0, so a plain re-run
  # doesn't repeat every step. The gate LOGIC lives in that branch's assess.sh
  # (plus its --force/--reinstall / TRACEBLOC_FORCE_REINSTALL bypass) — this is
  # only the call site, left here so the two changes reconcile cleanly. The call
  # is a guarded NO-OP until assess.sh ships (declare -F is false), so nothing
  # changes on this branch. NOTE: the bootstrap (install.sh) already performs the
  # pre-download `tracebloc doctor` bailout; this is the deeper post-download check.
  if declare -F assess_existing_install >/dev/null 2>&1; then
    assess_existing_install
  fi

  print_roadmap

  # ── a) Check your machine ────────────────────────────────────────────────
  step_header a "Checking your machine"
  run_preflight
  detect_gpu
  echo ""; echo ""

  # ── b) Install what tracebloc needs ──────────────────────────────────────
  #     Prerequisites (Docker + system tools) AND the tracebloc CLI. The CLI moved
  #     here from provisioning: step d (provision_client) needs it to sign in and
  #     mint the credential, so it must exist before then. install_tracebloc_cli is
  #     non-fatal on its own; step d's `has tracebloc` guard makes a genuinely
  #     missing CLI fatal at the point it's actually required.
  step_header b "Installing what tracebloc needs"
  case "$OS" in
    Darwin)   install_macos ;;
    Linux)    install_linux ;;
    MINGW*|MSYS*|CYGWIN*)
      error "Windows detected. Use PowerShell instead:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex" ;;
    *)        error "Unsupported OS: $OS" ;;
  esac
  # Guarded: a stale bootstrap may not have fetched install-cli.sh — then step d's
  # guard (or install_client_helm's dual-mode path) surfaces it.
  if declare -F install_tracebloc_cli >/dev/null 2>&1; then
    install_tracebloc_cli
  fi
  echo ""; echo ""

  # ── c) Create your secure environment ────────────────────────────────────
  step_header c "Creating your secure environment"
  create_cluster
  deploy_gpu_device_plugin
  verify_gpu
  echo ""; echo ""

  # ── d) Register this machine ─────────────────────────────────────────────
  #     Sign in + `client create` BEFORE Helm, so the minted credential + derived
  #     namespace feed the chart (#838). Dual-mode (TRACEBLOC_VALUES_FILE / pre-
  #     supplied credentials) skips sign-in. Guarded so a stale bootstrap that
  #     didn't fetch provision.sh degrades to the dual-mode credential path inside
  #     install_client_helm rather than aborting.
  step_header d "Registering this machine"
  if declare -F provision_client >/dev/null 2>&1; then
    provision_client
  fi
  echo ""; echo ""

  # ── e) Install tracebloc ─────────────────────────────────────────────────
  step_header e "Installing tracebloc"
  install_client_helm
  echo ""; echo ""

  # ── f) Connect to the tracebloc network ──────────────────────────────────
  #     Wait for the client's workloads to actually come up, then the rich summary.
  step_header f "Connecting to the tracebloc network"
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
