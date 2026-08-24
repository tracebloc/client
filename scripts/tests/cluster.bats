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
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE SSL_CERT_FILE GIT_SSL_CAINFO

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
  # _bounded wraps probes in timeout(1), which can't exec a `docker` shell-function
  # mock — on Linux CI (where `timeout` exists) that would bypass the mock. Run the
  # command directly so mocks work everywhere; the timeout wrapper is common.sh's
  # concern, not this unit's (#565 Bugbot).
  _bounded() { shift; "$@"; }
}

# ── _augment_no_proxy (Gap B) ───────────────────────────────────────────────
@test "_augment_no_proxy: empty host NO_PROXY -> cluster-internal defaults" {
  run _augment_no_proxy
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"localhost"* ]] || return 1
  [[ "$output" == *"169.254.169.254"* ]] || return 1
  [[ "$output" == *"127.0.0.1"* ]] || return 1
  [[ "$output" == *"10.0.0.0/8"* ]] || return 1
  [[ "$output" == *".svc"* ]] || return 1
  [[ "$output" == *".cluster.local"* ]] || return 1
  [[ "$output" == *"host.k3d.internal"* ]] || return 1
}

@test "_augment_no_proxy: host entries kept first and de-duplicated" {
  NO_PROXY="foo.com,127.0.0.1"
  run _augment_no_proxy
  [[ "$output" == "foo.com,127.0.0.1,"* ]] || return 1            # host entries first
  [ "$(grep -o '127\.0\.0\.1' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ] || return 1   # deduped
}

@test "_augment_no_proxy: lowercase no_proxy is honoured" {
  no_proxy="bar.internal"
  run _augment_no_proxy
  [[ "$output" == "bar.internal,"* ]] || return 1
}

# ── _write_k3d_proxy_config (Gap A + B) ─────────────────────────────────────
@test "_write_k3d_proxy_config: no proxy set -> empty (no file)" {
  run _write_k3d_proxy_config
  [ -z "$output" ] || return 1
}

@test "_write_k3d_proxy_config: auth creds preserved (Gap A) + augmented NO_PROXY (Gap B)" {
  HTTP_PROXY="http://user:pass@proxy.example.com:8080"
  HTTPS_PROXY="http://user:pass@proxy.example.com:8080"
  NO_PROXY="corp.internal"
  run _write_k3d_proxy_config
  [ -n "$output" ] || return 1
  local cfg="$output"
  [ -f "$cfg" ] || return 1
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
  [ -f "$cfg" ] || return 1
  grep -Eq 'NO_PROXY=.*127\.0\.0\.1' "$cfg"
  rm -rf "${cfg%/*}"
}

# ── _export_host_no_proxy (Gap B, host-side) ────────────────────────────────
@test "_export_host_no_proxy: exports augmented NO_PROXY when a proxy is set" {
  HTTP_PROXY="http://proxy:8080"
  _export_host_no_proxy
  [[ "$NO_PROXY" == *"127.0.0.1"* ]] || return 1
  [[ "$no_proxy" == *".svc"* ]] || return 1
}

@test "_export_host_no_proxy: no-op when no proxy is set" {
  _export_host_no_proxy
  [ -z "${NO_PROXY:-}" ] || return 1
}

# ── _create_new_cluster: proxy propagation via --config (Gap A integration) ──
@test "_create_new_cluster: auth proxy propagated via --config, not skipped" {
  HTTP_PROXY="http://user:pass@proxy.example.com:8080"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]] || return 1
  [[ "$output" == *"--config"* ]] || return 1
  [[ "$output" != *"Skipping"* ]] || return 1                       # old @-skip path is gone
  grep -q 'user:pass@proxy.example.com' "$CFG_CAPTURE"
}

@test "_create_new_cluster: no proxy -> no --config flag" {
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]] || return 1
  [[ "$output" != *"--config"* ]] || return 1
}

# ── HOST_DATASET_DIR: second bind-mount + dataset dir split (backend#743) ────
@test "_create_new_cluster: HOST_DATASET_DIR unset -> single /tracebloc mount" {
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]] || return 1
  [[ "$output" != *"/tracebloc-data@all"* ]] || return 1
}

@test "_create_new_cluster: HOST_DATASET_DIR set -> adds a distinct /tracebloc-data mount" {
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"; mkdir -p "$HOST_DATASET_DIR"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]] || return 1                 # mysql/logs stay local
  [[ "$output" == *"${HOST_DATASET_DIR}:/tracebloc-data@all"* ]] || return 1         # datasets on the mount
}

# ── RFC-0003 Option C: node-local storage (client#367) ──────────────────────
@test "_create_new_cluster: node-local -> no host bind-mount, keeps k3s local-storage" {
  TB_STORAGE_MODE="node-local"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]] || return 1
  [[ "$output" != *"/tracebloc@all"* ]] || return 1                 # no ~/.tracebloc bind-mount
  [[ "$output" != *"--disable=local-storage"* ]] || return 1        # keep local-path provisioner
}

@test "_create_new_cluster: hostpath (default) -> bind-mount + disables local-storage" {
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"${HOST_DATA_DIR}:/tracebloc@all"* ]] || return 1
  [[ "$output" == *"--disable=local-storage"* ]] || return 1
}

# ── k3s component disablement: the EXACT set, derived ───────────────────────
#
# The two tests above are the whole of what covered `--disable=` before this
# block, and they cover one component of three. `traefik` and `servicelb` appeared
# nowhere in scripts/tests/ at all — losing either silently re-adds an inbound
# component the chart has no use for (no Ingress resources, no LoadBalancer
# Services), so nothing would ever go red.
#
# The third property runs the OTHER WAY and is load-bearing: metrics-server must
# never be disabled. client/templates/resource-monitor-daemonset.yaml `lookup`s
# the v1beta1.metrics.k8s.io APIService and `fail`s the release when it is absent,
# so a plausible-looking "footprint" optimisation that added
# `--disable=metrics-server` here would abort the install AND every subsequent
# auto-upgrade tick, which re-renders the same template.
#
# So these assert the EXACT set, not "contains". A `contains` test can only ever
# catch a REMOVED flag; the exact set also catches an ADDED one — whatever it
# names, including components nobody has proposed yet. That is what makes the
# metrics-server property hold without this suite having to enumerate every
# k3s component someone might think to switch off.
#
# The set is parsed out of the argv `_create_new_cluster` actually built, and this
# file holds no second copy of it: a hand-maintained list would agree with itself
# while disagreeing with the installer.
#
# Scope: these see one function under this file's mocks. The union across BOTH
# installers, and the chart coupling that makes metrics-server load-bearing, are
# checked by scripts/tests/k3s-components-agreement.sh in the required
# `Source-of-truth drift` job.

# The k3s components the recorded k3d argv disables: space-separated, sorted,
# deduped, node filter (`@server:*`) stripped. Derives; holds no list.
_recorded_disables() {
  local set
  set="$(mock_calls | tr ' ' '\n' \
    | sed -n 's/^--disable=\([A-Za-z0-9_-]\{1,\}\).*$/\1/p' \
    | sort -u | tr '\n' ' ')"
  printf '%s\n' "${set% }"
}

@test "_create_new_cluster: hostpath disables EXACTLY traefik + servicelb + local-storage" {
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run _recorded_disables
  # Sorted, so: local-storage servicelb traefik. A non-empty exact match is also
  # the parser's liveness proof — a stale parser would report the empty string.
  [ "$output" = "local-storage servicelb traefik" ] || return 1
}

@test "_create_new_cluster: node-local's disable set is hostpath's MINUS local-storage" {
  # Derived relationship, not a second literal: whatever hostpath disables,
  # node-local must disable exactly that with local-storage taken out and nothing
  # else moved. Keeps the two branches from drifting apart on a component neither
  # test names.
  local hostpath nodelocal expected
  _create_new_cluster
  hostpath="$(_recorded_disables)"
  # Guard the subtraction below: if hostpath ever stopped disabling local-storage,
  # `expected` would equal `hostpath` and this test would pass while comparing
  # nothing (backend#1729 — a check disconnected from what it claims to check).
  [[ " $hostpath " == *" local-storage "* ]] || return 1

  : >"$MOCK_CALLS"
  TB_STORAGE_MODE="node-local"
  _create_new_cluster
  nodelocal="$(_recorded_disables)"

  expected="$(printf '%s\n' "$hostpath" | tr ' ' '\n' | grep -vx 'local-storage' | tr '\n' ' ')"
  [ "$nodelocal" = "${expected% }" ] || return 1
}

@test "_create_new_cluster: NEVER disables metrics-server, in either storage mode" {
  local mode
  for mode in hostpath node-local; do
    : >"$MOCK_CALLS"
    TB_STORAGE_MODE="$mode"
    _create_new_cluster
    # Two independent reads. The parsed set is the primary assertion; the raw
    # substring scan does not depend on the parser recognising the flag spelling,
    # so a `--disable metrics-server` written with a space instead of '=' — which
    # the parser above would miss — still fails here instead of passing vacuously.
    [ -n "$(_recorded_disables)" ] || return 1
    [[ " $(_recorded_disables) " != *" metrics-server "* ]] || return 1
    [[ "$(mock_calls)" != *"metrics-server"* ]] || return 1
  done
}

@test "_ensure_release_dirs: HOST_DATASET_DIR set -> data on dataset dir, mysql+logs local" {
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"; mkdir -p "$HOST_DATASET_DIR"
  _ensure_release_dirs tracebloc
  [ -d "$HOST_DATASET_DIR/tracebloc/data" ] || return 1    # dataset on the (network) mount
  [ -d "$HOST_DATA_DIR/tracebloc/logs" ] || return 1       # logs stay local
  [ -d "$HOST_DATA_DIR/tracebloc/mysql" ] || return 1      # mysql stays local
  [ ! -d "$HOST_DATA_DIR/tracebloc/data" ] || return 1     # data NOT created on the local tree
}

@test "_ensure_release_dirs: HOST_DATASET_DIR unset -> data stays local (unchanged)" {
  _ensure_release_dirs tracebloc
  [ -d "$HOST_DATA_DIR/tracebloc/data" ] || return 1
  [ -d "$HOST_DATA_DIR/tracebloc/logs" ] || return 1
  [ -d "$HOST_DATA_DIR/tracebloc/mysql" ] || return 1
}

