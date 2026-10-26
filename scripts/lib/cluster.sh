#!/usr/bin/env bash
# =============================================================================
#  cluster.sh — the substrate-neutral cluster helpers: host data dirs, the
#  proxy and CA trust inputs, the kubelet reservation and the leftover-data
#  guard. Native k3s's code that reads them lives in k3s.sh and mac-container.sh.
# =============================================================================

# Ensure HOST_DATA_DIR and its logs and mysql dirs exist, the chart's hostPath root on native k3s.
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
# same pair is spelled out in the chart's init-writable-data
# (client/templates/jobs-manager-deployment.yaml) too, and the two have to be
# diffable by eye rather than drifting (#667, #673); hostpath-prep.bats holds them
# equal.
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

# Echo the path:mode pairs this release needs, one per line — the same shape the chart's
# init-writable-data uses, so hostpath-prep.bats can diff the two without re-deriving the
# layout (#673).
#
# backend#743: the dataset dir goes under HOST_DATASET_DIR (network mount) when set, else
# stays local. logs (and mysql, below) always stay on the local HOST_DATA_DIR.
_release_dirs_spec() {
  local release="$1"
  # An installed native-k3s hostpath release keeps the root and dataset dir it was made
  # with (_native_k3s_release_storage, client-dev#1782): those are the dirs its PVs name,
  # so those are the ones to prepare, not this run's. _hostpath_root is HOST_DATA_DIR
  # unless a release's root is kept.
  local root; root="$(_hostpath_root)"; root="${root:-$HOST_DATA_DIR}"
  local ds="${HOST_DATASET_DIR:-}"
  [[ "${TB_HOSTPATH_KEPT:-}" != 1 ]] || ds="${TB_HOSTPATH_DATASET:-}"
  local base="$root/$release"
  local data_base="${ds:+$ds/$release}"
  data_base="${data_base:-$base}"
  printf '%s\n' "$data_base/data:$TB_SHARED_DIR_MODE" "$base/logs:$TB_LOGS_DIR_MODE"
}

