#!/usr/bin/env bash
# =============================================================================
#  assess.sh — installer "stop-and-check" gate.
#
#  A re-run of the installer on a machine that is ALREADY set up should not drag
#  the user back through full provisioning. This module inspects the machine
#  READ-ONLY and classifies it, so main() can short-circuit a healthy box
#  straight to the `tracebloc` home screen (exit 0) instead of re-running every
#  step — while a fresh or half-set-up machine still runs the normal flow.
#
#  STRICTLY NON-MUTATING. It must never start the cluster, run helm, mint a
#  credential, or write anything. Every probe is read-only (`k3d cluster list`,
#  `helm list`/`get values`, `kubectl get`) and BOUNDED (short timeouts) so it
#  can't hang, and it is NEVER fatal. On ANY probe failure or uncertainty it
#  degrades toward "run the normal flow" — never toward a false "healthy". A
#  false healthy that skips a needed install is the worst possible outcome, so
#  "healthy" must be CERTAIN: cluster running AND a tracebloc release present AND
#  the core workload (jobs-manager) Ready AND the CLI present. Anything less is
#  degraded (partial) or fresh (nothing here yet), and both fall through.
#
#  Sets INSTALL_STATE (+ INSTALL_STATE_REASON, a short machine-readable tag of
#  what is off):
#    fresh    — no cluster, or a cluster with no tracebloc release.
#    healthy  — all four signals above true. The ONLY short-circuit.
#    degraded — a partial state (cluster stopped, workload not Ready, CLI
#               missing, or any other partial state).
# =============================================================================

# --force / --reinstall (or TRACEBLOC_FORCE_REINSTALL=1) bypasses the gate and
# runs the full flow. Defaulted here so the gate is safe to consult even if the
# arg scan never set it; main()'s arg parsing flips it to 1 on the flag.
: "${TB_FORCE_REINSTALL:=${TRACEBLOC_FORCE_REINSTALL:-0}}"

# Bound on the readiness probe's API call — short so a stopped/unreachable API
# can never make the gate hang. Overridable for tests.
: "${TB_ASSESS_KUBECTL_TIMEOUT:=5s}"

# _assess_cluster_servers_running — echo the number of running servers for
# CLUSTER_NAME. This mirrors ONLY the read half of cluster.sh's
# _handle_existing_cluster; that function is off-limits here because it MUTATES
# (it starts a stopped cluster and runs drift checks). Single jq-free path — jq
# is NOT a guaranteed installer prerequisite (same rule as common.sh /
# install-client-helm.sh, Bugbot #284): read the k3d table's SERVERS column
# ("running/total") for an EXACT name match with awk. Echoes an integer; 0 on any
# error / when the cluster is absent.
_assess_cluster_servers_running() {
  local running="0" line
  # `|| line=""`: awk's `exit` closes the pipe, so under `set -o pipefail` a
  # SIGPIPE from k3d (141) — or any k3d failure — would otherwise propagate
  # non-zero out of the assignment and abort the installer under `set -e`.
  line="$(k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '$1 == n { print $2; exit }')" \
    || line=""
  [[ -n "$line" ]] && running="${line%%/*}"
  [[ "$running" =~ ^[0-9]+$ ]] || running="0"
  printf '%s' "$running"
}

# _assess_workload_ready NS — are ALL the client's core workloads Ready in
# namespace NS? "Ready" MUST match the installer's OWN definition, so this
# iterates the SAME deployment set as wait_for_client_ready (summary.sh) via the
# shared _client_workload_deployments — mysql-client + jobs-manager +
# requests-proxy. A machine with jobs-manager up but requests-proxy (training
# egress) or mysql-client down is NOT healthy, and must reconcile rather than be
# told "already set up". Read-only + bounded via kubectl --request-timeout, so a
# stopped/unreachable API returns quickly instead of hanging. A Deployment is
# Ready when it reports >=1 readyReplicas; ANY one missing / erroring / zero =>
# not ready (return 1), which degrades toward the normal flow.
_assess_workload_ready() {
  local ns="$1" d ready
  [[ -n "$ns" ]] || return 1
  has kubectl || return 1
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ready="$(kubectl get deployment "$d" -n "$ns" \
               --request-timeout="$TB_ASSESS_KUBECTL_TIMEOUT" \
               -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || return 1
    [[ "$ready" =~ ^[0-9]+$ ]] && [[ "$ready" -ge 1 ]] || return 1
  done < <(_client_workload_deployments "$ns")
  return 0
}

# _assess_cli_present — is the tracebloc CLI available? Counts a binary in
# ~/.local/bin (where the CLI installer drops it when /usr/local/bin isn't
# writable) even if THIS shell's PATH predates that dir — the same place
# provision.sh / install-cli.sh resolve it.
_assess_cli_present() {
  has tracebloc && return 0
  [[ -x "${HOME}/.local/bin/tracebloc" ]]
}

