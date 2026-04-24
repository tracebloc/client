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

create_cluster() {
  log "Creating k3d cluster: '$CLUSTER_NAME'"

  _ensure_tracebloc_dirs

  if _cluster_exists; then
    _handle_existing_cluster
  else
    _create_new_cluster
  fi

  _merge_kubeconfig
  _wait_for_api
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
}

_create_new_cluster() {
  # The tracebloc client is outbound-only: jobs-manager + pods-monitor dial out
  # to the platform, and the only in-cluster Service (mysql-client) is ClusterIP.
  # So we disable k3s components that exist solely to handle inbound traffic
  # or duplicate chart-provided resources:
  #   traefik        — no Ingress resources in the chart
  #   servicelb      — no LoadBalancer Services
  #   metrics-server — chart ships its own tracebloc-resource-monitor DaemonSet
  #   local-storage  — chart creates its own StorageClass (client-storage-class)
  K3D_ARGS=(
    cluster create "$CLUSTER_NAME"
    --servers "$SERVERS"
    --agents  "$AGENTS"
    --api-port 6550
    -v "${HOST_DATA_DIR}:/tracebloc@all"
    --k3s-arg "--disable=traefik@server:*"
    --k3s-arg "--disable=servicelb@server:*"
    --k3s-arg "--disable=metrics-server@server:*"
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

  local create_out create_rc
  create_out="$(mktemp)"
  if ! k3d "${K3D_ARGS[@]}" >"$create_out" 2>&1; then
    create_rc=$?
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
  error "Compute environment did not start within 60s. Check Docker and try again."
}
