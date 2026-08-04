#!/usr/bin/env bash
# =============================================================================
#  e2e-common.sh — shared bring-up contract for scripts/tests/e2e-*.sh
# -----------------------------------------------------------------------------
#  The e2e harnesses (e2e-cluster / e2e-proxy / e2e-journey / e2e-auto-upgrade,
#  plus the seal-check runner) each bring up a k3d cluster through the same two
#  blocks, previously copy-pasted near-verbatim: the isolation env (USER +
#  CLUSTER_NAME default + TRACEBLOC_NO_AUTOSTART) and the tool-install
#  prerequisites (docker check + umask + install_{kubectl,k3d,helm}). Multiple
#  Bugbot rounds have changed the install sequence, and every copy had to move
#  in lockstep or drift (PR #541 review). This single-sources those two blocks.
#
#  Deliberately NOT extracted — these legitimately differ per script, so
#  unifying them would change behavior:
#    * the sub-lib `source` set — e2e-proxy / e2e-journey source
#      common+setup-linux+cluster only; e2e-cluster / e2e-auto-upgrade also
#      source preflight (which has top-level PF_* side effects). (That proxy /
#      journey call create_cluster without preflight is a pre-existing
#      inconsistency worth a separate look — NOT changed here.)
#    * the `cleanup`/`trap` body — each reaps its own extra resources
#      (a squid container, work dirs) beyond the k3d cluster.
#    * CHART_DIR — only the chart-installing scripts set it.
#
#  Sourcing contract: source this file, then call the functions AFTER
#  common.sh + setup-linux.sh are sourced (e2e_install_prereqs resolves
#  `has`/`error` from common.sh and `install_*` from setup-linux.sh at CALL
#  time). This file defines functions only — no side effects on source.
# =============================================================================

# Isolate the run: a throwaway CLUSTER_NAME so we never touch a real 'tracebloc'
# install, and TRACEBLOC_NO_AUTOSTART so create_cluster never reconfigures the
# host's Docker restart policy / runs `systemctl enable docker`.
#   $1 — the caller's default CLUSTER_NAME (still overridable via the env).
e2e_isolate_env() {
  export USER="${USER:-$(id -un)}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$1}"
  export TRACEBLOC_NO_AUTOSTART=1
}

# Install the CLI prerequisites a k3d bring-up needs. The sourced libs DEFINE
# install_kubectl/install_k3d/install_helm but do not call them; create_cluster
# + helm need the binaries on PATH first, and a stock GitHub runner ships none.
# Callers with extra prerequisites (e.g. e2e-auto-upgrade needs jq) check those
# alongside this call.
e2e_install_prereqs() {
  has docker || error "Docker is not available on this host."
  umask 022
  install_kubectl
  install_k3d
  install_helm
}
