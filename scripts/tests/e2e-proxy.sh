#!/usr/bin/env bash
# =============================================================================
#  e2e-proxy.sh — authenticated corporate-proxy end-to-end test
# -----------------------------------------------------------------------------
#  Stands up a real squid proxy that REQUIRES basic auth, then brings up a k3d
#  cluster via the installer's create_cluster() with HTTP(S)_PROXY pointed at it
#  as http://user:pass@host — and proves the cluster's nodes pull a workload
#  image THROUGH the authenticated proxy.
#
#  This exercises the corporate-proxy hardening end-to-end (the Tenant-a/hospital
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

# Shared bring-up contract (isolation env + tool-install prereqs).
# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbproxy

PROXY_USER="tbuser"
PROXY_PASS="tb-Pass.123"          # contains no '@', but the URL form does: user:pass@host
PROXY_PORT="3128"
SQUID_NAME="tb-squid"

# Pinned by DIGEST, and declared ONCE for both squids in this file (the host
# container below and the in-cluster Deployment further down) so the two cannot
# drift apart.
#
# Why pinned at all: this job is a candidate required status check, and under a
# floating tag an external registry push can redden it on an unrelated PR with
# nothing in the diff to explain why. Squid especially, because the hand-written
# squid.conf below names a path INSIDE the image,
# /usr/lib/squid/basic_ncsa_auth, and the access-log assertions further down
# parse squid's log format -- an image rebuild can move either, and the failure
# would surface as an unexplained red check on someone else's PR.
#
# Why by digest and not just the tag: Canonical publishes this image only under
# channel suffixes (_beta / _edge) -- there is no immutable plain 6.6-24.04 --
# and those channel tags demonstrably move: 6.6-24.04_edge carries a different
# digest, re-pushed months after 6.6-24.04_beta. A bare tag would therefore only
# narrow the hole this pin exists to close. The tag is kept alongside the digest
# for readability; the digest is what actually pins.
#
# Behaviour-preserving by construction: this digest is what ubuntu/squid:latest
# already resolved to when the pin was taken, so the e2e run proves the pin
# rather than a version migration. NOTE the tag name is Canonical's channel, not
# the upstream version -- this image ships Squid 6.13, verified with
# "squid -v" in the image itself. Moving to the 7.2-26.04 channel is a deliberate
# upgrade with its own run, not a side effect of pinning.
SQUID_IMAGE="ubuntu/squid:6.6-24.04_beta@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029"
WORK="$(mktemp -d)"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"

# The harness's verdict is captured FIRST and returned LAST: errexit is live
# inside an EXIT trap, so any command here that ends non-zero aborts the trap and
# overwrites the script's exit status (client#979 — that is how a correct `set -e`
# abort became GitHub's `cancelled`). This file had a SECOND route to the same
# loss: `rm -rf "$WORK"` was the trap's last statement, so its status was the one
# the job reported. e2e_cleanup_cluster is bounded, prints what it did, and always
# returns 0.
cleanup() {
  local _status=$?
  e2e_cleanup_cluster
  # SAME CLASS, adjacent site (client#979): `docker rm -f` talks to the same engine
  # e2e_cleanup_cluster was stalling on, and was equally unbounded and equally
  # silenced — a second route to the same 24 invisible minutes in the same trap.
  # stderr is kept so a real docker error is visible; the `|| echo` keeps this from
  # ending the trap non-zero.
  _bounded "${TB_E2E_DELETE_TIMEOUT:-120}" docker rm -f "$SQUID_NAME" >/dev/null \
    || echo "cleanup: could not remove the squid container ${SQUID_NAME} within ${TB_E2E_DELETE_TIMEOUT:-120}s — it may remain on this runner." >&2
  rm -rf "$WORK" 2>/dev/null || true
  return "$_status"
}
trap cleanup EXIT

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Authenticated-proxy E2E   arch: $(uname -m)"
echo "═══════════════════════════════════════════════════════════════════════"

