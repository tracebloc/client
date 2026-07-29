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

# ── Check 4: in-node CA trust parity (#424) ──────────────────────────────────
@test "ca trust: both installers wire the CA -> no drift (#424)" {
  printf 'TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE _resolve_ca_bundle --registry-config tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/lib/cluster.sh"
  printf 'TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE Resolve-CaBundle --registry-config tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/install-k8s.ps1"
  _drift=0; _drift_ca_trust >/dev/null; [ "$_drift" -eq 0 ]
}

@test "ca trust: an installer missing the registry-config -> drift (#424)" {
  printf 'TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE _resolve_ca_bundle --registry-config tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/lib/cluster.sh"
  # ps1 missing --registry-config
  printf 'TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE Resolve-CaBundle tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/install-k8s.ps1"
  _drift=0; _drift_ca_trust >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

@test "ca trust: --registry-config only in a COMMENT does NOT count -> drift (Bugbot #424)" {
  # The functional wiring is gone; the token lingers only in a comment. A whole-file
  # grep would pass — the comment-stripping check must still flag it.
  printf '# uses --registry-config to point containerd at the CA\nTRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE _resolve_ca_bundle tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/lib/cluster.sh"
  printf 'TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE Resolve-CaBundle --registry-config tracebloc-mitm-ca.crt\n' > "$ROOT/scripts/install-k8s.ps1"
  _drift=0; _drift_ca_trust >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

# ── Check 5: preflight download-host parity (#416) ───────────────────────────
# The check extracts hosts from PROBE ENTRIES only — bash "label|https://host/…"
# and ps1 @{ label = "…"; url = "https://host/…" } (label REQUIRED on the ps1 line,
# so an unrelated $url = "https://…" download line can't count). Fixtures write
# real probe entries; an explicit array iterates regardless of the runner's IFS.
@test "preflight hosts: both installers probe the shared set as URLs -> no drift (#416)" {
  local shared=(registry-1.docker.io auth.docker.io ghcr.io dl.k8s.io get.helm.sh github.com objects.githubusercontent.com desktop.docker.com) h
  for h in "${shared[@]}"; do
    printf '  "L (%s)|https://%s/"\n'                 "$h" "$h" >> "$ROOT/scripts/lib/preflight.sh"
    printf '    @{ label = "L (%s)"; url = "https://%s/" }\n' "$h" "$h" >> "$ROOT/scripts/install-k8s.ps1"
  done
  _drift=0; _drift_preflight_hosts >/dev/null; [ "$_drift" -eq 0 ]
}

@test "preflight hosts: a probe entry missing from ps1 -> drift (#416)" {
  local shared=(registry-1.docker.io auth.docker.io ghcr.io dl.k8s.io get.helm.sh github.com objects.githubusercontent.com desktop.docker.com) h
  for h in "${shared[@]}"; do
    printf '  "L (%s)|https://%s/"\n' "$h" "$h" >> "$ROOT/scripts/lib/preflight.sh"
    [[ "$h" == "dl.k8s.io" ]] || printf '    @{ label = "L (%s)"; url = "https://%s/" }\n' "$h" "$h" >> "$ROOT/scripts/install-k8s.ps1"
  done
  _drift=0; _drift_preflight_hosts >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

@test "preflight hosts: a host present only in a COMMENT/hint is NOT counted -> drift (reviewer #416)" {
  # The whole-file grep this replaced would pass here; the URL-extracting check
  # must still flag dl.k8s.io because it's no longer in a probe entry on the ps1 side.
  local shared=(registry-1.docker.io auth.docker.io ghcr.io dl.k8s.io get.helm.sh github.com objects.githubusercontent.com desktop.docker.com) h
  for h in "${shared[@]}"; do
    printf '  "L (%s)|https://%s/"\n' "$h" "$h" >> "$ROOT/scripts/lib/preflight.sh"
    if [[ "$h" == "dl.k8s.io" ]]; then
      printf '  # kubectl comes from dl.k8s.io\n  Hint "allow HTTPS egress to dl.k8s.io"\n' >> "$ROOT/scripts/install-k8s.ps1"
    else
      printf '    @{ label = "L (%s)"; url = "https://%s/" }\n' "$h" "$h" >> "$ROOT/scripts/install-k8s.ps1"
    fi
  done
  _drift=0; _drift_preflight_hosts >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}

@test "preflight hosts: an unrelated \$url= download line does NOT mask a deleted probe -> drift (Bugbot #416)" {
  # github.com's PROBE entry is removed, but a winget-style \$url = "https://github.com/…"
  # download line remains — the label-scoped extractor must NOT count it as a probe.
  local shared=(registry-1.docker.io auth.docker.io ghcr.io dl.k8s.io get.helm.sh github.com objects.githubusercontent.com desktop.docker.com) h
  for h in "${shared[@]}"; do
    printf '  "L (%s)|https://%s/"\n' "$h" "$h" >> "$ROOT/scripts/lib/preflight.sh"
    if [[ "$h" == "github.com" ]]; then
      printf '  $url = "https://github.com/microsoft/winget-cli/releases/latest/download/x.msixbundle"\n' >> "$ROOT/scripts/install-k8s.ps1"
    else
      printf '    @{ label = "L (%s)"; url = "https://%s/" }\n' "$h" "$h" >> "$ROOT/scripts/install-k8s.ps1"
    fi
  done
  _drift=0; _drift_preflight_hosts >/dev/null 2>&1; [ "$_drift" -ge 1 ]
}