# Pre-create the per-release host dirs the chart's hostPath PVs bind to.
# The PVs use <hostPath.root>/<release>/{data,logs,mysql}, and on native k3s the
# installer sets that root to HOST_DATA_DIR, the host's own folder.
# Without pre-creating these as the host user, kubelet's DirectoryOrCreate
# makes them root:root 0755 and the host user can't drop training data into
# /data/shared.
_ensure_release_dirs() {
  local release="$1"
  [[ -z "$release" ]] && return 0
  local base root; root="$(_hostpath_root)"; base="${root:-$HOST_DATA_DIR}/$release"
  # mysql is deliberately left on the flat recursive 777 this function has always used:
  # it has ONE writer (uid 999) and its own init container in the chart, and its datadir
  # permissions are the database's business — the same reason it is out of scope for
  # init-writable-data (#654, #673).
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
# 10.42.0.0/16, the service CIDR 10.43.0.0/16 and node IPs in one shot), and the
# in-cluster DNS suffixes. Sending this traffic out to the proxy misroutes
# in-cluster calls. We union these into whatever NO_PROXY the host set. (A tenant that needs
# a *proxied* private-IP destination can narrow this; tracebloc itself only
# pulls from public registries + dials public api.tracebloc.io, so the broad
# bypass is safe for the isolated VM the client runs on.)
TB_NO_PROXY_DEFAULTS="localhost,127.0.0.1,0.0.0.0,169.254.169.254,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local"

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
# proxy: a NO_PROXY alone proxies nothing. k3s.sh hands them to upstream's
# install.sh, which writes them into k3s.service.env, and the macOS node runs with them.
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
# (rancher/k3s, tracebloc images) fails x509 — then masked into a
# root-cause-free "an image couldn't be pulled". When the operator supplies the
# CA bundle we hand it to the node and point containerd at it per-registry.

# The registries the cluster pulls from; behind a break-and-inspect proxy each
# needs the corporate CA to validate the intercepted cert.
TRACEBLOC_CA_REGISTRIES=(docker.io registry-1.docker.io auth.docker.io ghcr.io)

# Print a containerd registries.yaml that points every registry in TRACEBLOC_CA_REGISTRIES
# at the CA file $1 -- the path containerd reads it from, on the host on native k3s.
# Pure: the writer (k3s.sh's _native_k3s_write_config) owns where it lands.
_render_registries_config() {
  local node_ca="$1" host
  echo "configs:"
  for host in "${TRACEBLOC_CA_REGISTRIES[@]}"; do  # set-u-safe: TRACEBLOC_CA_REGISTRIES is a file-scope constant
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
    # it as a ca_file — the silent "looks applied but still x509" case (reviewer).
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
# corp-root-only bundle would drop the public roots). The node is trusted
# separately, through registries.yaml (#424). Idempotent; no-op when no CA is configured;
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
  # GIT_SSL_CAINFO, so claiming git trust from it was false (Bugbot).
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
# The guard asserts the INVARIANTS (all three set, low < high, never looser than
# stock) rather than these exact integers, so retuning them is a values change and
# not a guard change.
TB_KUBELET_IMAGE_GC_HIGH_PERCENT=75
TB_KUBELET_IMAGE_GC_LOW_PERCENT=60
TB_KUBELET_IMAGE_MIN_GC_AGE="2m"

# --- the node reservation (backend#2460) ---------------------------------------
#
# On every node this installer has ever provisioned, `allocatable == capacity`:
# k3s sets no kube-reserved, no system-reserved and no memory eviction threshold
# (its stock evictionHard carries only the two disk keys -- read from /configz on
# a bare v1.36.3-k3s1 node, 2026-09-09). So "what a pod may have" was the whole
# machine, k3s server, containerd and the VM's own daemons included, and
# every consumer of allocatable -- the training envelope, jobs-manager's
# admission, the T-shirt ladder -- inherited that. The 1 CPU / 3 GiB the envelope
# subtracts was a guess standing in for a reservation the kubelet never made.
#
# The values below are DERIVED FROM MEASUREMENT, per platform, never typed:
# scripts/tests/measure-node-reservation.sh brings a cluster up through the real
# create_cluster(), samples the kubelet's own /stats/summary idle and under a
# training-shaped load (the real 2 GB task image pulled and run), and writes a
# record to scripts/spec/node-reservation/. scripts/gen-node-reservation-embed.sh
# turns the records into the block between the markers, and its
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
# A platform with NO record gets NO reservation -- not a borrowed one. The macOS
# node's VM, tracebloc's WSL distro and a bare Linux host have different footprints, and a
# number extrapolated from one of them is the guess this ticket retires. The
# writer below emits the maps only for a platform named in
# TRACEBLOC_KUBELET_RESERVATION_PLATFORMS and the caller says so, once, when it does not.
# The kubelet default this replaces is `memory.available<100Mi`; k3s ships none.
#
# The eviction threshold is the one value that is policy rather than footprint:
# memory.available = 5% of the smallest machine the preflight admits
# (PF_MIN_MEM_GB, scripts/lib/preflight.sh), the same fraction k3s applies to its
# disk thresholds. It is derived by the generator from that declaration, so the
# floor moving moves it.
#
# ── kubelet node reservation (GENERATED by scripts/gen-node-reservation-embed.sh — do not hand-edit) ──
TRACEBLOC_KUBELET_RESERVATION_PLATFORMS="darwin_k3s linux_k3s windows_k3s"
# darwin_k3s: derived from darwin-arm64-k3s.json
TRACEBLOC_KUBELET_KUBE_RESERVED_CPU_MILLI_DARWIN_K3S=150
TRACEBLOC_KUBELET_KUBE_RESERVED_MEM_MIB_DARWIN_K3S=1280
TRACEBLOC_KUBELET_SYSTEM_RESERVED_MEM_MIB_DARWIN_K3S=1024
# linux_k3s: derived from linux-amd64-ubuntu-22.04-k3s.json
# linux_k3s: derived from linux-amd64-ubuntu-24.04-k3s.json
# linux_k3s: derived from linux-arm64-ubuntu-24.04-k3s.json
TRACEBLOC_KUBELET_KUBE_RESERVED_CPU_MILLI_LINUX_K3S=100
TRACEBLOC_KUBELET_KUBE_RESERVED_MEM_MIB_LINUX_K3S=1408
TRACEBLOC_KUBELET_SYSTEM_RESERVED_MEM_MIB_LINUX_K3S=1024
# windows_k3s: derived from windows-amd64-wsl2-server-2025-k3s.json
TRACEBLOC_KUBELET_KUBE_RESERVED_CPU_MILLI_WINDOWS_K3S=350
TRACEBLOC_KUBELET_KUBE_RESERVED_MEM_MIB_WINDOWS_K3S=992
TRACEBLOC_KUBELET_SYSTEM_RESERVED_MEM_MIB_WINDOWS_K3S=1024
# systemReserved memory: the contract's vm_reserve (scripts/tests/fixtures/envelope_contract.json); evictionHard memory.available: 5% of PF_MIN_MEM_GB=5 GiB (scripts/lib/preflight.sh)
TRACEBLOC_KUBELET_EVICTION_MEM_MIB=256
# ── end generated reservation ─────────────────────────────────────────────────

# Where native k3s reads it (RFC-0175 D4): the host IS the node, so there is no
# mount, and this one path is both what the writer writes and what k3s.sh's
# config.yaml names in `kubelet-arg: config=`. Mode 0644, so the e2e readback
# (e2e_assert_node_reservation) can read it without root.
TB_KUBELET_CONFIG_K3S_PATH="/etc/rancher/k3s/tracebloc-kubelet.yaml"

# Where the kubelet reads the drop-in: native k3s's path above. The e2e readback
# (e2e_assert_node_reservation) and the measurement harness read it here.
_kubelet_config_path() {
  printf '%s' "$TB_KUBELET_CONFIG_K3S_PATH"
}


# The platform key the reservation table is indexed by: `darwin`, `linux`,
# `linux_k3s` for native k3s, `darwin_k3s` for the macOS node, `windows_k3s` for
# native k3s in tracebloc's WSL distro, or `unknown`. A function, so the bats suite
# can drive the writer as either platform (and as one with no record) on whatever
# host runs the tests.
#
# NOT THE KERNEL NAME (backend#3861). Inside a WSL2 distro `uname -s` is `Linux`,
# so a kernel-name key would select TRACEBLOC_KUBELET_*_LINUX, a row measured on a
# Linux host, for a node inside the WSL2 VM. The measurement harness
# (scripts/tests/measure-node-reservation.sh) stopped believing that rule under
# client#1078; this is the apply side learning the same distinction, through the
# SAME detector (`_probe_wsl`, scripts/lib/probe.sh) rather than a copy of it.
# Inside WSL only native k3s has a key; any other substrate there is `unknown`, a
# run the installer refuses (refuse_wsl_run, common.sh), and no row is measured for
# it.
#
# AN ABSENT DETECTOR IS `unknown`, NEVER `linux`. install-k8s.sh sources probe.sh
# conditionally (a stale bootstrap that did not fetch it still installs), so
# `_probe_wsl` may be undefined here. "Assume linux" is exactly the bug being
# fixed; `unknown` matches no row in the generated table, so the writer emits no
# reservation and the create path says why -- unreserved and honest, the same
# posture as a platform nobody has measured yet.
#
# NATIVE k3s IS ITS OWN KEY, `linux_k3s` (TRACEBLOC_SUBSTRATE_RESOLVED=k3s on Linux outside WSL).
# It is measured on native k3s itself, on Ubuntu 22.04 and 24.04, amd64 and arm64
# (client-dev#1469). The `linux` key was a k3d node on Linux outside WSL, which
# slim client 4.1 retired: its three records went with it, so the table has no
# `linux` row, and k3d on Linux outside WSL is `unknown`, as wherever the create
# path refuses the host (install_linux refuses it first). A run that reached it
# would reserve nothing and say so, never borrow `linux_k3s`, a number measured on
# another substrate (rule 1).
#
# k3s ON A MAC IS `darwin_k3s` (slim client 2.1, tracebloc/client-dev#1615): the node
# is one k3s container in an Apple container VM (mac-container.sh), measured as
# that (scripts/spec/node-reservation/darwin-arm64-k3s.json, on the macOS node).
# It is a Mac's only key: a Mac gets no other substrate since slim client 4.1
# (TB_SUBSTRATE_RETIRED_MACOS, client-dev#1948), so any other one there is `unknown`,
# the answer the measurement harness's own refusal of it agrees with.
#
# k3s INSIDE WSL IS `windows_k3s` in tracebloc's own distro (_probe_wsl_ours,
# client-dev#1810 part 2): the generator's own key for a record the harness stamps
# Windows (a WSL2 shell) on substrate k3s
# (gen-node-reservation-embed.sh --key Windows k3s). Measured in that distro on
# Windows Server 2025 (windows-amd64-wsl2-server-2025-k3s.json, e2e-test-agent run
# 39123145117), so the writer reserves its row as it does linux_k3s's. In any other
# WSL distro it is `unknown`, because the k3s create path refuses that host.
_kubelet_reservation_platform() {
  local kernel
  kernel="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$kernel" == "darwin" ]]; then
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then printf 'darwin_k3s'; else printf 'unknown'; fi
    return 0
  fi
  if [[ "$kernel" != "linux" ]]; then
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then printf '%s' "$kernel"; else printf 'unknown'; fi
    return 0
  fi
  # SILENT here: this function returns a VALUE, and its callers (the writer, the
  # e2e check) read `$output` as a path or a key. The reason `unknown` was
  # selected is spoken once, by the create path below, where a warning belongs.
  declare -F _probe_wsl >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  if _probe_wsl; then
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then _kubelet_reservation_wsl_k3s; else printf 'unknown'; fi
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    printf 'linux_k3s'
  else
    printf 'unknown'
  fi
}

