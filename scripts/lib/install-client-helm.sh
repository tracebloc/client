#!/usr/bin/env bash
# =============================================================================
#  install-client-helm.sh — Install Tracebloc client (steps 3 & 4)
#  Generates values from defaults + user prompts (workspace, clientId, clientPassword)
#  and GPU detection. Values file is written to host_data_dir/values.yaml.
# =============================================================================

# The xtrace hold (output.sh). A no-op with an output.sh from before it, so a mixed
# set of libs runs, unheld, rather than stopping on a missing command.
declare -F _tb_trace_off >/dev/null 2>&1 || _tb_trace_off() { :; }
declare -F _tb_trace_on >/dev/null 2>&1 || _tb_trace_on() { :; }

# Stamped from scripts/spec/facts.env by scripts/check-facts.sh — do not hand-edit.
# The Windows installer waits for the same APIService with the same TB_METRICS_WAIT_S
# knob, so the two defaults are one fact, gated in CI.
METRICS_WAIT_TIMEOUT=120

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

# give the bundled metrics-server APIService a bounded window to register
# before helm renders. On a freshly created cluster k3s applies its bundled
# metrics-server (and the v1beta1.metrics.k8s.io APIService) shortly AFTER the
# API server is ready, and the API wait gates on the API, not bundled addons. The resource-monitor DaemonSet template calls
# `{{ fail }}` at render time if that APIService isn't registered yet, so on a
# slow WSL2/laptop helm can render in that window and abort the WHOLE install.
# Best-effort: if the APIService never registers here we fall through and let
# the chart's render-time guard produce its actionable error, so a genuinely
# missing metrics-server is still caught (issue's preferred option (a)).
_wait_for_metrics_apiservice() {
  # Skipped entirely under the bats suite (TRACEBLOC_SKIP_SERVICE_PROGRESS, set in setup())
  # or when kubectl is unavailable — same guard the neighbouring network-y step
  # _download_services_progress uses. Without this the poll loop below would
  # `sleep 3` up to the full ${TB_METRICS_WAIT_S:-120}s in every mocked
  # install_client_helm test (kubectl absent on the CI runner just makes each
  # `kubectl get` fail instantly, so the loop still burns its whole deadline),
  # blowing the job's 10-min deadline. Real installs never set the flag and
  # always have kubectl, so the wait is unchanged for them.
  [[ -n "${TRACEBLOC_SKIP_SERVICE_PROGRESS:-}" ]] && return 0
  has kubectl || return 0
  local _timeout_s="${TB_METRICS_WAIT_S:-}"
  case "$_timeout_s" in ''|*[!0-9]*) _timeout_s="$METRICS_WAIT_TIMEOUT" ;; *) _timeout_s=$((10#$_timeout_s)) ;; esac
  local _deadline=$(( SECONDS + _timeout_s ))
  while (( SECONDS < _deadline )); do
    if kubectl get apiservice v1beta1.metrics.k8s.io --request-timeout=10s >/dev/null 2>&1; then
      # Registered — give it a moment to also report Available, but don't fail
      # the install if it's merely slow to become ready; the DaemonSet only
      # needs the APIService present at render time.
      kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
        --timeout=30s >/dev/null 2>&1 || true
      log "metrics.k8s.io APIService registered — proceeding with helm install."
      return 0
    fi
    sleep 3
  done
  log "metrics.k8s.io APIService not registered after ${_timeout_s}s — proceeding; the chart guards if metrics-server is genuinely absent."
  return 0
}

# label + annotate a pre-existing, Helm-unowned GPU device-plugin
# DaemonSet (left by the old imperative `kubectl apply`) so `helm upgrade
# --install` adopts it in place instead of failing with "exists and cannot be
# imported into the current release". Best-effort, bounded, idempotent, and
# gated on the GPU path — GPU is optional, so nothing here may abort the install.
_adopt_orphaned_gpu_device_plugin() {
  [[ "${GPU_VENDOR:-}" == "nvidia" || "${GPU_VENDOR:-}" == "amd" ]] || return 0
  local ns="kube-system" ds
  case "${GPU_VENDOR}" in
    nvidia) ds="nvidia-device-plugin-daemonset" ;;
    amd)    ds="amdgpu-device-plugin-daemonset" ;;
  esac
  # Probe for a pre-chart imperative leftover. Distinguish "absent" (fresh host —
  # the chart just creates it) from a live API error: a wedged/slow API must NOT
  # be read as "absent", because a leftover-but-unadopted DaemonSet then makes
  # `helm upgrade --install` die with "exists and cannot be imported" and abort
  # the whole (otherwise GPU-optional) install. --request-timeout bounds the probe.
  # `|| rc=$?` (not `; rc=$?`): under set -e a bare assignment from a non-zero
  # command substitution aborts the script before the branch below runs — a
  # NotFound on a fresh GPU host would kill step e.
  local probe rc=0
  probe=$(kubectl get daemonset "$ds" -n "$ns" -o name --request-timeout=5s 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    case "$probe" in
      ""|*NotFound*|*"not found"*) return 0 ;;  # absent — nothing to adopt
      *) warn "Could not check for a pre-existing GPU device plugin ${ds} (API error); skipping adoption. If a non-Helm ${ds} exists in ${ns}, remove it before install: $(tb_kubectl_shown) delete daemonset ${ds} -n ${ns}"
         return 0 ;;
    esac
  fi
  log "Adopting pre-existing GPU device plugin ${ds} into the Helm release (migrating from the standalone install)"
  # Adoption must actually succeed — a swallowed label/annotate failure leaves an
  # unowned DS that collides with the release. If it fails, remove the orphan so
  # the chart recreates a clean Helm-owned copy (the plugin is stateless; a brief
  # re-roll is fine and keeps GPU optional) rather than bricking the install.
  if kubectl label daemonset "$ds" -n "$ns" \
       app.kubernetes.io/managed-by=Helm --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1 \
     && kubectl annotate daemonset "$ds" -n "$ns" \
       "meta.helm.sh/release-name=${namespace}" \
       "meta.helm.sh/release-namespace=${namespace}" \
       --overwrite --request-timeout=10s \
       >> "${LOG_FILE:-/dev/null}" 2>&1; then
    return 0
  fi
  warn "Could not adopt ${ds} into the Helm release; removing the orphan so the chart can recreate it."
  kubectl delete daemonset "$ds" -n "$ns" --timeout=30s --ignore-not-found \
    >> "${LOG_FILE:-/dev/null}" 2>&1 \
    || warn "Failed to remove orphaned ${ds}; if the install aborts with 'exists and cannot be imported', delete it manually: $(tb_kubectl_shown) delete daemonset ${ds} -n ${ns}"
  return 0
}

