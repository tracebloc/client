#!/usr/bin/env bash
# =============================================================================
#  k3s.sh — native k3s on Linux: k3s on the host, no k3d, no Docker
#           (RFC-0175 D3, D4, D9-D11; slim client Stage 1, 1.1b + 1.1e + 1.1f)
#
#  OPT-IN, LINUX ONLY. install-k8s.sh sources this file and both bootstraps fetch
#  it; install_linux and create_cluster route here when TB_SUBSTRATE=k3s, which a
#  customer gets by setting TRACEBLOC_SUBSTRATE=k3s, or by re-running on a machine
#  whose install record says k3s (common.sh's tb_substrate_resolve, 1.1f). The
#  default stays k3d until 1.7.
#
#  What is here:
#    - the pins: the release tag DERIVED from K8S_VERSION, and the three digests
#      common.sh stamps from facts.env (TB_K3S_BIN_SHA256_* / TB_K3S_INSTALL_SH_SHA256);
#    - the verified downloads of the binary and of upstream's install.sh at the tag,
#      and the scrubbed run of that script (INSTALL_K3S_SKIP_DOWNLOAD=binary);
#    - /etc/rancher/k3s/config.yaml, rendered pure and written as root with an
#      explicit mode, beside the kubelet drop-in and registries.yaml that cluster.sh
#      renders for both substrates;
#    - the frozen node name, the pod/service range pair, the cgroup read;
#    - the kubeconfig merge and the API wait;
#    - the install path (1.1e): step b's sudo-once tool install, and step c's
#      refusals, firewall, configuration, binary, kubeconfig and re-run, each artefact
#      recorded the moment it exists;
#    - the unprivileged probe re-run resolution reads (1.1f).
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
# The first line of every config.yaml this installer writes. It is the marker the
# re-run reads to tell tracebloc's k3s from a k3s someone else set up
# (_native_k3s_presence), so the renderer prints THIS constant, never a copy of it.
TB_K3S_CONFIG_MARKER="# Written by the tracebloc installer (scripts/lib/k3s.sh); a re-run rewrites it."

# k3s's own data path (its `--data-dir`, which the installer never sets): the
# images, containerd and the server state. Fixed by upstream.
TB_K3S_DATA_PATH="/var/lib/rancher/k3s"
# Where local-path puts the volumes when the operator chose no data dir (decided
# 2026-10-01): k3s's default, inside its data path.
TB_K3S_STORAGE_DEFAULT="${TB_K3S_DATA_PATH}/storage"

# ── Storage path ──────────────────────────────────────────────────────────────

# _native_k3s_storage_override -- the STORAGE_PATH _native_k3s_render_config takes:
# the directory local-path keeps the volumes in, or nothing for k3s's default. It is
# the ONE answer to "where do the volumes live": preflight's disk and storage checks,
# the leftover guard and the summary read it through _native_k3s_storage_path below,
# so the directory they measure is the one config.yaml names.
#
# FROZEN at first install, like the node name: the volumes already sit in the
# directory an existing config.yaml names, so a re-run keeps it and never follows the
# environment. A re-run that asks for another directory is told so, once, by
# preflight (_native_k3s_storage_drift_warn). With no config.yaml it is this run's
# choice (_native_k3s_storage_choice).
#
# config.yaml is root's (0600, or 0640 to the daily user's private group, D3), and
# preflight runs before preflight_sudo asks for the password, so this reads it only
# when root needs no prompt. A prompt here would sit
# inside the caller's $(...) (preflight_sudo's keepalive would hold that pipe open).
# Returns:
#   0  the directory, or nothing for k3s's default;
#   2  config.yaml exists and could not be read: cannot tell;
#   3  config.yaml may exist (TB_K3S_ETC_DIR's parent does) and reading it needs a
#      password. The caller asks for it in the main shell (preflight_sudo) and calls
#      again. A host with no /etc/rancher has no config.yaml, so a fresh install
#      reads its choice with no root and no prompt.
_native_k3s_storage_override() {
  local cfg="$TB_K3S_CONFIG_PATH" have rc=0
  if [[ -e "$(dirname "$TB_K3S_ETC_DIR")" ]]; then
    _native_k3s_root_ready || return 3
    if sudo test -e "$cfg"; then
      have="$(_native_k3s_config_value default-local-storage-path "$cfg")" || rc=$?
      [[ "$rc" -eq 0 ]] || return 2
      printf '%s' "$have"
      return 0
    fi
    # `test -e` fails for a missing file AND for a sudo that did not run (the
    # password prompt expired between the readiness check and here): a sudo that is
    # down is "cannot tell", never "no config.yaml" -- the latter re-derives a frozen
    # storage path from this run's environment. Same probe _native_k3s_config_value
    # makes.
    sudo test -d / || return 2
  fi
  _native_k3s_storage_choice
}

# _native_k3s_storage_frozen -- true when a config.yaml already froze the storage
# path, so this run's HOST_DATA_DIR cannot move the volumes. Same reads, same
# "cannot tell" as _native_k3s_storage_override: 1 when none exists, 2 when root
# cannot answer. A caller that has read the storage path has already handled both.
_native_k3s_storage_frozen() {
  [[ -e "$(dirname "$TB_K3S_ETC_DIR")" ]] || return 1
  _native_k3s_root_ready || return 2
  if sudo test -e "$TB_K3S_CONFIG_PATH"; then return 0; fi
  sudo test -d / || return 2
  return 1
}

