#!/usr/bin/env bash
# =============================================================================
#  mac-container.sh -- Apple's `container` runtime for the macOS node
#  (RFC-0175 D6, slim client 2.1 part 1).
# -----------------------------------------------------------------------------
#  On macOS, k3s runs as one container in a Linux micro-VM from Apple's open-source
#  `container` runtime. Apple's installer writes /usr/local and needs an
#  administrator; the payload does not. So the bootstrap takes Apple's signed
#  package at the pinned version, checks it, and unpacks it into the user's own
#  folder: no password, no dialog, nothing written outside the home (D6).
#
#  Part 1 puts the runtime on disk, and part 2 (below) starts it. Part 6 (the end of
#  this file) makes the path reachable behind TRACEBLOC_SUBSTRATE=k3s on a Mac: step b
#  runs _mac_ct_install_macos, step c _mac_ct_create_cluster.
#
#  Three checks, in order, each refused by name, and nothing is put in place until
#  all three pass:
#    1. the package's sha256 equals the pin (facts.env APPLE_CONTAINER_PKG_SHA256);
#    2. pkgutil says it is signed for distribution and notarised, and its leaf
#       certificate carries the pinned Team ID (APPLE_CONTAINER_TEAM_ID). The digest
#       already fixes the bytes; this proves a pin bump points at Apple's package;
#    3. every Mach-O in the payload passes `codesign --verify --strict` and is signed
#       by that Team ID, and bin/container is one of them. A check that finds no
#       program is blind, not clean.
#  The payload is unpacked into a staging folder beside its final place, checked,
#  marked with the package it came from, and only then renamed in, so a half-unpack
#  is never used. A re-run reuses a marked unpack of the pin after re-checking its
#  programs. Anything else at that place is refused, never deleted: it is in the
#  user's home, and nothing proves this installer wrote it.
#
#  The package check prints a whole sentence. The checks of an unpacked folder
#  print a finding about that folder, a clause, because two callers word it: the
#  unpack ("in the package's payload, <finding>") and the reuse ("<folder> is already
#  there, but <finding>"). Each prints nothing and returns 0 when it passes; the
#  caller cleans up and refuses with the finding.
#
#  macOS tools only (pkgutil, codesign, file, shasum), under bash 3.2. The bats
#  suite runs in both unit jobs with those tools stubbed (mac-container.bats).
# =============================================================================

TB_MAC_CT_MARKER=".tracebloc-verified"