# Mode string of a path, read with POSIX `ls -ldn` (field 1) rather than GNU-only
# `stat -c`, which BSD rejects silently — the trap hostpath-prep.bats guards the
# installer against, and the same one on a developer's Mac here.
# Trimmed to the 10 mode characters: macOS appends '@' for extended attributes and
# Linux '+' for an ACL, so anything comparing the whole field fails by platform.
# Indices below are into that string: 0 type, 1-3 owner, 4-6 group (6 = setgid),
# 7-9 other (8 = other-write, 9 = sticky).
_mode_of() {
  local out
  out="$(ls -ldn "$1" 2>/dev/null)" || return 1
  out="${out%% *}"
  printf '%s\n' "${out:0:10}"
}

# setgid/sticky are not settable everywhere (macOS refuses S_ISGID on a directory
# whose group the caller isn't in; some CI filesystems drop both). The chmod in
# _ensure_release_dirs is best-effort by design, so a runner that can't hold the
# bits must skip these rather than fail an install path that is actually fine.
_require_setgid_sticky() {
  local probe="$BATS_TEST_TMPDIR/.modeprobe"
  mkdir -p "$probe"
  chmod 3777 "$probe" 2>/dev/null || skip "filesystem/user cannot set setgid+sticky here"
  local m; m="$(_mode_of "$probe")"
  [ "${m:6:1}" = "s" ] && [ "${m:9:1}" = "t" ] || skip "filesystem does not retain setgid+sticky"
}

@test "_ensure_release_dirs: data gets 2777 (setgid, NO sticky) and logs 3777 (setgid + sticky)" {
  # #673: the same path:mode split the Windows installer and the chart's
  # init-writable-data use. Sticky on data would make `data delete` impossible —
  # the ingest writes as one uid, the teardown pod removes as another (#667).
  _require_setgid_sticky
  _ensure_release_dirs tracebloc
  local data logs
  data="$(_mode_of "$HOST_DATA_DIR/tracebloc/data")"
  logs="$(_mode_of "$HOST_DATA_DIR/tracebloc/logs")"
  [ "${data:6:1}" = "s" ] || return 1     # setgid: new entries inherit the group
  [ "${data:8:1}" = "w" ] || return 1     # other-writable: the writers share no group
  [ "${data:9:1}" = "x" ] || return 1     # NOT sticky ('t' here would break `data delete`)
  [ "${logs:6:1}" = "s" ] || return 1     # setgid
  [ "${logs:8:1}" = "w" ] || return 1     # other-writable
  [ "${logs:9:1}" = "t" ] || return 1     # sticky: /tmp semantics, nothing needs to unlink
}

@test "_ensure_release_dirs: the chmod is not recursive — files under data/logs keep their mode" {
  # The dropped -R (#673). The dir's own mode governs creation and unlink inside it;
  # recursing stamped setgid/sticky onto every data FILE and walked the whole dataset
  # tree to do it. A pre-existing file proves the recursion is gone.
  mkdir -p "$HOST_DATA_DIR/tracebloc/data" "$HOST_DATA_DIR/tracebloc/logs"
  : >"$HOST_DATA_DIR/tracebloc/data/sample.bin"
  : >"$HOST_DATA_DIR/tracebloc/logs/run.log"
  chmod 600 "$HOST_DATA_DIR/tracebloc/data/sample.bin" "$HOST_DATA_DIR/tracebloc/logs/run.log"
  _ensure_release_dirs tracebloc
  [ "$(_mode_of "$HOST_DATA_DIR/tracebloc/data/sample.bin")" = "-rw-------" ] || return 1
  [ "$(_mode_of "$HOST_DATA_DIR/tracebloc/logs/run.log")" = "-rw-------" ] || return 1
}

@test "_ensure_release_dirs: mysql is left on the flat recursive 777 (#673 keeps it out of scope)" {
  # One writer (uid 999), its own init container in the chart, datadir permissions are
  # the database's business — deliberately NOT part of the shared-dir spec.
  mkdir -p "$HOST_DATA_DIR/tracebloc/mysql"
  : >"$HOST_DATA_DIR/tracebloc/mysql/ibdata1"
  chmod 600 "$HOST_DATA_DIR/tracebloc/mysql/ibdata1"
  _ensure_release_dirs tracebloc
  local d; d="$(_mode_of "$HOST_DATA_DIR/tracebloc/mysql")"
  [ "${d:8:1}" = "w" ] || return 1                                             # world-writable
  [ "${d:6:1}" != "s" ] || return 1                                            # no setgid
  [ "$(_mode_of "$HOST_DATA_DIR/tracebloc/mysql/ibdata1")" = "-rwxrwxrwx" ] || return 1  # still -R
}

@test "_ensure_release_dirs: a HOST_DATA_DIR containing a colon still splits path from mode" {
  # The pairs are split on the LAST colon. Splitting on the first would take "2777" off a
  # path like /mnt/a:b/<rel>/data and chmod a directory that isn't there — silently, since
  # both the mkdir and the chmod are best-effort.
  _require_setgid_sticky
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/od:d"
  _ensure_release_dirs tracebloc
  [ -d "$HOST_DATA_DIR/tracebloc/data" ] || return 1
  local m; m="$(_mode_of "$HOST_DATA_DIR/tracebloc/data")"
  [ "${m:6:1}" = "s" ] || return 1
  [ "${m:8:1}" = "w" ] || return 1
}

@test "_release_dirs_spec: emits path:mode pairs, data following HOST_DATASET_DIR" {
  run _release_dirs_spec tracebloc
  [ "$status" -eq 0 ] || return 1
  [ "${lines[0]}" = "$HOST_DATA_DIR/tracebloc/data:2777" ] || return 1
  [ "${lines[1]}" = "$HOST_DATA_DIR/tracebloc/logs:3777" ] || return 1
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"
  run _release_dirs_spec tracebloc
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/ds/tracebloc/data:2777" ] || return 1
  [ "${lines[1]}" = "$HOST_DATA_DIR/tracebloc/logs:3777" ] || return 1   # logs stay local
}

# ── _check_existing_cluster_bind (Gap C) ────────────────────────────────────
@test "_check_existing_cluster_bind: 0.0.0.0 bind -> warns (created outside installer)" {
  docker() { echo "0.0.0.0 0.0.0.0 "; }
  run _check_existing_cluster_bind
  [[ "$output" == *"0.0.0.0"* ]] || return 1
  [[ "$output" == *"created outside this installer"* ]] || return 1
}

