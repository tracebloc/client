#!/usr/bin/env bash
# =============================================================================
#  k3s.sh — native k3s on Linux: k3s on the host, no k3d, no Docker
#
#  LINUX ONLY. install-k8s.sh sources this file and both bootstraps fetch it;
#  install_linux and create_cluster route here when TRACEBLOC_SUBSTRATE_RESOLVED=k3s.
#  substrate.sh's tb_substrate_resolve resolves k3s on Linux outside WSL by default,
#  because k3d is retired there (slim client 4.1).
#
#  What is here:
#    - the pins: the release tag DERIVED from K8S_VERSION, and the three digests
#      settings.sh stamps from facts.env (TB_K3S_BIN_SHA256_* / TB_K3S_INSTALL_SH_SHA256);
#    - the verified download of the binary, the verified copy of upstream's
#      install.sh at the tag that ships with the installer (scripts/vendor/), and the
#      scrubbed run of that script (INSTALL_K3S_SKIP_DOWNLOAD=binary);
#    - /etc/rancher/k3s/config.yaml, rendered pure, beside the kubelet drop-in and
#      registries.yaml that cluster.sh renders for both substrates;
#    - the install path (1.1e): step b's sudo-once tool install, and step c's
#      refusals, firewall, configuration, binary, kubeconfig and re-run, each artefact
#      recorded the moment it exists.
#
#  Their own modules, sourced right after this one and k3s-firewall.sh:
#  k3s-apparmor.sh (the runc profile and the rival guard), k3s-gpu.sh (the NVIDIA
#  GPU, 1.1i, natively and in tracebloc's WSL distro), k3s-prepared.sh (the prepared
#  host), k3s-config.sh (the join token, the config.yaml write, the frozen node name,
#  the pod/service range pair, the cgroup read) and k3s-kubeconfig.sh (the kubeconfig
#  merge, the API wait and the unprivileged probe re-run resolution reads, 1.1f).
#
#  Every function carries the `_native_k3s_` prefix (decided 2026-10-01), so a grep
#  for native k3s code finds every name here and nothing else.
#
#  bash 3.2-safe although native k3s is Linux-only: the macOS unit job sources this
#  file in k3s.bats. No `${x,,}`, no `declare -A`, no `mapfile`.
#
#  Sourcing it has no side effects: constants and functions only, and nothing at
#  the top level calls the core modules. check-facts.sh sources it alone, to derive the
#  release tag and the asset URLs the same way the installer does.
# =============================================================================

# The xtrace hold (output.sh). A no-op with an output.sh from before it, so a mixed
# set of libs runs, unheld, rather than stopping on a missing command.
declare -F _tb_trace_off >/dev/null 2>&1 || _tb_trace_off() { :; }
declare -F _tb_trace_on >/dev/null 2>&1 || _tb_trace_on() { :; }

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
# The join token's pinned file, which config.yaml's `token-file` names
# (_native_k3s_pin_token): root's, 0600, written once. The path the
# macOS node uses inside its container too (TB_MAC_CT_NODE_TOKEN_FILE).
TB_K3S_TOKEN_PATH="${TB_K3S_ETC_DIR}/tracebloc-token"
# Where the binary goes. upstream's install.sh looks for it in the same place
# (BIN_DIR=/usr/local/bin) when it is told to skip the download.
# shellcheck disable=SC2034  # the DEST 1.1e's install flow passes to _native_k3s_fetch_binary
TB_K3S_BIN_PATH="/usr/local/bin/k3s"
# The pod and service ranges, in the order they are tried: k3s's own defaults, then
# the fixed fallback pair (decided 2026-10-01), which sits inside the chart's
# networkPolicy.training.clusterCidrs (172.16/12) and inside the RFC1918 entries of
# cluster.sh's TB_NO_PROXY_DEFAULTS, and out of 10/8. k3s.bats derives both from
# those two declarations and holds each pair inside them.
TRACEBLOC_K3S_CIDR_PAIRS=("10.42.0.0/16 10.43.0.0/16" "172.16.0.0/17 172.16.128.0/17")
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
#   4  the host was prepared for this user (1.1g), but cannot be adopted as it
#      stands: _native_k3s_prepared_for_me says what is missing (a session that
#      started before the group, among others). The caller names that, with step
#      b's remedy, instead of asking for a password the prepared user may not have.
_native_k3s_storage_override() {
  local cfg="$TB_K3S_CONFIG_PATH" have rc=0 why=""
  if [[ -e "$(dirname "$TB_K3S_ETC_DIR")" ]]; then
    if [[ "${TB_K3S_ADOPTED:-}" != 1 ]] && ! _native_k3s_root_ready; then
      # A daily user on a host prepare-host set up for them (1.1g) has no sudo to
      # be asked for: config.yaml is read through the prepared group instead. The
      # local reaches the reads below, as bash scopes it into its callees.
      if ! why="$(_native_k3s_prepared_for_me)"; then
        [[ -z "$why" ]] || return 4
        return 3
      fi
      local TB_K3S_ADOPTED=1
    fi
    if _native_k3s_read test -e "$cfg"; then
      have="$(_native_k3s_config_value default-local-storage-path "$cfg")" || rc=$?
      [[ "$rc" -eq 0 ]] || return 2
      printf '%s' "$have"
      return 0
    fi
    # `test -e` fails for a missing file AND for a sudo that did not run (the
    # password prompt expired between the readiness check and here): a sudo that is
    # down is "cannot tell", never "no config.yaml" -- the latter re-derives a frozen
    # storage path from this run's environment. Same probe _native_k3s_config_value
    # makes, through the same reader: a prepared user has no sudo to probe with.
    _native_k3s_read test -d / || return 2
  fi
  _native_k3s_storage_choice
}

# _native_k3s_storage_frozen -- true when a config.yaml already froze the storage
# path, so this run's host_data_dir cannot move the volumes. Same reads, same
# "cannot tell" as _native_k3s_storage_override: 1 when none exists, 2 when root
# cannot answer. A caller that has read the storage path has already handled both.
_native_k3s_storage_frozen() {
  [[ -e "$(dirname "$TB_K3S_ETC_DIR")" ]] || return 1
  if [[ "${TB_K3S_ADOPTED:-}" != 1 ]] && ! _native_k3s_root_ready; then
    # A prepared user reads config.yaml through the group, with no sudo (1.1g).
    _native_k3s_prepared_for_me >/dev/null || return 2
    local TB_K3S_ADOPTED=1
  fi
  if _native_k3s_read test -e "$TB_K3S_CONFIG_PATH"; then return 0; fi
  _native_k3s_read test -d / || return 2
  return 1
}

# _native_k3s_storage_choice -- this run's choice: the operator's data dir when they
# chose one, else nothing (k3s's default). "Chose one" is host_data_dir naming a
# directory other than the default. A parent process that exported the default (an
# upgrade) is not a choice, so the volumes never move into the home directory because
# the default was passed along. Both sides are compared with their parents resolved
# physically, as validate_config resolves host_data_dir, so a symlinked $HOME is not a
# choice either.
_native_k3s_storage_choice() {
  local dir="${host_data_dir:-}" def="${TB_HOST_DATA_DIR_DEFAULT:-}"
  [[ -n "$dir" ]] || return 0
  [[ -n "$def" && "$(_native_k3s_resolved_dir "$dir")" == "$(_native_k3s_resolved_dir "$def")" ]] && return 0
  printf '%s' "$dir"
}