# _mac_ct_version_ok VERSION -- 0 when VERSION is a release tag like 1.4.1.
_mac_ct_version_ok() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# _mac_ct_norm_path PATH -- PATH with repeated / collapsed and a trailing / dropped (/ stays
# /). Apple's container CLI hands launchd its roots in this spelling, so every root this
# installer derives, and every root it reads back from launchd, is compared in it: a HOME
# ending in / (macOS's TMPDIR does) would otherwise read this installer's own system as
# another's (client-dev#1941).
_mac_ct_norm_path() {
  local p="${1:-}" one=/ two=//
  # Through variables, not \/ in the replacement: bash 3.2 keeps that backslash inside "".
  while [[ "$p" == *//* ]]; do p="${p//$two/$one}"; done
  [[ "$p" == ?*/ ]] && p="${p%/}"
  printf '%s' "$p"
}

# _mac_ct_home -- the runtime's folder (D6), normalised. TRACEBLOC_MAC_CT_HOME is the TEST
# SEAM. A HOME that is empty, relative or / (in any spelling, // included) would put the
# runtime in a system folder, so it is refused.
_mac_ct_home() {
  local h
  if [[ -n "${TRACEBLOC_MAC_CT_HOME:-}" ]]; then _mac_ct_norm_path "$TRACEBLOC_MAC_CT_HOME"; return 0; fi
  h="$(_mac_ct_norm_path "${HOME:-}")"
  if [[ "$h" != /?* ]]; then
    echo "Apple container: HOME is '${HOME:-}', not a home folder, so there is nowhere to unpack the runtime." >&2
    return 1
  fi
  printf '%s/Library/Application Support/tracebloc/container' "$h"
}

# _mac_ct_install_root [VERSION] -- where VERSION (default: the pin) is unpacked: one
# folder per version, so a pin bump unpacks beside the old runtime instead of over it.
_mac_ct_install_root() {
  local v="${1:-${TB_APPLE_CONTAINER_VERSION:-}}" home
  _mac_ct_version_ok "$v" || { echo "Apple container: '${v}' is not a release version (like 1.4.1)." >&2; return 1; }
  home="$(_mac_ct_home)" || return 1
  printf '%s/%s' "$home" "$v"
}

# _mac_ct_pkg_name [VERSION] / _mac_ct_pkg_url [VERSION] -- the signed package's asset
# name and its release URL, derived from the version, never pinned beside it.
_mac_ct_pkg_name() {
  local v="${1:-${TB_APPLE_CONTAINER_VERSION:-}}"
  _mac_ct_version_ok "$v" || { echo "Apple container: '${v}' is not a release version (like 1.4.1)." >&2; return 1; }
  printf 'container-%s-installer-signed.pkg' "$v"
}
_mac_ct_pkg_url() {
  local v="${1:-${TB_APPLE_CONTAINER_VERSION:-}}" name
  name="$(_mac_ct_pkg_name "$v")" || return 1
  printf 'https://github.com/apple/container/releases/download/%s/%s' "$v" "$name"
}

# _mac_ct_fetch_pkg DIR -- download the pinned package into DIR (a temporary folder the
# caller made) and verify it against the pinned sha256. On any failure DIR is removed
# and the install stops by name. Same bounds as k3s.sh's binary download: a stall
# floor, not a hard deadline, on a ~118 MB file.
_mac_ct_fetch_pkg() {
  local dir="$1" want="${TB_APPLE_CONTAINER_PKG_SHA256:-}" url name
  [[ -n "$want" ]] || { rm -rf "$dir"; error "Apple container: no pinned sha256 for the package is stamped in common.sh -- run scripts/check-facts.sh --write."; }
  url="$(_mac_ct_pkg_url)" && name="$(_mac_ct_pkg_name)" \
    || { rm -rf "$dir"; error "Apple container: cannot derive the package from TB_APPLE_CONTAINER_VERSION='${TB_APPLE_CONTAINER_VERSION:-}'."; }
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "$url" -o "${dir}/${name}" \
    || { rm -rf "$dir"; error "Couldn't download Apple's container package from ${url}. Check that this machine can reach github.com and release-assets.githubusercontent.com, then re-run."; }
  # 117.8 MB at 1.4.1; an error page or a truncated stream is far shorter.
  _assert_download_size "${dir}/${name}" 100000000 "Apple's container package" "$dir"
  _verify_sha256 "$want" "${dir}/${name}" \
    || { rm -rf "$dir"; error "Apple's container package downloaded from ${url} does not match its pinned sha256 (${want}), so it was not unpacked. Something between this machine and GitHub changed the file; do not install it by hand. Re-run on a network that does not rewrite downloads."; }
}

# _mac_ct_check_pkg PKG -- pkgutil's verdict on PKG (check 2). The lines are the ones
# pkgutil prints on macOS 26 for Apple's package (spike S-M, RFC-0175 section 12.6):
#   Status: signed by a developer certificate issued by Apple for distribution
#   Notarization: trusted by the Apple notary service
#   1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
# A pkgutil that does not answer is "cannot tell", never a pass.
_mac_ct_check_pkg() {
  local pkg="$1" team="${TB_APPLE_CONTAINER_TEAM_ID:-}" out rc=0 leaf
  [[ -n "$team" ]] || { echo "Apple container: no pinned Team ID is stamped in common.sh -- run scripts/check-facts.sh --write."; return 1; }
  out="$(_bounded 60 pkgutil --check-signature "$pkg" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "Apple container: pkgutil could not check the package's signature (exit ${rc}), so this run cannot tell who signed it, and it was not unpacked."
    return 1
  fi
  if ! grep -qF 'Status: signed by a developer certificate issued by Apple for distribution' <<<"$out"; then
    echo "Apple container: pkgutil does not say the package is signed for distribution, so it was not unpacked."
    return 1
  fi
  if ! grep -qF 'Notarization: trusted by the Apple notary service' <<<"$out"; then
    echo "Apple container: pkgutil does not say Apple's notary service trusts the package, so it was not unpacked."
    return 1
  fi
  leaf="$(awk '/^ *1\. /{ sub(/^ *1\. /, ""); print; exit }' <<<"$out")"
  if [[ "$leaf" != "Developer ID Installer: "*" (${team})" ]]; then
    echo "Apple container: the package is signed by '${leaf:-nobody}', not by a Developer ID Installer of Team ID ${team}, so it was not unpacked."
    return 1
  fi
}

# _mac_ct_check_binaries ROOT -- check 3, over an unpacked payload: every Mach-O under
# ROOT passes codesign's strict check and is signed by the pinned Team ID, and
# bin/container is among them. Mach-O is what file(1) says, so the shell scripts Apple
# ships beside the programs are not codesign's to judge, and a program Apple adds in a
# later release is checked without a list here to update.
_mac_ct_check_binaries() {
  local root="$1" team="${TB_APPLE_CONTAINER_TEAM_ID:-}" list f kind got out rc n=0 cli=""
  [[ -n "$team" ]] || { echo "no pinned Team ID is stamped in common.sh to check it against (run scripts/check-facts.sh --write)"; return 1; }
  command -v file >/dev/null 2>&1 \
    || { echo "file(1) is not on this Mac, so this run cannot tell which of its files are programs"; return 1; }
  list="$(find "$root" -type f -perm -0100 2>/dev/null)" \
    || { echo "its files could not be listed, so this run cannot tell whether its programs are Apple's"; return 1; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    kind="$(file -b "$f" 2>/dev/null)" || kind=""
    [[ "$kind" == *Mach-O* ]] || continue
    n=$((n + 1))
    [[ "$f" != "${root}/bin/container" ]] || cli=1
    rc=0; _bounded 60 codesign --verify --strict "$f" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "codesign did not answer within 60s about ${f#"${root}"/}, so this run cannot tell whether it passes the strict check"
      return 1
    elif [[ "$rc" -ne 0 ]]; then
      echo "${f#"${root}"/} does not pass codesign's strict check"
      return 1
    fi
    # Read first, parse second: piped into sed, codesign's status would be sed's, and a
    # timeout would read as a program signed by nobody.
    rc=0; out="$(_bounded 60 codesign -dv "$f" 2>&1)" || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "codesign did not answer within 60s about ${f#"${root}"/}, so this run cannot tell who signed it"
      return 1
    elif [[ "$rc" -ne 0 ]]; then
      echo "codesign could not read ${f#"${root}"/} (exit ${rc}), so this run cannot tell who signed it"
      return 1
    fi
    got="$(sed -n 's/^TeamIdentifier=//p' <<<"$out")"
    if [[ "$got" != "$team" ]]; then
      echo "${f#"${root}"/} is signed by Team ID '${got:-none}', not ${team}"
      return 1
    fi
  done <<<"$list"
  if [[ "$n" -eq 0 ]]; then
    echo "no program was found in it, so this run cannot tell whether it is Apple's runtime"
    return 1
  fi
  if [[ -z "$cli" ]]; then
    echo "it has no bin/container, so it is not the runtime this installer pins"
    return 1
  fi
}

# _mac_ct_marker_body -- what a verified unpack of the pin records about its package.
_mac_ct_marker_body() {
  printf 'version=%s\npkg_sha256=%s\n' "${TB_APPLE_CONTAINER_VERSION:-}" "${TB_APPLE_CONTAINER_PKG_SHA256:-}"
}

# _mac_ct_check_marker ROOT -- ROOT carries this installer's marker for the pinned
# package. An unreadable marker is "cannot tell", like a missing one.
_mac_ct_check_marker() {
  local root="$1" have
  if [[ ! -f "${root}/${TB_MAC_CT_MARKER}" ]]; then
    echo "it has no ${TB_MAC_CT_MARKER} marker, so nothing shows this installer unpacked and checked it"
    return 1
  fi
  have="$(cat "${root}/${TB_MAC_CT_MARKER}" 2>/dev/null)" \
    || { echo "its ${TB_MAC_CT_MARKER} marker cannot be read, so this run cannot tell which package it came from"; return 1; }
  if [[ "$have" != "$(_mac_ct_marker_body)" ]]; then
    echo "its ${TB_MAC_CT_MARKER} marker names another package than the pinned one (${TB_APPLE_CONTAINER_VERSION:-}, sha256 ${TB_APPLE_CONTAINER_PKG_SHA256:-})"
    return 1
  fi
}

# _mac_ct_unpack PKG DEST [JUNK] -- unpack the checked PKG's payload to DEST, which must
# not exist: expanded into a staging folder beside DEST, its programs checked, the
# marker written, then renamed in. Every failure removes the staging folder, and JUNK
# when given (the download's temporary folder), and stops by name.
_mac_ct_unpack() {
  local pkg="$1" dest="$2" junk="${3:-}" home stage why
  home="${dest%/*}"
  mkdir -p "$home" || { _mac_ct_drop "$junk"; error "Apple container: could not create ${home}."; }
  stage="$(mktemp -d "${home}/.staging.XXXXXX")" \
    || { _mac_ct_drop "$junk"; error "Apple container: could not create a staging folder in ${home}."; }
  _bounded 300 pkgutil --expand-full "$pkg" "${stage}/expanded" >/dev/null 2>&1 \
    || { _mac_ct_drop "$stage" "$junk"; error "Apple container: pkgutil could not unpack ${pkg##*/}, so the runtime was not put in place. It's safe to re-run this installer."; }
  [[ -d "${stage}/expanded/Payload" ]] \
    || { _mac_ct_drop "$stage" "$junk"; error "Apple container: ${pkg##*/} unpacked with no Payload folder, so it is not the package this installer pins, and the runtime was not put in place."; }
  if ! why="$(_mac_ct_check_binaries "${stage}/expanded/Payload")"; then
    _mac_ct_drop "$stage" "$junk"; error "Apple container: in the package's payload, ${why}, so the runtime was not put in place."
  fi
  _mac_ct_marker_body > "${stage}/expanded/Payload/${TB_MAC_CT_MARKER}" \
    || { _mac_ct_drop "$stage" "$junk"; error "Apple container: could not write the ${TB_MAC_CT_MARKER} marker in ${stage}."; }
  mv "${stage}/expanded/Payload" "$dest" \
    || { _mac_ct_drop "$stage" "$junk"; error "Apple container: could not move the checked runtime into ${dest}."; }
  _mac_ct_drop "$stage"
}

# _mac_ct_drop [DIR...] -- remove this run's own temporary folders; empty names are skipped.
_mac_ct_drop() {
  local d
  for d in "$@"; do [[ -z "$d" ]] || rm -rf "$d"; done
}

# _mac_ct_ensure_runtime -- the pinned runtime, unpacked and checked, at
# _mac_ct_install_root. A marked unpack of the pin is reused once its programs pass
# check 3 again; anything else at that place is refused and left alone. Either way the
# install record names it (kind apple-container: id = the version, path = the runtime's
# home, every folder of which tracebloc delete removes; a runtime bump adds a second
# entry with the same path).
_mac_ct_ensure_runtime() {
  local dest why tmp pkg
  dest="$(_mac_ct_install_root)" || error "Apple container: cannot tell where to unpack the runtime (above)."
  if [[ -e "$dest" ]]; then
    if why="$(_mac_ct_check_marker "$dest")" && why="$(_mac_ct_check_binaries "$dest")"; then
      log "Apple container ${TB_APPLE_CONTAINER_VERSION}: reusing the checked runtime in ${dest}."
      tb_record_write apple-container "$TB_APPLE_CONTAINER_VERSION" "${dest%/*}"
      return 0
    fi
    error "Apple container: ${dest} is already there, but ${why}. This installer does not delete it: move that folder out of the way yourself, then re-run."
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-container-XXXXXX")" || error "Apple container: could not create a temporary folder for the download."
  _mac_ct_fetch_pkg "$tmp"
  pkg="${tmp}/$(_mac_ct_pkg_name)"
  if ! why="$(_mac_ct_check_pkg "$pkg")"; then
    rm -rf "$tmp"; error "$why"
  fi
  _mac_ct_unpack "$pkg" "$dest" "$tmp"
  rm -rf "$tmp"
  tb_record_write apple-container "$TB_APPLE_CONTAINER_VERSION" "${dest%/*}"
  log "Apple container ${TB_APPLE_CONTAINER_VERSION}: unpacked and checked in ${dest}."
}

# =============================================================================
#  Part 2: the runtime started, on our kernel and the pinned init image.
# -----------------------------------------------------------------------------
#  `container system start` with the install root from part 1, an app root and a log
#  root beside it, and --disable-kernel-install, so nothing is fetched from Kata's
#  servers. The kernel is ours: the file ARM's apple-container-kernel.yml publishes,
#  pulled from ghcr.io by its sha256 (MAC_KERNEL_SHA256) and kept by digest, then set
#  with `container system kernel set`. The init image is set by digest
#  (APPLE_VMINIT_DIGEST) in the install root's own config.toml, never ~/.config, and
#  the running system is held to it. This is the shape of ARM's canary
#  (scripts/apple-container-pin.sh cmd_canary), which boots exactly these pins on the
#  e2e Mac.
#
#  The layout is the spike kit's (RFC-0175 section 12.6): <home>/<version> is the
#  install root, <home>/app the app root (images, kernels, volumes: kept across a
#  runtime bump), <home>/logs the log root, <home>/kernel the kept kernel files.
#
#  The system is launchd's com.apple.container.apiserver in this user's GUI domain.
#  `system start` writes its plist into the app root, not ~/Library/LaunchAgents, with
#  CONTAINER_APP_ROOT and CONTAINER_INSTALL_ROOT in its environment (spike S-M), which
#  is how a run tells this installer's system from anyone else's. Anyone else's is
#  refused and left alone.
# =============================================================================

TB_MAC_CT_APISERVER="com.apple.container.apiserver"

# _mac_ct_app_root / _mac_ct_log_root / _mac_ct_kernel_dir -- the folders beside the
# install roots (see the layout above).
_mac_ct_app_root()   { local home; home="$(_mac_ct_home)" || return 1; printf '%s/app' "$home"; }
_mac_ct_log_root()   { local home; home="$(_mac_ct_home)" || return 1; printf '%s/logs' "$home"; }
_mac_ct_kernel_dir() { local home; home="$(_mac_ct_home)" || return 1; printf '%s/kernel' "$home"; }

# _mac_ct_vminit_ref -- the init image the system boots: the stamped repository and
# digest, joined by '@'. A repository with a tag or digest of its own, or a digest that
# is not sha256, is refused: the digest alone must decide what boots.
_mac_ct_vminit_ref() {
  local image="${TB_APPLE_VMINIT_IMAGE:-}" digest="${TB_APPLE_VMINIT_DIGEST:-}"
  if [[ ! "$image" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+$ ]]; then
    echo "Apple container: the stamped init image repository is '${image}', not a bare registry path like ghcr.io/org/vminit (run scripts/check-facts.sh --write)."
    return 1
  fi
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Apple container: the stamped init image digest is '${digest}', not sha256:<64 hex> (run scripts/check-facts.sh --write)."
    return 1
  fi
  printf '%s@%s' "$image" "$digest"
}

# _mac_ct_check_pins -- every pin the start needs is stamped and well formed: the init
# image (_mac_ct_vminit_ref), the kernel's sha256 and its ghcr.io repository. Prints the
# finding and returns 1 when one is not, so a caller stops before it fetches anything.
_mac_ct_check_pins() {
  local ref
  ref="$(_mac_ct_vminit_ref)" || { echo "$ref"; return 1; }
  if [[ ! "${TB_MAC_KERNEL_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Apple container: the stamped kernel sha256 is '${TB_MAC_KERNEL_SHA256:-}', not 64 hex digits (run scripts/check-facts.sh --write)."
    return 1
  fi
  if [[ ! "${TB_MAC_KERNEL_IMAGE:-}" =~ ^ghcr\.io(/[a-z0-9._-]+)+$ ]]; then
    echo "Apple container: the stamped kernel repository is '${TB_MAC_KERNEL_IMAGE:-}', not a ghcr.io path (run scripts/check-facts.sh --write)."
    return 1
  fi
}

# _mac_ct_system_state -- this user's container system: "none", "ours ROOT" (its app
# root is ours and its install root ROOT is one of this installer's version folders,
# both sides compared as _mac_ct_norm_path spells them), or "foreign". launchctl exits 113 for a service it does not know; any other failure
# is "cannot tell" (return 1), never "none", so a run never starts a second system
# beside one it could not see.
_mac_ct_system_state() {
  local app home out rc=0 have_app have_root
  app="$(_mac_ct_app_root)" && home="$(_mac_ct_home)" || return 1
  out="$(_bounded 30 launchctl print "gui/$(id -u)/${TB_MAC_CT_APISERVER}" 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 113 ]]; then echo none; return 0; fi
  if [[ "$rc" -ne 0 ]]; then
    echo "Apple container: launchctl could not say whether a container system is registered for this user (exit ${rc}), so this run cannot tell whether one is running." >&2
    return 1
  fi
  have_app="$(_mac_ct_norm_path "$(awk -F' => ' '$1 ~ /^[[:space:]]*CONTAINER_APP_ROOT$/ { print $2; exit }' <<<"$out")")"
  have_root="$(_mac_ct_norm_path "$(awk -F' => ' '$1 ~ /^[[:space:]]*CONTAINER_INSTALL_ROOT$/ { print $2; exit }' <<<"$out")")"
  if [[ "$have_app" == "$app" && "${have_root%/*}" == "$home" ]] && _mac_ct_version_ok "${have_root##*/}"; then
    echo "ours ${have_root}"
  else
    echo foreign
  fi
}

# _mac_ct_registry_token REPO -- an anonymous pull token for ghcr.io/REPO. The answer is
# one JSON object; sed reads its "token", because the Mac path has no python3 (a fresh
# Mac's /usr/bin/python3 opens the Command Line Tools dialog). curl's own error (a TLS
# failure behind a corporate proxy, say) is left on stderr: -sS prints it, and hiding it
# made every failure read as "cannot reach ghcr.io".
_mac_ct_registry_token() {
  local repo="$1" body token
  body="$(curl_secure -fsS "https://ghcr.io/token?scope=repository:${repo}:pull")" || body=""
  token="$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body")"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

# _mac_ct_ensure_kernel -- our kernel, kept by digest in _mac_ct_kernel_dir; its path is
# left in TB_MAC_CT_KERNEL_FILE (not printed, so a refusal is not swallowed by a
# command substitution). A kept file is reused when it still hashes to the pin; one that
# does not is refused and left alone (nothing proves what changed it). Otherwise the
# kernel is pulled from ghcr.io by the pin, checked, and renamed into place.
_mac_ct_ensure_kernel() {
  local want="${TB_MAC_KERNEL_SHA256:-}" image="${TB_MAC_KERNEL_IMAGE:-}" dir file repo token tmp why
  TB_MAC_CT_KERNEL_FILE=""
  why="$(_mac_ct_check_pins)" || error "$why"
  dir="$(_mac_ct_kernel_dir)" || error "Apple container: cannot tell where to keep the kernel (above)."
  file="${dir}/vmlinux-sha256-${want}"
  if [[ -e "$file" ]]; then
    _verify_sha256 "$want" "$file" \
      || error "Apple container: the kept kernel ${file} no longer hashes to its pinned sha256. This installer does not delete it: move it out of the way yourself, then re-run."
    TB_MAC_CT_KERNEL_FILE="$file"
    return 0
  fi
  repo="${image#ghcr.io/}"
  token="$(_mac_ct_registry_token "$repo")" \
    || error "Apple container: ghcr.io gave no pull token for ${image}. Check that this machine can reach ghcr.io (behind a corporate proxy, set TRACEBLOC_CA_BUNDLE=/path/to/corporate-ca.pem), then re-run."
  mkdir -p "$dir" || error "Apple container: could not create ${dir}."
  tmp="$(mktemp -d "${dir}/.download.XXXXXX")" || error "Apple container: could not create a download folder in ${dir}."
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/blobs/sha256:${want}" -o "${tmp}/vmlinux" \
    || { rm -rf "$tmp"; error "Couldn't download the kernel for Apple container from ${image}. Check that this machine can reach ghcr.io and pkg-containers.githubusercontent.com, then re-run."; }
  # About 30 MB at 6.18.35; an error page or a truncated stream is far shorter.
  _assert_download_size "${tmp}/vmlinux" 10000000 "the kernel for Apple container" "$tmp" "ghcr.io / pkg-containers.githubusercontent.com"
  _verify_sha256 "$want" "${tmp}/vmlinux" \
    || { rm -rf "$tmp"; error "The kernel downloaded from ${image} does not match its pinned sha256 (${want}), so it was not used. Something between this machine and ghcr.io changed the file; re-run on a network that does not rewrite downloads."; }
  mv "${tmp}/vmlinux" "$file" || { rm -rf "$tmp"; error "Apple container: could not move the checked kernel into ${file}."; }
  rm -rf "$tmp"
  TB_MAC_CT_KERNEL_FILE="$file"
}

# _mac_ct_write_vminit_config ROOT -- the install root's config.toml names the init
# image by digest. Written through a copy and renamed, and left as it is when it
# already says exactly that.
_mac_ct_write_vminit_config() {
  local root="$1" ref conf want
  ref="$(_mac_ct_vminit_ref)" || error "$ref"
  conf="${root}/etc/container/config.toml"
  want="$(printf '[vminit]\nimage = "%s"' "$ref")"
  [[ -f "$conf" && "$(cat "$conf" 2>/dev/null)" == "$want" ]] && return 0
  mkdir -p "${conf%/*}" || error "Apple container: could not create ${conf%/*}."
  printf '%s\n' "$want" > "${conf}.tmp" && mv "${conf}.tmp" "$conf" \
    || { rm -f "${conf}.tmp"; error "Apple container: could not write ${conf}."; }
}

# _mac_ct_stop_system -- stop the container system this installer's home runs, with its
# own binary, bounded, and show it is stopped: launchd no longer lists it. No system, or
# anyone else's, is left alone and is a success. A launchd that cannot say is "cannot
# tell", by name, and so is a system still registered after the stop. The live proof's
# EXIT trap and the darwin_k3s measurement (2.1 part 5b) stop the system through it.
_mac_ct_stop_system() {
  local state
  state="$(_mac_ct_system_state)" || { echo "Apple container: launchd cannot say whether the container system stopped."; return 1; }
  case "$state" in
    none | foreign) return 0 ;;
  esac
  _bounded 120 "${state#ours }/bin/container" system stop </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  state="$(_mac_ct_system_state)" || { echo "Apple container: launchd cannot say whether the container system stopped."; return 1; }
  [[ "$state" == none ]] || { echo "Apple container: the container system did not stop (state: ${state})."; return 1; }
}

# _mac_ct_start_failed ROOT LOGS -- `system start` failed or was cut off. Apple's CLI
# registers the apiserver with launchd before it waits on --timeout, so a failure can
# leave this installer's system registered, and the next run would find an `ours` it
# cannot ask. Look, stop what is ours and left behind, and say what is true: "safe to
# re-run" only when launchd shows nothing registered afterwards. Never returns.
_mac_ct_start_failed() {
  local root="$1" logs="$2" left running
  left="$(_mac_ct_system_state 2>/dev/null)" || left=unknown
  if [[ "$left" == ours\ * ]]; then
    running="${left#ours }"
    _bounded 120 "${running}/bin/container" system stop </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    left="$(_mac_ct_system_state 2>/dev/null)" || left=unknown
  fi
  case "$left" in
    none) error "Apple container: the container system did not start (its logs are in ${logs}). Nothing it started is left running, so it's safe to re-run this installer." ;;
    ours\ *) error "Apple container: the container system did not start (its logs are in ${logs}), and a system of this installer's is still registered. Stop it yourself (\"${running}/bin/container\" system stop), then re-run." ;;
    *) error "Apple container: the container system did not start (its logs are in ${logs}), and this run cannot tell whether it left a system registered. Run \"${root}/bin/container\" system stop, then re-run this installer." ;;
  esac
}

# _mac_ct_start_system -- the runtime from _mac_ct_ensure_runtime, started on our kernel
# and the pinned init image. Reuses this installer's running system when it runs the
# pinned runtime with the pinned init image; restarts it when it runs another of this
# installer's versions or another init image; refuses anyone else's.
_mac_ct_start_system() {
  local root app logs ref state running out why
  why="$(_mac_ct_check_pins)" || error "$why"
  root="$(_mac_ct_install_root)" && app="$(_mac_ct_app_root)" && logs="$(_mac_ct_log_root)" \
    || error "Apple container: cannot tell where the runtime lives (above)."
  ref="$(_mac_ct_vminit_ref)"
  [[ ! -e "${HOME}/.config/container/config.toml" ]] \
    || error "Apple container: ${HOME}/.config/container/config.toml exists, and it overrides the settings this installer pins (the init image). This installer does not change it: move it out of the way yourself, then re-run."
  state="$(_mac_ct_system_state)" || error "Apple container: cannot tell whether a container system is already running (above)."
  case "$state" in
    foreign) error "Apple container: another container system is already registered for this user, and it is not this installer's. This installer does not touch it: stop it yourself (container system stop), then re-run." ;;
  esac
  _mac_ct_ensure_kernel
  _mac_ct_write_vminit_config "$root"
  if [[ "$state" == "ours ${root}" ]]; then
    out="$(_bounded 60 "${root}/bin/container" system property list </dev/null 2>&1)" \
      || error "Apple container: the container system did not list its settings, so this run cannot tell which init image it boots. Nothing was stopped; re-run when it answers."
    if [[ "$out" == *"\"${ref}\""* ]]; then
      log "Apple container ${TB_APPLE_CONTAINER_VERSION}: the system is already running on the pinned init image."
    else
      state="ours ${root} (another init image)"
    fi
  fi
  if [[ "$state" == ours\ * && "$state" != "ours ${root}" ]]; then
    running="${state#ours }"; running="${running%% (*}"
    _bounded 120 "${running}/bin/container" system stop </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || error "Apple container: could not stop this installer's earlier container system, so the pinned one was not started. Stop it yourself (\"${running}/bin/container\" system stop), then re-run."
    # A stop that exits 0 is not a stop launchd agrees with: look again, and start only on none.
    state="$(_mac_ct_system_state)" \
      || error "Apple container: this installer's earlier container system was told to stop, but this run cannot tell whether it did (above), so the pinned one was not started. Run \"${running}/bin/container\" system stop, then re-run."
    [[ "$state" == none ]] \
      || error "Apple container: this installer's earlier container system was told to stop, but it is still registered, so the pinned one was not started. Stop it yourself (\"${running}/bin/container\" system stop), then re-run."
  fi
  if [[ "$state" == none ]]; then
    mkdir -p "$app" "$logs" || error "Apple container: could not create ${app} or ${logs}."
    _bounded 330 "${root}/bin/container" system start --install-root "$root" --app-root "$app" --log-root "$logs" \
      --disable-kernel-install --timeout 300 </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || _mac_ct_start_failed "$root" "$logs"
  fi
  _bounded 120 "${root}/bin/container" system kernel set --force --arch arm64 --binary "$TB_MAC_CT_KERNEL_FILE" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || error "Apple container: the container system refused the pinned kernel ${TB_MAC_CT_KERNEL_FILE}."
  out="$(_bounded 60 "${root}/bin/container" system property list </dev/null 2>&1)" \
    || error "Apple container: the container system did not list its settings, so this run cannot tell which init image it boots."
  [[ "$out" == *"\"${ref}\""* ]] \
    || error "Apple container: the running container system does not boot the pinned init image ${ref}."
  log "Apple container ${TB_APPLE_CONTAINER_VERSION}: running on kernel sha256:${TB_MAC_KERNEL_SHA256} and init image ${ref}."
}

