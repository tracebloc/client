#!/usr/bin/env bash
# =============================================================================
#  cluster.sh — the substrate-neutral cluster helpers: host data dirs, the
#  proxy and CA trust inputs, the kubelet reservation and the leftover-data
#  guard. The k3d code that reads them lives in k3d.sh (RFC-0175 D15).
# =============================================================================

# Ensure host dirs exist so /tracebloc/data, /tracebloc/logs, /tracebloc/mysql exist inside nodes (HOST_DATA_DIR is mounted as /tracebloc).
# Only chmod the container data subdirs; do not make HOST_DATA_DIR or files like values.yaml world-readable.
_ensure_tracebloc_dirs() {
  mkdir -p "$HOST_DATA_DIR" "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql"
  chmod -R 777 "$HOST_DATA_DIR/logs" "$HOST_DATA_DIR/mysql" 2>/dev/null || true
  # backend#743: the dataset dir goes under HOST_DATASET_DIR (a network mount,
  # bind-mounted at /tracebloc-data) when set, else stays local under HOST_DATA_DIR.
  local data_base="${HOST_DATASET_DIR:-$HOST_DATA_DIR}"
  mkdir -p "$data_base/data"
  chmod -R 777 "$data_base/data" 2>/dev/null || true
}

# Modes the two SHARED hostPath dirs must end up with. Named constants because the
# same pair is spelled out in two other places — the Windows installer's
# $TB_SHARED_DIR_MODE/$TB_LOGS_DIR_MODE (scripts/install-k8s.ps1) and the chart's
# init-writable-data (client/templates/jobs-manager-deployment.yaml) — and the three
# have to be diffable by eye rather than drifting (#667, #673).
#
# Both get setgid (2) so new entries inherit the group. They differ in the sticky bit,
# deliberately:
#   data -> 2777  setgid + world-write, NO sticky. Sticky permits an unlink only by the
#                 entry's owner, the dir's owner, or root; `data delete` removes a tree
#                 the INGEST wrote (uid 65534) from a pod running as 65532, so sticky
#                 here makes the delete impossible — table dropped, files stranded (#667).
#   logs -> 3777  setgid + sticky. Nothing has to delete another writer's logs, so the
#                 /tmp-style protection costs nothing there.
TB_SHARED_DIR_MODE="2777"
TB_LOGS_DIR_MODE="3777"

# Echo the path:mode pairs this release needs, one per line — the same shape the Windows
# installer's Get-ReleaseDirsSpec and the chart's init-writable-data use, so the parity
# test can diff all three without re-deriving the layout (#673).
#
# backend#743: the dataset dir goes under HOST_DATASET_DIR (network mount) when set, else
# stays local. logs (and mysql, below) always stay on the local HOST_DATA_DIR.
_release_dirs_spec() {
  local release="$1"
  local base="$HOST_DATA_DIR/$release"
  local data_base="${HOST_DATASET_DIR:+$HOST_DATASET_DIR/$release}"
  data_base="${data_base:-$base}"
  printf '%s\n' "$data_base/data:$TB_SHARED_DIR_MODE" "$base/logs:$TB_LOGS_DIR_MODE"
}

# Pre-create the per-release host dirs the chart's hostPath PVs bind to.
# The PVs use /tracebloc/<release>/{data,logs,mysql}, which maps back to
# $HOST_DATA_DIR/<release>/{data,logs,mysql} on the host via the k3d -v mount.
# Without pre-creating these as the host user, kubelet's DirectoryOrCreate
# makes them root:root 0755 and the host user can't drop training data into
# /data/shared.
_ensure_release_dirs() {
  local release="$1"
  [[ -z "$release" ]] && return 0
  local base="$HOST_DATA_DIR/$release"
  # mysql is deliberately left on the flat recursive 777 this function has always used:
  # it has ONE writer (uid 999) and its own init container in the chart, and its datadir
  # permissions are the database's business — the same reason it is out of scope for the
  # Windows prep and for init-writable-data (#654, #673).
  mkdir -p "$base/mysql"
  chmod -R 777 "$base/mysql" 2>/dev/null || true
  local entry dir mode
  while IFS= read -r entry; do
    # Split on the LAST colon at both ends (%:* / ##*:), never the first: HOST_DATA_DIR is
    # a host path the operator chose and may legally contain a colon, while the mode never can.
    dir="${entry%:*}"; mode="${entry##*:}"
    mkdir -p "$dir"
    # No -R. The directory's own mode is what governs creation and unlink inside it;
    # recursing would stamp setgid/sticky onto every data FILE below, and on a dataset
    # tree it is a full walk for nothing. Best-effort, as before: a bind mount that
    # cannot represent POSIX modes must not abort the install (on Linux the chart's
    # init-writable-data fixes the same dirs again at pod start).
    chmod "$mode" "$dir" 2>/dev/null || true
  done < <(_release_dirs_spec "$release")
}

# --- Corporate-proxy support (authenticated proxies + NO_PROXY hardening) ----
# Cluster-internal destinations that must NEVER be routed through a corporate
# proxy: loopback, all RFC1918 private ranges (covers the k3s pod CIDR
# 10.42.0.0/16, the service CIDR 10.43.0.0/16, the k3d docker network and node
# IPs in one shot), and the in-cluster DNS suffixes. Sending this traffic out to
# the proxy misroutes in-cluster calls AND makes `k3d cluster create --wait`
# hang. We union these into whatever NO_PROXY the host set. (A tenant that needs
# a *proxied* private-IP destination can narrow this; tracebloc itself only
# pulls from public registries + dials public api.tracebloc.io, so the broad
# bypass is safe for the isolated VM the client runs on.)
TB_NO_PROXY_DEFAULTS="localhost,127.0.0.1,0.0.0.0,169.254.169.254,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local,host.k3d.internal"

# Echo an effective NO_PROXY = host NO_PROXY/no_proxy ∪ TB_NO_PROXY_DEFAULTS,
# de-duplicated with first-seen order preserved (host entries first).
_augment_no_proxy() {
  local existing="${NO_PROXY:-${no_proxy:-}}"
  printf '%s,%s' "$existing" "$TB_NO_PROXY_DEFAULTS" \
    | awk -v RS=',' '{ gsub(/[ \t\r\n]/, ""); if ($0 != "" && !seen[$0]++) printf "%s%s", (n++ ? "," : ""), $0 }'
}

# The proxy environment a cluster node runs with, one NAME=VALUE per line: each
# HTTP(S) proxy variable the host sets, in this order, then NO_PROXY and no_proxy,
# both set to the augmented list above. NOTHING when the host sets no HTTP(S)
# proxy: a NO_PROXY alone proxies nothing. ONE definition for both substrates:
# k3d.sh writes these into the k3d --config env list, and k3s.sh hands them to
# upstream's install.sh, which writes them into k3s.service.env.
_node_proxy_env() {
  local var have_http="" no_proxy_val
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ -n "${!var:-}" ]] && have_http=1
  done
  [[ -z "$have_http" ]] && return 0
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ -z "${!var:-}" ]] && continue
    printf '%s=%s\n' "$var" "${!var}"
  done
  no_proxy_val="$(_augment_no_proxy)"
  printf 'NO_PROXY=%s\nno_proxy=%s\n' "$no_proxy_val" "$no_proxy_val"
}

# --- Corporate MITM CA trust for in-node containerd pulls (#424) --------------
# Proxy REACHABILITY reaches the nodes (above), but on a TLS-inspecting network
# the nodes still don't TRUST the corporate CA, so every in-node containerd pull
# (rancher/k3s, ghcr.io/k3d-io, tracebloc images) fails x509 — then masked into a
# root-cause-free "an image couldn't be pulled". When the operator supplies the
# CA bundle we mount it into every node and point containerd at it per-registry.

