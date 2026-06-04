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
  # Defend against self-perpetuation: a previous corrupted save may have the
  # bracketed-paste markers and/or C0 controls (#168). _strip_paste_garbage
  # handles both. UTF-8 (0x80+) preserved.
  _strip_paste_garbage "$line"
}

# Strip ANSI escape sequences and C0 control characters from a value.
# `read -r -s` captures whatever the terminal sends — this can include:
#   • bracketed-paste wrappers:  ESC[200~ ... ESC[201~
#   • arrow keys / cursor moves: ESC[A/B/C/D, ESC[1;5C, ESC[3~ (Delete), …
#   • function keys, modifier combos, mode-switch sequences
# All follow the ANSI CSI shape:  ESC '[' <params> <final-byte>
# where params ∈ [0-9;] and final ∈ [A-Za-z~]. Strip them iteratively to
# handle consecutive sequences (e.g. paste-wrappers).
#
# Also handles the post-corruption case where ESC was stripped by an earlier
# (buggy) sanitizer but the literal `[200~`/`[201~` markers survived. Only
# self-heals the two well-defined bracketed-paste markers — generic `[X]`
# shapes could plausibly be real password content.
#
# UTF-8 bytes (0x80+) preserved so international characters survive.
_strip_paste_garbage() {
  local s="$1"
  local esc=$'\e'
  local csi_pattern="${esc}\\[[0-9;]*[A-Za-z~]"
  while [[ "$s" =~ $csi_pattern ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//\[200\~/}"
  s="${s//\[201\~/}"
  printf '%s' "$s" | tr -d '\000-\037\177'
}

# Sanitize a user-entered credential. Calls _strip_paste_garbage and notifies
# the user on stderr (NOT stdout — this function is called from inside $(...),
# so stdout is captured into the credential value itself).
_sanitize_credential() {
  local input="$1"
  local clean
  clean=$(_strip_paste_garbage "$input")
  if [[ "$clean" != "$input" ]]; then
    warn "Stripped non-printable / paste-mode characters from input." >&2
  fi
  printf '%s' "$clean"
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

# ── Credential verification (#717) ────────────────────────────────────────
# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: CLIENT_ENV → backend), defaulting to prod.
_backend_url() {
  case "${CLIENT_ENV:-prod}" in
    dev) printf 'https://dev-api.tracebloc.io/' ;;
    stg) printf 'https://stg-api.tracebloc.io/' ;;
    *)   printf 'https://api.tracebloc.io/' ;;
  esac
}

# Validate the entered Client ID / password against the backend's
# api-token-auth/ endpoint — the same call jobs-manager makes at runtime —
# using curl (already a dependency). Echoes: valid | invalid | inactive | unverified.
verify_credentials() {
  local client_id="$1" client_password="$2" backend code
  backend="$(_backend_url)"
  code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' \
    --data-urlencode "username=${client_id}" \
    --data-urlencode "password=${client_password}" \
    "${backend}api-token-auth/" 2>/dev/null) || code="000"
  case "$code" in
    200) printf 'valid' ;;
    400) printf 'invalid' ;;
    401) printf 'inactive' ;;
    *)   printf 'unverified' ;;   # 429 throttled, 000 unreachable, 5xx, …
  esac
}