# _native_k3s_root_ready -- true when a root read needs no password prompt: root
# itself, or a sudo that answers non-interactively (cached, or NOPASSWD).
_native_k3s_root_ready() {
  [ "$(id -u)" -eq 0 ] || tb_root_n true 2>/dev/null
}

# _native_k3s_storage_path -- the directory local-path keeps the volumes in: the
# frozen or chosen directory, or k3s's default. Returns the override's 2, 3 or 4.
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
# the form validate_config leaves host_data_dir in. PATH itself may not exist yet; an
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

# _native_k3s_image_ref [K8S_VERSION] -- the k3s node image for a k3s image tag:
# docker.io/rancher/k3s:<tag>, the image k3s publishes. The macOS node pulls its
# linux/arm64 manifest by digest (TB_K3S_IMAGE_ARM64_DIGEST, 2.1 part 3), and
# check-facts.sh resolves that digest through this function, so the image pinned is the
# image pulled. Refuses (return 1) anything that is not a k3s image tag.
_native_k3s_image_ref() {
  local v="${1:-${K8S_VERSION:-}}"
  _native_k3s_release_tag "$v" >/dev/null || return 1
  printf 'docker.io/rancher/k3s:%s' "$v"
}

# _native_k3s_check_version -- refuse, by name, a K8S_VERSION that is not the pin.
# Native k3s cannot honour a K8S_VERSION override (settings.sh), because the
# binary is checked against a digest and settings.sh stamps digests for the pinned
# version only.
_native_k3s_check_version() {
  [[ -n "${TB_K3S_PIN_K8S_VERSION:-}" ]] \
    || error "native k3s: no pinned k3s version is stamped in settings.sh (TB_K3S_PIN_K8S_VERSION) -- run scripts/check-facts.sh --write."
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
# raw.githubusercontent.com. Only the pin's tools read it (check-facts.sh,
# bump-k3s-pin.sh): the installer runs the copy it ships.
_native_k3s_install_script_url() {
  local tag
  tag="$(_native_k3s_release_tag "${1:-}")" || return 1
  printf 'https://raw.githubusercontent.com/k3s-io/k3s/%s/install.sh' "$tag"
}

# ── Downloads ─────────────────────────────────────────────────────────────────

# _native_k3s_binary_expect -- tell the live line about the k3s binary's download
# before it starts (tb_live_expect), when step c makes one (_native_k3s_binary_due;
# --print downloads nothing).
_native_k3s_binary_expect() {
  local asset url
  tb_live_watching || return 0
  ! tb_root_planning || return 0
  _native_k3s_binary_due || return 0
  asset="$(_native_k3s_binary_asset "$ARCH_DL" 2>/dev/null)" && url="$(_native_k3s_release_url "$asset" 2>/dev/null)" \
    || { tb_live_expect ""; return 0; }
  tb_live_expect "$url"
}

# _native_k3s_fetch_binary ARCH DEST -- download the k3s binary for ARCH, verify it
# against the pinned digest, and install it at DEST as root, mode 0755. A mismatch is
# refused by name and nothing is installed. Same bounds as setup-linux.sh's
# _fetch_kubectl: a stall floor, not a hard deadline, on a ~75 MB binary.
_native_k3s_fetch_binary() {
  local arch="$1" dest="$2" asset want url tmpdir
  asset="$(_native_k3s_binary_asset "$arch")" || error "native k3s: cannot install k3s on architecture '${arch}' (amd64 or arm64)."
  want="$(_native_k3s_binary_sha256 "$arch")"
  [[ -n "$want" ]] || error "native k3s: no pinned digest for the ${arch} k3s binary is stamped in settings.sh -- run scripts/check-facts.sh --write."
  url="$(_native_k3s_release_url "$asset")" || error "native k3s: cannot derive the k3s release from K8S_VERSION=${K8S_VERSION:-<empty>}."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-bin-XXXXXX")" || error "native k3s: could not create a temporary directory for the k3s download."
  # --print downloads nothing: it lists the install, which the run makes only after
  # the binary matched its pinned digest.
  if ! tb_root_planning; then
    retry 5 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
      "$url" -o "${tmpdir}/k3s" \
      || { rm -rf "$tmpdir"; error "Couldn't download the k3s binary from ${url}. Check that this machine can reach github.com and release-assets.githubusercontent.com, then re-run."; }
    _assert_download_size "${tmpdir}/k3s" 20000000 "k3s" "$tmpdir"
    _verify_sha256 "$want" "${tmpdir}/k3s" \
      || { rm -rf "$tmpdir"; error "The k3s binary downloaded from ${url} does not match its pinned sha256 (${want}), so it was not installed. Something between this machine and GitHub changed the file; do not install it by hand. Re-run on a network that does not rewrite downloads."; }
  fi
  tb_root install -m 0755 "${tmpdir}/k3s" "$dest" \
    || { rm -rf "$tmpdir"; error "Couldn't install the k3s binary at ${dest}."; }
  rm -rf "$tmpdir"
}

# _native_k3s_install_script_body FILE -- the upstream bytes of the vendored
# install.sh: line 1 and everything below its END PROVENANCE line, the bytes its
# PROVENANCE sha256 and TB_K3S_INSTALL_SH_SHA256 are of. k3s.bats stages the real
# vendored file through it and holds the result to the pin.
_native_k3s_install_script_body() {
  sed '2,/^# END PROVENANCE$/d' "$1"
}

# _native_k3s_vendored_install_script -- the path of upstream's install.sh at the
# tag, as the installer ships it: scripts/vendor/k3s-install.sh beside scripts/lib/,
# which both bootstraps fetch and verify with the rest (gen-manifest.sh FILES). Read
# off this file's own location, so the checkout and a bootstrap's temp tree agree.
_native_k3s_vendored_install_script() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../vendor" 2>/dev/null && pwd -P)" || return 1
  printf '%s/k3s-install.sh' "$dir"
}

# _native_k3s_stage_install_script DEST -- copy upstream's install.sh at the release
# tag out of the installer's own files to DEST (a file the caller owns), verified
# against the pinned digest. Nothing is downloaded, so no run of the installer
# needs raw.githubusercontent.com. Every run still runs the
# script: it rewrites k3s.service.env, native k3s's proxy home.
_native_k3s_stage_install_script() {
  local dest="$1" want="${TB_K3S_INSTALL_SH_SHA256:-}" src
  [[ -n "$want" ]] || error "native k3s: no pinned digest for k3s's install.sh is stamped in settings.sh -- run scripts/check-facts.sh --write."
  # --print copies nothing; the run verifies the script before running it.
  if tb_root_planning; then return 0; fi
  src="$(_native_k3s_vendored_install_script)" && [[ -r "$src" ]] \
    || error "This installer build doesn't include k3s's install script (scripts/vendor/k3s-install.sh: stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
  _native_k3s_install_script_body "$src" >"$dest" \
    || error "native k3s: couldn't copy k3s's install script from ${src}."
  _verify_sha256 "$want" "$dest" \
    || { rm -f "$dest"; error "k3s's install script in this installer (${src}) does not match its pinned sha256 (${want}), so it was not run. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"; }
}