@test "_check_existing_cluster_bind: 127.0.0.1 bind -> silent" {
  docker() { echo "127.0.0.1 "; }
  run _check_existing_cluster_bind
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_bind: inspect fails -> silent no-op" {
  docker() { return 1; }
  run _check_existing_cluster_bind
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# ── _check_existing_cluster_proxy: drift + auth-bucket regression ────────────
@test "_check_existing_cluster_proxy: auth proxy no longer triggers an @-skip warning" {
  HTTP_PROXY="http://u:p@proxy:8080"
  docker() { echo "HTTP_PROXY=http://u:p@proxy:8080"; }   # baked into the cluster
  run _check_existing_cluster_proxy
  [[ "$output" != *"embedded credentials"* ]] || return 1
  [[ "$output" != *"can't carry an"* ]] || return 1
}

@test "_check_existing_cluster_proxy: cluster missing a host proxy var -> drift warning" {
  HTTP_PROXY="http://proxy:8080"
  docker() { echo "PATH=/usr/bin"; }                      # HTTP_PROXY not baked
  run _check_existing_cluster_proxy
  [[ "$output" == *"missing: HTTP_PROXY"* ]] || return 1
}

# ── _check_existing_cluster_ca (Bugbot #424 r4) ─────────────────────────────
@test "_check_existing_cluster_ca: no CA var set -> no-op" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE
  docker() { echo "/should-not-be-read"; }
  run _check_existing_cluster_ca
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_ca: CA set but existing cluster lacks the mount -> recreate warning" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  docker() { printf '/tracebloc\n/etc/ssl/certs/ca-certificates.crt\n'; }   # no mitm-ca mount
  run _check_existing_cluster_ca
  [[ "$output" == *"created without it"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

@test "_check_existing_cluster_ca: CA set and mount present -> no warning" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  docker() { printf '/tracebloc\n/etc/ssl/certs/tracebloc-mitm-ca.crt\n'; }
  run _check_existing_cluster_ca
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_ca: a mount that only embeds the CA path -> still warns (Bugbot #424)" {
  export TRACEBLOC_CA_BUNDLE="/some/ca.pem"
  # substring but NOT the exact mount destination — must not be treated as our CA mount
  docker() { printf '/tracebloc\n/etc/ssl/certs/tracebloc-mitm-ca.crt.bak\n'; }
  run _check_existing_cluster_ca
  [[ "$output" == *"created without it"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

# ── _host_ca_create_hint (host Docker daemon x509 at create, #474) ───────────
@test "_host_ca_create_hint: no x509 in output -> silent" {
  run _host_ca_create_hint "FATA[0000] Failed to create cluster: docker daemon not running"
  [ -z "$output" ] || return 1
}

@test "_host_ca_create_hint: x509 on Linux -> host daemon + Debian AND RHEL paths + DD-for-Linux (#474)" {
  OS=Linux
  run _host_ca_create_hint 'FATA Failed to pull image "rancher/k3s": x509: certificate signed by unknown authority'
  [[ "$output" == *"HOST Docker daemon"* ]] || return 1
  [[ "$output" == *"update-ca-certificates"* ]] || return 1              # Debian/Ubuntu
  [[ "$output" == *"update-ca-trust"* ]] || return 1                     # RHEL/Fedora (Bugbot: not Debian-only)
  [[ "$output" == *"Docker Desktop for Linux"* ]] || return 1            # Bugbot: no dangling "Docker Desktop step"
  [[ "$output" != *"macOS keychain"* ]] || return 1
}

@test "_host_ca_create_hint: x509 on macOS -> Docker Desktop keychain AND Colima VM (#474 Bugbot)" {
  OS=Darwin
  run _host_ca_create_hint 'Error response from daemon: tls: failed to verify certificate'
  [[ "$output" == *"Docker Desktop"* ]] || return 1
  [[ "$output" == *"macOS keychain"* ]] || return 1
  [[ "$output" == *"Colima"* ]] || return 1            # headless macOS uses Colima, which ignores the keychain
  [[ "$output" != *"update-ca-certificates"* ]] || return 1
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
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"HOST Docker daemon"* ]] || return 1
}

# ── _cluster_exists under pipefail (client#682 / #680 hazard) ───────────────
# The consumers here stop at the FIRST matching line, and our own cluster is
# usually that line — so a piped k3d took SIGPIPE, pipefail made the pipeline
# 141, and inside the `if`s that read as "no such cluster". The stop-and-check
# gate then called a machine with a live cluster FRESH and offered a first-time
# install: a second, independent route to client#682.
#
# Mutation-real, but only against the WHOLE pre-fix function: reverting probe 2
# alone still passes, because probe 3's grep fallback then finds the cluster
# anyway. Verify this test by restoring all three probes to their piped form.
@test "_cluster_exists: long k3d listing with our cluster FIRST is still found (#680 hazard)" {
  set -o pipefail
  # Match on line 1, then far more than the 64KB pipe buffer behind it, so the
  # consumer closes the pipe while k3d is still writing. Position is the trigger.
  k3d() {
    printf '%s 1/1 0/0\n' "$CLUSTER_NAME"
    printf 'other-%s 1/1 0/0\n' $(seq 1 8000)
  }
  command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
  run _cluster_exists
  [ "$status" -eq 0 ] || return 1
}

@test "_cluster_exists: a genuinely absent cluster is still absent" {
  set -o pipefail
  k3d() { printf 'somethingelse 1/1 0/0\n'; }
  command() { [ "$1" = "-v" ] && [ "$2" = "jq" ] && return 1; builtin command "$@"; }
  run _cluster_exists
  [ "$status" -ne 0 ] || return 1
}

# ── _check_existing_cluster_dataset_mount (backend#743) ─────────────────────
@test "_check_existing_cluster_dataset_mount: HOST_DATASET_DIR unset -> no-op" {
  unset HOST_DATASET_DIR
  docker() { echo "/should-not-be-read"; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_dataset_mount: /tracebloc-data mount present -> silent pass" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { printf '%s\n' /tracebloc /tracebloc-data; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_dataset_mount: mount ABSENT -> fail fast (no ephemeral datasets)" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { printf '%s\n' /tracebloc; }                  # no /tracebloc-data bind
  run _check_existing_cluster_dataset_mount
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no /tracebloc-data bind mount"* ]] || return 1
  [[ "$output" == *"ephemeral"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

@test "_check_existing_cluster_dataset_mount: inspect fails -> silent no-op" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { return 1; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# ── _check_existing_cluster_storage_mode (RFC-0003 Option C) ────────────────
@test "_check_existing_cluster_storage_mode: node-local matches node-local cluster -> silent pass" {
  TB_STORAGE_MODE=node-local
  docker() { printf '%s\n' /var/lib/rancher; }              # no /tracebloc mount
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_storage_mode: hostpath matches hostpath cluster -> silent pass" {
  TB_STORAGE_MODE=hostpath
  docker() { printf '%s\n' /tracebloc; }
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_storage_mode: node-local onto hostpath cluster -> fail fast (no local-path SC)" {
  TB_STORAGE_MODE=node-local
  docker() { printf '%s\n' /tracebloc; }                    # hostpath cluster
  run _check_existing_cluster_storage_mode
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"built for hostpath storage"* ]] || return 1
  [[ "$output" == *"Pending"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

@test "_check_existing_cluster_storage_mode: hostpath onto node-local cluster -> fail fast (ephemeral)" {
  TB_STORAGE_MODE=hostpath
  docker() { printf '%s\n' /var/lib/rancher; }              # node-local cluster, no /tracebloc
  run _check_existing_cluster_storage_mode
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"built for node-local storage"* ]] || return 1
  [[ "$output" == *"ephemeral"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

@test "_check_existing_cluster_storage_mode: inspect fails -> silent no-op" {
  TB_STORAGE_MODE=node-local
  docker() { return 1; }
  run _check_existing_cluster_storage_mode
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
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
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-server-0"* ]] || return 1
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-serverlb"* ]] || return 1
  [[ "$output" == *"sudo systemctl enable docker"* ]] || return 1
}

@test "ensure_cluster_autostart: Tier 0 sets restart policy but does NOT sudo-enable docker.service (#375)" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { record "systemctl $*"; return 1; }   # docker.service not enabled on boot
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped"* ]] || return 1   # reboot policy still set (no privilege)
  [[ "$output" != *"systemctl enable docker"* ]] || return 1                  # but no sudo autostart on the zero-root path
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
  [ "${TB_DOCKER_AUTOSTART:-0}" = "1" ] || return 1                           # summary can honestly promise auto-restart
  run mock_calls
  [[ "$output" != *"systemctl enable docker"* ]] || return 1                  # still no privileged enable on the zero-root path
}

@test "ensure_cluster_autostart: Tier 0 with docker.service disabled -> no false auto-restart promise" {
  OS=Linux; INSTALL_TIER=0
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  systemctl() { [[ "$1 $2" == "is-enabled docker" ]] && { echo "disabled"; return 1; }; record "systemctl $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ] || return 1                          # summary tells the user to start Docker
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
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ] || return 1
}

@test "ensure_cluster_autostart: macOS does not enable docker.service" {
  OS=Darwin
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  has()    { return 0; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped"* ]] || return 1
  [[ "$output" != *"systemctl enable docker"* ]] || return 1
}

@test "ensure_cluster_autostart: TRACEBLOC_NO_AUTOSTART -> no-op" {
  OS=Linux
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()   { record "sudo $*"; }
  TRACEBLOC_NO_AUTOSTART=1 ensure_cluster_autostart
  run mock_calls
  [ -z "$output" ] || return 1
}

@test "ensure_cluster_autostart: no nodes -> no docker update" {
  OS=Darwin
  docker() { if [[ "$1 $2" == "ps -a" ]]; then echo ""; else record "docker $*"; fi; }
  ensure_cluster_autostart
  run mock_calls
  [[ "$output" != *"docker update"* ]] || return 1
}

# ── bounded create (#426) ────────────────────────────────────────────────────
@test "k3d create is bounded: --wait always pairs with --timeout (#426)" {
  grep -q -- '--wait --timeout' "$BATS_TEST_DIRNAME/../lib/cluster.sh"
}

@test "k3d cluster start is bounded: --timeout, so a wedged start can't hang (Bugbot)" {
  # The start output is redirected to the log; without a deadline a stuck start
  # would hang headless forever instead of reaching the curated error line.
  grep -Eq 'k3d cluster start "\$CLUSTER_NAME" .*--timeout' \
    "$BATS_TEST_DIRNAME/../lib/cluster.sh"
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
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_resolve_ca_bundle: TRACEBLOC_CA_BUNDLE readable -> absolute path (#424)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == /*ca.pem ]] || return 1
}

@test "_resolve_ca_bundle: CURL_CA_BUNDLE is the fallback (#424)" {
  unset TRACEBLOC_CA_BUNDLE
  export CURL_CA_BUNDLE="$BATS_TEST_TMPDIR/curlca.pem"; : > "$CURL_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *curlca.pem ]] || return 1
}

@test "_resolve_ca_bundle: set but unreadable -> var name + rc 2 (#424)" {
  export TRACEBLOC_CA_BUNDLE="/no/such/ca.pem"
  run _resolve_ca_bundle
  [ "$status" -eq 2 ] || return 1
  [ "$output" = "TRACEBLOC_CA_BUNDLE" ] || return 1
}

@test "_resolve_ca_bundle: a directory (readable but not a file) -> var name + rc 2 (#424 review)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca-dir"; mkdir -p "$TRACEBLOC_CA_BUNDLE"
  run _resolve_ca_bundle
  [ "$status" -eq 2 ] || return 1
  [ "$output" = "TRACEBLOC_CA_BUNDLE" ] || return 1
}

@test "_write_k3d_registries_config: ca_file for every registry (#424)" {
  run _write_k3d_registries_config /etc/ssl/certs/tracebloc-mitm-ca.crt
  [ "$status" -eq 0 ] || return 1
  local cfg="$output"
  grep -q 'registry-1.docker.io' "$cfg"
  grep -q 'auth.docker.io' "$cfg"      # Docker Hub token host — also TLS-handshakes (Bugbot #424)
  grep -q 'ghcr.io' "$cfg"
  [ "$(grep -c 'ca_file: "/etc/ssl/certs/tracebloc-mitm-ca.crt"' "$cfg")" -eq 4 ] || return 1
  rm -rf "${cfg%/*}"
}

@test "_write_k3d_registries_config: mktemp failure -> non-zero, no path (no fail-open; #424 Bugbot)" {
  mktemp() { return 1; }
  run _write_k3d_registries_config /etc/ssl/certs/tracebloc-mitm-ca.crt
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_create_new_cluster: CA supplied -> mounts CA + --registry-config (#424)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"k3d cluster create"* ]] || return 1
  [[ "$output" == *":/etc/ssl/certs/tracebloc-mitm-ca.crt@all"* ]] || return 1   # CA mounted into nodes
  [[ "$output" == *"--registry-config"* ]] || return 1                           # containerd pointed at it
}

@test "_create_new_cluster: CA supplied but registries config unwritable -> hard error, never fail-open (#424 Bugbot)" {
  export TRACEBLOC_CA_BUNDLE="$BATS_TEST_TMPDIR/ca.pem"; : > "$TRACEBLOC_CA_BUNDLE"
  # only the registries temp dir fails; other mktemp uses delegate to the real one
  mktemp() { case "$*" in *tracebloc-k3d-reg*) return 1 ;; *) command mktemp "$@" ;; esac; }
  run _create_new_cluster
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"registries config"* ]] || return 1
  run mock_calls
  [[ "$output" != *"k3d cluster create"* ]] || return 1   # aborted before create — never claims success
}

@test "_create_new_cluster: no CA var -> no registry-config, no mitm mount (#424)" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"tracebloc-mitm-ca.crt"* ]] || return 1
  [[ "$output" != *"--registry-config"* ]] || return 1
}

@test "_create_new_cluster: CA var set but file missing -> hard error (#424)" {
  export TRACEBLOC_CA_BUNDLE="/no/such/ca.pem"
  run _create_new_cluster
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"can't be read"* ]] || return 1
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
  [ "$status" -eq 0 ] || return 1                                  # no bare errexit exit
  [[ "$output" == *"rc=2"* ]] || return 1
  [[ "$output" == *"bundle=TRACEBLOC_CA_BUNDLE"* ]] || return 1
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
  # Stubbed explicitly, not just skipped by TB_STORAGE_MODE above: these tests
  # assert DOCKER_HOST wiring, and the probe shells out to docker. It happens to
  # return early in node-local mode today, so this line is belt-and-braces — but
  # it means changing the storage mode here can't silently start exercising it
  # (backend#2422).
  _verify_nodes_see_host_data() { :; }
}

@test "create_cluster: rootless active -> DOCKER_HOST targets the rootless socket before k3d runs" {
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1; XDG_RUNTIME_DIR=/run/user/12345
  _stub_create_cluster_deps
  _create_new_cluster() { record "create_saw DOCKER_HOST=$DOCKER_HOST"; }   # what k3d/docker would see
  create_cluster
  [ "$DOCKER_HOST" = "unix:///run/user/12345/docker.sock" ] || return 1
  run mock_calls
  [[ "$output" == *"create_saw DOCKER_HOST=unix:///run/user/12345/docker.sock"* ]] || return 1
}

@test "create_cluster: rootless flag OFF -> DOCKER_HOST left untouched (legacy host daemon)" {
  INSTALL_TIER=1                        # Tier 1 host, but the opt-in flag is unset
  unset TB_TIER1_ROOTLESS DOCKER_HOST
  _stub_create_cluster_deps
  _create_new_cluster() { :; }
  create_cluster
  [ -z "${DOCKER_HOST:-}" ] || return 1
}

@test "ensure_cluster_autostart: Tier 1 rootless -> systemctl --user + linger (both OK) => honest autostart promise, NOT sudo enable" {
  OS=Linux; INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; }
  systemctl() { record "systemctl $*"; case "$*" in *"--user enable"*) return 0 ;; *) return 1 ;; esac; }  # enable OK; is-enabled not
  loginctl()  { record "loginctl $*"; return 0; }        # linger OK
  has()       { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" = "1" ] || return 1                                                  # both succeeded -> honest promise
  run mock_calls
  [[ "$output" == *"docker update --restart unless-stopped k3d-tracebloc-server-0"* ]] || return 1  # node loop still runs
  [[ "$output" == *"systemctl --user enable docker"* ]] || return 1
  [[ "$output" == *"loginctl enable-linger"* ]] || return 1
  [[ "$output" != *"sudo systemctl enable docker"* ]] || return 1                                    # never the system unit
}

@test "ensure_cluster_autostart: Tier 1 rootless -> user-enable fails => NO false reboot promise, both still attempted (#375)" {
  OS=Linux; INSTALL_TIER=1; TB_TIER1_ROOTLESS=1; TB_DOCKER_AUTOSTART=0
  docker()    { if [[ "$1 $2" == "ps -a" ]]; then echo "k3d-tracebloc-server-0"; else record "docker $*"; fi; }
  sudo()      { record "sudo $*"; }
  systemctl() { record "systemctl $*"; return 1; }       # --user enable FAILS
  loginctl()  { record "loginctl $*"; return 0; }
  has()       { return 0; }
  ensure_cluster_autostart
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ] || return 1                                                 # honest: can't promise reboot-survival
  run mock_calls
  [[ "$output" == *"systemctl --user enable docker"* ]] || return 1                                  # attempted (best-effort)
  [[ "$output" == *"loginctl enable-linger"* ]] || return 1                                          # linger still attempted (not short-circuited)
  [[ "$output" != *"sudo systemctl enable docker"* ]] || return 1
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
  [ "${TB_DOCKER_AUTOSTART:-0}" != "1" ] || return 1      # system-unit seed ignored on the rootless socket path
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
  [[ "$output" == *"sudo systemctl enable docker"* ]] || return 1
  [[ "$output" != *"systemctl --user enable docker"* ]] || return 1
}

