#!/usr/bin/env bats
# Tests for scripts/lib/cluster.sh — corporate-proxy hardening:
#   Gap A — authenticated proxies propagated via a k3d --config file
#           (k3d's --env KEY=VALUE@FILTER can't carry an '@' in the value).
#   Gap B — NO_PROXY auto-augmented with the cluster-internal ranges, both into
#           the cluster and host-side, so in-cluster traffic never traverses the
#           proxy (which would misroute it and hang `k3d cluster create --wait`).
#   Gap C — externally-created clusters that bind 0.0.0.0 are detected + flagged.
load test_helper

setup() {
  load_lib cluster.sh
  MOCK_CALLS="$(mktemp)"
  CFG_CAPTURE="$(mktemp)"
  CLUSTER_NAME=tracebloc
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"
  SERVERS=1; AGENTS=0; K8S_VERSION=""; K3D_GPU_FLAGS=()
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy

  # k3d mock: record argv; if a --config <path> is present, snapshot the file so
  # a test can assert its contents (cluster.sh deletes the temp dir after create).
  k3d() {
    record "k3d $*"
    local prev="" a
    for a in "$@"; do
      [[ "$prev" == "--config" ]] && cp "$a" "$CFG_CAPTURE" 2>/dev/null
      prev="$a"
    done
    return 0
  }
  docker() { record "docker $*"; return 0; }
}

# ── _augment_no_proxy (Gap B) ───────────────────────────────────────────────
@test "_augment_no_proxy: empty host NO_PROXY -> cluster-internal defaults" {
  run _augment_no_proxy
  [ "$status" -eq 0 ]
  [[ "$output" == *"localhost"* ]]
  [[ "$output" == *"169.254.169.254"* ]]
  [[ "$output" == *"127.0.0.1"* ]]
  [[ "$output" == *"10.0.0.0/8"* ]]
  [[ "$output" == *".svc"* ]]
  [[ "$output" == *".cluster.local"* ]]
  [[ "$output" == *"host.k3d.internal"* ]]
}

@test "_augment_no_proxy: host entries kept first and de-duplicated" {
  NO_PROXY="foo.com,127.0.0.1"
  run _augment_no_proxy
  [[ "$output" == "foo.com,127.0.0.1,"* ]]            # host entries first
  [ "$(grep -o '127\.0\.0\.1' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ]   # deduped
}

@test "_augment_no_proxy: lowercase no_proxy is honoured" {
  no_proxy="bar.internal"
  run _augment_no_proxy
  [[ "$output" == "bar.internal,"* ]]
}

# ── _write_k3d_proxy_config (Gap A + B) ─────────────────────────────────────
@test "_write_k3d_proxy_config: no proxy set -> empty (no file)" {
  run _write_k3d_proxy_config
  [ -z "$output" ]
}

@test "_write_k3d_proxy_config: auth creds preserved (Gap A) + augmented NO_PROXY (Gap B)" {
  HTTP_PROXY="http://user:pass@proxy.example.com:8080"
  HTTPS_PROXY="http://user:pass@proxy.example.com:8080"
  NO_PROXY="corp.internal"
  run _write_k3d_proxy_config
  [ -n "$output" ]
  local cfg="$output"
  [ -f "$cfg" ]
  grep -q 'apiVersion: k3d.io/v1alpha5' "$cfg"
  grep -q 'nodeFilters' "$cfg"
  # the whole point of Gap A: the embedded '@' credentials survive intact
  grep -q 'HTTP_PROXY=http://user:pass@proxy.example.com:8080' "$cfg"
  grep -q 'HTTPS_PROXY=http://user:pass@proxy.example.com:8080' "$cfg"
  # augmented NO_PROXY: host entry first + cluster-internal ranges
  grep -q 'NO_PROXY=corp.internal,' "$cfg"
  grep -Eq 'NO_PROXY=.*127\.0\.0\.1' "$cfg"
  grep -Eq 'NO_PROXY=.*\.svc' "$cfg"
  rm -rf "${cfg%/*}"
}

@test "_write_k3d_proxy_config: HTTP_PROXY only still emits augmented NO_PROXY" {
  HTTP_PROXY="http://proxy:8080"
  run _write_k3d_proxy_config
  local cfg="$output"
  [ -f "$cfg" ]
  grep -Eq 'NO_PROXY=.*127\.0\.0\.1' "$cfg"
  rm -rf "${cfg%/*}"
}

# ── _export_host_no_proxy (Gap B, host-side) ────────────────────────────────
@test "_export_host_no_proxy: exports augmented NO_PROXY when a proxy is set" {
  HTTP_PROXY="http://proxy:8080"
  _export_host_no_proxy
  [[ "$NO_PROXY" == *"127.0.0.1"* ]]
  [[ "$no_proxy" == *".svc"* ]]
}

@test "_export_host_no_proxy: no-op when no proxy is set" {
  _export_host_no_proxy
  [ -z "${NO_PROXY:-}" ]
}

# ── _create_new_cluster: proxy propagation via --config (Gap A integration) ──
@test "_create_new_cluster: auth proxy propagated via --config, not skipped" {
  HTTP_PROXY="http://user:pass@proxy.example.com:8080"
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]]
  [[ "$output" == *"--config"* ]]
  [[ "$output" != *"Skipping"* ]]                       # old @-skip path is gone
  grep -q 'user:pass@proxy.example.com' "$CFG_CAPTURE"
}