# _native_k3s_run_install_script SCRIPT -- run upstream's install.sh as root over the
# binary _native_k3s_fetch_binary placed, in a SCRUBBED environment: only PATH, HOME,
# INSTALL_K3S_SKIP_DOWNLOAD=binary (decided 2026-10-01) and the node proxy variables.
#
#   - The scrub is what makes this a single server by construction: install.sh turns
#     the node into an AGENT when K3S_URL is set, and reads K3S_TOKEN, INSTALL_K3S_*
#     and K3S_* from whatever environment it inherits.
#   - It also hands the script EXACTLY the proxy variables cluster.sh's _node_proxy_env
#     gives: install.sh rewrites /etc/systemd/system/k3s.service.env from
#     its own environment on every run (K3S_*, CONTAINERD_* and the proxy variables,
#     mode 0600), and that file is native k3s's proxy home.
#   - `binary`, not `true`: the script skips only the binary, so on an EL host it still
#     installs the k3s-selinux policy from rpm.rancher.io.
#   - HOME=/root: the script runs as root, and nothing it writes may land, root-owned,
#     in the daily user's home.
# _native_k3s_run_install_script runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__native_k3s_run_install_script below is the function itself.
_native_k3s_run_install_script() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__native_k3s_run_install_script "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__native_k3s_run_install_script() {
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
  # that checked for it.
  # A host with no timeout(1) is bounded by bash's own deadline, through the executor
  # (tb_root_bounded): it backgrounds a binary, never the sudo()
  # shadow, and under --print lists the script and runs nothing.
  local secs="${TB_K3S_INSTALL_SH_TIMEOUT:-600}"
  local tmo; tmo="$(command -v timeout 2>/dev/null)" || tmo=""
  if [[ "$tmo" == /* ]]; then
    # set-u-safe: env_args is seeded with PATH, HOME and INSTALL_K3S_SKIP_DOWNLOAD
    tb_root env -i "${env_args[@]}" "$tmo" "$secs" sh "$script" </dev/null
    return
  fi
  # set-u-safe: env_args is seeded with PATH, HOME and INSTALL_K3S_SKIP_DOWNLOAD
  tb_root_bounded "$secs" env -i "${env_args[@]}" sh "$script" </dev/null
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
#   MODE          TB_STORAGE_MODE: node-local or hostpath. Both render the same file
# : hostpath's volumes are the chart's own hostPath
#                 PVs on its own manual class, so k3s's local-path stays for anything
#                 else and nothing here depends on the mode.
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
#                 that group (`write-kubeconfig-group`); empty, 0600.
#   TOKEN_FILE    optional: the join token's pinned file (TB_K3S_TOKEN_PATH, from
#                 _native_k3s_write_config). Given, it is `token-file`, so k3s takes
#                 its token from that file and never from the server/token it
#                 rewrites on every start. The macOS node names its
#                 own (_mac_ct_node_config) and passes none.
#   SELINUX       optional: `true` writes `selinux: true` (k3s's --selinux, pods run
#                 confined), _native_k3s_selinux_confine's answer; `false` or empty
#                 writes nothing.
# It never emits `server:` or `token:` -- this node is a server, alone, and its token
# is a file's, never a value in this file, which the daily user's group may read.
_native_k3s_render_config() {
  local mode="$1" name="$2" cidrs="$3" storage="$4" cgroup="$5" kgroup="${6:-}" tokfile="${7:-}" selinux="${8:-}" cluster_cidr service_cidr kubelet_args
  case "$mode" in
    node-local|hostpath) ;;
    *) echo "native k3s: '${mode}' is not a storage mode (node-local or hostpath)." >&2; return 1 ;;
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
  case "$tokfile" in
    ""|/*) ;;
    *) echo "native k3s: the join token's file '${tokfile}' is not an absolute path." >&2; return 1 ;;
  esac
  case "$selinux" in
    ""|true|false) ;;
    *) echo "native k3s: '${selinux}' is not an SELinux answer (true or false)." >&2; return 1 ;;
  esac
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
  if [[ "$selinux" == true ]]; then
    printf 'selinux: true\n'
  fi
  if [[ -n "$storage" ]]; then
    printf 'default-local-storage-path: "%s"\n' "$storage"
  fi
  if [[ -n "$tokfile" ]]; then
    printf 'token-file: "%s"\n' "$tokfile"
  fi
}

# _native_k3s_install_file MODE DEST BODY [GROUP] -- write BODY (plus a newline) to
# DEST as root, mode MODE (and group GROUP when given), never through the umask: the core runs under `umask 077`
# (settings.sh), which a `sudo tee` inherits, so a file written without a mode comes out
# 0600 and a directory 0700. A DEST whose content already equals BODY is left alone;
# a DEST it does write is appended to TB_K3S_FILES_CHANGED, which tells a re-run
# whether k3s has to restart to read it.
TB_K3S_FILES_CHANGED=""
_native_k3s_install_file() {
  local mode="$1" dest="$2" body="$3" group="${4:-}" have tmp
  if have="$(tb_root cat "$dest" 2>/dev/null)" && [[ "$have" == "$body" ]]; then
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/tracebloc-k3s-XXXXXX")" || return 1
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  tb_root install -m "$mode" ${group:+-g "$group"} "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  TB_K3S_FILES_CHANGED="${TB_K3S_FILES_CHANGED:+${TB_K3S_FILES_CHANGED} }${dest}"
}

# _native_k3s_kubeconfig_group -- print the daily user's primary group when it is
# PRIVATE to them: the group k3s.yaml and config.yaml may be granted to (`write-kubeconfig-group`,
# mode 0640). Private means all three: the group is named
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

# The group prepare-host grants k3s.yaml and config.yaml to (mode
# 0640). Every member of it is cluster-admin on this k3s: prepare-host says so, and
# lists the members.
TB_K3S_PREPARED_GROUP="tracebloc"
# TB_K3S_GROUP_MADE: 1 when this run's own groupadd made the prepared group, else 0
# . Assigned, never read from the environment: it becomes the
# record's created_by_prepare_host, and delete removes the group only on true.
TB_K3S_GROUP_MADE=""
# The two modes 1.1g adds, assigned here and never read from the environment.
# TB_K3S_PREPARED: this run is prepare-host, setting k3s up FOR a named user.
# TB_K3S_ADOPTED: this run is that user's install at Tier 0, using the k3s an
# administrator prepared for them (_native_k3s_prepared_for_me).
TB_K3S_PREPARED=""
TB_K3S_ADOPTED=""
# TB_K3S_ON_MAC: this run installs the macOS node (mac-container.sh, 2.1 part 3). k3s
# runs in a container there, the files this file reads are the daily user's own copies
# in the runtime's folder, and the Mac has no k3s binary: nothing here may use sudo.
TB_K3S_ON_MAC=""

# _native_k3s_read CMD... -- CMD on one of k3s's root-owned files: through sudo,
# except on an adopted host, where this user reads them through the prepared group
# and has no sudo to use, and on the macOS node, whose copies are the user's.
_native_k3s_read() {
  if [[ "${TB_K3S_ADOPTED:-}" == 1 || "${TB_K3S_ON_MAC:-}" == 1 ]]; then "$@"; else tb_root "$@"; fi
}

# _native_k3s_kubeconfig_grant -- the group k3s.yaml and config.yaml are granted to,
# or nothing for none. The prepared group when this run is prepare-host, or when
# config.yaml already grants it: a later run with sudo, by the user or an
# administrator, never takes a prepared user's access away. Else the daily user's
# private group, when it is one (_native_k3s_kubeconfig_group). Returns 2 when
# config.yaml is there and cannot be read: cannot tell.
_native_k3s_kubeconfig_grant() {
  local have rc=0
  if [[ "${TB_K3S_PREPARED:-}" == 1 ]]; then printf '%s\n' "$TB_K3S_PREPARED_GROUP"; return 0; fi
  have="$(_native_k3s_config_value write-kubeconfig-group)" || rc=$?
  [[ "$rc" -eq 0 ]] || return 2
  if [[ "$have" == "$TB_K3S_PREPARED_GROUP" ]]; then printf '%s\n' "$have"; return 0; fi
  _native_k3s_kubeconfig_group || true
}

# _native_k3s_kubeconfig_shared_notice -- the grant was not made (the group is not
# private, or could not be read): say so in the log, and give the user the remedy.
# k3s's kubectl reads root's k3s.yaml when KUBECONFIG is unset, so without the grant
# a kubectl without sudo needs the user's own kubeconfig named. Main shell only.
_native_k3s_kubeconfig_shared_notice() {
  log "native k3s: no group grant on k3s.yaml: $(id -un 2>/dev/null)'s primary group $(id -gn 2>/dev/null) is not confirmed private to them, so k3s.yaml and config.yaml stay root's (0600)."
  tb_machine_lines hint "To run kubectl without sudo here, name your own kubeconfig: export KUBECONFIG=~/.kube/config"
}

# _native_k3s_cgroup_v1_notice -- on a cgroup v1 host k3s runs with the kubelet's
# fail-cgroupv1=false (the render's v1 arm); say so, beside the remedy that moves
# the host to cgroup v2, an IT step and a reboot. Measured on RHEL 8.10 (S-R2):
# v1 with the flag passes, and so does v2 after grubby.
# Main shell only: it prints.
_native_k3s_cgroup_v1_notice() {
  warn "This machine runs cgroup v1, which Kubernetes is retiring. k3s runs on it with the kubelet's fail-cgroupv1=false."
  if has grubby; then
    hint "To move it to cgroup v2 (an IT step, then a reboot): sudo grubby --update-kernel=ALL --args=\"systemd.unified_cgroup_hierarchy=1\""
  else
    hint "To move it to cgroup v2 (an IT step, then a reboot): add systemd.unified_cgroup_hierarchy=1 to the kernel command line."
  fi
}

# ── SELinux ───────────────────────────────────────────────────────────────────

# TB_K3S_SELINUX_ARMED -- 1 lets _native_k3s_selinux_confine answer true; 0 confines no
# host. Confined, every pod sharing a local-path volume runs at the chart's selinux.level,
# the pods jobs-manager spawns included (it passes them TRACEBLOC_SELINUX_LEVEL).
TB_K3S_SELINUX_ARMED=1

# _native_k3s_selinux_enabled -- true when `selinuxenabled` says SELinux is on
# (Enforcing or Permissive). A host without the command has no SELinux to confine
# with. TRACEBLOC_K3S_SELINUXENABLED is the TEST SEAM: the command asked.
_native_k3s_selinux_enabled() {
  local cmd="${TRACEBLOC_K3S_SELINUXENABLED:-selinuxenabled}"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" >/dev/null 2>&1
}

# _native_k3s_caller_hostpath -- 0 when a caller's values file (TRACEBLOC_VALUES_FILE,
# which dev mode installs as-is) may turn hostPath on: its hostPath.enabled is anything
# but empty or false, or the file cannot be read. 1 with no such file, or hostPath off.
_native_k3s_caller_hostpath() {
  local vf="${TRACEBLOC_VALUES_FILE:-}" out
  [[ -n "$vf" ]] || return 1
  [[ -r "$vf" ]] && declare -F _values_hostpath_storage >/dev/null 2>&1 || return 0
  out="$(_values_hostpath_storage <"$vf")" || return 0
  [[ "$out" != unreadable ]] || return 0
  case "$(printf '%s\n' "$out" | sed -n 's/^enabled=//p')" in
    ""|false|null|"~") return 1 ;;
  esac
  return 0
}

# _native_k3s_selinux_confine MODE -- `true` when this k3s runs its pods confined
# (`selinux: true`), else `false`. Only with SELinux on and node-local volumes: the
# chart's hostPath PVs (MODE hostpath, or a caller's file that turns hostPath on) are
# never relabelled by the kubelet, so a confined pod could not use their directories.
# And never newly while this run has not read its release's storage
# (_native_k3s_selinux_deferred).
_native_k3s_selinux_confine() {
  if [[ "$TB_K3S_SELINUX_ARMED" == 1 && "${1:-}" == node-local ]] && ! _native_k3s_caller_hostpath \
     && _native_k3s_selinux_enabled && ! _native_k3s_selinux_deferred; then
    printf 'true'
  else
    printf 'false'
  fi
}

# _native_k3s_selinux_confined -- whether this machine's config.yaml runs k3s
# confined: 0 yes, 1 no (no config.yaml, or no `selinux: true` in it), 2 cannot tell.
# The chart's selinux.confine is read from here, so the two never disagree.
_native_k3s_selinux_confined() {
  local v rc=0
  v="$(_native_k3s_config_value selinux)" || rc=$?
  [[ "$rc" -eq 0 ]] || return 2
  [[ "$v" == true ]]
}

# _native_k3s_selinux_deferred -- 0 when this run must not confine a k3s that does not
# run confined now. install-k8s.sh's early read found a k3s this installer set up
# and could not read its release (TB_RELEASE_STORAGE_UNREAD, set by
# _native_k3s_release_storage), so this run's storage mode is still the default's
# node-local, while the release may keep its data in hostPath volumes:
# install_client_helm learns that only after config.yaml is written and k3s restarted. Until then config.yaml keeps what it says: a confined
# k3s stays confined, and one that is not, or a config.yaml that cannot be read,
# is not confined by this run. The next run that reads the release decides.
_native_k3s_selinux_deferred() {
  [[ "${TB_RELEASE_STORAGE_UNREAD:-}" == 1 ]] || return 1
  ! _native_k3s_selinux_confined
}

# ── The install path (1.1e) ───────────────────────────────────────────────────
#
# install_linux (setup-linux.sh) runs _native_k3s_install_linux and create_cluster
# (cluster.sh) runs _native_k3s_create_cluster when TRACEBLOC_SUBSTRATE_RESOLVED=k3s. Native k3s is
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
# Linux 2023 have no nft, no iptables and no firewalld (S-R2).
# Then step b installs nftables with the host's package manager. The firewall step
# still refuses a host it cannot fence. There are no modules to load here: k3s loads
# every one it needs itself, at install and after every boot (S-R2), so the native
# path writes no /etc/modules-load.d file. A kernel that lacks br_netfilter gets the
# file installed (_native_k3s_ensure_bridge_module), and k3s loads it.
_native_k3s_ensure_firewall_tool() {
  case "$(_native_k3s_fw_pick)" in nft|iptables) return 0 ;; esac
  # Bounded: a stalled package mirror hung here behind the
  # spinner with no message. Best-effort either way -- the firewall step still
  # refuses a host it cannot fence -- but a stall is named as one.
  local _nft_rc=0
  # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
  spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 600 "Installing nftables…" $PM_INSTALL nftables || _nft_rc=$?
  if (( _nft_rc == 124 )) && [[ -n "${_TB_SPIN_SURVIVORS:-}" ]]; then
    # The package manager outlived its kill: it still holds the lock, so the
    # firewall step and every later install would queue behind it unannounced.
    error "Installing nftables did not finish within 10 minutes, and the package manager is still running and holding the package lock. Wait for it to finish, check your network/proxy, then re-run prepare-host or the installer."
  elif (( _nft_rc == 124 )); then
    warn "Installing nftables did not finish within 10 minutes — the package mirror stalled; the firewall step names what is missing."
  elif (( _nft_rc != 0 )); then
    log "Could not install nftables; the firewall step names what is missing."
  fi
  # --print installed nothing: the rule it plans is for the nftables it plans.
  # shellcheck disable=SC2034  # consumed cross-file by k3s-firewall.sh (_native_k3s_fw_pick)
  if tb_root_planning; then TRACEBLOC_K3S_FW_PLANNED=nft; fi
}

# _native_k3s_ensure_bridge_module -- k3s loads br_netfilter itself at every start,
# before the CNI bridge comes up, and sets net.bridge.bridge-nf-call-ip{,6}tables once
# it is loaded (k3s's syssetup). That load fails when this kernel has no such module:
# AlmaLinux 10.2's image ships it in a kernel package it does not install, so bridged
# pod traffic skipped kube-proxy's rules and no pod reached the API's ClusterIP.
# So when this kernel's modules.dep and modules.builtin name no
# br_netfilter, step b installs the file by its path with dnf or yum, which picks
# whichever kernel package holds it for the RUNNING kernel. A kernel that has it, a
# host whose module index this run cannot read (a container, tracebloc's WSL distro,
# which never gets here), and every other package manager are left as they were.
# Best-effort, like nftables: a refusal names what to install.
# TRACEBLOC_K3S_MODULES_DIR is the TEST SEAM: the running kernel's module directory.
_native_k3s_ensure_bridge_module() {
  local dir="${TRACEBLOC_K3S_MODULES_DIR:-/lib/modules/$(uname -r 2>/dev/null)}" ext ko pm rc=0
  [[ -r "${dir}/modules.dep" ]] || return 0
  if grep -qE '(^|/)br_netfilter\.ko' "${dir}/modules.dep" "${dir}/modules.builtin" 2>/dev/null; then return 0; fi
  case " ${PM_INSTALL:-} " in
    *" dnf "*) pm=dnf ;;
    *" yum "*) pm=yum ;;
    *) log "step b: native k3s: this kernel has no br_netfilter module, and this package manager cannot be asked for it by path"; return 0 ;;
  esac
  # The compression this kernel's modules carry, read from the bridge module's own
  # line (EL ships .ko.xz); .xz when the index names no bridge module.
  ext="$(sed -n 's#^kernel/net/bridge/bridge\.ko\(\.[a-z]*\)\{0,1\}:.*#=\1#p' "${dir}/modules.dep")"
  ext="${ext%%$'\n'*}"
  if [[ -n "$ext" ]]; then ext="${ext#=}"; else ext=".xz"; fi
  ko="${dir}/kernel/net/bridge/br_netfilter.ko${ext}"
  # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
  spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 600 "Installing the br_netfilter kernel module…" $PM_INSTALL "$ko" || rc=$?
  # A path is resolved through the repos' filelists metadata, which a dnf configured
  # without it cannot do. The packages that hold this kernel's modules are asked for
  # by name instead: on AlmaLinux 10.2 br_netfilter is in kernel-modules-extra, which
  # needs kernel-modules of the same version. ${dir##*/} is the running kernel's
  # version. A stalled mirror (124) is not asked twice.
  if (( rc != 0 && rc != 124 )); then
    rc=0
    # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
    spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 600 "Installing the br_netfilter kernel module…" $PM_INSTALL "kernel-modules-${dir##*/}" "kernel-modules-extra-${dir##*/}" || rc=$?
  fi
  if (( rc == 124 )) && [[ -n "${_TB_SPIN_SURVIVORS:-}" ]]; then
    error "Installing the br_netfilter kernel module did not finish within 10 minutes, and the package manager is still running and holding the package lock. Wait for it to finish, check your network/proxy, then re-run prepare-host or the installer."
  elif (( rc != 0 )); then
    warn "This kernel has no br_netfilter module, and installing it failed, so pods may not reach the cluster. Run 'sudo ${pm} install kernel-modules-${dir##*/} kernel-modules-extra-${dir##*/}' (after a kernel update, reboot first), then re-run the installer."
  elif ! tb_root_planning; then
    # --print installed nothing: its plan lists the install, so nothing is claimed here.
    log "step b: native k3s: installed ${ko}; k3s loads it when it starts"
  fi
}