# _refuse_other_client_id ID NS -- this machine runs the secure environment ID (in
# namespace NS), and this run was given another Client ID (TB_CLIENT_ID).
_refuse_other_client_id() {
  _refuse_foreign_client "This machine runs another secure environment" \
    "To keep it, run the installer again with its Client ID." \
    "To use this Client ID instead, sign in as the account that owns it and delete it first:" \
    "This machine already runs the secure environment '${1}' (namespace '${2}'), and the Client ID given is '${TB_CLIENT_ID:-}'. tracebloc runs one secure environment per machine: it shares this cluster and the machine's resources, and tracebloc counts each one as separate capacity, so this run does not replace it."
}

# The `localApi` block of the generated values: present only when the macOS node
# (_mac_ct_ensure_node) recorded the
# mapping (TB_LOCAL_API_MAPPED=1, with the two ports it mapped), because the chart
# opens the NodePort only when it exists. An existing release gets the same decision as --set args in
# _reconcile_adopted_client.
_local_api_values_block() {
  [[ "${TB_LOCAL_API_MAPPED:-0}" == "1" ]] || return 0
  printf '\n# The local API the dashboard reaches on this machine: on, because the cluster maps\n'
  printf '# 127.0.0.1:%s to its NodePort (the macOS node: _mac_ct_ensure_node).\n' "$TRACEBLOC_LOCAL_API_HOST_PORT"
  printf 'localApi:\n  enabled: true\n  nodePort: %s\n  hostPort: %s\n  singleMachine: true\n' "$TRACEBLOC_LOCAL_API_NODE_PORT" "$TRACEBLOC_LOCAL_API_HOST_PORT"
}

# install_client_helm's stages, in the order it runs them. Each runs inside it and
# reads and sets its locals (values_file, chart_ref, ...) through bash dynamic scope.