# ── _check_existing_cluster_k8s_version (#547 — k3s pin drift on reuse) ──────
@test "_check_existing_cluster_k8s_version: K8S_VERSION empty -> no-op" {
  K8S_VERSION=""
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }   # would mismatch, but pin unset
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_k8s_version: K8S_VERSION=latest -> no-op (explicit opt-out)" {
  K8S_VERSION="latest"
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_k8s_version: running k3s matches the pin -> silent pass" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "rancher/k3s:v1.29.4-k3s1"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_k8s_version: running k3s drifted from the pin -> recreate warning" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "rancher/k3s:v1.35.5-k3s1"; }    # the #547 observation
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"v1.35.5-k3s1"* ]] || return 1
  [[ "$output" == *"not the validated pin"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
}

# backend#2448: the pin move makes drift the COMMON case. Every cluster that
# predates it now warns, so the warning has to be true for THAT reader — the
# original text named only "older/unpinned installer or K8S_VERSION=latest",
# which is not what happened to them.
@test "_check_existing_cluster_k8s_version: the drift warning does not misattribute a pre-pin-move cluster" {
  local pin
  pin="$(sed -n 's/^K8S_VERSION=\(.*\)$/\1/p' "$BATS_TEST_DIRNAME/../spec/facts.env")"
  [[ -n "$pin" ]] || { echo "could not read the pin from facts.env"; return 1; }
  K8S_VERSION="$pin"
  docker() { echo "rancher/k3s:v1.29.4-k3s1"; }   # the pin BEFORE backend#2448
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  # names both versions, so the operator can see what moved
  [[ "$output" == *"v1.29.4-k3s1"* ]] || return 1
  [[ "$output" == *"$pin"* ]] || return 1
  # offers the recreate remedy
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
  # and says predating the pin is a cause, rather than blaming the operator's setup
  [[ "$output" == *"predates the current pin"* ]] \
    || { echo "warning still attributes drift only to an old installer / latest: $output"; return 1; }
}

@test "_check_existing_cluster_k8s_version: registry-qualified + digest suffix still compares the tag" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "docker.io/rancher/k3s:v1.29.4-k3s1@sha256:deadbeef"; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1                                  # tag matches -> no warning
}

@test "_check_existing_cluster_k8s_version: unparseable image ref -> silent no-op (no false warn)" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { echo "some-mirror/other-image:tag"; }  # not rancher/k3s
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_check_existing_cluster_k8s_version: docker inspect fails -> silent no-op" {
  K8S_VERSION="v1.29.4-k3s1"
  docker() { return 1; }
  run _check_existing_cluster_k8s_version
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# ── wire_ca_trust: extend the corporate CA to every host tool (#583) ─────────
@test "wire_ca_trust: exports SSL_CERT_FILE + GIT_SSL_CAINFO from a CA (#583)" {
  local ca="$BATS_TEST_TMPDIR/ca.pem"; echo pem > "$ca"
  TRACEBLOC_CA_BUNDLE="$ca"; OS="Linux"
  wire_ca_trust >/dev/null
  [ "$SSL_CERT_FILE" = "$ca" ] || return 1
  [ "$GIT_SSL_CAINFO" = "$ca" ] || return 1
}

@test "wire_ca_trust: Linux announce names cosign/helm/git (SSL_CERT_FILE effective there)" {
  local ca="$BATS_TEST_TMPDIR/ca.pem"; echo pem > "$ca"
  TRACEBLOC_CA_BUNDLE="$ca"; OS="Linux"
  run wire_ca_trust
  [[ "$output" == *"cosign, helm and git"* ]] || return 1
  [[ "$output" != *"downloads"* ]] || return 1   # curl trust is the user's CURL_CA_BUNDLE; don't over-claim
}

@test "wire_ca_trust: macOS announce names only git + hints Keychain for cosign/helm (Bugbot)" {
  # Go reads the Keychain on macOS (not SSL_CERT_FILE) and Apple's system git
  # (SecureTransport) ignores GIT_SSL_CAINFO — so on Darwin the function wires
  # NOTHING and claims nothing: it points at the Keychain for all three tools
  # (Bugbot ×2: inert-but-hazardous SSL_CERT_FILE, false git claim).
  local ca="$BATS_TEST_TMPDIR/ca.pem"; echo pem > "$ca"
  TRACEBLOC_CA_BUNDLE="$ca"; OS="Darwin"
  run wire_ca_trust
  [[ "$output" != *"Trusting"* ]] || return 1        # no success claim — nothing was wired
  [[ "$output" == *"git, cosign and helm"* ]] || return 1
  [[ "$output" == *"Keychain"* ]] || return 1
}

@test "wire_ca_trust: Darwin exports NEITHER trust var (inert for Go, hazardous for curl, Bugbot)" {
  # SSL_CERT_FILE would shrink OpenSSL-curl's download trust to the corp root
  # while helping neither cosign nor helm; GIT_SSL_CAINFO is ignored by the
  # system git that runs Homebrew's own bootstrap clone.
  local ca="$BATS_TEST_TMPDIR/ca.pem"; echo pem > "$ca"
  TRACEBLOC_CA_BUNDLE="$ca"; OS="Darwin"
  wire_ca_trust >/dev/null
  [ -z "${SSL_CERT_FILE:-}" ] || return 1
  [ -z "${GIT_SSL_CAINFO:-}" ] || return 1
}

@test "wire_ca_trust: does NOT clobber a user's CURL_CA_BUNDLE (replace-not-augment, Bugbot)" {
  local ca="$BATS_TEST_TMPDIR/corp.pem";       echo pem > "$ca"
  local full="$BATS_TEST_TMPDIR/full-bundle.pem"; echo pem > "$full"
  TRACEBLOC_CA_BUNDLE="$ca"; CURL_CA_BUNDLE="$full"; OS="Linux"
  wire_ca_trust >/dev/null
  [ "$SSL_CERT_FILE" = "$ca" ] || return 1       # cosign/helm/git get the corp CA
  [ "$CURL_CA_BUNDLE" = "$full" ] || return 1    # curl's own bundle is left intact (not overwritten)
}