# _native_k3s_storage_choice -- this run's choice: the operator's data dir when they
# chose one, else nothing (k3s's default). "Chose one" is HOST_DATA_DIR naming a
# directory other than the default. A parent process that exported the default (an
# upgrade) is not a choice, so the volumes never move into the home directory because
# the default was passed along. Both sides are compared with their parents resolved
# physically, as validate_config resolves HOST_DATA_DIR, so a symlinked $HOME is not a
# choice either.
_native_k3s_storage_choice() {
  local dir="${HOST_DATA_DIR:-}" def="${TB_HOST_DATA_DIR_DEFAULT:-}"
  [[ -n "$dir" ]] || return 0
  [[ -n "$def" && "$(_native_k3s_resolved_dir "$dir")" == "$(_native_k3s_resolved_dir "$def")" ]] && return 0
  printf '%s' "$dir"
}

# _native_k3s_root_ready -- true when a root read needs no password prompt: root
# itself, or a sudo that answers non-interactively (cached, or NOPASSWD).
_native_k3s_root_ready() {
  [ "$(id -u)" -eq 0 ] || _real_sudo -n true 2>/dev/null
}

# _native_k3s_storage_path -- the directory local-path keeps the volumes in: the
# frozen or chosen directory, or k3s's default. Returns the override's 2 or 3.
_native_k3s_storage_path() {
  local o rc=0
  o="$(_native_k3s_storage_override)" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  printf '%s' "${o:-$TB_K3S_STORAGE_DEFAULT}"
}

# _native_k3s_storage_drift_warn -- one warning when the volumes stay where an
# existing config.yaml froze them while this run asked for another directory. Main
# shell only (it warns on stdout); preflight calls it once per run.
_native_k3s_storage_drift_warn() {
  local kept chosen
  kept="$(_native_k3s_storage_path)" || return 0
  chosen="$(_native_k3s_storage_choice)"
  chosen="${chosen:-$TB_K3S_STORAGE_DEFAULT}"
  [[ "$(_native_k3s_resolved_dir "$kept")" != "$(_native_k3s_resolved_dir "$chosen")" ]] || return 0
  warn "This machine's k3s keeps its volumes in ${kept}; this run asked for ${chosen}, which is not used."
  hint "The volumes can't move: to use ${chosen}, remove tracebloc from this machine, then install again with that data dir."
}

# _native_k3s_resolved_dir PATH -- PATH with its parent resolved physically (`cd -P`),
# the form validate_config leaves HOST_DATA_DIR in. PATH itself may not exist yet; an
# unresolvable parent leaves PATH as given.
_native_k3s_resolved_dir() {
  local p="$1" parent
  parent="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s' "$p"; return 0; }
  printf '%s/%s' "${parent%/}" "$(basename "$p")"
}

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

# _native_k3s_group_name_ok NAME -- 0 when NAME is empty (no grant) or a group name the
# render writes into config.yaml: lowercase letters, digits, `_` and `-`, not starting
# with a digit or `-`. The one test both _native_k3s_kubeconfig_group (which decides to
# grant) and _native_k3s_render_config (which writes it) make, so a group the first
# approves can never be one the second refuses. Spelled out, never a-z: bash 3.2 under
# a UTF-8 locale collates A-Z into a-z.
_native_k3s_group_name_ok() {
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*|[!abcdefghijklmnopqrstuvwxyz_]*) return 1 ;;
  esac
  return 0
}

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
#   KGROUP        optional: the daily user's private group
#                 (_native_k3s_kubeconfig_group). Given, k3s writes k3s.yaml 0640 to
#                 that group (RFC-0175 D3, `write-kubeconfig-group`); empty, 0600.
# It never emits `server:` or `token:` -- this node is a server, alone.
_native_k3s_render_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" kgroup="${6:-}" cluster_cidr service_cidr kubelet_args
  case "$mode" in
    node-local) ;;
    hostpath) echo "native k3s: TRACEBLOC_STORAGE_MODE=hostpath is not supported on native k3s; it keeps datasets in k3s's local-path storage (node-local)." >&2; return 1 ;;
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
  _native_k3s_group_name_ok "$kgroup" || { echo "native k3s: '${kgroup}' is not a group name k3s's kubeconfig can be granted to." >&2; return 1; }
  printf '%s\n' "$TB_K3S_CONFIG_MARKER"
  printf '# node-name and the two CIDRs are read back from here and never change.\n'
  printf 'disable: [traefik, servicelb]\n'
  printf 'disable-helm-controller: true\n'
  printf 'disable-cloud-controller: true\n'
  printf 'node-name: "%s"\n' "$name"
  printf 'cluster-cidr: "%s"\n' "$cluster_cidr"
  printf 'service-cidr: "%s"\n' "$service_cidr"
  if [[ -n "$kgroup" ]]; then
    printf 'write-kubeconfig-mode: "0640"\n'
    printf 'write-kubeconfig-group: "%s"\n' "$kgroup"
  else
    printf 'write-kubeconfig-mode: "0600"\n'
  fi
  printf 'kubelet-arg: [%s]\n' "$kubelet_args"
  if [[ -n "$storage" ]]; then
    printf 'default-local-storage-path: "%s"\n' "$storage"
  fi
}

