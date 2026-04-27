#!/usr/bin/env bash
# =============================================================================
#  install-client-helm.sh — Install Tracebloc client (steps 3 & 4)
#  Generates values from defaults + user prompts (workspace, clientId, clientPassword)
#  and GPU detection. Values file is written to HOST_DATA_DIR/values.yaml.
# =============================================================================

TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
TRACEBLOC_HELM_REPO_NAME="tracebloc"
TRACEBLOC_CHART_NAME="client"

_ensure_helm_runnable() {
  if helm version --short &>/dev/null; then
    return 0
  fi
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -z "$helm_bin" || ! -f "$helm_bin" ]]; then
    error "Installation tools are not available. Re-run the installer."
  fi
  if [[ ! -x "$helm_bin" ]]; then
    log "Helm at $helm_bin is not executable — fixing permissions"
    if sudo chmod 755 "$helm_bin" 2>/dev/null; then
      log "Helm permissions fixed."
      return 0
    fi
    error "Could not fix tool permissions. Run manually: sudo chmod 755 $helm_bin"
  fi
  error "Installation tools could not be run. Try: sudo chmod 755 $helm_bin then re-run this script."
}

_extract_yaml_value() {
  local file="$1" key="$2"
  local line
  line=$(grep -E "^${key}:" "$file" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return
  line="${line#*:}"
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == \'*\' ]]; then
    line="${line#\'}"
    line="${line%\'}"
    line="${line//\'\'/\'}"
  else
    line="${line#\"}"
    line="${line%\"}"
  fi
  printf '%s' "$line"
}

# Sanitize workspace name to comply with DNS-1123 (lowercase, alphanumeric + hyphens)
_sanitize_workspace_name() {
  local input="$1"
  local sanitized
  sanitized=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  sanitized="${sanitized// /-}"
  sanitized="${sanitized//_/-}"
  sanitized=$(printf '%s' "$sanitized" | sed 's/[^a-z0-9-]//g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/--*/-/g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/^-//; s/-$//')
  if [[ -z "$sanitized" ]]; then
    sanitized="default"
  fi
  if [[ ${#sanitized} -gt 63 ]]; then
    sanitized="${sanitized:0:63}"
    sanitized=$(printf '%s' "$sanitized" | sed 's/-$//')
  fi
  printf '%s' "$sanitized"
}

install_client_helm() {
  # ── Step 3/4: Install tracebloc client ───────────────────────────────────
  step 3 4 "Installing tracebloc client"

  _ensure_tracebloc_dirs
  local values_file="${HOST_DATA_DIR}/values.yaml"

  # ── Dev-mode override: caller-supplied values file ───────────────────────
  # When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
  # and use the provided file as-is. Used for local testing against an
  # unreleased chart (pair with TRACEBLOC_CHART_PATH).
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
    values_file="$TRACEBLOC_VALUES_FILE"
    TB_NAMESPACE="${TB_NAMESPACE:-default}"
    info "Dev mode: using caller-provided values file"
    log "Using values file: $values_file (namespace: $TB_NAMESPACE)"
  else

  local use_existing=""
  local default_namespace="default"
  local default_client_id=""
  local default_client_password=""

  if [[ -f "$values_file" ]]; then
    hint "Previous configuration found."
    while true; do
      read -r -p "  Use previous settings as defaults? [Y/n]: " use_existing
      use_existing="$(echo "${use_existing}" | tr '[:upper:]' '[:lower:]')"
      [[ "$use_existing" == "y" || "$use_existing" == "yes" || "$use_existing" == "n" || "$use_existing" == "no" || -z "$use_existing" ]] && break
      warn "Please enter y or n."
    done
    if [[ "$use_existing" == "y" || "$use_existing" == "yes" || -z "$use_existing" ]]; then
      default_client_id=$(_extract_yaml_value "$values_file" "clientId")
      default_client_password=$(_extract_yaml_value "$values_file" "clientPassword")
      [[ -n "$default_client_id" ]] && log "Using existing clientId as default."
      [[ -n "$default_client_password" ]] && log "Using existing clientPassword as default."
    fi
  fi

  # ── Workspace name prompt ────────────────────────────────────────────────
  prompt_header "Choose a workspace name"
  hint "This identifies your tracebloc client on this machine."
  echo ""
  hint "Examples: berlin-team, vision-lab, ml-mardan"
  echo ""
  read -r -p "  Workspace name [${default_namespace}]: " TB_NAMESPACE_INPUT
  local raw_name="${TB_NAMESPACE_INPUT:-$default_namespace}"
  TB_NAMESPACE=$(_sanitize_workspace_name "$raw_name")

  if [[ "$TB_NAMESPACE" != "$raw_name" ]]; then
    info "Using workspace: ${BOLD}${TB_NAMESPACE}${RESET}"
  fi

  # ── Step 4/4: Connect to tracebloc network ──────────────────────────────
  step 4 4 "Connect to tracebloc network"

  prompt_header "To connect this machine, you need a tracebloc client."
  hint "A client links your secure environment to the tracebloc"
  hint "platform so vendors can submit models for evaluation."
  echo ""
  hint "Create one here (free):"
  echo -e "    ${BOLD}${WHITE}https://ai.tracebloc.io/clients${RESET}"
  echo ""

  if [[ -n "$default_client_id" ]]; then
    read -r -p "  Client ID [${default_client_id}]: " TB_CLIENT_ID_INPUT
    TB_CLIENT_ID="${TB_CLIENT_ID_INPUT:-$default_client_id}"
  else
    read -r -p "  Client ID: " TB_CLIENT_ID
  fi
  [[ -z "$TB_CLIENT_ID" ]] && error "Client ID cannot be empty."

  if [[ -n "$default_client_password" ]]; then
    read -r -s -p "  Client password [press Enter to keep existing]: " TB_CLIENT_PASSWORD_INPUT
    echo ""
    TB_CLIENT_PASSWORD="${TB_CLIENT_PASSWORD_INPUT:-$default_client_password}"
  else
    read -r -s -p "  Client password: " TB_CLIENT_PASSWORD
    echo ""
  fi
  [[ -z "$TB_CLIENT_PASSWORD" ]] && error "Client password cannot be empty."

  TB_CLIENT_PASSWORD_ESCAPED="${TB_CLIENT_PASSWORD//\'/\'\'}"

  # ── GPU limits ──────────────────────────────────────────────────────────
  local gpu_val
  if [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    gpu_val="nvidia.com/gpu=1"
    log "NVIDIA GPU detected — setting GPU_LIMITS and GPU_REQUESTS to nvidia.com/gpu=1"
  else
    gpu_val=""
    log "No NVIDIA GPU — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"
  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "${CLIENT_ENV:-}" ] && printf '  CLIENT_ENV: "%s"\n' "$CLIENT_ENV")
  RESOURCE_LIMITS: "cpu=2,memory=8Gi"
  RESOURCE_REQUESTS: "cpu=2,memory=8Gi"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  RUNTIME_CLASS_NAME: ""

storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true

pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true

clientId: "$TB_CLIENT_ID"
clientPassword: '$TB_CLIENT_PASSWORD_ESCAPED'

EOF

  chmod 600 "$values_file" 2>/dev/null || true
  log "Values file written to $values_file"
  fi

  _ensure_helm_runnable

  # ── Resolve chart reference: local path (dev) or remote repo (default) ──
  local chart_ref
  if [[ -n "${TRACEBLOC_CHART_PATH:-}" ]]; then
    [[ -d "$TRACEBLOC_CHART_PATH" ]] || error "TRACEBLOC_CHART_PATH not found: $TRACEBLOC_CHART_PATH"
    chart_ref="$TRACEBLOC_CHART_PATH"
    info "Dev mode: using local chart at $chart_ref"
    log "Using local chart: $chart_ref"
  else
    if ! helm repo list 2>/dev/null | grep -q "^${TRACEBLOC_HELM_REPO_NAME}[[:space:]]"; then
      log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
      helm repo add "$TRACEBLOC_HELM_REPO_NAME" "$TRACEBLOC_HELM_REPO_URL" >> "${LOG_FILE:-/dev/null}" 2>&1
    fi
    log "Updating Helm repos..."
    helm repo update >> "${LOG_FILE:-/dev/null}" 2>&1
    chart_ref="$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME"
  fi

  echo ""
  log "Installing $TB_NAMESPACE from $chart_ref in namespace '$TB_NAMESPACE'..."

  # Pre-create per-release hostPath dirs so they're owned by the host user, not
  # root:root from kubelet's DirectoryOrCreate. See _ensure_release_dirs.
  _ensure_release_dirs "$TB_NAMESPACE"

  local helm_log
  helm_log="$(mktemp)"
  if ! helm upgrade --install "$TB_NAMESPACE" "$chart_ref" \
    --namespace "$TB_NAMESPACE" \
    --create-namespace \
    --values "$values_file" > "$helm_log" 2>&1; then
    log "Helm install failed — output:"
    cat "$helm_log" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
    cat "$helm_log" >&2
    rm -f "$helm_log"
    error "Client installation failed. Check the log for details: ${LOG_FILE:-}"
  fi
  cat "$helm_log" >> "${LOG_FILE:-/dev/null}" 2>/dev/null
  rm -f "$helm_log"

  success "Connected to tracebloc"
  log "Values file: $values_file"
}