# =============================================================================
#  Part 3: the node.
# -----------------------------------------------------------------------------
#  k3s runs as one container on the system part 2 started, in the shape spike S-M
#  measured (RFC-0175 section 12.6, the fresh-Mac kit's node_run):
#    - the image is rancher/k3s's linux/arm64 manifest, pulled by its digest
#      (K3S_IMAGE_ARM64_DIGEST, at the pinned K8S_VERSION);
#    - all its state is one volume, named like the container, at /var/lib/rancher/k3s;
#    - --cap-add ALL --read-only-path NONE --masked-path NONE, without which k3s stops
#      at "open /proc/sys/kernel/panic: read-only file system";
#    - the API published on 127.0.0.1:6443 only;
#    - --rosetta when Rosetta is installed, while the chart's MySQL pin is amd64;
#    - a fixed node IP: the container's address changes on every start, so the node
#      advertises a loopback alias, TB_MAC_CT_NODE_IP, that the entrypoint adds.
#  The config is _native_k3s_render_config's, never a fork, plus the Mac's own keys.
#  It reaches the node as ARGUMENTS (open decision 1, option b): the entrypoint
#  writes it, and the kubelet drop-in, into /etc/rancher/k3s, then execs k3s. The
#  host keeps its own copies in _mac_ct_node_dir: config.yaml (the node name and the
#  ranges, frozen there as on Linux), run-args (the argv the node was created with)
#  and k3s.yaml (fetched from the node).
#
#  A run whose argv differs from run-args recreates the node on its volume (measured:
#  the data is kept). A container or a volume of the node's name that run-args does
#  not vouch for is refused, never adopted (D5): nothing shows this installer made it.
#
#  The join token is pinned on the host, outside the volume (client-dev#1976): k3s
#  encrypts its datastore's bootstrap data with it, and without one it reads the
#  server/token it rewrites, unsynced, on every start. A VM killed seconds after a
#  start can tear that file, and k3s then refuses its own data on every start after
#  ("bootstrap data already found and encrypted with different token"). The token is
#  written once to _mac_ct_node_dir/token (0600) and reaches the node as an argument;
#  the entrypoint writes it to TB_MAC_CT_NODE_TOKEN_FILE before every start, and the
#  config names that file (`token-file`). A node made before the pin keeps the token
#  it already has (_mac_ct_node_token), never a fresh one.
#
#  "Ready" is a Ready condition whose heartbeat is newer than the start this run
#  made: for about 40 s after a restart the stored status is the old one (S-M).
#
#  Step c reaches it through _mac_ct_create_cluster (part 6).
# =============================================================================