# _native_k3s_install_linux -- step b on native k3s (D3, D9). k3s runs as root, so
# administrator rights are asked for ONCE, here, and the keepalive preflight_sudo
# starts covers the rest of the run. A usable Docker does not make this Tier 0:
# Tier 0 promises no administrator rights, and native k3s cannot keep that promise,
# so the run is Tier 2 and the record gets its root copy. Tier 1 (rootless) does not
# exist on k3s (D3). No Docker, no k3d and no kubectl download: upstream's install.sh
# links kubectl to k3s wherever root's PATH has none.
#
# The one exception (1.1g): a host an administrator prepared for this user
# (_native_k3s_prepared_for_me) is adopted at Tier 0, decided before anything asks
# for a password. Every refusal for administrator rights names prepare-host.
_native_k3s_install_linux() {
  local why=""
  if [[ "$(id -u 2>/dev/null)" != "0" ]]; then
    if why="$(_native_k3s_prepared_for_me)"; then
      _native_k3s_adopt_tools
      return 0
    fi
  fi
  # shellcheck disable=SC2034  # consumed cross-file (record.sh's root copy, setup-linux.sh's tools target, diagnose.sh)
  INSTALL_TIER=2
  # shellcheck disable=SC2034  # consumed cross-file by diagnose.sh
  INSTALL_TIER_REASON="native-k3s"
  log "step b: native k3s: tier 2 (k3s runs as root; administrator rights once)"
  # A password that fails is an administrator's prepare-host to answer (the helper
  # ends this remedy once the password is in). With no sudo at all, preflight_sudo
  # says so in its own words; the prepare-host way forward goes to its machine line.
  # On a host prepared for this user, what it still lacks and its own way forward
  # are the remedy, sudo or none (tb_fail_firm).
  if [[ -n "$why" ]]; then
    local next cmd
    next="$(_native_k3s_prepared_reason "$why" next)"; cmd="$(_native_k3s_prepared_reason "$why" cmd)"
    if [[ -n "$cmd" ]]; then tb_fail_next "$next" "$cmd"; else tb_fail_next "$next"; fi
    tb_fail_firm
  else
    tb_fail_next "Ask an administrator to run this once, then run the installer again:" "$(_native_k3s_prepare_host_cmd)"
  fi
  _native_k3s_host_prereqs "install system tools" "Re-run as a user allowed to sudo, or as root. $(_native_k3s_prepare_host_remedy "$why")"
  _set_tools_target
  local saved_umask
  saved_umask="$(umask)"
  umask 022
  tb_live_quiet "Installing system tools..."
  _helm_expect
  install_helm
  tb_live_done "System tools ready"
  umask "$saved_umask"
  log "step b: native k3s: system tools and helm ready (no Docker, no k3d, no kubectl download)"
  # The NVIDIA driver, toolkit and CDI spec (1.1i), before k3s first starts in step c.
  # Only for NVIDIA: native k3s sets up no other vendor in step b.
  if [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    dispatch_gpu_setup
  fi
}

# _native_k3s_host_prereqs WHAT [REMEDY] -- the privileged half of step b, which
# prepare-host runs too: administrator rights once (WHAT is what the password line
# says they are for, REMEDY what a refusal's machine line says to do), the package
# manager, the system tools, and a firewall tool.
_native_k3s_host_prereqs() {
  preflight_sudo "$1" "${2:-}"
  # The caller's remedy for the password (tb_fail_next) ends with it: a package or
  # firewall failure past it is not an administrator's to fix, and ends with the
  # default block.
  tb_fail_clear
  # tracebloc's WSL distro: its image carries what this would install
  # (scripts/spec/wsl-distro.env), nftables included; were nft ever missing there,
  # the firewall step refuses a host it cannot fence.
  if _native_k3s_on_wsl; then
    log "step b: native k3s in tracebloc's WSL distro: no package installs (the distro's image carries its tools)"
    return 0
  fi
  setup_pm
  apt_wait_for_lock
  install_system_deps
  _native_k3s_ensure_firewall_tool
  _native_k3s_ensure_bridge_module
}

# _native_k3s_refuse_host -- refuse, each by name, a host or a setting the native path
# does not serve in Stage 1, before anything is written. refuse_k3d_machine
# (reinstall.sh) also calls it before step a, so it stays
# read-only and reads nothing step a sets; a reinstall.bats case holds that
# for a setting.
# The OS case below is the one declaration of where native k3s runs: on Linux, the
# host itself; on a Mac, a node in Apple's VM (mac-container.sh, 2.1 part 6), whose
# own refusals (_mac_ct_refuse_host) say which Mac and which settings it serves;
# inside WSL, tracebloc's own distro only (_probe_wsl_ours),
# with its data off the Windows drives.
_native_k3s_refuse_host() {
  case "${OS:-}" in
    Linux) ;;
    Darwin)
      declare -F _mac_ct_refuse_host >/dev/null 2>&1 \
        || error "This installer build can't check whether this Mac can run native k3s (mac-container.sh is missing: stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
      _mac_ct_refuse_host
      return 0 ;;
    *) error "Native k3s runs on Linux and on a Mac with Apple silicon only for now, and this machine runs ${OS:-an unknown OS}." ;;
  esac
  declare -F _probe_wsl >/dev/null \
    || error "native k3s: probe.sh is not loaded, so this run cannot tell whether it is inside WSL. Re-run the installer from a fresh download."
  # Inside WSL, native k3s runs in tracebloc's own distro, where the Windows
  # installer runs this core, and nowhere else.
  if _probe_wsl; then
    declare -F _probe_wsl_ours >/dev/null \
      || error "native k3s: this probe.sh cannot tell tracebloc's WSL distro from another (stale bootstrap). Re-run the installer from a fresh download."
    _probe_wsl_ours \
      || error "Inside WSL, native k3s runs only in tracebloc's own distro, '${TB_WSL_DISTRO}', which the Windows installer sets up, and this is $(_native_k3s_wsl_which). $(_native_k3s_wsl_way_out)"
    _native_k3s_refuse_windows_drive
  fi
  # hostpath and HOST_DATASET_DIR are served: the node is the host,
  # so the chart's hostPath PVs name host_data_dir and the dataset dir themselves
  # (install-client-helm.sh, _hostpath_paths_block). validate_config still refuses a
  # dataset dir under node-local, on both substrates.
  _native_k3s_check_version
}