@test "wire_ca_trust: does NOT clobber pre-set SSL_CERT_FILE / GIT_SSL_CAINFO (replace-not-augment, Bugbot)" {
  local ca="$BATS_TEST_TMPDIR/corp.pem";  echo pem > "$ca"
  local uf="$BATS_TEST_TMPDIR/user-full.pem"; echo pem > "$uf"
  TRACEBLOC_CA_BUNDLE="$ca"; SSL_CERT_FILE="$uf"; GIT_SSL_CAINFO="$uf"; OS="Linux"
  wire_ca_trust >/dev/null
  [ "$SSL_CERT_FILE" = "$uf" ] || return 1     # user's fuller bundles are left intact...
  [ "$GIT_SSL_CAINFO" = "$uf" ] || return 1    # ...not overwritten with the corp-root-only one
}

@test "wire_ca_trust: skipped exports are not claimed as success (Bugbot)" {
  # With both vars pre-set every export is skipped — a green "Trusting…" then
  # reports wiring that did not happen and masks a pre-set bundle that may
  # still lack the corporate CA. Say what was kept, claim nothing.
  local ca="$BATS_TEST_TMPDIR/corp.pem";  echo pem > "$ca"
  local uf="$BATS_TEST_TMPDIR/user-full.pem"; echo pem > "$uf"
  TRACEBLOC_CA_BUNDLE="$ca"; SSL_CERT_FILE="$uf"; GIT_SSL_CAINFO="$uf"; OS="Linux"
  run wire_ca_trust
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Trusting"* ]] || return 1
  [[ "$output" == *"Keeping your pre-set"* ]] || return 1
  [[ "$output" == *"make sure that bundle includes your company's CA"* ]] || return 1
}

@test "wire_ca_trust: partial pre-set claims only the wired half (Bugbot)" {
  # SSL_CERT_FILE pre-set, GIT_SSL_CAINFO free: success must name git alone,
  # and the kept half gets the check-your-bundle hint.
  local ca="$BATS_TEST_TMPDIR/corp.pem";  echo pem > "$ca"
  local uf="$BATS_TEST_TMPDIR/user-full.pem"; echo pem > "$uf"
  TRACEBLOC_CA_BUNDLE="$ca"; SSL_CERT_FILE="$uf"; OS="Linux"
  unset GIT_SSL_CAINFO
  run wire_ca_trust
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Trusting your company's certificate for git."* ]] || return 1
  [[ "$output" != *"for cosign"* ]] || return 1     # the wired claim must not cover the kept half
  [[ "$output" == *"Keeping your pre-set SSL_CERT_FILE"* ]] || return 1
}

@test "wire_ca_trust: no-op when no CA is configured (#583)" {
  unset TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE SSL_CERT_FILE GIT_SSL_CAINFO
  wire_ca_trust >/dev/null
  [ -z "${SSL_CERT_FILE:-}" ] || return 1
  [ -z "${GIT_SSL_CAINFO:-}" ] || return 1
}

@test "wire_ca_trust: hard-fails early on a set-but-unreadable bundle (#583)" {
  TRACEBLOC_CA_BUNDLE="/no/such/corporate-ca.pem"
  run wire_ca_trust
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"can't be read"* ]] || return 1
}

# ── _merge_kubeconfig: the anchor is verified, never assumed (client#732) ─────
#
# The installer passes no --kubeconfig/--context to `tracebloc client create`, so
# the secure environment is registered against kubectl's CURRENT context. The
# merge used to run under `>/dev/null 2>&1` with no `||`, so a failure left the
# previous context selected and the install carried on and anchored to it.
merge_setup() {                       # isolate HOME/KUBECONFIG from the real machine
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.kube"
  KUBECONFIG="$HOME/.kube/config"
  : >"$KUBECONFIG"
}

@test "_merge_kubeconfig: k3d merge FAILS -> hard stop, with k3d's own reason (client#732)" {
  merge_setup
  k3d() { record "k3d $*"; echo "FATA[0000] open /home/u/.kube/config: permission denied" >&2; return 1; }
  kubectl() { echo "k3d-tracebloc"; }   # a context check would PASS — the failed merge must still stop us
  run _merge_kubeconfig
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't point kubectl at the 'tracebloc' cluster"* ]] || return 1
  [[ "$output" == *"permission denied"* ]] || return 1
  [[ "$output" == *"refusing to continue against an unknown cluster"* ]] || return 1
}

@test "_merge_kubeconfig: merge timeout (rc 124) names the deadline, not a bare exit code" {
  merge_setup
  k3d() { return 124; }
  kubectl() { echo "k3d-tracebloc"; }
  run _merge_kubeconfig
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"timed out"* ]] || return 1
  [[ "$output" == *"docker ps"* ]] || return 1
}

@test "_merge_kubeconfig: a merge that fails with NO output still prints the full guidance and stops" {
  # k3d says nothing on the timeout path, and the earlier version of this branch
  # only had k3d's own words to offer — so a silent failure must still produce the
  # remedy, not just a bare symptom. Run in the real shape (`set -euo pipefail`,
  # both libs sourced) so nothing in the branch can trip errexit before the end.
  run bash -euo pipefail -c '
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/cluster.sh"
    LOG_FILE=/dev/null; CLUSTER_NAME=tracebloc
    HOME="'"$BATS_TEST_TMPDIR"'/errexit-home"; mkdir -p "$HOME/.kube"
    KUBECONFIG="$HOME/.kube/config"; : >"$KUBECONFIG"
    _bounded() { shift; "$@"; }
    k3d()     { return 1; }             # fails, prints nothing
    kubectl() { echo k3d-tracebloc; }
    _merge_kubeconfig'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Stopping here on purpose"* ]] || return 1
  [[ "$output" == *"k3d kubeconfig merge tracebloc --kubeconfig-merge-default"* ]] || return 1
  [[ "$output" == *"refusing to continue against an unknown cluster"* ]] || return 1
}

@test "_merge_kubeconfig: merge exits 0 but current-context is another cluster -> hard stop (client#732)" {
  merge_setup
  k3d() { return 0; }
  # the exact scenario in the ticket: a corporate EKS stayed selected
  kubectl() { echo "arn:aws:eks:eu-central-1:111122223333:cluster/corp-prod"; }
  run _merge_kubeconfig
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"arn:aws:eks:eu-central-1:111122223333:cluster/corp-prod"* ]] || return 1
  [[ "$output" == *"kubectl config use-context k3d-tracebloc"* ]] || return 1
  [[ "$output" == *"refusing to continue against an unknown cluster"* ]] || return 1
}

@test "_merge_kubeconfig: current-context UNREADABLE -> hard stop (can't tell is not agreement)" {
  merge_setup
  k3d() { return 0; }
  kubectl() { return 1; }
  run _merge_kubeconfig
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"can't tell us which context is current"* ]] || return 1
}

@test "_merge_kubeconfig: merge OK and context is ours -> proceeds, still normalizes 0.0.0.0" {
  merge_setup
  printf 'server: https://0.0.0.0:6550\n' >"$KUBECONFIG"
  k3d() { return 0; }
  kubectl() { echo "k3d-tracebloc"; }
  run _merge_kubeconfig
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"refusing to continue"* ]] || return 1
  grep -q 'https://127\.0\.0\.1:6550' "$KUBECONFIG"
}

@test "_merge_kubeconfig: still merges into the DEFAULT kubeconfig and switches context" {
  merge_setup
  k3d() { record "k3d $*"; return 0; }
  kubectl() { echo "k3d-tracebloc"; }
  _merge_kubeconfig >/dev/null
  run mock_calls
  [[ "$output" == *"k3d kubeconfig merge tracebloc"* ]] || return 1
  [[ "$output" == *"--kubeconfig-merge-default"* ]] || return 1
  [[ "$output" == *"--kubeconfig-switch-context"* ]] || return 1
}

# ── _recreate_cluster_hint: release the record, then the cluster (backend#2077) ──
#
# The backend record is anchored to the CLUSTER's identity (the kube-system
# namespace UID), which dies with the k3d cluster. A bare `k3d cluster delete`
# therefore strands this machine's secure environment on the dashboard for good —
# and the installer used to print exactly that, in seven places.
@test "_recreate_cluster_hint: names 'tracebloc delete' BEFORE the k3d delete (the order is the fix)" {
  run _recreate_cluster_hint
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"tracebloc delete --keep-data"* ]] || return 1
  [[ "$output" == *"k3d cluster delete tracebloc"* ]] || return 1
  # everything printed before the k3d line already carries the release step
  [[ "${output%%k3d cluster delete*}" == *"tracebloc delete --keep-data"* ]] || return 1
}

@test "_recreate_cluster_hint: never a BARE 'tracebloc delete' — the plain form wipes the data these sites keep" {
  run _recreate_cluster_hint
  [[ "$output" == *"keeps your local data"* ]] || return 1
  [ "$(grep -c 'tracebloc delete' <<<"$output")" -eq "$(grep -c 'tracebloc delete --keep-data' <<<"$output")" ] || return 1
}

@test "_recreate_cluster_hint: a machine with nothing installed is told it can skip the release" {
  run _recreate_cluster_hint
  [[ "$output" == *"nothing installed on this machine yet"* ]] || return 1
}

@test "_recreate_cluster_hint: the re-run prefix lands on the k3d line, not a line of its own" {
  run _recreate_cluster_hint "TB_STORAGE_MODE=node-local  "
  [[ "$output" == *"k3d cluster delete tracebloc  &&  TB_STORAGE_MODE=node-local  re-run this installer."* ]] || return 1
}

@test "_recreate_cluster_hint: follows CLUSTER_NAME, so a custom cluster gets a runnable command" {
  CLUSTER_NAME=myapp
  run _recreate_cluster_hint
  [[ "$output" == *"k3d cluster delete myapp"* ]] || return 1
}

# Derived from the source, not from a list kept by hand: ANY recreate hint added
# later with its own `hint "… k3d cluster delete …"` line strands a dashboard
# record exactly like the seven this replaced, and this reddens on it.
#
# Scoped to `hint` lines on purpose. The create-timeout path (a `warn` telling the
# user to remove a PARTIAL cluster) is deliberately out of scope: `k3d cluster
# create` only runs when the cluster is absent, so a cluster that never finished
# creating never had a secure environment registered against it — there is nothing
# to release, and `tracebloc delete` would refuse with "no active client".
@test "every recreate hint in cluster.sh goes through _recreate_cluster_hint (backend#2077)" {
  local offenders
  offenders="$(awk '
    /^_recreate_cluster_hint\(\)[[:space:]]*\{/ { inhelper = 1; next }
    inhelper && /^\}/                          { inhelper = 0; next }
    inhelper                                   { next }
    /^[[:space:]]*hint[[:space:]].*k3d cluster delete/ { printf "%d: %s\n", NR, $0 }
  ' "${LIB_DIR}/cluster.sh")"
  [ -z "$offenders" ] || { echo "bare recreate hints (must call _recreate_cluster_hint):"; echo "$offenders"; return 1; }
}