# The node's address: TEST-NET-1 (RFC 5737), never routed, so it is free on any network.
TB_MAC_CT_NODE_IP="192.0.2.10"
# The interface flannel uses inside the node (the container's only one).
TB_MAC_CT_NODE_IFACE="eth0"
# The volume's size: a sparse ext4 image, so it takes only what is written.
TB_MAC_CT_NODE_VOLUME_SIZE="64g"
# What the node needs Rosetta for is an amd64 image; this file is there once it is installed.
TB_MAC_CT_ROSETTA_RUNTIME="/Library/Apple/usr/libexec/oah/libRosettaRuntime"
# Where the entrypoint puts the join token inside the node, and the file the config's
# `token-file` names: on the container's own disk, rewritten from the argument on every
# start, so a copy a killed VM tore never reaches k3s.
TB_MAC_CT_NODE_TOKEN_FILE="/etc/rancher/k3s/tracebloc-token"
# The node's entrypoint. $1 is config.yaml, $2 the kubelet drop-in, $3 the node IP, $4
# the join token. A token that is not one (empty, or not hex as _mac_ct_node_token
# makes and reads them) stops the node before k3s starts: k3s would make a new one. An
# address it cannot add, and that lo does not already carry, stops the node: k3s would
# advertise an address nothing answers on.
TB_MAC_CT_NODE_ENTRY='set -e
mkdir -p /etc/rancher/k3s
printf "%s\n" "$1" > /etc/rancher/k3s/config.yaml
printf "%s\n" "$2" > /etc/rancher/k3s/tracebloc-kubelet.yaml
case "$4" in ""|*[!0-9a-f]*) echo "tracebloc: the node was started without its join token" >&2; exit 1 ;; esac
(umask 077; printf "%s\n" "$4" > /etc/rancher/k3s/tracebloc-token)
ip addr add "$3/32" dev lo 2>/dev/null || case "$(ip -4 addr show dev lo)" in *"inet $3/32"*) ;; *) exit 1 ;; esac
exec /bin/k3s server'

# _mac_ct_refuse_host -- refuse, each by name, a host or a setting the macOS node does
# not serve, before anything is written. _native_k3s_refuse_host, the one declaration of
# where native k3s runs, calls it for a Mac (2.1 part 6), so it runs where Linux's
# refusals run, including before a k3d offboard (reinstall.sh): it stays read-only and
# reads nothing step a sets. The darwin_k3s measurement (2.1 part 5b) calls it too.
#   - The macOS floor, common.sh's one declaration (tb_mac_floor_verdict): Apple silicon,
#     since Apple's container runtime is arm64-only, with macOS TB_MACOS_FLOOR_MAJOR or
#     later, which the runtime needs (RFC-0175 D6). Its words are the floor's own
#     (tb_mac_floor_reason); this path adds the way back to k3d, which serves those Macs
#     until 2.1's flip. 2.4 (client-dev#1623) refuses them on every path at the flip.
#   - No corporate CA: the node's image pulls do not take one yet, so a network that
#     inspects TLS would fail them after the node is up.
#   - No hostPath storage and no dataset folder: the node is a VM, so either would be
#     inside it, not on this Mac. (Linux serves both: there the node is the host.)
#   - k3d's node counts, refused as on Linux (_native_k3s_refuse_k3d_nodes), and the
#     pinned k3s version (_native_k3s_check_version).
_mac_ct_refuse_host() {
  [[ "${OS:-}" == "Darwin" ]] \
    || error "The macOS node runs on a Mac only, and this machine runs ${OS:-an unknown OS}."
  local verdict
  verdict="$(tb_mac_floor_verdict)"
  case "$verdict" in
    '' | ok) ;;
    *) error "$(tb_mac_floor_reason "$verdict") Set TRACEBLOC_SUBSTRATE=k3d to install on k3d." ;;
  esac
  local ca="" carc=0
  if declare -F _resolve_ca_bundle >/dev/null 2>&1; then ca="$(_resolve_ca_bundle)" || carc=$?; fi
  [[ -z "$ca" && "$carc" -eq 0 ]] \
    || error "A corporate CA (TRACEBLOC_CA_BUNDLE or CURL_CA_BUNDLE) is not available on the macOS node yet: the node's image pulls would not trust it. Unset it, or set TRACEBLOC_SUBSTRATE=k3d to install on k3d with it."
  [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]] \
    || error "TRACEBLOC_STORAGE_MODE=hostpath is not available on the macOS node yet: the node is a VM, so its hostPath volumes would be inside the VM, not on this Mac. Unset TRACEBLOC_STORAGE_MODE (and the older TB_STORAGE_MODE), or set TRACEBLOC_SUBSTRATE=k3d to keep hostpath on k3d."
  [[ -z "${HOST_DATASET_DIR:-}" ]] \
    || error "HOST_DATASET_DIR is not available on the macOS node yet: a folder on this Mac is not mounted into the node's VM. Unset TRACEBLOC_HOST_DATASET_DIR (and the older HOST_DATASET_DIR), or set TRACEBLOC_SUBSTRATE=k3d to keep the mount on k3d."
  _native_k3s_refuse_k3d_nodes
  _native_k3s_check_version
}