# The key for native k3s inside WSL: `windows_k3s` in tracebloc's own distro, the one
# WSL host the k3s create path serves, through the same predicate it asks
# (_probe_wsl_ours, probe.sh); `unknown` in any other, and when that predicate is
# not loaded (a stale probe.sh cannot tell the distros apart).
_kubelet_reservation_wsl_k3s() {
  if declare -F _probe_wsl_ours >/dev/null 2>&1 && _probe_wsl_ours; then
    printf 'windows_k3s'
  else
    printf 'unknown'
  fi
}

# Does the generated table carry a MEASURED entry for this platform?
_kubelet_reservation_measured() {
  local platforms=" ${TRACEBLOC_KUBELET_RESERVATION_PLATFORMS:-} "
  [[ "$platforms" == *" $1 "* ]]
}

# The warning for a platform with no measured reservation, said ONCE per run
# (backend#2460: the operator is told rather than handed a number borrowed from
# another platform; "cannot tell" is a finding, not a default). Every step that
# learns it calls this, so one install never warns twice about the same node:
# on native k3s the pre-create fit gate. Silent for a measured platform.
_kubelet_reservation_warn_unmeasured() {
  local platform="${1:-$(_kubelet_reservation_platform)}"
  _kubelet_reservation_measured "$platform" && return 0
  [[ -z "${TB_RESERVATION_WARNED:-}" ]] || return 0
  TB_RESERVATION_WARNED=1
  if [[ "$platform" == "unknown" ]] && declare -F tb_substrate_retired_here >/dev/null 2>&1 \
       && tb_substrate_retired_here "${TRACEBLOC_SUBSTRATE_RESOLVED:-}"; then
    # A substrate retired where this run is (k3d, slim client 4.1): the installer
    # refuses it before this runs, so this says so if a caller skipped that refusal.
    warn "No node reservation will be written: this installer no longer sets up ${TRACEBLOC_SUBSTRATE_RESOLVED} $(_tb_substrate_where), so no measured reservation applies to this node."
  elif [[ "$platform" == "unknown" ]] && declare -F _probe_wsl >/dev/null 2>&1; then
    # The detector IS loaded, so not "re-run": `unknown` is a host _probe_wsl takes for
    # WSL, off native k3s in tracebloc's distro. refuse_wsl_run (common.sh) and the k3s
    # create path refuse it on WSL's kernel; WSL's names alone, on another, reach here.
    warn "No node reservation will be written: this host shows WSL's markers, and no reservation is measured for WSL outside native k3s in tracebloc's distro, so allocatable will equal capacity on this node."
    if declare -F _probe_wsl_kernel >/dev/null 2>&1 && ! _probe_wsl_kernel; then
      hint "This kernel is not WSL's: if this host is not WSL, unset WSL_DISTRO_NAME and WSL_INTEROP, then re-run, and its Linux reservation is written."
    fi
  elif [[ "$platform" == "unknown" ]]; then
    # An absent probe.sh (a stale bootstrap that did not fetch it): this Linux
    # kernel cannot be told apart from WSL2, and guessing linux is the defect
    # the detection replaced. Say why, once, here -- not from the selector.
    warn "No node reservation will be written: the host detector (probe.sh) is not loaded, so this Linux kernel cannot be told apart from WSL2 and no platform's measured numbers apply. Allocatable will equal capacity on this node."
    hint "Re-run the installer from a fresh bootstrap so probe.sh is fetched; the reservation is then written for the platform detected."
  else
    warn "No measured node reservation exists for platform '${platform}' ($(uname -s)) yet, so this node's allocatable will equal its capacity -- the training envelope is sized against a number that includes the kubelet and container runtime."
    hint "Measure one with scripts/tests/measure-node-reservation.sh (tracebloc/client) and the installer picks it up."
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
  cpu_var="TRACEBLOC_KUBELET_KUBE_RESERVED_CPU_MILLI_${key}"
  mem_var="TRACEBLOC_KUBELET_KUBE_RESERVED_MEM_MIB_${key}"
  sys_var="TRACEBLOC_KUBELET_SYSTEM_RESERVED_MEM_MIB_${key}"
  local cpu="${!cpu_var:-}" mem="${!mem_var:-}" sys="${!sys_var:-}"
  local v
  for v in "$cpu_var=$cpu" "$mem_var=$mem" "$sys_var=$sys" "TRACEBLOC_KUBELET_EVICTION_MEM_MIB=${TRACEBLOC_KUBELET_EVICTION_MEM_MIB:-}"; do
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
    printf -v line 'evictionHard:\n  memory.available: %sMi\n' "${TRACEBLOC_KUBELET_EVICTION_MEM_MIB}"; out+="$line"
  fi
  printf '%s' "$out"
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
# tests can feed canned input via TRACEBLOC_TTY=/dev/stdin).
: "${TRACEBLOC_TTY:=/dev/tty}"

# True only when $TRACEBLOC_TTY can actually be OPENED for reading. A plain `-r` test is
# not enough: /dev/tty is world-readable even with no controlling terminal (CI,
# `curl|bash`), so `-r` would route those runs into the interactive branch where
# the `read` then fails immediately and the guard aborts with the generic abort
# text instead of the non-interactive guidance that lists --reuse-data/--wipe-data
# (Bugbot #384). Mirrors the openability probe assess.sh already uses.
_tty_usable() { { : <"$TRACEBLOC_TTY"; } 2>/dev/null; }

# Echo each dir under HOST_DATA_DIR that holds real client data — a MySQL data
# dir or a dataset dir with at least one file — across BOTH on-disk layouts:
# flat ($HOST_DATA_DIR/{mysql,data}) and per-release ($HOST_DATA_DIR/<rel>/…).
# Deliberately scoped to HOST_DATA_DIR only: HOST_DATASET_DIR may be a shared
# network mount other tools use, so the guard never scans or touches it. Empty
# dirs, values.yaml and install-*.log are not data and are ignored.
#
# On native k3s (TRACEBLOC_SUBSTRATE_RESOLVED=k3s) the volumes live in local-path's storage path
# instead, so the native scan below runs first; HOST_DATA_DIR is still scanned,
# because data an earlier install left there is stranded either way.
_leftover_data_dirs() {
  local base="${HOST_DATA_DIR:-}" native=""
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    native="$(_leftover_k3s_volume_dirs)"
    [[ -z "$native" ]] || printf '%s\n' "$native"
  fi
  # prepare-host (TB_K3S_PREPARED=1) scans a data dir that is the named user's, made
  # 0700 by their own installer: the administrator running this cannot enter it, and
  # an unreadable base would read as a clean slate. Root reads it instead.
  if [[ "${TB_K3S_PREPARED:-}" == 1 && -n "$base" ]]; then
    _leftover_base_dirs_as_root "$base" "$native"
    return 0
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

# _leftover_base_dirs_as_root BASE NATIVE -- _leftover_data_dirs' base scan, read as
# root through the sudo shadow, for a BASE another user owns (prepare-host). The same
# candidates and the same rules as the scan above: BASE/mysql, BASE/data and the same
# two under each real subdir; no symlinks; a subdir the native scan already named is
# not a second root (NATIVE, one per line); a dir counts when it holds a file, and
# root cannot be refused one. When sudo cannot answer, BASE is echoed itself: data
# nobody could prove absent, never a clean slate. The scan is a fixed script that
# only reads, so --print makes it as this user (_tb_root_reads, word for word).
# shellcheck disable=SC2016  # $1, $2 and the rest are the inner sh's, on purpose
TRACEBLOC_ROOT_SH_LEFTOVER_SCAN='
    b="$1"; native="$2"
    [ -e "$b" ] || exit 0
    [ -d "$b" ] && [ ! -L "$b" ] || { echo "$b"; exit 0; }
    for d in "$b/mysql" "$b/data"; do
      [ -d "$d" ] && [ ! -L "$d" ] && [ -n "$(find "$d" -type f -print -quit 2>&1)" ] && echo "$d"
    done
    for s in "$b"/*/; do
      s="${s%/}"
      [ -d "$s" ] && [ ! -L "$s" ] || continue
      case "$s" in "$b/mysql"|"$b/data") continue ;; esac
      case "
$native
" in *"
$s
"*) continue ;; esac
      for d in "$s/mysql" "$s/data"; do
        [ -d "$d" ] && [ ! -L "$d" ] && [ -n "$(find "$d" -type f -print -quit 2>&1)" ] && echo "$d"
      done
    done
    exit 0'
_leftover_base_dirs_as_root() {
  local out
  out="$(tb_root sh -c "$TRACEBLOC_ROOT_SH_LEFTOVER_SCAN" _ "$1" "$2" 2>/dev/null)" || { printf '%s\n' "$1"; return 0; }
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# _leftover_k3s_present PATH -- `present` or `absent`, read as root through the sudo
# shadow (k3s owns the storage path, and a parent it made 0700 hides PATH from the
# daily user). Empty when root cannot answer, which is "cannot tell", never absent.
_leftover_k3s_present() {
  tb_root sh -c "$TRACEBLOC_ROOT_SH_EXISTS" _ "$1" 2>/dev/null || true
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
  out="$(tb_root find "$storage" -mindepth 1 -maxdepth 1 -type d -name 'pvc-*' ! -empty 2>/dev/null)" || rc=$?
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
# HOST_DATA_DIR, and on native k3s the storage path when a found path is under it.
_leftover_where() {
  local storage="" d in_s=0 in_h=0
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] && storage="$(_native_k3s_storage_path)"
  for d in "$@"; do
    if [[ -n "$storage" && ( "$d" == "$storage" || "$d" == "$storage"/* ) ]]; then in_s=1; else in_h=1; fi
  done
  if (( in_s && in_h )); then printf '%s and %s' "$storage" "$HOST_DATA_DIR"
  elif (( in_s )); then printf '%s' "$storage"
  else printf '%s' "$HOST_DATA_DIR"
  fi
}

# Read one line from $TRACEBLOC_TTY into the named variable, stripping bracketed-paste
# / CSI escape garbage (arrow keys, pastes survive `read -r`) and trimming
# surrounding whitespace — so a paste or a spaces-then-Enter can't smuggle
# control bytes into HOST_DATA_DIR or slip past a non-empty check. Mirrors the
# provision.sh client-name handling (_strip_paste_garbage + trim).
_read_sanitized() {
  local __prompt="$1" __var="$2" __in=""
  read -r -p "$__prompt" __in <"$TRACEBLOC_TTY" || __in=""
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
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
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
    as_root=(tb_root)
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
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
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

  # Native k3s (TRACEBLOC_SUBSTRATE_RESOLVED=k3s) words each line for its own storage: the data
  # lies in the storage path as well as HOST_DATA_DIR (_leftover_where). Under
  # node-local (native_nl) a fresh install gives its volumes new directories, so
  # nothing found is adopted. Under hostpath (client-dev#1782) the chart's PVs name
  # HOST_DATA_DIR itself, so what lies there IS adopted; only a k3s
  # volume (pvc-*) is not.
  local where k3s="" native_nl="" frozen=""
  where="$(_leftover_where "${found[@]}")"  # set-u-safe: the empty-found check above returns first
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] && k3s=1
  [[ -n "$k3s" && "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] && native_nl=1
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
  # prepare-host (TB_K3S_PREPARED=1) runs as an administrator over the data of the
  # user it names: it lists that data but never offers to delete it. --wipe-data is
  # refused before prepare-host writes anything (_native_k3s_prepare_host).
  local wipe=1
  [[ -n "$k3s" && "${TB_K3S_PREPARED:-}" == 1 ]] && wipe=""
  warn "Existing tracebloc data found under ${where}:"
  # vols: a native scan's volume is a pvc-* directory; the data dir scan only ever
  # yields .../mysql and .../data (client-dev#1782).
  local vols="" kept=""
  for d in "${found[@]}"; do hint "  • ${d}"; case "${d##*/}" in pvc-*) vols=1 ;; *) kept=1 ;; esac; done  # set-u-safe: the empty-found check above returns first
  # hostpath on native k3s never mounts a k3s volume, so every line below words what
  # was found (Bugbot on #1790): only k3s volumes (hp_vols=all) and nothing is
  # adopted; k3s volumes beside data under HOST_DATA_DIR (some) and only the data is.
  local hp_vols=""
  if [[ -n "$k3s" && "${TB_STORAGE_MODE:-node-local}" == "hostpath" && -n "$vols" ]]; then
    if [[ -n "$kept" ]]; then hp_vols=some; else hp_vols=all; fi
  fi
  # The "silently adopt" warning is true ONLY for hostpath. Under node-local (the
  # default since D15, client#456) a fresh install does NOT adopt this data — the
  # cluster starts empty in-node and the host data is stranded. Leading with the
  # adopt claim there would contradict the very next line (client#456 Bugbot).
  if [[ -n "$native_nl" ]]; then
    hint "A fresh native k3s install does NOT adopt this data: its volumes get new directories, so the data would be stranded, not used."
  elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    hint "node-local storage keeps data inside the cluster node — a fresh install does NOT adopt this ~/.tracebloc data; it would be stranded, not used."
  elif [[ "$hp_vols" == all ]]; then
    hint "A fresh install does NOT adopt these: they are k3s volumes (pvc-*), and hostpath keeps its data under ${HOST_DATA_DIR}, so they would be stranded, not used."
  else
    hint "A fresh install would silently adopt it, so it would not really be fresh."
    # hostpath never mounts a k3s volume, so one found on native k3s is stranded.
    [[ -z "$k3s" || -z "$vols" ]] \
      || hint "The k3s volumes (pvc-*) among them are not adopted: hostpath keeps its data under ${HOST_DATA_DIR}, so those would be stranded, not used."
  fi

  local action="${TB_LEFTOVER_ACTION:-}"
  if [[ -z "$action" ]]; then
    if _tty_usable; then
      prompt_header "How should the installer handle it?"
      if [[ -n "$native_nl" ]]; then
        hint "  [r] keep  — leave the existing data on disk, unused (a fresh install starts empty; it is NOT adopted)"
      elif [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
        # node-local can't adopt the host data (no /tracebloc bind-mount) — the
        # cluster starts empty in-node — so don't offer "reuse = adopt" here (#367).
        hint "  [r] keep  — leave the existing data on disk, unused (node-local starts empty; it is NOT adopted)"
      elif [[ "$hp_vols" == all ]]; then
        hint "  [r] keep  — leave the k3s volumes on disk, unused (hostpath does not mount them; they are NOT adopted)"
      elif [[ "$hp_vols" == some ]]; then
        hint "  [r] reuse — keep and adopt the data under ${HOST_DATA_DIR}; the k3s volumes stay on disk, NOT adopted"
      else
        hint "  [r] reuse — keep and adopt the existing data"
      fi
      [[ -z "$wipe" ]] || hint "  [w] wipe  — delete it and start fresh"
      [[ -n "$frozen" ]] || hint "  [n] new   — install into a different directory"
      hint "  [a] abort — stop and sort it out myself (default)"
      local reply="" keys="r"
      [[ -z "$wipe" ]] || keys="${keys}/w"
      [[ -n "$frozen" ]] || keys="${keys}/n"
      _read_sanitized "  Choice [${keys}/a]: " reply
      # Accept the word we SHOW: node-local relabels [r] to "keep", so r/reuse AND
      # k/keep must both map to the reuse action or a user typing the shown "keep"
      # would fall through to abort (Bugbot). Lowercase via tr (bash 3.2-safe — no
      # ${x,,}) so any casing works.
      local choice; choice=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
      case "$choice" in
        r|reuse|k|keep) action=reuse ;;
        w|wipe)         if [[ -n "$wipe" ]]; then action=wipe; else action=abort; fi ;;
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
      [[ -n "$native_nl" ]] && reuse_desc="keep the data on disk, NOT adopted (a fresh install starts empty)"
      [[ "$hp_vols" == some ]] && reuse_desc="adopt the data under ${HOST_DATA_DIR}; the k3s volumes (pvc-*) stay on disk, NOT adopted"
      [[ "$hp_vols" == all ]] && reuse_desc="keep the k3s volumes on disk, NOT adopted (hostpath does not mount them)"
      local newdir_line="
  TRACEBLOC_HOST_DATA_DIR=<new-path> ...  install into a different directory"
      [[ -n "$frozen" ]] && newdir_line=""   # config.yaml froze the volumes' directory: the env cannot move them
      local wipe_line="
  --wipe-data                     delete it and start fresh"
      [[ -n "$wipe" ]] || wipe_line=""
      error "Existing data found under ${where} and no choice was given (no terminal). Re-run with one of:
  --reuse-data                    ${reuse_desc}${wipe_line}${newdir_line}
  (or TRACEBLOC_SKIP_LEFTOVER_GUARD=1 to bypass this guard entirely)"
    fi
  fi

  case "$action" in
    reuse)
      if [[ -n "$native_nl" ]]; then
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
      elif [[ "$hp_vols" == all ]]; then
        warn "hostpath can't adopt the k3s volumes under ${where} — it keeps its data under ${HOST_DATA_DIR}."
        hint "They are left on disk, untouched but unused. Re-ingest the data after setup ('tracebloc data ingest')."
        log "hostpath: left the k3s volumes under ${where} on disk (NOT adopted)."
      else
        log "Reusing existing data under ${HOST_DATA_DIR} (user choice)."
        [[ "$hp_vols" != some ]] || log "hostpath: the k3s volumes (pvc-*) found beside it are left on disk (NOT adopted)."
      fi
      ;;
    wipe)
      # Fail closed: if any data survived the wipe, abort rather than fall
      # through to create_cluster, which would adopt the survivors and silently
      # break the "wipe means gone" guarantee.
      if ! _wipe_leftover_data "${found[@]}"; then  # set-u-safe: the empty-found check at the top of this function returns first
        local rm_tail=" ${HOST_DATA_DIR}'"
        [[ -n "$k3s" ]] && rm_tail="' on each path listed above, with k3s stopped"
        local or_dir=", or choose a different directory"
        [[ -n "$frozen" ]] && or_dir=""   # config.yaml froze the volumes' directory: there is no other to choose
        error "Could not fully wipe existing data under ${where} — some files could not be removed (often root/container-owned MySQL files). Remove them manually (e.g. 'sudo rm -rf${rm_tail}) and re-run${or_dir}. Refusing to proceed and adopt the leftovers."
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
      # prepare-host never wipes, so the choice is not on offer and is not named.
      if [[ -n "$frozen" ]]; then
        if [[ -n "$wipe" ]]; then
          error "Aborted — existing data under ${where} left untouched. Choose keep / wipe and re-run."
        else
          error "Aborted — existing data under ${where} left untouched. Choose keep and re-run."
        fi
      elif [[ -n "$wipe" ]]; then
        error "Aborted — existing data under ${where} left untouched. Choose reuse / wipe / a new directory and re-run."
      else
        error "Aborted — existing data under ${where} left untouched. Choose reuse / a new directory and re-run."
      fi
      ;;
  esac
}

