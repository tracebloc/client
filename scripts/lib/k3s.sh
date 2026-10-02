#!/usr/bin/env bash
# =============================================================================
#  k3s.sh — native k3s install mechanics: k3s on the host, no k3d, no Docker
#           (RFC-0175 D4; slim client Stage 1, 1.1b)
#
#  NOT REACHABLE YET. install.sh and gen-manifest.sh do not list this file and
#  install-k8s.sh does not source it, so no customer install can call anything
#  here; k3s.bats' tripwire holds all three, and 1.1e wires it in and deletes the
#  tripwire. Until then only guards and bats files load it.
#
#  What is here, and what is not:
#    - the pins: the release tag DERIVED from K8S_VERSION, and the three digests
#      common.sh stamps from facts.env (TB_K3S_BIN_SHA256_* / TB_K3S_INSTALL_SH_SHA256);
#    - the verified downloads of the binary and of upstream's install.sh at the tag,
#      and the scrubbed run of that script (INSTALL_K3S_SKIP_DOWNLOAD=binary);
#    - /etc/rancher/k3s/config.yaml, rendered pure and written as root with an
#      explicit mode, beside the kubelet drop-in and registries.yaml that cluster.sh
#      renders for both substrates;
#    - the frozen node name, the pod/service range pair, the cgroup read;
#    - the kubeconfig merge and the API wait.
#    The order these run in, the substrate switch and the record writes are 1.1e.
#
#  Every function carries the `_native_k3s_` prefix (decided 2026-10-01): k3d.sh
#  already has four `_k3s_*` helpers that read k3s INSIDE a k3d node, and a Stage 4
#  grep for k3d code must never meet a k3d name here, or the reverse.
#
#  bash 3.2-safe although native k3s is Linux-only: the macOS unit job sources this
#  file in k3s.bats. No `${x,,}`, no `declare -A`, no `mapfile`.
#
#  Sourcing it has no side effects: constants and functions only, and nothing at
#  the top level calls common.sh. check-facts.sh sources it alone, to derive the
#  release tag and the asset URLs the same way the installer does.
# =============================================================================

# Where k3s reads its configuration, and what it writes. Fixed by upstream.
TB_K3S_ETC_DIR="/etc/rancher/k3s"
TB_K3S_CONFIG_PATH="${TB_K3S_ETC_DIR}/config.yaml"
TB_K3S_REGISTRIES_PATH="${TB_K3S_ETC_DIR}/registries.yaml"
TB_K3S_KUBECONFIG_PATH="${TB_K3S_ETC_DIR}/k3s.yaml"
# The corporate CA, copied next to the file that names it. NOT the operator's own
# path: a bundle under /tmp or in a home directory can move or vanish, and k3s
# re-reads registries.yaml on every start -- the same reason the kubelet drop-in
# is not under /tmp (cluster.sh).
TB_K3S_CA_PATH="${TB_K3S_ETC_DIR}/tracebloc-ca.pem"
# Where the binary goes. upstream's install.sh looks for it in the same place
# (BIN_DIR=/usr/local/bin) when it is told to skip the download.
# shellcheck disable=SC2034  # the DEST 1.1e's install flow passes to _native_k3s_fetch_binary
TB_K3S_BIN_PATH="/usr/local/bin/k3s"
# The pod and service ranges, in the order they are tried: k3s's own defaults, then
# the fixed fallback pair (decided 2026-10-01), which sits inside the chart's
# networkPolicy.training.clusterCidrs (172.16/12) and inside the RFC1918 entries of
# cluster.sh's TB_NO_PROXY_DEFAULTS, and out of 10/8. k3s.bats derives both from
# those two declarations and holds each pair inside them.
TB_K3S_CIDR_PAIRS=("10.42.0.0/16 10.43.0.0/16" "172.16.0.0/17 172.16.128.0/17")

# ── Pins ──────────────────────────────────────────────────────────────────────

# _native_k3s_release_tag [K8S_VERSION] -- the k3s release tag for a k3s image tag:
# v1.36.3-k3s1 -> v1.36.3+k3s1. The ONE derivation; check-facts.sh --check-published
# calls it too, so the release it checks is the release the installer fetches.
# Refuses (return 1, and says why) anything that is not a k3s image tag.
_native_k3s_release_tag() {
  local v="${1:-${K8S_VERSION:-}}" re='^v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+$'
  if [[ ! "$v" =~ $re ]]; then
    echo "native k3s: '${v}' is not a k3s image tag (vX.Y.Z-k3sN), so no k3s release can be derived from it" >&2
    return 1
  fi
  printf '%s' "${v%-k3s*}+k3s${v##*-k3s}"
}