# ── Dev-mode override: caller-supplied values file ───────────────────────
# When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
# and use the provided file as-is, except that the helm call below sets this
# run's GPU decision over it (_gpu_decision_set_args). Used for
# local testing against an unreleased chart (pair with TRACEBLOC_CHART_PATH).
_client_helm_dev_mode() {
  [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
  values_file="$TRACEBLOC_VALUES_FILE"
  namespace="${namespace:-tracebloc}"
  info "Dev mode: using caller-provided values file"
  log "Using values file: $values_file (namespace: $namespace)"
  # Gate the arch here too, before helm deploys: read the engine the caller's file
  # declares (never re-resolve: that could pick 8.4 where the file pins the
  # amd64-only 5.7 image). Preflight's early arch gate uses the same helper.
  local _dm_decision; _dm_decision="$(_devmode_engine_decision)"
  TB_MYSQL_ENGINE_RESOLVED="${_dm_decision%% *}"
  TB_MYSQL_ENGINE_REASON="${_dm_decision#* }"
  _assert_engine_runs_on_this_arch
  # The macOS node's storage steps, as the normal path takes them below: dev mode
  # installs the job-data folder too (_mac_node_profile_set_args), so it records it
  _mac_node_storage_steps
}

# Env or prompted credentials, and the previous values file's defaults for the prompt.
_client_helm_previous_config() {
  # Non-interactive credentials (non-interactive): set TRACEBLOC_CLIENT_ID +
  # TRACEBLOC_CLIENT_PASSWORD to provision without typing the secret inline
  # (CI / automation / golden images). Verified the same way as the prompt.
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  if [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -n "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]; then
    _noninteractive_creds=1
  fi
  _tb_trace_on

  if [[ "$_noninteractive_creds" == 0 && -f "$values_file" && "${TRACEBLOC_CLIENT_ADOPTED:-}" != 1 ]] && _tty_available; then
    hint "Previous configuration found."
    local _answer
    while true; do
      read -r -p "  Use previous settings as defaults? [Y/n]: " _answer <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      use_existing="$(echo "${_answer}" | tr '[:upper:]' '[:lower:]')"
      [[ "$use_existing" == "y" || "$use_existing" == "yes" || "$use_existing" == "n" || "$use_existing" == "no" || -z "$use_existing" ]] && break
      tb_choice_refused "$_answer" y/n y
    done
    if [[ "$use_existing" == "y" || "$use_existing" == "yes" || -z "$use_existing" ]]; then
      default_client_id=$(_extract_yaml_value "$values_file" "clientId")
      # The password stays out of bash -x's trace (_tb_trace_off, output.sh).
      { _tb_trace_off; } 2>/dev/null
      default_client_password=$(_extract_yaml_value "$values_file" "clientPassword")
      [[ -z "$default_client_password" ]] || log "Using existing clientPassword as default."
      _tb_trace_on
      [[ -n "$default_client_id" ]] && log "Using existing clientId as default."
    fi
  fi
  return 0
}

# The credentials: from TRACEBLOC_CLIENT_ID/PASSWORD, or the prompt; verified.
_client_helm_credentials() {
  # Every line from here to the end of the credential prompt holds the password,
  # so it runs with bash -x held off (_tb_trace_off, output.sh).
  { _tb_trace_off; } 2>/dev/null
  if [[ "$_noninteractive_creds" == 1 ]]; then
    # Credentials supplied via env — verify once, no prompt, no re-prompt.
    TB_CLIENT_ID=$(_sanitize_credential "$TRACEBLOC_CLIENT_ID")
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TRACEBLOC_CLIENT_PASSWORD")
    [[ -n "$TB_CLIENT_ID" && -n "$TB_CLIENT_PASSWORD" ]] || \
      error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD must be non-empty."
    tb_live "Verifying credentials..."
    case "$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")" in
      valid)      tb_live_done "Credentials verified" ;;
      invalid)    error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD was rejected by tracebloc. Check them against the credential file \`tracebloc client create\` wrote, or create a new pair ($(_credential_file_cmd)), load it ($(_credential_file_load_cmd)) and re-run." ;;
      inactive)   error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified) tb_live_done; warn "Couldn't reach tracebloc to verify credentials right now — continuing (the secure environment will stay offline if they are wrong)." ;;
    esac
  else

  # We must prompt for credentials, but there may be no terminal to prompt on
  # (typically `curl … | bash`, where stdin is the piped script). Fail here with
  # an actionable message rather than aborting opaquely under set -e. The
  # per-read `|| _no_interactive_creds_die` guards below catch the harder case
  # this cheap check can't: a tty that is readable (`-r`) but yields no input.
  if ! _tty_available; then
    _no_interactive_creds_die
  fi

  prompt_header "Connect this machine with a Client ID."
  hint "A Client ID links your secure environment to tracebloc"
  hint "so peers can upload models for evaluation."
  echo ""
  hint "Already have one? Enter its credentials below — or set"
  hint "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD to skip this prompt."
  hint "Need one? With a current tracebloc CLI, this installer signs you in through"
  hint "your browser and needs no Client ID or password. For an unattended install,"
  hint "create the pair (free) on a machine signed in to tracebloc; it writes tb.env:"
  echo -e "    ${TB_CMD}$(_credential_file_cmd)${RESET}"
  echo ""

  # Collect + verify credentials. The entered Client ID / password are checked
  # against the backend (the same api-token-auth/ call jobs-manager makes)
  # before we deploy, so a wrong credential is caught here and asked for again, with
  # no cap (Ctrl-C stops), instead of surfacing later as a silently crash-looping pod.
  local _cred_status _cred_file_line="Use the one in the credential file \`tracebloc client create\` wrote."
  while true; do
    if [[ -n "$default_client_id" ]]; then
      read -r -p "  Client ID [${default_client_id}]: " TRACEBLOC_CLIENT_ID_INPUT <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      TB_CLIENT_ID="${TRACEBLOC_CLIENT_ID_INPUT:-$default_client_id}"
    else
      read -r -p "  Client ID: " TB_CLIENT_ID <"$TRACEBLOC_TTY" || _no_interactive_creds_die
    fi
    TB_CLIENT_ID=$(_sanitize_credential "$TB_CLIENT_ID")
    if [[ -z "$TB_CLIENT_ID" ]]; then tb_refused "A Client ID is required." "$_cred_file_line"; continue; fi

    if [[ -n "$default_client_password" ]]; then
      read -r -s -p "  Client password [press Enter to keep existing]: " TRACEBLOC_CLIENT_PASSWORD_INPUT <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      echo ""
      TB_CLIENT_PASSWORD="${TRACEBLOC_CLIENT_PASSWORD_INPUT:-$default_client_password}"
    else
      read -r -s -p "  Client password: " TB_CLIENT_PASSWORD <"$TRACEBLOC_TTY" || _no_interactive_creds_die
      echo ""
    fi
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TB_CLIENT_PASSWORD")
    if [[ -z "$TB_CLIENT_PASSWORD" ]]; then tb_refused "A password is required." "$_cred_file_line"; continue; fi

    tb_live "Verifying credentials..."
    _cred_status=$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")
    case "$_cred_status" in
      valid)
        tb_live_done "Credentials verified"
        break ;;
      invalid)
        tb_live_done
        tb_refused "tracebloc didn't accept this Client ID and password." \
          "Use the pair in the credential file \`tracebloc client create\` wrote." ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified)
        tb_live_done
        warn "Couldn't reach tracebloc to verify your credentials right now — continuing."
        hint "If they are wrong, your secure environment will stay offline at $(_dashboard_url) after install."
        break ;;
    esac

    # Force an active re-entry on retry (don't silently reuse a rejected default).
    default_client_id=""; default_client_password=""
  done
  fi
  _tb_trace_on
}

# ── One-client-per-machine guard ─────────────────────────────────────────
# A machine runs exactly one tracebloc client, so a DIFFERENT client installed in
# ANY namespace stops the install for the operator to decide; the same clientId is
# a re-run and passes. detect_installed_client, shared with the pre-flight, finds it.
# Then both credentials are escaped for the values file.
_client_helm_one_client_guard() {
  detect_installed_client
  existing_id="$INSTALLED_CLIENT_ID"; existing_ns="$INSTALLED_CLIENT_NS"
  # Fail CLOSED when we couldn't enumerate what's here (API/helm failure): refuse
  # rather than risk overwriting a client the guard simply couldn't see.
  if [[ "${INSTALLED_CLIENT_UNKNOWN:-0}" == 1 ]]; then
    echo ""
    warn "Couldn't determine which secure environment (if any) is already installed here."
    hint "tracebloc runs one secure environment per machine, so the installer won't risk overwriting"
    hint "an existing secure environment it can't see — usually the cluster API is briefly unreachable."
    hint "Check it and re-run:"
    hint "  $(tb_kubectl_shown) cluster-info"
    hint "  $(tb_helm_shown) list -A"
    echo ""
    error "Refusing to install without verifying what's already on this machine."
  fi
  if [[ -n "$existing_id" && "$existing_id" != "$TB_CLIENT_ID" ]]; then
    _refuse_other_client_id "$existing_id" "$existing_ns"
  fi

  # Same client under a DIFFERENT namespace (an older installer's fixed `tracebloc`):
  # upgrade THAT release in place. A second release would double-book this host's
  # capacity and orphan the first; moving namespaces is a delete-then-reinstall.
  if [[ -n "$existing_id" && "$existing_id" == "$TB_CLIENT_ID" && -n "$existing_ns" && "$existing_ns" != "$namespace" ]]; then
    log "Client '${existing_id}' already installed in namespace '${existing_ns}'; upgrading it in place instead of creating '${namespace}'."
    info "Updating the existing secure environment (namespace '${existing_ns}')."
    namespace="$existing_ns"
  fi

  # Both credentials go into SINGLE-quoted YAML scalars through the shared escaper,
  # so no character in them can corrupt the values file (_sanitize_credential
  # strips only paste/non-printable characters).
  TB_CLIENT_ID_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_ID")"
  { _tb_trace_off; } 2>/dev/null
  TB_CLIENT_PASSWORD_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_PASSWORD")"
  _tb_trace_on
}

# ── GPU request + runtime class ───────────────
# Training jobs request the vendor's GPU (_gpu_request_value: nvidia.com/gpu /
# amd.com/gpu, empty = CPU); NVIDIA's only once the GPU is WIRED into the cluster,
# as a node advertising 0 strands every job Pending. NVIDIA pods also run under the
# NVIDIA RuntimeClass (_gpu_runtime_class). SINGLE_NODE below has jobs-manager
# downgrade a GPU pod this single node can't satisfy to CPU.
# Then the device plugin, the engine, and (once the values write is logged) proxy and mirror.
_client_helm_runtime_values() {
  gpu_val="$(_gpu_request_value)"
  if _gpu_wired; then runtime_class="$(_gpu_runtime_class)"; fi
  device_type="$(_detect_device_type "$gpu_val")"
  log "Device type for the dashboard: ${device_type:-unknown (not reported)}"
  if [[ -n "$gpu_val" ]]; then
    log "${GPU_VENDOR} GPU wired — GPU_LIMITS/GPU_REQUESTS=${gpu_val}${runtime_class:+, RUNTIME_CLASS_NAME=${runtime_class}}"
  elif [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    warn "NVIDIA GPU detected but not wired into this cluster — running CPU-only (GPU_LIMITS/GPU_REQUESTS left empty)."
  else
    log "No GPU wired for training jobs — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # ── GPU device plugin ────────────────────────────────────────
  # The chart's device-plugin DaemonSet, enabled when a GPU vendor is detected, so
  # it's reconciled on upgrade and removed on `helm uninstall`; CPU-only installs
  # keep the chart default (disabled). NVIDIA's runs under the NVIDIA RuntimeClass
  # (without it NVML sees no GPU and it registers 0), so it's enabled only when the
  # GPU is wired: a stock CPU node has no `nvidia` RuntimeClass. AMD's needs none
  # and stays gated on bare detection.
  local rtc
  if _gpu_wired; then
    rtc="$(_gpu_runtime_class)"
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: nvidia\n    nvidia:\n      runtimeClassName: %s\n' "$rtc")"
    log "Helm-managed GPU device plugin enabled (vendor=nvidia, runtimeClassName=${rtc})"
  elif [[ "${GPU_VENDOR:-}" == "amd" ]]; then
    gpu_block="$(printf 'gpu:\n  devicePlugin:\n    enabled: true\n    vendor: amd\n')"
    log "Helm-managed GPU device plugin enabled (vendor=amd)"
  fi

  # Pick the MySQL engine for this install (before the heredoc
  # below is rendered; see _resolve_mysql_engine for the full decision rules).
  _resolve_mysql_engine
  # and only now is it knowable whether this host can run the
  # engine that rule picked. Ordering, not duplication — the arch question is
  # asked against the resolved engine, never ahead of it.
  _assert_engine_runs_on_this_arch

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"

  # Translate a corporate proxy on the host into the chart's split proxy keys so
  # every egress-needing workload inherits it (see _chart_proxy_env_yaml). Empty
  # when the host has no proxy — the env: block is then unchanged.
  # The proxy's password and the mirror's are held with bash -x off (output.sh).
  { _tb_trace_off; } 2>/dev/null
  proxy_env_yaml="$(_chart_proxy_env_yaml)"
  [[ -z "$proxy_env_yaml" ]] || log "Corporate proxy detected on host — propagating to client workloads via chart values."
  _tb_trace_on

  # Private registry mirror: re-home every image onto TRACEBLOC_IMAGE_REGISTRY
  # for restricted-network / air-gapped installs. Empty when unset (values unchanged).
  { _tb_trace_off; } 2>/dev/null
  image_mirror_yaml="$(_image_mirror_yaml)"
  _tb_trace_on
  if [[ -n "${TRACEBLOC_IMAGE_REGISTRY:-}" ]]; then
    log "Image registry mirror configured — pulling all images from ${TRACEBLOC_IMAGE_REGISTRY}."
    [[ -n "${TRACEBLOC_REGISTRY_USERNAME:-}" ]] && log "Mirror credentials provided — minting an imagePullSecret for the mirror."
  fi
  return 0
}

# Option A: size the default training budget to this machine.
# One pass, both answers — the probes are bounded but not free,
# and calling the two wrappers separately would run them twice.
_client_helm_training_fit() {
  _resolve_training_size
  # and only now, is what was chosen schedulable HERE -- beside the
  # chart's control plane and the system pods already on the node? Ours gets
  # reduced or refused; a human's gets warned. The arithmetic is printed in every
  # case that changes or blocks anything, because an operator reading `Pending /
  # Insufficient memory` later needs the numbers, not the verdict.
  _fit_training_envelope
  case "$_TB_FIT_VERDICT" in
    refused)
      _print_fit_refusal \
        "This machine cannot schedule a training beside the platform, so no training envelope is written:" \
        "$_TB_FIT_LINES" \
        "Refusing to write a training envelope that cannot be scheduled on this machine." \
        "$_TB_FIT_CAUSE"
      ;;
    reduced)
      # The size it was reduced to is the summary's Compute row. The arithmetic is e2e's
      # (O-108): on stdout when nobody watches it, in the log when a person does.
      if [[ -n "${_TB_STDOUT_TTY:-}" ]]; then
        log "Training envelope reduced to fit beside the platform on this machine:"
        _print_fit_lines log
      else
        info "Training envelope reduced to fit beside the platform on this machine:"
        _print_fit_lines hint
      fi
      ;;
    pinned-over)
      warn "The chosen training size does not fit beside the platform on this machine; training pods will stay Pending until it is lowered:"
      _print_fit_lines hint
      ;;
    unverified)
      warn "Training envelope UNVERIFIED: ${_TB_FIT_LINES}"
      hint "  Grant the installer 'get nodes' and 'list pods' to have it checked, or set TRACEBLOC_TRAINING_RESOURCES to a size you know fits."
      ;;
    *)
      # Fits: the arithmetic goes to the log file only, so a re-read later can
      # still see what was checked without it cluttering a clean install.
      _print_fit_lines log
      ;;
  esac
  training_size="$_TB_TRAINING_SIZE"
  training_provenance="$_TB_TRAINING_PROVENANCE"
  if [[ "$_TB_FIT_VERDICT" != refused ]] && (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 0 )); then
    _TB_COMPUTE_SHOWN="$(_envelope_display "$training_size")"
  fi
  log "Training size: ${training_size} (adjust any time with 'tracebloc resources set')"
  # The warning belongs HERE, not in the resolver: the resolver's output is
  # captured with $(...) by _training_resources / _training_provenance, so a warn
  # emitted there would end up inside the value.
  if (( ${_TB_TRAINING_UNDERSIZED:-0} == 1 )); then
    warn "This machine is below the size a training wants: ${training_size} is all that is left after the platform's reservation."
    hint "The secure environment will install and run, but trainings may be killed for memory. ~16 GB of RAM is the recommendation for training locally."
  elif (( ${_TB_TRAINING_UNSCHEDULABLE:-0} == 1 )); then
    warn "This machine is too small to host a training at all; keeping the default ${training_size}."
    hint "Trainings will wait for room until this machine has more memory — the secure environment itself will still run, ingest and report."
  fi
  # The ingestion Job did not fit beside the size written (_fit_verdict): the run
  # was kept at no less than the floor, so an upload queues behind it.
  if (( ${_TB_FIT_INGEST_WAITS:-0} == 1 )); then
    warn "A data ingest started while a training is using this machine waits until the training ends."
    hint "  An ingest needs $(( _TB_ENVELOPE_INGESTION_MEM_BYTES / 1024 / 1024 )) MiB / ${_TB_ENVELOPE_INGESTION_CPU_MILLI} m free beside ${training_size}; ingest between trainings, or give this machine more CPU and memory."
  fi
}