# The registries the cluster pulls from; behind a break-and-inspect proxy each
# needs the corporate CA to validate the intercepted cert.
TB_CA_REGISTRIES=(docker.io registry-1.docker.io auth.docker.io ghcr.io)

# Print a containerd registries.yaml that points every registry in TB_CA_REGISTRIES
# at the CA file $1 -- the path containerd reads it from, which is inside the node
# on k3d and on the host on native k3s. Pure: the writers (k3d.sh's
# _write_k3d_registries_config, k3s.sh's _native_k3s_write_config) own where it lands.
_render_registries_config() {
  local node_ca="$1" host
  echo "configs:"
  for host in "${TB_CA_REGISTRIES[@]}"; do  # set-u-safe: TB_CA_REGISTRIES is a file-scope constant
    printf '  "%s":\n    tls:\n      ca_file: "%s"\n' "$host" "$node_ca"
  done
}

# Echo the operator's CA bundle path (absolute) when TRACEBLOC_CA_BUNDLE or
# CURL_CA_BUNDLE is set and readable. If a var is set but the file is unreadable,
# echo the offending var NAME and return 2 — the caller turns that into a hard
# error (a silent skip would drop them straight back into the x509 failure they
# set the var to fix). Empty stdout + return 0 when no CA var is set.
_resolve_ca_bundle() {
  local var val
  for var in TRACEBLOC_CA_BUNDLE CURL_CA_BUNDLE; do
    val="${!var:-}"; [[ -z "$val" ]] && continue
    # Require a readable regular FILE, not just -r: a directory of PEMs is readable
    # but would bind-mount over the single-file node path and containerd can't read
    # it as a ca_file — the silent "looks applied but still x509" case. Mirrors the
    # PS Resolve-CaBundle -PathType Leaf check (reviewer).
    if [[ ! -r "$val" || ! -f "$val" ]]; then echo "$var"; return 2; fi
    case "$val" in /*) : ;; *) val="$(cd "$(dirname "$val")" 2>/dev/null && pwd)/$(basename "$val")" ;; esac
    echo "$val"; return 0
  done
  return 0
}

# Wire the resolved corporate CA into the HOST tools that do NOT honor a CA env on
# their own (#583). git (OpenSSL-backed) honors GIT_SSL_CAINFO on Linux + macOS. The
# Go tools (cosign/helm) read SSL_CERT_FILE on LINUX only — on macOS Go uses the
# system Keychain and IGNORES SSL_CERT_FILE (Bugbot), so there the CA must live in the
# Keychain (or use the offline path, #584). curl ALREADY honors the user's own
# CURL_CA_BUNDLE natively, so we do NOT re-export it (it's replace-not-augment, and a
# corp-root-only bundle would drop the public roots). The k3d NODES are trusted
# separately at cluster-create (#424). Idempotent; no-op when no CA is configured;
# fails fast on a set-but-unreadable bundle. The announce names only what actually
# takes effect on this platform.
wire_ca_trust() {
  local ca rc=0
  ca="$(_resolve_ca_bundle)" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    error "$ca is set but its CA bundle file can't be read — fix its path/permissions and re-run."
  fi
  [[ -z "$ca" ]] && return 0
  # On macOS, wire NOTHING (same decision as Windows, and for the same reason):
  # Go reads the Keychain, not SSL_CERT_FILE, so exporting it helps neither
  # cosign nor helm — while OpenSSL-backed curl DOES honor it, replace-not-
  # augment, so a corp-root-only bundle would shrink download trust for zero
  # gain (Bugbot). And Apple's system git (SecureTransport) ignores
  # GIT_SSL_CAINFO, so claiming git trust from it was false — the clone that
  # matters most, Homebrew's own bootstrap, runs system git (Bugbot).
  if [[ "$OS" == "Darwin" ]]; then
    hint "On macOS, git, cosign and helm read the system Keychain, not a PEM file — add your company's CA to the login Keychain (or use the offline installer) so they trust the proxy."
    return 0
  fi
  # Only set trust vars the user hasn't already set: SSL_CERT_FILE and GIT_SSL_CAINFO
  # are replace-not-augment (Go / OpenSSL), so overwriting a fuller pre-set bundle with
  # a corp-root-only one would drop the public roots those tools need elsewhere (Bugbot).
  #
  # And SAY only what actually happened: a green "Trusting…" while every export was
  # skipped reported wiring that did not happen — masking a pre-set bundle that may
  # still lack the corporate CA (Bugbot). curl "downloads" trust the user's own
  # CURL_CA_BUNDLE, which we deliberately don't touch, so it is never claimed here.
  local wired="" kept=""
  # A var already pointing at OUR CA ($ca) -- whether the installer set it from
  # TRACEBLOC_CA_BUNDLE (the curl|bash path exports SSL_CERT_FILE before launching
  # install-k8s.sh) or the operator set it to the same file -- is WIRED, not a
  # foreign pre-set to keep-and-verify. Reporting it as "keeping your pre-set, verify
  # it" was misleading for a value the installer itself set, and hid the cosign/helm
  # wiring (Bugbot client#631). Only a DIFFERENT pre-set bundle takes the kept branch.
  # `-ef` compares by file identity, robust to relative/absolute/symlink differences.
  if [[ -z "${SSL_CERT_FILE:-}" || "${SSL_CERT_FILE}" -ef "$ca" ]]; then
    export SSL_CERT_FILE="$ca";  wired="cosign, helm"
  else
    kept="SSL_CERT_FILE (cosign/helm)"
  fi
  if [[ -z "${GIT_SSL_CAINFO:-}" || "${GIT_SSL_CAINFO}" -ef "$ca" ]]; then
    export GIT_SSL_CAINFO="$ca"; wired="${wired:+$wired and }git"
  else
    kept="${kept:+$kept and }GIT_SSL_CAINFO (git)"
  fi
  [[ -n "$wired" ]] && success "Trusting your company's certificate for $wired."
  [[ -n "$kept" ]]  && hint "Keeping your pre-set $kept — make sure that bundle includes your company's CA, or those tools will still fail x509."
  return 0
}

# --- kubelet config drop-in (backend#2634, mechanism shared with backend#2460) ---
#
# WHY A CONFIG FILE AND NOT `--kubelet-arg` (read before "simplifying" this)
# `EvictionHard`, `KubeReserved` and `SystemReserved` are MAPS and the kubelet
# replaces them WHOLESALE. k3s ships `imagefs.available` / `nodefs.available`
# defaults, so a CLI write of one eviction key silently drops both disk
# thresholds -- the failure backend#2223 and backend#2443 exist to prevent.
# `scripts/tests/kubelet-arg-map-safety.sh` refuses those settings as CLI args
# for exactly this reason. Image GC is scalar and would survive the CLI, but it
# has to live beside the eviction thresholds it interacts with (`imagefs`
# governs both), and #2460 needs the maps here anyway. One file, authored whole.
#
# MEASURED, not assumed (2026-08-31, k3d v5.8.3 / rancher/k3s:v1.36.3-k3s1,
# server + agent): with this file mounted and `--kubelet-arg=config=` pointing at
# it, /configz on BOTH nodes reports the values below, and it coexists with the
# `fail-cgroupv1` CLI arg.
#
# HOW k3s LOADS IT, re-measured 2026-09-09 (k3d v5.9.0 / rancher/k3s:v1.36.3-k3s1)
# because it decides how the reservation maps below behave: k3s writes its own
# kubelet defaults to `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/
# 00-k3s-defaults.conf` and copies the file named by `--kubelet-arg=config=` into
# the same directory as `10-cli-config.conf`. The kubelet merges config-dir
# drop-ins in lexical order, KEY BY KEY -- so this file already IS the drop-in
# backend#2460 asked for, and a map it sets is merged with k3s's, not swapped for
# it: a probe writing `evictionHard: {memory.available: 500Mi, imagefs.available:
# 7%}` read back as {imagefs 7%, memory.available 500Mi, nodefs.available 5%} --
# k3s's untouched `nodefs` key survived. (An earlier version of this comment said
# the file's map REPLACED k3s's; that was inferred from a probe that set no
# overlapping key, and it is false. The wholesale replacement is real, but it is
# the `--kubelet-arg=eviction-hard=` CLI path's behaviour, which is why that path
# stays refused.) Mounting the file straight into kubelet.conf.d/ as
# `99-tracebloc.conf` behaved identically; the `config=` wiring is kept because
# it is what every installed edge already has.
#
# THE VALUES, and why they are not the stock 85/80
# Task images are 2.7-11 GB and the base image IS the image (`base:gpu` 7.88 GB,
# `client-image_classification-gpu` 7.89 GB -- the task adds ~10 MB), so there is
# no small image to fall back to. Stock leaves a 5-point reclaim band: on a 200 GB
# disk that is 10 GB, which can be less than ONE image, so GC frees nothing
# useful and immediately re-trips while a pull is already failing.
#   high 75  start reclaiming before the disk is full enough to fail a pull
#   low  60  a 15-point band -- on a 100 GB disk ~15 GB, about 2x the largest
#            single image, so one pass makes room for the next pull
#   age  2m  the kubelet never GCs an image a running container uses; this only
#            protects a just-pulled, not-yet-used image from being reclaimed
#            under the same burst that pulled it
# The guard asserts the INVARIANTS (all three set, both twins agree, low < high,
# never looser than stock) rather than these exact integers, so retuning them is
# a values change and not a guard change.
TB_KUBELET_IMAGE_GC_HIGH_PERCENT=75
TB_KUBELET_IMAGE_GC_LOW_PERCENT=60
TB_KUBELET_IMAGE_MIN_GC_AGE="2m"

# --- the node reservation (backend#2460) ---------------------------------------
#
# On every node this installer has ever provisioned, `allocatable == capacity`:
# k3s sets no kube-reserved, no system-reserved and no memory eviction threshold
# (its stock evictionHard carries only the two disk keys -- read from /configz on
# a bare v1.36.3-k3s1 node, 2026-09-09). So "what a pod may have" was the whole
# machine, k3s server, containerd and the Docker VM's own daemons included, and
# every consumer of allocatable -- the training envelope, jobs-manager's
# admission, the T-shirt ladder -- inherited that. The 1 CPU / 3 GiB the envelope
# subtracts was a guess standing in for a reservation the kubelet never made.
#
# The values below are DERIVED FROM MEASUREMENT, per platform, never typed:
# scripts/tests/measure-node-reservation.sh brings a cluster up through the real
# create_cluster(), samples the kubelet's own /stats/summary idle and under a
# training-shaped load (the real 2 GB task image pulled and run), and writes a
# record to scripts/spec/node-reservation/. scripts/gen-node-reservation-embed.sh
# turns the records into the block between the markers, in BOTH twins, and its
# `--check` runs in `make drift` (the required Source-of-truth drift job). What
# it reserves is everything on the node that is NOT a pod -- the node's working
# set minus the `pods` system container, which on k3s is ~5x what the kubelet's
# own `kubelet`/`runtime` rows admit to (they map to the /k3s cgroup; the k3s
# server process itself sits outside it) -- plus, as systemReserved, what the VM
# or host runs outside every node container. On native k3s (the `linux_k3s`
# row) the node IS the host, so node minus pods would count every process on the
# machine: that row reserves the k3s unit's own cgroup instead (k3s, its
# containerd and the shims). The generator's header states the headroom policy;
# the record states the numbers it was applied to.
#
# A platform with NO record gets NO reservation -- not a borrowed one. Docker
# Desktop on macOS, WSL2 and a bare Linux host have different footprints, and a
# number extrapolated from one of them is the guess this ticket retires. The
# writer below emits the maps only for a platform named in
# TB_KUBELET_RESERVATION_PLATFORMS and the caller says so, once, when it does not.
# The kubelet default this replaces is `memory.available<100Mi`; k3s ships none.
#
# The eviction threshold is the one value that is policy rather than footprint:
# memory.available = 5% of the smallest machine the preflight admits
# (PF_MIN_MEM_GB, scripts/lib/preflight.sh), the same fraction k3s applies to its
# disk thresholds. It is derived by the generator from that declaration, so the
# floor moving moves it.
#
# ── kubelet node reservation (GENERATED by scripts/gen-node-reservation-embed.sh — do not hand-edit) ──
TB_KUBELET_RESERVATION_PLATFORMS="darwin linux linux_k3s windows"
# darwin: derived from darwin-arm64.json
TB_KUBELET_KUBE_RESERVED_CPU_MILLI_DARWIN=150
TB_KUBELET_KUBE_RESERVED_MEM_MIB_DARWIN=1088
TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_DARWIN=1024
# linux: derived from linux-amd64-ubuntu-22.04.json
# linux: derived from linux-amd64-ubuntu-24.04.json
# linux: derived from linux-arm64-ubuntu-24.04.json
TB_KUBELET_KUBE_RESERVED_CPU_MILLI_LINUX=100
TB_KUBELET_KUBE_RESERVED_MEM_MIB_LINUX=1152
TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_LINUX=1024
# linux_k3s: derived from linux-amd64-ubuntu-22.04-k3s.json
# linux_k3s: derived from linux-amd64-ubuntu-24.04-k3s.json
# linux_k3s: derived from linux-arm64-ubuntu-24.04-k3s.json
TB_KUBELET_KUBE_RESERVED_CPU_MILLI_LINUX_K3S=100
TB_KUBELET_KUBE_RESERVED_MEM_MIB_LINUX_K3S=1408
TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_LINUX_K3S=1024
# windows: derived from windows-amd64-wsl2-server-2022.json
TB_KUBELET_KUBE_RESERVED_CPU_MILLI_WINDOWS=150
TB_KUBELET_KUBE_RESERVED_MEM_MIB_WINDOWS=2336
TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_WINDOWS=1024
# systemReserved memory: the contract's vm_reserve (scripts/tests/fixtures/envelope_contract.json); evictionHard memory.available: 5% of PF_MIN_MEM_GB=5 GiB (scripts/lib/preflight.sh)
TB_KUBELET_EVICTION_MEM_MIB=256
# ── end generated reservation ─────────────────────────────────────────────────

# Path the file is mounted to INSIDE every k3d node. Named once; the mount and the
# --kubelet-arg must not be able to disagree about it.
TB_KUBELET_CONFIG_NODE_PATH="/etc/tracebloc/kubelet.yaml"
# Where native k3s reads it (RFC-0175 D4): the host IS the node, so there is no
# mount, and this one path is both what the writer writes and what k3s.sh's
# config.yaml names in `kubelet-arg: config=`. Mode 0644, so the e2e readback
# (e2e_assert_node_reservation) can read it without root.
TB_KUBELET_CONFIG_K3S_PATH="/etc/rancher/k3s/tracebloc-kubelet.yaml"

# NOT under /tmp (Bugbot, High, on client#912). This file is BIND-MOUNTED into
# every k3d node, so the host path has to outlive the install: a bind-mount source
# that has disappeared cannot be remounted, and `docker start` of the node then
# fails with a generic Docker error. /tmp is cleared on reboot on macOS and on most
# Linux, so a cluster created from a temp path comes up healthy and can never be
# RESTARTED -- a headless edge looks fine until its first reboot, which is the
# worst possible moment to find out. HOST_DATA_DIR is the installer's own
# persistent directory (already bind-mounted into the nodes as /tracebloc).
#
# On native k3s (TB_SUBSTRATE=k3s) it is the root-owned path above instead,
# written by k3s.sh as root.
_kubelet_config_path() {
  if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then
    printf '%s' "$TB_KUBELET_CONFIG_K3S_PATH"
    return 0
  fi
  printf '%s/kubelet/kubelet.yaml' "${HOST_DATA_DIR:-$HOME/.tracebloc}"
}

# The platform key the reservation table is indexed by: `darwin`, `linux`,
# `windows`, or `linux_k3s` for native k3s. A function, so the bats suite can
# drive the writer as either platform (and as one with no record) on whatever
# host runs the tests.
#
# NOT THE KERNEL NAME (backend#3861). Inside a WSL2 distro `uname -s` is `Linux`,
# and the WSL2 route is the one docs/INSTALL.md recommends for Windows -- so a
# kernel-name key selected TB_KUBELET_*_LINUX on the very machine the `windows`
# record was measured on, and the record could never reach it. The measurement
# harness (scripts/tests/measure-node-reservation.sh) stopped believing that rule
# under client#1078; this is the apply side learning the same distinction,
# through the SAME detector (`_probe_wsl`, scripts/lib/probe.sh) rather than a
# copy of it.
#
# AN ABSENT DETECTOR IS `unknown`, NEVER `linux`. install-k8s.sh sources probe.sh
# conditionally (a stale bootstrap that did not fetch it still installs), so
# `_probe_wsl` may be undefined here. "Assume linux" is exactly the bug being
# fixed; `unknown` matches no row in the generated table, so the writer emits no
# reservation and the create path says why -- unreserved and honest, the same
# posture as a platform nobody has measured yet.
#
# NATIVE k3s IS ITS OWN KEY, `linux_k3s` (TB_SUBSTRATE=k3s on Linux outside WSL).
# The `linux` row was measured on a k3d node, where Docker and the node container
# sit outside the kubelet's view; borrowing it for a host that runs k3s directly
# would restate a number measured on another substrate (rule 1). The
# `linux_k3s` row is measured on native k3s itself, on Ubuntu 22.04 and 24.04,
# amd64 and arm64 (client-dev#1469). k3s on darwin or inside WSL is `unknown`:
# the k3s create path refuses both hosts.
_kubelet_reservation_platform() {
  local kernel
  kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$kernel" != "linux" ]]; then
    if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then printf 'unknown'; else printf '%s' "$kernel"; fi
    return 0
  fi
  # SILENT here: this function returns a VALUE, and its callers (the writer, the
  # e2e check) read `$output` as a path or a key. The reason `unknown` was
  # selected is spoken once, by the create path below, where a warning belongs.
  declare -F _probe_wsl >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  if _probe_wsl; then
    if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then printf 'unknown'; else printf 'windows'; fi
  elif [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then
    printf 'linux_k3s'
  else
    printf 'linux'
  fi
}

# Does the generated table carry a MEASURED entry for this platform?
_kubelet_reservation_measured() {
  local platforms=" ${TB_KUBELET_RESERVATION_PLATFORMS:-} "
  [[ "$platforms" == *" $1 "* ]]
}

# The warning for a platform with no measured reservation, said ONCE per run
# (backend#2460: the operator is told rather than handed a number borrowed from
# another platform; "cannot tell" is a finding, not a default). Every step that
# learns it calls this, so one install never warns twice about the same node:
# k3d's create path, and on native k3s the pre-create fit gate. Silent for a
# measured platform.
_kubelet_reservation_warn_unmeasured() {
  local platform="${1:-$(_kubelet_reservation_platform)}"
  _kubelet_reservation_measured "$platform" && return 0
  [[ -z "${TB_RESERVATION_WARNED:-}" ]] || return 0
  TB_RESERVATION_WARNED=1
  if [[ "$platform" == "unknown" ]] && declare -F _probe_wsl >/dev/null 2>&1; then
    # The detector IS loaded: `unknown` is native k3s on a host the k3s create
    # path refuses (macOS, or WSL), not a missing probe. Say that, not "re-run".
    warn "No node reservation will be written: native k3s has no measured reservation on this host (macOS or WSL), so allocatable will equal capacity on this node."
    hint "Native k3s runs on Linux outside WSL; this host needs the installer's default substrate instead."
  elif [[ "$platform" == "unknown" ]]; then
    # An absent probe.sh (a stale bootstrap that did not fetch it): this Linux
    # kernel cannot be told apart from WSL2, and guessing linux is the defect
    # the detection replaced. Say why, once, here -- not from the selector.
    warn "No node reservation will be written: the host detector (probe.sh) is not loaded, so this Linux kernel cannot be told apart from WSL2 and no platform's measured numbers apply. Allocatable will equal capacity on this node."
    hint "Re-run the installer from a fresh bootstrap so probe.sh is fetched; the reservation is then written for the platform detected."
  else
    warn "No measured node reservation exists for platform '${platform}' ($(uname -s)) yet, so this node's allocatable will equal its capacity -- the training envelope is sized against a number that includes the kubelet and container runtime."
    hint "Measure one with scripts/tests/measure-node-reservation.sh (tracebloc/client) and both installers pick it up."
  fi
  return 0
}

# The three reservation values for a measured platform, echoed as
# "<kube cpu m> <kube mem MiB> <system mem MiB>", read from the generated block by
# indirection. Returns 1 -- and says why on stderr -- when any of them is missing
# or not a whole number: a platform listed as measured whose numbers cannot be
# read is a broken embed, and a reservation written from an empty variable would
# be a `memory: Mi` the kubelet refuses to start on, or a `0` that silently keeps
# the node dishonest. Fail closed, loudly.
_kubelet_reservation_values() {
  local platform="$1" key cpu_var mem_var sys_var
  key="$(printf '%s' "$platform" | tr '[:lower:]' '[:upper:]')"
  cpu_var="TB_KUBELET_KUBE_RESERVED_CPU_MILLI_${key}"
  mem_var="TB_KUBELET_KUBE_RESERVED_MEM_MIB_${key}"
  sys_var="TB_KUBELET_SYSTEM_RESERVED_MEM_MIB_${key}"
  local cpu="${!cpu_var:-}" mem="${!mem_var:-}" sys="${!sys_var:-}"
  local v
  for v in "$cpu_var=$cpu" "$mem_var=$mem" "$sys_var=$sys" "TB_KUBELET_EVICTION_MEM_MIB=${TB_KUBELET_EVICTION_MEM_MIB:-}"; do
    if [[ ! "${v#*=}" =~ ^[1-9][0-9]*$ ]]; then
      echo "kubelet reservation: ${v%%=*} is '${v#*=}', not a positive whole number -- the generated block is broken; run scripts/gen-node-reservation-embed.sh" >&2
      return 1
    fi
  done
  # Newline-terminated: `read` returns 1 at EOF without one, even having filled
  # every variable, and the writer's `|| return 1` would read that as a refusal.
  printf '%s %s %s\n' "$cpu" "$mem" "$sys"
}

# Print the kubelet config drop-in: the image-GC thresholds, plus the node
# reservation for a measured platform. Pure; returns 1 on a broken reservation
# embed, or when the one write of the rendering fails. The writer below and
# k3s.sh's _native_k3s_write_config both print it through here, so the two
# substrates cannot write different kubelet configs.
#
# The text is built in memory with `printf -v` and written ONCE, so the exit
# status is that write's and a failed write can never pass as a shorter file;
# and the reservation is read synchronously, never through `< <(...)`. That
# process substitution was an asynchronous child, its SIGCHLD landed while the
# lines after it were being printed into the caller's pipe, and bash 3.2's
# printf reports the interrupted write (EINTR) rather than retrying it: macOS
# runners failed the install on it (client-dev#1564).
_render_kubelet_config() {
  local platform out line
  platform="$(_kubelet_reservation_platform)"
  printf -v out 'apiVersion: kubelet.config.k8s.io/v1beta1\nkind: KubeletConfiguration\n'
  printf -v line 'imageGCHighThresholdPercent: %s\n' "${TB_KUBELET_IMAGE_GC_HIGH_PERCENT}"; out+="$line"
  printf -v line 'imageGCLowThresholdPercent: %s\n' "${TB_KUBELET_IMAGE_GC_LOW_PERCENT}"; out+="$line"
  printf -v line 'imageMinimumGCAge: %s\n' "${TB_KUBELET_IMAGE_MIN_GC_AGE}"; out+="$line"
  if _kubelet_reservation_measured "$platform"; then
    local vals cpu mem sys
    vals="$(_kubelet_reservation_values "$platform")" || return 1
    read -r cpu mem sys <<<"$vals" || return 1
    [[ -n "$sys" ]] || return 1
    # `pods` is the kubelet default for enforceNodeAllocatable and k3s's too;
    # written so the file says what it relies on: the kubepods cgroup is capped
    # at capacity - kubeReserved - systemReserved, and the eviction threshold is
    # the kubelet's early warning above that cap. `memory.available` is the ONLY
    # evictionHard key written: k3s's `imagefs.available` / `nodefs.available`
    # are merged in from its own drop-in (measured above), and restating them
    # here would pin k3s's numbers in a second place.
    printf -v line 'enforceNodeAllocatable:\n- pods\n'; out+="$line"
    printf -v line 'kubeReserved:\n  cpu: %sm\n  memory: %sMi\n' "$cpu" "$mem"; out+="$line"
    printf -v line 'systemReserved:\n  memory: %sMi\n' "$sys"; out+="$line"
    printf -v line 'evictionHard:\n  memory.available: %sMi\n' "${TB_KUBELET_EVICTION_MEM_MIB}"; out+="$line"
  fi
  printf '%s' "$out"
}

# Write the drop-in to $1 (default: _kubelet_config_path) and echo the path. The
# k3d path; native k3s writes the same rendering as root, with an explicit mode.
# Each attempt renders, writes a sibling temp file, checks the bytes on disk are
# the rendering, and only then moves it over the fixed path, so a re-install
# overwrites and an interrupted write (see the render above) is retried rather
# than failing the install or leaving a partial file where the kubelet reads.
_write_kubelet_config() {
  local cfg="${1:-$(_kubelet_config_path)}" dir body tmp attempt
  dir="$(dirname "$cfg")" || return 1
  mkdir -p "$dir" || return 1
  tmp="${cfg}.tracebloc-tmp.$$"
  for attempt in 1 2 3; do
    if body="$(_render_kubelet_config)" \
      && printf '%s\n' "$body" > "$tmp" \
      && printf '%s\n' "$body" | cmp -s - "$tmp" \
      && mv -f "$tmp" "$cfg"; then
      echo "$cfg"
      return 0
    fi
    rm -f "$tmp"
  done
  return 1
}

# When a proxy is configured, ensure THIS installer's own kubectl/helm/curl
# bypass it for the cluster API (127.0.0.1) and the in-cluster ranges. Go
# already auto-bypasses loopback, but exporting NO_PROXY also covers helm/curl.
_export_host_no_proxy() {
  local var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!var:-}" ]]; then
      local aug; aug="$(_augment_no_proxy)"
      export NO_PROXY="$aug" no_proxy="$aug"
      return 0
    fi
  done
}

# ── Leftover-data guard (RFC-0003 §4 / D3, #376) ─────────────────────────────
# The installer used to `mkdir -p` its data dirs and silently adopt whatever was
# already there — data left by an earlier install (different layout, older
# version, custom dir) got picked up by the next install, so a "fresh" install
# was not guaranteed fresh. This guard detects real leftover data at install
# time and forces a choice instead of adopting it. It doubles as the migration
# prompt for the node-local transition (#367): existing ~/.tracebloc data is
# never silently stranded.
#
# Where prompts READ from (mirrors provision.sh/install-client-helm.sh so the
# curl|bash path can still prompt on the controlling terminal; overridable so
# tests can feed canned input via TB_TTY=/dev/stdin).
: "${TB_TTY:=/dev/tty}"

# True only when $TB_TTY can actually be OPENED for reading. A plain `-r` test is
# not enough: /dev/tty is world-readable even with no controlling terminal (CI,
# `curl|bash`), so `-r` would route those runs into the interactive branch where
# the `read` then fails immediately and the guard aborts with the generic abort
# text instead of the non-interactive guidance that lists --reuse-data/--wipe-data
# (Bugbot #384). Mirrors the openability probe assess.sh already uses.
_tty_usable() { { : <"$TB_TTY"; } 2>/dev/null; }

# Echo each dir under HOST_DATA_DIR that holds real client data — a MySQL data
# dir or a dataset dir with at least one file — across BOTH on-disk layouts:
# flat ($HOST_DATA_DIR/{mysql,data}) and per-release ($HOST_DATA_DIR/<rel>/…).
# Deliberately scoped to HOST_DATA_DIR only: HOST_DATASET_DIR may be a shared
# network mount other tools use, so the guard never scans or touches it. Empty
# dirs, values.yaml and install-*.log are not data and are ignored.
#
# On native k3s (TB_SUBSTRATE=k3s) the volumes live in local-path's storage path
# instead, so the native scan below runs first; HOST_DATA_DIR is still scanned,
# because data an earlier install left there is stranded either way.
_leftover_data_dirs() {
  local base="${HOST_DATA_DIR:-}" native=""
  if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then
    native="$(_leftover_k3s_volume_dirs)"
    [[ -z "$native" ]] || printf '%s\n' "$native"
  fi
  [[ -n "$base" && -d "$base" ]] || return 0
  local -a candidates=("$base/mysql" "$base/data")
  local sub
  for sub in "$base"/*/; do
    # Skip symlinked per-release dirs: base is physically resolved (validate_config
    # uses `cd -P`), so a real subdir can't escape it — but a symlink could point
    # anywhere, and $base/<link>/mysql would let the wipe's rm -rf follow it
    # outside HOST_DATA_DIR (Bugbot #384). Not walking symlinks keeps scope honest.
    [[ -d "$sub" && ! -L "${sub%/}" ]] || continue
    # Skip the flat-layout data dirs themselves — they are already candidates
    # above. Descending into them would mislabel a real MySQL datadir's nested
    # `mysql` system schema ($base/mysql/mysql) as a second leftover root, which
    # confuses the prompt and doubles up wipe targets (Bugbot #384).
    case "${sub%/}" in "$base/mysql"|"$base/data") continue ;; esac
    # Likewise a volume the native scan already named: when the operator's data dir
    # IS the storage path, a pvc-* volume is a root, and the `mysql` system schema
    # inside it is not a second leftover (Bugbot).
    [[ -z "$native" ]] || { grep -qxF -- "${sub%/}" <<<"$native" && continue; }
    candidates+=("${sub%/}/mysql" "${sub%/}/data")
  done
  local d
  for d in "${candidates[@]}"; do  # set-u-safe: seeded with mysql and data at its declaration
    # ! -L: never treat a symlink as a data dir — it would let the wipe traverse
    # outside HOST_DATA_DIR (Bugbot #384). A symlinked data path is out of scope.
    [[ -d "$d" && ! -L "$d" ]] || continue

    # Fail closed on an unlistable dir: a root/container-owned mysql/data dir the
    # host user can't read/enter can't be proven empty, so treat it as a leftover
    # rather than mistake it for a clean slate and adopt it (Bugbot #384; same
    # ownership case the wipe path treats as fatal). This is the common shape —
    # the whole data dir is owned by the container uid. No temp file, so it can't
    # itself fail open (an earlier mktemp-based version could when mktemp failed).
    if [[ ! -r "$d" || ! -x "$d" ]]; then
      echo "$d"; continue
    fi

    # Readable dir → non-empty test. pipefail-safe AND portable (GNU + BSD/macOS:
    # no -quit): a `find | head -1 | grep` pipeline SIGPIPEs find once output
    # exceeds the pipe buffer (a real multi-table MySQL dir), and under the
    # installer's `set -o pipefail` that reads as "empty" — the exact leftover
    # this guard must catch. `read < <(find …)` keeps find's status out of the
    # check and short-circuits after one line. The `||` fallback (only reached
    # when no top-level file was read) captures find's stderr WITHOUT a temp file
    # — so an unreadable *sub*dir (Permission denied) is also caught, not skipped.
    if read -r _ < <(find "$d" -type f 2>/dev/null) \
       || [[ -n "$(find "$d" -type f 2>&1 >/dev/null)" ]]; then
      echo "$d"
    fi
  done
}