# _native_k3s_check_version -- refuse, by name, a K8S_VERSION that is not the pin.
# k3d honours a K8S_VERSION override (common.sh); native k3s cannot, because the
# binary is checked against a digest and common.sh stamps digests for the pinned
# version only.
_native_k3s_check_version() {
  [[ -n "${TB_K3S_PIN_K8S_VERSION:-}" ]] \
    || error "native k3s: no pinned k3s version is stamped in common.sh (TB_K3S_PIN_K8S_VERSION) -- run scripts/check-facts.sh --write."
  [[ "${K8S_VERSION:-}" == "$TB_K3S_PIN_K8S_VERSION" ]] && return 0
  error "K8S_VERSION=${K8S_VERSION:-<empty>} cannot be installed as native k3s: this installer pins the k3s binary by digest, and the only version it has a digest for is ${TB_K3S_PIN_K8S_VERSION}. Unset K8S_VERSION to install ${TB_K3S_PIN_K8S_VERSION}."
}

# _native_k3s_binary_asset ARCH -- the release asset name for ARCH (amd64 / arm64).
_native_k3s_binary_asset() {
  case "${1:-}" in
    amd64) printf 'k3s' ;;
    arm64) printf 'k3s-arm64' ;;
    *) echo "native k3s: no k3s release binary for architecture '${1:-}' (amd64 or arm64)" >&2; return 1 ;;
  esac
}

# _native_k3s_binary_sha256 ARCH -- the pinned digest of that asset.
_native_k3s_binary_sha256() {
  case "${1:-}" in
    amd64) printf '%s' "${TB_K3S_BIN_SHA256_AMD64:-}" ;;
    arm64) printf '%s' "${TB_K3S_BIN_SHA256_ARM64:-}" ;;
    *) echo "native k3s: no pinned k3s digest for architecture '${1:-}'" >&2; return 1 ;;
  esac
}

# _native_k3s_release_url ASSET [K8S_VERSION] -- a release asset's download URL.
# The `+` stays literal: it is a path character, and GitHub serves it as one.
_native_k3s_release_url() {
  local tag
  tag="$(_native_k3s_release_tag "${2:-}")" || return 1
  printf 'https://github.com/k3s-io/k3s/releases/download/%s/%s' "$tag" "$1"
}

# _native_k3s_install_script_url [K8S_VERSION] -- upstream's install.sh AT THE TAG.
# The release does not attach install.sh (measured on v1.36.3+k3s1), and get.k3s.io
# serves the tip of master, which moves under any pin -- so the tagged blob, from
# raw.githubusercontent.com.
_native_k3s_install_script_url() {
  local tag
  tag="$(_native_k3s_release_tag "${1:-}")" || return 1
  printf 'https://raw.githubusercontent.com/k3s-io/k3s/%s/install.sh' "$tag"
}

# ── Downloads ─────────────────────────────────────────────────────────────────

# _native_k3s_fetch_binary ARCH DEST -- download the k3s binary for ARCH, verify it
# against the pinned digest, and install it at DEST as root, mode 0755. A mismatch is
# refused by name and nothing is installed. Same bounds as setup-linux.sh's
# _fetch_kubectl: a stall floor, not a hard deadline, on a ~75 MB binary.
_native_k3s_fetch_binary() {
  local arch="$1" dest="$2" asset want url tmpdir
  asset="$(_native_k3s_binary_asset "$arch")" || error "native k3s: cannot install k3s on architecture '${arch}' (amd64 or arm64)."
  want="$(_native_k3s_binary_sha256 "$arch")"
  [[ -n "$want" ]] || error "native k3s: no pinned digest for the ${arch} k3s binary is stamped in common.sh -- run scripts/check-facts.sh --write."
  url="$(_native_k3s_release_url "$asset")" || error "native k3s: cannot derive the k3s release from K8S_VERSION=${K8S_VERSION:-<empty>}."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-bin-XXXXXX")" || error "native k3s: could not create a temporary directory for the k3s download."
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "$url" -o "${tmpdir}/k3s" \
    || { rm -rf "$tmpdir"; error "Couldn't download the k3s binary from ${url}. Check that this machine can reach github.com and release-assets.githubusercontent.com, then re-run."; }
  _assert_download_size "${tmpdir}/k3s" 20000000 "k3s" "$tmpdir"
  _verify_sha256 "$want" "${tmpdir}/k3s" \
    || { rm -rf "$tmpdir"; error "The k3s binary downloaded from ${url} does not match its pinned sha256 (${want}), so it was not installed. Something between this machine and GitHub changed the file; do not install it by hand. Re-run on a network that does not rewrite downloads."; }
  sudo install -m 0755 "${tmpdir}/k3s" "$dest" \
    || { rm -rf "$tmpdir"; error "Couldn't install the k3s binary at ${dest}."; }
  rm -rf "$tmpdir"
}

