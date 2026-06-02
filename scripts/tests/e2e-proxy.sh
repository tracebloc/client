#!/usr/bin/env bash
# =============================================================================
#  e2e-proxy.sh — authenticated corporate-proxy end-to-end test
# -----------------------------------------------------------------------------
#  Stands up a real squid proxy that REQUIRES basic auth, then brings up a k3d
#  cluster via the installer's create_cluster() with HTTP(S)_PROXY pointed at it
#  as http://user:pass@host — and proves the cluster's nodes pull a workload
#  image THROUGH the authenticated proxy.
#
#  This exercises the corporate-proxy hardening end-to-end (the Charité/hospital
#  archetype): _write_k3d_proxy_config (passes proxy env via a k3d CONFIG FILE so
#  the '@' in user:pass@host survives — k3d splits --env on '@') + _augment_no_proxy
#  (so in-cluster traffic bypasses the proxy and `--wait` doesn't hang).
#
#  If the credentials get mangled, squid answers 407, the image pull hangs, and
#  the pod never goes Ready — so this test fails loudly on a proxy-auth regression.
#  It stops before the tracebloc helm install / backend registration (no secrets).
#
#  Usage:  bash scripts/tests/e2e-proxy.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

export USER="${USER:-$(id -un)}"
export CLUSTER_NAME="${CLUSTER_NAME:-tbproxy}"
export TRACEBLOC_NO_AUTOSTART=1

PROXY_USER="tbuser"
PROXY_PASS="tb-Pass.123"          # contains no '@', but the URL form does: user:pass@host
PROXY_PORT="3128"
SQUID_NAME="tb-squid"
WORK="$(mktemp -d)"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"

cleanup() {
  k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
  docker rm -f "$SQUID_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Authenticated-proxy E2E   arch: $(uname -m)"
echo "═══════════════════════════════════════════════════════════════════════"

has docker || error "Docker is not available on this host."

# Install the CLI tools directly (the proxy below is exercised by the cluster
# NODES, which is where the auth-proxy hardening lives).
umask 022
install_kubectl
install_k3d
install_helm

# ── 1. squid that REQUIRES basic auth ───────────────────────────────────────
echo "── starting an authenticated squid proxy ──"
printf '%s:%s\n' "$PROXY_USER" "$(openssl passwd -apr1 "$PROXY_PASS")" > "$WORK/passwords"
cat > "$WORK/squid.conf" <<'EOF'
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm tracebloc-test-proxy
acl authed proxy_auth REQUIRED
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny CONNECT !SSL_ports
http_access allow authed
http_access deny all
http_port 3128
EOF
docker rm -f "$SQUID_NAME" >/dev/null 2>&1 || true
docker run -d --name "$SQUID_NAME" -p "${PROXY_PORT}:3128" \
  -v "$WORK/squid.conf:/etc/squid/squid.conf:ro" \
  -v "$WORK/passwords:/etc/squid/passwords:ro" \
  ubuntu/squid:latest >/dev/null

echo "── waiting for squid + verifying auth is enforced ──"
ready=""
for _ in $(seq 1 30); do
  # A correctly-authenticated CONNECT to a registry should tunnel (curl exit 0);
  # squid returns 407 (curl exit 56/22) if auth is wrong or not yet up.
  # No -f: the registry answers 401 (needs a token) even on a healthy tunnel; we
  # only care that the proxy TUNNELED the request (curl exit 0) vs refused with
  # 407 (curl non-zero). -o /dev/null discards the body.
  if curl -sS -m 8 -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT}" \
        https://registry-1.docker.io/v2/ -o /dev/null 2>/dev/null; then
    ready=1; break
  fi
  sleep 2
done
[[ -n "$ready" ]] || error "squid did not become ready / auth check failed."
# Prove auth is actually ENFORCED: a request with NO credentials must be refused.
if curl -sS -m 8 -x "http://127.0.0.1:${PROXY_PORT}" https://registry-1.docker.io/v2/ -o /dev/null 2>/dev/null; then
  error "Proxy allowed an unauthenticated request — auth not enforced; test is invalid."
fi
success "Authenticated squid proxy up (anonymous requests refused)."

# ── 2. bring up the cluster with the nodes pointed at the AUTHED proxy ───────
# Nodes reach the host's published squid via host.k3d.internal (k3d injects it).
# The user:pass@host form is the exact shape the #174 fix protects.
export HTTP_PROXY="http://${PROXY_USER}:${PROXY_PASS}@host.k3d.internal:${PROXY_PORT}"
export HTTPS_PROXY="$HTTP_PROXY"
echo "── create_cluster() with HTTP(S)_PROXY=http://${PROXY_USER}:***@host.k3d.internal:${PROXY_PORT} ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "── wait for the default ServiceAccount (created async after node Ready) ──"
for _ in $(seq 1 30); do
  kubectl get serviceaccount default -n default >/dev/null 2>&1 && break
  sleep 2
done

echo "── pull + run a public workload — the node must fetch it THROUGH the proxy ──"
kubectl run e2e-probe --image=nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/e2e-probe --timeout=180s
kubectl get pods -o wide

# ── 3. prove the node's image pull actually traversed the AUTHED proxy ───────
echo "── squid access log: the node's authenticated image-pull traffic ──"
plog="$(docker exec "$SQUID_NAME" cat /var/log/squid/access.log 2>/dev/null || true)"
echo "$plog" | grep -E 'CONNECT' | grep "$PROXY_USER" | grep -E 'docker' | tail -8 | sed 's/^/    /'
# auth.docker.io is fetched only by a real image pull (the node getting a pull
# token) — never by the readiness probe to /v2/, which stops at the 401. So an
# authenticated CONNECT to it proves the NODE pulled through the proxy (not just
# the host's readiness check), closing the "proxy silently ignored" false-positive.
if ! echo "$plog" | grep -E 'CONNECT .*auth\.docker\.io' | grep -q "$PROXY_USER"; then
  error "No authenticated auth.docker.io CONNECT in the proxy log — the node's image pull did not traverse the proxy."
fi

echo ""
echo "E2E PASS: cluster came up via an AUTHENTICATED proxy and pulled a workload through it."