@test "_create_new_cluster: no proxy -> no --config flag" {
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]]
  [[ "$output" != *"--config"* ]]
}

# ── HOST_DATASET_DIR: second bind-mount + dataset dir split (backend#743) ────
@test "_create_new_cluster: HOST_DATASET_DIR unset -> single /tracebloc mount" {
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]]
  [[ "$output" != *"/tracebloc-data@all"* ]]
}

@test "_create_new_cluster: HOST_DATASET_DIR set -> adds a distinct /tracebloc-data mount" {
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"; mkdir -p "$HOST_DATASET_DIR"
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]]                 # mysql/logs stay local
  [[ "$output" == *"${HOST_DATASET_DIR}:/tracebloc-data@all"* ]]         # datasets on the mount
}

# ── RFC-0003 Option C: node-local storage (client#367) ──────────────────────
@test "_create_new_cluster: node-local -> no host bind-mount, keeps k3s local-storage" {
  TB_STORAGE_MODE="node-local"
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]]
  [[ "$output" != *"/tracebloc@all"* ]]                 # no ~/.tracebloc bind-mount
  [[ "$output" != *"--disable=local-storage"* ]]        # keep local-path provisioner
}

@test "_create_new_cluster: hostpath (default) -> bind-mount + disables local-storage" {
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]]
  [[ "$output" == *"--disable=local-storage"* ]]
}

@test "_ensure_release_dirs: HOST_DATASET_DIR set -> data on dataset dir, mysql+logs local" {
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"; mkdir -p "$HOST_DATASET_DIR"
  _ensure_release_dirs tracebloc
  [ -d "$HOST_DATASET_DIR/tracebloc/data" ]    # dataset on the (network) mount
  [ -d "$HOST_DATA_DIR/tracebloc/logs" ]       # logs stay local
  [ -d "$HOST_DATA_DIR/tracebloc/mysql" ]      # mysql stays local
  [ ! -d "$HOST_DATA_DIR/tracebloc/data" ]     # data NOT created on the local tree
}

@test "_ensure_release_dirs: HOST_DATASET_DIR unset -> data stays local (unchanged)" {
  _ensure_release_dirs tracebloc
  [ -d "$HOST_DATA_DIR/tracebloc/data" ]
  [ -d "$HOST_DATA_DIR/tracebloc/logs" ]
  [ -d "$HOST_DATA_DIR/tracebloc/mysql" ]
}

# ── _check_existing_cluster_bind (Gap C) ────────────────────────────────────
@test "_check_existing_cluster_bind: 0.0.0.0 bind -> warns (created outside installer)" {
  docker() { echo "0.0.0.0 0.0.0.0 "; }
  run _check_existing_cluster_bind
  [[ "$output" == *"0.0.0.0"* ]]
  [[ "$output" == *"created outside this installer"* ]]
}

@test "_check_existing_cluster_bind: 127.0.0.1 bind -> silent" {
  docker() { echo "127.0.0.1 "; }
  run _check_existing_cluster_bind
  [ -z "$output" ]
}