# _assess_classify — set INSTALL_STATE (+ INSTALL_STATE_REASON). Pure read-only
# detection; no mutation, never fatal.
_assess_classify() {
  INSTALL_STATE="fresh"
  INSTALL_STATE_REASON="no-cluster"

  # No engine or no cluster => first-time setup. (has k3d short-circuits before
  # _cluster_exists so a machine without k3d doesn't shell out at all.)
  if ! has k3d || ! _cluster_exists; then
    INSTALL_STATE="fresh"; INSTALL_STATE_REASON="no-cluster"
    return 0
  fi

  # A cluster exists. Is a tracebloc release installed on it? Reuse the shared
  # jq-free probe (sets INSTALLED_CLIENT_NS) so this can never disagree with the
  # Helm-step / #303 ownership guards on "what runs here". A cluster with no
  # release is still a first-time client setup.
  local ns=""
  if declare -F detect_installed_client >/dev/null 2>&1; then
    detect_installed_client
    ns="$INSTALLED_CLIENT_NS"
  fi
  if [[ -z "$ns" ]]; then
    INSTALL_STATE="fresh"; INSTALL_STATE_REASON="cluster-no-release"
    return 0
  fi

  # Cluster + release both present -> healthy or degraded. Require CERTAINTY on
  # every signal for "healthy"; anything less degrades to the normal flow, which
  # reconciles the specific layer that is off.
  local servers; servers="$(_assess_cluster_servers_running)"
  if [[ "$servers" -lt 1 ]]; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-stopped"
    return 0
  fi

  # Cluster is running, so the readiness probe talks to a live API (and is
  # bounded regardless). ANY of the client's core workloads not Ready => degraded.
  if ! _assess_workload_ready "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="workload-not-ready"
    return 0
  fi

  # Env is up and Ready, but the CLI is missing => degraded (the normal flow
  # reinstalls the CLI).
  if ! _assess_cli_present; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-missing"
    return 0
  fi

  INSTALL_STATE="healthy"; INSTALL_STATE_REASON="ns:${ns}"
  return 0
}

# _assess_handoff — hand a healthy machine to the tracebloc home screen, then
# exit 0. We deliberately do NOT `exec` so the EXIT trap (install_cleanup) still
# runs its cleanup. The CLI may live in ~/.local/bin and not yet be on this
# shell's PATH, so put that dir on PATH first (mirrors provision.sh). If
# `tracebloc` is somehow still unresolvable, fall back to a short status line so
# a healthy re-run always ends cleanly at exit 0.
_assess_handoff() {
  success "Already set up on this machine — no need to run the installer again."
  export PATH="${HOME}/.local/bin:${PATH}"
  if has tracebloc; then
    echo ""
    # Bare invocation -> the home screen; the user lands on their status. Give it
    # the user's REAL terminal: under `curl … | bash` this shell's stdin is the
    # install pipe, so a bare `tracebloc` would consume/block on the script bytes
    # (same class as #341). Redirect </dev/tty when it's openable, else </dev/null
    # — never the pipe (mirrors install.sh's bootstrap hand-off). Deliberately NO
    # `exec` (see above) so the EXIT trap still runs. Never let a non-zero render
    # flip our exit code — a healthy machine exits 0.
    if { : </dev/tty; } 2>/dev/null; then tracebloc </dev/tty || true; else tracebloc </dev/null || true; fi
    exit 0
  fi
  info "Open the tracebloc home screen any time with:  tracebloc"
  exit 0
}

# assess_existing_install — the gate. Called from main() after print_banner and
# before the roadmap / Step 1. READ-ONLY, never fatal. On a healthy machine it
# short-circuits (hand-off + exit 0). On fresh / degraded it prints a warm
# one-liner and RETURNS 0 so main() runs the normal flow to set up (fresh) or
# reconcile (degraded).
assess_existing_install() {
  # --force / --reinstall (or the env override): skip the gate entirely.
  if [[ "${TB_FORCE_REINSTALL:-0}" == 1 ]]; then
    log "assess: --force/--reinstall set — bypassing the stop-and-check gate."
    return 0
  fi

  _assess_classify
  log "assess: INSTALL_STATE=${INSTALL_STATE} reason=${INSTALL_STATE_REASON:-}"

  case "$INSTALL_STATE" in
    healthy)
      echo ""
      _assess_handoff        # prints the "already set up" line, runs `tracebloc`, exit 0
      ;;
    degraded)
      echo ""
      case "$INSTALL_STATE_REASON" in
        cluster-stopped)    info "Your secure environment is stopped — starting it and finishing setup." ;;
        workload-not-ready) info "Your secure environment is still starting up — finishing setup." ;;
        cli-missing)        info "The tracebloc CLI isn't installed yet — setting it up." ;;
        *)                  info "Your secure environment is only partly set up — finishing setup." ;;
      esac
      echo ""
      return 0               # fall through to the normal flow to reconcile
      ;;
    fresh|*)
      # Only the truly-empty machine gets a first-time header; a cluster that
      # merely lacks a release proceeds without ceremony.
      if [[ "$INSTALL_STATE_REASON" == "no-cluster" ]]; then
        info "Setting up your secure environment on this machine for the first time."
        echo ""
      fi
      return 0               # today's normal flow
      ;;
  esac
}
