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

# ── ensure_cluster_autostart (reboot persistence) ───────────────────────────
@test "ensure_cluster_autostart: unless-stopped per node + enables docker (Linux)" {
  OS=Linux
  docker() { if [[ "$1 $2" == "ps -a" ]]; then printf '%s\n' "k3d-tracebloc-server-0" "k3d-tracebloc-serverlb"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
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
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped"* ]]   # reboot policy still set (no privilege)
  [[ "$output" != *"systemctl enable docker"* ]]                  # but no sudo autostart on the zero-root path
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