# _leftover_k3s_present PATH -- `present` or `absent`, read as root through the sudo
# shadow (k3s owns the storage path, and a parent it made 0700 hides PATH from the
# daily user). Empty when root cannot answer, which is "cannot tell", never absent.
_leftover_k3s_present() {
  sudo sh -c 'if [ -e "$1" ]; then echo present; else echo absent; fi' _ "$1" 2>/dev/null || true
}

# The native k3s scan: every local-path volume directory (pvc-*, with anything in
# it) under the storage path _native_k3s_storage_path names (k3s.sh): k3s's
# default, or the operator's data dir. Read as root. FAIL CLOSED: a storage path
# root cannot be read is echoed itself, as data nobody could prove absent, and a
# storage path that cannot be told (config.yaml unreadable) echoes config.yaml.
# This runs inside the guard's process substitution, whose status nobody reads, so
# it must print rather than fail.
_leftover_k3s_volume_dirs() {
  local storage out rc=0
  storage="$(_native_k3s_storage_path)" || { printf '%s\n' "$TB_K3S_CONFIG_PATH"; return 0; }
  case "$(_leftover_k3s_present "$storage")" in
    absent)  return 0 ;;
    present) ;;
    *)       printf '%s\n' "$storage"; return 0 ;;
  esac
  out="$(sudo find "$storage" -mindepth 1 -maxdepth 1 -type d -name 'pvc-*' ! -empty 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$storage"; return 0; fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return 0
}

