#!/usr/bin/env bash
# =============================================================================
#  cluster.sh — k3d cluster creation, start, and kubeconfig merge
# =============================================================================

# Exact cluster name match (avoids "tracebloc" matching "tracebloc2").
# Uses multiple detection methods so re-runs work on all distros (e.g. SUSE where
# jq may be missing or k3d list output format differs).
_cluster_exists() {
  # 1) JSON output (exact name match) when jq is available
  if command -v jq &>/dev/null; then
    if k3d cluster list -o json 2>/dev/null | jq -e --arg n "$CLUSTER_NAME" '(.[] | select(.name == $n)) != null' >/dev/null 2>&1; then
      return 0
    fi
  fi
  # 2) Table format: first column is cluster name (--no-headers)
  if k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '$1 == n { exit 0 } END { exit 1 }'; then
    return 0
  fi
  # 3) Fallback: any line whose first column equals CLUSTER_NAME (handles varying table layout)
  if k3d cluster list 2>/dev/null | grep -qE "^[[:space:]]*${CLUSTER_NAME}[[:space:]]"; then
    return 0
  fi
  return 1
}

# Ensure host dirs exist so /tracebloc/data, /tracebloc/logs, /tracebloc/mysql exist inside nodes (HOST_DATA_DIR is mounted as /tracebloc).
# Only chmod the container data subdirs; do not make HOST_DATA_DIR or files like values.yaml world-readable.
_ensure_tracebloc_dirs() {
  mkdir -p "$HOST_DATA_DIR" "$HOST_DATA_DIR/data" "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql"
  chmod -R 777 "$HOST_DATA_DIR/data" "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql" 2>/dev/null || true
}

# Pre-create the per-release host dirs the chart's hostPath PVs bind to.
# The PVs use /tracebloc/<release>/{data,logs,mysql}, which maps back to
# $HOST_DATA_DIR/<release>/{data,logs,mysql} on the host via the k3d -v mount.
# Without pre-creating these as the host user, kubelet's DirectoryOrCreate
# makes them root:root 0755 and the host user can't drop training data into
# /data/shared.
_ensure_release_dirs() {
  local release="$1"
  [[ -z "$release" ]] && return 0
  local base="$HOST_DATA_DIR/$release"
  mkdir -p "$base/data" "$base/logs" "$base/mysql"
  chmod -R 777 "$base/data" "$base/logs" "$base/mysql" 2>/dev/null || true
}

# --- Corporate-proxy support (authenticated proxies + NO_PROXY hardening) ----
# Cluster-internal destinations that must NEVER be routed through a corporate
# proxy: loopback, all RFC1918 private ranges (covers the k3s pod CIDR
# 10.42.0.0/16, the service CIDR 10.43.0.0/16, the k3d docker network and node
# IPs in one shot), and the in-cluster DNS suffixes. Sending this traffic out to
# the proxy misroutes in-cluster calls AND makes `k3d cluster create --wait`
# hang. We union these into whatever NO_PROXY the host set. (A tenant that needs
# a *proxied* private-IP destination can narrow this; tracebloc itself only
# pulls from public registries + dials public api.tracebloc.io, so the broad
# bypass is safe for the isolated VM the client runs on.)
TB_NO_PROXY_DEFAULTS="localhost,127.0.0.1,0.0.0.0,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local,host.k3d.internal"

# Echo an effective NO_PROXY = host NO_PROXY/no_proxy ∪ TB_NO_PROXY_DEFAULTS,
# de-duplicated with first-seen order preserved (host entries first).
_augment_no_proxy() {
  local existing="${NO_PROXY:-${no_proxy:-}}"
  printf '%s,%s' "$existing" "$TB_NO_PROXY_DEFAULTS" \
    | awk -v RS=',' '{ gsub(/[ \t\r\n]/, ""); if ($0 != "" && !seen[$0]++) printf "%s%s", (n++ ? "," : ""), $0 }'
}