# The proxy below is exercised by the cluster NODES, which is where the
# auth-proxy hardening lives — so we just need the CLI tools + a cluster.
e2e_install_prereqs

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
  "$SQUID_IMAGE" >/dev/null

echo "── waiting for squid + verifying auth is enforced ──"
ready=""
for _ in $(seq 1 30); do
  # A correctly-authenticated CONNECT to a registry should tunnel (curl exit 0);
  # squid returns 407 (curl exit 56/22) if auth is wrong or not yet up.
  # No -f: the registry answers 401 (needs a token) even on a healthy tunnel; we
  # only care that the proxy TUNNELED the request (curl exit 0) vs refused with
  # 407 (curl non-zero). -o /dev/null discards the body.
  if curl -sS --tlsv1.2 -m 8 -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${PROXY_PORT}" \
        https://registry-1.docker.io/v2/ -o /dev/null 2>/dev/null; then
    ready=1; break
  fi
  sleep 2
done
[[ -n "$ready" ]] || error "squid did not become ready / auth check failed."
# Prove auth is actually ENFORCED: a request with NO credentials must be refused.
if curl -sS --tlsv1.2 -m 8 -x "http://127.0.0.1:${PROXY_PORT}" https://registry-1.docker.io/v2/ -o /dev/null 2>/dev/null; then
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
# Pinned by digest for the same required-check reason as SQUID_IMAGE above.
# Nothing here asserts anything ABOUT nginx -- it is only a public image whose
# pull has to traverse the proxy -- so the version itself is immaterial; what
# matters is that an upstream rebuild cannot change what this check pulls. This
# digest is what nginx:alpine already resolved to when the pin was taken.
kubectl run e2e-probe --image=nginx:1.31.4-alpine@sha256:db35bfc6b2951e7f8a72db5db120288c127ffaeeb4a6d4b95a26fead017d5913 --restart=Never
kubectl wait --for=condition=Ready pod/e2e-probe --timeout=180s
kubectl get pods -o wide

# ── 3. prove the node's image pull actually traversed the AUTHED proxy ───────
echo "── squid access log: the node's authenticated image-pull traffic ──"
plog="$(docker exec "$SQUID_NAME" cat /var/log/squid/access.log 2>/dev/null || true)"
# Diagnostic preview only. `|| true` is load-bearing: with no matching lines the
# first grep exits 1 and, under `set -euo pipefail`, would kill the script HERE —
# before the real assertion just below could report the actual reason.
echo "$plog" | grep -E 'CONNECT' | grep "$PROXY_USER" | grep -E 'docker' | tail -8 | sed 's/^/    /' || true
# auth.docker.io is fetched only by a real image pull (the node getting a pull
# token) — never by the readiness probe to /v2/, which stops at the 401. So an
# authenticated CONNECT to it proves the NODE pulled through the proxy (not just
# the host's readiness check), closing the "proxy silently ignored" false-positive.
# Capture-then-match, NOT `… | grep -q` (backend#1778). grep -q closes the pipe
# on the first match, so on a busy proxy log the upstream grep takes SIGPIPE and
# pipefail makes the whole pipeline 141 — non-zero — which `if !` reads as "no
# match" and fires this error BECAUSE the CONNECT was there. A size-dependent
# false failure, and $plog is exactly the value that grows.
connect_lines="$(grep -E 'CONNECT .*auth\.docker\.io' <<<"$plog" || true)"
if ! grep -q "$PROXY_USER" <<<"$connect_lines"; then
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
#     pre-fix Job — in a real proxy-only network like Tenant-a that direct dial is
#     refused with [Errno 111]; here the env-unset call simply reaches the backend
#     stand-in directly, and we assert the *absence* of a proxied CONNECT).
#
# HERMETIC (no external network I/O): the "backend" both calls target is a
# reserved-TLD stand-in host — backend.tracebloc-e2e.test (RFC 6761 .test, which
# is guaranteed never to resolve on the public internet). We alias it, via
# /etc/hosts on BOTH the squid pod and the app pod, to the cluster's OWN
# kube-apiserver ClusterIP — a guaranteed, always-up in-cluster HTTPS:443 listener.
# So the squid's CONNECT tunnel terminates against a real in-cluster TLS endpoint
# and the test never dials the production backend. The previous revision curled the
# real https://api.tracebloc.io/ through the in-cluster squid, whose egress to that
# host depends on the CI runner's internet at test time — the intermittent flake
# that randomly red-X'd this required check on develop (e.g. run 27765964135).
echo "── reading the in-cluster kube-apiserver ClusterIP (the backend stand-in) ──"
APISERVER_IP="$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
[[ -n "$APISERVER_IP" ]] || error "Could not read the kube-apiserver ClusterIP for the in-cluster backend stand-in."
BACKEND_HOST="backend.tracebloc-e2e.test"