# Write generated values.yaml from what the stages above set.
_client_helm_write_values() {
  # CREATE IT EMPTY AND 0600 *BEFORE* THE CREDENTIAL GOES IN: the heredoc alone
  # would create it at the process umask, readable while clientPassword goes in.
  # `>` on an EXISTING file truncates without touching its mode, so the heredoc
  # writes into a file already 0600. Only the GENERATED file: dev mode
  # (TRACEBLOC_VALUES_FILE) never runs this stage.
  : > "$values_file" || error "Could not create $values_file"
  chmod 600 "$values_file" 2>/dev/null || true
  # The stage, read from the shell's TRACEBLOC_ENV as tb_client_env reads it,
  # and written under env.TRACEBLOC_ENV only: every reader of these values (the
  # chart's tracebloc.clientEnv, assess.sh's _assess_release_client_env, the
  # CLI) reads that key first.
  local _tb_stage_raw="${TRACEBLOC_ENV:-}" _tb_stage_resolved=""
  [ -n "$_tb_stage_raw" ] && _tb_stage_resolved="$(tb_client_env "$_tb_stage_raw")"
  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "$_tb_stage_resolved" ] && printf '  TRACEBLOC_ENV: "%s"\n' "$_tb_stage_resolved")${proxy_env_yaml}
  # Training size: how much CPU/RAM each training run gets. Sized to this
  # machine at install — largest node minus ~1 CPU / 3 GiB platform overhead —
  # unless TRACEBLOC_TRAINING_RESOURCES is set or the installed release already
  # carries a choice (option A).
  #
  # THE TWO HALVES ARE NOT THE SAME STRING any more (L0.2):
  # requests carries cpu AND memory, limits carries memory ONLY. CPU is
  # time-shared, so a request with no limit is a share weight rather than a
  # quota that throttles on an idle machine; memory is not time-shared, so
  # requests == limits stays. See _training_limits for the full reasoning and
  # for the ordering constraint.
  RESOURCE_LIMITS: "$(_training_limits "${training_size}")"
  RESOURCE_REQUESTS: "${training_size}"
  # Who chose the pair above. Bookkeeping only — it never changes
  # the envelope. "unknown" means the value was carried forward from before this
  # key existed and is genuinely unattributable, so consumers treat it as "user".
  RESOURCE_PROVENANCE: "${training_provenance}"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  # nvidia when the GPU is wired: jobs-manager threads it into every
  # spawned pod so the node's containerd invokes the NVIDIA runtime; "" on CPU.
  RUNTIME_CLASS_NAME: "$runtime_class"
  # an installer-provisioned cluster is a fixed single host
  # that cannot autoscale, so jobs-manager applies the hard CPU-or-GPU rule —
  # a Pending GPU pod is downgraded to CPU rather than waiting for a GPU node
  # that will never arrive.
  SINGLE_NODE: "true"
  # what kind of machine this is, for the dashboard's switcher —
  # the chassis this installer read (TRACEBLOC_DEVICE_TYPE overrides), or ""
  # when it could not tell, which the chart drops and jobs-manager then omits.
  DEVICE_TYPE: "${device_type}"
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  HOST_UID: "%s"\n  HOST_GID: "%s"\n' "$(id -u)" "$(id -g)")
$(if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
cat <<'STORAGE'
# Node-local: use k3s's built-in local-path StorageClass.
# No hostPath PVs, so dataset volumes are provisioned in k3s's local-path
# storage on the node rather than in host folders the chart names.
storageClass:
  create: false
  name: local-path

hostPath:
  enabled: false

# node-local is a single schedulable node (native k3s is one server),
# so the single-replica PDBs would be undrainable here. hostPath.enabled=false
# would otherwise misclassify this as multi-node, so declare the topology
# explicitly to skip those PDBs and keep the node drainable.
singleNode: true
STORAGE
else
cat <<'STORAGE'
storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true
STORAGE
_hostpath_paths_block
fi)
$(_local_api_values_block)
$(if [[ "${TB_MYSQL_ENGINE_RESOLVED:-5.7}" == "8.4" ]]; then
cat <<MYSQL84

# MySQL engine: the multi-arch 8.4 engine (the chart default
# since the 8.4 default switch). Stated explicitly rather than left to the chart
# default, so the sticky read finds it on every re-run and no later chart
# default can move this datadir. Pinned by the chart's own 8.4 digest, so it
# renders the same image the chart default does, never the moving 8.4 tag.
# Override with TB_MYSQL_ENGINE=5.7|8.4.
images:
  mysqlClient:
    tag: "8.4"
    digest: "${TB_MYSQL_84_DEFAULT_DIGEST}"
MYSQL84
else
cat <<MYSQL57

# MySQL engine: this install stays on the 5.7 engine (an existing release or
# datadir, or TB_MYSQL_ENGINE=5.7), pinned to the frozen 5.7-lineage image.
# EXPLICIT since the 8.4 default switch made 8.4 the chart default: left to the default,
# the next upgrade would render 8.4 over this 5.7 datadir, which 8.4 refuses to
# open. Move it to 8.4 with the 8.4 migration, never by editing this pin.
images:
  mysqlClient:
    tag: "${TB_MYSQL_57_PIN_TAG}"
    digest: "${TB_MYSQL_57_PIN_DIGEST}"
MYSQL57
fi)
${gpu_block:+$gpu_block
}pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true
${image_mirror_yaml}
clientId: '$TB_CLIENT_ID_ESCAPED'
clientPassword: '$TB_CLIENT_PASSWORD_ESCAPED'