# _mac_ct_node_name -- the node container's name, and its volume's: the kube context's
# name (_native_k3s_context), so `container list` and kubectl name the node alike.
_mac_ct_node_name() {
  local n; n="$(_native_k3s_context)"
  if [[ ! "$n" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "Apple container: '${n}' is not a name the node's container can take (lowercase letters, digits, '.', '_', '-'); set TRACEBLOC_CLUSTER_NAME to one."
    return 1
  fi
  printf '%s' "$n"
}

# _mac_ct_node_dir -- the host's copies of what the node runs on (see above).
_mac_ct_node_dir() { local home; home="$(_mac_ct_home)" || return 1; printf '%s/node' "$home"; }

# _mac_ct_node_image -- rancher/k3s at the pinned K8S_VERSION, by its linux/arm64
# digest: the repository from _native_k3s_image_ref, the one derivation check-facts.sh
# resolves the digest through, and no tag, so the digest alone decides what runs.
_mac_ct_node_image() {
  local digest="${TB_K3S_IMAGE_ARM64_DIGEST:-}" ref
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Apple container: the stamped k3s node image digest is '${digest}', not sha256:<64 hex> (run scripts/check-facts.sh --write)."
    return 1
  fi
  ref="$(_native_k3s_image_ref "${TB_K3S_PIN_K8S_VERSION:-}" 2>&1)" \
    || { echo "Apple container: no k3s node image for the pinned version: ${ref}"; return 1; }
  printf '%s@%s' "${ref%:*}" "$digest"
}

# _mac_ct_node_cidrs CONFIG -- the node's "<cluster-cidr> <service-cidr>": the pair
# CONFIG froze, else the first of TRACEBLOC_K3S_CIDR_PAIRS. Unlike Linux, no host route
# is read: the pod and service routes live in the VM, never on the Mac, so they cannot
# misroute the Mac's own traffic (the reason _native_k3s_pick_cidrs reads them).
_mac_ct_node_cidrs() {
  local cfg="$1" c s rc=0
  c="$(_native_k3s_config_value cluster-cidr "$cfg")" || rc=$?
  [[ "$rc" -eq 0 ]] && { s="$(_native_k3s_config_value service-cidr "$cfg")" || rc=$?; }
  [[ "$rc" -eq 0 ]] || error "Apple container: ${cfg} exists but could not be read, so the pod and service ranges it holds cannot be kept. Check it, then re-run."
  if [[ -n "$c" && -n "${s:-}" ]]; then printf '%s %s\n' "$c" "$s"; return 0; fi
  printf '%s\n' "${TRACEBLOC_K3S_CIDR_PAIRS[0]}"
}

# _mac_ct_node_config NAME CIDRS -- the node's config.yaml: _native_k3s_render_config's
# (node-local storage on the volume, cgroup v2, the kubeconfig root's only), then the
# Mac's own keys, the join token's file among them (client-dev#1976).
_mac_ct_node_config() {
  _native_k3s_render_config node-local "$1" "$2" "" v2 "" || return 1
  printf 'node-ip: "%s"\n' "$TB_MAC_CT_NODE_IP"
  printf 'advertise-address: "%s"\n' "$TB_MAC_CT_NODE_IP"
  printf 'tls-san: ["127.0.0.1"]\n'
  printf 'flannel-iface: "%s"\n' "$TB_MAC_CT_NODE_IFACE"
  printf 'token-file: "%s"\n' "$TB_MAC_CT_NODE_TOKEN_FILE"
}

# _mac_ct_node_size -- "<cpus> <memory>" for the node.
#   Memory: the installer's one macOS VM rule, preflight.sh's _macos_vm_mem_gb, which
#           sizes Colima and Docker Desktop too, on the Mac's RAM as preflight reads it
#           (_pf_host_mem_gb). Asked, never restated: one Mac gets one VM size whichever
#           runtime holds the node. Lukas decided this on 2026-10-11
#           (tracebloc/backend#4827), departing from RFC-0175's proposal, a quarter of
#           the RAM between 4 and 16 GB.
#   CPUs:   the Mac's cores less one, at least 1. The VM adds a vCPU of its own
#           (RFC-0175's measurement), so the node advertises the Mac's cores.
# The VM never returns memory (no balloon), so this is what the Mac gives up while the
# node runs.
_mac_ct_node_size() {
  local spare=1 phys ncpu cpus re='^[1-9][0-9]*$'
  if ! declare -F _macos_vm_mem_gb _pf_host_mem_gb >/dev/null 2>&1; then
    echo "Apple container: the installer's macOS VM sizing (preflight.sh) is not loaded, so this run cannot size the node."
    return 1
  fi
  phys="$(_pf_host_mem_gb)" || phys=""
  if [[ ! "$phys" =~ $re ]]; then
    echo "Apple container: sysctl did not say how much memory this Mac has (hw.memsize), so this run cannot size the node."
    return 1
  fi
  ncpu="$(sysctl -n hw.ncpu 2>/dev/null)" || ncpu=""
  if [[ ! "$ncpu" =~ $re ]]; then
    echo "Apple container: sysctl did not say how many cores this Mac has (hw.ncpu), so this run cannot size the node."
    return 1
  fi
  cpus=$(( ncpu - spare ))
  (( cpus >= 1 )) || cpus=1
  printf '%s %sg' "$cpus" "$(_macos_vm_mem_gb "$phys")"
}

# _mac_ct_node_argv NAME IMAGE CONFIG KUBELET SIZE TOKEN -- the `container run` argv,
# into TB_MAC_CT_NODE_ARGV (an array: the config holds newlines and quotes). --rosetta is
# in it when TRACEBLOC_MAC_CT_ROSETTA (the TEST SEAM), else TB_MAC_CT_ROSETTA_RUNTIME,
# exists. TOKEN is the join token, the entrypoint's last argument: it makes the argv a
# secret, so run-args is kept 0600.
TB_MAC_CT_NODE_ARGV=()
_mac_ct_node_argv() {
  local name="$1" image="$2" cfg="$3" kubelet="$4" cpus="${5%% *}" mem="${5#* }" token="$6"
  TB_MAC_CT_NODE_ARGV=(run -d --name "$name"
    --cap-add ALL --read-only-path NONE --masked-path NONE)
  [[ ! -e "${TRACEBLOC_MAC_CT_ROSETTA:-$TB_MAC_CT_ROSETTA_RUNTIME}" ]] || TB_MAC_CT_NODE_ARGV+=(--rosetta)
  TB_MAC_CT_NODE_ARGV+=(--cpus "$cpus" --memory "$mem"
    -v "${name}:/var/lib/rancher/k3s" --tmpfs /run --tmpfs /var/run
    -p 127.0.0.1:6443:6443
    --entrypoint /bin/sh "$image" -c "$TB_MAC_CT_NODE_ENTRY" sh "$cfg" "$kubelet" "$TB_MAC_CT_NODE_IP" "$token")
}

# _mac_ct_node_running CT NAME -- 0 when `container list` (running containers only)
# has NAME in its first column; 1 when it does not; 2 when the list fails (cannot tell).
_mac_ct_node_running() {
  local out
  out="$(_bounded 30 "$1" list </dev/null 2>/dev/null)" || return 2
  awk -v n="$2" 'NR > 1 && $1 == n { found = 1 } END { exit !found }' <<<"$out"
}

# _mac_ct_node_exists CT NAME -- 0 when container NAME exists (running or not); 1 when it
# does not; 2 when this run cannot tell. A failed `inspect` is not "absent": it may be a
# timeout or a runtime hiccup beside a node that is there, so it is settled by the
# list of all containers, and a list that fails is cannot tell.
_mac_ct_node_exists() {
  local out
  _bounded 30 "$1" inspect "$2" </dev/null >/dev/null 2>&1 && return 0
  out="$(_bounded 30 "$1" list --all </dev/null 2>/dev/null)" || return 2
  awk -v n="$2" 'NR > 1 && $1 == n { found = 1 } END { exit !found }' <<<"$out"
}

# _mac_ct_volume_exists CT NAME -- 0 when volume NAME exists; 1 when it does not; 2 when
# this run cannot tell. As for the container: a failed `volume inspect` may be a timeout
# beside a volume that is there, so it is settled by the list of volumes, and a list that
# fails is cannot tell.
_mac_ct_volume_exists() {
  local out
  _bounded 30 "$1" volume inspect "$2" </dev/null >/dev/null 2>&1 && return 0
  out="$(_bounded 30 "$1" volume list </dev/null 2>/dev/null)" || return 2
  awk -v n="$2" 'NR > 1 && $1 == n { found = 1 } END { exit !found }' <<<"$out"
}

# _mac_ct_node_ready_since CT NAME NODE SINCE -- 0 when node NODE's Ready condition is
# True with a heartbeat at or after SINCE (UTC, %Y-%m-%dT%H:%M:%SZ), asked inside the
# node. Both times are that format, so their digits compare as numbers. The heartbeat
# it read is left in TB_MAC_CT_NODE_HB, for the log, and the condition, as
# STATUS|REASON|MESSAGE, in TB_MAC_CT_NODE_READY, for the refusal (client-dev#1935).
# The message comes last, because it may hold spaces.
TB_MAC_CT_NODE_HB=""
TB_MAC_CT_NODE_READY=""
_mac_ct_node_ready_since() {
  local out hb st rest why=""
  out="$(_bounded 15 "$1" exec "$2" kubectl get node "$3" --request-timeout=5s \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].lastHeartbeatTime} {.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}|{.status.conditions[?(@.type=="Ready")].message}' \
    </dev/null 2>/dev/null)" || return 1
  hb="${out%% *}"; rest="${out#* }"; st="${rest%% *}"; TB_MAC_CT_NODE_HB="$hb"
  [[ "$rest" != *" "* ]] || why="${rest#* }"
  [[ -z "$st" ]] || TB_MAC_CT_NODE_READY="${st}${why:+|${why}}"
  [[ "$st" == True && "$hb" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  (( 10#${hb//[^0-9]/} >= 10#${4//[^0-9]/} ))
}

# _mac_ct_ready_why CT NAME SINCE -- why the macOS node's Ready wait was refused: the
# last Ready condition it read (k3s.sh _native_k3s_ready_said) with its heartbeat, and
# whether the node container still runs. Where Linux counts k3s's restarts, the Mac
# cannot: k3s is the container's PID 1 and Apple's runtime has no restart policy, so a
# k3s that exited is a node container that stopped.
_mac_ct_ready_why() {
  local rc=0
  _native_k3s_ready_said "$TB_MAC_CT_NODE_READY"
  [[ -z "$TB_MAC_CT_NODE_READY" ]] || printf ' Its heartbeat was %s, and the wait needs one at or after %s.' "${TB_MAC_CT_NODE_HB:-none}" "$3"
  _mac_ct_node_running "$1" "$2" || rc=$?
  case "$rc" in
    0) printf ' The node container is running.' ;;
    1) printf ' The node container has stopped, so k3s exited.' ;;
    *) printf " Whether the node container still runs could not be read ('%s list' did not answer)." "$1" ;;
  esac
}

# _mac_ct_wait_node_ready CT NAME NODE SINCE -- wait on the API budget the Linux waits
# share (_native_k3s_budget_left) for _mac_ct_node_ready_since.
_mac_ct_wait_node_ready() {
  local budget
  budget="$(_api_wait_budget_s)"
  TB_MAC_CT_NODE_READY=""
  log "Waiting for node '${3}' to be Ready..."
  until _mac_ct_node_ready_since "$@"; do
    _native_k3s_budget_left "$budget" \
      || error "Node '${3}' did not become Ready within ${budget}s. $(_mac_ct_ready_why "$1" "$2" "$4") It's safe to re-run this installer; on a slow machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. \"${1}\" logs ${2} says why k3s is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
  log "Node '${3}' is Ready (heartbeat ${TB_MAC_CT_NODE_HB}, asked for one at or after ${4})."
}

# The join token as _mac_ct_node_token makes and reads it: 16 random bytes in hex, the
# shape k3s's own util.Random(16) gives the token it makes when none is passed.
TB_MAC_CT_NODE_TOKEN_RE='^[0-9a-f]{32}$'

# _mac_ct_node_token CT NAME DIR STATE -- the node's join token, into
# TB_MAC_CT_NODE_TOKEN, pinned in DIR/token (0600) before the argv that carries it is
# kept (client-dev#1976). STATE is what _mac_ct_ensure_node found of NAME: fresh (no
# container and no volume), container, or volume (a volume without its container).
#   - DIR/token there: it is the token, whatever STATE says. A re-run never makes
#     another: one that cannot be read, or is not a token, is refused by name and left
#     as it is.
#   - none, on a fresh node: 16 new random bytes, written once.
#   - none, on a node this installer made before it pinned the token: the token the
#     node already has, read from it while it runs (a stopped one is started for it).
#     k3s keeps it twice, as the user "server" in server/cred/passwd and after
#     "::server:" in server/token, and the two must say the same.
#   Anything else is refused by name, never answered with a new token: a node whose
#   data was encrypted with another token never starts again. A node that cannot hand
#   its token over (one k3s already refuses to start is this case) can only be
#   reinstalled, and the refusal says how.
TB_MAC_CT_NODE_TOKEN=""
_mac_ct_node_token() {
  local ct="$1" name="$2" dir="$3" state="$4" file="${3}/token" t="" passwd="" tok="" p="" rc
  local how="run \"tracebloc delete\" (it removes the node and its data), then install again"
  TB_MAC_CT_NODE_TOKEN=""
  if [[ -e "$file" ]]; then
    t="$(cat "$file")" \
      || error "Apple container: ${file} cannot be read, so this run cannot tell the node's join token, and it never makes a new one. Make the file readable, then re-run."
    [[ "$t" =~ $TB_MAC_CT_NODE_TOKEN_RE ]] \
      || error "Apple container: ${file} does not hold a join token this installer wrote, and this run never replaces it. Remove it (rm \"${file}\") and re-run with the node running: the run then reads the token back from the node."
    TB_MAC_CT_NODE_TOKEN="$t"
    return 0
  fi
  case "$state" in
    fresh)
      t="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')" || t=""
      [[ "$t" =~ $TB_MAC_CT_NODE_TOKEN_RE ]] || error "Apple container: /dev/urandom gave no join token for the node." ;;
    container)
      rc=0; _mac_ct_node_running "$ct" "$name" || rc=$?
      case "$rc" in
        0) ;;
        1) _bounded 120 "$ct" start "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true ;;
        *) error "Apple container: the container system did not list its containers, so this run cannot tell whether the node ${name} runs to read its join token." ;;
      esac
      passwd="$(_bounded 30 "$ct" exec "$name" cat /var/lib/rancher/k3s/server/cred/passwd </dev/null 2>/dev/null)" || passwd=""
      tok="$(_bounded 30 "$ct" exec "$name" cat /var/lib/rancher/k3s/server/token </dev/null 2>/dev/null)" || tok=""
      p="$(awk -F, '$2 == "server" { print $1; exit }' <<<"$passwd")"
      if [[ "$tok" == *::server:* ]]; then t="${tok##*::server:}"; fi
      [[ -n "$p" && -n "$t" ]] \
        || error "Apple container: the node ${name} was made before this installer pinned its join token, and the token could not be read from it (k3s's server/cred/passwd and server/token, inside the node). This run never gives it a new one: k3s would then refuse the node's own data. Start the node (\"${ct}\" start ${name}) and re-run. If it does not stay up, k3s is refusing its own data, and the node cannot be recovered without a reinstall: ${how}."
      [[ "$p" == "$t" && "$t" =~ $TB_MAC_CT_NODE_TOKEN_RE ]] \
        || error "Apple container: the node ${name} holds two different join tokens (k3s's server/cred/passwd and server/token), so this run cannot tell which one its data is encrypted with, and pins neither. \"${ct}\" logs ${name} says whether k3s starts. If it does not stay up, k3s is refusing its own data, and the node cannot be recovered without a reinstall: ${how}." ;;
    *)
      error "Apple container: a volume named ${name} is there without its node, and no join token is pinned for it (${file}), so this run cannot tell the token its data is encrypted with, and it never makes a new one for it. It cannot be recovered without a reinstall: ${how}." ;;
  esac
  (umask 077; printf '%s\n' "$t" > "${file}.tmp") && mv "${file}.tmp" "$file" \
    || { rm -f "${file}.tmp"; error "Apple container: could not write ${file}."; }
  TB_MAC_CT_NODE_TOKEN="$t"
}

