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
#    K8S_VERSION=v1.36.3-k3s1   default: v1.36.3-k3s1 (pinned + validated; "latest" is UNSUPPORTED — see #547)
#    K3D_VERSION=v5.9.0          default: v5.9.0  (k3d release tag; "latest" resolves at install time)
#    HOST_DATA_DIR=~/.tracebloc  default: ~/.tracebloc
#    TB_STORAGE_MODE=hostpath    default: node-local  (RFC-0003 Option C; D15 flip, client#456)
#                                node-local (default) stores datasets on k3s local-path
#                                INSIDE the node — no ~/.tracebloc host dirs, wiped on
#                                cluster delete; forces AGENTS=0/SERVERS=1 (single-node).
#                                Set TB_STORAGE_MODE=hostpath to keep datasets in
#                                ~/.tracebloc on the host (survive cluster delete;
#                                required for a HOST_DATASET_DIR network mount).
#                                Linux/k3s path only — install-k8s.ps1 is hostpath-only.
#    CLIENT_ENV=dev              optional; if not set, CLIENT_ENV is not added to env in values
#    TRACEBLOC_FORCE_REINSTALL=1  skip the "already set up" stop-and-check gate
#                                and re-run every step (same as --force/--reinstall)
#    TB_LEFTOVER_ACTION=reuse|wipe  non-interactive answer to the leftover-data
#                                guard (#376) — same as --reuse-data / --wipe-data.
#                                A new install onto a machine that still holds old
#                                data STOPS and asks by default rather than
#                                silently adopting it; a fresh HOST_DATA_DIR (or
#                                --data-dir=PATH) sidesteps the prompt.
#    TRACEBLOC_SKIP_LEFTOVER_GUARD=1  bypass the leftover-data guard entirely
#    TRACEBLOC_SKIP_REBOOT_PROMPT=1 (Linux) skip "Reboot now?" after NVIDIA driver install
#    TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"  CPU/RAM each training run
#                                may use (sized to the machine, else the contract
#                                floor cpu=1,memory=2Gi; sets requests==limits)
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
# telemetry.sh (backend#1907) is sourced right after common.sh so the install
# clock starts before any work does, and so common.sh's step_header /
# install_cleanup hooks find their functions. Guarded like the other late
# additions: an older bootstrap (e.g. a not-yet-updated tracebloc.io/i.sh, whose
# FILES list is hand-maintained) may not have fetched it, and an installer that
# aborted because it could not report on itself would be a poor trade.
if [[ -f "${LIB_DIR}/telemetry.sh" ]]; then
  source "${LIB_DIR}/telemetry.sh"
fi
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
# probe.sh (RFC 0001 host capability/privilege audit) may likewise be absent
# under a stale bootstrap that didn't fetch it — guard the source so `--diagnose`
# simply omits the install-tier section instead of aborting under `set -e`.
if [[ -f "${LIB_DIR}/probe.sh" ]]; then
  source "${LIB_DIR}/probe.sh"
fi
source "${LIB_DIR}/summary.sh"
source "${LIB_DIR}/diagnose.sh"