install_client_helm() {
  # ── Step 3/4: Install tracebloc client ───────────────────────────────────
  step 3 5 "Installing tracebloc client"

  _ensure_tracebloc_dirs
  local values_file="${HOST_DATA_DIR}/values.yaml"

  # ── Dev-mode override: caller-supplied values file ───────────────────────
  # When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
  # and use the provided file as-is. Used for local testing against an
  # unreleased chart (pair with TRACEBLOC_CHART_PATH).
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
    values_file="$TRACEBLOC_VALUES_FILE"
    TB_NAMESPACE="${TB_NAMESPACE:-tracebloc}"
    info "Dev mode: using caller-provided values file"
    log "Using values file: $values_file (namespace: $TB_NAMESPACE)"
  else

  local use_existing=""
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

  # ── Namespace (fixed; not prompted) ──────────────────────────────────────
  # The on-prem client is one-per-machine and is identified to the backend by
  # its credentials (clientId), not by this name — so we don't ask the user to
  # invent one. It's just the local k8s namespace / Helm release name.
  # Advanced / GitOps setups can override with TB_NAMESPACE=<name>.
  TB_NAMESPACE=$(_sanitize_workspace_name "${TB_NAMESPACE:-tracebloc}")

  # ── Step 4/4: Connect to tracebloc network ──────────────────────────────
  step 4 5 "Connect to tracebloc network"

  prompt_header "To connect this machine, you need a tracebloc client."
  hint "A client links your secure environment to the tracebloc"
  hint "platform so vendors can submit models for evaluation."
  echo ""
  hint "Create one here (free):"
  echo -e "    ${BOLD}${WHITE}https://ai.tracebloc.io/clients${RESET}"
  echo ""

  # Collect + verify credentials. The entered Client ID / password are checked
  # against the backend (the same api-token-auth/ call jobs-manager makes)
  # before we deploy, so a wrong credential is caught here — with a re-prompt —
  # instead of surfacing later as a silently crash-looping pod.
  local _cred_attempt=0 _cred_max=5 _cred_status
  while true; do
    if [[ -n "$default_client_id" ]]; then
      read -r -p "  Client ID [${default_client_id}]: " TB_CLIENT_ID_INPUT
      TB_CLIENT_ID="${TB_CLIENT_ID_INPUT:-$default_client_id}"
    else
      read -r -p "  Client ID: " TB_CLIENT_ID
    fi
    TB_CLIENT_ID=$(_sanitize_credential "$TB_CLIENT_ID")
    if [[ -z "$TB_CLIENT_ID" ]]; then warn "Client ID cannot be empty."; continue; fi

    if [[ -n "$default_client_password" ]]; then
      read -r -s -p "  Client password [press Enter to keep existing]: " TB_CLIENT_PASSWORD_INPUT
      echo ""
      TB_CLIENT_PASSWORD="${TB_CLIENT_PASSWORD_INPUT:-$default_client_password}"
    else
      read -r -s -p "  Client password: " TB_CLIENT_PASSWORD
      echo ""
    fi
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TB_CLIENT_PASSWORD")
    if [[ -z "$TB_CLIENT_PASSWORD" ]]; then warn "Client password cannot be empty."; continue; fi

    info "Verifying credentials with tracebloc…"
    _cred_status=$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")
    case "$_cred_status" in
      valid)
        success "Credentials verified."
        break ;;
      invalid)
        warn "That Client ID / password was rejected by tracebloc — please re-enter."
        hint "Find your credentials at https://ai.tracebloc.io/clients" ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified)
        warn "Couldn't reach tracebloc to verify your credentials right now — continuing."
        hint "If they are wrong, your client will stay offline at https://ai.tracebloc.io/clients after install."
        break ;;
    esac

    _cred_attempt=$((_cred_attempt + 1))
    if [[ $_cred_attempt -ge $_cred_max ]]; then
      error "Too many failed attempts. Double-check your credentials at https://ai.tracebloc.io/clients and re-run."
    fi
    # Force an active re-entry on retry (don't silently reuse a rejected default).
    default_client_id=""; default_client_password=""
  done

  # ── One-client-per-machine guard ─────────────────────────────────────────
  # A machine runs exactly one tracebloc client: it shares this cluster and the
  # host's CPU/RAM/GPU, and the platform counts each client as separate
  # capacity. If a DIFFERENT client is already installed here, a re-install
  # would silently re-point the machine — so we stop and let the operator
  # decide. The same clientId is a normal re-run/upgrade and passes through.
  # Check ANY namespace: a fresh install lands in `tracebloc`, but an install
  # from an older installer version may be in a different namespace. Enumerate
  # client-chart releases and read each clientId. jq is already used elsewhere
  # in the installer; if it's somehow absent, fall back to the `tracebloc` ns.
  local existing_id="" existing_ns="" _gvf _rel _ns _id
  _gvf="$(mktemp)"
  if has jq; then
    while IFS=$'\t' read -r _rel _ns; do
      [[ -z "$_rel" ]] && continue
      if helm get values "$_rel" -n "$_ns" > "$_gvf" 2>/dev/null; then
        _id="$(_extract_yaml_value "$_gvf" clientId)"
        [[ -n "$_id" ]] && { existing_id="$_id"; existing_ns="$_ns"; break; }
      fi
    done < <(helm list -A -o json 2>/dev/null | jq -r '.[] | select((.chart // "") | startswith("client-")) | "\(.name)\t\(.namespace)"')
  elif helm get values "$TB_NAMESPACE" -n "$TB_NAMESPACE" > "$_gvf" 2>/dev/null; then
    existing_id="$(_extract_yaml_value "$_gvf" clientId)"; existing_ns="$TB_NAMESPACE"
  fi
  rm -f "$_gvf"
  if [[ -n "$existing_id" && "$existing_id" != "$TB_CLIENT_ID" ]]; then
    echo ""
    warn "This machine already runs the tracebloc client '${existing_id}' (namespace '${existing_ns}')."
    hint "tracebloc runs one client per machine — it shares this cluster and host"
    hint "resources, and the platform counts each client as separate capacity."
    echo ""
    hint "You entered a different Client ID ('${TB_CLIENT_ID}'). Pick one:"
    hint "  • Repair / update '${existing_id}'  →  re-run with that same Client ID"
    hint "  • Switch to '${TB_CLIENT_ID}'        →  remove the current client first:"
    hint "        k3d cluster delete ${CLUSTER_NAME:-tracebloc}   (wipes this client + its local data)"
    hint "      then re-run this installer"
    hint "  • Run both clients                   →  install on a separate machine"
    echo ""
    error "Refusing to replace the existing client. See the options above."
  fi

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