# _api_answers [CONTEXT] -- the API answers: on CONTEXT by name when given (native
# k3s asks its own), else on the current context. ONE definition, read by every API
# wait and by assess, so they cannot disagree about what "answers" means.
# --request-timeout bounds the call itself.
_api_answers() {
  kubectl ${1:+--context "$1"} cluster-info --request-timeout=5s &>/dev/null
}

# The API wait budget in seconds: TB_API_WAIT_S when it is a whole number, else 180.
# One reading for every wait (k3s.sh's _native_k3s_wait_for_api, the macOS node's),
# so the documented knob means the same wherever it is read.
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

# ── The local dashboard port ─────────────────────────────────────────────────
# The tracebloc dashboard, open in a browser on this machine, asks the client
# whether the two are on one machine, on 127.0.0.1:TRACEBLOC_LOCAL_API_HOST_PORT.
# The node publishes that host port to the chart's NodePort (localApi.nodePort):
# the macOS node in its run-args (mac-container.sh, _mac_ct_local_api). The chart turns the listener on
# only when this installer says the mapping exists (TB_LOCAL_API_MAPPED=1, read by
# install-client-helm.sh). Bound to 127.0.0.1, so nothing beyond this machine can
# reach it.
#
# Fail-soft everywhere: a port already in use, or one the node will not publish,
# turns the feature off with a warning and never stops the install.
# TRACEBLOC_LOCAL_API=off opts out.
# The defaults are the chart's localApi.hostPort / localApi.nodePort;
# local-api-port.bats holds them to values.yaml.
_TB_LOCAL_API_HOST_PORT_DEFAULT="47910"
_TB_LOCAL_API_NODE_PORT_DEFAULT="30910"
# The NodePort range the chart's values.schema.json allows for localApi.nodePort
# (Kubernetes' default service-node-port-range); local-api-port.bats holds them to
# the schema (client-dev#1688).
_TB_LOCAL_API_NODE_PORT_MIN="30000"
_TB_LOCAL_API_NODE_PORT_MAX="32767"
# Overridable, for a host whose 47910 is spoken for, and resolved IN PLACE: the
# TRACEBLOC_ name is both the env input and the value every reader reads
# (backend#3846 folded the TB_-prefixed internal copies into it; TB_ is banned).
TRACEBLOC_LOCAL_API_HOST_PORT="${TRACEBLOC_LOCAL_API_HOST_PORT:-$_TB_LOCAL_API_HOST_PORT_DEFAULT}"
TRACEBLOC_LOCAL_API_NODE_PORT="${TRACEBLOC_LOCAL_API_NODE_PORT:-$_TB_LOCAL_API_NODE_PORT_DEFAULT}"
TB_LOCAL_API_MAPPED=0