# _native_k3s_install_file MODE DEST BODY [GROUP] -- write BODY (plus a newline) to
# DEST as root, mode MODE (and group GROUP when given), never through the umask: the core runs under `umask 077`
# (common.sh), which a `sudo tee` inherits, so a file written without a mode comes out
# 0600 and a directory 0700. A DEST whose content already equals BODY is left alone;
# a DEST it does write is appended to TB_K3S_FILES_CHANGED, which tells a re-run
# whether k3s has to restart to read it.
TB_K3S_FILES_CHANGED=""
_native_k3s_install_file() {
  local mode="$1" dest="$2" body="$3" group="${4:-}" have tmp
  if have="$(sudo cat "$dest" 2>/dev/null)" && [[ "$have" == "$body" ]]; then
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/tracebloc-k3s-XXXXXX")" || return 1
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo install -m "$mode" ${group:+-g "$group"} "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  TB_K3S_FILES_CHANGED="${TB_K3S_FILES_CHANGED:+${TB_K3S_FILES_CHANGED} }${dest}"
}

# _native_k3s_kubeconfig_group -- print the daily user's primary group when it is
# PRIVATE to them: the group k3s.yaml and config.yaml may be granted to (RFC-0175 D3,
# `write-kubeconfig-group`, mode 0640). Private means all three: the group is named
# after the user, no other passwd entry has its gid, and it has no members. That is
# the default on Ubuntu, RHEL and AL2023. The name test keeps a directory group (an
# AD "domain users") shared even where NSS enumerates no other user. Anything else,
# or anything it cannot read in time, returns 1: a group is never widened on a guess.
# Measured on the 1.1e VM: with the grant, kubectl from a login shell, an interactive
# shell and a fresh SSH login answers without sudo, KUBECONFIG unset.
_native_k3s_kubeconfig_group() {
  local user gid gname line pw n
  user="$(id -un 2>/dev/null)" && gid="$(id -g 2>/dev/null)" && gname="$(id -gn 2>/dev/null)" || return 1
  [[ -n "$user" && "$gname" == "$user" ]] || return 1
  # A name the render would refuse ('John.Smith' on an AD-joined RHEL host) is shared,
  # not an install that aborts: the grant falls back to 0600 and the notice.
  _native_k3s_group_name_ok "$gname" || return 1
  line="$(_bounded 10 getent group "$gname" 2>/dev/null)" || return 1
  [[ -n "$line" && -z "${line##*:}" ]] || return 1
  # Bounded, and read whole before it is counted: on an AD-joined host a wedged SSSD/LDAP
  # makes the listing hang, which would stop a headless install at the config write; a
  # deadline is "cannot read", so the grant is not made. Piping the bounded call straight
  # into awk would count the entries a killed listing had printed so far, and a short
  # count passes the `== 1` test below.
  pw="$(_bounded 10 getent passwd 2>/dev/null)" || return 1
  n="$(printf '%s\n' "$pw" | awk -F: -v g="$gid" '$4 == g { n++ } END { print n + 0 }')" || return 1
  [[ "$n" == 1 ]] || return 1
  printf '%s\n' "$gname"
}