EOF
}

# values.yaml's mode, checked after the write.
_client_helm_check_values_mode() {
  # DEFENCE IN DEPTH, AND THEN A CHECK -- not a silent best-effort: a chmod that
  # did not apply would leave clientPassword world-readable and say nothing.
  #
  # POSIX `ls -ldn`, NEVER GNU-only `stat -c` -- BSD rejects `-c` silently.
  # install-client-helm.bats' "the values.yaml mode is read with POSIX ls -ldn,
  # never GNU-only stat -c" holds this block to it.
  #
  # WARN RATHER THAN error, deliberately. chmod genuinely cannot apply on a
  # host_data_dir living on a filesystem without POSIX modes (exFAT, some
  # Windows/WSL mounts), and refusing to install there would trade a readable file
  # for no tracebloc at all. So it names the mode it actually found and continues:
  # an operator can act on "-rw-r--r--", not on silence; a failing ls must reach "" under pipefail.
  chmod 600 "$values_file" 2>/dev/null || true
  local _vf_mode; _vf_mode="$(ls -ldn "$values_file" 2>/dev/null | awk 'NR==1{print $1}')" || _vf_mode=""
  case "$_vf_mode" in
    -rw-------*) : ;;
    "")          warn "Could not read the mode of $values_file -- it holds a live credential; check that other users cannot read it." ;;
    *)           warn "$values_file is $_vf_mode, not -rw------- . It holds your clientPassword in cleartext; restrict it with: chmod 600 $values_file" ;;
  esac
  log "Values file written to $values_file"
}

