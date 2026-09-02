#!/usr/bin/env bash
# =============================================================================
#  e2e-mysql.sh — native-arm64 MySQL 8.4 install + real-driver auth e2e (backend#723)
# -----------------------------------------------------------------------------
#  The gap this closes (backend#723, Option A): the chart/installer ship the
#  native multi-arch MySQL 8.4 engine for fresh installs, but nothing asserted,
#  on a real host, that it (a) runs NATIVELY on arm64 (not silently under qemu)
#  and (b) accepts the clients' cold-cache plaintext connect without ERROR 2061.
#  The Deployment's only probe is `mysqladmin ping`, which passes regardless of
#  the auth plugin — so it cannot catch the D2 regression. This does.
#
#  It brings up a real k3d cluster via the installer's own create_cluster(),
#  helm-installs THIS chart with the 8.4 engine on a public-image / hostPath
#  profile with dummy creds (no registry secret, no backend registration — the
#  private pods ImagePullBackOff and are ignored; mysql-client is a PUBLIC
#  image), then asserts against the live server:
#    * the mysql-format-guard init container passed on the fresh datadir;
#    * the container runs the host's native arch (aarch64 on an arm64 runner) —
#      an emulated single-arch pull would mismatch;
#    * engine is 8.4.x and edgeuser is mysql_native_password (D2);
#    * max_allowed_packet is the chart ConfigMap's 256M;
#  and runs the real driver (mysql-connector-python, scripts/tests/lib/
#  mysql-auth-probe.py) as an in-cluster Job for a cold-cache connect, a
#  dataset enumeration, and a multi-MB LONGBLOB round-trip — once on first boot
#  and again after a `rollout restart` (the strategy: Recreate cache-wipe case).
#
#  Engine selection: this test installs the 8.4 tag EXPLICITLY. The installer's
#  arch-driven auto-resolution (fresh arm64 -> 8.4) is exhaustively covered by
#  the bats suite (_resolve_mysql_engine in install-client-helm.bats); the
#  unique value here is proving the resolved image actually runs native and
#  authenticates. On amd64 this also proves the multi-arch 8.4 image runs there.
#
#  No secrets; stock GitHub runners (Docker preinstalled), amd64 + arm64.
#  Usage:  bash scripts/tests/e2e-mysql.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"
CHART_DIR="$HERE/../../client"

# Shared bring-up contract (isolation env + tool-install prereqs).
# shellcheck source=/dev/null
source "$HERE/lib/e2e-common.sh"
e2e_isolate_env tbmysql
NS="tbmysql"

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"
# shellcheck source=/dev/null
source "$LIB/cluster.sh"
# shellcheck source=/dev/null
source "$LIB/preflight.sh"   # provides _pf_recheck_runtime_mem (called by create_cluster)

