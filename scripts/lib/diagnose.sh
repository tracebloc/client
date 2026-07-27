#!/usr/bin/env bash
# =============================================================================
#  diagnose.sh — `--diagnose` support bundle
#
#  Collects logs + cluster/host status into ONE redacted archive the customer
#  can send to support, collapsing multi-round triage into a single file.
#
#  Two guarantees:
#   • Best-effort — works even when the install is broken (the whole collection
#     runs under `set +e`; every section is independent).
#   • Credential-safe — clientPassword, proxy credentials (user:pass@host), and
#     password=/token/secret values are redacted from EVERY file before it is
#     archived. clientId is kept (it's the identifier support needs, not a secret).
#
#  Side-effect-safe to source (function definitions only).
# =============================================================================

# Redact secrets from a file IN PLACE. Applied to every collected file before
# archiving. `sed -i.bak` + `rm .bak` is portable across GNU and BSD/macOS sed.
_redact_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # Case-insensitive via explicit classes (BSD/macOS sed has no `I` flag). The
  # first rule redacts ANY *password key (clientPassword, dockerRegistry
  # `password:`, HTTP_PROXY_PASSWORD, …) in either `:` or `=` form — not just
  # clientPassword — so registry/proxy/db passwords don't leak into the bundle.
  sed -i.bak -E \
    -e 's/([A-Za-z0-9_.-]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^:/@[:space:]]+:[^@/[:space:]]+@#\1[REDACTED]@#g' \
    -e 's/(([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy])[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/' \
    "$f" 2>/dev/null
  rm -f "${f}.bak" 2>/dev/null
}

# Redact every regular file under a directory.
_redact_tree() {
  local f
  while IFS= read -r f; do _redact_file "$f"; done < <(find "$1" -type f 2>/dev/null)
}