# Build a k3d config file that carries the proxy env vars as structured YAML
# entries, and echo its path. We use --config rather than --env KEY=VALUE@FILTER
# because k3d splits the --env flag on '@', which corrupts authenticated-proxy
# URLs (http://user:pass@host); the YAML env list has no such ambiguity, so
# credentials survive intact. NO_PROXY is always emitted (auto-augmented) when a
# proxy is present, so in-cluster traffic bypasses the proxy even if the host
# set only HTTP_PROXY. Echoes nothing when the host has no HTTP(S) proxy set.
_write_k3d_proxy_config() {
  local var have_http=""
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ -n "${!var:-}" ]] && have_http=1
  done
  [[ -z "$have_http" ]] && return 0

  local no_proxy_val; no_proxy_val="$(_augment_no_proxy)"
  # mktemp -d with trailing X's is portable across GNU + BSD/macOS mktemp; a
  # plain file template with a '.yaml' suffix is not (BSD needs trailing X's),
  # and k3d/viper needs the '.yaml' extension to parse the config — so the file
  # lives inside a temp dir. Caller removes the dir.
  local td; td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3d-XXXXXX")" || return 0
  local cfg="$td/config.yaml"
  {
    echo "apiVersion: k3d.io/v1alpha5"
    echo "kind: Simple"
    echo "env:"
    for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
      [[ -z "${!var:-}" ]] && continue
      printf '  - envVar: "%s=%s"\n    nodeFilters:\n      - all\n' "$var" "${!var}"
    done
    printf '  - envVar: "NO_PROXY=%s"\n    nodeFilters:\n      - all\n' "$no_proxy_val"
    printf '  - envVar: "no_proxy=%s"\n    nodeFilters:\n      - all\n' "$no_proxy_val"
  } > "$cfg"
  echo "$cfg"
}

# When a proxy is configured, ensure THIS installer's own kubectl/helm/curl
# bypass it for the cluster API (127.0.0.1) and the in-cluster ranges. Go
# already auto-bypasses loopback, but exporting NO_PROXY also covers helm/curl.
_export_host_no_proxy() {
  local var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!var:-}" ]]; then
      local aug; aug="$(_augment_no_proxy)"
      export NO_PROXY="$aug" no_proxy="$aug"
      return 0
    fi
  done
}

create_cluster() {
  log "Creating k3d cluster: '$CLUSTER_NAME'"

  _ensure_tracebloc_dirs

  if _cluster_exists; then
    _handle_existing_cluster
  else
    _create_new_cluster
  fi

  ensure_cluster_autostart
  _merge_kubeconfig
  _export_host_no_proxy
  _wait_for_api
}