# _native_k3s_kubeconfig_shared_notice -- the grant was not made (the group is not
# private, or could not be read): say so in the log, and give the user the remedy.
# k3s's kubectl reads root's k3s.yaml when KUBECONFIG is unset, so without the grant
# a kubectl without sudo needs the user's own kubeconfig named. Main shell only.
_native_k3s_kubeconfig_shared_notice() {
  log "native k3s: no group grant on k3s.yaml: $(id -un 2>/dev/null)'s primary group $(id -gn 2>/dev/null) is not confirmed private to them, so k3s.yaml and config.yaml stay root's (0600)."
  hint "To run kubectl without sudo here, name your own kubeconfig: export KUBECONFIG=~/.kube/config"
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
#   node and the ranges, and k3s keeps its own secrets beside it), or 0640 to the
#   daily user's private group, which then reads k3s.yaml too (D3); the kubelet
#   drop-in 0644 (the e2e readback reads it unprivileged); and, when CA_FILE is
#   given, the CA 0644 and registries.yaml 0600.
#
# The group is granted only when it is private (_native_k3s_kubeconfig_group).
# config.yaml holds no secret, and k3s's kubectl reads it on every call, warning
# "permission denied" when it cannot (measured on the 1.1e VM). A shared group is
# never widened: both stay 0600, and the user is told the one-line remedy.
_native_k3s_write_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" ca="${6:-}" cfg kubelet ca_body kgroup
  kgroup="$(_native_k3s_kubeconfig_group)" || kgroup=""
  cfg="$(_native_k3s_render_config "$mode" "$name" "$cidrs" "$storage" "$cgroup" "$kgroup")" || return 1
  [[ "$cgroup" != v1 ]] || _native_k3s_cgroup_v1_notice
  kubelet="$(_render_kubelet_config)" || return 1
  sudo install -d -m 0755 /etc/rancher || return 1
  sudo install -d -m 0755 "$TB_K3S_ETC_DIR" || return 1
  if [[ -n "$kgroup" ]]; then
    _native_k3s_install_file 0640 "$TB_K3S_CONFIG_PATH" "$cfg" "$kgroup" || return 1
  else
    _native_k3s_kubeconfig_shared_notice
    _native_k3s_install_file 0600 "$TB_K3S_CONFIG_PATH" "$cfg" || return 1
  fi
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

# _native_k3s_context -- the kubeconfig context native k3s is merged as:
# k3s-<CLUSTER_NAME> (decided 2026-10-01; it mirrors k3d's k3d-<name>). The cluster
# and the user entries carry the same name. One definition, read by the merge, the
# record and the API wait.
_native_k3s_context() { printf 'k3s-%s' "${CLUSTER_NAME}"; }

# _native_k3s_kubeconfig_target -- the kubeconfig the merge writes, the one k3d's
# merge writes: the first entry of KUBECONFIG, else ~/.kube/config.
_native_k3s_kubeconfig_target() {
  local target="${KUBECONFIG:-${HOME}/.kube/config}"
  printf '%s' "${target%%:*}"
}

# _native_k3s_merge_kubeconfig -- merge k3s's kubeconfig into the daily user's
# (_native_k3s_kubeconfig_target), as _native_k3s_context, make it current, and set
# TB_KUBE_CONTEXT. It is written by this (the daily user's) process, mode 0600, so
# the user owns it; k3s's own copy stays root's.
#
# Merged by `$TB_K3S_BIN_PATH kubectl config view --flatten` with the RENAMED file FIRST in
# KUBECONFIG: the first file wins a conflict, so a re-install's fresh credentials
# replace the previous install's, and its current-context becomes the user's.
#
# With KUBECONFIG unset it is then EXPORTED as the merged file, for the rest of the
# run. Upstream links kubectl to k3s (D3), and k3s's kubectl reads root's k3s.yaml,
# never ~/.kube/config, whenever KUBECONFIG is unset and that file exists: on the
# 1.1e VM every kubectl the run made failed "permission denied" and the API wait
# ran out. A KUBECONFIG the user set already names the target, and is left alone.
_native_k3s_merge_kubeconfig() {
  local ctx target td prev_ctx=""
  ctx="$(_native_k3s_context)"; target="$(_native_k3s_kubeconfig_target)"
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
  # The user's own shell has no KUBECONFIG either, and there k3s's kubectl reads
  # k3s.yaml (context default, no namespace), never this file: print_summary
  # prints the export line for it.
  # shellcheck disable=SC2034  # consumed cross-file by summary.sh (print_summary)
  [[ -n "${KUBECONFIG:-}" ]] || TB_K3S_KUBECONFIG_HINT="$target"
  [[ -n "${KUBECONFIG:-}" ]] || export KUBECONFIG="$target"
  log "kubeconfig updated — kubectl now points to '${CLUSTER_NAME}' (context ${ctx})."
  # shellcheck disable=SC2034  # consumed cross-file by common.sh (tb_record_write's kube_context)
  TB_KUBE_CONTEXT="$ctx"
}

# The ONE TB_API_WAIT_S budget the three waits share: the wait for k3s.yaml starts
# it, and the API and node Ready waits spend what is left, so a slow k3s start never
# earns a second full budget. TWO CLOCKS, and the budget is spent when either runs
# out, as client-dev#1514 holds the core's deadlines. TB_K3S_WAITED_S counts the
# sleeps, so a stubbed sleep still reaches the deadline (noop-sleep-deadline-guard);
# TB_K3S_WAIT_T0 is the epoch second the budget started, so the time a probe itself
# takes (_api_answers: up to 5 s a request) counts too.
TB_K3S_WAITED_S=0
TB_K3S_WAIT_T0=0

# _native_k3s_budget_left BUDGET -- true while the shared budget has time left on both
# clocks. A wait that runs first, with no start recorded, starts the clock.
_native_k3s_budget_left() {
  (( TB_K3S_WAIT_T0 > 0 )) || TB_K3S_WAIT_T0="$(date +%s)"
  (( TB_K3S_WAITED_S < $1 )) && (( $(date +%s) - TB_K3S_WAIT_T0 < $1 ))
}

# _native_k3s_node_ready CTX NAME -- the Ready condition's status of node NAME on
# context CTX (True, False or Unknown), or nothing when the API does not say.
_native_k3s_node_ready() {
  kubectl --context "$1" get node "$2" --request-timeout=5s \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
}

# _native_k3s_wait_for_node_ready NAME -- the install is done only when node NAME is
# Ready, asked on the k3s context by name, on the budget the two waits before it
# share. Neither install.sh's exit 0 nor `systemctl is-active k3s` says so: on cgroup
# v1 without fail-cgroupv1=false both read success while the kubelet exits every
# ~14 s, and the API answers in between (S-R2, tracebloc/backend#5072).
_native_k3s_wait_for_node_ready() {
  local name="$1" budget ctx
  budget="$(_api_wait_budget_s)"; ctx="$(_native_k3s_context)"
  log "Waiting for node '${name}' to be Ready..."
  until [[ "$(_native_k3s_node_ready "$ctx" "$name")" == True ]]; do
    _native_k3s_budget_left "$budget" \
      || error "Node '${name}' did not become Ready within ${budget}s. It's safe to re-run this installer; on a slow machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. 'sudo journalctl -u k3s' says why the kubelet is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
  log "Node '${name}' is Ready."
}

# _native_k3s_wait_for_api -- wait for the API to answer on the k3s context BY NAME,
# never on the user's current context, which may be another cluster's. On
# cluster.sh's _api_answers (the one definition of "answers") and its
# _api_wait_budget_s (the TB_API_WAIT_S budget k3d's wait reads), continuing the
# count _native_k3s_wait_for_kubeconfig started.
_native_k3s_wait_for_api() {
  local budget ctx
  budget="$(_api_wait_budget_s)"; ctx="$(_native_k3s_context)"
  log "Waiting for the k3s API server to answer on context ${ctx}..."
  until _api_answers "$ctx"; do
    _native_k3s_budget_left "$budget" \
      || error "The k3s API server did not answer within ${budget}s. It's safe to re-run this installer; on a slow machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why it is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
  log "k3s API server is answering."
}

# ── Re-run resolution's probe (1.1f) ───────────────────────────────────────────

# _native_k3s_live_probe -- whether a tracebloc native k3s is set up on this
# machine, read with no privileges, for common.sh's tb_substrate_resolve. The
# marker in config.yaml is out of reach (root's, 0600), so it reads what any user
# can: tracebloc's kubelet drop-in (0644; on the host only the native path writes
# it, so a k3s without it is not tracebloc's), k3s's uninstall script, and
# systemctl. "Set up" is running OR enabled: a k3s that is crash-looping or not yet
# started reads inactive, and it comes back at the next boot either way.
# 0 = set up, 1 = not here (or installed, stopped and disabled), 2 = tracebloc's
# files are here but systemctl did not answer (cannot tell). Linux only.
_native_k3s_live_probe() {
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 1
  [[ -f "$TB_KUBELET_CONFIG_K3S_PATH" && -f "$TB_K3S_UNINSTALL_PATH" ]] || return 1
  local rc=0
  _bounded "${TB_PROBE_TIMEOUT:-5}" systemctl is-active --quiet k3s 2>/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  [[ "$rc" -eq 3 || "$rc" -eq 4 ]] || return 2
  rc=0
  _bounded "${TB_PROBE_TIMEOUT:-5}" systemctl is-enabled --quiet k3s 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# ── The install path (1.1e) ───────────────────────────────────────────────────
#
# install_linux (setup-linux.sh) runs _native_k3s_install_linux and create_cluster
# (cluster.sh) runs _native_k3s_create_cluster when TB_SUBSTRATE=k3s. Native k3s is
# Linux-only in Stage 1; macOS gets its node in 2.1 (D6).

# What upstream's install.sh writes. The presence check reads the units; the record
# names the uninstall script, which delete runs.
TB_K3S_UNIT_PATH="/etc/systemd/system/k3s.service"
TB_K3S_AGENT_UNIT_PATH="/etc/systemd/system/k3s-agent.service"
TB_K3S_UNINSTALL_PATH="/usr/local/bin/k3s-uninstall.sh"
# Written by k3s when the node first registers. k3s-uninstall.sh leaves it behind, so
# the record lists it as a `file` for delete to remove.
TB_K3S_NODE_PASSWORD_PATH="/etc/rancher/node/password"

# _native_k3s_ensure_firewall_tool -- the host firewall (1.1c) needs nft, or iptables
# with ip6tables, and minimal cloud images ship none of them: RHEL 8.10 and Amazon
# Linux 2023 have no nft, no iptables and no firewalld (S-R2, tracebloc/backend#5072).
# Then step b installs nftables with the host's package manager. The firewall step
# still refuses a host it cannot fence. There are no modules to load here: k3s loads
# every one it needs itself, from the base kernel, at install and after every boot
# (S-R2), so the native path writes no /etc/modules-load.d file and installs no
# kernel-modules-extra (_ensure_kernel_modules is the Docker path's).
_native_k3s_ensure_firewall_tool() {
  case "$(_native_k3s_fw_pick)" in nft|iptables) return 0 ;; esac
  # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
  spin_cmd "Installing nftables…" $PM_INSTALL nftables || \
    log "Could not install nftables; the firewall step names what is missing."
}

# _native_k3s_install_linux -- step b on native k3s (D3, D9). k3s runs as root, so
# administrator rights are asked for ONCE, here, and the keepalive preflight_sudo
# starts covers the rest of the run. A usable Docker does not make this Tier 0:
# Tier 0 promises no administrator rights, and native k3s cannot keep that promise,
# so the run is Tier 2 and the record gets its root copy. Tier 1 (rootless) does not
# exist on k3s (D3). No Docker, no k3d and no kubectl download: upstream's install.sh
# links kubectl to k3s wherever root's PATH has none. Helm installs as it does for k3d.
_native_k3s_install_linux() {
  if [[ "$(id -u 2>/dev/null)" != "0" ]] && ! _have_sudo_bin; then
    error "Native k3s runs as root, so installing it needs administrator rights once, and you are not root and this machine has no sudo. Re-run as root, or as a user who can sudo."
  fi
  # shellcheck disable=SC2034  # consumed cross-file (common.sh's root copy, setup-linux.sh's tools target, diagnose.sh)
  INSTALL_TIER=2
  # shellcheck disable=SC2034  # consumed cross-file by diagnose.sh
  INSTALL_TIER_REASON="native-k3s"
  log "step b: native k3s: tier 2 (k3s runs as root; administrator rights once)"
  preflight_sudo "set up k3s and a few tools"
  setup_pm
  apt_wait_for_lock
  install_system_deps
  _native_k3s_ensure_firewall_tool
  _set_tools_target
  local saved_umask
  saved_umask="$(umask)"
  umask 022
  install_helm
  umask "$saved_umask"
  log "step b: native k3s: system tools and helm ready (no Docker, no k3d, no kubectl download)"
}

# _native_k3s_refuse_host -- refuse, each by name, a host or a setting the native path
# does not serve in Stage 1, before anything is written.
_native_k3s_refuse_host() {
  [[ "${OS:-}" == "Linux" ]] \
    || error "Native k3s runs on Linux only for now, and this machine runs ${OS:-an unknown OS}. Set TRACEBLOC_SUBSTRATE=k3d to install on k3d."
  declare -F _probe_wsl >/dev/null \
    || error "native k3s: probe.sh is not loaded, so this run cannot tell whether it is inside WSL. Re-run the installer from a fresh download."
  ! _probe_wsl \
    || error "Native k3s does not run inside WSL yet. Set TRACEBLOC_SUBSTRATE=k3d to install on k3d."
  [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]] \
    || error "TRACEBLOC_STORAGE_MODE=hostpath is not available on native k3s yet: native k3s keeps datasets in k3s's local-path storage. Unset TRACEBLOC_STORAGE_MODE (and the older TB_STORAGE_MODE), or set TRACEBLOC_SUBSTRATE=k3d to keep hostpath on k3d."
  [[ -z "${HOST_DATASET_DIR:-}" ]] \
    || error "HOST_DATASET_DIR is not available on native k3s yet: a dataset directory cannot be mounted into native k3s. Unset TRACEBLOC_HOST_DATASET_DIR (and the older HOST_DATASET_DIR), or set TRACEBLOC_SUBSTRATE=k3d to keep the mount on k3d."
  [[ -z "${AGENTS:-}" ]] \
    || error "AGENTS=${AGENTS} is a k3d setting: native k3s is one server with no agent. Unset TRACEBLOC_AGENTS (and the older AGENTS)."
  [[ -z "${SERVERS:-}" || "${SERVERS}" == "1" ]] \
    || error "SERVERS=${SERVERS} is a k3d setting: native k3s is exactly one server. Unset TRACEBLOC_SERVERS (and the older SERVERS)."
  _native_k3s_check_version
}

