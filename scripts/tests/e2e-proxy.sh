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

# ── 4. APPLICATION-pod egress through a proxy (client-runtime#119) ────────────
# §1-3 prove NODE egress (image pulls) through the AUTHENTICATED host squid. But
# the ingestion Job and training pods are application pods that POST to the
# backend via requests/urllib3 — they only traverse a proxy if their POD env
# carries HTTP(S)_PROXY (build_job_spec / jobs_manager._add_environment_variables).
# That layer is what client-runtime#119 was about, and §3 never touches it.
#
# A pod cannot reach the host squid via host.k3d.internal (that alias is for k3d
# NODES, not pod DNS), so we stand up an in-cluster squid the pods reach by
# Service DNS — a closer model of a real corporate proxy reachable by name. Auth
# survival is already covered by §1-3; this section is about proxy-env ROUTING.
# One pod carries the ingestion-style proxy env and makes two calls to the SAME
# backend (one pod / two calls = deterministic; no multi-pod scheduling or
# log-flush race to flake on):
#   * WITH the proxy env it reaches the backend THROUGH the squid (the fixed
#     ingestion Job);
#   * with that env unset the same call bypasses the squid / dials direct (the
#     pre-fix Job — in a real proxy-only network like Charité that direct dial is
#     refused with [Errno 111]; here the node has direct egress, so we assert the
#     *absence* of a proxied CONNECT).
echo "── deploying an in-cluster squid the test pods can reach by Service DNS ──"
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: tb-egress-squid }
data:
  squid.conf: |
    acl SSL_ports port 443
    acl CONNECT method CONNECT
    http_access deny CONNECT !SSL_ports
    http_access allow all
    http_port 3128
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: tb-egress-squid, labels: { app: tb-egress-squid } }
spec:
  replicas: 1
  selector: { matchLabels: { app: tb-egress-squid } }
  template:
    metadata: { labels: { app: tb-egress-squid } }
    spec:
      containers:
        - name: squid
          image: ubuntu/squid:latest
          ports: [{ containerPort: 3128 }]
          # Gate rollout on squid actually LISTENING, so the probe pods below
          # don't race a not-yet-bound port (the "connect refused after 1ms").
          readinessProbe:
            tcpSocket: { port: 3128 }
            initialDelaySeconds: 2
            periodSeconds: 2
          volumeMounts:
            - { name: conf, mountPath: /etc/squid/squid.conf, subPath: squid.conf }
      volumes:
        - { name: conf, configMap: { name: tb-egress-squid } }
---
apiVersion: v1
kind: Service
metadata: { name: tb-egress-squid }
spec:
  selector: { app: tb-egress-squid }
  ports: [{ port: 3128, targetPort: 3128 }]
YAML
kubectl rollout status deploy/tb-egress-squid --timeout=180s

# Mirrors _EGRESS_NO_PROXY / the chart's cluster-safe NO_PROXY: in-cluster direct.
APP_PROXY_URL="http://tb-egress-squid.default.svc.cluster.local:3128"
APP_NO_PROXY="localhost,127.0.0.1,mysql-client,requests-proxy-service,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# ONE pod carrying the ingestion-style proxy env (BOTH cases — curl honours the
# lower-case `https_proxy` for HTTPS; the real ingestion env emits both, so the
# probe must too or it silently dials direct and the test is a lie). It makes two
# calls to the SAME backend: (A) with the proxy env it must traverse the squid via
# a CONNECT tunnel; (B) with the proxy env unset it must dial direct. A single pod
# keeps this deterministic — no multi-pod scheduling / log-flush race to flake on.
echo "── one app pod: WITH the ingestion proxy env it must tunnel via the squid; with it unset it must dial direct ──"
kubectl run egress-app --image=curlimages/curl:latest --restart=Never \
  --env="HTTP_PROXY=${APP_PROXY_URL}"  --env="HTTPS_PROXY=${APP_PROXY_URL}" \
  --env="http_proxy=${APP_PROXY_URL}"  --env="https_proxy=${APP_PROXY_URL}" \
  --env="NO_PROXY=${APP_NO_PROXY}"     --env="no_proxy=${APP_NO_PROXY}" \
  --command -- sh -c '
    echo ">>>>> SECTION_A_WITH_PROXY_ENV";
    curl -v -sS -m 20 -o /dev/null https://api.tracebloc.io/ 2>&1;
    echo ">>>>> SECTION_B_PROXY_ENV_UNSET";
    env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy curl -v -sS -m 20 -o /dev/null https://api.tracebloc.io/ 2>&1;
    echo ">>>>> SECTION_END"'

# Wait for the pod to finish, then read its single log once.
for _ in $(seq 1 90); do
  phase="$(kubectl get pod egress-app -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
  sleep 2
done
applog="$(kubectl logs egress-app 2>/dev/null || true)"
a_section="$(printf '%s\n' "$applog" | awk '/SECTION_A_WITH_PROXY_ENV/{f=1;next} /SECTION_B_PROXY_ENV_UNSET/{f=0} f')"
b_section="$(printf '%s\n' "$applog" | awk '/SECTION_B_PROXY_ENV_UNSET/{f=1;next} /SECTION_END/{f=0} f')"

# Proof is CLIENT-side from `curl -v` — deterministic, unlike squid's access log
# which the log daemon buffers and may not have flushed when we read it.
printf '%s\n' "$a_section" | grep -iE 'Establish HTTP proxy tunnel|CONNECT tunnel established|< HTTP/1.1 200' | sed 's/^/    A WITH proxy env:  /'
printf '%s\n' "$b_section" | grep -iE 'Trying|Connected to|< HTTP/1.1 200'                                   | sed 's/^/    B env unset:       /'
# (A) WITH the ingestion proxy env, the backend call MUST traverse the squid.
if ! printf '%s' "$a_section" | grep -qiE 'Establish HTTP proxy tunnel to api\.tracebloc\.io|CONNECT tunnel established'; then
  error "App pod WITH the ingestion proxy env did NOT tunnel through the squid — ingestion-style backend egress is not proxied (the #119 bug)."
fi
# (B) With the env unset, the SAME call MUST NOT use a proxy (it dials direct).
if printf '%s' "$b_section" | grep -qiE 'proxy tunnel|CONNECT tunnel established'; then
  error "App pod with the proxy env unset still used a proxy — unexpected; that path should dial direct."
fi
success "App-pod egress verified: WITH the ingestion proxy env the backend call tunnelled through the in-cluster squid; with it unset the same call dialled direct."

echo ""
echo "E2E PASS: cluster came up via an AUTHENTICATED proxy, pulled a workload through it, and an ingestion-style app pod egressed to the backend through a proxy (a no-proxy pod bypassed it)."
