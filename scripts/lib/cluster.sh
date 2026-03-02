#!/usr/bin/env bash
# =============================================================================
#  cluster.sh — k3d cluster creation, start, and kubeconfig merge
# =============================================================================

# Exact cluster name match (avoids "tracebloc" matching "tracebloc2")
_cluster_exists() {
  if command -v jq &>/dev/null; then
    k3d cluster list -o json 2>/dev/null | jq -e --arg n "$CLUSTER_NAME" '(.[] | select(.name == $n)) != null' >/dev/null 2>&1
  else
    k3d cluster list --no-headers 2>/dev/null | awk -v n="$CLUSTER_NAME" '$1 == n { exit 0 } END { exit 1 }'
  fi
}

create_cluster() {
  step "Creating k3d Cluster: '$CLUSTER_NAME'"

  if _cluster_exists; then
    _handle_existing_cluster
  else
    _create_new_cluster
  fi

  _merge_kubeconfig
  _wait_for_api
}

_handle_existing_cluster() {
  # Get serversRunning for this cluster only (jq preferred; fallback to table parsing)
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
    success "Cluster '$CLUSTER_NAME' already running — skipping creation."
  else
    info "Cluster '$CLUSTER_NAME' exists but is stopped — starting it..."
    k3d cluster start "$CLUSTER_NAME"
    success "Cluster started."
  fi
}

_create_new_cluster() {
  if [[ ! -d "$HOST_DATA_DIR" ]]; then
    info "Creating host data directory: $HOST_DATA_DIR"
    mkdir -p "$HOST_DATA_DIR"
  fi

  K3D_ARGS=(
    cluster create "$CLUSTER_NAME"
    --servers "$SERVERS"
    --agents  "$AGENTS"
    --port "${HTTP_PORT}:80@loadbalancer"
    --port "${HTTPS_PORT}:443@loadbalancer"
    --api-port 6550
    -v "${HOST_DATA_DIR}:/tracebloc@all"
    --wait
  )

  # Empty or "latest" = k3d default; otherwise use pinned image
  [[ -n "$K8S_VERSION" && "$K8S_VERSION" != "latest" ]] && K3D_ARGS+=(--image "rancher/k3s:${K8S_VERSION}")

  if [[ ${#K3D_GPU_FLAGS[@]} -gt 0 ]]; then
    K3D_ARGS+=("${K3D_GPU_FLAGS[@]}")
    info "GPU flag(s) active: ${K3D_GPU_FLAGS[*]}"
    info "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) + GPU passthrough..."
  else
    info "Creating cluster with $SERVERS server(s) + $AGENTS agent(s) (CPU-only)..."
  fi
  info "(First run pulls the k3s image — takes ~1 min on a fast connection)"

  k3d "${K3D_ARGS[@]}"
  success "Cluster '$CLUSTER_NAME' created and ready!"
}

_merge_kubeconfig() {
  mkdir -p "${HOME}/.kube"
  export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
  k3d kubeconfig merge "$CLUSTER_NAME" \
    --kubeconfig-merge-default \
    --kubeconfig-switch-context \
    >/dev/null 2>&1
  success "kubeconfig updated — kubectl now points to '$CLUSTER_NAME'."
}

_wait_for_api() {
  info "Waiting for k8s API server to become ready..."
  local attempt
  for attempt in {1..30}; do
    if kubectl cluster-info &>/dev/null 2>&1; then
      success "API server reachable."
      return
    fi
    sleep 2
  done
  error "API server not reachable after 60s. Check: k3d cluster list / docker ps"
}
