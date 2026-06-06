#!/usr/bin/env bats
# Tests for scripts/tests/check-drift.sh — the source-of-truth drift checker.
# We build a tiny fixture repo under $BATS_TEST_TMPDIR, point DRIFT_ROOT at it,
# source the script (its `set` + main() only run when executed directly), and
# call the check helpers. helm is stubbed so Check 2b is deterministic offline.

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/scripts" "$ROOT/client/ci"
  # Check 1 fixtures — all three carry the same dev/stg/prod hosts.
  printf '_pf_backend_host(){ echo dev-api.tracebloc.io; echo stg-api.tracebloc.io; echo api.tracebloc.io; }\n' > "$ROOT/scripts/lib/preflight.sh"
  printf '_backend_url(){ printf https://dev-api.tracebloc.io/; printf https://stg-api.tracebloc.io/; printf https://api.tracebloc.io/; }\n' > "$ROOT/scripts/lib/install-client-helm.sh"
  printf 'function Get-BackendUrl { "dev-api.tracebloc.io"; "stg-api.tracebloc.io"; "api.tracebloc.io" }\n' > "$ROOT/scripts/install-k8s.ps1"
  # Check 2a fixtures — scripts reference all contract workloads.
  printf 'deploys=("mysql-client" "${ns}-jobs-manager" "${ns}-requests-proxy")\n' > "$ROOT/scripts/lib/summary.sh"
  printf 'for w in mysql-client "${ns}-jobs-manager" "${ns}-requests-proxy"; do :; done\nkubectl logs daemonset/tracebloc-resource-monitor\n' > "$ROOT/scripts/lib/diagnose.sh"
  printf 'clientId: x\nclientPassword: y\n' > "$ROOT/client/ci/bm-values.yaml"

  export DRIFT_ROOT="$ROOT" TB_RELEASE=tracebloc TB_NAMESPACE=tracebloc
  source "${BATS_TEST_DIRNAME}/check-drift.sh"

  # helm stub rendering all four contract workloads (override per-test as needed).
  helm() { cat <<'YAML'
kind: Deployment
metadata:
  name: mysql-client
kind: Deployment
metadata:
  name: tracebloc-jobs-manager
kind: Deployment
metadata:
  name: tracebloc-requests-proxy
kind: DaemonSet
metadata:
  name: tracebloc-resource-monitor
YAML
}
}

# ── Check 1: backend host parity ─────────────────────────────────────────────
@test "backend hosts: all three files agree -> no drift" {
  _drift=0; _drift_backend_hosts >/dev/null; [ "$_drift" -eq 0 ]
}

@test "backend hosts: one file diverges (missing stg) -> drift" {
  printf '_backend_url(){ printf https://dev-api.tracebloc.io/; printf https://api.tracebloc.io/; }\n' > "$DRIFT_ROOT/scripts/lib/install-client-helm.sh"
  _drift=0; _drift_backend_hosts >/dev/null; [ "$_drift" -ge 1 ]
}

@test "backend hosts: prod host renamed in one file -> drift" {
  printf 'function Get-BackendUrl { "dev-api.tracebloc.io"; "stg-api.tracebloc.io"; "prod.tracebloc.io" }\n' > "$DRIFT_ROOT/scripts/install-k8s.ps1"
  _drift=0; _drift_backend_hosts >/dev/null; [ "$_drift" -ge 1 ]
}

@test "backend hosts: function removed (no hosts) -> drift" {
  echo '# backend function gone' > "$DRIFT_ROOT/scripts/lib/preflight.sh"
  _drift=0; _drift_backend_hosts >/dev/null; [ "$_drift" -ge 1 ]
}

# ── Check 2: workload-name contract ──────────────────────────────────────────
@test "workloads: scripts + chart both carry all names -> no drift" {
  _drift=0; _drift_workload_names >/dev/null 2>&1; [ "$_drift" -eq 0 ]
}

@test "workloads: a contract name dropped from the scripts -> drift (2a)" {
  printf 'deploys=("mysql-client")\n' > "$DRIFT_ROOT/scripts/lib/summary.sh"
  printf 'echo no-workloads-here\n' > "$DRIFT_ROOT/scripts/lib/diagnose.sh"
  _drift=0; _drift_workload_names >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

@test "workloads: chart render missing a name -> drift (2b)" {
  helm() { cat <<'YAML'
kind: Deployment
metadata:
  name: mysql-client
kind: Deployment
metadata:
  name: tracebloc-jobs-manager
kind: DaemonSet
metadata:
  name: tracebloc-resource-monitor
YAML
}   # tracebloc-requests-proxy is absent
  _drift=0; _drift_workload_names >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

@test "workloads: helm unavailable -> 2b skipped, no drift from the render half" {
  command() { if [[ "${2:-}" == helm ]]; then return 1; fi; builtin command "$@"; }
  _drift=0; _drift_workload_names >/dev/null 2>&1; [ "$_drift" -eq 0 ]
}