# _native_k3s_on_wsl -- native k3s inside tracebloc's WSL distro: Linux, and
# _probe_wsl_ours. The one predicate the WSL steps read:
# step b runs no package manager (_native_k3s_host_prereqs), because the distro's
# image carries what it would install, nftables for step c's firewall among them
# (scripts/spec/wsl-distro.env). Any other WSL distro never gets
# that far: _native_k3s_refuse_host refuses it first.
_native_k3s_on_wsl() {
  tb_in_wsl_distro
}

# _native_k3s_wsl_which -- the WSL distro this run is in, for a refusal: its name,
# that WSL passed none, or that the name came without a WSL kernel (exported by
# hand on another Linux, or a stale probe of the kernel).
_native_k3s_wsl_which() {
  if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
    printf '%s' "a WSL distro whose name this run was not given (WSL_DISTRO_NAME is empty)"
  elif declare -F _probe_wsl_kernel >/dev/null 2>&1 && _probe_wsl_kernel; then
    printf "the distro '%s'" "$WSL_DISTRO_NAME"
  else
    printf "a shell whose WSL_DISTRO_NAME says '%s', on a kernel that is not WSL's" "$WSL_DISTRO_NAME"
  fi
}

# _native_k3s_wsl_way_out -- that refusal's way out: install.ps1 on WSL's kernel. On
# another, only WSL's names make this shell look like WSL (refuse_wsl_run, host.sh,
# takes it for Linux), and unsetting them is a way out where install.ps1 cannot run.
_native_k3s_wsl_way_out() {
  if declare -F _probe_wsl_kernel >/dev/null 2>&1 && _probe_wsl_kernel; then
    printf '%s' "Install from Windows with install.ps1."
  else
    printf '%s' "If this is not WSL, unset WSL_DISTRO_NAME and WSL_INTEROP, then re-run; inside WSL, install from Windows with install.ps1."
  fi
}

