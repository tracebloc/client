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
#    TRACEBLOC_FORCE_REINSTALL=1  skip the "already set up" stop-and-check gate
#                                and re-run every step (same as --force/--reinstall)
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
# assess.sh (the stop-and-check gate) may likewise be absent under a stale
# bootstrap that didn't fetch it — guard the source so the installer simply runs
# the full flow (no gate) instead of aborting under `set -e`. An `if` block, not
# `[[ -f … ]] && source`, so a false test doesn't trip `set -e`.
if [[ -f "${LIB_DIR}/assess.sh" ]]; then
  source "${LIB_DIR}/assess.sh"
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
main() {
  [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && print_help
  # Support bundle: collect redacted diagnostics and exit, before any install
  # work (so it works even when the install is broken). Clear the EXIT trap so
  # the post-install cleanup message doesn't fire after a diagnose run.
  [[ "${1:-}" == "--diagnose" ]] && { trap - EXIT; run_diagnose; exit $?; }

  # Run-modifying flags (unlike --help/--diagnose, which are terminal). --force /
  # --reinstall skips the stop-and-check gate below and re-runs every step. Also
  # honored via TRACEBLOC_FORCE_REINSTALL=1 for the curl|bash path (assess.sh
  # seeds that default; here we let the flag override it).
  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      --force|--reinstall) TB_FORCE_REINSTALL=1 ;;
    esac
  done

  validate_config
  setup_log_file
  print_banner

  # ── Stop-and-check gate ──────────────────────────────────────────────────
  # A re-run on an already-set-up machine must not re-run full provisioning.
  # assess_existing_install inspects the machine READ-ONLY: a verifiably healthy
  # box is handed straight to the `tracebloc` home screen and exits 0; a fresh or
  # half-set-up box falls through to the normal flow below. Guarded so a stale
  # bootstrap that didn't fetch assess.sh — or --force/--reinstall — simply runs
  # the full flow.
  if [[ "${TB_FORCE_REINSTALL:-0}" != 1 ]] && declare -F assess_existing_install >/dev/null 2>&1; then
    assess_existing_install
  fi

  print_roadmap

  # ── Step 1/5: Check system requirements ──────────────────────────────────
  step 1 5 "Checking system requirements"
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

  # ── Step 2/5: Set up secure compute environment ──────────────────────────
  step 2 5 "Setting up secure compute environment"
  create_cluster
  deploy_gpu_device_plugin
  verify_gpu

  # ── Step 3/5: sign in + provision the client (install CLI, login, client
  #    create) BEFORE Helm, so the minted credential + derived namespace feed the
  #    chart (#838). On the dual-mode path (TRACEBLOC_VALUES_FILE / pre-supplied
  #    credentials) this skips sign-in. Guarded so a stale bootstrap that didn't
  #    fetch provision.sh degrades to the dual-mode credential path rather than
  #    aborting; in that case the operator must supply credentials/values. ──────
  if declare -F provision_client >/dev/null 2>&1; then
    provision_client
  elif declare -F install_tracebloc_cli >/dev/null 2>&1; then
    # Stale bootstrap: provision.sh wasn't fetched, but install-cli.sh was. Keep
    # the old post-Helm Step 5 behavior so the CLI still gets installed (non-fatal,
    # for `tracebloc data ingest`); provisioning then falls through to the dual-mode
    # credential path inside install_client_helm.
    install_tracebloc_cli
  fi

  # ── Step 4/5 + 5/5 are handled inside install_client_helm ────────────────
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