# Guarantee the cluster returns after a host reboot. On Linux this already works
# by default — k3d sets `--restart unless-stopped` on its node containers and the
# Docker install enables docker.service on boot — but we harden both so it holds
# even on a re-run where Docker was installed-but-disabled, or for an externally-
# created cluster. On macOS/Windows the restart policy is set too, but Docker
# Desktop must be configured to start on login (the summary tells the user).
# Opt out with TRACEBLOC_NO_AUTOSTART=1.
ensure_cluster_autostart() {
  if [[ -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then return 0; fi

  local nodes node
  nodes=$(docker ps -a --filter "name=k3d-${CLUSTER_NAME}-" --format '{{.Names}}' 2>/dev/null) || return 0
  if [[ -n "$nodes" ]]; then
    for node in $nodes; do
      docker update --restart unless-stopped "$node" >/dev/null 2>&1 || true
    done
    log "Set restart=unless-stopped on k3d nodes so the cluster returns after a reboot."
  fi

  # On Linux, make sure Docker itself starts on boot. The fresh-install path only
  # enables docker.service when Docker was absent; this also covers the
  # installed-but-disabled re-run case. Idempotent.
  if [[ "$OS" == "Linux" ]] && has systemctl; then
    if sudo systemctl enable docker >/dev/null 2>&1; then
      log "Ensured docker.service is enabled on boot."
    fi
  fi
  return 0
}

_handle_existing_cluster() {
  CLUSTER_STATUS="0"
  if command -v jq &>/dev/null; then
    CLUSTER_STATUS=$(k3d cluster list -o json 2>/dev/null | jq -r --arg n "$CLUSTER_NAME" '.[] | select(.name == $n) | .serversRunning // 0' 2>/dev/null || echo "0")
  else
    local line
    line=$(k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '$1 == n { print $2; exit }')
    if [[ -n "$line" ]]; then
      CLUSTER_STATUS="${line%%/*}"
    fi
  fi
  CLUSTER_STATUS="${CLUSTER_STATUS:-0}"

  if [[ "$CLUSTER_STATUS" -gt "0" ]]; then
    success "Compute environment already running."
  else
    log "Cluster '$CLUSTER_NAME' exists but is stopped — starting it..."
    k3d cluster start "$CLUSTER_NAME"
    success "Compute environment started."
  fi

  _check_existing_cluster_proxy
  _check_existing_cluster_bind
}

# k3d bakes proxy env into containers at create time; it cannot be added to a
# running cluster. For each proxy var set on the host, verify the existing
# cluster has it, and warn (with the recreate remedy) on drift. Authenticated
# proxies are now propagated like any other var (via _write_k3d_proxy_config),
# so there is no longer a separate '@' bucket. Silent no-op if Docker isn't
# running, the server container can't be inspected, or no proxy env is set.
_check_existing_cluster_proxy() {
  local var candidates=()
  for var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    [[ -n "${!var:-}" ]] && candidates+=("$var")
  done
  [[ ${#candidates[@]} -eq 0 ]] && return 0

  local server_container="k3d-${CLUSTER_NAME}-server-0"
  local cluster_env
  cluster_env=$(docker inspect "$server_container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$cluster_env" ]] && return 0

  local missing=()
  for var in "${candidates[@]}"; do
    echo "$cluster_env" | grep -Eq "^${var}=" || missing+=("$var")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    warn "Host has proxy env set, but the existing '$CLUSTER_NAME' cluster is missing: ${missing[*]}."
    hint "k3d bakes proxy settings into containers at create time — they can't be added to a running cluster."
    hint "If image pulls fail or in-cluster traffic misroutes, recreate the cluster:"
    hint "  k3d cluster delete $CLUSTER_NAME  &&  re-run this installer."
    echo ""
  fi
}

# An externally-created cluster may bind its API to 0.0.0.0 rather than the
# 127.0.0.1 this installer uses. _merge_kubeconfig normalizes the kubeconfig
# (→127.0.0.1) so reuse still works, but we warn so the user understands their
# cluster differs and how to rebuild it loopback-bound if a TLS/HTTP proxy still
# intercepts external kubectl. Silent no-op if the serverlb can't be inspected.
_check_existing_cluster_bind() {
  local binds
  binds=$(docker inspect "k3d-${CLUSTER_NAME}-serverlb" \
    --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}} {{end}}{{end}}' 2>/dev/null) || return 0
  [[ -z "$binds" ]] && return 0
  if grep -qw '0\.0\.0\.0' <<<"$binds" && ! grep -qw '127\.0\.0\.1' <<<"$binds"; then
    echo ""
    warn "The existing '$CLUSTER_NAME' cluster binds its API to 0.0.0.0 (created outside this installer)."
    hint "This installer binds clusters to 127.0.0.1; behind a corporate proxy a 0.0.0.0 bind can be intercepted."
    hint "Your kubeconfig is normalized to 127.0.0.1 so reuse works. If kubectl is still intercepted, rebuild it:"
    hint "  k3d cluster delete $CLUSTER_NAME  &&  re-run this installer."
    echo ""
  fi
}

_create_new_cluster() {
  # The tracebloc client is outbound-only: jobs-manager + pods-monitor dial out
  # to the platform, and the only in-cluster Service (mysql-client) is ClusterIP.
  # So we disable k3s components that exist solely to handle inbound traffic
  # or duplicate chart-provided resources:
  #   traefik        — no Ingress resources in the chart
  #   servicelb      — no LoadBalancer Services
  #   local-storage  — chart creates its own StorageClass (client-storage-class)
  #
  # metrics-server is kept: the tracebloc-resource-monitor DaemonSet queries
  # the metrics.k8s.io API for node CPU/memory; without it the DaemonSet
  # crash-loops with 404s against /apis/metrics.k8s.io/v1beta1.
  K3D_ARGS=(
    cluster create "$CLUSTER_NAME"
    --servers "$SERVERS"
    --agents  "$AGENTS"
    --api-port 127.0.0.1:6550
    -v "${HOST_DATA_DIR}:/tracebloc@all"
    --k3s-arg "--disable=traefik@server:*"
    --k3s-arg "--disable=servicelb@server:*"
    --k3s-arg "--disable=local-storage@server:*"
    --wait
  )

  [[ -n "$K8S_VERSION" && "$K8S_VERSION" != "latest" ]] && K3D_ARGS+=(--image "rancher/k3s:${K8S_VERSION}")

  if [[ ${#K3D_GPU_FLAGS[@]} -gt 0 ]]; then
    K3D_ARGS+=("${K3D_GPU_FLAGS[@]}")
    log "GPU flag(s) active: ${K3D_GPU_FLAGS[*]}"
    log "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) + GPU passthrough..."
  else
    log "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) (CPU-only)..."
  fi
  hint "First run may take 1-2 minutes to download components."

  # Propagate corporate proxy env so k3s/containerd can reach external registries
  # behind an HTTP/HTTPS proxy (hospital/banking/government tenants). Passed via a
  # k3d --config file rather than --env: k3d splits --env on '@', which corrupts
  # authenticated-proxy URLs (http://user:pass@host), whereas the YAML env list in
  # a config file preserves them. NO_PROXY is auto-augmented with the cluster-
  # internal ranges so in-cluster traffic never traverses the proxy (which would
  # otherwise misroute it and hang `k3d cluster create --wait`). k3d merges the
  # --config env with these CLI flags (verified on k3d v5.8.3).
  local proxy_cfg
  proxy_cfg="$(_write_k3d_proxy_config)"
  if [[ -n "$proxy_cfg" ]]; then
    K3D_ARGS+=(--config "$proxy_cfg")
    log "Propagating proxy settings to k3d nodes (authenticated proxies supported; NO_PROXY auto-augmented)."
  fi

  local create_out create_rc
  create_out="$(mktemp)"
  k3d "${K3D_ARGS[@]}" >"$create_out" 2>&1
  create_rc=$?
  [[ -n "$proxy_cfg" ]] && rm -rf "${proxy_cfg%/*}"
  if [[ $create_rc -ne 0 ]]; then
    if grep -qi "already exists\|a cluster with that name already exists" "$create_out" 2>/dev/null; then
      log "Cluster '$CLUSTER_NAME' already exists (detected from k3d message). Using existing cluster."
      rm -f "$create_out"
      _handle_existing_cluster
      return 0
    fi
    cat "$create_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
    cat "$create_out" >&2
    rm -f "$create_out"
    exit "$create_rc"
  fi
  cat "$create_out" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
  rm -f "$create_out"
  success "Compute environment ready."
}

_merge_kubeconfig() {
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
  k3d kubeconfig merge "$CLUSTER_NAME" \
    --kubeconfig-merge-default \
    --kubeconfig-switch-context \
    >/dev/null 2>&1

  # Defensive normalization: k3d may still emit 0.0.0.0 server URLs into the
  # kubeconfig (older k3d versions, or pre-existing entries from previous
  # installs). Behind a corporate HTTP/HTTPS proxy, 0.0.0.0 gets intercepted
  # and kubectl fails. Anchored to `https://0.0.0.0:` so CIDR ranges and other
  # 0.0.0.0 occurrences elsewhere in the file are left untouched.
  #
  # KUBECONFIG can be colon-separated (kubectl path-list semantics); k3d's
  # --kubeconfig-merge-default writes into the first entry (or ~/.kube/config
  # if KUBECONFIG is unset). Target the same file or the rewrite would be
  # skipped by -f on multi-file layouts.
  local kc_target="${KUBECONFIG:-${HOME}/.kube/config}"
  kc_target="${kc_target%%:*}"
  if [[ -f "$kc_target" ]] && grep -q 'https://0\.0\.0\.0:' "$kc_target"; then
    sed -i.bak 's|https://0\.0\.0\.0:|https://127.0.0.1:|g' "$kc_target"
    rm -f "${kc_target}.bak"
    log "Normalized kubeconfig server URL: 0.0.0.0 → 127.0.0.1 in $kc_target (corporate-proxy safety)."
  fi

  log "kubeconfig updated — kubectl now points to '$CLUSTER_NAME'."
}

_wait_for_api() {
  local logfile="${LOG_FILE:-/tmp/tracebloc-spin.log}"
  local attempt max=30
  log "Waiting for API server to become ready..."

  tput civis 2>/dev/null || true
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local f=0
  for attempt in $(seq 1 $max); do
    if kubectl cluster-info &>/dev/null 2>&1; then
      printf "\r\033[K"
      tput cnorm 2>/dev/null || true
      success "Compute environment online."
      return
    fi
    printf "\r  ${CYAN}%s${RESET} Starting compute environment..." "${frames[f]}"
    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 2
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true

  # Surface the actual kubeconfig path. KUBECONFIG can be colon-separated
  # (kubectl supports a list); point at the first entry — users with custom
  # multi-file layouts can adapt the sed command themselves.
  local kc="${KUBECONFIG:-${HOME}/.kube/config}"
  kc="${kc%%:*}"
  error "kubectl cluster-info failed for 60s. Cluster reports running, but the API is unreachable. Possible causes:
   (a) Docker daemon stopped (run 'docker ps' to verify);
   (b) corporate HTTP/HTTPS proxy intercepting localhost — this installer auto-adds 127.0.0.1/localhost + private ranges to NO_PROXY; a custom proxy wrapper may still override it;
   (c) kubeconfig has 0.0.0.0 — try: sed -i.bak 's|0.0.0.0|127.0.0.1|g' ${kc} && rm ${kc}.bak"
}