# _native_k3s_refuse_windows_drive -- in tracebloc's WSL distro, refuse by name a data
# path on a Windows drive (drvfs, _probe_windows_drive): k3s's data and its default
# volumes (TB_K3S_DATA_PATH), the data dir (host_data_dir: the volumes' directory when
# it is not the default, and hostpath's), and the dataset dir. On
# Windows the volumes, the database's among them, live on the distro's own disk, and a
# dataset is a Linux-side mount, never drvfs. A path whose filesystem this run cannot
# read is "cannot tell", refused the same way. Read-only.
_native_k3s_refuse_windows_drive() {
  local name path what rc
  for name in TB_K3S_DATA_PATH host_data_dir HOST_DATASET_DIR; do
    path="${!name:-}"
    [[ -n "$path" ]] || continue
    # Before validate_config: the data dir is read as it will read it, under $HOME.
    [[ "$name" != host_data_dir ]] || path="$(_tb_home_path "$path")"
    case "$name" in
      TB_K3S_DATA_PATH) what="k3s's data directory ${path}" ;;
      host_data_dir)    what="The data directory ${path} (TRACEBLOC_HOST_DATA_DIR, --data-dir)" ;;
      *)                what="The dataset directory ${path} (TRACEBLOC_HOST_DATASET_DIR)" ;;
    esac
    rc=0; _probe_windows_drive "$path" || rc=$?
    case "$rc" in
      1) ;;
      0) error "${what} is on a Windows drive (drvfs). In tracebloc's WSL distro, tracebloc keeps its data on the distro's own disk and mounts datasets Linux-side, never from a Windows drive. Choose a path inside the distro, then re-run." ;;
      *) error "native k3s: this run cannot read which filesystem holds ${path} (${what%% (*}), so it cannot tell whether it is on a Windows drive (drvfs), where tracebloc never keeps its data. Check that /proc/self/mounts is readable, then re-run." ;;
    esac
  done
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
  if ! tb_root test -e "$srv"; then
    tb_root test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether an earlier k3s left its cluster state in ${srv}. Check that 'sudo true' runs, then re-run."
    return 0
  fi
  entries="$(tb_root ls -A "$srv")" \
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
    if tb_root test -e "$p"; then found="${found:+${found}, }${p}"; fi
  done
  if [[ -z "$found" ]]; then
    # `test -e` fails for a missing path AND for a sudo that did not run (a dropped
    # credential, no tty): only a root read of a path that always exists tells them
    # apart. A sudo that is down is "cannot tell", never "no k3s here", which would
    # skip the foreign-k3s refusal below and run the leftover guard over a live
    # cluster. Same probe _native_k3s_config_value makes, after the reads it
    # disambiguates.
    tb_root test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether a k3s is already on this machine, and it never sets up k3s over one it cannot see. Check that 'sudo true' runs, then re-run."
    _native_k3s_refuse_server_state
    return 1
  fi
  if ! tb_root test -e "$TB_K3S_AGENT_UNIT_PATH"; then
    # Same probe as above: this `test -e` also fails when sudo stopped answering after
    # the first reads, and an agent unit root could not see must not read as no agent
    # unit, which would let a foreign agent be adopted as ours.
    tb_root test -d / || error "native k3s: sudo did not answer, so this run cannot tell whether an agent unit is on this machine, and it never adopts a k3s it cannot fully see. Check that 'sudo true' runs, then re-run."
    if tb_root test -e "$TB_K3S_CONFIG_PATH"; then
      body="$(tb_root cat "$TB_K3S_CONFIG_PATH")" \
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