# _native_k3s_refuse_live_k3d -- never k3s beside a live k3d (D10). k3d.sh's
# _k3d_live_clusters has four answers, and each is acted on here: none (go on), a
# listed cluster (refused), a k3d that did not answer in time, and a listing that
# failed fast. The last two are "cannot tell" and refused too -- an unreadable state
# is not evidence of absence -- but each names its own remedy: "start Docker" is
# only right for the first, and a fast failure quotes what k3d said instead.
_native_k3s_refuse_live_k3d() {
  local names rc=0
  names="$(_k3d_live_clusters)" || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) error "A k3d cluster is running on this machine ($(printf '%s' "$names" | tr '\n' ' ' | sed 's/ *$//')), and native k3s is never set up beside a live k3d. Moving to native k3s is a reinstall (a new client, datasets ingested again), which this installer cannot do yet. Keep k3d with TRACEBLOC_SUBSTRATE=k3d, or remove the k3d cluster first ('tracebloc delete'), then re-run." ;;
    3) error "k3d is installed but 'k3d cluster list' failed (${names}), so this run cannot tell whether a k3d cluster is live, and native k3s is never set up beside one. Fix what k3d reports (start Docker if it is not running), or remove k3d, then re-run." ;;
    *) error "k3d is installed but did not answer, so this run cannot tell whether a k3d cluster is live, and native k3s is never set up beside one. Start Docker so the check can run, or remove k3d, then re-run." ;;
  esac
}