@test "_check_existing_cluster_bind: inspect fails -> silent no-op" {
  docker() { return 1; }
  run _check_existing_cluster_bind
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── _check_existing_cluster_proxy: drift + auth-bucket regression ────────────
@test "_check_existing_cluster_proxy: auth proxy no longer triggers an @-skip warning" {
  HTTP_PROXY="http://u:p@proxy:8080"
  docker() { echo "HTTP_PROXY=http://u:p@proxy:8080"; }   # baked into the cluster
  run _check_existing_cluster_proxy
  [[ "$output" != *"embedded credentials"* ]]
  [[ "$output" != *"can't carry an"* ]]
}

@test "_check_existing_cluster_proxy: cluster missing a host proxy var -> drift warning" {
  HTTP_PROXY="http://proxy:8080"
  docker() { echo "PATH=/usr/bin"; }                      # HTTP_PROXY not baked
  run _check_existing_cluster_proxy
  [[ "$output" == *"missing: HTTP_PROXY"* ]]
}

# ── _check_existing_cluster_ca (Bugbot #424 r4) ─────────────────────────────
@test "_check_existing_cluster_ca: no CA var set -> no-op" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE
  docker() { echo "/should-not-be-read"; }
  run _check_existing_cluster_ca
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_ca: CA set but existing cluster lacks the mount -> recreate warning" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  docker() { printf '/tracebloc\n/etc/ssl/certs/ca-certificates.crt\n'; }   # no mitm-ca mount
  run _check_existing_cluster_ca
  [[ "$output" == *"created without it"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

@test "_check_existing_cluster_ca: CA set and mount present -> no warning" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  docker() { printf '/tracebloc\n/etc/ssl/certs/tracebloc-mitm-ca.crt\n'; }
  run _check_existing_cluster_ca
  [ -z "$output" ]
}

@test "_check_existing_cluster_ca: a mount that only embeds the CA path -> still warns (Bugbot #424)" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  # substring but NOT the exact mount destination — must not be treated as our CA mount
  docker() { printf '/tracebloc\n/etc/ssl/certs/tracebloc-mitm-ca.crt.bak\n'; }
  run _check_existing_cluster_ca
  [[ "$output" == *"created without it"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

# ── _host_ca_create_hint (host Docker daemon x509 at create, #474) ───────────
@test "_host_ca_create_hint: no x509 in output -> silent" {
  run _host_ca_create_hint "FATA[0000] Failed to create cluster: docker daemon not running"
  [ -z "$output" ]
}

@test "_host_ca_create_hint: x509 on Linux -> host daemon + Debian AND RHEL paths + DD-for-Linux (#474)" {
  OS=Linux
  run _host_ca_create_hint 'FATA Failed to pull image "rancher/k3s": x509: certificate signed by unknown authority'
  [[ "$output" == *"HOST Docker daemon"* ]]
  [[ "$output" == *"update-ca-certificates"* ]]              # Debian/Ubuntu
  [[ "$output" == *"update-ca-trust"* ]]                     # RHEL/Fedora (Bugbot: not Debian-only)
  [[ "$output" == *"Docker Desktop for Linux"* ]]            # Bugbot: no dangling "Docker Desktop step"
  [[ "$output" != *"macOS keychain"* ]]
}

@test "_host_ca_create_hint: x509 on macOS -> Docker Desktop keychain AND Colima VM (#474 Bugbot)" {
  OS=Darwin
  run _host_ca_create_hint 'Error response from daemon: tls: failed to verify certificate'
  [[ "$output" == *"Docker Desktop"* ]]
  [[ "$output" == *"macOS keychain"* ]]
  [[ "$output" == *"Colima"* ]]            # headless macOS uses Colima, which ignores the keychain
  [[ "$output" != *"update-ca-certificates"* ]]
}

@test "_host_ca_create_hint: large (>64KB) x509 output under pipefail still fires (reviewer #474)" {
  # The timeout path passes the FULL create logs; with a pipe + grep -q under
  # set -o pipefail, printf would take SIGPIPE past the ~64KB buffer and the hint
  # would be silently swallowed even though x509 matched. Guard against that.
  set -o pipefail
  OS=Linux
  local big; big="$(printf 'noise line %s\n' $(seq 1 8000))"   # well over 64KB
  big+=$'\nFATA Failed to pull image "rancher/k3s": x509: certificate signed by unknown authority'
  run _host_ca_create_hint "$big"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOST Docker daemon"* ]]
}

# ── _check_existing_cluster_dataset_mount (backend#743) ─────────────────────
@test "_check_existing_cluster_dataset_mount: HOST_DATASET_DIR unset -> no-op" {
  unset HOST_DATASET_DIR
  docker() { echo "/should-not-be-read"; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_dataset_mount: /tracebloc-data mount present -> silent pass" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { printf '%s\n' /tracebloc /tracebloc-data; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_dataset_mount: mount ABSENT -> fail fast (no ephemeral datasets)" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { printf '%s\n' /tracebloc; }                  # no /tracebloc-data bind
  run _check_existing_cluster_dataset_mount
  [ "$status" -ne 0 ]
  [[ "$output" == *"no /tracebloc-data bind mount"* ]]
  [[ "$output" == *"ephemeral"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

@test "_check_existing_cluster_dataset_mount: inspect fails -> silent no-op" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { return 1; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── _check_existing_cluster_storage_mode (RFC-0003 Option C) ────────────────
@test "_check_existing_cluster_storage_mode: node-local matches node-local cluster -> silent pass" {
  TB_STORAGE_MODE=node-local
  docker() { printf '%s\n' /var/lib/rancher; }              # no /tracebloc mount
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_storage_mode: hostpath matches hostpath cluster -> silent pass" {
  TB_STORAGE_MODE=hostpath
  docker() { printf '%s\n' /tracebloc; }
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_storage_mode: node-local onto hostpath cluster -> fail fast (no local-path SC)" {
  TB_STORAGE_MODE=node-local
  docker() { printf '%s\n' /tracebloc; }                    # hostpath cluster
  run _check_existing_cluster_storage_mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"built for hostpath storage"* ]]
  [[ "$output" == *"Pending"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

@test "_check_existing_cluster_storage_mode: hostpath onto node-local cluster -> fail fast (ephemeral)" {
  TB_STORAGE_MODE=hostpath
  docker() { printf '%s\n' /var/lib/rancher; }              # node-local cluster, no /tracebloc
  run _check_existing_cluster_storage_mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"built for node-local storage"* ]]
  [[ "$output" == *"ephemeral"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

@test "_check_existing_cluster_storage_mode: inspect fails -> silent no-op" {
  TB_STORAGE_MODE=node-local
  docker() { return 1; }
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── ensure_cluster_autostart (reboot persistence) ───────────────────────────
@test "ensure_cluster_autostart: unless-stopped per node + enables docker (Linux)" {
  OS=Linux
  docker() { if [[ "$1 $2" == "ps -a" ]]; then printf '%s\n' "k3d-tracebloc-server-0" "k3d-tracebloc-serverlb"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { record "systemctl $*"; return 1; }   # not already enabled on boot
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-server-0"* ]]
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-serverlb"* ]]
  [[ "$output" == *"sudo systemctl enable docker"* ]]
}

@test "ensure_cluster_autostart: Tier 0 sets restart policy but does NOT sudo-enable docker.service (#375)" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { record "systemctl $*"; return 1; }   # docker.service not enabled on boot
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped"* ]]   # reboot policy still set (no privilege)
  [[ "$output" != *"systemctl enable docker"* ]]                  # but no sudo autostart on the zero-root path
}

# Tier 0 never runs `systemctl enable`, but a normal Docker package install
# already enables docker.service — so the reboot promise must be seeded from that
# pre-install state, not left at 0 just because THIS run didn't flip it (Bugbot:
# cross-step state flags must seed from pre-install state, not hard defaults).
@test "ensure_cluster_autostart: Tier 0 with docker.service already enabled -> honest auto-restart promise" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { [[ "$1 $2" == "is-enabled docker" ]] && { echo "enabled"; return 0; }; record "systemctl $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" = "1" ]                           # summary can honestly promise auto-restart
  run mock_calls
  [[ "$output" != *"systemctl enable docker"* ]]                  # still no privileged enable on the zero-root path
}

@test "ensure_cluster_autostart: Tier 0 with docker.service disabled -> no false auto-restart promise" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { [[ "$1 $2" == "is-enabled docker" ]] && { echo "disabled"; return 1; }; record "systemctl $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ]                          # summary tells the user to start Docker
}

# `enabled-runtime` is a transient enable that does NOT survive a reboot, so it
# must not set the auto-restart flag.
@test "ensure_cluster_autostart: docker.service 'enabled-runtime' (transient) does NOT promise auto-restart" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { [[ "$1 $2" == "is-enabled docker" ]] && { echo "enabled-runtime"; return 0; }; record "systemctl $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ]
}

@test "ensure_cluster_autostart: macOS does not enable docker.service" {
  OS=Darwin
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped"* ]]
  [[ "$output" != *"systemctl enable docker"* ]]
}

@test "ensure_cluster_autostart: TRACEBLOC_NO_AUTOSTART -> no-op" {
  OS=Linux
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  TRACEBLOC_NO_AUTOSTART=1 ensure_cluster_autostart
  run mock_calls
  [ -z "$output" ]
}

@test "ensure_cluster_autostart: no nodes -> no docker update" {
  OS=Darwin
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo ""; else record "docker $*"; fi; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" != *"docker update"* ]]
}

# ── bounded create (#426) ────────────────────────────────────────────────────
@test "k3d create is bounded: --wait always pairs with --timeout (#426)" {
  grep -q -- '--wait --timeout' "$BATS_TEST_DIRNAME/../lib/cluster.sh"
}

@test "create spin carries the backstop deadline (#426)" {
  grep -q 'spin "\$!" "Creating your secure environment…" "\$(( (_create_timeout_min + 5) \* 60 ))"' \
    "$BATS_TEST_DIRNAME/../lib/cluster.sh"
}

@test "create backstop names the timeout and removes the partial cluster (Bugbot #442)" {
  # rc 124 must produce an explicit timed-out message (the create log is often
  # empty on a hung daemon) and must not leave the half-created cluster for a
  # re-run to adopt via the "already exists" branch.
  grep -q 'timed out after \$(( _create_timeout_min + 5 )) minutes' \
    "$BATS_TEST_DIRNAME/../lib/cluster.sh"
  grep -q 'TB_CREATE_TIMEOUT_MIN raises the k3d bound' \
    "$BATS_TEST_DIRNAME/../lib/cluster.sh"
  grep -q 'k3d cluster delete "\$CLUSTER_NAME"' \
    "$BATS_TEST_DIRNAME/../lib/cluster.sh"
}

# ── In-node CA trust for TLS-inspecting networks (#424) ──────────────────────
@test "_resolve_ca_bundle: no CA var set -> empty, rc 0" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE
  run _resolve_ca_bundle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_resolve_ca_bundle: TRACEBLOC_CA_BUNDLE readable -> absolute path (#424)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 0 ]
  [[ "$output" == /*ca.pem ]]
}

@test "_resolve_ca_bundle: CURL_CA_BUNDLE is the fallback (#424)" {
  unset TRACEBLOC_CA_BUNDLE
  export CURL_CA_BUNDLE="$BATS_TEST_TMPDIR/curlca.pem"; : > "$CURL_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 0 ]
  [[ "$output" == *curlca.pem ]]
}

@test "_resolve_ca_bundle: set but unreadable -> var name + rc 2 (#424)" {
  export TRACEBLOC_CA_BUNDLE="/no/such/ca.pem"
  run _resolve_ca_bundle
  [ "$status" -eq 2 ]
  [ "$output" = "TRACEBLOC_CA_BUNDLE" ]
}

@test "_resolve_ca_bundle: a directory (readable but not a file) -> var name + rc 2 (#424 review)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca-dir"; mkdir -p "$TRACEBLOC_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 2 ]
  [ "$output" = "TRACEBLOC_CA_BUNDLE" ]
}

@test "_write_k3d_registries_config: ca_file for every registry (#424)" {
  run _write_k3d_registries_config /etc/ssl/certs/tracebloc-mitm-ca.crt
  [ "$status" -eq 0 ]
  local cfg="$output"
  grep -q 'registry-1.docker.io' "$cfg"
  grep -q 'auth.docker.io' "$cfg"      # Docker Hub token host — also TLS-handshakes (Bugbot #424)
  grep -q 'ghcr.io' "$cfg"
  [ "$(grep -c 'ca_file: "/etc/ssl/certs/tracebloc-mitm-ca.crt"' "$cfg")" -eq 4 ]
  rm -rf "${cfg%/*}"
}

@test "_write_k3d_registries_config: mktemp failure -> non-zero, no path (no fail-open; #424 Bugbot)" {
  mktemp() { return 1; }
  run _write_k3d_registries_config /etc/ssl/certs/tracebloc-mitm-ca.crt
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_create_new_cluster: CA supplied -> mounts CA + --registry-config (#424)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]]
  [[ "$output" == *":/etc/ssl/certs/tracebloc-mitm-ca.crt@all"* ]]   # CA mounted into nodes
  [[ "$output" == *"--registry-config"* ]]                           # containerd pointed at it
}

@test "_create_new_cluster: CA supplied but registries config unwritable -> hard error, never fail-open (#424 Bugbot)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  # only the registries temp dir fails; other mktemp uses delegate to the real one
  mktemp() { case "$*" in *tracebloc-k3d-reg*) return 1 ;; *) command mktemp "$@" ;; esac; }
  run _create_new_cluster
  [ "$status" -ne 0 ]
  [[ "$output" == *"registries config"* ]]
  run mock_calls
  [[ "$output" != *"k3d cluster create"* ]]   # aborted before create — never claims success
}

@test "_create_new_cluster: no CA var -> no registry-config, no mitm mount (#424)" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE
  run _create_new_cluster
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" != *"tracebloc-mitm-ca.crt"* ]]
  [[ "$output" != *"--registry-config"* ]]
}

@test "_create_new_cluster: CA var set but file missing -> hard error (#424)" {
  export TRACEBLOC_CA_BUNDLE="/no/such/ca.pem"
  run _create_new_cluster
  [ "$status" -ne 0 ]
  [[ "$output" == *"can't be read"* ]]
}

@test "CA resolve capture is errexit-safe under set -euo pipefail — reaches the guidance, not a bare exit (#424 Bugbot)" {
  # The real install runs under `set -euo pipefail`. With a bare `; ca_rc=$?` the
  # rc-2 from the command substitution would exit before the error(); `|| ca_rc=$?`
  # keeps errexit from firing so ca_rc is captured. Assert the idiom + that
  # cluster.sh actually uses it.
  run bash -euo pipefail -c '
    _resolve_ca_bundle() { echo TRACEBLOC_CA_BUNDLE; return 2; }
    ca_rc=0; ca_bundle="$(_resolve_ca_bundle)" || ca_rc=$?
    printf "rc=%s bundle=%s\n" "$ca_rc" "$ca_bundle"'
  [ "$status" -eq 0 ]                                  # no bare errexit exit
  [[ "$output" == *"rc=2"* ]]
  [[ "$output" == *"bundle=TRACEBLOC_CA_BUNDLE"* ]]
  grep -qE 'ca_bundle="\$\(_resolve_ca_bundle\)" \|\| ca_rc=' "$BATS_TEST_DIRNAME/../lib/cluster.sh"
}

# ── Tier 1 rootless: k3d on the rootless socket + autostart (RFC 0001 #1221) ──
# Shared stubs for the create_cluster wiring tests: neutralise everything
# create_cluster calls EXCEPT the DOCKER_HOST export under test.
_stub_create_cluster_deps() {
  TB_STORAGE_MODE=node-local            # skip _ensure_tracebloc_dirs (host dirs)
  _cluster_exists()          { return 1; }   # NEW-cluster path
  guard_leftover_data()      { :; }
  ensure_cluster_autostart() { :; }
  _merge_kubeconfig()        { :; }
  _export_host_no_proxy()    { :; }
  _wait_for_api()            { :; }
}

@test "create_cluster: rootless active -> DOCKER_HOST targets the rootless socket before k3d runs" {
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1; XDG_RUNTIME_DIR=/run/user/12345
  _stub_create_cluster_deps
  _create_new_cluster() { record "create_saw DOCKER_HOST=$DOCKER_HOST"; }   # what k3d/docker would see
  create_cluster
  [ "$DOCKER_HOST" = "unix:///run/user/12345/docker.sock" ]
  run mock_calls
  [[ "$output" == *"create_saw DOCKER_HOST=unix:///run/user/12345/docker.sock"* ]]
}

@test "create_cluster: rootless flag OFF -> DOCKER_HOST left untouched (legacy host daemon)" {
  INSTALL_TIER=1                        # Tier 1 host, but the opt-in flag is unset
  unset TB_TIER1_ROOTLESS DOCKER_HOST
  _stub_create_cluster_deps
  _create_new_cluster() { :; }
  create_cluster
  [ -z "${DOCKER_HOST:-}" ]
}

@test "ensure_cluster_autostart: Tier 1 rootless -> systemctl --user + linger (both OK) => honest autostart promise, NOT sudo enable" {
  OS=Linux; INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; }
  systemctl() { record "systemctl $*"; case "$*" in *"--user enable"*) return 0 ;; *) return 1 ;; esac; }  # enable OK; is-enabled not
  loginctl()  { record "loginctl $*"; return 0; }        # linger OK
  has()       { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" = "1" ]                                                  # both succeeded -> honest promise
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-server-0"* ]]  # node loop still runs
  [[ "$output" == *"systemctl --user enable docker"* ]]
  [[ "$output" == *"loginctl enable-linger"* ]]
  [[ "$output" != *"sudo systemctl enable docker"* ]]                                    # never the system unit
}

@test "ensure_cluster_autostart: Tier 1 rootless -> user-enable fails => NO false reboot promise, both still attempted (#375)" {
  OS=Linux; INSTALL_TIER=1; TB_TIER1_ROOTLESS=1; TB_DOCKER_AUTOSTART=0
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; }
  systemctl() { record "systemctl $*"; return 1; }       # --user enable FAILS
  loginctl()  { record "loginctl $*"; return 0; }
  has()       { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ]                                                 # honest: can't promise reboot-survival
  run mock_calls
  [[ "$output" == *"systemctl --user enable docker"* ]]                                  # attempted (best-effort)
  [[ "$output" == *"loginctl enable-linger"* ]]                                          # linger still attempted (not short-circuited)
  [[ "$output" != *"sudo systemctl enable docker"* ]]
}

@test "ensure_cluster_autostart: Tier 1 rootless -> system docker.service enabled does NOT seed a false promise when user-enable fails (Bugbot #478)" {
  OS=Linux; INSTALL_TIER=1; TB_TIER1_ROOTLESS=1; TB_DOCKER_AUTOSTART=0
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; }
  # System docker.service IS enabled (the seed source), but the rootless user-scope
  # enable FAILS: the rootless path must ignore the system-unit seed, so no promise.
  systemctl() { record "systemctl $*"; case "$*" in "is-enabled docker") echo enabled; return 0 ;; *) return 1 ;; esac; }
  loginctl()  { record "loginctl $*"; return 0; }
  has()       { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ]      # system-unit seed ignored on the rootless socket path
}

@test "ensure_cluster_autostart: Tier 1 flag OFF -> legacy sudo systemctl enable docker (unchanged)" {
  OS=Linux; INSTALL_TIER=1
  unset TB_TIER1_ROOTLESS
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; return 0; }
  systemctl() { record "systemctl $*"; return 1; }
  loginctl()  { record "loginctl $*"; }
  has()       { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"sudo systemctl enable docker"* ]]
  [[ "$output" != *"systemctl --user enable docker"* ]]
}

# ── _check_existing_cluster_k8s_version (#547 — k3s pin drift on reuse) ──────
@test "_check_existing_cluster_k8s_version: K8S_VERSION empty -> no-op" {
  K8S_VERSION=""
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }   # would mismatch, but pin unset
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_k8s_version: K8S_VERSION=latest -> no-op (explicit opt-out)" {
  K8S_VERSION="latest"
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_k8s_version: running k3s matches the pin -> silent pass" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "rancher/k3s:v1.29.4-k3s1"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_k8s_version: running k3s drifted from the pin -> recreate warning" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }    # the #547 observation
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [[ "$output" == *"v1.35.5-k3s1"* ]]
  [[ "$output" == *"not the validated pin"* ]]
  [[ "$output" == *"k3d cluster delete"* ]]
}

@test "_check_existing_cluster_k8s_version: registry-qualified + digest suffix still compares the tag" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "docker.io/rancher/k3s:v1.29.4-k3s1@sha256:deadbeef"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]                                  # tag matches -> no warning
}

@test "_check_existing_cluster_k8s_version: unparseable image ref -> silent no-op (no false warn)" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "some-mirror/other-image:tag"; }  # not rancher/k3s
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_check_existing_cluster_k8s_version: docker inspect fails -> silent no-op" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { return 1; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