# _native_k3s_fetch_install_script DEST -- download upstream's install.sh at the
# release tag to DEST (a file the caller owns), verified against the pinned digest.
_native_k3s_fetch_install_script() {
  local dest="$1" want="${TB_K3S_INSTALL_SH_SHA256:-}" url
  [[ -n "$want" ]] || error "native k3s: no pinned digest for k3s's install.sh is stamped in common.sh -- run scripts/check-facts.sh --write."
  url="$(_native_k3s_install_script_url)" || error "native k3s: cannot derive the k3s release from K8S_VERSION=${K8S_VERSION:-<empty>}."
  retry 3 5 curl_secure -fsSL "$url" -o "$dest" \
    || error "Couldn't download k3s's install script from ${url}. Check that this machine can reach raw.githubusercontent.com, then re-run."
  # 37 KB at v1.36.3+k3s1; an error page or a truncated stream is far shorter.
  _assert_download_size "$dest" 10000 "k3s install.sh"
  _verify_sha256 "$want" "$dest" \
    || { rm -f "$dest"; error "k3s's install script downloaded from ${url} does not match its pinned sha256 (${want}), so it was not run. Something between this machine and GitHub changed the file. Re-run on a network that does not rewrite downloads."; }
}

# _native_k3s_run_install_script SCRIPT -- run upstream's install.sh as root over the
# binary _native_k3s_fetch_binary placed, in a SCRUBBED environment: only PATH, HOME,
# INSTALL_K3S_SKIP_DOWNLOAD=binary (decided 2026-10-01) and the node proxy variables.
#
#   - The scrub is what makes this a single server by construction: install.sh turns
#     the node into an AGENT when K3S_URL is set, and reads K3S_TOKEN, INSTALL_K3S_*
#     and K3S_* from whatever environment it inherits.
#   - It also hands the script EXACTLY the proxy variables cluster.sh's _node_proxy_env
#     gives a k3d node: install.sh rewrites /etc/systemd/system/k3s.service.env from
#     its own environment on every run (K3S_*, CONTAINERD_* and the proxy variables,
#     mode 0600), and that file is native k3s's proxy home (RFC-0175 D4).
#   - `binary`, not `true`: the script skips only the binary, so on an EL host it still
#     installs the k3s-selinux policy from rpm.rancher.io.
#   - HOME=/root: the script runs as root, and nothing it writes may land, root-owned,
#     in the daily user's home.
_native_k3s_run_install_script() {
  local script="$1" pair
  local -a env_args=(
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "HOME=/root"
    "INSTALL_K3S_SKIP_DOWNLOAD=binary"
  )
  while IFS= read -r pair; do
    [[ -n "$pair" ]] && env_args+=("$pair")
  done <<<"$(_node_proxy_env)"
  # Bounded and cut off from stdin. On an EL host the script still fetches the
  # k3s-selinux RPM from rpm.rancher.io, and a wedged mirror would otherwise hang a
  # headless install in silence. Under `curl | bash` stdin is the installer itself,
  # which the child must not read; a sudo password prompt reads /dev/tty, not stdin.
  # `timeout` sits AFTER `env -i` because _bounded would exec the binary `sudo`,
  # bypassing a root-aware sudo(). It is resolved HERE, on the caller's PATH, and run
  # by absolute path: env -i resets PATH to the fixed one above, which would not find
  # a timeout(1) installed anywhere else, and env would then fail 127 on an install
  # that checked for it. No timeout(1) is no bound.
  local -a bound=()
  local tmo; tmo="$(command -v timeout 2>/dev/null)" || tmo=""
  if [[ "$tmo" == /* ]]; then bound=("$tmo" 600); fi
  # set-u-safe: env_args is seeded with PATH, HOME and the skip flag; bound may be empty
  sudo env -i "${env_args[@]}" ${bound[@]+"${bound[@]}"} sh "$script" </dev/null
}

# ── config.yaml ───────────────────────────────────────────────────────────────

# _native_k3s_render_config MODE NODE_NAME CIDR_PAIR STORAGE_PATH CGROUP
#   -- print /etc/rancher/k3s/config.yaml. PURE: no reads, no writes, one fixed format.
#   MODE          TB_STORAGE_MODE. Only node-local: the native path has no hostpath
#                 mode (1.1e), so hostpath is refused by name.
#   NODE_NAME     _native_k3s_node_name's answer.
#   CIDR_PAIR     "<cluster-cidr> <service-cidr>", _native_k3s_pick_cidrs's answer.
#   STORAGE_PATH  empty for k3s's default (/var/lib/rancher/k3s/storage, decided
#                 2026-10-01), else the installer's explicit data dir. It becomes
#                 `default-local-storage-path`, NEVER k3s's own `data-dir` -- the
#                 installer's --data-dir and k3s's --data-dir are different things.
#   CGROUP        v1 or v2. `fail-cgroupv1=false` only on v1: the kubelet refuses a
#                 v1 host by default since 1.35, and on v2 the flag says nothing.
# It never emits `server:` or `token:` -- this node is a server, alone.
_native_k3s_render_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" cluster_cidr service_cidr kubelet_args
  case "$mode" in
    node-local) ;;
    hostpath) echo "native k3s: TB_STORAGE_MODE=hostpath is not supported on native k3s; it keeps datasets in k3s's local-path storage (node-local)." >&2; return 1 ;;
    *) echo "native k3s: '${mode}' is not a storage mode (node-local)." >&2; return 1 ;;
  esac
  [[ -n "$name" ]] || { echo "native k3s: no node name to render." >&2; return 1; }
  cluster_cidr="${cidrs%% *}"; service_cidr="${cidrs#* }"
  if [[ -z "$cidrs" || "$cluster_cidr" == "$cidrs" || -z "$service_cidr" || "$service_cidr" == *" "* ]]; then
    echo "native k3s: '${cidrs}' is not a '<cluster-cidr> <service-cidr>' pair." >&2; return 1
  fi
  if [[ -n "$storage" ]]; then
    [[ "$storage" == /* ]] || { echo "native k3s: the data dir '${storage}' is not an absolute path." >&2; return 1; }
    ! _tb_system_path "$storage" || { echo "native k3s: the data dir '${storage}' is a system path." >&2; return 1; }
  fi
  case "$cgroup" in
    v2) kubelet_args="\"config=${TB_KUBELET_CONFIG_K3S_PATH}\"" ;;
    v1) kubelet_args="\"config=${TB_KUBELET_CONFIG_K3S_PATH}\", \"fail-cgroupv1=false\"" ;;
    *) echo "native k3s: '${cgroup}' is not a cgroup version (v1 or v2)." >&2; return 1 ;;
  esac
  printf '# Written by the tracebloc installer (scripts/lib/k3s.sh); a re-run rewrites it.\n'
  printf '# node-name and the two CIDRs are read back from here and never change.\n'
  printf 'disable: [traefik, servicelb]\n'
  printf 'disable-helm-controller: true\n'
  printf 'disable-cloud-controller: true\n'
  printf 'node-name: "%s"\n' "$name"
  printf 'cluster-cidr: "%s"\n' "$cluster_cidr"
  printf 'service-cidr: "%s"\n' "$service_cidr"
  printf 'write-kubeconfig-mode: "0600"\n'
  printf 'kubelet-arg: [%s]\n' "$kubelet_args"
  if [[ -n "$storage" ]]; then
    printf 'default-local-storage-path: "%s"\n' "$storage"
  fi
}

# _native_k3s_install_file MODE DEST BODY -- write BODY (plus a newline) to DEST as
# root, mode MODE, never through the umask: the core runs under `umask 077`
# (common.sh), which a `sudo tee` inherits, so a file written without a mode comes out
# 0600 and a directory 0700. A DEST whose content already equals BODY is left alone.
_native_k3s_install_file() {
  local mode="$1" dest="$2" body="$3" have tmp
  if have="$(sudo cat "$dest" 2>/dev/null)" && [[ "$have" == "$body" ]]; then
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/tracebloc-k3s-XXXXXX")" || return 1
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# _native_k3s_cgroup_v1_notice -- on a cgroup v1 host k3s runs with the kubelet's
# fail-cgroupv1=false (the render's v1 arm); say so, beside the remedy that moves
# the host to cgroup v2, an IT step and a reboot. Measured on RHEL 8.10 (S-R2,
# tracebloc/backend#5072): v1 with the flag passes, and so does v2 after grubby.
# Main shell only: it prints.
_native_k3s_cgroup_v1_notice() {
  warn "This machine runs cgroup v1, which Kubernetes is retiring. k3s runs on it with the kubelet's fail-cgroupv1=false."
  if has grubby; then
    hint "To move it to cgroup v2 (an IT step, then a reboot): sudo grubby --update-kernel=ALL --args=\"systemd.unified_cgroup_hierarchy=1\""
  else
    hint "To move it to cgroup v2 (an IT step, then a reboot): add systemd.unified_cgroup_hierarchy=1 to the kernel command line."
  fi
}

# _native_k3s_write_config MODE NODE_NAME CIDR_PAIR STORAGE_PATH CGROUP [CA_FILE]
#   -- write everything k3s reads at start, as root, with an explicit mode on every
#   path: /etc/rancher and /etc/rancher/k3s 0755; config.yaml 0600 (it names the
#   node and the ranges, and k3s keeps its own secrets beside it); the kubelet
#   drop-in 0644 (the e2e readback reads it unprivileged); and, when CA_FILE is
#   given, the CA 0644 and registries.yaml 0600.
_native_k3s_write_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" ca="${6:-}" cfg kubelet ca_body
  cfg="$(_native_k3s_render_config "$mode" "$name" "$cidrs" "$storage" "$cgroup")" || return 1
  [[ "$cgroup" != v1 ]] || _native_k3s_cgroup_v1_notice
  kubelet="$(_render_kubelet_config)" || return 1
  sudo install -d -m 0755 /etc/rancher || return 1
  sudo install -d -m 0755 "$TB_K3S_ETC_DIR" || return 1
  _native_k3s_install_file 0600 "$TB_K3S_CONFIG_PATH" "$cfg" || return 1
  _native_k3s_install_file 0644 "$TB_KUBELET_CONFIG_K3S_PATH" "$kubelet" || return 1
  if [[ -n "$ca" ]]; then
    ca_body="$(cat "$ca")" || return 1
    _native_k3s_install_file 0644 "$TB_K3S_CA_PATH" "$ca_body" || return 1
    _native_k3s_install_file 0600 "$TB_K3S_REGISTRIES_PATH" "$(_render_registries_config "$TB_K3S_CA_PATH")" || return 1
  fi
}

# _native_k3s_config_value KEY [FILE] -- KEY's value in an existing config.yaml, quotes
# stripped; empty when the file has no such key. Returns 2 when FILE exists but cannot
# be read: a value that is there and unreadable is "cannot tell", never "absent".
_native_k3s_config_value() {
  local key="$1" cfg="${2:-$TB_K3S_CONFIG_PATH}" body line
  if ! sudo test -e "$cfg"; then
    # `test -e` fails for a missing file AND for a sudo that did not run: only a root
    # read of a path that always exists tells them apart. sudo down is "cannot tell".
    sudo test -d / || return 2
    return 0
  fi
  body="$(sudo cat "$cfg")" || return 2
  line="$(printf '%s\n' "$body" | sed -n "s/^${key}:[[:space:]]*//p")"
  line="${line%%$'\n'*}"
  line="${line#\"}"; line="${line%\"}"
  printf '%s' "$line"
}

# ── Node name ─────────────────────────────────────────────────────────────────

# _native_k3s_sanitize_node_name RAW -- RAW as a DNS-1123 subdomain, which is what
# Kubernetes takes as a node name: lowercased (by `tr`; bash 3.2 has no `${x,,}`),
# every other character outside [a-z0-9.-] made '-', each dot-separated label trimmed
# of leading and trailing '-' and cut to 63, empty labels dropped, the whole cut to
# 253. Empty when nothing usable is left.
_native_k3s_sanitize_node_name() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-' | awk -F. '{
    out = ""
    for (i = 1; i <= NF; i++) {
      l = $i; sub(/^-+/, "", l); l = substr(l, 1, 63); sub(/-+$/, "", l)
      if (l != "") out = out (out == "" ? "" : ".") l
    }
    out = substr(out, 1, 253); sub(/[.-]+$/, "", out)
    printf "%s", out
  }'
}

# _native_k3s_node_name [CONFIG] -- the node name, FROZEN at first install (RFC-0175
# D4, decision 8): local-path volumes are pinned to it, so a later rename would strand
# them. Once CONFIG (config.yaml) names a node, that name is returned and the hostname
# is never read again. Otherwise the lowercased hostname, sanitised, and both names
# logged. Never a constant: the environment switcher shows it (backend#4346).
_native_k3s_node_name() {
  local cfg="${1:-$TB_K3S_CONFIG_PATH}" have rc=0 raw name
  have="$(_native_k3s_config_value node-name "$cfg")" || rc=$?
  [[ "$rc" -eq 0 ]] || error "native k3s: ${cfg} exists but could not be read, so the node name it froze cannot be kept. Check it with 'sudo cat ${cfg}', then re-run."
  if [[ -n "$have" ]]; then
    printf '%s\n' "$have"
    return 0
  fi
  raw="$(hostname 2>/dev/null || uname -n)"
  name="$(_native_k3s_sanitize_node_name "$raw")"
  [[ -n "$name" ]] || error "native k3s: this machine's hostname '${raw}' has nothing a Kubernetes node name can use. Give the machine a hostname with letters or digits, then re-run."
  if [[ "$name" == "$raw" ]]; then
    log "native k3s node name: '${name}' (the hostname)."
  else
    log "native k3s node name: '${name}' (the hostname '${raw}', made a valid Kubernetes name)."
  fi
  printf '%s\n' "$name"
}

# ── Pod and service ranges ────────────────────────────────────────────────────

# _native_k3s_host_routes -- the host's IPv4 routes, as `ip -4 route show` prints
# them. TB_K3S_ROUTES_STUB is the TEST SEAM: a file whose lines replace the command.
_native_k3s_host_routes() {
  if [[ -n "${TB_K3S_ROUTES_STUB:-}" ]]; then
    cat "$TB_K3S_ROUTES_STUB"
    return
  fi
  ip -4 route show
}

# _native_k3s_cidr_overlap A B -- true when the IPv4 ranges A and B share an address.
# A bare address is a /32. Returns 2 when either cannot be read as a range.
_native_k3s_cidr_overlap() {
  local a="$1" b="$2" an bn al=32 bl=32 m mask
  [[ "$a" == */* ]] && al="${a#*/}"
  [[ "$b" == */* ]] && bl="${b#*/}"
  an="$(_ipv4_to_int "${a%/*}")" || return 2
  bn="$(_ipv4_to_int "${b%/*}")" || return 2
  [[ "$al" =~ ^[0-9]+$ && "$bl" =~ ^[0-9]+$ ]] || return 2
  (( al <= 32 && bl <= 32 )) || return 2
  m=$(( al < bl ? al : bl ))
  mask=0
  (( m > 0 )) && mask=$(( (0xFFFFFFFF << (32 - m)) & 0xFFFFFFFF ))
  (( (an & mask) == (bn & mask) ))
}

# _native_k3s_pick_cidrs [CONFIG] -- the "<cluster-cidr> <service-cidr>" pair for this
# host. An existing CONFIG keeps its pair: pods and services already carry addresses
# from it. Otherwise the first pair in TB_K3S_CIDR_PAIRS that no host route overlaps --
# on native Linux the pod routes land on the host, so a collision misroutes the host's
# own traffic. When every pair overlaps a route, the install is refused and the routes
# are named; so is a route this cannot read.
_native_k3s_pick_cidrs() {
  local cfg="${1:-$TB_K3S_CONFIG_PATH}" have_c have_s rc=0 routes pair dest cidr hits all="" line f1 f2 rest
  have_c="$(_native_k3s_config_value cluster-cidr "$cfg")" || rc=$?
  [[ "$rc" -eq 0 ]] && { have_s="$(_native_k3s_config_value service-cidr "$cfg")" || rc=$?; }
  [[ "$rc" -eq 0 ]] || error "native k3s: ${cfg} exists but could not be read, so the pod and service ranges it holds cannot be kept. Check it with 'sudo cat ${cfg}', then re-run."
  if [[ -n "$have_c" && -n "${have_s:-}" ]]; then
    printf '%s %s\n' "$have_c" "$have_s"
    return 0
  fi
  routes="$(_native_k3s_host_routes)" || error "native k3s: couldn't read this machine's routes (ip -4 route show), so it cannot tell which pod and service ranges are free. Install iproute2, then re-run."
  for pair in "${TB_K3S_CIDR_PAIRS[@]}"; do  # set-u-safe: TB_K3S_CIDR_PAIRS is a file-scope constant
    hits=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # A multipath route continues on indented `nexthop via ...` lines: its
      # destination is on the line above, which was already checked.
      [[ "$line" == [[:space:]]* || "$line" == nexthop* ]] && continue
      # The destination is the first field, or the second after a route type.
      read -r f1 f2 rest <<<"$line"
      case "$f1" in
        unicast|local|broadcast|multicast|throw|unreachable|prohibit|blackhole|nat) dest="${f2:-}" ;;
        *) dest="$f1" ;;
      esac
      [[ "$dest" == "default" || -z "$dest" ]] && continue
      for cidr in $pair; do
        rc=0
        _native_k3s_cidr_overlap "$cidr" "$dest" || rc=$?
        case "$rc" in
          0) hits="${hits:+${hits}, }${dest} (overlaps ${cidr})"; break ;;
          1) ;;
          *) error "native k3s: couldn't read the host route '${line}', so it cannot tell whether it overlaps ${cidr}. Refusing to guess." ;;
        esac
      done
    done <<<"$routes"
    if [[ -z "$hits" ]]; then
      log "native k3s pod and service ranges: ${pair% *} and ${pair#* }."
      printf '%s\n' "$pair"
      return 0
    fi
    all="${all:+${all}; }${pair}: ${hits}"
  done
  error "native k3s: every pod and service range this installer can use overlaps a route on this machine (${all}). Free one of those ranges, then re-run."
}

# _native_k3s_cgroup_version -- v2 when the unified hierarchy is mounted at the
# cgroup root (it has cgroup.controllers), else v1, which covers hybrid hosts too.
# TB_K3S_CGROUP_ROOT is the TEST SEAM: point it at a directory with or without that file.
_native_k3s_cgroup_version() {
  if [[ -f "${TB_K3S_CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" ]]; then
    printf 'v2'
  else
    printf 'v1'
  fi
}

# ── kubeconfig and the API ────────────────────────────────────────────────────

# _native_k3s_rename_kubeconfig CONTEXT -- stdin k3s.yaml, stdout the same with its
# `default` cluster, user and context, and the current-context, renamed CONTEXT. Every
# k3s names all three `default`, so a merge without the rename would collide with any
# other tool's `default` in the user's kubeconfig. Returns 1 when any `default` name is
# left, or when the current context did not become CONTEXT: a file of another shape
# is not one this can vouch for.
_native_k3s_rename_kubeconfig() {
  local ctx="$1" out
  out="$(sed -e "s/^\(  name: \)default\$/\1${ctx}/" \
             -e "s/^\(    cluster: \)default\$/\1${ctx}/" \
             -e "s/^\(    user: \)default\$/\1${ctx}/" \
             -e "s/^\(- name: \)default\$/\1${ctx}/" \
             -e "s/^\(current-context: \)default\$/\1${ctx}/")" || return 1
  if printf '%s\n' "$out" | grep -E '^([ -]*name|[ ]*cluster|[ ]*user|current-context): *default$' >/dev/null; then
    return 1
  fi
  case $'\n'"$out"$'\n' in
    *$'\n'"current-context: ${ctx}"$'\n'*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# _native_k3s_merge_kubeconfig -- merge k3s's kubeconfig into the daily user's, as
# context k3s-<CLUSTER_NAME> (decided 2026-10-01; it mirrors k3d's k3d-<name>), make it
# current, and set TB_KUBE_CONTEXT. The target is the one k3d's merge writes:
# the first entry of KUBECONFIG, else ~/.kube/config. It is written by this (the
# daily user's) process, mode 0600, so the user owns it; k3s's own copy stays root's.
#
# Merged by `$TB_K3S_BIN_PATH kubectl config view --flatten` with the RENAMED file FIRST in
# KUBECONFIG: the first file wins a conflict, so a re-install's fresh credentials
# replace the previous install's, and its current-context becomes the user's.
_native_k3s_merge_kubeconfig() {
  local ctx="k3s-${CLUSTER_NAME}" target td prev_ctx=""
  target="${KUBECONFIG:-${HOME}/.kube/config}"; target="${target%%:*}"
  # What kubectl pointed at before this install, so the summary can say how to switch
  # back (k3d's merge does the same). Read before the merge changes it; a read that
  # fails or times out is "no previous context", never a failed install. The read
  # names the user's kubeconfig: with KUBECONFIG unset, k3s's kubectl reads
  # /etc/rancher/k3s/k3s.yaml (context `default`) and never ~/.kube/config.
  TB_PREV_KUBE_CONTEXT=""
  prev_ctx="$(_bounded 10 env KUBECONFIG="${KUBECONFIG:-$target}" "$TB_K3S_BIN_PATH" kubectl config current-context 2>/dev/null)" || prev_ctx=""
  prev_ctx="${prev_ctx//[$'\r\n']/}"
  td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-kc-XXXXXX")" || error "native k3s: could not create a temporary directory for the kubeconfig merge."
  # Read as root, written as the user: the redirect is meant to stay outside sudo.
  # shellcheck disable=SC2024
  sudo cat "$TB_K3S_KUBECONFIG_PATH" > "${td}/k3s.yaml" \
    || { rm -rf "$td"; error "native k3s: couldn't read ${TB_K3S_KUBECONFIG_PATH}; k3s writes it when it starts. Check 'sudo systemctl status k3s', then re-run."; }
  _native_k3s_rename_kubeconfig "$ctx" < "${td}/k3s.yaml" > "${td}/renamed.yaml" \
    || { rm -rf "$td"; error "native k3s: ${TB_K3S_KUBECONFIG_PATH} is not the shape k3s writes (one cluster, user and context, all named 'default'), so it was not merged into ${target}."; }
  mkdir -p "$(dirname "$target")" \
    || { rm -rf "$td"; error "native k3s: couldn't create $(dirname "$target")."; }
  KUBECONFIG="${td}/renamed.yaml:${target}" "$TB_K3S_BIN_PATH" kubectl config view --flatten > "${td}/merged.yaml" \
    || { rm -rf "$td"; error "native k3s: couldn't merge the k3s kubeconfig into ${target}."; }
  install -m 0600 "${td}/merged.yaml" "$target" \
    || { rm -rf "$td"; error "native k3s: couldn't write ${target}."; }
  rm -rf "$td"
  if [[ -n "$prev_ctx" && "$prev_ctx" != "$ctx" ]]; then
    # shellcheck disable=SC2034  # consumed cross-file by summary.sh
    TB_PREV_KUBE_CONTEXT="$prev_ctx"
    log "kubectl's current context was '$prev_ctx' before this install; the summary says how to switch back."
  fi
  log "kubeconfig updated — kubectl now points to '${CLUSTER_NAME}' (context ${ctx})."
  # shellcheck disable=SC2034  # consumed cross-file by common.sh (tb_record_write's kube_context)
  TB_KUBE_CONTEXT="$ctx"
}

# _native_k3s_wait_for_api -- wait for the API to answer, on cluster.sh's _api_answers
# (the one definition of "answers") and for cluster.sh's _api_wait_budget_s, the same
# TB_API_WAIT_S budget k3d's wait reads.
_native_k3s_wait_for_api() {
  local budget deadline
  budget="$(_api_wait_budget_s)"
  # A wall-clock deadline, as k3d's wait uses: a tick counter ignores the time
  # _api_answers itself spends (up to its 5s request timeout per probe).
  deadline=$(( $(date +%s) + budget ))
  log "Waiting for the k3s API server to answer (up to ${budget}s)..."
  until _api_answers; do
    (( $(date +%s) < deadline )) \
      || error "The k3s API server did not answer within ${budget}s. It's safe to re-run this installer; on a slow machine, extend the wait with TB_API_WAIT_S=<seconds>. 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why it is not up."
    sleep 2
  done
  log "k3s API server is answering."
}