run_diagnose() {
  set +e   # every step is best-effort — never abort the bundle mid-collection

  local ts base outdir d ns cn
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null)"; [[ -z "$ts" ]] && ts="bundle"
  base="${HOST_DATA_DIR:-$HOME/.tracebloc}"; mkdir -p "$base" 2>/dev/null
  cn="${CLUSTER_NAME:-tracebloc}"
  outdir="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-diag-XXXXXX" 2>/dev/null)"
  if [[ -z "$outdir" || ! -d "$outdir" ]]; then echo "  diagnose: cannot create a temp directory" >&2; return 1; fi
  d="$outdir/tracebloc-diagnose-$ts"; mkdir -p "$d/logs"

  # Namespace discovery — TB_NAMESPACE isn't set on a standalone diagnose run,
  # so find the namespace of the jobs-manager pod (falls back to "default").
  # Every kubectl call below carries --request-timeout: run_diagnose runs `set +e`
  # so a non-zero exit is harmless, but that does NOT bound an indefinite BLOCK —
  # and --diagnose is exactly the "API may be wedged" path, where an unbounded
  # call would freeze the bundle this function exists to produce.
  local kt="--request-timeout=5s"
  ns="${TB_NAMESPACE:-}"
  if [[ -z "$ns" ]] && has kubectl; then
    ns="$(kubectl get pods -A $kt 2>/dev/null | awk '/-jobs-manager/{print $1; exit}')"
  fi
  [[ -z "$ns" ]] && ns="default"

  # Surface the client version first — the #1 thing support needs to know.
  local cver; cver="$(_chart_version "$ns")"
  info "tracebloc client version: ${cver:-unknown}   (namespace: $ns)"
  info "Collecting diagnostics — this is safe; credentials are redacted before the file is written."

  # RFC 0001 host audit — read-only capability/privilege probe + install tier.
  # --diagnose installs nothing, so showing the detected tier here is honest and
  # useful for support. Guarded: a stale bootstrap may not have fetched probe.sh.
  # Sets PROBE_*/INSTALL_TIER, which the 00-host.txt section below records.
  if declare -F host_audit >/dev/null 2>&1; then
    host_audit
  fi

  # ── host / versions ──
  {
    echo "# tracebloc diagnose ($ts)"
    echo "OS:   $(uname -s) $(uname -r)"
    echo "ARCH: $(uname -m)"
    echo "CLIENT_ENV: ${CLIENT_ENV:-<unset>}   CLUSTER_NAME: $cn   NAMESPACE: $ns"
    echo "CLIENT VERSION: ${cver:-unknown}"
    echo; echo "## versions"
    has k3d     && k3d version
    has kubectl && kubectl version --client 2>/dev/null
    has helm    && helm version --short 2>/dev/null
    has docker  && docker version 2>/dev/null
    echo; echo "## cpu / mem / disk"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "ncpu=$(sysctl -n hw.ncpu 2>/dev/null)  memsize=$(sysctl -n hw.memsize 2>/dev/null)"
    else
      echo "nproc=$(nproc 2>/dev/null)"; grep -i MemTotal /proc/meminfo 2>/dev/null
    fi
    df -h 2>/dev/null | head -20
    if has docker; then
      echo; echo "## docker info"
      docker info 2>/dev/null | grep -iE 'Server Version|Storage Driver|Docker Root|Operating System|Total Memory|CPUs|Cgroup'
    fi
    # RFC 0001 install-tier readout (set by host_audit above; plain for the bundle).
    if declare -F run_host_probes >/dev/null 2>&1; then
      echo; echo "## install tier (RFC 0001)"
      echo "INSTALL_TIER=${INSTALL_TIER:-?}  reason=${INSTALL_TIER_REASON:-?}"
      echo "runtime_usable=${PROBE_RUNTIME_USABLE:-?}  privilege=${PROBE_PRIVILEGE:-?}  cgroup2=${PROBE_CGROUP2:-?}  userns=${PROBE_USERNS:-?}"
    fi
  } > "$d/00-host.txt" 2>&1

  # ── docker / k3d ──
  {
    echo "## docker ps -a (k3d nodes)"
    has docker && docker ps -a --filter "name=k3d-${cn}-" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    echo; echo "## k3d cluster list"
    has k3d && k3d cluster list
    echo; echo "## node restart policy + proxy env"
    if has docker; then
      for c in $(docker ps -a --filter "name=k3d-${cn}-" --format '{{.Names}}' 2>/dev/null); do
        echo "### $c"
        docker inspect "$c" --format 'RestartPolicy={{.HostConfig.RestartPolicy.Name}}' 2>/dev/null
        docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -iE 'PROXY'
      done
    fi
  } > "$d/01-docker.txt" 2>&1

  # ── kubectl overview + per-pod detail ──
  if has kubectl; then
    {
      echo "## nodes";        kubectl get nodes -o wide $kt 2>&1
      echo; echo "## pods (all namespaces)"; kubectl get pods -A -o wide $kt 2>&1
      echo; echo "## workloads"; kubectl get deploy,ds,sts -A $kt 2>&1
      echo; echo "## recent events"; kubectl get events -A --sort-by=.lastTimestamp $kt 2>&1 | tail -120
    } > "$d/02-kubectl.txt" 2>&1
    {
      echo "## describe of non-Running pods in namespace '$ns'"
      for p in $(kubectl get pods -n "$ns" --no-headers $kt 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1}'); do
        echo; echo "### $p"; kubectl describe pod -n "$ns" "$p" $kt 2>&1
      done
    } > "$d/03-describe.txt" 2>&1
    # workload logs (current + previous)
    local w
    for w in mysql-client "${ns}-jobs-manager" "${ns}-requests-proxy"; do
      kubectl logs -n "$ns" "deploy/$w" --all-containers --tail=500 $kt           > "$d/logs/${w}.log" 2>&1
      kubectl logs -n "$ns" "deploy/$w" --all-containers --previous --tail=500 $kt > "$d/logs/${w}.previous.log" 2>&1
    done
    kubectl logs -n "$ns" "daemonset/tracebloc-resource-monitor" --tail=300 $kt   > "$d/logs/resource-monitor.log" 2>&1
  fi

  # ── helm (redacted afterwards) ──
  # helm has no --request-timeout; it talks to the same API. Only run it when a
  # BOUNDED probe confirms the API is reachable, so a wedged API can't hang the
  # bundle here (the kubectl output above already captured the degraded state).
  if has helm && { ! has kubectl || kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; }; then
    # NOTE: deliberately NOT collecting `helm get manifest` — it renders the
    # Secret objects with base64-encoded credentials (CLIENT_PASSWORD,
    # .dockerconfigjson), which the text redaction can't see. `helm get values`
    # (input values, redacted) + the kubectl output already cover triage.
    {
      echo "## helm list -A";          helm list -A 2>&1
      echo; echo "## helm get values $ns"; helm get values "$ns" -n "$ns" 2>&1
    } > "$d/04-helm.txt" 2>&1
  elif has helm; then
    echo "## helm skipped — API unreachable (bounded cluster-info probe failed)" > "$d/04-helm.txt" 2>&1
  fi

  # ── install artifacts (copied, redacted afterwards) ──
  cp "$base"/install-*.log "$d/" 2>/dev/null
  [[ -f "$base/values.yaml" ]] && cp "$base/values.yaml" "$d/values.yaml" 2>/dev/null

  # ── proxy / env ──
  {
    echo "## proxy environment"
    local v
    for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
      echo "$v=${!v:-<unset>}"
    done
  } > "$d/05-proxy.txt" 2>&1

  # ── REDACT every collected file, THEN archive ──
  _redact_tree "$d"

  local bundle="$base/tracebloc-diagnose-$ts.tgz"
  tar -czf "$bundle" -C "$outdir" "tracebloc-diagnose-$ts" 2>/dev/null
  rm -rf "$outdir" 2>/dev/null

  echo ""
  if [[ -f "$bundle" ]]; then
    success "Diagnostics saved (credentials redacted):"
    echo "    $bundle"
    hint "Send this file to tracebloc support — it has logs + status with passwords removed."
    return 0
  fi
  echo "  Could not create the diagnostics archive." >&2
  return 1
}