# _mac_ct_ensure_node -- the node on the running system (part 2), Ready, recorded, and
# its kubeconfig copied to _mac_ct_node_dir/k3s.yaml. Reuses a running node created with
# this argv, starts a stopped one, recreates one created with another argv on its
# volume, and refuses a container or a volume of its name that nothing shows this
# installer made.
_mac_ct_ensure_node() {
  local root ct name dir image cfgfile cidrs node cfg kubelet size want have="" rc since start="" mkvol="" state
  _native_k3s_check_version
  TB_K3S_ON_MAC=1
  root="$(_mac_ct_install_root)" && dir="$(_mac_ct_node_dir)" \
    || error "Apple container: cannot tell where the runtime lives (above)."
  ct="${root}/bin/container"
  name="$(_mac_ct_node_name)" || error "$name"
  image="$(_mac_ct_node_image)" || error "$image"
  size="$(_mac_ct_node_size)" || error "$size"
  mkdir -p "$dir" || error "Apple container: could not create ${dir}."
  cfgfile="${dir}/config.yaml"
  cidrs="$(_mac_ct_node_cidrs "$cfgfile")" || exit 1
  node="$(_native_k3s_node_name "$cfgfile")" || exit 1
  cfg="$(_mac_ct_node_config "$node" "$cidrs")" || error "Apple container: could not render the node's k3s config (above)."
  # The node is k3s whatever this run resolved: never k3d's Docker Desktop reservation.
  kubelet="$(TRACEBLOC_SUBSTRATE_RESOLVED=k3s _render_kubelet_config)" || error "Apple container: could not render the node's kubelet drop-in."
  if [[ -e "${dir}/run-args" ]]; then
    have="$(cat "${dir}/run-args")" || error "Apple container: ${dir}/run-args cannot be read, so this run cannot tell how the node was created."
  fi
  # The config is frozen before the node first reads it, as on Linux.
  printf '%s\n' "$cfg" > "${cfgfile}.tmp" && mv "${cfgfile}.tmp" "$cfgfile" \
    || { rm -f "${cfgfile}.tmp"; error "Apple container: could not write ${cfgfile}."; }
  # What is there of the node, settled before its token is read from it: a container
  # or a volume nothing shows this installer made is refused before anything runs in it.
  rc=0; _mac_ct_node_exists "$ct" "$name" || rc=$?
  [[ "$rc" != 2 ]] \
    || error "Apple container: the container system did not answer whether a container named ${name} exists, so this run cannot tell. It's safe to re-run this installer."
  if [[ "$rc" == 0 ]]; then
    [[ -n "$have" ]] \
      || error "Apple container: a container named ${name} already exists, and nothing shows this installer created it (${dir}/run-args is missing). This installer does not delete it: remove it yourself (\"${ct}\" delete --force ${name}), then re-run."
    state=container
  else
    rc=0; _mac_ct_volume_exists "$ct" "$name" || rc=$?
    [[ "$rc" != 2 ]] \
      || error "Apple container: the container system did not answer whether a volume named ${name} exists, so this run cannot tell. It's safe to re-run this installer."
    if [[ "$rc" == 0 ]]; then
      [[ -n "$have" ]] \
        || error "Apple container: a volume named ${name} already exists, and nothing shows this installer created it, so a new node would silently take over its data. This installer does not delete it: remove it yourself (\"${ct}\" volume delete ${name}), then re-run."
      state=volume
    else
      mkvol=1; state=fresh
    fi
  fi
  # The token goes first, before run-args: whatever a run cut off half-way leaves, a
  # re-run must start with the token the node's data is encrypted with.
  _mac_ct_node_token "$ct" "$name" "$dir" "$state"
  _mac_ct_node_argv "$name" "$image" "$cfg" "$kubelet" "$size" "$TB_MAC_CT_NODE_TOKEN"
  want="$(printf '%s\n' "${TB_MAC_CT_NODE_ARGV[@]}")"  # set-u-safe: _mac_ct_node_argv seeds it with the run verb
  if [[ "$state" == container ]]; then
    if [[ "$have" != "$want" ]]; then
      log "Apple container: the node's settings changed since it was created, so it is recreated on its volume ${name}; its data is kept."
      # A stop that fails is not the end: a node that is already stopped may refuse it,
      # and the delete below is what says whether the node is gone.
      _bounded 120 "$ct" stop "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
      _bounded 60 "$ct" delete "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: could not remove the node ${name} to recreate it. Its volume is untouched. Run \"${ct}\" delete --force ${name}, then re-run."
      start=run
    else
      rc=0; _mac_ct_node_running "$ct" "$name" || rc=$?
      case "$rc" in
        0) ;;
        1) start=start ;;
        *) error "Apple container: the container system did not list its containers, so this run cannot tell whether the node ${name} is running." ;;
      esac
    fi
  else
    start=run
  fi
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$start" in
    run)
      # The image is needed only to create a node: reusing or starting one works with the
      # registry unreachable.
      log "Apple container: pulling the k3s node image ${image}..."
      _bounded 900 "$ct" image pull --platform linux/arm64 --progress none "$image" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Couldn't pull the k3s node image ${image}. Check that this machine can reach registry-1.docker.io, then re-run."
      # run-args goes first, before the volume and the container: whatever a run cut off
      # half-way leaves, a re-run must recognise as this installer's.
      # 0600: the argv carries the join token.
      (umask 077; printf '%s\n' "$want" > "${dir}/run-args.tmp") && mv "${dir}/run-args.tmp" "${dir}/run-args" \
        || { rm -f "${dir}/run-args.tmp"; error "Apple container: could not write ${dir}/run-args."; }
      [[ -z "$mkvol" ]] || _bounded 60 "$ct" volume create --opt "size=${TB_MAC_CT_NODE_VOLUME_SIZE}" "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: could not create the node's volume ${name}."
      # set-u-safe: _mac_ct_node_argv seeds it with the run verb
      _bounded 300 "$ct" "${TB_MAC_CT_NODE_ARGV[@]}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: the node ${name} did not start. \"${ct}\" logs ${name} says why. It's safe to re-run this installer." ;;
    start)
      _bounded 120 "$ct" start "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: the node ${name} did not start. \"${ct}\" logs ${name} says why. It's safe to re-run this installer." ;;
    *) since="" ;;
  esac
  tb_record_write container-node "$name" "$(_mac_ct_home)"
  # A node this run did not start is Ready on its current status; one it started must
  # say so with a heartbeat newer than the start.
  # Each wait spends its own budget: _native_k3s_budget_left reads these two as it
  # goes, and a second call in one process (the live test makes three) would
  # otherwise inherit the first wait's elapsed time and time out at once.
  TB_K3S_WAITED_S=0; TB_K3S_WAIT_T0="$(date +%s)"
  _mac_ct_wait_node_ready "$ct" "$name" "$node" "${since:-0000-00-00T00:00:00Z}"
  (umask 077; _bounded 30 "$ct" exec "$name" cat /etc/rancher/k3s/k3s.yaml </dev/null > "${dir}/k3s.yaml.tmp") \
    && [[ -s "${dir}/k3s.yaml.tmp" ]] && mv "${dir}/k3s.yaml.tmp" "${dir}/k3s.yaml" \
    || { rm -f "${dir}/k3s.yaml.tmp"; error "Apple container: could not copy the node's kubeconfig out of ${name}. It's safe to re-run this installer."; }
  log "Apple container: node '${node}' is Ready in ${name}, its API on 127.0.0.1:6443."
}