cleanup() { k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The baked root credential of tracebloc/mysql-client (public image; a throwaway
# in-cluster password, see the Dockerfile). Used only to read server state.
MYSQL_PW="Edg9@Tr@ce"
# Pinned so the run is reproducible; mirrors the runtime clients' 9.x connector.
CONNECTOR_VERSION="${MYSQL_CONNECTOR_VERSION:-9.4.0}"

# ── mysql_root <sql> — run SQL as root over TCP, plaintext, no TLS ────────────
# TCP (-h 127.0.0.1), NOT the default socket: on a fresh datadir the server's
# unix socket lands at /var/lib/mysql/mysql.sock, while the client's compiled
# default is /var/run/mysqld/mysqld.sock — so a socket connect finds nothing and
# hangs/fails. 127.0.0.1 is the path the chart's own readiness probe uses.
mysql_root() {
  kubectl -n "$NS" exec deploy/mysql-client -c mysql-client -- \
    mysql -h 127.0.0.1 -uroot -p"$MYSQL_PW" --ssl-mode=DISABLED -N -e "$1" 2>/dev/null
}

# ── _dump_mysql_state — diagnostics for a wait/probe failure ──────────────────
_dump_mysql_state() {
  echo "── DIAGNOSTICS: mysql-client state ──" >&2
  kubectl -n "$NS" get pods -l app=mysql-client -o wide >&2 2>&1 || true
  kubectl -n "$NS" describe pod -l app=mysql-client 2>&1 | sed -n '/Events:/,$p' | head -25 >&2 || true
  echo "── mysql-client container log (tail) ──" >&2
  kubectl -n "$NS" logs deploy/mysql-client -c mysql-client --tail=60 >&2 2>&1 || true
  echo "── previous container log, if it restarted ──" >&2
  kubectl -n "$NS" logs deploy/mysql-client -c mysql-client --previous --tail=40 >&2 2>&1 || true
}

# ── wait_accepting — block until mysqld ANSWERS AN AUTHENTICATED QUERY ─────────
# rollout status returns on the chart's `mysqladmin ping` readiness probe, which
# answers "alive" against the fresh-init temporary server and even on
# access-denied — so it can go ready before the real server finishes a cold
# datadir init (slow on a loaded CI runner). Gate on an actual authenticated
# SELECT 1 over TCP (see mysql_root on why not the socket), which only succeeds
# once the real server is up AND the account is usable. Generous window: a
# first-boot init on a busy runner is far slower than the ~15s it takes locally.
wait_accepting() {
  local i
  for i in $(seq 1 60); do
    if kubectl -n "$NS" exec deploy/mysql-client -c mysql-client -- \
        mysql -h 127.0.0.1 -uroot -p"$MYSQL_PW" --ssl-mode=DISABLED -N -e "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    (( i % 10 == 0 )) && echo "   … still waiting for mysqld to accept authenticated connections (${i}0s)"
    sleep 3
  done
  _dump_mysql_state
  fail "mysqld did not start accepting authenticated connections within 180s"
}

# ── run_probe <label> — the real-driver auth Job, fresh each call ─────────────
# A fresh pod each time = a genuine cold-cache connect. Under caching_sha2 the
# plaintext connect throws every attempt (no RSA/TLS ever offered), so retrying
# transient infra errors cannot mask the D2 regression — but we don't need to:
# wait_accepting gates the launch. backoffLimit 0 -> a real failure fails fast.
run_probe() {
  local label="$1"
  kubectl -n "$NS" create configmap mysql-auth-probe \
    --from-file=mysql-auth-probe.py="$LIB/mysql-auth-probe.py" \
    --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
  kubectl -n "$NS" delete job mysql-auth-probe --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: mysql-auth-probe
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: probe
        image: python:3.12-slim
        command: ["sh", "-c", "pip install --quiet --no-cache-dir mysql-connector-python==${CONNECTOR_VERSION} && python /probe/mysql-auth-probe.py"]
        volumeMounts:
        - name: probe
          mountPath: /probe
      volumes:
      - name: probe
        configMap:
          name: mysql-auth-probe
EOF
  echo "── auth probe (${label}): real driver mysql-connector-python==${CONNECTOR_VERSION} ──"
  local s f
  for _ in $(seq 1 40); do
    s="$(kubectl -n "$NS" get job mysql-auth-probe -o jsonpath='{.status.succeeded}' 2>/dev/null)"
    f="$(kubectl -n "$NS" get job mysql-auth-probe -o jsonpath='{.status.failed}' 2>/dev/null)"
    [[ "$s" == "1" ]] && break
    [[ "$f" == "1" ]] && break
    sleep 6
  done
  kubectl -n "$NS" logs job/mysql-auth-probe 2>&1 | grep -E '^\[ok\]|^FAIL|AUTH-PROBE-PASS' || true
  [[ "$(kubectl -n "$NS" get job mysql-auth-probe -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]] \
    || fail "auth probe (${label}) did not pass — see the Job logs above"
}

HOST_ARCH="$(uname -m)"   # aarch64 on an arm64 runner, x86_64 on amd64
echo "═══════════════════════════════════════════════════════════════════════"
echo "  E2E mysql 8.4   host arch: ${HOST_ARCH}   kernel: $(uname -r)"
echo "═══════════════════════════════════════════════════════════════════════"

e2e_install_prereqs

echo "── create_cluster() — the installer's real cluster-bring-up path ──"
create_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "── helm install THIS chart on the 8.4 engine (hostPath, dummy creds) ──"
# hostPath storage sidesteps the dynamic provisioner (no CSI on a stock runner);
# storageClass.create=false because hostPath needs no dynamic StorageClass. The
# non-mysql pods pull private images and ImagePullBackOff — expected and ignored.
helm install "$NS" "$CHART_DIR" --namespace "$NS" --create-namespace \
  --set clientId=ci-e2e-mysql --set clientPassword=ci-e2e-mysql \
  --set hostPath.enabled=true --set storageClass.create=false \
  --set images.mysqlClient.tag=8.4 --set images.mysqlClient.digest=""

echo "── wait for mysql-client (format-guard init + mysqld) to be Available ──"
kubectl -n "$NS" rollout status deploy/mysql-client --timeout=300s
wait_accepting

echo "── assert: the mysql-format-guard init container passed on the fresh datadir ──"
guard_exit="$(kubectl -n "$NS" get pod -l app=mysql-client \
  -o jsonpath='{.items[0].status.initContainerStatuses[?(@.name=="mysql-format-guard")].state.terminated.exitCode}' 2>/dev/null)"
[[ "$guard_exit" == "0" ]] || fail "mysql-format-guard did not complete cleanly (exitCode='${guard_exit}')"

echo "── assert: NATIVE arch, engine 8.4.x, native_password, 256M packet ──"
container_arch="$(kubectl -n "$NS" exec deploy/mysql-client -c mysql-client -- uname -m 2>/dev/null | tr -d '[:space:]')"
[[ "$container_arch" == "$HOST_ARCH" ]] \
  || fail "container arch '${container_arch}' != host '${HOST_ARCH}' — image is emulated, not native"

version="$(mysql_root 'SELECT VERSION();' | tr -d '[:space:]')"
[[ "$version" == 8.4.* ]] || fail "server version '${version}' is not 8.4.x"

plugin="$(mysql_root "SELECT plugin FROM mysql.user WHERE user='edgeuser';" | tr -d '[:space:]')"
[[ "$plugin" == "mysql_native_password" ]] || fail "edgeuser plugin is '${plugin}', not mysql_native_password (D2)"

packet="$(mysql_root 'SELECT @@max_allowed_packet;' | tr -d '[:space:]')"
if [[ "$packet" != "268435456" ]]; then
  # Diagnose whether the mysql-client-config ConfigMap (256M) reached the server:
  # is the file present at the include path, and can the mysqld user read it?
  echo "── DIAGNOSTICS: max_allowed_packet=${packet}, want 268435456 ──" >&2
  kubectl -n "$NS" exec deploy/mysql-client -c mysql-client -- sh -c '
    echo "== mysqld user =="; id
    echo "== /etc/my.cnf includedir =="; grep -n includedir /etc/my.cnf /etc/mysql/my.cnf 2>/dev/null
    echo "== /etc/mysql/conf.d (numeric owners) =="; ls -lnL /etc/mysql/conf.d/ 2>&1
    echo "== can the mysqld user read mysql.cnf? =="; cat /etc/mysql/conf.d/mysql.cnf >/dev/null 2>&1 && echo READABLE || echo UNREADABLE
    echo "== mysql.cnf content =="; cat /etc/mysql/conf.d/mysql.cnf 2>&1 | head -4
  ' >&2 2>&1 || true
  fail "max_allowed_packet='${packet}', expected 268435456 (mysql-client-config not in effect — see diagnostics)"
fi

digest="$(kubectl -n "$NS" get pod -l app=mysql-client -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
echo "   arch=${container_arch}  version=${version}  plugin=${plugin}  max_allowed_packet=${packet}"
echo "   resolved image: ${digest}"

# The regression surface: cold-cache first connect, then again after the
# strategy:Recreate cache-wipe.
run_probe "cold-cache first boot"

echo "── rollout restart (strategy:Recreate wipes the server-side auth cache) ──"
kubectl -n "$NS" rollout restart deploy/mysql-client
kubectl -n "$NS" rollout status deploy/mysql-client --timeout=180s
wait_accepting
run_probe "post-Recreate"

echo ""
echo "E2E PASS: native ${HOST_ARCH} MySQL ${version}; edgeuser ${plugin}; cold-cache + post-Recreate real-driver auth OK."