# Two real call sites, end to end — the helper being right buys nothing if a site
# prints something else.
@test "_check_existing_cluster_storage_mode: node-local drift keeps its TB_STORAGE_MODE re-run AND releases first" {
  TB_STORAGE_MODE=node-local
  docker() { printf '%s\n' /tracebloc; }
  run _check_existing_cluster_storage_mode
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"tracebloc delete --keep-data"* ]] || return 1
  [[ "$output" == *"TB_STORAGE_MODE=node-local  re-run this installer."* ]] || return 1
}

@test "_check_existing_cluster_dataset_mount: still fails fast, and now releases the record first" {
  HOST_DATASET_DIR=/mnt/nfs/datasets
  docker() { printf '%s\n' /tracebloc; }
  run _check_existing_cluster_dataset_mount
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no /tracebloc-data bind mount"* ]] || return 1
  [[ "${output%%k3d cluster delete*}" == *"tracebloc delete --keep-data"* ]] || return 1
}

# ── fail-cgroupv1: gated on the k3s pin (backend#2422) ──────────────────────
#
# k8s 1.35 flipped the kubelet's failCgroupV1 default to true, so from k3s 1.35
# the kubelet refuses to start on a cgroup v1/hybrid host — WSL2 (hybrid by
# default) and RHEL 8 / CentOS 7 / Ubuntu 20.04. We pass the override
# proactively, but ONLY from 1.31, because that is the release that ADDED the
# flag: handing it to a pre-1.31 kubelet is an unknown flag and the kubelet does
# not start. So the gate is not a nicety — an ungated version of this line broke
# every install while the pin was 1.29.4.
#
# The bands, since a reader will need them to interpret a failure here:
#   < 1.31   the flag does not exist        -> must NOT be emitted
#   1.31-1.34 exists, no refusal yet        -> emitting is harmless
#   >= 1.35  refusal is ON by default       -> emitting is REQUIRED
# The shipped pin is 1.36.3, i.e. the third band.

@test "fail-cgroupv1: NOT passed on a pre-1.31 k3s, which predates the flag" {
  # 1.29.4 was the pin until backend#2448 moved it to 1.36.3. Kept as the
  # below-the-band case; it is deliberately a LITERAL, because it stands for
  # "any version older than the flag" rather than for whatever we ship.
  K8S_VERSION="v1.29.4-k3s1"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"fail-cgroupv1"* ]] || return 1
}

@test "fail-cgroupv1: passed from 1.31.0, the release that added the flag" {
  K8S_VERSION="v1.31.0-k3s1"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"--kubelet-arg=fail-cgroupv1=false@all"* ]] || return 1
}

# MUTATION ANCHOR. _version_lt reads a leading "v" as a non-numeric component,
# i.e. 0 — so `_version_lt v1.36.3 1.31.0` is TRUE and the gate inverts. Drop the
# `${K8S_VERSION#v}` strip in cluster.sh and this test reddens while the two above
# still pass, which is exactly the silent failure it exists to catch: the flag
# would quietly stop being emitted on the versions that actually need it.
@test "fail-cgroupv1: passed on the 1.36 migration target (pins the leading-v strip)" {
  K8S_VERSION="v1.36.3-k3s1"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"fail-cgroupv1=false"* ]] || return 1
}

@test "fail-cgroupv1: the SHIPPED pin emits the flag — derived from facts.env, not restated" {
  # DERIVED, because every version literal in a test is a copy that keeps passing
  # after the real pin moves. This suite had exactly that: a test named "the
  # currently pinned k3s" that hardcoded 1.29.4 and sailed through the 1.36
  # migration still green, while NOTHING asserted the behaviour of the version we
  # actually ship. facts.env is the single source of truth (check-facts.sh stamps
  # it into every consumer), so read it.
  #
  # A red here means one of two things, so check which: either the gate broke, or
  # the pin moved below 1.31 — in which case not emitting is CORRECT and this test
  # is the one that needs revisiting (see the bands above).
  local pin
  pin="$(sed -n 's/^K8S_VERSION=\(.*\)$/\1/p' "$BATS_TEST_DIRNAME/../spec/facts.env")"
  # Fail closed: an unreadable spec is a finding, not a pass.
  [[ -n "$pin" ]] || { echo "could not read K8S_VERSION from scripts/spec/facts.env"; return 1; }
  K8S_VERSION="$pin"
  run _create_new_cluster
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run mock_calls
  [[ "$output" == *"--kubelet-arg=fail-cgroupv1=false@all"* ]] \
    || { echo "the shipped pin ($pin) does not emit the cgroup v1 override"; return 1; }
}

@test "fail-cgroupv1: unset K8S_VERSION does not emit the flag" {
  K8S_VERSION=""
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"fail-cgroupv1"* ]] || return 1
}

# `latest` EMITS, and it is decided rather than fallen into (#806 review). It is the
# unsupported opt-out where k3d picks the k3s version and we cannot read it, so the
# trade is a flag that is harmless from 1.31 against a refusal that is fatal from
# 1.35 -- and `latest` is the path that produced the v1.35.5 drift incident. Pinned
# k3d v5.9.0 defaults to k3s 1.32, above the flag and below the refusal.
@test "fail-cgroupv1: latest emits the flag (decided, not a parse accident)" {
  K8S_VERSION="latest"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"--kubelet-arg=fail-cgroupv1=false@all"* ]] || return 1
}

# A digest-only pin is not dotted-numeric, so it must fall to skip rather than
# throw or emit -- the bash half reads a non-numeric component as 0 (below 1.31),
# and the PowerShell half now shape-checks before casting instead of letting
# [version] throw.
# The nodefilter is load-bearing and easy to "tidy" into the wrong thing: the
# --disable= args beside it are @server:* because addon deployment is server-only,
# but AGENTS defaults to 1 and an agent runs a kubelet too. @server:* would leave
# the agent kubelet refusing to start on a cgroup v1 host -- `--wait` then fails or
# the cluster sits half-ready, which is the refusal this whole block prevents.
@test "fail-cgroupv1: scoped @all, never @server:* — agents run kubelets too" {
  K8S_VERSION="v1.36.3-k3s1"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"fail-cgroupv1=false@all"* ]] || return 1
  [[ "$output" != *"fail-cgroupv1=false@server"* ]] || return 1
}

@test "fail-cgroupv1: an unparseable pin (digest) skips rather than emitting" {
  K8S_VERSION="sha256:0123456789abcdef"
  run _create_new_cluster
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"fail-cgroupv1"* ]] || return 1
}

# ── _verify_nodes_see_host_data (backend#2422) ──────────────────────────────
#
# In hostpath mode /tracebloc is the k3d bind mount of HOST_DATA_DIR. If it is
# not in effect, DirectoryOrCreate fabricates the dirs inside the node: PVC
# Bound, pod Running, MySQL on an empty datadir, no error anywhere. The
# chart-side fix (type: Directory) is impossible on an existing release —
# spec.persistentvolumesource is immutable, so it fails the helm upgrade — so
# this probe has to catch it, and has to fail CLOSED.

# Mock the pair of docker verbs the probe uses. `ps` lists nodes; `exec … cat`
# returns whatever the fake node "sees" at /tracebloc/<marker>.
#   _mock_docker <ps-output> <mode>
#     mode=passthrough : exec returns the real marker file (mount works)
#     mode=empty       : exec returns nothing (dir exists but is not the host tree)
#     mode=stale       : exec returns a DIFFERENT token (mount points elsewhere)
#     mode=fail        : exec exits non-zero (cannot tell)
# The probe now runs ONE `docker ps` PER ROLE (`--filter label=k3d.role=<role>`)
# and asks only for `{{.Names}}`, so no argument carries a space or a quote — a hard
# requirement of the PowerShell twin's command-line joining (#817). The mock therefore
# answers based on the role filter it is handed, rather than returning "name role"
# pairs. MOCK_PS_OUT stays "<name> <role>" lines as the fixture's SOURCE OF TRUTH and
# is filtered per call, which keeps each test's intent readable.
_mock_docker() {
  # GLOBALS, not locals: the docker() body below runs long after _mock_docker has
  # returned, and bash captures no closure — locals would be unset there, docker
  # ps would print nothing, and every test would take the "cannot list nodes"
  # branch. Which is non-zero, so the REFUSAL tests would pass while exercising
  # the wrong refusal entirely. (Caught by tests 1-2 failing; hence each refusal
  # test below asserts its OWN message rather than just a non-zero status.)
  MOCK_PS_OUT="$1"; MOCK_MODE="$2"
  docker() {
    if [[ "$1" == "ps" ]]; then
      local want=""
      for a in "$@"; do case "$a" in label=k3d.role=*) want="${a#label=k3d.role=}" ;; esac; done
      # no role filter asked for -> return nothing, so a probe that forgot to scope
      # its query cannot accidentally pass
      [[ -n "$want" ]] || return 0
      printf '%s\n' "$MOCK_PS_OUT" | awk -v r="$want" '$2 == r { print $1 }'
      return 0
    fi
    if [[ "$1" == "exec" ]]; then
      case "$MOCK_MODE" in
        passthrough) cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0 ;;
        empty)       return 0 ;;
        stale)       printf 'a-token-from-some-other-run'; return 0 ;;
        fail)        return 1 ;;
      esac
    fi
    return 0
  }
}

@test "_verify_nodes_see_host_data passes when every node sees the host tree" {
  mkdir -p "$HOST_DATA_DIR"
  _mock_docker "k3d-tracebloc-server-0 server
k3d-tracebloc-agent-0 agent" passthrough
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # and it must not leave its probe file behind
  [ ! -f "$HOST_DATA_DIR/.tracebloc-mount-probe" ] || return 1
}