# True only when the k3s service is known to be stopped. Its volumes are open while
# it runs, so a wipe under it deletes data a live workload holds. No answer from
# systemctl is "cannot tell", which refuses as a running service does -- and so
# is `unknown`, which is systemctl failing to read the unit's state, not a stop.
_leftover_k3s_service_stopped() {
  local state
  state="$(systemctl is-active k3s 2>/dev/null)" || true
  case "${state%%$'\n'*}" in
    inactive|failed) return 0 ;;
  esac
  return 1
}

# _leftover_where PATH... -- where the found data lies, for the guard's copy:
# HOST_DATA_DIR (k3d, always), and on native k3s the storage path when a found
# path is under it.
_leftover_where() {
  local storage="" d in_s=0 in_h=0
  [[ "${TB_SUBSTRATE:-}" == "k3s" ]] && storage="$(_native_k3s_storage_path)"
  for d in "$@"; do
    if [[ -n "$storage" && ( "$d" == "$storage" || "$d" == "$storage"/* ) ]]; then in_s=1; else in_h=1; fi
  done
  if (( in_s && in_h )); then printf '%s and %s' "$storage" "$HOST_DATA_DIR"
  elif (( in_s )); then printf '%s' "$storage"
  else printf '%s' "$HOST_DATA_DIR"
  fi
}

# Read one line from $TB_TTY into the named variable, stripping bracketed-paste
# / CSI escape garbage (arrow keys, pastes survive `read -r`) and trimming
# surrounding whitespace — so a paste or a spaces-then-Enter can't smuggle
# control bytes into HOST_DATA_DIR or slip past a non-empty check. Mirrors the
# provision.sh client-name handling (_strip_paste_garbage + trim).
_read_sanitized() {
  local __prompt="$1" __var="$2" __in=""
  read -r -p "$__prompt" __in <"$TB_TTY" || __in=""
  __in="$(_strip_paste_garbage "$__in")"
  __in="${__in#"${__in%%[![:space:]]*}"}"; __in="${__in%"${__in##*[![:space:]]}"}"
  printf -v "$__var" '%s' "$__in"
}

# Delete the detected leftover data dirs. Only ever removes paths UNDER the
# already-validated HOST_DATA_DIR (validate_config guarantees it is under $HOME
# and not a system path) — never HOST_DATASET_DIR, never a system path. Returns
# non-zero if anything survived the wipe (e.g. root/container-owned MySQL files
# the host user can't remove) so the caller can fail closed instead of letting
# create_cluster adopt the survivors — a warn-and-proceed would silently break
# the "wipe means gone" guarantee.
#
# On native k3s it also removes a pvc-* volume directory directly under the
# storage path, and every removal and its check run as root (through sudo; k3s owns
# the volumes). It never runs while the k3s service may be running.
_wipe_leftover_data() {
  # Belt-and-suspenders (Lukas review, #384): never wipe unless HOST_DATA_DIR is
  # a non-empty path strictly under $HOME — exactly what validate_config enforces.
  # This guards the rm below even if a future refactor ever calls the guard before
  # validate_config: an empty HOST_DATA_DIR would collapse the "$HOST_DATA_DIR"/*
  # case pattern to /* and defeat the scope check. Placed in the destructive
  # function itself so it holds for every caller, not just the current one.
  [[ -n "${HOST_DATA_DIR:-}" && "$HOST_DATA_DIR" == "$HOME"/* ]] \
    || error "Refusing to wipe: HOST_DATA_DIR is unset or not under \$HOME (got '${HOST_DATA_DIR:-}')."
  local d rc=0 storage=""
  local -a as_root=()
  if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then
    _leftover_k3s_service_stopped \
      || error "Refusing to wipe while the k3s service may be running: its volumes are in use. Stop it with 'sudo systemctl stop k3s', check 'systemctl is-active k3s' says inactive, then re-run."
    local src=0
    storage="$(_native_k3s_storage_path)" || src=$?
    if [[ "$src" -eq 3 ]]; then   # needs the password: ask once, retry once
      declare -F preflight_sudo >/dev/null 2>&1 && preflight_sudo
      src=0; storage="$(_native_k3s_storage_path)" || src=$?
    fi
    [[ "$src" -eq 0 ]] \
      || error "Refusing to wipe: couldn't read ${TB_K3S_CONFIG_PATH}, so where k3s keeps its volumes can't be told."
    as_root=(sudo)
  fi
  for d in "$@"; do
    case "$d" in
      "$HOST_DATA_DIR"/*)
        # Backstop for the symlink case (detection already skips symlinks): never
        # rm -rf a symlink — it would delete the target OUTSIDE HOST_DATA_DIR.
        if [[ -L "$d" ]]; then
          warn "Refusing to wipe symlink ${d} — it could point outside ${HOST_DATA_DIR}; remove it by hand."
          rc=1; continue
        fi
        ;;
      *)
        # The native storage path's own volume dirs, and nothing else: one level,
        # pvc-*, no `..` (detection lists them with find -type d, so no symlink).
        if [[ -z "$storage" || "$d" != "$storage"/pvc-* || "$d" == *"/.."* || "${d#"$storage"/}" == */* ]]; then
          warn "Refusing to wipe ${d} — outside ${HOST_DATA_DIR}."
          rc=1; continue
        fi
        ;;
    esac
    log "Wiping leftover data: ${d}"
    ${as_root[@]+"${as_root[@]}"} rm -rf "$d" 2>/dev/null || true
    # Verify — do not trust rm's exit code alone. As root on k3s, where a check
    # that cannot answer is a survivor, never a removal.
    if [[ -n "$storage" ]]; then
      [[ "$(_leftover_k3s_present "$d")" == "absent" ]] || { warn "Could not remove ${d} as root."; rc=1; }
    elif [[ -e "$d" ]]; then
      warn "Could not remove ${d} — files may be owned by another user (root/container)."
      rc=1
    fi
  done
  return "$rc"
}

# Guard entry point. Called from create_cluster ONLY when creating a NEW cluster
# (an existing cluster is an in-place reuse/upgrade whose data stays by design,
# §3.3). Resolves an action from TB_LEFTOVER_ACTION (set by --reuse-data /
# --wipe-data, or directly) or, failing that, an interactive prompt. When there
# is no terminal and no explicit action, it fails safe: abort, never adopt.
guard_leftover_data() {
  [[ -n "${TRACEBLOC_SKIP_LEFTOVER_GUARD:-}" ]] && return 0

  local -a found=()
  local d
  # Native k3s: where the volumes live is read here, in the main shell, so a
  # config.yaml that cannot be read stops the run by name instead of reading as
  # an empty scan inside the process substitution below.
  if [[ "${TB_SUBSTRATE:-}" == "k3s" ]]; then
    local src=0
    _native_k3s_storage_path >/dev/null || src=$?
    if [[ "$src" -eq 3 ]]; then   # root-only config.yaml: ask for the password once, retry once
      declare -F preflight_sudo >/dev/null 2>&1 && preflight_sudo
      src=0; _native_k3s_storage_path >/dev/null || src=$?
    fi
    [[ "$src" -eq 0 ]] \
      || error "Couldn't read ${TB_K3S_CONFIG_PATH}, so whether this machine holds tracebloc data can't be told. Check it with 'sudo cat ${TB_K3S_CONFIG_PATH}', then re-run."
  fi
  while IFS= read -r d; do [[ -n "$d" ]] && found+=("$d"); done < <(_leftover_data_dirs)
  [[ ${#found[@]} -eq 0 ]] && return 0   # clean slate — nothing to guard

  # Native k3s (TB_SUBSTRATE=k3s) words each line for its own storage: the data
  # lies in the storage path as well as HOST_DATA_DIR (_leftover_where), and a
  # fresh install gives its volumes new directories, so nothing found is adopted.
  # hostpath is never offered there: native k3s has no hostpath mode.
  local where k3s="" frozen=""
  where="$(_leftover_where "${found[@]}")"  # set-u-safe: the empty-found check above returns first
  [[ "${TB_SUBSTRATE:-}" == "k3s" ]] && k3s=1
  # A config.yaml froze the storage path: another data dir does not move the
  # volumes, so "install into a different directory" is not an escape and is not
  # offered (the same scan would find the same volumes and ask again).
  # A frozen check that cannot answer (rc 2) is treated as frozen: do not offer an
  # escape that may not exist.
  if [[ -n "$k3s" ]]; then
    local frc=0
    _native_k3s_storage_frozen || frc=$?
    [[ "$frc" -eq 1 ]] || frozen=1
  fi
  warn "Existing tracebloc data found under ${where}:"
  for d in "${found[@]}"; do hint "  • ${d}"; done  # set-u-safe: the empty-found check above returns first
  # The "silently adopt" warning is true ONLY for hostpath. Under node-local (the
  # default since D15, client#456) a fresh install does NOT adopt this data — the
  # cluster starts empty in-node and the host data is stranded. Leading with the
  # adopt claim there would contradict the very next line (client#456 Bugbot).
  if [[ -n "$k3s" ]]; then
    hint "A fresh native k3s install does NOT adopt this data: its volumes get new directories, so the data would be stranded, not used."
  elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    hint "node-local storage keeps data inside the cluster node — a fresh install does NOT adopt this ~/.tracebloc data; it would be stranded, not used."
  else
    hint "A fresh install would silently adopt it, so it would not really be fresh."
  fi

  local action="${TB_LEFTOVER_ACTION:-}"
  if [[ -z "$action" ]]; then
    if _tty_usable; then
      prompt_header "How should the installer handle it?"
      if [[ -n "$k3s" ]]; then
        hint "  [r] keep  — leave the existing data on disk, unused (a fresh install starts empty; it is NOT adopted)"
      elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        # node-local can't adopt the host data (no /tracebloc bind-mount) — the
        # cluster starts empty in-node — so don't offer "reuse = adopt" here (#367).
        hint "  [r] keep  — leave the existing data on disk, unused (node-local starts empty; it is NOT adopted)"
      else
        hint "  [r] reuse — keep and adopt the existing data"
      fi
      hint "  [w] wipe  — delete it and start fresh"
      [[ -n "$frozen" ]] || hint "  [n] new   — install into a different directory"
      hint "  [a] abort — stop and sort it out myself (default)"
      local reply=""
      if [[ -n "$frozen" ]]; then
        _read_sanitized "  Choice [r/w/a]: " reply
      else
        _read_sanitized "  Choice [r/w/n/a]: " reply
      fi
      # Accept the word we SHOW: node-local relabels [r] to "keep", so r/reuse AND
      # k/keep must both map to the reuse action or a user typing the shown "keep"
      # would fall through to abort (Bugbot). Lowercase via tr (bash 3.2-safe — no
      # ${x,,}) so any casing works.
      local choice; choice=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
      case "$choice" in
        r|reuse|k|keep) action=reuse ;;
        w|wipe)         action=wipe ;;
        n|new)          if [[ -n "$frozen" ]]; then action=abort; else action=newdir; fi ;;
        *)              action=abort ;;
      esac
    else
      # Non-interactive with no explicit choice → fail safe. Describe --reuse-data
      # honestly per storage mode: under node-local it keeps the data on disk but
      # does NOT adopt it (the cluster starts empty in-node), matching the
      # interactive reuse branch below (Bugbot).
      local reuse_desc="adopt the existing data"
      [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] && \
        reuse_desc="keep the data on disk, NOT adopted (node-local starts empty in-node)"
      [[ -n "$k3s" ]] && reuse_desc="keep the data on disk, NOT adopted (a fresh install starts empty)"
      local newdir_line="
  TRACEBLOC_HOST_DATA_DIR=<new-path> ...  install into a different directory"
      [[ -n "$frozen" ]] && newdir_line=""   # config.yaml froze the volumes' directory: the env cannot move them
      error "Existing data found under ${where} and no choice was given (no terminal). Re-run with one of:
  --reuse-data                    ${reuse_desc}
  --wipe-data                     delete it and start fresh${newdir_line}
  (or TRACEBLOC_SKIP_LEFTOVER_GUARD=1 to bypass this guard entirely)"
    fi
  fi

  case "$action" in
    reuse)
      if [[ -n "$k3s" ]]; then
        warn "A fresh native k3s install can't adopt the data under ${where} — its volumes start empty."
        hint "Your existing data is left on disk, untouched but unused. Re-ingest it after setup ('tracebloc data ingest')."
        log "native k3s: left ${where} on disk (NOT adopted)."
      elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        # node-local starts empty in-node — the host data is NOT adopted (RFC-0003
        # §4 / #367). Keep the files on disk but say so plainly, so "reuse" never
        # silently claims an adoption that node-local can't actually do.
        warn "node-local storage can't adopt ${HOST_DATA_DIR} — the new cluster starts empty inside the node."
        hint "Your existing data is left on disk, untouched but unused. Re-ingest it after setup ('tracebloc data ingest'), or use hostpath storage (TRACEBLOC_STORAGE_MODE=hostpath) to keep using it in place."
        log "node-local: left ${HOST_DATA_DIR} on disk (NOT adopted — no host bind-mount)."
      else
        log "Reusing existing data under ${HOST_DATA_DIR} (user choice)."
      fi
      ;;
    wipe)
      # Fail closed: if any data survived the wipe, abort rather than fall
      # through to create_cluster, which would adopt the survivors and silently
      # break the "wipe means gone" guarantee.
      if ! _wipe_leftover_data "${found[@]}"; then  # set-u-safe: the empty-found check at the top of this function returns first
        local rm_eg="'sudo rm -rf ${HOST_DATA_DIR}'"
        [[ -n "$k3s" ]] && rm_eg="'sudo rm -rf' on each path listed above, with k3s stopped"
        local or_dir=", or choose a different directory"
        [[ -n "$frozen" ]] && or_dir=""   # config.yaml froze the volumes' directory: there is no other to choose
        error "Could not fully wipe existing data under ${where} — some files could not be removed (often root/container-owned MySQL files). Remove them manually (e.g. ${rm_eg}) and re-run${or_dir}. Refusing to proceed and adopt the leftovers."
      fi
      if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
        hint "Left HOST_DATASET_DIR (${HOST_DATASET_DIR}) untouched — it is a shared mount, not wiped."
      fi
      log "Wiped leftover data under ${where} (user choice)."
      ;;
    newdir)
      local newdir=""
      _tty_usable && _read_sanitized "  New data directory (absolute or under \$HOME): " newdir
      [[ -n "$newdir" ]] || error "No new directory given — aborting."
      HOST_DATA_DIR="$newdir"
      # Re-resolve + re-validate the new path, then re-check it for leftovers too.
      if declare -F validate_config >/dev/null 2>&1; then validate_config; fi
      log "Switched HOST_DATA_DIR to ${HOST_DATA_DIR}; re-checking it for leftover data."
      guard_leftover_data
      ;;
    abort|*)
      if [[ -n "$frozen" ]]; then
        error "Aborted — existing data under ${where} left untouched. Choose keep / wipe and re-run."
      else
        error "Aborted — existing data under ${where} left untouched. Choose reuse / wipe / a new directory and re-run."
      fi
      ;;
  esac
}