echo "── deploying an in-cluster squid the test pods can reach by Service DNS ──"
kubectl apply -f - <<YAML
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
      # Resolve the stand-in backend host to the in-cluster kube-apiserver so the
      # CONNECT tunnel terminates locally (squid honours /etc/hosts by default).
      hostAliases:
        - ip: "${APISERVER_IP}"
          hostnames: ["${BACKEND_HOST}"]
      containers:
        - name: squid
          image: ${SQUID_IMAGE}
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
# The stand-in backend host is deliberately OUTSIDE this list (not a .svc / RFC1918
# entry), so WITH the env set curl routes it through the proxy.
APP_PROXY_URL="http://tb-egress-squid.default.svc.cluster.local:3128"
APP_NO_PROXY="localhost,127.0.0.1,mysql-client,requests-proxy-service,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# ONE pod carrying the ingestion-style proxy env (BOTH cases — curl honours the
# lower-case `https_proxy` for HTTPS; the real ingestion env emits both, so the
# probe must too or it silently dials direct and the test is a lie). It makes two
# calls to the SAME backend: (A) with the proxy env it must traverse the squid via
# a CONNECT tunnel; (B) with the proxy env unset it must dial direct. A single pod
# keeps this deterministic — no multi-pod scheduling / log-flush race to flake on.
# The same stand-in→apiserver /etc/hosts alias lets the (B) direct call reach a
# real in-cluster TLS endpoint instead of failing DNS. `-k`: the apiserver presents
# the cluster-CA cert (untrusted here) — we assert proxy ROUTING, not TLS trust, so
# verification is skipped and both calls complete to a real 401.
# §A's probe, single-sourced from e2e-common.sh so the bats suite runs the very
# same text (see e2e_proxy_probe_snippet for WHY it loops fresh curl PROCESSES
# instead of using curl's own --retry — backend#2350). Indented to sit inside the
# pod manifest's literal block scalar below. Assigned to a variable, NOT inlined
# in the heredoc: a heredoc swallows the exit status of a command substitution,
# so the function's fail-closed guard would not stop the run from there.
APP_PROBE_SNIPPET="$(e2e_proxy_probe_snippet "$BACKEND_HOST" | sed 's/^/          /')"

echo "── one app pod: WITH the ingestion proxy env it must tunnel via the squid; with it unset it must dial direct ──"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: egress-app }
spec:
  restartPolicy: Never
  hostAliases:
    - ip: "${APISERVER_IP}"
      hostnames: ["${BACKEND_HOST}"]
  containers:
    - name: app
      # Pinned, and to the SAME tag as e2e_egress_positive_control's probe in
      # lib/e2e-common.sh, so the suite's two curl probes cannot drift apart.
      #
      # Why: this job is a candidate required status check, and a floating tag
      # lets an external registry's next push block a merge here with nothing in
      # the diff to explain why. That exposure is a property of the whole job,
      # not of this one line -- the squid and nginx images it also pulls were
      # digest-pinned in client#814 (backend#2446). With those and this, every
      # image the job pulls is pinned; none of them floats.
      #
      # Not a flake fix: latest and 8.20.0 were both measured under backend#2350
      # and behave identically with respect to curl's negative DNS caching.
      image: curlimages/curl:8.20.0
      env:
        - { name: HTTP_PROXY,  value: "${APP_PROXY_URL}" }
        - { name: HTTPS_PROXY, value: "${APP_PROXY_URL}" }
        - { name: http_proxy,  value: "${APP_PROXY_URL}" }
        - { name: https_proxy, value: "${APP_PROXY_URL}" }
        - { name: NO_PROXY,    value: "${APP_NO_PROXY}" }
        - { name: no_proxy,    value: "${APP_NO_PROXY}" }
      command: ["sh", "-c"]
      args:
        - |
          echo ">>>>> SECTION_A_WITH_PROXY_ENV"
