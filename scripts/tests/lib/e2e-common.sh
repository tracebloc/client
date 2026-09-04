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
#      (a squid container, work dirs) beyond the k3d cluster. The `k3d cluster
#      delete` HALF of it is extracted (e2e_cleanup_cluster, client#979): it was
#      byte-identical in all seven harnesses and identically wrong in all seven,
#      so it is exactly the drift this note warns about. Each cleanup still owns
#      its own extras — and its own exit-status discipline, which the guard
#      scripts/tests/e2e-cleanup-trap.bats pins per harness.
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

# ── e2e_wait_for_metrics_apiservice [existence_timeout_s] [available_timeout_s] ─
# Block until k3s has registered its bundled metrics-server before a helm install
# that renders the resource-monitor DaemonSet.
#
# WHY THIS EXISTS. k3s applies its packaged metrics-server addon — and the
# v1beta1.metrics.k8s.io APIService the resource-monitor preflight looks up
# (client#823) — asynchronously, AFTER nodes report Ready. `create_cluster` +
# `kubectl wait --for=condition=Ready nodes` only proves node readiness, which is
# merely a PROXY for the addon being reconciled. On a fast runner the helm install
# can beat that reconcile: the preflight's live `lookup` finds no APIService and
# `fail`s the WHOLE release with "the metrics.k8s.io/v1beta1 API is not registered"
# — a harness race, not a chart defect (client#863; #862 false-failed at 26s while
# #861 passed at 51s, neither touching the chart or these scripts). Disabling the
# preflight / resourceMonitor would only mask it by deleting the #823 coverage the
# seal-checks exist to exercise on a REAL cluster, so instead we wait for the real
# precondition here.
#
# WHY POLL FOR EXISTENCE, not just `kubectl wait`. The object itself appears late,
# not merely its condition, and `kubectl wait` on a not-yet-CREATED named object
# errors out immediately ("NotFound") rather than waiting for it — so a bare
# `kubectl wait --for=condition=Available apiservice/...` would just swap one red
# for another in exactly the window that fails today. Poll for the APIService to
# exist first (the chart's actual render-time precondition — the preflight only
# checks presence), then best-effort wait for it to report Available so the
# resource-monitor pod's own metrics.k8s.io reads work from the first tick. This
# mirrors the production installer's _wait_for_metrics_apiservice
# (lib/install-client-helm.sh, client#553), which faces the identical race.
#
# Contract: the caller defines fail() (every e2e-*.sh does) and has already
# installed kubectl + brought up the cluster.
e2e_wait_for_metrics_apiservice() {
  local timeout_s="${1:-180}" available_s="${2:-60}"
  echo "── wait for the metrics.k8s.io APIService to register (the real install precondition) ──"
  local deadline=$(( SECONDS + timeout_s ))
  until kubectl get apiservice v1beta1.metrics.k8s.io --request-timeout=10s >/dev/null 2>&1; do
    (( SECONDS < deadline )) ||
      fail "metrics.k8s.io APIService never registered within ${timeout_s}s of nodes going Ready — k3s did not reconcile its bundled metrics-server addon. This is a cluster bring-up problem, not a chart defect: the resource-monitor preflight (client#823) does a live lookup for this APIService and would abort the helm install below with 'the metrics.k8s.io/v1beta1 API is not registered'. Failing here with the real reason instead of a buried render error."
    sleep 3
  done
  # Registered. Give metrics-server a moment to also report Available so the
  # resource-monitor DaemonSet's metrics.k8s.io reads work from its first tick,
  # but do NOT fail on a merely-slow-to-serve addon — the chart's preflight only
  # needs the APIService PRESENT at render time (same stance as the installer's
  # _wait_for_metrics_apiservice).
  kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
    --timeout="${available_s}s" >/dev/null 2>&1 || true
  echo "metrics.k8s.io APIService registered — proceeding with helm install."
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

# ── e2e_cleanup_cluster [seconds] ────────────────────────────────────────────
# Reap the throwaway k3d cluster: BOUNDED, LOUD, and incapable of changing the
# harness's verdict. THE ONE implementation, so an eighth harness inherits all
# three properties instead of having to remember them.
#
# WHY THIS EXISTS (client#979). All seven harnesses carried the identical line:
#
#     cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
#     trap cleanup EXIT
#
# and it cost a reviewer-visible false signal on client#977, a test-only diff.
# Measured from the job log: `E2E mysql 8.4 (ubuntu-24.04-arm)` aborted CORRECTLY
# at 09:15:44 on a rollout `--timeout=300s`, then produced NO OUTPUT AT ALL for
# ~24 minutes until the job's own `timeout-minutes: 30` killed it at 09:39:23 —
# "Terminate orphan process: pid (4358) (k3d)" is that hung child.
#
# Three separate defects in that one line, and fixing fewer than three leaves the
# failure mode intact:
#
#  1. UNBOUNDED. `k3d cluster delete` talks to the Docker engine and takes no
#     `--timeout` of its own (unlike `k3d cluster start`/`create`, which accept
#     `--wait --timeout`). On a runner whose engine is already unhappy — precisely
#     what a failed pod rollout suggests — it blocks. `_bounded` (common.sh) puts a
#     deadline on it and reports 124 when the deadline fires. The macOS no-op
#     caveat on `_bounded` genuinely does not apply: every job that runs these
#     harnesses is on an `ubuntu-*` GitHub runner, where coreutils `timeout` is
#     present — asserted from the workflow files by e2e-cleanup-trap.bats rather
#     than assumed, since that caveat is real elsewhere in this repo.
#  2. SILENCED. `>/dev/null 2>&1` is what made 24 minutes invisible: there was no
#     line in the log to attribute the stall to, so it read as "the test hung"
#     rather than "cleanup hung after the test already failed". Output is no longer
#     redirected, and a bound that fires prints one line naming itself.
#  3. VERDICT-DESTROYING. `set -e` worked — the body aborted with a correct
#     non-zero status and a named reason — and the trap-hang converted that into
#     GitHub's `cancelled`, which is neither pass nor fail (backend#1758: "a job
#     timeout destroys the verdict artifact"; client#753 / client#920 are the same
#     class at other sites). Note the mechanism carefully: errexit is LIVE inside
#     an EXIT trap, so any command there that ends non-zero aborts the trap and
#     OVERWRITES the script's exit status — verified, `exit 7` plus a trap whose
#     last command is `false` exits 1. The old `|| true` happened to neutralise
#     that; removing it without care would have introduced a new way to lose the
#     verdict. So this function ALWAYS returns 0, and each caller captures `$?`
#     first and returns it last.
#
# A leftover throwaway cluster on an ephemeral runner costs nothing. The stall
# cost a 30-minute job and a reviewer's afternoon, so on the deadline we give up
# and say so rather than wait.
e2e_cleanup_cluster() {
  local secs="${1:-${TB_E2E_DELETE_TIMEOUT:-120}}" rc=0
  [ -n "${CLUSTER_NAME:-}" ] || return 0
  # Fail toward "don't hang": running the delete UNBOUNDED is the defect itself,
  # so if common.sh was never sourced we skip it and say so. Every harness sets its
  # trap AFTER sourcing common.sh, so this branch is a belt, not the trousers.
  if ! declare -F _bounded >/dev/null 2>&1; then
    echo "cleanup: _bounded is unavailable (common.sh not sourced) — SKIPPING 'k3d cluster delete ${CLUSTER_NAME}' rather than running it unbounded (client#979). Delete it by hand if this was not an ephemeral runner." >&2
    return 0
  fi
  echo "cleanup: deleting k3d cluster '${CLUSTER_NAME}' (bounded at ${secs}s)…" >&2
  _bounded "$secs" k3d cluster delete "$CLUSTER_NAME" || rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "cleanup: 'k3d cluster delete ${CLUSTER_NAME}' TIMED OUT after ${secs}s — the Docker engine is not answering. Giving up so the harness's own verdict above is the one this job reports (client#979). A leftover cluster / orphan k3d process may remain on this runner." >&2
  elif [ "$rc" -ne 0 ]; then
    echo "cleanup: 'k3d cluster delete ${CLUSTER_NAME}' exited ${rc} — a leftover cluster may remain on this runner." >&2
  fi
  # ALWAYS 0: cleanup is a note, never the outcome. See defect 3 above.
  return 0
}

# ── e2e_reap_path PATH… ──────────────────────────────────────────────────────
# Remove files/directories from inside an EXIT trap without ever being able to
# change the harness's verdict. THE ONE implementation, so an eighth harness
# inherits the guarantee instead of having to remember it.
#
# WHY THIS EXISTS (client#979, LukasWodka + saqlainsyed007 both drove it).
# e2e-full-seal.sh's cleanup read:
#
#     [ -n "$CREDS_FILE" ] && rm -f "$CREDS_FILE"
#
# and `rm -f` is the LAST command of that `&&` list, so `set -e` is NOT exempt
# from it — the exemption covers every command in a `&&`/`||` list EXCEPT the
# last. A failing `rm -f` (a read-only mount, a mode-500 parent directory) aborts
# the trap. Driven, harness exiting 7:
#
#     CREDS_FILE=""                 -> rm not reached   -> exit 7   reap ran
#     CREDS_FILE=<removable>        -> rm succeeds      -> exit 7   reap ran
#     CREDS_FILE=<in a 0500 dir>    -> rm FAILS         -> exit 1   reap SKIPPED
#
# Two losses from one line, and the second is worse than the first: the harness's
# verdict is replaced by the `rm`'s status — the exact overwrite this change
# exists to stop — and the abort also skips e2e_cleanup_cluster, so the k3d
# cluster leaks as well.
#
# `rm -f` already ignores a missing path, so the only thing left to neutralise is
# a permission/read-only failure. Empty arguments are skipped rather than passed
# on: `rm -f ""` is a no-op on GNU but noisy elsewhere, and an unset variable
# reaching here is a caller bug worth not hiding behind a redirect.
e2e_reap_path() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    rm -rf -- "$p" 2>/dev/null || echo "cleanup: could not remove ${p} — it may remain on this runner." >&2
  done
  # ALWAYS 0: a reap that could not complete is a note, never the outcome.
  return 0
}