# THE ORDER IS THE CONTRACT: guard_leftover_data FIRST, the host data dirs
# SECOND, and only then _create_new_cluster (LukasWodka, client#984 round 7).
#
# Extracted so both paths into `_create_new_cluster` run the SAME step rather
# than one of them re-deriving it. The rc-3 path ran the two the other way round
# — `_ensure_tracebloc_dirs` had already fired above the `case` — while its own
# comment claimed it ran "exactly as it does for a first-read ABSENT". Both of
# the guard's mutating arms are falsified by that order:
#
#   * WIPE. `_leftover_data_dirs` yields `$base/mysql` and `$base/data`, and
#     `_wipe_leftover_data` does `rm -rf "$d"` — the DIRECTORY, not its contents.
#     The definite-absent path re-creates and re-`chmod 777`s them afterwards; on
#     the rc-3 path nothing did, so `_create_new_cluster` bind-mounted a
#     HOST_DATA_DIR whose `mysql` and `data` were gone.
#   * NEWDIR. That arm sets `HOST_DATA_DIR="$newdir"`, calls `validate_config`
#     and recurses. `validate_config` has no `mkdir` and no `chmod`, so on the
#     rc-3 path the dirs step had already run against the OLD path and the new
#     one got neither before the mount.
#
# Hostpath only. node-local (RFC-0003 Option C) has no host data dirs, no
# bind-mount and no chmod — datasets live on k3s local-path inside the node — so
# there is nothing to create and calling it twice there is a no-op either way.
# The mode's log line stays at the single decision point in create_cluster so it
# is printed once, not once per path.
_ensure_host_data_dirs() {
  if [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    return 0
  fi
  _ensure_tracebloc_dirs
}

# _api_answers [CONTEXT] -- the API answers: on CONTEXT by name when given (native
# k3s asks its own), else on the current context (k3d's merge makes its context
# current). ONE definition, read by the detector's gate and by both API waits, so
# they cannot disagree about what "answers" means. --request-timeout bounds the
# call itself (see _wait_for_api).
_api_answers() {
  kubectl ${1:+--context "$1"} cluster-info --request-timeout=5s &>/dev/null
}

# The API wait budget in seconds: TB_API_WAIT_S when it is a whole number, else 180.
# One reading for both waits (k3d.sh's _wait_for_api, k3s.sh's
# _native_k3s_wait_for_api), so the documented knob means the same on each substrate.
_api_wait_budget_s() {
  case "${TB_API_WAIT_S:-}" in ''|*[!0-9]*) printf '180' ;; *) printf '%s' "$((10#${TB_API_WAIT_S}))" ;; esac
}