# _mac_ct_merge_kubeconfig -- the node's kubeconfig merged into the user's, as a
# kube-context, by the Linux merge (_native_k3s_merge_kubeconfig), from the copy
# _mac_ct_ensure_node took. It needs a kubectl on PATH: step b installs the pinned one
# (_mac_ct_install_macos).
_mac_ct_merge_kubeconfig() {
  local dir
  dir="$(_mac_ct_node_dir)" || error "Apple container: cannot tell where the node's kubeconfig is (above)."
  TB_K3S_ON_MAC=1
  _native_k3s_merge_kubeconfig "${dir}/k3s.yaml"
  tb_record_write kube-context "$(_native_k3s_context)" "$(_native_k3s_kubeconfig_target)"
}

# ── Part 4: the login item io.tracebloc.node ────────────────────────────────
#  Apple's runtime has no restart policy: after a login, a reboot, a stopped node or a
#  killed VM, nothing brings the node back (RFC-0175 §12.6). A per-user LaunchAgent does,
#  as in spike S-M. launchd runs our signed CLI's `tracebloc node ensure` at load and every
#  60 s (cli-dev#1124): it starts the container system when none runs, then the node, and
#  waits for it to be Ready. It reads the runtime and the node from the install record, so
#  the plist names neither.
#    - ProgramArguments is [the CLI's absolute path, node, ensure] (backend#5245 box 3):
#      launchd has no PATH, and the login item then reads "tracebloc". The caller passes
#      the path the CLI's installer reported. A binary without the verb is refused by
#      name; the binary itself is asked, so no version is restated here.
#    - Before anything is written, the binary's `node ensure` runs once, as launchd will
#      run it. A command that fails would fail every minute with nobody told: measured on
#      the e2e Mac, a CLI whose record schema predates this install's kinds refuses the
#      record each time ("newer than this tracebloc reads"). That one, any other failure,
#      and a run past its bound are each refused by name.
#    - EnvironmentVariables: HOME is the home this run records into (tb_record_path), so
#      the agent reads the record the installer wrote; TRACEBLOC_SKIP_TELEMETRY=1, or each
#      tick would record a CLI outcome, about 1,440 a day.
#    - LimitLoadToSessionType Aqua: it loads in a login session only, so a headless Mac
#      never runs it (#1615 open decision 4). ProcessType Background.
#  The plist is rewritten and the agent reloaded only when its bytes change: that is how
#  a CLI that moved (an upgrade between /usr/local/bin and ~/.local/bin) is followed.
#  On this path it replaces io.tracebloc.runtime (setup-macos.sh): step b on the macOS
#  node installs no Docker, so nothing writes that one, and step c loads this one
#  (_mac_ct_create_cluster).
TB_MAC_CT_AGENT_LABEL="io.tracebloc.node"
TB_MAC_CT_AGENT_INTERVAL=60

