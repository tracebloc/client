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
#    3. The chart names/shapes the tracebloc CLI hardcodes (tracebloc/cli#290) —
#       Service, PVC + mount, ingestion-authz ConfigMap, ingestor SA, digest env,
#       submit path — so a chart rename fails HERE, at the source, not in the
#       field after both repos shipped green.
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

# ── Check 3: CLI-assumed chart contract (tracebloc/cli#290) ──────────────────
# The tracebloc CLI hardcodes these names/shapes to discover the release, run
# `cluster doctor`, and ingest datasets (cli: internal/cluster/discover.go,
# internal/cluster/pvc.go, internal/submit/client.go). Check 2 already pins the
# two Deployment names; this pins the REST of the CLI contract. The cli repo
# runs the mirror gate against a pinned chart ref (cli .github/workflows/
# chart-drift.yml + scripts/.client-ref); this side fails the renaming chart PR
# itself.

# _render_doc <kind> <name-regex>: print the rendered doc(s) (stdin) whose
# top-level kind and metadata.name match. Line-oriented on helm output: docs
# split on ^---, kind/metadata are unindented, metadata.name is the first
# 2-space `name:` inside the metadata block (chart names render unquoted).
_render_doc() {
  awk -v K="$1" -v NRE="$2" '
    function flush() { if (kind == K && name ~ NRE) printf "%s", buf; buf=""; kind=""; name=""; inmeta=0 }
    /^---/ { flush(); next }
    { buf = buf $0 "\n" }
    /^kind:/     { kind=$2 }
    /^metadata:/ { inmeta=1; next }
    /^[^ ]/      { inmeta=0 }
    inmeta && name=="" && /^  name:/ { name=$2 }
    END { flush() }
  '
}

_drift_cli_contract() {
  echo "▸ CLI-assumed chart contract (tracebloc/cli#290) vs the chart render"
  if ! command -v helm >/dev/null 2>&1; then
    echo "  (helm not installed — skipping chart render; CI runs this half)"; return 0
  fi
  local vals; vals="$(ls "$DRIFT_ROOT"/client/ci/bm-values.yaml "$DRIFT_ROOT"/client/ci/*-values.yaml 2>/dev/null | head -1)"
  local rendered
  if ! rendered="$(helm template "$TB_RELEASE" "$DRIFT_ROOT/client" -n "$TB_NAMESPACE" ${vals:+-f "$vals"} 2>/dev/null)"; then
    _note "helm template failed — the chart does not render (values: ${vals:-none})"; return 0
  fi
  local doc

  # Service jobs-manager on port 8080 — the CLI probes both name forms and
  # port-forwards to 8080 (discover.go pickJobsManagerService, jobsManagerPort).
  doc="$(_render_doc Service "^(jobs-manager|${TB_RELEASE}-jobs-manager)\$" <<<"$rendered")"
  if [[ -n "$doc" ]] && grep -qE '^[[:space:]]*port:[[:space:]]*8080([[:space:]]|$)' <<<"$doc"; then
    _ok "Service jobs-manager rendered with port 8080 (CLI port-forward + POST target)"
  else
    _note "the CLI expects a Service named 'jobs-manager' (or '${TB_RELEASE}-jobs-manager') with port 8080 — not rendered"
  fi

  # Shared-data PVC + its mount — the CLI pins the claim name 'client-pvc' and
  # the '/data/shared' mount for stage/ingestor pods (pvc.go SharedPVCClaimName,
  # SharedPVCMountPath).
  if [[ -n "$(_render_doc PersistentVolumeClaim '^client-pvc$' <<<"$rendered")" ]]; then
    _ok "PVC client-pvc rendered"
  else
    _note "the CLI expects a PVC named 'client-pvc' — not rendered"
  fi
  doc="$(_render_doc Deployment "^${TB_RELEASE}-jobs-manager\$" <<<"$rendered")"
  if grep -qF 'mountPath: "/data/shared"' <<<"$doc" && grep -qE '^[[:space:]]*claimName:[[:space:]]*client-pvc([[:space:]]|$)' <<<"$doc"; then
    _ok "jobs-manager mounts client-pvc at /data/shared"
  else
    _note "the CLI expects jobs-manager to mount claim 'client-pvc' at '/data/shared' — mount or claim missing from the render"
  fi

  # Ingestion authz — the CLI reads ConfigMap '<release>-ingestion-authz', key
  # 'ingestion-authz.yaml', and falls back to the SA name 'ingestor' when the
  # ConfigMap is unreadable (discover.go discoverIngestorSAName, IngestorSAName).
  doc="$(_render_doc ConfigMap "^${TB_RELEASE}-ingestion-authz\$" <<<"$rendered")"
  if [[ -n "$doc" ]] && grep -qE '^[[:space:]]*ingestion-authz\.yaml:' <<<"$doc"; then
    _ok "ConfigMap ${TB_RELEASE}-ingestion-authz rendered with key ingestion-authz.yaml"
  else
    _note "the CLI expects ConfigMap '${TB_RELEASE}-ingestion-authz' with key 'ingestion-authz.yaml' — not rendered"
  fi
  if [[ -n "$(_render_doc ServiceAccount '^ingestor$' <<<"$rendered")" ]]; then
    _ok "ServiceAccount ingestor rendered (the CLI's hardcoded fallback SA)"
  else
    _note "the CLI's fallback ingestor SA name is 'ingestor' — no such ServiceAccount rendered (update discover.go IngestorSAName together with any rename)"
  fi

  # Ingestor digest pin — the CLI reads INGESTOR_IMAGE_DIGEST off jobs-manager's
  # first container (discover.go).
  doc="$(_render_doc Deployment "^${TB_RELEASE}-jobs-manager\$" <<<"$rendered")"
  if grep -qE '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*INGESTOR_IMAGE_DIGEST([[:space:]]|$)' <<<"$doc"; then
    _ok "jobs-manager carries the INGESTOR_IMAGE_DIGEST env"
  else
    _note "the CLI expects env INGESTOR_IMAGE_DIGEST on jobs-manager — not rendered"
  fi

  # Submit endpoint — the CLI POSTs /internal/submit-ingestion-run to port 8080
  # (submit/client.go SubmitPath). The path lives in rendered comments; a
  # client-runtime endpoint move updates those in the same change, and this
  # makes it confront the CLI's constant too.
  if grep -qF '/internal/submit-ingestion-run' <<<"$rendered"; then
    _ok "chart still references POST /internal/submit-ingestion-run (CLI SubmitPath)"
  else
    _note "the render no longer references '/internal/submit-ingestion-run' — if the endpoint moved, the CLI's SubmitPath must move with it"
  fi
}

main() {
  set -uo pipefail
  echo "── source-of-truth drift checks ─────────────────────────────"
  _drift_backend_hosts
  _drift_workload_names
  _drift_cli_contract
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