# _native_k3s_binary_due -- 0 when this run downloads the k3s binary: none at
# TB_K3S_BIN_PATH, or one that is not the pinned release (the run after a pin bump).
# Step c downloads on it, and preflight probes the download hosts on it, so the two
# cannot disagree. A pin that cannot be derived counts as due:
# preflight then probes, and step c refuses it by name.
_native_k3s_binary_due() {
  local want
  want="$(_native_k3s_release_tag 2>/dev/null)" || return 0
  [[ "$(_native_k3s_installed_version)" != "$want" ]]
}

# _native_k3s_wait_for_kubeconfig -- wait for k3s to write its kubeconfig, starting
# the count of the ONE budget it shares with the API wait (TB_K3S_WAITED_S). The merge
# reads the file, and the API wait asks the merged context by name.
_native_k3s_wait_for_kubeconfig() {
  local budget
  budget="$(_api_wait_budget_s)"
  TB_K3S_WAITED_S=0; TB_K3S_WAIT_T0="$(date +%s)"
  # --print: nothing ran, so there is nothing to wait for or read back.
  if tb_root_planning; then return 0; fi
  log "Waiting for k3s to start and its API server to answer (up to ${budget}s)..."
  until tb_root test -s "$TB_K3S_KUBECONFIG_PATH"; do
    _native_k3s_budget_left "$budget" \
      || error "k3s did not write ${TB_K3S_KUBECONFIG_PATH} within ${budget}s. It's safe to re-run this installer; 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why it is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
}

# _native_k3s_run_state -- k3s's state in systemd's own word (`systemctl is-active
# k3s`, which needs no root), printed, and what it means here: 0 running, 1 stopped
# (a state _native_k3s_ensure_running starts), 2 no state this run can read. One
# reading for the create path, which starts what it calls stopped, and for the
# stop-and-check gate (assess.sh), which says it will.
_native_k3s_run_state() {
  local state
  state="$(_bounded 10 systemctl is-active k3s 2>/dev/null)" || true
  printf '%s' "$state"
  case "$state" in
    active|reloading|refreshing) return 0 ;;
    inactive|failed|activating|deactivating|maintenance) return 1 ;;
    *) return 2 ;;
  esac
}

# _native_k3s_ensure_running -- start k3s when it is not running, after step 3.
# Upstream's script starts the unit only when its own hashes changed
# (service_enable_and_start: "No change detected so skipping service start"), and
# step 3 restarts it only when it replaced the binary or a file of ours changed. So
# on an unchanged re-run a stopped k3s would stay down, and the waits would spend
# their whole budget on it.
# A running k3s is left alone: INSTALL_K3S_FORCE_RESTART would restart it on every
# re-run. The state is systemd's own word (_native_k3s_run_state); one it cannot
# give is "cannot tell", refused, never read as running.
_native_k3s_ensure_running() {
  local state rc=0
  state="$(_native_k3s_run_state)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) error "native k3s: this run cannot tell whether k3s is running ('systemctl is-active k3s' answered '${state:-nothing}'), so it neither starts k3s nor waits on it. Check that 'systemctl status k3s' answers, then re-run; it's safe to re-run this installer." ;;
  esac
  # --print ran no install.sh, and on a new k3s that is what starts it: here only a k3s
  # already set up (its unit on disk) and stopped is started, so only that one is listed.
  if tb_root_planning && ! tb_root test -e "$TB_K3S_UNIT_PATH"; then return 0; fi
  log "native k3s: k3s is not running (systemd state '${state}'); starting it."
  tb_root systemctl start k3s \
    || error "native k3s: k3s was not running (systemd state '${state}') and did not start. 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why; it's safe to re-run this installer."
}