# _native_k3s_refuse_server_state -- refuse a fresh install over the cluster state an
# earlier k3s left in TB_K3S_DATA_PATH (D5: no install silently adopts earlier data).
# The unit and config.yaml can be removed by hand while ${TB_K3S_DATA_PATH}/server
# stays, and a new k3s server would start on that datastore and take over the old
# cluster. guard_leftover_data cannot see it: it lists volumes. Keeping it would be
# adoption and wiping it is an uninstall, so no choice is offered: a non-empty
# server/ is refused, and one root cannot read is "cannot tell", refused the same way.
_native_k3s_refuse_server_state() {
  local srv="${TB_K3S_DATA_PATH}/server" entries
  if ! sudo test -e "$srv"; then
    sudo test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether an earlier k3s left its cluster state in ${srv}. Check that 'sudo true' runs, then re-run."
    return 0
  fi
  entries="$(sudo ls -A "$srv")" \
    || error "native k3s: ${srv} exists but could not be listed, so this run cannot tell whether an earlier k3s left its cluster state there. Check it with 'sudo ls -A ${srv}', then re-run."
  [[ -n "$entries" ]] || return 0
  error "native k3s: an earlier k3s left its cluster state in ${srv}, though its unit and config.yaml are gone, and tracebloc never starts a new k3s on an old cluster's data. Remove that k3s with ${TB_K3S_UNINSTALL_PATH} if it is still there: it deletes ${TB_K3S_DATA_PATH} (the old cluster's state, its images and the volumes under it), /etc/rancher/k3s and the k3s binary. Or move ${TB_K3S_DATA_PATH} aside to keep it. Then re-run."
}

