#!/usr/bin/env bash
# =============================================================================
#  summary.sh — Final success screen + cluster verification (debug only)
# =============================================================================

verify_cluster() {
  log "--- Cluster Status ---"
  kubectl cluster-info >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get nodes -o wide >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  kubectl get pods -n "${TB_NAMESPACE:-default}" >> "${LOG_FILE:-/dev/null}" 2>&1 || true
  log "--- End Cluster Status ---"
}

print_summary() {
  local mode="CPU"
  [[ "$GPU_VENDOR" == "nvidia" ]] && mode="NVIDIA GPU"
  [[ "$GPU_VENDOR" == "amd" ]] && mode="AMD GPU"

  echo ""
  echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  ${BOLD}${GREEN}tracebloc client installed successfully${RESET}"
  echo ""
  echo -e "  ${BOLD}Workspace${RESET} : ${CYAN}${TB_NAMESPACE:-default}${RESET}"
  echo -e "  ${BOLD}Mode${RESET}      : ${CYAN}${mode}${RESET}"
  echo ""
  echo -e "  ${DIM}This machine is now a secure compute environment${RESET}"
  echo -e "  ${DIM}on the tracebloc network. External AI vendors can${RESET}"
  echo -e "  ${DIM}submit models to be trained and evaluated here —${RESET}"
  echo -e "  ${DIM}your data never leaves your infrastructure.${RESET}"
  echo ""
  echo -e "  ${BOLD}What to do next${RESET}"
  echo ""
  echo -e "  ${WHITE}1.${RESET} Open the tracebloc dashboard"
  echo -e "     ${CYAN}https://ai.tracebloc.io${RESET}"
  echo ""
  echo -e "  ${WHITE}2.${RESET} Ingest your training and test data"
  echo ""
  echo -e "  ${WHITE}3.${RESET} Define your first AI use case and"
  echo -e "     invite vendors to submit models"
  echo ""
  echo -e "  ${DIM}Need help?${RESET}  ${CYAN}https://docs.tracebloc.io${RESET}"
  echo -e "  ${DIM}Logs:${RESET}       ${DIM}~/.tracebloc/${RESET}"
  echo -e "  ${DIM}Data:${RESET}       ${DIM}/tracebloc/${TB_NAMESPACE:-default}${RESET}"
  echo ""
  echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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
