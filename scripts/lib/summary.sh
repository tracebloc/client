#!/usr/bin/env bash
# =============================================================================
#  summary.sh — Final success screen + cluster verification (debug only)
# =============================================================================

# Cluster status dump (debug log only).
_log_cluster_status() {
  log "--- Cluster Status ---"
  kubectl cluster-info >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get nodes -o wide >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get pods -n "${TB_NAMESPACE:-default}" -o wide >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  log "--- End Cluster Status ---"
}

# ── Readiness gate (#716) ─────────────────────────────────────────────────
# helm install only *applies* manifests; it does not wait for pods. After it
# returns we wait for the client's workloads to actually become Ready and set
# CLIENT_STATE so the summary reports the truth instead of an unconditional
# "installed successfully":
#   connected | starting | bad_creds | image_pull | crash
# Empty until wait_for_client_ready runs — so install_cleanup can distinguish an
# early failure (before the readiness gate, CLIENT_STATE still empty) from a
# reported outcome, and still print the "check the log / safe to re-run" hint.
CLIENT_STATE=""
READY_TIMEOUT="${READY_TIMEOUT:-300}"

wait_for_client_ready() {
  local ns="${TB_NAMESPACE:-default}"
  # The workloads that must be Ready are shared with the installer's stop-and-check
  # gate (assess.sh) via _client_workload_deployments — single source of truth, so
  # the readiness gate and the gate's "healthy" test can't drift.
  local deploys=() _d
  while IFS= read -r _d; do [[ -n "$_d" ]] && deploys+=("$_d"); done < <(_client_workload_deployments "$ns")
  local deadline=$(( $(date +%s) + READY_TIMEOUT ))
  local all_ready=true d remaining

  echo ""
  info "Connecting to the tracebloc network — waiting for your services to come online…"
  for d in "${deploys[@]}"; do
    remaining=$(( deadline - $(date +%s) )); (( remaining < 10 )) && remaining=10
    if kubectl rollout status "deployment/${d}" -n "$ns" --timeout="${remaining}s" \
        >> "${LOG_FILE:-/dev/null}" 2>&1; then
      success "${d#${ns}-} ready"
    else
      all_ready=false; break
    fi
  done

  _log_cluster_status
  if [[ "$all_ready" == true ]]; then
    CLIENT_STATE="connected"
  else
    CLIENT_STATE="$(_diagnose_not_ready "$ns")"
  fi
  return 0
}

# Classify why the client isn't Ready, for an accurate message. Echoes a state.
_diagnose_not_ready() {
  local ns="$1" pods jm_logs
  # Wrong credentials: jobs-manager authenticates to the backend on startup and
  # crash-loops when rejected — surfaced as an auth error in its logs.
  jm_logs="$(kubectl logs -n "$ns" "deployment/${ns}-jobs-manager" --all-containers --tail=50 2>/dev/null || true)"
  if printf '%s' "$jm_logs" | grep -qiE 'authentication failed|unable to log in'; then
    printf 'bad_creds'; return
  fi
  pods="$(kubectl get pods -n "$ns" 2>/dev/null || true)"
  if printf '%s' "$pods" | grep -qiE 'ImagePullBackOff|ErrImagePull|InvalidImageName'; then
    printf 'image_pull'; return
  fi
  if printf '%s' "$pods" | grep -qiE 'CrashLoopBackOff'; then
    printf 'crash'; return
  fi
  printf 'starting'
}

# Reports the outcome based on CLIENT_STATE (set by wait_for_client_ready).
# The "secure compute environment / your data never leaves" claim is printed
# ONLY when the client is verifiably connected — never on a partial/failed run.
# One-line note in the success summary so the user knows the client survives a
# reboot — automatic on Linux; needs Docker Desktop start-on-login on macOS/Win.
_reboot_note() {
  # Single dim footer line — the LAST line of the summary. OS-specific so Linux is
  # NOT regressed: on Linux the cluster + Docker come back on boot automatically;
  # on macOS/Windows Docker Desktop must be launched (the run-through's macOS copy).
  if [[ "$OS" == "Linux" ]]; then
    echo -e "  ${DIM}After a reboot, tracebloc restarts automatically.${RESET}"
  else
    echo -e "  ${DIM}After a reboot, open Docker Desktop to bring tracebloc back.${RESET}"
  fi
}

