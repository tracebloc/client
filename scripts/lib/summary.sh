#!/usr/bin/env bash
# =============================================================================
#  summary.sh — Final cluster status + cheatsheet
# =============================================================================

verify_cluster() {
  step "Cluster Status"
  kubectl cluster-info
  echo ""
  kubectl get nodes -o wide
}

print_summary() {
  echo -e "\n${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║  ✅  Kubernetes cluster '${CLUSTER_NAME}' is ready!              ${RESET}${BOLD}${GREEN}║${RESET}"
  [[ "$GPU_VENDOR" == "nvidia" ]] && \
    echo -e "${BOLD}${GREEN}║  🎮  NVIDIA GPU support enabled                               ║${RESET}"
  [[ "$GPU_VENDOR" == "amd" ]] && \
    echo -e "${BOLD}${GREEN}║  🎮  AMD GPU support enabled                                  ║${RESET}"
  [[ "$GPU_VENDOR" == "apple_silicon" ]] && \
    echo -e "${BOLD}${YELLOW}║  ⚠️   macOS — GPU passthrough unavailable (CPU-only cluster)   ║${RESET}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${RESET}"

  _print_topology
  _print_common_commands
  _print_lifecycle_commands
  _print_gpu_test_commands
  echo ""
}

_print_topology() {
  echo ""
  echo -e "  ${BOLD}Cluster topology:${RESET}"
  echo -e "  Servers (control-plane): ${CYAN}$SERVERS${RESET}"
  echo -e "  Agents  (workers)      : ${CYAN}$AGENTS${RESET}"
  echo -e "  Ingress (HTTP/S)       : ${CYAN}localhost:$HTTP_PORT  /  localhost:$HTTPS_PORT${RESET}"
}

_print_common_commands() {
  echo ""
  echo -e "  ${BOLD}Common commands:${RESET}"
  echo -e "  ${CYAN}kubectl get nodes -o wide${RESET}              — all cluster nodes"
  echo -e "  ${CYAN}kubectl get pods -A${RESET}                    — all pods"
  echo -e "  ${CYAN}kubectl apply -f <manifest.yaml>${RESET}        — deploy your app"
  echo -e "  ${CYAN}helm install <name> <chart>${RESET}             — deploy via Helm"
}

_print_lifecycle_commands() {
  echo ""
  echo -e "  ${BOLD}Cluster lifecycle:${RESET}"
  echo -e "  ${CYAN}k3d cluster stop  $CLUSTER_NAME${RESET}         — pause (saves RAM)"
  echo -e "  ${CYAN}k3d cluster start $CLUSTER_NAME${RESET}         — resume"
  echo -e "  ${CYAN}k3d cluster delete $CLUSTER_NAME${RESET}        — destroy"
  echo -e "  ${CYAN}k3d cluster list${RESET}                       — all clusters"
}

_print_gpu_test_commands() {
  if [[ "$GPU_VENDOR" == "nvidia" ]]; then
    echo ""
    echo -e "  ${BOLD}GPU quick-test:${RESET}"
    echo -e "  ${CYAN}kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.1-base-ubuntu22.04 \\"
    echo -e "    --limits='nvidia.com/gpu=1' -- nvidia-smi${RESET}"
  fi
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    echo ""
    echo -e "  ${BOLD}GPU quick-test:${RESET}"
    echo -e "  ${CYAN}kubectl run gpu-test --rm -it --image=rocm/rocm-terminal \\"
    echo -e "    --limits='amd.com/gpu=1' -- rocm-smi${RESET}"
  fi
}