# _native_k3s_presence -- 0 when this machine already runs the k3s this installer set
# up (a re-run), 1 when it has no k3s. A k3s someone else set up is refused here: its
# flags are not ours, so adopting it would lose D4's guarantees. "Ours" is a k3s unit
# or config.yaml together with config.yaml's marker line or an install record that
# lists `k3s-install`. An agent unit is never ours: this installer sets up one server.
# A sudo that cannot answer is refused too: "no k3s" is only said when root saw none.
# Neither is it said over an earlier k3s's cluster state (_native_k3s_refuse_server_state).
_native_k3s_presence() {
  local found="" p body rec
  for p in "$TB_K3S_UNIT_PATH" "$TB_K3S_AGENT_UNIT_PATH" "$TB_K3S_CONFIG_PATH"; do
    if sudo test -e "$p"; then found="${found:+${found}, }${p}"; fi
  done
  if [[ -z "$found" ]]; then
    # `test -e` fails for a missing path AND for a sudo that did not run (a dropped
    # credential, no tty): only a root read of a path that always exists tells them
    # apart. A sudo that is down is "cannot tell", never "no k3s here", which would
    # skip the foreign-k3s refusal below and run the leftover guard over a live
    # cluster. Same probe _native_k3s_config_value makes, after the reads it
    # disambiguates.
    sudo test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether a k3s is already on this machine, and it never sets up k3s over one it cannot see. Check that 'sudo true' runs, then re-run."
    _native_k3s_refuse_server_state
    return 1
  fi
  if ! sudo test -e "$TB_K3S_AGENT_UNIT_PATH"; then
    # Same probe as above: this `test -e` also fails when sudo stopped answering after
    # the first reads, and an agent unit root could not see must not read as no agent
    # unit, which would let a foreign agent be adopted as ours.
    sudo test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether an agent unit is on this machine, and it never adopts a k3s it cannot fully see. Check that 'sudo true' runs, then re-run."
    if sudo test -e "$TB_K3S_CONFIG_PATH"; then
      body="$(sudo cat "$TB_K3S_CONFIG_PATH")" \
        || error "native k3s: ${TB_K3S_CONFIG_PATH} exists but could not be read, so this run cannot tell whether the k3s on this machine is the one tracebloc set up. Check it with 'sudo cat ${TB_K3S_CONFIG_PATH}', then re-run."
      case $'\n'"$body"$'\n' in *$'\n'"${TB_K3S_CONFIG_MARKER}"$'\n'*) return 0 ;; esac
    fi
    rec="$(tb_record_path)"
    if [[ -f "$rec" ]] && grep -F '"kind": "k3s-install"' "$rec" >/dev/null 2>&1; then
      return 0
    fi
  fi
  error "A k3s that this installer did not set up is already on this machine (${found}), and tracebloc will not take over a k3s whose settings it did not choose. Remove it with ${TB_K3S_UNINSTALL_PATH} (k3s-agent-uninstall.sh for an agent), which deletes that cluster and its data, then re-run."
}

# _native_k3s_installed_version -- the release tag of the k3s binary at
# TB_K3S_BIN_PATH (`k3s version v1.36.3+k3s1 (...)` -> v1.36.3+k3s1); empty when there
# is none, or when it does not say. Empty never equals the pin, so the re-run replaces
# such a binary.
_native_k3s_installed_version() {
  local out line
  [[ -x "$TB_K3S_BIN_PATH" ]] || return 0
  out="$("$TB_K3S_BIN_PATH" --version 2>/dev/null)" || return 0
  line="${out%%$'\n'*}"
  case "$line" in "k3s version "*) line="${line#k3s version }"; printf '%s' "${line%% *}" ;; esac
}

# _native_k3s_wait_for_kubeconfig -- wait for k3s to write its kubeconfig, starting
# the count of the ONE budget it shares with the API wait (TB_K3S_WAITED_S). The merge
# reads the file, and the API wait asks the merged context by name.
_native_k3s_wait_for_kubeconfig() {
  local budget
  budget="$(_api_wait_budget_s)"
  TB_K3S_WAITED_S=0; TB_K3S_WAIT_T0="$(date +%s)"
  log "Waiting for k3s to start and its API server to answer (up to ${budget}s)..."
  until sudo test -s "$TB_K3S_KUBECONFIG_PATH"; do
    _native_k3s_budget_left "$budget" \
      || error "k3s did not write ${TB_K3S_KUBECONFIG_PATH} within ${budget}s. It's safe to re-run this installer; 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why it is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
}

# _native_k3s_ensure_running -- start k3s when it is not running, after step 3.
# Upstream's script starts the unit only when its own hashes changed
# (service_enable_and_start: "No change detected so skipping service start"), and
# step 3 restarts it only when a file of ours changed. So on an unchanged re-run a
# stopped k3s would stay down, and the waits would spend their whole budget on it.
# A running k3s is left alone: INSTALL_K3S_FORCE_RESTART would restart it on every
# re-run. The state is systemd's own word (`systemctl is-active`, which needs no
# root); one it cannot give is "cannot tell", refused, never read as running.
_native_k3s_ensure_running() {
  local state
  state="$(_bounded 10 systemctl is-active k3s 2>/dev/null)" || true
  case "$state" in
    active|reloading|refreshing) return 0 ;;
    inactive|failed|activating|deactivating|maintenance) ;;
    *) error "native k3s: this run cannot tell whether k3s is running ('systemctl is-active k3s' answered '${state:-nothing}'), so it neither starts k3s nor waits on it. Check that 'systemctl status k3s' answers, then re-run; it's safe to re-run this installer." ;;
  esac
  log "native k3s: k3s is not running (systemd state '${state}'); starting it."
  sudo systemctl start k3s \
    || error "native k3s: k3s was not running (systemd state '${state}') and did not start. 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why; it's safe to re-run this installer."
}

