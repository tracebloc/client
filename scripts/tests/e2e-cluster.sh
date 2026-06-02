#!/usr/bin/env bash
# =============================================================================
#  e2e-cluster.sh — real end-to-end cluster smoke test
# -----------------------------------------------------------------------------
#  Brings up an ACTUAL k3d cluster on a real kernel using the installer's own
#  create_cluster() path (the same function main() calls), proves the cluster can
#  schedule and run a public workload, then tears it down. This is the highest-
#  fidelity check CI can run: it exercises k3d cluster create, the proxy/NO_PROXY
#  config, kubeconfig merge, and the API-readiness wait against a live daemon —
#  none of which the mocked unit tests or the prereq-install matrix can.
#
#  It deliberately STOPS before the tracebloc helm install / backend
#  registration: those pull private images and need real credentials + a
#  reachable platform. So this needs no secrets and runs on stock GitHub runners
#  (Docker is preinstalled) and locally (Lima/any Docker host).
#
#  Usage:  bash scripts/tests/e2e-cluster.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

# Isolated cluster name so we never touch a real 'tracebloc' cluster; opt out of
# autostart so we don't reconfigure docker.service / restart policies on the host.
export USER="${USER:-$(id -un)}"
export CLUSTER_NAME="${CLUSTER_NAME:-tbe2e}"
export TRACEBLOC_NO_AUTOSTART=1

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"

cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════════════════"
echo "  E2E cluster smoke   arch: $(uname -m)   kernel: $(uname -r)"
echo "═══════════════════════════════════════════════════════════════════════"

# Docker is preinstalled + running on the runner; we only need the CLI tools the
# cluster step uses. (We do NOT run install_docker_engine — no daemon gymnastics.)
has docker || error "Docker is not available on this host."
umask 022
install_kubectl
install_k3d
install_helm

echo "── create_cluster() — the installer's real cluster-bring-up path ──"
create_cluster

echo "── assert: all nodes reach Ready ──"
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

echo "── wait for the default ServiceAccount (created async after node Ready) ──"
# kubectl run binds the pod to default/default; on fast runners that can race the
# service-account controller ("serviceaccount default not found"). Wait for it.
for _ in $(seq 1 30); do
  kubectl get serviceaccount default -n default >/dev/null 2>&1 && break
  sleep 2
done

echo "── assert: the cluster can pull, schedule, and run a public workload ──"
kubectl run e2e-probe --image=nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/e2e-probe --timeout=180s
kubectl get pods -o wide

echo ""
echo "E2E PASS: k3d cluster came up via the installer's create_cluster() and ran a workload."