${APP_PROBE_SNIPPET}
          echo ">>>>> SECTION_B_PROXY_ENV_UNSET"
          env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u NO_PROXY -u no_proxy curl -k -v -sS -m 20 -o /dev/null https://${BACKEND_HOST}/ 2>&1
          echo ">>>>> SECTION_END"
YAML

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
# which the log daemon buffers and may not have flushed when we read it. These two
# lines are DIAGNOSTIC ONLY; the trailing `|| true` is load-bearing: when a section
# is empty (the failure case) `grep` exits 1 and, under `set -euo pipefail`, the
# pipeline would kill the whole script HERE — before the real assertions below can
# print WHY (the CI log then shows only "exit code 1" with no reason). `|| true`
# keeps the diagnostics non-fatal so the assertions get to run and report.
printf '%s\n' "$a_section" | grep -iE 'Establish HTTP proxy tunnel|CONNECT tunnel established|< HTTP/' | sed 's/^/    A WITH proxy env:  /' || true
printf '%s\n' "$b_section" | grep -iE 'Trying|Connected to|< HTTP/|Could not resolve'                 | sed 's/^/    B env unset:       /' || true
# (A) WITH the ingestion proxy env, the backend call MUST traverse the squid.
# Here-string, not a pipe into grep -q (backend#1778): a 141 from SIGPIPE would
# read as "no tunnel" and fail the run on a long section that DID tunnel.
if ! grep -qiE 'Establish HTTP proxy tunnel to backend\.tracebloc-e2e\.test|CONNECT tunnel established' <<<"$a_section"; then
  # The filtered diagnostics above matched nothing on a novel failure (run
  # 29255451968 showed only the B line). Dump the RAW pod log + squid/endpoint
  # state so the cause is visible next time instead of a bare "did NOT tunnel."
  echo "── DIAGNOSTIC: raw egress-app log (section A showed no proxy tunnel) ──"
  printf '%s\n' "$applog" | sed 's/^/    app| /'
  echo "── DIAGNOSTIC: squid pod + service endpoints ──"
  kubectl get pod -l app=tb-egress-squid -o wide 2>&1 | sed 's/^/    /' || true
  kubectl get endpoints tb-egress-squid 2>&1 | sed 's/^/    /' || true
  error "App pod WITH the ingestion proxy env did NOT tunnel through the squid — ingestion-style backend egress is not proxied (the #119 bug)."
fi
# (B) With the env unset, the SAME call MUST NOT use a proxy (it dials direct).
# Here-string (backend#1778). Here the 141 would read as "no proxy used" and
# SKIP the assertion entirely — a false pass, the quieter half of the same bug.
if grep -qiE 'proxy tunnel|CONNECT tunnel established' <<<"$b_section"; then
  error "App pod with the proxy env unset still used a proxy — unexpected; that path should dial direct."
fi
success "App-pod egress verified: WITH the ingestion proxy env the backend call tunnelled through the in-cluster squid; with it unset the same call dialled direct."

echo ""
echo "E2E PASS: cluster came up via an AUTHENTICATED proxy, pulled a workload through it, and an ingestion-style app pod tunnelled to an in-cluster backend stand-in through a proxy (with the proxy env unset the same call dialled direct)."