# _native_k3s_create_cluster -- step c on native k3s. The refusals first (on a new
# k3s, the pre-create fit gate among them), then each artefact in the order it must
# exist, recorded with tb_record_write the moment it does, so a run that fails at
# step N leaves a record of steps 1 to N-1:
#   1. the firewall rule, before k3s first starts, so the API never listens unfenced;
#   2. config.yaml, the kubelet drop-in and (with a corporate CA) the CA and
#      registries.yaml, each with its explicit mode;
#   3. the verified binary and upstream's install.sh at the tag, run scrubbed, then
#      k3s running: started when it is not (_native_k3s_ensure_running);
#   4. the merged kubeconfig, recorded BEFORE the API wait so a failed wait leaves
#      the context for delete, then the API (asked on that context by name, on one
#      budget with the wait for k3s.yaml), then the node password k3s wrote, then
#      the node Ready on that same budget: success is the node Ready, never
#      install.sh's exit 0 or an active unit;
#   5. NO_PROXY for this process.
# A re-run on tracebloc's k3s (the node half of D11) re-renders every file and keeps
# the node name and ranges config.yaml froze. It restarts k3s only when a file it
# writes changed, and replaces the binary only when its version is not the pin. The
# script runs on every pass: it rewrites the unit and k3s.service.env (the proxy
# home) and restarts k3s itself only when those or the binary changed. A k3s that is
# not running after that is started, whatever changed.
_native_k3s_create_cluster() {
  local present=0 tool aid apath name cidrs cgroup storage ca rc=0 src=0 want have tmp replaced=""
  log "Setting up native k3s for '${CLUSTER_NAME}'"
  _native_k3s_refuse_host
  _native_k3s_refuse_live_k3d
  _native_k3s_presence || present=$?
  # A new k3s only. A re-run of tracebloc's own k3s keeps its node and its data by
  # design, as k3d's existing cluster does.
  if [[ "$present" -eq 1 ]]; then
    # Refuse a host the fit refuses before anything exists (backend#3535), with the
    # gate k3d's _create_new_cluster runs; on k3s it sizes from the host. It runs
    # before the leftover guard, so a refused host is never asked about its data.
    # Guarded as on k3d: cluster.sh can be sourced without install-client-helm.sh.
    if declare -F _precreate_fit_gate >/dev/null 2>&1; then _precreate_fit_gate; fi
    # D5: a new k3s must not silently adopt an earlier install's data.
    guard_leftover_data
  fi

  # 1. The firewall.
  _native_k3s_fw_apply
  tool="$(_native_k3s_fw_tool)"
  IFS=$'\t' read -r aid apath < <(_native_k3s_fw_artefact "$tool")
  tb_record_write firewall-rule "$aid" "$apath"
  tb_record_write file firewall-rules "$(_native_k3s_fw_file "$tool")"

  # 2. The configuration.
  name="$(_native_k3s_node_name)"
  cidrs="$(_native_k3s_pick_cidrs)"
  cgroup="$(_native_k3s_cgroup_version)"
  # The volumes' directory, frozen in an existing config.yaml (1.1d). Step b asked for
  # the password, so a 3 here means sudo lost it; either way nothing is guessed.
  storage="$(_native_k3s_storage_override)" || src=$?
  case "$src" in
    0) ;;
    3) error "native k3s: reading ${TB_K3S_CONFIG_PATH} needs administrator rights, and sudo asked for a password. Re-run the installer; it asks for the password once, at the start." ;;
    *) error "native k3s: ${TB_K3S_CONFIG_PATH} exists but could not be read, so this run cannot tell where the volumes live. Check that sudo can read it, then re-run." ;;
  esac
  ca="$(_resolve_ca_bundle)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "$ca is set but its CA bundle file can't be read — fix its path/permissions and re-run."
  TB_K3S_FILES_CHANGED=""
  _native_k3s_write_config "${TB_STORAGE_MODE:-node-local}" "$name" "$cidrs" "$storage" "$cgroup" "$ca" \
    || error "native k3s: couldn't write k3s's configuration under ${TB_K3S_ETC_DIR}. Check that sudo can write there, then re-run."
  tb_record_write file k3s-config "$TB_K3S_CONFIG_PATH"
  tb_record_write file kubelet-config "$TB_KUBELET_CONFIG_K3S_PATH"
  if [[ -n "$ca" ]]; then
    tb_record_write file ca "$TB_K3S_CA_PATH"
    tb_record_write file registries "$TB_K3S_REGISTRIES_PATH"
  fi

  # 3. The binary and the install script.
  want="$(_native_k3s_release_tag)" || error "native k3s: cannot derive the k3s release from K8S_VERSION=${K8S_VERSION:-<empty>}."
  have="$(_native_k3s_installed_version)"
  if [[ "$have" != "$want" ]]; then
    log "native k3s: installing k3s ${want}${have:+ over ${have}}."
    _native_k3s_fetch_binary "$ARCH_DL" "$TB_K3S_BIN_PATH"
    replaced=1
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-sh-XXXXXX")" || error "native k3s: could not create a temporary directory for k3s's install script."
  _native_k3s_fetch_install_script "${tmp}/install.sh"
  _native_k3s_run_install_script "${tmp}/install.sh" \
    || { rm -rf "$tmp"; error "k3s's install script failed. 'sudo journalctl -u k3s' says why; it's safe to re-run this installer."; }
  rm -rf "$tmp"
  tb_record_write k3s-install "$CLUSTER_NAME" "$TB_K3S_UNINSTALL_PATH"
  # The script restarts k3s itself when the binary changed. config.yaml is not in its
  # hash set, so a changed file of ours is this function's restart to make.
  if [[ -n "$TB_K3S_FILES_CHANGED" && -z "$replaced" && "$present" -eq 0 ]]; then
    log "native k3s: ${TB_K3S_FILES_CHANGED} changed; restarting k3s to read it."
    sudo systemctl restart k3s || error "k3s did not restart after its configuration changed. 'sudo journalctl -u k3s' says why; it's safe to re-run this installer."
  fi
  # Neither the script nor the restart above starts a stopped k3s on an unchanged re-run.
  _native_k3s_ensure_running

  # 4. The kubeconfig, the API and the node password.
  _native_k3s_wait_for_kubeconfig
  _native_k3s_merge_kubeconfig
  tb_record_write kube-context "$(_native_k3s_context)" "$(_native_k3s_kubeconfig_target)"
  _native_k3s_wait_for_api
  tb_record_write file node-password "$TB_K3S_NODE_PASSWORD_PATH"
  _native_k3s_wait_for_node_ready "$name"

  # 5. This process's NO_PROXY: the RFC1918 defaults cover both range pairs.
  _export_host_no_proxy
}