@test "_verify_nodes_see_host_data REFUSES when the node cannot see the host tree" {
  mkdir -p "$HOST_DATA_DIR"
  _mock_docker "k3d-tracebloc-server-0 server" empty
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "accepted an invisible data dir"; return 1; }
  [[ "$output" == *"cannot see your data directory"* ]] || return 1
  # the remedy has to name Docker Desktop file sharing — the likeliest cause on
  # the Mac/Windows laptops this guard exists for
  [[ "$output" == *"File sharing"* ]] || return 1
  [ ! -f "$HOST_DATA_DIR/.tracebloc-mount-probe" ] || return 1
}

@test "_verify_nodes_see_host_data compares the token, not just the file's presence" {
  mkdir -p "$HOST_DATA_DIR"
  # A mount pointed at the WRONG host directory can still surface a file of the
  # same name from an earlier run. Presence alone would pass this; content fails.
  _mock_docker "k3d-tracebloc-server-0 server" stale
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "a stale marker from another tree was accepted"; return 1; }
  # the SPECIFIC refusal: "cannot see your data directory", not the node-listing
  # one. A bare non-zero check here passed even when the mock was broken.
  [[ "$output" == *"cannot see your data directory"* ]] || { echo "wrong refusal: $output"; return 1; }
}

@test "_verify_nodes_see_host_data fails closed when a node cannot be exec'd" {
  mkdir -p "$HOST_DATA_DIR"
  _mock_docker "k3d-tracebloc-server-0 server" fail
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "an unverifiable node was treated as a pass"; return 1; }
  [[ "$output" == *"cannot see your data directory"* ]] || { echo "wrong refusal: $output"; return 1; }
}

@test "_verify_nodes_see_host_data fails closed when no nodes can be listed" {
  mkdir -p "$HOST_DATA_DIR"
  _mock_docker "" fail
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "an empty node list was treated as a pass"; return 1; }
  [[ "$output" == *"Couldn't list the nodes"* ]] || return 1
}

@test "_verify_nodes_see_host_data fails closed when ONE role's query errors (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # The probe now runs one query per role, so a per-role FAILURE is its own case and
  # its own fail-closed decision. Here `server` answers fine and `agent` errors: we
  # cannot tell whether there are agents we should be probing, so refusing is the
  # only safe answer — passing would silently check half the cluster.
  #
  # An EMPTY agent list is different and legitimate (AGENTS=0), which is why the
  # branch keys on the exit status and not on emptiness. Without this test that
  # distinction is invisible: the empty-list case reaches the same final error, so a
  # fail-OPEN mutation of the per-role branch stays green (measured).
  #
  # BUT NOTE WHAT THIS TEST CANNOT SEE, because the earlier note here claimed more
  # than it proved (@saadqbal on #817): `run` captures the status, which SUPPRESSES
  # `set -e`. Production calls this function BARE under `set -euo pipefail`, so a
  # bare `out=$(docker ps …)` aborts at the assignment and this whole branch becomes
  # dead code — and this test stays green throughout, measured against that exact
  # shape. The reachability axis is covered by the "PRODUCTION call shape" test
  # below; this one only covers the branch's LOGIC once reached.
  docker() {
    if [[ "$1" == "ps" ]]; then
      case "$*" in
        *label=k3d.role=server*) echo k3d-tracebloc-server-0; return 0 ;;
        *label=k3d.role=agent*)  return 1 ;;                 # cannot tell
      esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "an unlistable role was treated as 'no nodes of that role'"; return 1; }
  [[ "$output" == *"Couldn't list the nodes"* ]] || { echo "wrong refusal: $output"; return 1; }
}

@test "_verify_nodes_see_host_data refuses under set -e too — the PRODUCTION call shape (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # `run` CANNOT SEE THIS CLASS OF BUG, which is why it needs its own test.
  #
  # install-k8s.sh runs under `set -euo pipefail`, and shell options are global to
  # the sourcing shell. A bare `out=$(docker ps …)` is a simple command whose status
  # is the substitution's, so when docker errors set -e exits AT THE ASSIGNMENT and
  # every line below — the fail-closed branch, the `rm -f` of the marker — is dead.
  # Production calls this bare (create_cluster -> install-k8s.sh:272), but `run`
  # captures the status, which SUPPRESSES set -e and lets the branch execute. So the
  # per-role tests above pass either way, and did while the branch was unreachable
  # (@saadqbal on #817).
  #
  # Reproduce production instead: a subshell that sets the same options and calls the
  # function BARE. The outer `|| st=$?` is on the substitution, not inside it.
  docker() {
    if [[ "$1" == "ps" ]]; then
      case "$*" in
        *label=k3d.role=server*) echo k3d-tracebloc-server-0; return 0 ;;
        *label=k3d.role=agent*)  return 1 ;;                 # cannot tell
      esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  local out st=0
  out=$( set -euo pipefail; _verify_nodes_see_host_data 2>&1 ) || st=$?

  [ "$st" -ne 0 ] || { echo "did not refuse under set -e"; return 1; }
  # THE assertion: the curated refusal must actually be reached. Without `|| st=$?`
  # on the inner assignment this is empty — set -e aborted before the message, and
  # the operator gets only the ERR trap's generic "docker ps" record.
  [[ "$out" == *"Couldn't list the nodes"* ]] \
    || { echo "fail-closed branch unreachable under set -e; got: '$out'"; return 1; }
  # ...and the cleanup below it must have run, or the probe marker is left in the
  # operator's data dir.
  [ ! -f "$HOST_DATA_DIR/.tracebloc-mount-probe" ] \
    || { echo "probe marker left behind — the rm -f was skipped"; return 1; }
}

@test "_verify_nodes_see_host_data completes the SUCCESS path under set -e too (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # The companion to the refusal case: a `set -e` abort on the HAPPY path would fail
  # every install rather than just skipping a guard, so the absence of that class is
  # worth pinning and not only the one instance that was found. Checked at the time:
  # the `printf … || error`, the `$( … || true )` exec capture, the
  # `[[ -n "$out" ]] && nodes+=…` append (an AND-list failure does NOT trip set -e)
  # and the `rm -f … || true` are all safe; only the per-role assignment was not.
  docker() {
    if [[ "$1" == "ps" ]]; then
      case "$*" in
        *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;;
        *label=k3d.role=agent*)  echo k3d-tracebloc-agent-0 ;;
      esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  local out st=0
  out=$( set -euo pipefail; _verify_nodes_see_host_data 2>&1 ) || st=$?
  [ "$st" -eq 0 ] || { echo "the success path ABORTED under set -e (st=$st): '$out'"; return 1; }
  [ ! -f "$HOST_DATA_DIR/.tracebloc-mount-probe" ] || { echo "marker left behind"; return 1; }
}

@test "_verify_nodes_see_host_data node-local skip is safe under set -e (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # The early return is `[[ … ]] && return 0`, whose AND-list failure in hostpath
  # mode must not trip set -e either — an abort here would break every hostpath
  # install before the probe even started.
  TB_STORAGE_MODE=node-local
  local out st=0
  out=$( set -euo pipefail; _verify_nodes_see_host_data 2>&1 ) || st=$?
  [ "$st" -eq 0 ] || { echo "node-local skip ABORTED under set -e: '$out'"; return 1; }
}

@test "_verify_nodes_see_host_data accepts an EMPTY agent list (AGENTS=0 is legitimate) (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # The other side of the same coin: a single-node cluster genuinely has no agent,
  # and that must not be mistaken for a failure. Pins the branch to exit status
  # rather than emptiness, from the opposite direction.
  docker() {
    if [[ "$1" == "ps" ]]; then
      case "$*" in *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;; esac
      return 0                                               # agent: empty, exit 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "a single-node cluster was refused: $output"; return 1; }
}

@test "_verify_nodes_see_host_data checks EVERY node, not just the server" {
  mkdir -p "$HOST_DATA_DIR"
  # AGENTS defaults to 1 and agents run kubelets, so a training pod can land on
  # an agent. A server-only probe would pass while the pod's node is blind —
  # the same @all-vs-@server trap as the cgroup v1 flag (client#806).
  docker() {
    if [[ "$1" == "ps" ]]; then
      case "$*" in *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;;
                   *label=k3d.role=agent*)  echo k3d-tracebloc-agent-0 ;; esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then
      [[ "$2" == *server-0 ]] && { cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; }
      return 0   # the AGENT is blind
    fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -ne 0 ] || { echo "only the server was checked"; return 1; }
  [[ "$output" == *"agent-0"* ]] || { echo "did not name the blind node: $output"; return 1; }
}

@test "_verify_nodes_see_host_data ignores the k3d load balancer" {
  mkdir -p "$HOST_DATA_DIR"
  # k3d-<cluster>-serverlb is a proxy container, not a kubelet — no bind mount is
  # requested for it and none is needed. Including it would make every hostpath
  # install fail on a container that never touches the data.
  docker() {
    if [[ "$1" == "ps" ]]; then
      # docker HONOURS the role filter, so a `loadbalancer` container is never
      # returned for role=server or role=agent — the lb is excluded by construction
      # rather than by a name-suffix exclusion.
      case "$*" in *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;; esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then
      [[ "$2" == *serverlb ]] && return 1        # lb genuinely has no /tracebloc
      cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0
    fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "the load balancer was probed: $output"; return 1; }
}