# _mac_ct_agent_home -- the home the install record is written under: tb_record_path
# without the record's user path. It is the agent's HOME, and its plist and log live
# under it.
_mac_ct_agent_home() {
  local rec home
  rec="$(tb_record_path)"
  home="${rec%"${TB_RECORD_USER_PATH#\~}"}"
  if [[ "$home" == "$rec" || "$home" != /?* ]]; then
    echo "Apple container: the install record's path is '${rec}', which is not under a home folder, so the login item has no home."
    return 1
  fi
  printf '%s\n' "$home"
}

TB_MAC_CT_AGENT_HELP_S=30
# _mac_ct_agent_bin_check BIN -- prints nothing and returns 0 when the login item can
# run BIN: an absolute path to an executable file that knows `node ensure`. Otherwise
# prints why and returns 1. `--help` runs nothing: an older tracebloc fails it, because
# its root takes no unknown command.
_mac_ct_agent_bin_check() {
  local bin="$1" out rc
  case "$bin" in
    /*) ;;
    *) echo "Apple container: the tracebloc CLI's path '${bin}' is not absolute, and launchd starts the login item with no PATH."; return 1 ;;
  esac
  [[ -f "$bin" && -x "$bin" ]] \
    || { echo "Apple container: ${bin} is not an executable file, so the login item would have nothing to run."; return 1; }
  rc=0
  out="$(TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TB_MAC_CT_AGENT_HELP_S" "$bin" node ensure --help </dev/null 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure --help\` did not finish within ${TB_MAC_CT_AGENT_HELP_S} s, so this run cannot tell whether the CLI knows the command the login item runs. It's safe to re-run this installer."
    return 1
  fi
  [[ "$rc" -eq 0 && "$out" == *"node ensure"* ]] \
    || { echo "Apple container: ${bin} does not know \`tracebloc node ensure\`, the command the login item runs, so it is older than this installer needs. Run \`tracebloc upgrade\`, then re-run this installer."; return 1; }
}

# _mac_ct_agent_trial BIN HOME -- prints nothing and returns 0 when BIN's `node ensure`,
# run once as the login item runs it (HOME the record's home, telemetry off), succeeds
# within TB_MAC_CT_AGENT_TRIAL_S; its output goes to the install log. Otherwise prints
# why and returns 1. Step c calls it just after the node is Ready, so `node ensure` only
# probes; a run past the bound cannot tell, and fails closed.
TB_MAC_CT_AGENT_TRIAL_S=120
_mac_ct_agent_trial() {
  local bin="$1" home="$2" out rc=0 ver="" first _w _rest nl=$'\n'
  out="$(HOME="$home" TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TB_MAC_CT_AGENT_TRIAL_S" "$bin" node ensure </dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure\`, the command the login item runs, did not finish within ${TB_MAC_CT_AGENT_TRIAL_S} s, so this run cannot tell whether the login item would bring the node back. It's safe to re-run this installer."
    return 1
  fi
  if [[ "$out" == *"newer than this tracebloc reads"* ]]; then
    first="$(HOME="$home" TRACEBLOC_SKIP_TELEMETRY=1 _bounded 30 "$bin" version </dev/null 2>/dev/null)" || first=""
    first="${first%%"$nl"*}"
    read -r _w ver _rest <<<"$first" || true
    echo "Apple container: the tracebloc CLI at ${bin} (${ver:-version unknown}) cannot read this install's record, which is newer than it, so the login item's \`node ensure\` would fail every ${TB_MAC_CT_AGENT_INTERVAL} s and the node would not come back after a restart. Run \`tracebloc upgrade\`, then re-run this installer."
    return 1
  fi
  echo "Apple container: \`${bin} node ensure\`, the command the login item runs every ${TB_MAC_CT_AGENT_INTERVAL} s, failed (exit ${rc}), so the node would not come back after a restart. It said:"
  printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /'
  return 1
}

# _mac_ct_agent_plist BIN HOME -- the login item's plist, by setup-macos.sh's writer.
_mac_ct_agent_plist() {
  local extra
  extra="  <key>StartInterval</key><integer>${TB_MAC_CT_AGENT_INTERVAL}</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${2}</string>
    <key>TRACEBLOC_SKIP_TELEMETRY</key><string>1</string>
  </dict>"
  _emit_launch_plist "$TB_MAC_CT_AGENT_LABEL" "$extra" "${2}/Library/Logs/tracebloc-node.log" "$1" node ensure
}

# _mac_ct_agent_loaded -- 0 when this user's GUI domain has the login item, 1 when it
# does not (launchctl's 113), 2 when launchctl cannot say.
_mac_ct_agent_loaded() {
  local rc=0
  _bounded 30 launchctl print "gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    113) return 1 ;;
    *) return 2 ;;
  esac
}

# _mac_ct_ensure_agent BIN -- the login item io.tracebloc.node, running BIN's
# `node ensure`: written, recorded as a launch-agent and loaded into this login session.
# A loaded agent whose plist is already these bytes is left as it is.
_mac_ct_ensure_agent() {
  local bin="$1" why home dir plist want have="" loaded=0
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" || -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then
    warn "Login item skipped (TRACEBLOC_SKIP_AUTOSTART/TRACEBLOC_NO_AUTOSTART set): after a reboot, or when its VM stops, the node stays down until you run \`tracebloc node ensure\`."
    return 0
  fi
  why="$(_mac_ct_agent_bin_check "$bin")" || error "$why"
  home="$(_mac_ct_agent_home)" || error "$home"
  # A plist string holds these only escaped, and the writer prints values as they are.
  case "${bin}${home}" in
    *[\&\<\>]*) error "Apple container: '${bin}' or '${home}' holds &, < or >, which the login item's plist cannot hold as it is." ;;
  esac
  # Run as launchd will, before anything is written or loaded.
  why="$(_mac_ct_agent_trial "$bin" "$home")" || error "$why"
  dir="${TRACEBLOC_LAUNCHAGENTS_DIR:-${home}/Library/LaunchAgents}"
  plist="${dir}/${TB_MAC_CT_AGENT_LABEL}.plist"
  want="$(_mac_ct_agent_plist "$bin" "$home")"
  if [[ -e "$plist" ]]; then
    have="$(cat "$plist")" || error "Apple container: ${plist} cannot be read, so this run cannot tell what the login item runs."
  fi
  _mac_ct_agent_loaded || loaded=$?
  [[ "$loaded" -ne 2 ]] \
    || error "Apple container: launchctl could not say whether the login item ${TB_MAC_CT_AGENT_LABEL} is loaded, so this run leaves it as it is."
  if [[ "$loaded" -eq 0 && "$have" == "$want" ]]; then
    tb_record_write launch-agent "$TB_MAC_CT_AGENT_LABEL" "$plist"
    log "Apple container: the login item ${TB_MAC_CT_AGENT_LABEL} is loaded and runs ${bin} node ensure."
    return 0
  fi
  if [[ "$loaded" -eq 0 ]]; then
    _bounded 30 launchctl bootout "gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || error "Apple container: could not unload the login item ${TB_MAC_CT_AGENT_LABEL} to rewrite it. Run launchctl bootout gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}, then re-run."
  fi
  mkdir -p "$dir" "${home}/Library/Logs" || error "Apple container: could not create ${dir}."
  printf '%s\n' "$want" > "${plist}.tmp" && mv "${plist}.tmp" "$plist" \
    || { rm -f "${plist}.tmp"; error "Apple container: could not write ${plist}."; }
  # Recorded before it loads: a run cut off here leaves an artefact delete knows.
  tb_record_write launch-agent "$TB_MAC_CT_AGENT_LABEL" "$plist"
  _bounded 30 launchctl bootstrap "gui/$(id -u)" "$plist" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || error "Apple container: launchd did not load the login item ${plist}, so the node would not come back after a reboot. It's safe to re-run this installer."
  log "Apple container: the login item ${TB_MAC_CT_AGENT_LABEL} is loaded and runs ${bin} node ensure every ${TB_MAC_CT_AGENT_INTERVAL} s."
}

# ── Part 6: reachable behind TRACEBLOC_SUBSTRATE=k3s on a Mac ───────────────
#  _native_k3s_refuse_host (k3s.sh), the one declaration of where native k3s runs, lets
#  a Mac through to _mac_ct_refuse_host. Step b's install_macos routes native k3s to
#  _mac_ct_install_macos (setup-macos.sh), and step c's _native_k3s_create_cluster routes
#  a Mac to _mac_ct_create_cluster (k3s.sh). The default stays k3d on every OS: only
#  TRACEBLOC_SUBSTRATE=k3s, or a re-run of a Mac whose install record says k3s
#  (tb_substrate_resolve), comes here.

# _mac_ct_kubectl_version -- the kubectl the macOS node is driven with: the pinned k3s
# version's Kubernetes release (v1.36.5-k3s1 -> v1.36.5), so client and node never skew.
# Exit 1, printing why, when the pin has another shape.
_mac_ct_kubectl_version() {
  local v="${TB_K3S_PIN_K8S_VERSION:-}" re='^v[0-9]+\.[0-9]+\.[0-9]+$'
  v="${v%%-k3s*}"
  [[ "$v" =~ $re ]] \
    || { echo "Apple container: the pinned k3s version '${TB_K3S_PIN_K8S_VERSION:-}' names no Kubernetes release (like v1.36.5-k3s1)."; return 1; }
  printf '%s' "$v"
}

# _mac_ct_install_macos -- step b on the macOS node (RFC-0175 D6). Nothing here needs an
# administrator: the runtime unpacks into the user's own folder and kubectl and helm go
# to ~/.local/bin, so the run is Tier 0. It installs no Homebrew, Docker, colima or k3d,
# and no io.tracebloc.runtime. kubectl is the node's release (_mac_ct_kubectl_version),
# helm HELM_VERSION as on Linux. Then the runtime is unpacked and checked, and its system
# started, so step c has only the node to run. It refuses nothing itself: a Mac the node
# does not serve never gets here, because main()'s refuse_k3s_beside_live_k3d
# (reinstall.sh) runs _native_k3s_refuse_host before step a on every native k3s request,
# k3d or not. reinstall.bats' #1913 case holds that order (client-dev#1913).
_mac_ct_install_macos() {
  local kver saved_umask
  # shellcheck disable=SC2034  # consumed cross-file (setup-linux.sh's tools target, diagnose.sh)
  INSTALL_TIER=0
  # shellcheck disable=SC2034  # consumed cross-file by diagnose.sh
  INSTALL_TIER_REASON="mac-node"
  log "step b: macOS node: tier 0 (Apple's container runtime in your own folder; no administrator rights)"
  kver="$(_mac_ct_kubectl_version)" || error "$kver"
  # shellcheck disable=SC2034  # consumed cross-file by setup-linux.sh's _fetch_* (the download's OS)
  OS_DL=darwin
  _set_tools_target
  saved_umask="$(umask)"
  umask 022
  install_kubectl "$kver"
  install_helm
  umask "$saved_umask"
  _persist_tools_on_path
  log "step b: macOS node: kubectl ${kver} and helm ready (no Homebrew, no Docker, no k3d)"
  _mac_ct_ensure_runtime
  _mac_ct_start_system
}

# _mac_ct_create_cluster -- step c on the macOS node: the k3s node in Apple's VM, Ready,
# its kubeconfig merged as a kube-context, NO_PROXY for this process (before the Local
# Network gate's first curl of the API), and the login item that keeps it running. As
# on Linux, the host is refused first, and a Mac with no node yet meets the fit gate
# before one is created, sized from the node (preflight's readers, 2.1 part 5a). A node
# of this installer's keeps its volume and its data, and a container or volume nothing
# shows this installer made is refused (_mac_ct_ensure_node): that is this path's
# leftover guard (D5).
# The login item runs the CLI step b installed (TB_CLI_BIN, install-cli.sh). Without it
# the node would not come back after a restart, so a run without it stops before the
# node is touched.
_mac_ct_create_cluster() {
  local dir
  log "Setting up the macOS node for '${CLUSTER_NAME}'"
  _native_k3s_refuse_host
  dir="$(_mac_ct_node_dir)" || error "Apple container: cannot tell where the node's files are (above)."
  if [[ ! -e "${dir}/run-args" ]] && declare -F _precreate_fit_gate >/dev/null 2>&1; then
    _precreate_fit_gate
  fi
  [[ -n "${TB_CLI_BIN:-}" ]] \
    || error "The macOS node's login item runs the tracebloc CLI, and step b did not install it (above). Without the login item the node would not come back after a restart. Install the tracebloc CLI, then re-run this installer."
  _mac_ct_ensure_node
  _mac_ct_merge_kubeconfig
  # NO_PROXY before the gate (client-dev#1892), for the kubectl calls after it: the gate's
  # own probe of 127.0.0.1:6443 bypasses every proxy itself (client-dev#1914).
  _export_host_no_proxy
  _mac_ct_local_network_gate
  _mac_ct_ensure_agent "$TB_CLI_BIN"
}

# ── The Local Network prompt (backend#5407, option a) ──────────────────────────
#  The node's API reaches this Mac through Apple's container-runtime-linux helper, which
#  forwards 127.0.0.1:6443 into the VM. It is a launchd agent, so macOS's Local Network
#  privacy gates it (TN3179). Until the user allows "container-runtime-linux" in
#  System Settings › Privacy & Security › Local Network, every connection to the port is
#  accepted and then reset (curl exit 35, or 56 once a TLS session was open), while the
#  API answers inside the node. Measured on the e2e Mac: a grant turned 31 resets into
#  an answer 0 s after the node's Ready, and the grant is kept per bundle id, so a
#  fresh unpack, or any later install, is not asked again.
#  So before the first API call from this Mac, the installer says the prompt may come
#  and what the helper is for, makes the call, and waits for the answer. A reset that
#  outlasts the wait is the missing permission, refused by name with where to allow it.
#  The node is Ready by then: the installer never reports it as a broken cluster.

TB_MAC_CT_LAN_HELPER="container-runtime-linux"
TB_MAC_CT_LAN_SETTINGS="System Settings › Privacy & Security › Local Network"
# How long the first call waits for the user to answer the prompt.
TB_MAC_CT_LAN_WAIT_S=120

# _mac_ct_api_try KUBECONFIG -- one /readyz on 127.0.0.1:6443 from this Mac, with the
# node's own CA and client certificate read from KUBECONFIG (the copy _mac_ct_ensure_node
# took), as the live proof asks it (mac-container-live.sh _live_api_readyz). Prints the
# body and returns curl's exit code; 100, printing why, when KUBECONFIG cannot be read,
# lacks one of them, or holds one that does not decode.
# --noproxy '*': the port is this Mac's own loopback, so no proxy is ever asked, ALL_PROXY
# included, which NO_PROXY's export does not cover. A proxy's own refusal is a curl 56, the
# gate's reading of the Local Network refusal (client-dev#1914).
# Capture-then-slice, never `sed | head -n 1`: head closes the pipe early (the
# early-close rule, .cursor/BUGBOT.md). base64's own status is read, so a value that
# does not decode is refused by name rather than handed to curl as a partial file.
_mac_ct_api_try() {
  local kc="$1" d f v rc=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-api-XXXXXX")" || { echo "could not create a temporary folder"; return 100; }
  for f in certificate-authority-data client-certificate-data client-key-data; do
    v="$(sed -n "s/^ *${f}: *//p" "$kc" 2>/dev/null)" || { rm -rf "$d"; echo "${kc} cannot be read"; return 100; }
    v="${v%%$'\n'*}"
    [[ -n "$v" ]] || { rm -rf "$d"; echo "${kc} holds no ${f}"; return 100; }
    printf '%s' "$v" | base64 --decode > "${d}/${f}" 2>/dev/null && [[ -s "${d}/${f}" ]] \
      || { rm -rf "$d"; echo "${kc} holds a ${f} that does not decode"; return 100; }
  done
  curl_secure -sS --max-time 15 --noproxy '*' --cacert "${d}/certificate-authority-data" \
    --cert "${d}/client-certificate-data" --key "${d}/client-key-data" \
    https://127.0.0.1:6443/readyz 2>/dev/null || rc=$?
  rm -rf "$d"
  return "$rc"
}

# _mac_ct_local_network_gate -- the node's API answering from this Mac, or a refusal that
# names what stops it. Says the prompt may come before the first call, then calls until
# /readyz says ok or TB_MAC_CT_LAN_WAIT_S have passed. A last answer that was a reset
# (curl 35 or 56) is the Local Network permission; any other is the port, said as it is.
_mac_ct_local_network_gate() {
  local dir kc body="" rc t0
  dir="$(_mac_ct_node_dir)" || error "Apple container: cannot tell where the node's kubeconfig is (above)."
  kc="${dir}/k3s.yaml"
  info "macOS may now ask whether \"${TB_MAC_CT_LAN_HELPER}\" can find devices on your local network. It is part of Apple's container runtime: it makes the cluster's API reachable from this Mac only, on 127.0.0.1:6443. Click Allow. This waits up to $(( TB_MAC_CT_LAN_WAIT_S / 60 )) minutes for your answer."
  t0=$SECONDS
  while :; do
    rc=0; body="$(_mac_ct_api_try "$kc")" || rc=$?
    [[ "$rc" -ne 100 ]] \
      || error "Apple container: the node's kubeconfig cannot be used to ask its API from this Mac: ${body}. It's safe to re-run this installer."
    if [[ "$rc" -eq 0 && "$body" == ok ]]; then
      log "Apple container: the node's API answers from this Mac on 127.0.0.1:6443."
      return 0
    fi
    (( SECONDS - t0 < TB_MAC_CT_LAN_WAIT_S )) || break
    sleep 3
  done
  case "$rc" in
    35|56)
      # A refusal: nothing changes until the user allows it, so no "try again" footer.
      # shellcheck disable=SC2034  # consumed cross-file by install_cleanup (common.sh)
      TB_EXIT_REFUSED=1
      error "This Mac blocks the cluster's API: Local Network access is not allowed for \"${TB_MAC_CT_LAN_HELPER}\", the part of Apple's container runtime that makes the API reachable from this Mac. Allow it in ${TB_MAC_CT_LAN_SETTINGS}, then re-run this installer. The node is running and keeps its data." ;;
    *)
      error "The node is Ready, but its API on 127.0.0.1:6443 did not answer from this Mac within ${TB_MAC_CT_LAN_WAIT_S}s (the last try exited ${rc}${body:+ and said: ${body}}). It's safe to re-run this installer." ;;
  esac
}