# _ipv4_to_int ADDR — a dotted quad as an integer; non-zero for anything else.
_ipv4_to_int() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' a b c d
  [[ "${1:-}" =~ $re ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  printf '%s\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

_int_to_ipv4() {
  printf '%d.%d.%d.%d\n' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

# The three log markers the detector reads, declared once: the parser in k3d.sh and
# the tests' fixtures both go through _k3s_log_facts, never a copy of these.
_TB_K3S_RUN_MARK='msg="Starting k3s v'
_TB_K3S_NODEIP_FAIL='failed to find interface with specified node ip'
_TB_K3S_NODEIPS_MARK='"Successfully retrieved NodeIPs"'

# The finding _wait_for_api names instead of its generic list, when the detector
# found a node whose k3s is not running for a reason it does not recognise.
#
# STICKY across the re-checks of one API wait (_wait_for_api resets it once, at
# its start). k3s flaps for 10-30 s after a swap, so a later check can land on an
# API that answers for a moment, or on a read that cannot tell; neither is
# evidence the earlier finding stopped being true, and clearing it there sent the
# timeout back to the generic list. Only a completed check that sees every server
# running k3s clears it, and so does a repair that worked.
TB_K3S_NODE_FINDING="${TB_K3S_NODE_FINDING:-}"

# ── The substrate dispatcher ─────────────────────────────────────────────────

# create_cluster -- step c: set up the substrate this run resolved (TB_SUBSTRATE).
# The ONE switch: k3d's create path lives in k3d.sh, native k3s's in k3s.sh, and each
# arm only calls into its lib. A value with no arm is refused by name and never
# routed to a default (fail closed): main() refuses it before this point, so reaching
# here with one means a caller skipped that refusal, and it gets no cluster.
create_cluster() {
  case "${TB_SUBSTRATE:-}" in
    k3d) _k3d_create_cluster ;;
    k3s) _native_k3s_create_cluster ;;
    *) error "create_cluster: TRACEBLOC_SUBSTRATE='${TB_SUBSTRATE:-}' names no runtime this installer can create, so nothing was created." ;;
  esac
}