@test "_verify_nodes_see_host_data is skipped in node-local mode (no bind mount by design)" {
  mkdir -p "$HOST_DATA_DIR"
  TB_STORAGE_MODE=node-local
  # node-local (RFC-0003 Option C) deliberately has NO host mount — data lives on
  # k3s local-path inside the node. Probing there would fail every install.
  _mock_docker "k3d-tracebloc-server-0 server" empty
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "_verify_nodes_see_host_data selects nodes by k3d LABEL, never by name substring (#817 review)" {
  mkdir -p "$HOST_DATA_DIR"
  # `name=k3d-<cluster>-` is an unanchored SUBSTRING match, so it also lists a
  # same-prefixed sibling cluster's nodes (k3d-tracebloc-dev-server-0). If that
  # sibling was created against a different HOST_DATA_DIR it cannot see this
  # token, and the probe refuses THIS install while naming a node that is not
  # ours — a FALSE REFUSAL, the one failure mode a fail-closed guard most has to
  # avoid (@saqlainsyed007). The exact-match label filter closes it.
  #
  # The mock ignores --filter (it cannot implement docker's matching), so the
  # assertion is on the ARGUMENTS: an exact k3d.cluster label, and no name filter.
  # Recorded to a FILE, not a variable: `nodes=$(docker ps …)` runs the mock in a
  # command-substitution SUBSHELL, so an assignment there never reaches the parent.
  local argfile="$BATS_TEST_TMPDIR/psargs"; : > "$argfile"
  docker() {
    if [[ "$1" == "ps" ]]; then
      printf '%s\n' "$*" >> "$argfile"
      # what docker WOULD return for the label filters: only our own cluster's server
      case "$*" in *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;; esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  _verify_nodes_see_host_data || { echo "probe failed unexpectedly"; return 1; }
  local seen_args; seen_args="$(cat "$argfile")"
  [[ -n "$seen_args" ]] || { echo "docker ps was never called"; return 1; }
  [[ "$seen_args" == *"label=k3d.cluster=tracebloc"* ]] \
    || { echo "not selecting on the exact cluster label: $seen_args"; return 1; }
  [[ "$seen_args" != *"name=k3d-"* ]] \
    || { echo "still using the substring name filter: $seen_args"; return 1; }
  # and the role must come from k3d's label, not from a name suffix
  [[ "$seen_args" == *'k3d.role'* ]] \
    || { echo "role not read from the label: $seen_args"; return 1; }
  # NO ARGUMENT MAY CARRY A SPACE OR A QUOTE. Bash tolerates both, but the twin's
  # command-line joining does not: it quotes a whitespace-bearing value without
  # escaping inner quotes, and the resulting --format arrives with its quotes eaten
  # (#817). Keeping the shapes identical is what keeps them diffable, so assert the
  # constraint on BOTH halves rather than only where it bites.
  grep -q '"' "$argfile" && { echo "an argument carries a quote: $seen_args"; return 1; }
  grep -qE '\{\{[^}]* ' "$argfile" && { echo "a --format argument carries a space: $seen_args"; return 1; }
  # both roles must be queried, or an agent could go unprobed
  grep -q 'label=k3d.role=server' "$argfile" || { echo "server role never queried"; return 1; }
  grep -q 'label=k3d.role=agent'  "$argfile" || { echo "agent role never queried"; return 1; }
}

@test "_verify_nodes_see_host_data does not exec a sibling cluster's node (#817 review)" {
  mkdir -p "$HOST_DATA_DIR"
  # End-to-end version of the above: docker HONOURS the label filter here, so a
  # sibling cluster's blind node is simply never returned and the probe passes.
  # Under the old name-substring filter it would have been listed and refused.
  docker() {
    if [[ "$1" == "ps" ]]; then
      if [[ "$*" != *"label=k3d.role=server"* ]]; then return 0; fi
      if [[ "$*" == *"label=k3d.cluster=tracebloc"* ]]; then
        echo k3d-tracebloc-server-0                        # ours only
      else
        printf 'k3d-tracebloc-server-0\nk3d-tracebloc-dev-server-0\n'
      fi
      return 0
    fi
    if [[ "$1" == "exec" ]]; then
      [[ "$2" == *-dev-* ]] && return 0                     # the sibling is blind
      cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0
    fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "refused because of a sibling cluster: $output"; return 1; }
}

@test "_verify_nodes_see_host_data discards docker stderr, so chatter cannot forge a miss (#817)" {
  mkdir -p "$HOST_DATA_DIR"
  # The PowerShell twin had a real bug here: its bounded helper concatenates
  # stdout+stderr, and because the marker is written with no trailing newline a
  # docker warning glued onto the token INSIDE the same line and produced a FALSE
  # REFUSAL (#817).
  #
  # Bash is protected by `$( )` SEMANTICS, not by the `2>/dev/null` — command
  # substitution captures stdout only, so the redirect just keeps the terminal
  # quiet. Worth stating precisely, because the first version of this test claimed
  # to guard the redirect and was VACUOUS: removing `2>/dev/null` changes nothing
  # capturable and the test stayed green.
  #
  # What it does catch is the regression that can actually break this side —
  # someone "helpfully" adding `2>&1` to capture diagnostics into the variable.
  # Mutation-checked: with `2>&1` this test fails with the exact false refusal.
  docker() {
    echo "WARNING: docker chatter on stderr" >&2
    if [[ "$1" == "ps" ]]; then
      case "$*" in *label=k3d.role=server*) echo k3d-tracebloc-server-0 ;; esac
      return 0
    fi
    if [[ "$1" == "exec" ]]; then cat "${HOST_DATA_DIR}/.tracebloc-mount-probe" 2>/dev/null; return 0; fi
    return 0
  }
  run _verify_nodes_see_host_data
  [ "$status" -eq 0 ] || { echo "stderr chatter caused a false refusal: $output"; return 1; }
}

@test "_verify_nodes_see_host_data bounds both docker calls (#817 Bugbot)" {
  mkdir -p "$HOST_DATA_DIR"
  # A WEDGED (not stopped) daemon never returns from a bare `docker`, which would
  # freeze a headless install here with no further output — the exact failure this
  # guard exists to replace with a clear refusal. Assert the calls route through
  # _bounded, which is the house pattern (_docker_answers does the same).
  # Counted in a FILE: the probe's docker calls run in command-substitution
  # subshells, so an incremented variable never reaches the parent.
  local tally="$BATS_TEST_TMPDIR/bounded"; : > "$tally"
  _bounded() { echo "$1" >> "$tally"; shift; "$@"; }
  _mock_docker "k3d-tracebloc-server-0 server" passthrough
  _verify_nodes_see_host_data || { echo "probe failed unexpectedly"; return 1; }
  local n; n="$(wc -l < "$tally" | tr -d ' ')"
  # one for `docker ps`, one for the single node's `docker exec`
  [ "$n" -ge 2 ] || { echo "expected >=2 bounded docker calls, saw $n"; return 1; }
  # and with a real timeout, not an empty/zero one that never fires
  grep -qE '^[1-9][0-9]*$' "$tally" || { echo "bounded with a non-positive timeout: $(cat "$tally")"; return 1; }
}

@test "the mount probe exists in BOTH installers, and both are wired in (backend#2422)" {
  # Five twin divergences were found one at a time across backend#2220, one of
  # which had silently disabled machine sizing on Windows with nothing failing.
  # A guard that exists in only one language leaves the other half of the fleet
  # with the silent-empty-datadir mode — and Windows/Docker Desktop is where the
  # unshared-path cause is MOST likely. Assert presence and wiring, in both.
  local sh="$BATS_TEST_DIRNAME/../lib/cluster.sh"
  local ps1="$BATS_TEST_DIRNAME/../install-k8s.ps1"

  grep -q '^_verify_nodes_see_host_data()' "$sh" || return 1
  grep -q '^function Assert-NodesSeeHostData' "$ps1" || return 1

  # Defined but never CALLED is the failure mode this pair regresses into, and the
  # first version of this check could not see it. It counted MENTIONS with
  # `grep -c … -ge 2`, and comments naming the function keep the count up: measured
  # on install-k8s.ps1, deleting the real call left THREE mentions (the definition
  # plus two comments), so the guard stayed green with the wiring gone — vacuous on
  # exactly the regression it names (@saadqbal / Bugbot on #817).
  #
  # The bash half was sound only by luck — two occurrences, so removing the call
  # took it to one — and would have become vacuous the moment anyone wrote a comment
  # naming the function, which is precisely what happened on the ps1 side. So a
  # threshold bump would be papering over it: the count has to be of CALL SITES.
  #
  # Strip comment lines before counting, the technique
  # scripts/tests/k3s-components-agreement.sh already uses (which is why naming
  # TB_STORAGE_MODE in a comment does not trip it), then subtract the definition.
  local sh_calls ps_calls
  sh_calls=$(grep -v '^[[:space:]]*#' "$sh"  | grep -c '_verify_nodes_see_host_data')
  ps_calls=$(grep -v '^[[:space:]]*#' "$ps1" | grep -c 'Assert-NodesSeeHostData')
  # one of each match is the definition itself; anything above that is a call site
  (( sh_calls >= 2 )) || { echo "bash: defined but never called (code mentions: $sh_calls)"; return 1; }
  (( ps_calls >= 2 )) || { echo "ps1: defined but never called (code mentions: $ps_calls)"; return 1; }
}

@test "the README's recreate instructions carry the same release-first step as _recreate_cluster_hint (#819)" {
  # This PR forces a cluster REBUILD on the whole installed base (k3s's version is
  # fixed at create time), so the README's recreate instructions are suddenly the
  # most-followed path in the repo. The first draft of that note said only
  # `k3d cluster delete` — and both installers explicitly warn that deleting the
  # cluster first "strands it on your dashboard for good", because the secure
  # environment is anchored to the cluster's identity. Following the README would
  # have stranded the backend record for every customer this pin bump rebuilds
  # (Bugbot on #819).
  #
  # DERIVED from _recreate_cluster_hint rather than restated: pull the command lines
  # the installer actually prints and require the README to carry them. A guard that
  # hardcoded "tracebloc delete --keep-data" would agree with itself while the hint
  # moved on.
  local sh="$BATS_TEST_DIRNAME/../lib/cluster.sh"
  local readme="$BATS_TEST_DIRNAME/../../README.md"

  # the release command, exactly as the hint spells it (strip the hint wrapper and
  # the trailing parenthetical gloss)
  local release
  release=$(sed -n 's/^ *hint "  \(tracebloc delete [^ ]*\).*/\1/p' "$sh" | head -1)
  [[ -n "$release" ]] || { echo "could not read the release command out of _recreate_cluster_hint"; return 1; }

  grep -qF -- "$release" "$readme" \
    || { echo "README's recreate guidance omits the release step the installer prints: '$release'"; return 1; }

  # ...and it must come BEFORE the k3d delete, which is the whole point: the
  # ordering is what protects the dashboard record.
  local rel_line k3d_line
  rel_line=$(grep -nF -- "$release" "$readme" | head -1 | cut -d: -f1)
  k3d_line=$(grep -n 'k3d cluster delete' "$readme" | head -1 | cut -d: -f1)
  [[ -n "$k3d_line" ]] || { echo "README never mentions the k3d delete"; return 1; }
  (( rel_line < k3d_line )) \
    || { echo "README puts the k3d delete (line $k3d_line) before the release (line $rel_line)"; return 1; }
}
