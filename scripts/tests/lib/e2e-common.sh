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

# ── e2e_egress_positive_control <host> ──────────────────────────────────────
# Positive control for the egress seal-checks (Saqlain review on #541): before
# trusting a BLOCKED probe result, prove the cluster can actually REACH the
# probe host. Otherwise egress failing for an unrelated reason (a runner
# firewall, a target outage, a rate-limit) makes the probe print OK and the
# seal-check pass green while the NetworkPolicy did nothing. A pod in `default`
# is governed by NO training-egress policy (the policy is namespace-scoped to
# the release ns), so if IT reaches the host, a training pod's block is
# attributable to the policy, not the environment. Same image + curl invocation
# as the probe, targeting the SAME host pinned on the caller's install — so a
# reachable positive is attributable to exactly the host the probe is blocked
# from (no hardcoded-vs-chart-default drift).
# Moved verbatim from e2e-seal-check.sh (#541) so e2e-full-seal.sh shares the
# one copy. Contract: the caller defines fail() (every e2e-*.sh does).
e2e_egress_positive_control() {
  local host="$1"
  echo "── positive control: a non-policied pod must REACH ${host}:443 ──"
  # A fast runner can schedule the pod before the `default` ServiceAccount is
  # created ("serviceaccount default not found"), which aborts under set -e
  # before the attribution failure below. Wait for the SA first (Bugbot).
  for _ in $(seq 1 20); do
    kubectl --request-timeout=10s get serviceaccount default -n default >/dev/null 2>&1 && break
    sleep 1
  done
  kubectl --request-timeout=10s run seal-poscheck --namespace default --restart=Never \
    --image="curlimages/curl:8.20.0" \
    --command -- curl --noproxy '*' --tlsv1.2 -k -sS -m 15 -o /dev/null "https://${host}"
  local posphase=""
  for _ in $(seq 1 40); do
    posphase="$(kubectl --request-timeout=10s get pod seal-poscheck -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    { [ "$posphase" = "Succeeded" ] || [ "$posphase" = "Failed" ]; } && break
    sleep 3
  done
  kubectl --request-timeout=10s logs seal-poscheck -n default 2>/dev/null || true
  kubectl --request-timeout=10s delete pod seal-poscheck -n default --ignore-not-found --now >/dev/null 2>&1 || true
  [ "$posphase" = "Succeeded" ] ||
    fail "positive control FAILED — a non-policied pod could not reach ${host}:443 (phase=${posphase:-none}). A blocked training pod would NOT be attributable to the NetworkPolicy (runner egress / target issue), so the seal-check is inconclusive — refusing to report a false PASS."
  echo "positive control OK — ${host}:443 reachable; a training-pod block is now attributable to the policy."
}
