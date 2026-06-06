#!/usr/bin/env bash
# =============================================================================
#  check-drift.sh — fail when two sources of truth that MUST agree have drifted.
#
#  Mocked unit tests can't catch "the chart renamed a Deployment that the
#  diagnostics script greps for by name" or "the prod API host changed in one of
#  the three files that hardcode it". Those ship green and break in the field.
#  This runs in CI on any scripts/ or client/ change and fails with a precise
#  diff. (Same idea as cli/scripts/sync-schema.sh, which pins the ingest schema.)
#
#  Checks:
#    1. Backend API host map identical across preflight.sh / install-client-helm.sh
#       / install-k8s.ps1 — the dev/stg/prod hosts are hardcoded in all three.
#    2. The workload objects summary.sh (readiness wait) and diagnose.sh (support
#       bundle) reference BY NAME are actually rendered by the chart. A chart
#       rename would silently break readiness detection and the --diagnose bundle.
#
#  Exit 0 = no drift; non-zero = drift (every divergence is printed).
#  Overrides: DRIFT_ROOT (repo root), TB_RELEASE, TB_NAMESPACE.
# =============================================================================
# (set -uo pipefail lives inside main() so this file is side-effect-safe to
#  source — the bats suite sources it to exercise the helpers in isolation.)

DRIFT_ROOT="${DRIFT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TB_RELEASE="${TB_RELEASE:-tracebloc}"
TB_NAMESPACE="${TB_NAMESPACE:-tracebloc}"

_drift=0
_note() { printf '  \033[31m✖\033[0m %s\n' "$*"; _drift=$(( _drift + 1 )); }
_ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }

# ── Check 1: backend API host map parity ─────────────────────────────────────
# preflight.sh::_pf_backend_host, install-client-helm.sh::_backend_url, and
# install-k8s.ps1::Get-BackendUrl each hardcode the dev/stg/prod hosts. They must
# carry the identical set; a domain change in one file that misses the others is
# the drift we're guarding.
_drift_backend_hosts() {
  echo "▸ Backend API host map (preflight.sh · install-client-helm.sh · install-k8s.ps1)"
  local files=( scripts/lib/preflight.sh scripts/lib/install-client-helm.sh scripts/install-k8s.ps1 )
  local ref="" reff="" f hset
  for f in "${files[@]}"; do
    if [[ ! -f "$DRIFT_ROOT/$f" ]]; then _note "$f is missing"; continue; fi
    hset="$(grep -oE '(dev-api|stg-api|api)\.tracebloc\.io' "$DRIFT_ROOT/$f" | sort -u | paste -sd, -)"
    if [[ -z "$hset" ]]; then _note "$f: no *.tracebloc.io API hosts found (function renamed/removed?)"; continue; fi
    if [[ -z "$ref" ]]; then ref="$hset"; reff="$f"; _ok "$f → $hset"
    elif [[ "$hset" != "$ref" ]]; then _note "$f → [$hset]  differs from  $reff → [$ref]"
    else _ok "$f → $hset"; fi
  done
}

# ── Check 2: script-referenced workloads exist in the rendered chart ─────────
# summary.sh waits on `deployment/<name>` and diagnose.sh logs `deploy/<name>` +
# `daemonset/<name>`. If the chart renames any, readiness + diagnostics break
# silently. The names below are the contract (release-prefixed where the scripts
# use ${ns}-); they're asserted against `helm template` AND against the scripts
# (so the contract here can't go stale on either side).
_drift_workload_names() {
  echo "▸ Workload objects referenced by summary.sh / diagnose.sh vs the chart render"
  local deployments=( "mysql-client" "${TB_RELEASE}-jobs-manager" "${TB_RELEASE}-requests-proxy" )
  local daemonsets=( "tracebloc-resource-monitor" )
  local n

  # 2a. each contract name must still be referenced by the scripts.
  local blob; blob="$(cat "$DRIFT_ROOT"/scripts/lib/summary.sh "$DRIFT_ROOT"/scripts/lib/diagnose.sh 2>/dev/null)"
  for n in "mysql-client" '${ns}-jobs-manager' '${ns}-requests-proxy' "tracebloc-resource-monitor"; do
    grep -qF -- "$n" <<<"$blob" || _note "contract lists '$n' but summary.sh/diagnose.sh no longer reference it — update check-drift.sh"
  done

  # 2b. each contract name must be rendered by the chart.
  if ! command -v helm >/dev/null 2>&1; then
    echo "  (helm not installed — skipping chart render; CI runs this half)"; return 0
  fi
  local vals; vals="$(ls "$DRIFT_ROOT"/client/ci/bm-values.yaml "$DRIFT_ROOT"/client/ci/*-values.yaml 2>/dev/null | head -1)"
  local rendered
  if ! rendered="$(helm template "$TB_RELEASE" "$DRIFT_ROOT/client" -n "$TB_NAMESPACE" ${vals:+-f "$vals"} 2>/dev/null)"; then
    _note "helm template failed — the chart does not render (values: ${vals:-none})"; return 0
  fi
  for n in "${deployments[@]}"; do
    if grep -qE "^[[:space:]]*name:[[:space:]]+${n}([[:space:]]|$)" <<<"$rendered"; then _ok "Deployment/$n rendered"
    else _note "summary.sh/diagnose.sh expect Deployment/$n — the chart does not render that name"; fi
  done
  for n in "${daemonsets[@]}"; do
    if grep -qE "^[[:space:]]*name:[[:space:]]+${n}([[:space:]]|$)" <<<"$rendered"; then _ok "DaemonSet/$n rendered"
    else _note "diagnose.sh expects DaemonSet/$n — the chart does not render that name"; fi
  done
}

main() {
  set -uo pipefail
  echo "── source-of-truth drift checks ─────────────────────────────"
  _drift_backend_hosts
  _drift_workload_names
  echo "─────────────────────────────────────────────────────────────"
  if [[ "$_drift" -gt 0 ]]; then
    echo "DRIFT: $_drift divergence(s) above. Update both sides (or the contract in check-drift.sh) and re-run." >&2
    return 1
  fi
  echo "no drift."
  return 0
}

# Run only when executed directly (bats sources this file to test the helpers).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
