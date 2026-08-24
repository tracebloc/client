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

# ── e2e_proxy_probe_snippet <backend-host> [deadline_s] [delay_s] ────────────
# Emits the in-pod shell for §A of e2e-proxy.sh — the backend call that MUST
# traverse the squid. EMITTED rather than written inline in the pod manifest so
# that scripts/tests/e2e-proxy-probe.bats executes THIS text and not a
# paraphrase of it (backend#1729 rule 9: a mutation check must call the code
# under test, not a copy).
#
# WHY A LOOP OF FRESH PROCESSES, and not curl's own --retry. The probe used to be
# ONE curl carrying `--retry 8 --retry-connrefused --retry-all-errors`, above a
# comment asserting that --retry-all-errors covered the "Could not resolve proxy"
# case. It does not. curl caches a FAILED name resolution for the life of the
# process, so every retry after the first is answered from that cache without
# touching the resolver. Verbatim from both develop failures (runs 32473068472
# and 32589039697) — 9 attempts, 8 of which logged the cache hit:
#
#     * Could not resolve proxy: tb-egress-squid.default.svc.cluster.local
#     * Negative DNS entry
#     curl: (5) Could not resolve proxy: tb-egress-squid.default.svc.cluster.local
#
# So exactly ONE resolver query was ever issued, about a second after the pod
# started, and the documented protection against the cluster-DNS startup window
# was inert: the guard turned entirely on whether CoreDNS happened to be serving
# at that single instant. Measured 2 failures in 30 develop runs (backend#2350).
# A new PROCESS cannot inherit the poisoned cache, which is why the retry has to
# live out here rather than inside one curl.
#
# TEETH. Only exit 5 (could not resolve proxy), 6 (could not resolve host) and 7
# (connection refused) are retried — the three symptoms of the startup window
# (the proxy Service name not yet in the pod's resolver; Service endpoints not
# yet programmed into kube-proxy — run 29255451968). EVERY other outcome ENDS the
# loop, success included, so a real #119 regression (proxy env ignored, so the
# call dials direct and succeeds with no CONNECT) still fails on the first
# attempt instead of being retried into a slow green. A squid that is genuinely
# down exhausts the deadline and fails.
#
# Every attempt prints its number, curl's exit code and the elapsed seconds, so
# a future red says whether it waited — the old failure could not distinguish
# "did not tunnel" from "had not tunnelled yet".
e2e_proxy_probe_snippet() {
  local host="${1:-}" deadline="${2:-90}" delay="${3:-2}"
  # Fail closed (rule 3): an empty host would emit a probe of https:/// that
  # fails for a reason having nothing to do with proxying — a red meaning
  # nothing. Callers assign this into a variable, so `set -e` aborts on return.
  [ -n "$host" ] || { echo "e2e_proxy_probe_snippet: backend host is required" >&2; return 2; }
  sed -e "s|@@HOST@@|${host}|g" \
      -e "s|@@DEADLINE@@|${deadline}|g" \
      -e "s|@@DELAY@@|${delay}|g" <<'SNIP'
probe_start=$(date +%s)
probe_attempt=0
while :; do
  probe_attempt=$((probe_attempt+1))
  probe_rc=0
  curl -k -v -sS -m 30 -o /dev/null "https://@@HOST@@/" 2>&1 || probe_rc=$?
  probe_elapsed=$(( $(date +%s) - probe_start ))
  echo "----- probe attempt ${probe_attempt} rc=${probe_rc} elapsed=${probe_elapsed}s -----"
  case "${probe_rc}" in
    5|6|7) ;;
    *) break ;;
  esac
  if [ "${probe_elapsed}" -ge @@DEADLINE@@ ]; then
    echo "----- probe GAVE UP after ${probe_attempt} attempts / ${probe_elapsed}s waiting for the proxy Service name to resolve -----"
    break
  fi
  sleep @@DELAY@@
done
SNIP
}