_local_api_wanted() {
  case "$(printf '%s' "${TRACEBLOC_LOCAL_API:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) return 1 ;;
  esac
  return 0
}

# Whether something on this machine already listens on the host port. A
# connect that succeeds means busy; bash's /dev/tcp works in 3.2 as well.
# Bounded (client-dev#1664): /dev/tcp has no connect timeout of its own, so a
# listener whose backlog is full -- a SYN nobody answers -- held the install for
# the kernel's whole SYN-retry window. The deadline (1 s) reads as "not busy".
_local_api_host_port_busy() {
  _bounded 1 "${BASH:-bash}" -c \
    'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "${TRACEBLOC_LOCAL_API_HOST_PORT}" 2>/dev/null
}

# Whether both ports are ones the install can take (digits only): the host port
# any TCP port (1..65535), the node port one the chart's schema accepts
# (30000..32767) -- anything else reaches the node and fails `helm install` on
# localApi.nodePort (client-dev#1688). The overrides are free text; a bad one must
# turn the feature off, never reach the node's create and fail the install
# (client-dev#1665).
_local_api_port_valid() {
  local p="$TRACEBLOC_LOCAL_API_HOST_PORT" n="$TRACEBLOC_LOCAL_API_NODE_PORT"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
  [[ "$n" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$n >= _TB_LOCAL_API_NODE_PORT_MIN && 10#$n <= _TB_LOCAL_API_NODE_PORT_MAX )) || return 1
  return 0
}

# _local_api_busy_warn -- the host port is taken: the one wording of it, for the
# macOS node's publish (mac-container.sh, _mac_ct_local_api).
_local_api_busy_warn() {
  warn "Port ${TRACEBLOC_LOCAL_API_HOST_PORT} on 127.0.0.1 is already in use, so the dashboard won't be able to tell it is on this machine. Everything else works; free the port and re-run the installer to turn it on."
}

_local_api_invalid_warn() {
  warn "The local dashboard port settings (TRACEBLOC_LOCAL_API_HOST_PORT=${TRACEBLOC_LOCAL_API_HOST_PORT}, TRACEBLOC_LOCAL_API_NODE_PORT=${TRACEBLOC_LOCAL_API_NODE_PORT}) are not valid port numbers, so the dashboard won't be able to tell it is on this machine. Everything else works; set the host port to a number from 1 to 65535 and the node port to one from ${_TB_LOCAL_API_NODE_PORT_MIN} to ${_TB_LOCAL_API_NODE_PORT_MAX}, then re-run the installer to turn it on."
}

# ── The substrate dispatcher ─────────────────────────────────────────────────

# create_cluster -- step c: set up the substrate this run resolved (TRACEBLOC_SUBSTRATE_RESOLVED).
# The ONE switch: native k3s's create path lives in k3s.sh. A value with no arm is
# refused by name and never routed to a default (fail closed): main() refuses it before
# this point, so reaching here with one means a caller skipped that refusal.
create_cluster() {
  case "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" in
    k3s) _native_k3s_create_cluster ;;
    *) error "create_cluster: TRACEBLOC_SUBSTRATE='${TRACEBLOC_SUBSTRATE_RESOLVED:-}' names no runtime this installer can create, so nothing was created." ;;
  esac
}