# _native_k3s_create_cluster -- step c on native k3s. The refusals first (on a new
# k3s, the pre-create fit gate among them), then each artefact in the order it must
# exist, recorded with tb_record_write the moment it does, so a run that fails at
# step N leaves a record of steps 1 to N-1:
#   1. the firewall rule, before k3s first starts, so the API never listens unfenced;
#   2. the join token's pin, then config.yaml naming it, the
#      kubelet drop-in and (with a corporate CA) the CA and registries.yaml, each
#      with its explicit mode;
#   3. the verified binary and upstream's install.sh at the tag (the copy the
#      installer ships, verified), run scrubbed, then
#      k3s running: started when it is not (_native_k3s_ensure_running);
#   4. the merged kubeconfig, recorded BEFORE the API wait so a failed wait leaves
#      the context for delete, then the API (asked on that context by name, on one
#      budget with the wait for k3s.yaml), then the node password k3s wrote, then
#      the node Ready on that same budget: success is the node Ready, never
#      install.sh's exit 0 or an active unit;
#   5. the NVIDIA GPU's gate (1.1i), which may restart k3s once;
#   6. NO_PROXY for this process.
# A re-run on tracebloc's k3s (the node half of D11) re-renders every file and keeps
# the node name and ranges config.yaml froze. It replaces the binary only when its
# version is not the pin, and restarts k3s once, after the script, when it replaced
# the binary or a file it writes changed. The script runs on every pass: it rewrites
# the unit and k3s.service.env (the proxy home) and restarts k3s itself only when
# those changed while it ran; the binary is swapped before it, so a new binary is no
# change to it. A k3s that is not running after that is started, whatever changed.
#
# Two modes (1.1g). Prepared (prepare-host, TB_K3S_PREPARED) runs steps 1 to 3 as
# the administrator for a named user, then _native_k3s_prepared_finish. Adopted (that
# user's Tier 0 install, TB_K3S_ADOPTED) runs _native_k3s_adopt_cluster instead.
_native_k3s_create_cluster() {
  local present=0 tool aid apath name cidrs cgroup storage ca rc=0 src=0 want have tmp replaced=""
  # On a Mac, native k3s is the node in Apple's VM (mac-container.sh, 2.1 part 6).
  if [[ "${OS:-}" == "Darwin" ]]; then
    declare -F _mac_ct_create_cluster >/dev/null 2>&1 \
      || error "This installer build can't set up native k3s on a Mac (mac-container.sh is missing: stale bootstrap). Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
    _mac_ct_create_cluster
    return 0
  fi
  log "Setting up native k3s for '${cluster_name}'"
  if [[ "${TB_K3S_ADOPTED:-}" == 1 ]]; then
    _native_k3s_adopt_cluster
    return 0
  fi
  _native_k3s_refuse_host
  # A machine that runs tracebloc on k3d is refused before this, in main()
  # (reinstall.sh's refuse_k3d_machine, D10).
  _native_k3s_presence || present=$?
  # A new k3s only. A re-run of tracebloc's own k3s keeps its node and its data by
  # design.
  if [[ "$present" -eq 1 ]]; then
    # Refuse a host the fit refuses before anything exists; on k3s the
    # gate sizes from the host. It runs before the leftover guard, so a refused host is
    # never asked about its data. Guarded: cluster.sh can be sourced without
    # install-client-helm.sh.
    if declare -F _precreate_fit_gate >/dev/null 2>&1; then _precreate_fit_gate; fi
    # D5: a new k3s must not silently adopt an earlier install's data.
    guard_leftover_data
  fi

  # 1. The firewall.
  _native_k3s_fw_apply
  # The live lines are the Mac's (_mac_ct_create_cluster).
  tb_live "Preparing local container runtime..."
  _native_k3s_binary_expect
  tool="$(_native_k3s_fw_tool)"
  IFS=$'\t' read -r aid apath < <(_native_k3s_fw_artefact "$tool")
  tb_record_write firewall-rule "$aid" "$apath"
  tb_record_write file firewall-rules "$(_native_k3s_fw_file "$tool")"

  # 2. The configuration.
  name="$(_native_k3s_node_name)" || _native_k3s_node_name_stop "$?"
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
  tb_record_write file k3s-token "$TB_K3S_TOKEN_PATH"
  tb_record_write file k3s-config "$TB_K3S_CONFIG_PATH"
  tb_record_write file kubelet-config "$TB_KUBELET_CONFIG_K3S_PATH"
  if [[ -n "$ca" ]]; then
    tb_record_write file ca "$TB_K3S_CA_PATH"
    tb_record_write file registries "$TB_K3S_REGISTRIES_PATH"
  fi
  # Before k3s starts, so no container is ever started stacked.
  _native_k3s_apparmor_runc

  # 3. The binary and the install script.
  want="$(_native_k3s_release_tag)" || error "native k3s: cannot derive the k3s release from K8S_VERSION=${K8S_VERSION:-<empty>}."
  have="$(_native_k3s_installed_version)"
  if _native_k3s_binary_due; then
    log "native k3s: installing k3s ${want}${have:+ over ${have}}."
    _native_k3s_fetch_binary "$ARCH_DL" "$TB_K3S_BIN_PATH"
    replaced=1
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-sh-XXXXXX")" || error "native k3s: could not create a temporary directory for k3s's install script."
  _native_k3s_stage_install_script "${tmp}/install.sh"
  # Its own lines are for the log: what it creates is in the install record.
  tb_machine_lines _native_k3s_run_install_script "${tmp}/install.sh" \
    || { rm -rf "$tmp"; error "k3s's install script failed. 'sudo journalctl -u k3s' says why; it's safe to re-run this installer."; }
  rm -rf "$tmp"
  tb_record_write k3s-install "$cluster_name" "$TB_K3S_UNINSTALL_PATH"
  # On a re-run the script never restarts k3s for us: it restarts only when its own
  # hashes changed while it ran, and it hashes the binary at its start, after the
  # swap above, so a replaced binary is no change to it ("No change detected so
  # skipping service start"). config.yaml is not in its set at all. So a replaced
  # binary or a changed file of ours is this function's one restart to make, or the
  # old k3s keeps running until a reboot. A new k3s is
  # started by the script itself.
  if [[ "$present" -eq 0 && ( -n "$replaced" || -n "$TB_K3S_FILES_CHANGED" ) ]]; then
    if [[ -n "$replaced" ]]; then
      log "native k3s: k3s ${want} replaced ${have:-the previous binary}; restarting k3s to run it."
    else
      log "native k3s: ${TB_K3S_FILES_CHANGED} changed; restarting k3s to read it."
    fi
    tb_root systemctl restart k3s || error "k3s did not restart after its binary or configuration changed. 'sudo journalctl -u k3s' says why; it's safe to re-run this installer."
  fi
  # Neither the script nor the restart above starts a stopped k3s on an unchanged re-run.
  _native_k3s_ensure_running

  # 4. The kubeconfig, the API and the node password. Prepared mode finishes on its
  # own path (_native_k3s_prepared_finish): the administrator's kubeconfig is not
  # the user's, so it merges nothing and records no context.
  tb_live_next "Configuring your secure environment..."
  _native_k3s_wait_for_kubeconfig
  if [[ "${TB_K3S_PREPARED:-}" == 1 ]]; then
    _native_k3s_prepared_finish "$name"
    tb_live_stop
    return 0
  fi
  _native_k3s_merge_kubeconfig
  tb_record_write kube-context "$(_native_k3s_context)" "$(_native_k3s_kubeconfig_target)"
  _native_k3s_wait_for_api
  tb_record_write file node-password "$TB_K3S_NODE_PASSWORD_PATH"
  _native_k3s_wait_for_node_ready "$name"

  # 5. The NVIDIA GPU: wired only when k3s's own containerd registered the runtime.
  _native_k3s_gpu_wire "$name"

  # 6. This process's NO_PROXY: the RFC1918 defaults cover both range pairs.
  _export_host_no_proxy
  # No line of its own: its result is step c's "✔ Secure environment created".
  tb_live_stop
}