trap install_cleanup EXIT
# Record the site of the first failing command (client#681). `set -E` (errtrace)
# is what makes this useful: without it an ERR trap fires only at top level, so
# every failure inside install_macos / install_linux — i.e. nearly all of them —
# stayed invisible, and the user got a generic closer over an empty log.
# _record_err is the trap's FIRST command so `$?` is still the failure's status;
# the location is passed in because BASH_SOURCE/LINENO inside the recorder would
# describe common.sh. Recording only — it never alters control flow.
set -E
trap '_record_err "${BASH_SOURCE[0]:-?}:${LINENO}" "$BASH_COMMAND"' ERR
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

  # prepare-host: the standalone, admin-run Tier-2 step (RFC 0001 #1178) —
  # installs the privileged prerequisites so a researcher can then install
  # unprivileged at Tier 0, and grants them docker-group access. Terminal like
  # --diagnose (never provisions as the admin); clear the EXIT trap so no
  # post-install cleanup message fires. Accept both the bootstrap positional
  # (`… | bash -s -- prepare-host`) and the direct flag, AT ANY POSITION —
  # install.sh's bailout exemption scans all args, so a run like
  # `--force prepare-host` must dispatch here too, never fall through into a
  # (forced) full provision as the admin (Bugbot r4).
  local _a_ph
  for _a_ph in "$@"; do
    [[ "$_a_ph" == "prepare-host" || "$_a_ph" == "--prepare-host" ]] || continue
    # Replace the full install_cleanup (its credential-shred + "did not complete"
    # messaging don't apply to a host-prep run) with a lightweight reaper that
    # still tears down the sudo keepalive preflight_sudo starts — otherwise it
    # orphans a background loop polling `sudo` every 50s (Bugbot #377).
    trap 'if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fi' EXIT
    setup_log_file
    if declare -F run_prepare_host >/dev/null 2>&1; then
      run_prepare_host; exit $?
    fi
    error "This installer build doesn't include prepare-host (stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host"
  done

  # Past this line the run is committed to installing, so it is the one that
  # produces an outcome event (backend#1907). Everything above is terminal and
  # touches nothing: --help exits 0, --diagnose clears the EXIT trap, and
  # prepare-host swaps it for a lightweight reaper. Without this latch, a
  # `--help` emitted install.run.succeeded and inflated the denominator of the
  # failure rate the ticket exists to produce (Bugbot, client#747).
  #
  # NOT covered, deliberately: prepare-host. It is a different command with its
  # own registry component (§10.1 gives `installer` the components install /
  # preflight / upgrade), and reporting it as tracebloc.component=install would
  # be mislabelling it rather than measuring it.
  if declare -F telemetry_run_started >/dev/null 2>&1; then
    telemetry_run_started
  fi

  # Run-modifying flags (unlike --help/--diagnose, which are terminal). --force /
  # --reinstall skips the stop-and-check gate below and re-runs every step. Also
  # honored via TRACEBLOC_FORCE_REINSTALL=1 for the curl|bash path (assess.sh
  # seeds that default; here we let the flag override it).
  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      --force|--reinstall) TB_FORCE_REINSTALL=1 ;;
      # Leftover-data guard (#376): non-interactive answers to the reuse/wipe/
      # new-dir prompt. --data-dir=PATH just points HOST_DATA_DIR elsewhere
      # (validate_config resolves it below), so a fresh dir sidesteps the prompt.
      --reuse-data) TB_LEFTOVER_ACTION=reuse ;;
      --wipe-data)  TB_LEFTOVER_ACTION=wipe ;;
      --data-dir=*) HOST_DATA_DIR="${_arg#*=}" ;;
    esac
  done

  # Refuse a sudo-wrapped full run BEFORE any file is created (#427): running the
  # whole install as root grants Docker to root and root-owns the user's ~/.tracebloc
  # + ~/.kube. prepare-host (the admin path) already dispatched-and-exited above;
  # a genuine root login (no SUDO_USER) is allowed. Guarded so a stale bootstrap
  # without the helper proceeds as before (same pattern as early_data_dir_guard).
  if declare -F refuse_sudo_wrapped_install >/dev/null 2>&1; then
    refuse_sudo_wrapped_install
  fi

  validate_config
  # Pre-log network-FS guard (#432): setup_log_file mkdirs HOST_DATA_DIR and
  # redirects the whole session's output onto it — refuse a network-FS target
  # BEFORE that unguarded mkdir can fail (or land root-squashed) on an NFS
  # home. Guarded so a stale bootstrap without the new helper proceeds as
  # before (same pattern as the assess/host_audit gates below).
  if declare -F early_data_dir_guard >/dev/null 2>&1; then
    early_data_dir_guard
  fi
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

  # Trust an explicit corporate CA across every host tool (cosign/helm/git/curl)
  # BEFORE preflight's HTTPS probes and any tool download, so a TLS-inspecting proxy
  # is handled end-to-end (#583). Guarded so a stale bootstrap without the helper
  # proceeds as before (same pattern as the assess/early_data_dir gates).
  if declare -F wire_ca_trust >/dev/null 2>&1; then
    wire_ca_trust
  fi

  # ── a) Check your machine ────────────────────────────────────────────────
  step_header a "Checking your machine"
  run_preflight
  detect_gpu
  # RFC 0001 host audit: capability/privilege probe + the chosen install tier.
  # Sets INSTALL_TIER, which install_linux's _route_install_tier honours. Guarded
  # so a stale bootstrap without probe.sh simply skips it (routing then proceeds
  # exactly as before).
  if declare -F host_audit >/dev/null 2>&1; then
    host_audit
  fi
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
  # The GPU device plugin is no longer applied imperatively here (client#564):
  # the chart now renders it as a Helm-managed DaemonSet, gated on
  # gpu.devicePlugin.enabled, which install_client_helm sets in step (e) from
  # GPU_VENDOR. So it comes up WITH the release (tracked, and removed on
  # uninstall) and node verification moves to after Helm install below.
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
  # Node-level GPU verification (informational): the chart-managed device plugin
  # (client#564) rolls out as part of the Helm release above, so confirm the node
  # now advertises the GPU here rather than before Helm. verify_gpu no-ops for a
  # CPU-only host (GPU_VENDOR neither nvidia nor amd).
  verify_gpu
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