print_summary() {
  local mode="CPU"
  [[ "$GPU_VENDOR" == "nvidia" ]] && mode="NVIDIA GPU"
  [[ "$GPU_VENDOR" == "amd" ]] && mode="AMD GPU"
  local ns="${TB_NAMESPACE:-default}"
  local cver; cver="$(_chart_version "$ns")"
  # Footer log path: HOST_DATA_DIR with $HOME collapsed to ~ (e.g. ~/.tracebloc).
  local logdisp="${HOST_DATA_DIR:-$HOME/.tracebloc}"
  if [[ -n "${HOME:-}" && "$logdisp" == "$HOME"* ]]; then logdisp="~${logdisp#"$HOME"}"; fi

  echo ""
  case "$CLIENT_STATE" in
    connected)
      echo -e "  ${BOLD}${GREEN}✔${RESET} ${BOLD}Connected to tracebloc${RESET}"
      echo ""
      echo -e "  ${DIM}Environment${RESET} : ${ns}"
      echo -e "  ${DIM}Version${RESET}     : ${cver:-unknown}"
      echo -e "  ${DIM}Mode${RESET}        : ${mode}"
      echo ""
      echo -e "  Your secure environment is live 🟢"
      echo -e "    See it on your dashboard:  ${CYAN}https://ai.tracebloc.io/clients${RESET}"
      echo ""
      # "What's next" is deliberately NOT dim — it's the primary call to action.
      echo -e "  ${BOLD}What's next${RESET}"
      echo -e "    1. Ingest your data       ${CYAN}tracebloc data ingest${RESET}"
      echo -e "    2. Create a use case      ${CYAN}https://ai.tracebloc.io/my-use-cases${RESET}"
      echo -e "    3. Invite collaborators — they train on your data; it never leaves this machine"
      echo ""
      echo -e "  ${BOLD}Run  ${CYAN}tracebloc${RESET}${BOLD}  to get started.${RESET}"
      echo ""
      echo -e "  ${DIM}────────────────────────────────────────${RESET}"
      echo -e "  ${DIM}Logs ${logdisp}  ·  Data /tracebloc/${ns}${RESET}"
      _reboot_note
      ;;
    starting)
      echo -e "  ${YELLOW}⚠  Almost there — tracebloc is installed but still starting.${RESET}"
      echo ""
      echo -e "  Components are still downloading/starting (first run can take a few minutes)."
      echo -e "  Check progress:   ${CYAN}kubectl get pods -n ${ns}${RESET}"
      echo ""
      echo -e "  Your client will show as ${BOLD}🟢 Online${RESET} at ${CYAN}https://ai.tracebloc.io/clients${RESET}"
      echo -e "  once it finishes. ${DIM}Re-running this installer is safe.${RESET}"
      ;;
    bad_creds)
      echo -e "  ${RED}${BOLD}✖ Couldn't connect — your Client ID or password was rejected.${RESET}" >&2
      echo ""
      echo -e "  The environment installed, but tracebloc refused those credentials."
      echo -e "    1. Re-check them at ${CYAN}https://ai.tracebloc.io/clients${RESET}"
      echo -e "    2. Re-run this installer ${DIM}(safe to re-run)${RESET}"
      ;;
    image_pull|crash)
      local reason="a component didn't start"
      [[ "$CLIENT_STATE" == "image_pull" ]] && reason="an image couldn't be pulled"
      [[ "$CLIENT_STATE" == "crash" ]] && reason="a container is restarting (crash loop)"
      echo -e "  ${RED}${BOLD}✖ Setup didn't finish — ${reason}.${RESET}" >&2
      echo ""
      echo -e "  Inspect:  ${CYAN}kubectl get pods -n ${ns}${RESET}"
      echo -e "  Logs:     ${DIM}~/.tracebloc/install-*.log${RESET}"
      echo -e "  ${DIM}Re-running this installer is safe.${RESET}"
      ;;
  esac
  echo ""

  _log_advanced_info
}

_log_advanced_info() {
  log ""
  log "=== Advanced Info (for debugging) ==="
  log "Cluster topology: Servers=$SERVERS  Agents=$AGENTS"
  log "Volume mount: $HOST_DATA_DIR → /tracebloc"
  log ""
  log "Useful commands:"
  log "  kubectl get nodes -o wide"
  log "  kubectl get pods -A"
  log "  kubectl get pods -n ${TB_NAMESPACE:-default}"
  log "  k3d cluster stop $CLUSTER_NAME"
  log "  k3d cluster start $CLUSTER_NAME"
  log "  k3d cluster delete $CLUSTER_NAME"
  if [[ "$GPU_VENDOR" == "nvidia" ]]; then
    log "  GPU test: kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.1-base-ubuntu22.04 --limits='nvidia.com/gpu=1' -- nvidia-smi"
  fi
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    log "  GPU test: kubectl run gpu-test --rm -it --image=rocm/rocm-terminal --limits='amd.com/gpu=1' -- rocm-smi"
  fi
  log "=== End Advanced Info ==="
}