# Before the helm apply: helm, the chart, the metrics API, a pending release, the --set-string words.
_client_helm_prepare_apply() {
  _ensure_helm_runnable

  # ── Resolve chart reference: local path (dev) or remote repo (default) ──
  _resolve_chart_ref

  # Said before the download line starts; rides _gpu_args below.
  _collector_set_args fresh "$namespace" "$namespace"

  log "Installing $namespace from $chart_ref in namespace '$namespace'..."
  # One line from here to the images on the node: the metrics wait, the chart and the
  # pulls (_download_services_progress ends it).
  tb_live "Downloading tracebloc services..."

  # Pre-create per-release hostPath dirs so they're owned by the host user, not
  # root:root from kubelet's DirectoryOrCreate. See _ensure_release_dirs.
  # node-local (node-local storage) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-node-local}" != "node-local" ]] && _ensure_release_dirs "$namespace"

  # wait out the metrics-server APIService registration race before helm
  # renders the resource-monitor DaemonSet (whose template hard-fails if the
  # metrics API isn't registered yet). Bounded + best-effort. The outer spinner
  # deadline must never truncate the configured inner wait, so derive it from
  # TB_METRICS_WAIT_S (same parse as _wait_for_metrics_apiservice) plus slack for
  # the post-registration `kubectl wait --for=Available` (30s) and jitter.
  local _metrics_wait_s="${TB_METRICS_WAIT_S:-}"
  case "$_metrics_wait_s" in ''|*[!0-9]*) _metrics_wait_s="$METRICS_WAIT_TIMEOUT" ;; *) _metrics_wait_s=$((10#$_metrics_wait_s)) ;; esac
  spin_cmd_bounded "$(( _metrics_wait_s + 60 ))" "Waiting for the metrics API to register…" \
    _wait_for_metrics_apiservice || true

  # The chart install blocks ~10-15s (render + apply + image pull), so run it
  # behind a spinner instead of a frozen terminal — spin_cmd_bounded streams
  # helm output to $LOG_FILE and, on failure, tails the log to stderr. Gives
  # progress on every wait; the deadline stops a wedged
  # kube-apiserver from hanging the install forever.
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"

  # clear any pending-* wedge left by a previously killed helm op (Ctrl-C,
  # OOM, reboot) before we upgrade — otherwise this run just fails with "another
  # operation is in progress" (exit 1) and the machine stays wedged across every
  # re-run. The release name equals the namespace on the normal install path.
  # Fail closed if recovery itself couldn't clear it.
  if ! _recover_pending_helm_release "$namespace" "$namespace"; then
    hint "Couldn't automatically clear the interrupted release. Recover it by hand, then re-run:"
    hint "  first install:  $(tb_helm_shown) -n $namespace uninstall $namespace    (removes only the half-installed release)"
    hint "  upgrade:        $(tb_helm_shown) -n $namespace rollback $namespace     (returns to the previous release)"
    error "Client installation blocked by an interrupted previous helm operation. Check the log for details: ${LOG_FILE:-}"
  fi

  # migration: an earlier install applied the GPU device plugin with
  # an imperative `kubectl apply` (unowned by Helm). If that DaemonSet survived a
  # `helm uninstall` — the exact litter this migration is about — this fresh install would
  # now fail with "exists and cannot be imported into the current release". Label
  # + annotate any such orphan for Helm adoption so the chart takes it over IN
  # PLACE (no GPU blip), instead of colliding. Best-effort + bounded + idempotent:
  # a missing DS or a kubectl hiccup must never block the install (GPU is
  # optional). Only runs on the GPU path; a no-op everywhere else.
  _adopt_orphaned_gpu_device_plugin

  # the unsupported-GPU reason and card ride --set-string, not the
  # values heredoc: the sentence is free text (apostrophes, commas), and
  # _helm_set_string_escape is the one quoting rule both install paths share.
  # dev mode installs a values file the installer did not write, so
  # it gets THIS run's whole GPU decision, the adopt reconcile's: the caller's file
  # supplies everything else, the GPU keys and the device plugin stay the installer's.
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    _gpu_decision_set_args
    _gpu_args=("${_TB_GPU_DECISION_ARGS[@]}")  # set-u-safe: _gpu_decision_set_args always assigns
    log "Dev mode: this run's GPU decision overrides the values file's GPU keys: ${_gpu_args[*]}"  # set-u-safe: _gpu_decision_set_args always assigns
  else
    _gpu_unsupported_set_args
    _gpu_args=("${_TB_GPU_UNSUPPORTED_ARGS[@]}")  # set-u-safe: _gpu_unsupported_set_args always assigns six words
  fi
  # The host's OS, on both branches: not a GPU word, but the
  # same --set-string route, so it rides this array into the one helm call.
  _host_os_set_args
  _gpu_args+=("${_TB_HOST_OS_ARGS[@]}")  # set-u-safe: _host_os_set_args always assigns two words
  # The machine facts (kind, cloud, CPU name), the same way.
  _machine_facts_set_args
  _gpu_args+=("${_TB_MACHINE_FACTS_ARGS[@]}")  # set-u-safe: _machine_facts_set_args always assigns six words
  # Whether k3s runs the pods confined (_selinux_set_args), the same way.
  _selinux_set_args
  _gpu_args+=(${_TB_SELINUX_ARGS[@]+"${_TB_SELINUX_ARGS[@]}"})
  # The macOS node's values profile, on both branches: over the values
  # file this run wrote, and over a caller's own in dev mode.
  _mac_node_profile_set_args
  _gpu_args+=(${_TB_MAC_PROFILE_ARGS[@]+"${_TB_MAC_PROFILE_ARGS[@]}"})
  _mac_runner_set_args
  _gpu_args+=(${_TB_MAC_RUNNER_ARGS[@]+"${_TB_MAC_RUNNER_ARGS[@]}"})
  _gpu_args+=(${_TB_COLLECTOR_ARGS[@]+"${_TB_COLLECTOR_ARGS[@]}"})
}

# The helm apply, its record, and a restart of pods a changed credential left on the old one.
_client_helm_upgrade() {
  local _helm_rc=0
  # The password the running pods started on, read before helm overwrites it, so
  # the restart below can see a credential that changed under them.
  # A read that CANNOT TELL (rc 2) is not a first install: when the Secret holds a
  # password after helm, the pods may have started on a different one, so that
  # restarts below.
  local _prev_password _prev_unreadable=0
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  _prev_password="$(_client_password_from_secret "$namespace" "$namespace")" \
    || _prev_unreadable=1
  _tb_trace_on
  # The lock's prefix has a line of its own, so the call still starts its line, where
  # release-name-equals-namespace.sh reads the release's name from.
  _tb_helm_lock
  spin_cmd_bounded "$(_tb_helm_deadline_s "$_helm_timeout_min")" "Installing your secure environment…" \
    ${_TB_HELM_LOCK[@]+"${_TB_HELM_LOCK[@]}"} \
    helm upgrade --install "$namespace" "$chart_ref" \
    --namespace "$namespace" \
    --create-namespace \
    --cleanup-on-fail \
    --values "$values_file" \
    "${_gpu_args[@]}" || _helm_rc=$?  # set-u-safe: both branches above assign at least six words
  if [[ "$_helm_rc" -ne 0 ]]; then
    _tb_helm_lock_timed_out "$_helm_rc"
    # A helm op killed partway (timeout=124, or an in-progress wedge=exit 1) can
    # leave the release pending-*. The next run auto-recovers
    # (_recover_pending_helm_release), but name the manual unwedge too — on exit
    # 1, not only the 124 timeout.
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  first install:  $(tb_helm_shown) -n $namespace uninstall $namespace    (removes only the half-installed release)"
    hint "  upgrade:        $(tb_helm_shown) -n $namespace rollback $namespace     (returns to the previous release)"
    error "Client installation failed. Check the log for details: ${LOG_FILE:-}"
  fi
  # The release offboarding removes: named after its namespace on
  # this path, which is the record's namespace field.
  tb_record_write helm-release "$namespace" ""

  # kubectl and the tracebloc CLI default to the client namespace, with no -n flag.
  tb_kube_set_namespace "$namespace"

  # A credential issued to a client that is already running here (the
  # credential-rejected repair), or any other new password written
  # over a running release's (a preset), is in the Secret now,
  # but the pods read it from their environment at start and the chart doesn't
  # roll them on a Secret change. Restart the ones that authenticate so they use it.
  # An unreadable read before helm with one that reads after it is "cannot tell",
  # and restarts; unreadable on both sides is a cluster nothing here can roll.
  local _now_password _changed=0
  { _tb_trace_off; } 2>/dev/null   # the password stays out of bash -x's trace (output.sh)
  _now_password="$(_client_password_from_secret "$namespace" "$namespace")" || _now_password=""
  if [[ "${TRACEBLOC_CREDENTIAL_REISSUED:-0}" == 1 ]] \
     || [[ "$_prev_unreadable" == 1 && -n "$_now_password" ]] \
     || _credential_changed_under_pods "$_prev_password" "$_now_password"; then
    _changed=1
  fi
  _prev_password=""; _now_password=""
  _tb_trace_on
  if [[ "$_changed" == 1 ]]; then
    _restart_credential_consumers "$namespace" \
      || error "This machine's new credential is in place, but its services are still on the old one."
  fi
}

install_client_helm() {
  # Step e (Install tracebloc) — main() prints the "e) Installing tracebloc"
  # header. The credential + namespace were provisioned in step d
  # (provision_client) or supplied via dual-mode (TRACEBLOC_CLIENT_ID/PASSWORD or
  # TRACEBLOC_VALUES_FILE). This step renders the values, runs Helm, and shows the
  # services download; the final connect + summary is step f.
  # node-local (node-local storage): data lives inside the node, so skip the
  # world-writable ~/.tracebloc/{data,logs,mysql} dirs; just ensure the base dir
  # exists for values.yaml + the install log.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    mkdir -p "$host_data_dir"
  else
    _ensure_tracebloc_dirs
  fi
  local values_file; values_file="$(_client_values_file)"

  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    _client_helm_dev_mode
  else
  local use_existing="" default_client_id="" default_client_password="" _noninteractive_creds=0
  _client_helm_previous_config

  # ── Namespace (fixed; not prompted) ──────────────────────────────────────
  # The on-prem client is one-per-machine and is identified to the backend by
  # its credentials (clientId), not by this name — so we don't ask the user to
  # invent one. It's just the local k8s namespace / Helm release name.
  # Advanced / GitOps setups can override with namespace=<name>.
  namespace=$(_client_default_namespace)

  # Native k3s: an installed release keeps the storage it was made with, before the
  # reconcile and the values below read TB_STORAGE_MODE.
  _native_k3s_release_storage
  _mac_node_storage_steps

  # A re-run on an already-connected client must reconcile in place,
  # not re-provision. Step 3 marks that case with TRACEBLOC_CLIENT_ADOPTED=1 (+ the
  # UUID, no password). Honor it: reconcile the live release silently — no credential
  # prompt, no verify, no duplicate. Only if there's no live release to reconcile do
  # we fall through to the normal connect flow below.
  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == 1 ]] && _reconcile_adopted_client; then
    # What helm did, as the fresh path says it below; no "installed" claim here,
    # whether the install succeeded is step f's.
    tb_live "Installing services..."
    _installed_services_line "$namespace"
    log "Reconciled adopted client in namespace '$namespace'"
    return 0
  fi

  _client_helm_credentials
  local existing_id="" existing_ns=""
  _client_helm_one_client_guard
  local gpu_val runtime_class="" device_type="" gpu_block="" proxy_env_yaml image_mirror_yaml
  _client_helm_runtime_values
  local training_size training_provenance
  _client_helm_training_fit
  _client_helm_write_values
  _client_helm_check_values_mode
  fi

  local chart_ref="" _helm_timeout_min _gpu_args
  _client_helm_prepare_apply
  _client_helm_upgrade

  # Honest N-of-M count as the service images pull onto the node. Best-effort +
  # bounded + non-fatal — the real readiness gate is step f (wait_for_client_ready).
  _download_services_progress "$namespace"
  tb_live_done

  tb_live "Installing services..."
  _installed_services_line "$namespace"
  log "Values file: $values_file"
}

# _installed_services_line NS -- step e's "Installing services..." ends with how many
# services the release installed, the count its "Downloaded" line gave
# (_release_service_count). With no count it stays "· Installing services...".
# Step e ends on this line: it says what helm did, never that tracebloc is installed.
# Whether the install succeeded is step f's (wait_for_client_ready), and the summary
# says it: a refused install must never have said "installed" first.
_installed_services_line() {
  local n
  if n="$(_release_service_count "$1" 10s)"; then
    tb_live_done "Installed · ${n} services"
  else
    log "The release in $1 has no service this run could count."
    tb_live_done
  fi
}
