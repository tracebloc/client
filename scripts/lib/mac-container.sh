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
  local v="${1:-${TRACEBLOC_APPLE_CONTAINER_VERSION:-}}" home
  _mac_ct_version_ok "$v" || { echo "Apple container: '${v}' is not a release version (like 1.4.1)." >&2; return 1; }
  home="$(_mac_ct_home)" || return 1
  printf '%s/%s' "$home" "$v"
}

# _mac_ct_pkg_name [VERSION] / _mac_ct_pkg_url [VERSION] -- the signed package's asset
# name and its release URL, derived from the version, never pinned beside it.
_mac_ct_pkg_name() {
  local v="${1:-${TRACEBLOC_APPLE_CONTAINER_VERSION:-}}"
  _mac_ct_version_ok "$v" || { echo "Apple container: '${v}' is not a release version (like 1.4.1)." >&2; return 1; }
  printf 'container-%s-installer-signed.pkg' "$v"
}
_mac_ct_pkg_url() {
  local v="${1:-${TRACEBLOC_APPLE_CONTAINER_VERSION:-}}" name
  name="$(_mac_ct_pkg_name "$v")" || return 1
  printf 'https://github.com/apple/container/releases/download/%s/%s' "$v" "$name"
}

# _mac_ct_fetch_pkg DIR -- download the pinned package into DIR (a temporary folder the
# caller made) and verify it against the pinned sha256. On any failure DIR is removed
# and the install stops by name. Same bounds as k3s.sh's binary download: a stall
# floor, not a hard deadline, on a ~118 MB file.
_mac_ct_fetch_pkg() {
  local dir="$1" want="${TRACEBLOC_APPLE_CONTAINER_PKG_SHA256:-}" url name
  [[ -n "$want" ]] || { rm -rf "$dir"; error "Apple container: no pinned sha256 for the package is stamped in common.sh -- run scripts/check-facts.sh --write."; }
  url="$(_mac_ct_pkg_url)" && name="$(_mac_ct_pkg_name)" \
    || { rm -rf "$dir"; error "Apple container: cannot derive the package from TRACEBLOC_APPLE_CONTAINER_VERSION='${TRACEBLOC_APPLE_CONTAINER_VERSION:-}'."; }
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "$url" -o "${dir}/${name}" \
    || { rm -rf "$dir"; error "Couldn't download Apple's container package from ${url}. Check that this machine can reach github.com and release-assets.githubusercontent.com, then re-run."; }
  # 117.8 MB at 1.4.1; an error page or a truncated stream is far shorter.
  _assert_download_size "${dir}/${name}" 100000000 "Apple's container package" "$dir"
  _verify_sha256 "$want" "${dir}/${name}" \
    || { rm -rf "$dir"; error "Apple's container package downloaded from ${url} does not match its pinned sha256 (${want}), so it was not unpacked. Something between this machine and GitHub changed the file; do not install it by hand. Re-run on a network that does not rewrite downloads."; }
}

# _mac_ct_notary_pause -- the 5 s between pkgutil's two reads in _mac_ct_check_pkg. Its
# own function so a test counts the pause without stubbing `sleep`, which the
# deadline primitives under _bounded also tick with.
_mac_ct_notary_pause() { sleep 5; }

# _mac_ct_check_pkg PKG -- pkgutil's verdict on PKG (check 2). The lines are the ones
# pkgutil prints on macOS 26 for Apple's package (spike S-M, RFC-0175 section 12.6):
#   Status: signed by a developer certificate issued by Apple for distribution
#   Notarization: trusted by the Apple notary service
#   1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
# A pkgutil that does not answer is "cannot tell", never a pass.
#
# THE NOTARIZATION LINE IS A LIVE ANSWER. pkgutil prints it only when Apple's notary
# service vouches for the package, and without a ticket stapled to it that is a lookup
# over the network: one that does not answer prints the signature without the line,
# exactly like a package that was never notarised (the pin gate's verify read the same
# pinned package with the line, and 30 minutes later without it). So a read that is
# signed for distribution but lacks the line is read once more, 5 s later, and if the
# line is still absent this says it cannot tell. It never passes: an unread
# notarisation is not a notarised package.
_mac_ct_check_pkg() {
  local pkg="$1" team="${TRACEBLOC_APPLE_CONTAINER_TEAM_ID:-}" out rc=0 leaf
  local status_line='Status: signed by a developer certificate issued by Apple for distribution'
  local notary_line='Notarization: trusted by the Apple notary service'
  [[ -n "$team" ]] || { echo "Apple container: no pinned Team ID is stamped in common.sh -- run scripts/check-facts.sh --write."; return 1; }
  out="$(_bounded 60 pkgutil --check-signature "$pkg" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]] && grep -qF "$status_line" <<<"$out" && ! grep -qF "$notary_line" <<<"$out"; then
    _mac_ct_notary_pause
    rc=0; out="$(_bounded 60 pkgutil --check-signature "$pkg" 2>&1)" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "Apple container: pkgutil could not check the package's signature (exit ${rc}), so this run cannot tell who signed it, and it was not unpacked."
    return 1
  fi
  if ! grep -qF "$status_line" <<<"$out"; then
    echo "Apple container: pkgutil does not say the package is signed for distribution, so it was not unpacked."
    return 1
  fi
  if ! grep -qF "$notary_line" <<<"$out"; then
    echo "Apple container: pkgutil did not report the package as notarised on two reads 5 s apart. It reports that only when Apple's notary service answers for the package, so this run cannot tell whether the package is notarised, and it was not unpacked. Check that this Mac can reach Apple, then run this again."
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
  local root="$1" team="${TRACEBLOC_APPLE_CONTAINER_TEAM_ID:-}" list f kind got out rc n=0 cli=""
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
  printf 'version=%s\npkg_sha256=%s\n' "${TRACEBLOC_APPLE_CONTAINER_VERSION:-}" "${TRACEBLOC_APPLE_CONTAINER_PKG_SHA256:-}"
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
    echo "its ${TB_MAC_CT_MARKER} marker names another package than the pinned one (${TRACEBLOC_APPLE_CONTAINER_VERSION:-}, sha256 ${TRACEBLOC_APPLE_CONTAINER_PKG_SHA256:-})"
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
      log "Apple container ${TRACEBLOC_APPLE_CONTAINER_VERSION}: reusing the checked runtime in ${dest}."
      tb_record_write apple-container "$TRACEBLOC_APPLE_CONTAINER_VERSION" "${dest%/*}"
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
  tb_record_write apple-container "$TRACEBLOC_APPLE_CONTAINER_VERSION" "${dest%/*}"
  log "Apple container ${TRACEBLOC_APPLE_CONTAINER_VERSION}: unpacked and checked in ${dest}."
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
  local image="${TRACEBLOC_APPLE_VMINIT_IMAGE:-}" digest="${TRACEBLOC_APPLE_VMINIT_DIGEST:-}"
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
  if [[ ! "${TRACEBLOC_MAC_KERNEL_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Apple container: the stamped kernel sha256 is '${TRACEBLOC_MAC_KERNEL_SHA256:-}', not 64 hex digits (run scripts/check-facts.sh --write)."
    return 1
  fi
  if [[ ! "${TRACEBLOC_MAC_KERNEL_IMAGE:-}" =~ ^ghcr\.io(/[a-z0-9._-]+)+$ ]]; then
    echo "Apple container: the stamped kernel repository is '${TRACEBLOC_MAC_KERNEL_IMAGE:-}', not a ghcr.io path (run scripts/check-facts.sh --write)."
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
  local want="${TRACEBLOC_MAC_KERNEL_SHA256:-}" image="${TRACEBLOC_MAC_KERNEL_IMAGE:-}" dir file repo token tmp why
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
      log "Apple container ${TRACEBLOC_APPLE_CONTAINER_VERSION}: the system is already running on the pinned init image."
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
  log "Apple container ${TRACEBLOC_APPLE_CONTAINER_VERSION}: running on kernel sha256:${TRACEBLOC_MAC_KERNEL_SHA256} and init image ${ref}."
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
#    - the API published on 127.0.0.1:6443 only, the local API (the dashboard's
#      "is this machine" handshake, client-dev#2379) on 127.0.0.1 only, and a
#      packet filter inside the node (TB_MAC_CT_NODE_WALL) that drops what other VMs on
#      this Mac send it;
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
#  The volume is made with an ext4 journal (client-dev#1983). Apple container makes a
#  volume without one unless `--opt journal=` asks for it, and a VM killed while the
#  node writes is a power loss to that filesystem: without a journal it came back
#  corrupt ("structure needs cleaning", directories containerd's metadata still names
#  gone), and containerd then refused to start on every start after. A volume an
#  earlier installer made without a journal cannot be given one in place: the run says
#  so, and how to get one, and goes on.
#
#  A corporate CA (TRACEBLOC_CA_BUNDLE, else CURL_CA_BUNDLE) reaches the node by path,
#  as the host's roots reach the WSL distro (client-dev#2116). Its certificates are
#  copied to _mac_ct_node_dir/ca, a folder the node mounts read-only: Apple container
#  mounts folders, not files. On every start, before k3s, the entrypoint rebuilds the
#  trust bundle containerd's image pulls read from the image's own copy and those
#  roots. The roots' checksum is in the argv, so new roots recreate the node (the argv
#  rule above) and k3s reads them as it starts; the same roots restart nothing. Once
#  the node is Ready this Mac reads the bundle back and holds it to every root it
#  handed in. No registries.yaml: with the bundle rebuilt, the WSL distro's containerd
#  pulled with none.
#
#  "Ready" is a Ready condition whose heartbeat is newer than the start this run
#  made: for about 40 s after a restart the stored status is the old one (S-M).
#
#  Behind a proxy the node runs with this Mac's proxy environment, as k3d's nodes and
#  native k3s's service do (cluster.sh's _node_proxy_env), with the node IP added to
#  NO_PROXY: k3s reaches its own API there, and no default range covers it. The values
#  cross in a file, never on the line: a proxy's URL can hold a password, and the argv
#  is `container run`'s command line. The file (<node dir>/proxy.env, 0600, as the join
#  token's) is handed to the runtime as `--env-file`, so the argv names only its path.
#  A changed proxy recreates the node (its data kept), and k3s and its containerd read
#  it as they start; a run without one recreates it without, and removes the file. No
#  value is logged.
#  hostPath storage and a dataset folder (TRACEBLOC_STORAGE_MODE=hostpath,
#  TRACEBLOC_HOST_DATASET_DIR) are folders on this Mac, each mounted into the node at its
#  own path (_mac_ct_node_mounts). The chart's hostPath PVs then name the same folder on
#  both sides, as on native k3s, where the node is the host (client-dev#1782): the
#  values (_hostpath_paths_block), the folders the installer prepares
#  (_ensure_release_dirs) and the summary read them unchanged. The folders are frozen
#  with the node, as its name and ranges are: an installed release's PVs name them, and
#  hostPath volumes cannot move.
#  The job-data folder (client-dev#2320, RFC-0185) is the node-local install's one folder
#  on this Mac: the dataset, logs and resume claims live in it (the chart's jobData.path),
#  so a job the Apple-GPU runner starts on the Mac reads them at the paths a pod does;
#  k3s and MySQL stay in the node. It is the user's own, at mode 0700, and mounted at its
#  own path like the hostPath folders (_mac_ct_job_data_dir, _mac_ct_job_data_private).
#  Measured on the e2e Mac (spike run 39148554631): the node's file sharing checks no
#  mode, so pods of any uid write it without opening it, and what they write is the
#  user's on this Mac. Nothing chmods inside it: a chmod in the node would reach the Mac.
#
#  Step c reaches it through _mac_ct_create_cluster (part 6).
# =============================================================================

# The node's address: TEST-NET-1 (RFC 5737), never routed, so it is free on any network.
TB_MAC_CT_NODE_IP="192.0.2.10"
# The interface flannel uses inside the node (the container's only one).
TB_MAC_CT_NODE_IFACE="eth0"
# The port the node's API listens on, published on this Mac's 127.0.0.1 only
# (_mac_ct_node_argv), and a port the node's packet filter lets this Mac reach.
TB_MAC_CT_NODE_API_PORT="6443"
# The node's packet filter (client-dev#2297, RFC-0185 D10 item 4): a chain in the mangle
# table of both IP families, which PREROUTING sends everything arriving on
# TB_MAC_CT_NODE_IFACE through, before kube-proxy's NodePort DNAT can see it. Every VM on
# this Mac shares the node's network, and the node listens on every address (the
# kubelet's 10250, the API, every NodePort), so without it any of them reaches the
# cluster. The chain lets back what answers the node's own connections, and this Mac,
# the network's gateway, to the API port and, when the node publishes it
# (TRACEBLOC_MAC_CT_LOCAL_API), the local API's NodePort, over IPv4 (the runtime's 127.0.0.1
# forwards arrive from it); it drops the rest. The local API's NodePort is the one
# NodePort this Mac reaches (Lukas's decision of 2026-10-19 on client-dev#2379,
# amending RFC-0185 D10 item 4); no other VM reaches it. The entrypoint sets the chain
# before k3s starts, on every start (the VM's kernel keeps no rule across one), and
# _mac_ct_node_walled reads it back.
TB_MAC_CT_NODE_WALL="TRACEBLOC-WALL"
# The volume's size: a sparse ext4 image, so it takes only what is written.
TB_MAC_CT_NODE_VOLUME_SIZE="64g"
# The volume's ext4 journal mode (`--opt journal=`): metadata journalled, data written
# before the metadata that names it, as Linux mounts ext4 by default (client-dev#1983).
TB_MAC_CT_NODE_VOLUME_JOURNAL="ordered"
# What a node that cannot be repaired in place needs, said by every refusal that ends there.
TB_MAC_CT_NODE_REINSTALL='run "tracebloc delete" (it removes the node and its data), then install again'
# What the node needs Rosetta for is an amd64 image; this file is there once it is installed.
TB_MAC_CT_ROSETTA_RUNTIME="/Library/Apple/usr/libexec/oah/libRosettaRuntime"
# _mac_ct_rosetta_present -- 0 when this Mac has Rosetta: TRACEBLOC_MAC_CT_ROSETTA (the
# TEST SEAM), else TB_MAC_CT_ROSETTA_RUNTIME, exists. The one answer to it: the node gets
# --rosetta exactly then (_mac_ct_node_argv), and the MySQL 5.7 gate asks the same
# (setup-macos.sh, _macos_amd64_emulation_ok).
_mac_ct_rosetta_present() { [[ -e "${TRACEBLOC_MAC_CT_ROSETTA:-$TB_MAC_CT_ROSETTA_RUNTIME}" ]]; }
# Where the entrypoint puts the join token inside the node, and the file the config's
# `token-file` names: on the container's own disk, rewritten from the argument on every
# start, so a copy a killed VM tore never reaches k3s.
TB_MAC_CT_NODE_TOKEN_FILE="/etc/rancher/k3s/tracebloc-token"
# Where the node finds the corporate CA's roots: _mac_ct_node_dir/ca, mounted read-only
# here, holding TB_MAC_CT_NODE_CA_ROOTS.
TB_MAC_CT_NODE_CA_DIR="/etc/tracebloc/ca"
TB_MAC_CT_NODE_CA_ROOTS="roots.pem"
# The trust bundle the node's containerd reads (the first of Go's system paths on
# Linux), which the entrypoint rebuilds, and the image's own copy of it, kept beside it
# once, so a restart rebuilds from that rather than adding the roots twice.
TB_MAC_CT_NODE_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
TB_MAC_CT_NODE_CA_BUNDLE_IMAGE="${TB_MAC_CT_NODE_CA_BUNDLE}.tracebloc-image"
# `awk "$TB_MAC_CT_CA_HELD_AWK" ROOTS BUNDLE` prints "HELD N": how many of the N PEM
# certificates in ROOTS the PEM file BUNDLE holds, compared by their base64 bodies, as
# the WSL distro's check compares them. It exits 1 when one is missing, or when ROOTS
# holds none. One program, for the CA (_mac_ct_ca_bundle, against /dev/null: N is how
# many it holds) and for the node's bundle read back (_mac_ct_node_ca_held).
TB_MAC_CT_CA_HELD_AWK='/-----BEGIN CERTIFICATE-----/ { body = ""; inside = 1; next }
/-----END CERTIFICATE-----/ { if (inside && body != "") { if (FILENAME == ARGV[1]) want[body] = 1; else held[body] = 1 }; inside = 0; next }
inside { gsub(/[ \t\r]/, ""); body = body $0 }
END { n = 0; m = 0; for (b in want) { n++; if (b in held) m++ }; print m, n; exit (n == 0 || m < n) }'
# The node's entrypoint. $1 is config.yaml, $2 the kubelet drop-in, $3 the node IP, $4
# the corporate CA roots' checksum (empty: no CA), $5 the local API's NodePort (empty:
# the node publishes no local API), $6 the join token. A token that is not one (empty,
# or not hex as _mac_ct_node_token makes and reads them), or a NodePort that is not a
# number, stops the node before k3s starts: k3s would make a new token. With a checksum, TB_MAC_CT_NODE_CA_BUNDLE
# is rebuilt from the image's copy and the roots handed in; roots that were not handed
# in stop the node, since its image pulls would fail on an unknown issuer. An address
# it cannot add, and that lo does not already carry, stops the node: k3s would
# advertise an address nothing answers on. Then it sets the packet filter
# (TB_MAC_CT_NODE_WALL), with this Mac's address read from the node's IPv4 default route
# (the VM's address changes on every start, and its network may not be the default
# one): this Mac reaches the API port and, with $5, that NodePort. A node with no such
# route within 30 s, or a rule it cannot set, stops before k3s: a node it cannot wall is
# never one other VMs can reach.
TB_MAC_CT_NODE_ENTRY='set -e
mkdir -p /etc/rancher/k3s
printf "%s\n" "$1" > /etc/rancher/k3s/config.yaml
printf "%s\n" "$2" > /etc/rancher/k3s/tracebloc-kubelet.yaml
case "$6" in ""|*[!0-9a-f]*) echo "tracebloc: the node was started without its join token" >&2; exit 1 ;; esac
case "$5" in *[!0-9]*) echo "tracebloc: the node was started with a local API port that is not a number ($5)" >&2; exit 1 ;; esac
(umask 077; printf "%s\n" "$6" > /etc/rancher/k3s/tracebloc-token)
if [ -n "$4" ]; then
  b='"$TB_MAC_CT_NODE_CA_BUNDLE"' i='"$TB_MAC_CT_NODE_CA_BUNDLE_IMAGE"' r='"$TB_MAC_CT_NODE_CA_DIR/$TB_MAC_CT_NODE_CA_ROOTS"'
  [ -r "$r" ] || { echo "tracebloc: the corporate CA roots were not handed to the node ($r)" >&2; exit 1; }
  [ -e "$i" ] || cp "$b" "$i"
  cat "$i" "$r" > "$b.tracebloc-new"
  mv "$b.tracebloc-new" "$b"
fi
ip addr add "$3/32" dev lo 2>/dev/null || case "$(ip -4 addr show dev lo)" in *"inet $3/32"*) ;; *) exit 1 ;; esac
w() { "$@" || { echo "tracebloc: the node could not set its packet filter ($*)" >&2; exit 1; }; }
e='"$TB_MAC_CT_NODE_IFACE"' c='"$TB_MAC_CT_NODE_WALL"' g="" n=0
while :; do
  r="$(ip -4 route show default 2>/dev/null)" || r=""
  case "$r" in "default via "*" dev $e"|"default via "*" dev $e "*) g="${r#default via }"; g="${g%% *}" ;; esac
  case "$g" in ""|*[!0-9.]*) g="" ;; *) break ;; esac
  n=$((n + 1))
  [ "$n" -lt 30 ] || { echo "tracebloc: the node has no IPv4 default route on $e, so its packet filter cannot tell this Mac from other VMs" >&2; exit 1; }
  sleep 1
done
for f in iptables ip6tables; do
  w "$f" -t mangle -N "$c"
  w "$f" -t mangle -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
done
w iptables -t mangle -A "$c" -s "$g" -p tcp --dport '"$TB_MAC_CT_NODE_API_PORT"' -j RETURN
[ -z "$5" ] || w iptables -t mangle -A "$c" -s "$g" -p tcp --dport "$5" -j RETURN
for f in iptables ip6tables; do
  w "$f" -t mangle -A "$c" -j DROP
  w "$f" -t mangle -I PREROUTING -i "$e" -j "$c"
done
exec /bin/k3s server'

# _mac_ct_refuse_host -- refuse, each by name, a host or a setting the macOS node does
# not serve, before anything is written. _native_k3s_refuse_host, the one declaration of
# where native k3s runs, calls it for a Mac (2.1 part 6), so it runs where Linux's
# refusals run, including before a k3d offboard (reinstall.sh): it stays read-only and
# reads nothing step a sets. The darwin_k3s measurement (2.1 part 5b) calls it too.
#   - The macOS floor (refuse_unsupported_mac, common.sh, on its one declaration
#     tb_mac_floor_verdict): Apple silicon, since Apple's container runtime is
#     arm64-only, with macOS TB_MACOS_FLOOR_MAJOR or later, which the runtime needs
#     (RFC-0175 D6). main() refuses those Macs on every path first (2.4,
#     client-dev#1623), with no way back to k3d; this is the same refusal.
#   - A corporate CA the node cannot take (_mac_ct_ca_bundle): set but unreadable, or
#     holding no PEM certificate. One it can take is handed in by _mac_ct_ensure_node.
#   - hostPath storage and a dataset folder the node cannot mount
#     (_mac_ct_hostpath_dirs): a path that is not absolute, holds a ':' (which
#     `container run -v` splits on) or a line break, or lies in a system tree the node's
#     own files are in (_tb_system_path). One it can mount is served (_mac_ct_node_mounts).
#   - k3d's node counts, refused as on Linux (_native_k3s_refuse_k3d_nodes), and the
#     pinned k3s version (_native_k3s_check_version).
_mac_ct_refuse_host() {
  [[ "${OS:-}" == "Darwin" ]] \
    || error "The macOS node runs on a Mac only, and this machine runs ${OS:-an unknown OS}."
  refuse_unsupported_mac
  local why
  if declare -F _resolve_ca_bundle >/dev/null 2>&1; then why="$(_mac_ct_ca_bundle)" || error "$why"; fi
  local dirs
  dirs="$(_mac_ct_hostpath_dirs)" || error "$dirs"
  _native_k3s_refuse_k3d_nodes
  _native_k3s_check_version
}

# _mac_ct_job_data_dir -- the macOS node's job-data folder (client-dev#2320), or nothing
# when this run keeps no job data on this Mac. Under node-local only (hostpath keeps its
# own tree). An installed release decides, once _native_k3s_release_storage has read it:
# one that names a folder (jobData.path) keeps that folder, and one that names none (a
# v1.11 Mac's: its claims are in the node and cannot move) gets none. Before the release
# is read, the node decides: one made without any frozen mounts (run-args and no
# hostpath file, a v1.11 node-local Mac's) gets none, so an upgrade neither recreates it
# nor makes a folder its claims never use. Otherwise it is <data dir>/job-data, the data
# dir read as validate_config reads HOST_DATA_DIR (_tb_home_path). A caller's values file
# (TRACEBLOC_VALUES_FILE) that opens hostPath keeps job data in its own tree, so it gets
# none: the chart refuses jobData.path beside hostPath.enabled (tracebloc.jobDataRefusal).
_mac_ct_job_data_dir() {
  [[ "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] || return 0
  case "${TRACEBLOC_JOB_DATA_KEPT:-}" in
    1) printf '%s' "${TRACEBLOC_JOB_DATA_KEPT_DIR:-}"; return 0 ;;
    0) return 0 ;;
  esac
  local base dir
  if [[ -r "${TRACEBLOC_VALUES_FILE:-}" ]] && declare -F _values_hostpath_storage >/dev/null \
     && _values_hostpath_storage <"$TRACEBLOC_VALUES_FILE" | grep -x 'enabled=true' >/dev/null; then
    return 0
  fi
  if dir="$(_mac_ct_node_dir 2>/dev/null)" && [[ -e "${dir}/run-args" && ! -e "${dir}/hostpath" ]]; then
    return 0
  fi
  base="$(_tb_home_path "${HOST_DATA_DIR:-}")"
  [[ -n "$base" ]] || return 0
  printf '%s/job-data' "${base%/}"
}

# _mac_ct_job_data_private DIR -- DIR is a folder of this user's at mode 0700, or prints
# why and fails. A missing one is made (its parents as mkdir -p makes them) at 0700, and
# one at another mode is set to it: never world-writable (RFC-0003's reason for leaving
# hostpath), and nothing in the node needs more (see Part 3). A symbolic link, or a
# folder that is not this user's, is refused, never chmodded: it is not a folder this
# installer made. The checks are find's -user and -perm, which BSD and GNU read alike.
_mac_ct_job_data_private() {
  local d="$1" uid
  uid="$(id -u)" || { echo "Apple container: cannot tell this user's uid (id -u), so whether ${d} is theirs cannot be told."; return 1; }
  if [[ -L "$d" ]]; then
    echo "The job-data folder ${d} is a symbolic link. It must be a folder of your own, so that training data on this Mac stays private to you. Remove the link, or point TRACEBLOC_HOST_DATA_DIR at another folder, then re-run."
    return 1
  fi
  if [[ ! -e "$d" ]]; then
    { mkdir -p "${d%/*}" && mkdir -m 0700 "$d"; } \
      || { echo "Apple container: the job-data folder ${d} could not be made, so the node cannot mount it."; return 1; }
  fi
  [[ -d "$d" ]] || { echo "The job-data folder ${d} is there and is not a folder. Move it aside, or point TRACEBLOC_HOST_DATA_DIR at another folder, then re-run."; return 1; }
  [[ -n "$(find "$d" -prune -user "$uid" 2>/dev/null)" ]] \
    || { echo "The job-data folder ${d} is not yours (uid ${uid}), so training data in it would not be private to you. Point TRACEBLOC_HOST_DATA_DIR at a folder of your own, then re-run."; return 1; }
  chmod 0700 "$d" 2>/dev/null \
    || { echo "Apple container: could not set the job-data folder ${d} to mode 0700 (yours only)."; return 1; }
  [[ -n "$(find "$d" -prune -perm 700 2>/dev/null)" ]] \
    || { echo "Apple container: the job-data folder ${d} is not at mode 0700 after chmod, so whether it is private to you cannot be told."; return 1; }
}

# _mac_ct_hostpath_dirs -- the folders this run's storage asks the node to mount, one a
# line. hostpath: the hostPath root (_hostpath_root, HOST_DATA_DIR read as
# validate_config reads it, unless a release's own is kept) and the dataset folder (an
# installed release's, else HOST_DATASET_DIR) when there is one. node-local: the
# job-data folder (_mac_ct_job_data_dir), when there is one. Prints why, and fails, for
# a folder the node cannot mount at its own path: one that is not absolute, holds a ':'
# (`container run -v` splits on it) or a line break, or lies in a system tree
# (_tb_system_path), where it would cover the node's own files.
_mac_ct_hostpath_dirs() {
  local root ds d nl=$'\n'
  if [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]]; then
    # node-local: the job-data folder, when this run keeps one (client-dev#2320).
    root="$(_mac_ct_job_data_dir)"; ds=""
    [[ -n "$root" ]] || return 0
  else
    root="$(_hostpath_root)"
    # The refusal runs before validate_config: read this run's root as it will
    # (_tb_home_path), so ~/data or a $HOME-relative one is not refused as relative.
    [[ "${TB_HOSTPATH_KEPT:-}" == 1 ]] || root="$(_tb_home_path "$root")"
    ds="${HOST_DATASET_DIR:-}"
    [[ "${TB_HOSTPATH_KEPT:-}" != 1 ]] || ds="${TB_HOSTPATH_DATASET:-}"
  fi
  for d in "$root" "$ds"; do
    [[ -n "$d" ]] || continue
    if [[ "$d" != /* || "$d" == *:* || "$d" == *"$nl"* ]] || _tb_system_path "$d"; then
      echo "'${d}' is a hostPath folder the macOS node cannot mount at its own path: it must be an absolute path with no ':', outside the system folders (/etc, /usr, /var and the like). Point TRACEBLOC_HOST_DATA_DIR or TRACEBLOC_HOST_DATASET_DIR at another folder, then re-run."
      return 1
    fi
    printf '%s\n' "$d"
  done
}

# _mac_ct_node_mounts DIR -- the hostPath folders the node mounts, one a line, frozen in
# DIR/hostpath. A node with none frozen takes this run's (_mac_ct_hostpath_dirs), and
# keeps them: every run after mounts the same folders, whatever it asks for, since an
# installed release's PVs name them, and a run that asks for others is told they are
# not used. Each folder is made if it is missing (as _ensure_release_dirs makes them
# on Linux): the runtime mounts only a folder that is there. Nothing when the node has
# none frozen and this run is node-local. Prints why, and fails, when a folder cannot
# be mounted, made, read back from DIR/hostpath, or frozen.
_mac_ct_node_mounts() {
  local file="${1}/hostpath" want got d off="" jd why
  want="$(_mac_ct_hostpath_dirs)" || { printf '%s' "$want"; return 1; }
  jd="$(_mac_ct_job_data_dir)"
  if [[ -e "$file" ]]; then
    got="$(cat "$file")" || { echo "Apple container: ${file} cannot be read, so this run cannot tell which hostPath folders the node mounts."; return 1; }
    # A job-data folder the node lacks is not named here: whether this release needs it
    # is decided once the release is read, and _mac_ct_hostpath_mounted stops it then.
    while IFS= read -r d; do
      [[ -z "$d" || "$d" == "$jd" ]] || grep -qxF -- "$d" <<<"$got" || off="${off:+${off}, }${d}"
    done <<<"$want"
    if [[ -n "$off" ]]; then
      warn "The macOS node mounts the hostPath folders it was made with (${got//$'\n'/, }), and this run asked for ${off}, which it does not mount: hostPath volumes can't move. To use another folder, remove tracebloc from this Mac, then install again with it." >&2
    fi
  else
    got="$want"
    [[ -n "$got" ]] || return 0
    printf '%s\n' "$got" > "${file}.tmp" && mv "${file}.tmp" "$file" \
      || { rm -f "${file}.tmp"; echo "Apple container: could not write ${file}."; return 1; }
  fi
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ -n "$jd" && "$d" == "$jd" ]]; then
      why="$(_mac_ct_job_data_private "$d")" || { printf '%s' "$why"; return 1; }
      continue
    fi
    mkdir -p "$d" || { echo "Apple container: the hostPath folder ${d} is not there and could not be made, so the node cannot mount it. Make it (or mount the volume it is on), then re-run."; return 1; }
  done <<<"$got"
  printf '%s' "$got"
}

# _mac_ct_hostpath_mounted -- the folders the release's PVs will name (_mac_ct_hostpath_dirs,
# after _native_k3s_release_storage has read the release: hostpath's, or the job-data
# folder) are among the node's frozen mounts (_mac_ct_node_dir/hostpath), or the run stops
# by name before the values are written: a PV naming a folder the node does not mount
# would put its data inside the VM, not on this Mac. The job-data folder is held private
# again first (_mac_ct_job_data_private). A frozen file that cannot be read is cannot
# tell, and stops it too. Nothing to check when the release names no folder.
_mac_ct_hostpath_mounted() {
  local want got dir d jd why
  want="$(_mac_ct_hostpath_dirs)" || error "$want"
  [[ -n "$want" ]] || return 0
  jd="$(_mac_ct_job_data_dir)"
  if [[ -n "$jd" ]]; then why="$(_mac_ct_job_data_private "$jd")" || error "$why"; fi
  dir="$(_mac_ct_node_dir)" || error "Apple container: cannot tell where the node's files are (above)."
  got="$(cat "${dir}/hostpath" 2>/dev/null)" \
    || error "Apple container: ${dir}/hostpath cannot be read, so this run cannot tell which hostPath folders the node mounts. It's safe to re-run this installer."
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ "$d" != "$jd" ]] || grep -qxF -- "$d" <<<"$got" \
      || error "The tracebloc release's job data is in ${d}, and the macOS node does not mount it (it mounts ${got:-nothing}): its data would land inside the node's VM, not on this Mac. Remove tracebloc from this Mac, then install again."
    grep -qxF -- "$d" <<<"$got" \
      || error "The tracebloc release's hostPath volumes are in ${d}, and the macOS node does not mount it (it mounts ${got//$'\n'/, }): its data would land inside the node's VM, not on this Mac. hostPath volumes can't move: re-run with the folders the node mounts, or remove tracebloc from this Mac, then install again."
  done <<<"$want"
}

# _mac_ct_job_data_record -- records the job-data folder (install-record kind job-data,
# client-dev#2320), id = the node that mounts it, once the release's storage is decided
# and the node is known to mount the folder (_mac_ct_hostpath_mounted). Only a release
# that keeps its job data there records one, so the entry is also the Apple-GPU runner's
# marker that it does (tracebloc/cli-dev#1305). Nothing without one.
_mac_ct_job_data_record() {
  local jd name
  jd="$(_mac_ct_job_data_dir)"
  [[ -n "$jd" ]] || return 0
  name="$(_mac_ct_node_name)" || error "$name"
  tb_record_write job-data "$name" "$jd"
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
#   CPUs:   the Mac's cores less the VM's own (TB_MAC_CT_VM_OWN_CPUS), at least 1, so
#           the node advertises the Mac's cores.
# The VM never returns memory (no balloon), so this is what the Mac gives up while the
# node runs.
#
# TB_MAC_CT_VM_OWN_CPUS: the vCPUs Apple's VM adds to the --cpus it is given, as the node
# advertises them. RFC-0175 measured one on the spike Mac, and the e2e EC2 Mac again on
# 2026-10-14 (--cpus 2 advertised 3, --cpus 9 advertised 10). The one declaration: the
# node's size keeps that many of the Mac's cores back, and preflight's CPU reader
# (_pf_runtime_ncpu) adds them again, so the fit gate budgets what the node advertises.
TB_MAC_CT_VM_OWN_CPUS=1
_mac_ct_node_size() {
  local spare="$TB_MAC_CT_VM_OWN_CPUS" phys ncpu cpus re='^[1-9][0-9]*$'
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

# _mac_ct_node_proxy_env -- the proxy environment the node runs with, one NAME=VALUE a
# line, into stdout: cluster.sh's _node_proxy_env, the one definition k3d's nodes and
# native k3s take, with TB_MAC_CT_NODE_IP added to this Mac's NO_PROXY (or no_proxy).
# Nothing when this Mac sets no HTTP(S) proxy. Prints why, and fails, when cluster.sh,
# which holds it, is not loaded: a node run without the proxy would pull direct and
# fail late, naming nothing of ours. A proxy value with a line break in it is refused by
# the variable's name, never its value: it would end its line in the env file early.
_mac_ct_node_proxy_env() {
  if ! declare -F _node_proxy_env >/dev/null 2>&1; then
    echo "Apple container: the installer's proxy reader (cluster.sh) is not loaded, so this run cannot tell whether the node needs a proxy."
    return 1
  fi
  local np="${NO_PROXY:-${no_proxy:-}}" var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ "${!var:-}" == *$'\n'* ]]; then
      echo "${var} is set, but its value has a line break in it, so the macOS node cannot take it as a proxy. Set ${var} to your proxy's address, like http://proxy.example.com:3128, or remove it, then re-run."
      return 1
    fi
  done
  ( NO_PROXY="${np:+${np},}${TB_MAC_CT_NODE_IP}"; _node_proxy_env )
}

# _mac_ct_node_argv NAME IMAGE CONFIG KUBELET SIZE TOKEN [CADIR CASUM] -- the `container
# run` argv, into TB_MAC_CT_NODE_ARGV (an array: the config holds newlines and quotes).
# --rosetta is in it when this Mac has Rosetta (_mac_ct_rosetta_present), a
# `-v FOLDER:FOLDER` for each line of TB_MAC_CT_NODE_MOUNTS (the hostPath folders,
# _mac_ct_node_mounts's, which _mac_ct_ensure_node sets), and `--env-file` naming
# TB_MAC_CT_NODE_PROXY_FILE when it is set (the proxy's file, which _mac_ct_ensure_node
# sets: a path, never a value). TOKEN is the join token, the entrypoint's last argument:
# it makes the argv a secret, so run-args is kept 0600. CASUM is the corporate CA roots'
# checksum (_mac_ct_node_ca): with one, CADIR, the folder on this Mac that holds them, is
# mounted read-only at TB_MAC_CT_NODE_CA_DIR, and the checksum reaches the entrypoint, so
# that new roots make a new argv. With TRACEBLOC_MAC_CT_LOCAL_API set ("HOST NODE", which
# _mac_ct_local_api decides), 127.0.0.1:HOST is published to the local API's NodePort
# beside the API, and NODE reaches the entrypoint, whose packet filter lets this Mac
# reach it; without, neither.
TB_MAC_CT_NODE_ARGV=()
TB_MAC_CT_NODE_MOUNTS=""
TB_MAC_CT_NODE_PROXY=""
TB_MAC_CT_NODE_PROXY_FILE=""
TRACEBLOC_MAC_CT_LOCAL_API=""
_mac_ct_node_argv() {
  local name="$1" image="$2" cfg="$3" kubelet="$4" cpus="${5%% *}" mem="${5#* }" token="$6" cadir="${7:-}" casum="${8:-}" d
  TB_MAC_CT_NODE_ARGV=(run -d --name "$name"
    --cap-add ALL --read-only-path NONE --masked-path NONE)
  ! _mac_ct_rosetta_present || TB_MAC_CT_NODE_ARGV+=(--rosetta)
  TB_MAC_CT_NODE_ARGV+=(--cpus "$cpus" --memory "$mem"
    -v "${name}:/var/lib/rancher/k3s" --tmpfs /run --tmpfs /var/run)
  [[ -z "$casum" ]] || TB_MAC_CT_NODE_ARGV+=(-v "${cadir}:${TB_MAC_CT_NODE_CA_DIR}:ro")
  while IFS= read -r d; do
    [[ -z "$d" ]] || TB_MAC_CT_NODE_ARGV+=(-v "${d}:${d}")
  done <<<"$TB_MAC_CT_NODE_MOUNTS"
  [[ -z "$TB_MAC_CT_NODE_PROXY_FILE" ]] || TB_MAC_CT_NODE_ARGV+=(--env-file "$TB_MAC_CT_NODE_PROXY_FILE")
  TB_MAC_CT_NODE_ARGV+=(-p "127.0.0.1:${TB_MAC_CT_NODE_API_PORT}:${TB_MAC_CT_NODE_API_PORT}")
  local lport=""
  if [[ -n "$TRACEBLOC_MAC_CT_LOCAL_API" ]]; then
    lport="${TRACEBLOC_MAC_CT_LOCAL_API#* }"
    TB_MAC_CT_NODE_ARGV+=(-p "127.0.0.1:${TRACEBLOC_MAC_CT_LOCAL_API%% *}:${lport}")
  fi
  TB_MAC_CT_NODE_ARGV+=(--entrypoint /bin/sh "$image" -c "$TB_MAC_CT_NODE_ENTRY"
    sh "$cfg" "$kubelet" "$TB_MAC_CT_NODE_IP" "$casum" "$lport" "$token")
}

# _mac_ct_local_api HAVE -- whether this run's node publishes the local API (backend#5208,
# client-dev#2379): into TRACEBLOC_MAC_CT_LOCAL_API, "HOST NODE" (TRACEBLOC_LOCAL_API_HOST_PORT
# and TRACEBLOC_LOCAL_API_NODE_PORT, k3d.sh's one declaration of them), or "" when it
# does not. As on k3d, fail-soft: TRACEBLOC_LOCAL_API=off opts out (_local_api_wanted),
# ports the chart would refuse turn it off with k3d's warning (_local_api_port_valid), and
# so does a host port something else on this Mac already listens on
# (_local_api_host_port_busy), or the API's own port. HAVE is the argv the node was
# created with (run-args): a node that already publishes the host port, to whichever
# NodePort, is what holds it, so it is never read as busy, and recreating that node
# frees it first.
_mac_ct_local_api() {
  local have="${1:-}" hp="$TRACEBLOC_LOCAL_API_HOST_PORT"
  TRACEBLOC_MAC_CT_LOCAL_API=""
  _local_api_wanted || return 0
  _local_api_port_valid || { _local_api_invalid_warn; return 0; }
  if (( 10#$hp == 10#$TB_MAC_CT_NODE_API_PORT )) \
      || { ! grep -qE "^127[.]0[.]0[.]1:${hp}:[0-9]+\$" <<<"$have" && _local_api_host_port_busy; }; then
    _local_api_busy_warn
    return 0
  fi
  TRACEBLOC_MAC_CT_LOCAL_API="${TRACEBLOC_LOCAL_API_HOST_PORT} ${TRACEBLOC_LOCAL_API_NODE_PORT}"
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

# _mac_ct_volume_journaled CT NAME -- 0 when volume NAME was made with an ext4 journal:
# its options, as `volume inspect` prints them, name one; 1 when they name none; 2 when
# this run cannot tell (the inspect failed, or printed no options at all).
_mac_ct_volume_journaled() {
  local out
  out="$(_bounded 30 "$1" volume inspect "$2" </dev/null 2>/dev/null)" || return 2
  grep -q '"options"' <<<"$out" || return 2
  grep -Eq '"journal"[[:space:]]*:[[:space:]]*"[a-z]' <<<"$out"
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
  local how="$TB_MAC_CT_NODE_REINSTALL"
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

# _mac_ct_ca_bundle -- the corporate CA the node takes: _resolve_ca_bundle's file
# (TRACEBLOC_CA_BUNDLE, else CURL_CA_BUNDLE), printed when it holds a PEM certificate,
# nothing when none is set. Prints why, and fails, when the bundle is set but cannot be
# read, when it holds no PEM certificate (a DER file, say: the node would start with
# none of it), and when cluster.sh, which reads it, is not loaded (cannot tell).
_mac_ct_ca_bundle() {
  local ca="" rc=0 said=""
  if ! declare -F _resolve_ca_bundle >/dev/null 2>&1; then
    echo "Apple container: the installer's CA reader (cluster.sh) is not loaded, so this run cannot tell whether a corporate CA is set."
    return 1
  fi
  ca="$(_resolve_ca_bundle)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "${ca} is set but its CA bundle file can't be read — fix its path/permissions and re-run."
    return 1
  fi
  [[ -n "$ca" ]] || return 0
  said="$(awk "$TB_MAC_CT_CA_HELD_AWK" "$ca" /dev/null)" || true
  if [[ ! "${said#* }" =~ ^[1-9][0-9]*$ ]]; then
    echo "${ca}, the corporate CA bundle (TRACEBLOC_CA_BUNDLE or CURL_CA_BUNDLE), holds no PEM certificate (-----BEGIN CERTIFICATE-----), so the macOS node could not trust it. Point it at the bundle in PEM form, then re-run."
    return 1
  fi
  printf '%s' "$ca"
}

# _mac_ct_node_ca CADIR -- hand the corporate CA to the node: _mac_ct_ca_bundle's file
# copied to CADIR/TB_MAC_CT_NODE_CA_ROOTS (0644; rewritten only when it changed), and
# its checksum printed for the argv (`cksum`'s CRC and size). Prints nothing when no CA
# is set: an earlier copy stays until the node runs without it (_mac_ct_ensure_node).
# Prints why, and fails, when the CA cannot be taken, when CADIR has a ':' in it, which
# `container run -v` splits on, and when the copy cannot be written.
_mac_ct_node_ca() {
  local cadir="$1" ca roots sum
  ca="$(_mac_ct_ca_bundle)" || { printf '%s' "$ca"; return 1; }
  [[ -n "$ca" ]] || return 0
  if [[ "$cadir" == *:* ]]; then
    echo "Apple container: ${cadir} has a ':' in it, and the node's mounts cannot take one, so the corporate CA cannot be handed to the node. Set TRACEBLOC_CA_BUNDLE only on a Mac whose home folder path has no ':'."
    return 1
  fi
  roots="${cadir}/${TB_MAC_CT_NODE_CA_ROOTS}"
  if ! cmp -s "$ca" "$roots"; then
    { mkdir -p "$cadir" && cp "$ca" "${roots}.tmp" && chmod 0644 "${roots}.tmp" && mv "${roots}.tmp" "$roots"; } || {
      rm -f "${roots}.tmp"
      echo "Apple container: could not copy the corporate CA (${ca}) to ${roots}, where the node reads it."
      return 1
    }
  fi
  sum="$(cksum < "$roots")" || sum=""
  if [[ ! "$sum" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
    echo "Apple container: cksum gave no checksum for ${roots}, so this run cannot tell whether the node holds these roots."
    return 1
  fi
  printf '%s-%s' "${sum%%[[:space:]]*}" "${sum##*[[:space:]]}"
}

# _mac_ct_node_ca_held CT NAME DIR -- the node's trust bundle, read back, holds every
# corporate CA root handed in (DIR/ca/TB_MAC_CT_NODE_CA_ROOTS), or the run stops,
# saying how many it holds. A bundle that cannot be read back is cannot tell, and stops
# it too: it is never read as held.
_mac_ct_node_ca_held() {
  local ct="$1" name="$2" roots="${3}/ca/${TB_MAC_CT_NODE_CA_ROOTS}" bundle="${3}/node-ca-bundle.tmp" said="" rc=0
  local re='^[0-9]+ [0-9]+$' cannot="could not be read back, so whether it holds the corporate CA's roots cannot be told. It's safe to re-run this installer."
  if ! _bounded 30 "$ct" exec "$name" cat "$TB_MAC_CT_NODE_CA_BUNDLE" </dev/null >"$bundle" 2>/dev/null || [[ ! -s "$bundle" ]]; then
    rm -f "$bundle"
    error "Apple container: the node's trust bundle (${TB_MAC_CT_NODE_CA_BUNDLE} in ${name}) ${cannot}"
  fi
  said="$(awk "$TB_MAC_CT_CA_HELD_AWK" "$roots" "$bundle")" || rc=$?
  rm -f "$bundle"
  [[ "$said" =~ $re ]] \
    || error "Apple container: the corporate CA's roots (${roots}) or the node's trust bundle ${cannot}"
  [[ "$rc" -eq 0 ]] \
    || error "Apple container: the node's trust bundle (${TB_MAC_CT_NODE_CA_BUNDLE} in ${name}) holds ${said% *} of the ${said#* } corporate CA root(s) in ${roots}, so its image pulls would fail on an unknown certificate issuer. Run this installer again; if it keeps failing, share this output with tracebloc support."
  log "Apple container: the node trusts the corporate CA's ${said#* } root(s)."
}

# _mac_ct_node_walled CT NAME -- the node's packet filter, read back from the mangle
# table of both IP families: PREROUTING's first rule sends TB_MAC_CT_NODE_IFACE through
# TB_MAC_CT_NODE_WALL, and that chain's last rule drops. With the local API published
# (TRACEBLOC_MAC_CT_LOCAL_API), the IPv4 chain also lets one address, this Mac's, to its
# NodePort: without that rule the dashboard's handshake never reaches the node. Anything
# else stops the run, saying which family is open or which rule is missing; a table that
# cannot be read back is cannot tell, and stops it too: it is never read as walled.
_mac_ct_node_walled() {
  local ct="$1" name="$2" f out said err lport=""
  err="$(mktemp)" || error "Apple container: cannot make a scratch file to read the node's packet filter back."
  local jump="-A PREROUTING -i ${TB_MAC_CT_NODE_IFACE} -j ${TB_MAC_CT_NODE_WALL}" drop="-A ${TB_MAC_CT_NODE_WALL} -j DROP"
  [[ -z "$TRACEBLOC_MAC_CT_LOCAL_API" ]] || lport="${TRACEBLOC_MAC_CT_LOCAL_API#* }"
  for f in iptables ip6tables; do
    out="$(_bounded 30 "$ct" exec "$name" "$f" -w 10 -t mangle -S </dev/null 2>"$err")" && [[ -n "$out" ]] \
      || { said="$(head -c 300 "$err" 2>/dev/null | tr '\n' ' ')"; rm -f "$err"; error "Apple container: the node's packet filter (${f} in ${name}) could not be read back${said:+ (${said% })}, so whether other VMs on this Mac can reach the cluster cannot be told. It's safe to re-run this installer."; }
    rm -f "$err"
    awk -v jump="$jump" -v chain="-A ${TB_MAC_CT_NODE_WALL} " -v drop="$drop" '
      /^-A PREROUTING / && first == "" { first = $0 }
      index($0, chain) == 1 { last = $0 }
      END { exit !(first == jump && last == drop) }' <<<"$out" \
      || error "Apple container: the node's packet filter is not set (${f} in ${name}: PREROUTING's first rule is not \"${jump}\", or the chain does not end in \"${drop}\"), so other VMs on this Mac could reach the cluster. Run this installer again; if it keeps failing, share this output with tracebloc support."
    [[ "$f" == iptables && -n "$lport" ]] || continue
    awk -v chain="-A ${TB_MAC_CT_NODE_WALL} " -v port="$lport" '
      index($0, chain) == 1 && $3 == "-s" && $4 ~ /^[0-9.]+\/32$/ && $0 ~ (" --dport " port " -j RETURN$") { found = 1 }
      END { exit !found }' <<<"$out" \
      || error "Apple container: the node's packet filter does not let this Mac reach the local API (${f} in ${name}: no rule lets one address to port ${lport}), so the dashboard cannot tell it is on this machine. Run this installer again; if it keeps failing, share this output with tracebloc support."
  done
  if [[ -n "$lport" ]]; then
    log "Apple container: the node's packet filter holds: other VMs on this Mac cannot reach it, and this Mac reaches its API and the local API only."
  else
    log "Apple container: the node's packet filter holds: other VMs on this Mac cannot reach it, and this Mac reaches its API only."
  fi
}

# _mac_ct_node_drop_local_api CT NAME VERB RC -- the node's VERB (run or start) exited RC
# with the local API published: say so, remove the node it left and clear
# TRACEBLOC_MAC_CT_LOCAL_API, so the caller makes the node again without it on its volume.
# The local API is optional, as on k3d (client-dev#1665): the free-port probe is a
# snapshot, and the runtime's own bind can still lose the port.
_mac_ct_node_drop_local_api() {
  local ct="$1" name="$2" verb="$3" rc="$4" gone
  warn "The node did not start with the local dashboard port 127.0.0.1:${TRACEBLOC_MAC_CT_LOCAL_API%% *} published (\"${ct}\" ${verb} exited ${rc}), so it is started again without it, and the dashboard won't be able to tell it is on this machine. Everything else works; free the port and re-run the installer to turn it on."
  # A failed start may leave a node, stopped or not: stop it, then remove it, and a node
  # that is still there is no node to make again beside.
  _bounded 120 "$ct" stop "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  if ! _bounded 60 "$ct" delete "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; then
    gone=0; _mac_ct_node_exists "$ct" "$name" || gone=$?
    [[ "$gone" -eq 1 ]] \
      || error "Apple container: could not remove the node ${name} the failed start left, to start it again without the local dashboard port. Its volume is untouched. Run \"${ct}\" delete --force ${name}, then re-run."
  fi
  TRACEBLOC_MAC_CT_LOCAL_API=""
}

# _mac_ct_ensure_node -- the node on the running system (part 2), Ready, its packet
# filter read back (_mac_ct_node_walled), recorded, and its kubeconfig copied to
# _mac_ct_node_dir/k3s.yaml. Reuses a running node created with this argv, starts a
# stopped one, recreates one created with another argv on its volume, and refuses a
# container or a volume of its name that nothing shows this installer made.
_mac_ct_ensure_node() {
  local root ct name dir image cfgfile cidrs node cfg kubelet size want have="" rc since start="" mkvol="" state casum running=""
  local penv pold="" pchanged=""
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
  # A volume an earlier installer made without a journal is kept: it cannot gain one in
  # place, and the node on it runs. The run says what it risks and how to get one.
  if [[ "$state" != fresh ]]; then
    rc=0; _mac_ct_volume_journaled "$ct" "$name" || rc=$?
    case "$rc" in
      0) ;;
      1) warn "Apple container: the node's volume ${name} was made without an ext4 journal, by an earlier installer. A crash or power loss while the node runs can corrupt it, and the node then never starts again. It cannot be given one in place (the node's image carries no e2fsprogs). To get a volume with a journal, ${TB_MAC_CT_NODE_REINSTALL}." ;;
      *) warn "Apple container: this run cannot tell whether the node's volume ${name} has an ext4 journal (\"${ct}\" volume inspect ${name} did not say). Without one, a crash or power loss while the node runs can corrupt it." ;;
    esac
  fi
  # The token goes first, before run-args: whatever a run cut off half-way leaves, a
  # re-run must start with the token the node's data is encrypted with.
  _mac_ct_node_token "$ct" "$name" "$dir" "$state"
  casum="$(_mac_ct_node_ca "${dir}/ca")" || error "$casum"
  TB_MAC_CT_NODE_MOUNTS="$(_mac_ct_node_mounts "$dir")" || error "$TB_MAC_CT_NODE_MOUNTS"
  # The proxy: its values in a 0600 file the argv names, never in the argv. The file the
  # node was made with says whether they changed; one that cannot be read is cannot tell.
  TB_MAC_CT_NODE_PROXY="$(_mac_ct_node_proxy_env)" || error "$TB_MAC_CT_NODE_PROXY"
  penv="${dir}/proxy.env"; TB_MAC_CT_NODE_PROXY_FILE=""
  if [[ -n "$TB_MAC_CT_NODE_PROXY" ]]; then
    TB_MAC_CT_NODE_PROXY_FILE="$penv"
    if [[ -e "$penv" ]]; then
      pold="$(cat "$penv")" || error "Apple container: ${penv} cannot be read, so this run cannot tell which proxy the node runs with. It's safe to re-run this installer."
    fi
    [[ "$pold" == "$TB_MAC_CT_NODE_PROXY" ]] || pchanged=1
  fi
  # The node holds the local API's host port only while it runs. One that is stopped, or a
  # run cut off before its node started, holds nothing, so its run-args says nothing about
  # who holds the port, and the port is probed as on a fresh node. This one read also
  # decides below whether a kept node is started.
  if [[ "$state" == container ]]; then
    rc=0; _mac_ct_node_running "$ct" "$name" || rc=$?
    case "$rc" in
      0) running=1 ;;
      1) ;;
      *) error "Apple container: the container system did not list its containers, so this run cannot tell whether the node ${name} is running." ;;
    esac
  fi
  _mac_ct_local_api "${running:+$have}"
  _mac_ct_node_argv "$name" "$image" "$cfg" "$kubelet" "$size" "$TB_MAC_CT_NODE_TOKEN" "${dir}/ca" "$casum"
  want="$(printf '%s\n' "${TB_MAC_CT_NODE_ARGV[@]}")"  # set-u-safe: _mac_ct_node_argv seeds it with the run verb
  if [[ "$state" == container ]]; then
    if [[ "$have" != "$want" || -n "$pchanged" ]]; then
      log "Apple container: the node's settings changed since it was created, so it is recreated on its volume ${name}; its data is kept."
      # A stop that fails is not the end: a node that is already stopped may refuse it,
      # and the delete below is what says whether the node is gone.
      _bounded 120 "$ct" stop "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
      _bounded 60 "$ct" delete "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: could not remove the node ${name} to recreate it. Its volume is untouched. Run \"${ct}\" delete --force ${name}, then re-run."
      start=run
    else
      [[ -n "$running" ]] || start=start
    fi
  else
    start=run
  fi
  # A run without a proxy keeps no proxy file: this node's argv names none (one made
  # with it was removed above, to be made again without).
  [[ -n "$TB_MAC_CT_NODE_PROXY" ]] || rm -f "$penv"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$start" == start ]]; then
    rc=0; _bounded 120 "$ct" start "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 && -n "$TRACEBLOC_MAC_CT_LOCAL_API" ]]; then
      _mac_ct_node_drop_local_api "$ct" "$name" start "$rc"
      _mac_ct_node_argv "$name" "$image" "$cfg" "$kubelet" "$size" "$TB_MAC_CT_NODE_TOKEN" "${dir}/ca" "$casum"
      want="$(printf '%s\n' "${TB_MAC_CT_NODE_ARGV[@]}")"  # set-u-safe: _mac_ct_node_argv seeds it with the run verb
      start=run
    else
      [[ "$rc" -eq 0 ]] \
        || error "Apple container: the node ${name} did not start. \"${ct}\" logs ${name} says why. It's safe to re-run this installer."
    fi
  fi
  case "$start" in
    run)
      # The image is needed only to create a node: reusing or starting one works with the
      # registry unreachable.
      log "Apple container: pulling the k3s node image ${image}..."
      _bounded 900 "$ct" image pull --platform linux/arm64 --progress none "$image" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Couldn't pull the k3s node image ${image}. Check that this machine can reach registry-1.docker.io, then re-run."
      # run-args goes first, before the volume and the container: whatever a run cut off
      # half-way leaves, a re-run must recognise as this installer's.
      # 0600: the argv carries the join token, and the proxy's file can carry a password.
      if [[ -n "$TB_MAC_CT_NODE_PROXY" ]]; then
        (umask 077; printf '%s\n' "$TB_MAC_CT_NODE_PROXY" > "${penv}.tmp") && mv "${penv}.tmp" "$penv" \
          || { rm -f "${penv}.tmp"; error "Apple container: could not write ${penv}."; }
      fi
      (umask 077; printf '%s\n' "$want" > "${dir}/run-args.tmp") && mv "${dir}/run-args.tmp" "${dir}/run-args" \
        || { rm -f "${dir}/run-args.tmp"; error "Apple container: could not write ${dir}/run-args."; }
      [[ -z "$mkvol" ]] || _bounded 60 "$ct" volume create --opt "size=${TB_MAC_CT_NODE_VOLUME_SIZE}" --opt "journal=${TB_MAC_CT_NODE_VOLUME_JOURNAL}" "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
        || error "Apple container: could not create the node's volume ${name}."
      # set-u-safe: _mac_ct_node_argv seeds it with the run verb
      rc=0; _bounded 300 "$ct" "${TB_MAC_CT_NODE_ARGV[@]}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
      # A run that carried the local API and failed is made once more without it
      # (_mac_ct_node_drop_local_api), and run-args says so first, so a re-run probes the
      # port afresh. A node that fails again fails the run.
      if [[ "$rc" -ne 0 && -n "$TRACEBLOC_MAC_CT_LOCAL_API" ]]; then
        _mac_ct_node_drop_local_api "$ct" "$name" run "$rc"
        _mac_ct_node_argv "$name" "$image" "$cfg" "$kubelet" "$size" "$TB_MAC_CT_NODE_TOKEN" "${dir}/ca" "$casum"
        want="$(printf '%s\n' "${TB_MAC_CT_NODE_ARGV[@]}")"  # set-u-safe: _mac_ct_node_argv seeds it with the run verb
        (umask 077; printf '%s\n' "$want" > "${dir}/run-args.tmp") && mv "${dir}/run-args.tmp" "${dir}/run-args" \
          || { rm -f "${dir}/run-args.tmp"; error "Apple container: could not write ${dir}/run-args."; }
        rc=0; _bounded 300 "$ct" "${TB_MAC_CT_NODE_ARGV[@]}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?  # set-u-safe: as above
      fi
      [[ "$rc" -eq 0 ]] \
        || error "Apple container: the node ${name} did not start. \"${ct}\" logs ${name} says why. It's safe to re-run this installer." ;;
    start) ;;
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
  # Roots a run without a CA leaves behind go once the node runs without them.
  if [[ -n "$casum" ]]; then
    _mac_ct_node_ca_held "$ct" "$name" "$dir"
  else
    rm -f "${dir}/ca/${TB_MAC_CT_NODE_CA_ROOTS}"
  fi
  _mac_ct_node_walled "$ct" "$name"
  # The chart opens the local API only when the node publishes it and the wall lets this
  # Mac to it, as on k3d once its load balancer maps the port (install-client-helm.sh).
  [[ -z "$TRACEBLOC_MAC_CT_LOCAL_API" ]] || TB_LOCAL_API_MAPPED=1
  (umask 077; _bounded 30 "$ct" exec "$name" cat /etc/rancher/k3s/k3s.yaml </dev/null > "${dir}/k3s.yaml.tmp") \
    && [[ -s "${dir}/k3s.yaml.tmp" ]] && mv "${dir}/k3s.yaml.tmp" "${dir}/k3s.yaml" \
    || { rm -f "${dir}/k3s.yaml.tmp"; error "Apple container: could not copy the node's kubeconfig out of ${name}. It's safe to re-run this installer."; }
  log "Apple container: node '${node}' is Ready in ${name}, its API on 127.0.0.1:${TB_MAC_CT_NODE_API_PORT}${TRACEBLOC_MAC_CT_LOCAL_API:+, the local API on 127.0.0.1:${TRACEBLOC_MAC_CT_LOCAL_API%% *}}."
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

TRACEBLOC_MAC_CT_AGENT_HELP_S=30
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
  out="$(TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_AGENT_HELP_S" "$bin" node ensure --help </dev/null 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure --help\` did not finish within ${TRACEBLOC_MAC_CT_AGENT_HELP_S} s, so this run cannot tell whether the CLI knows the command the login item runs. It's safe to re-run this installer."
    return 1
  fi
  [[ "$rc" -eq 0 && "$out" == *"node ensure"* ]] \
    || { echo "Apple container: ${bin} does not know \`tracebloc node ensure\`, the command the login item runs, so it is older than this installer needs. Run \`tracebloc upgrade\`, then re-run this installer."; return 1; }
}

# _mac_ct_agent_trial BIN HOME -- prints nothing and returns 0 when BIN's `node ensure`,
# run once as the login item runs it (HOME the record's home, telemetry off), succeeds
# within TRACEBLOC_MAC_CT_AGENT_TRIAL_S; its output goes to the install log. Otherwise prints
# why and returns 1. Step c calls it just after the node is Ready, so `node ensure` only
# probes; a run past the bound cannot tell, and fails closed.
TRACEBLOC_MAC_CT_AGENT_TRIAL_S=120
_mac_ct_agent_trial() {
  local bin="$1" home="$2" out rc=0 ver="" first _w _rest nl=$'\n'
  out="$(HOME="$home" TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_AGENT_TRIAL_S" "$bin" node ensure </dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure\`, the command the login item runs, did not finish within ${TRACEBLOC_MAC_CT_AGENT_TRIAL_S} s, so this run cannot tell whether the login item would bring the node back. It's safe to re-run this installer."
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

# _mac_ct_agent_log -- the file the login item logs to: in the runtime's log folder, so
# the runtime's removal (apple-container, whose path is the runtime's home) removes it too.
_mac_ct_agent_log() { local logs; logs="$(_mac_ct_log_root)" || return 1; printf '%s/tracebloc-node.log' "$logs"; }

# TB_MAC_CT_AGENT_OLD_LOG -- where the login item logged before it logged into the
# runtime's folder, under its home. Nothing removed it, so a rewrite of the plist removes
# that one file (client-dev#1615).
TB_MAC_CT_AGENT_OLD_LOG="Library/Logs/tracebloc-node.log"

# _mac_ct_agent_plist BIN HOME LOG -- the login item's plist, by setup-macos.sh's writer.
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
  _emit_launch_plist "$TB_MAC_CT_AGENT_LABEL" "$extra" "$3" "$1" node ensure
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
  local bin="$1" why home dir plist agent_log old_log want have="" loaded=0
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" || -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then
    warn "Login item skipped (TRACEBLOC_SKIP_AUTOSTART/TRACEBLOC_NO_AUTOSTART set): after a reboot, or when its VM stops, the node stays down until you run \`tracebloc node ensure\`."
    return 0
  fi
  why="$(_mac_ct_agent_bin_check "$bin")" || error "$why"
  home="$(_mac_ct_agent_home)" || error "$home"
  agent_log="$(_mac_ct_agent_log)" || error "Apple container: cannot tell where the login item logs (above)."
  # A plist string holds these only escaped, and the writer prints values as they are.
  case "${bin}${home}${agent_log}" in
    *[\&\<\>]*) error "Apple container: '${bin}', '${home}' or '${agent_log}' holds &, < or >, which the login item's plist cannot hold as it is." ;;
  esac
  # Run as launchd will, before anything is written or loaded.
  why="$(_mac_ct_agent_trial "$bin" "$home")" || error "$why"
  dir="${TRACEBLOC_LAUNCHAGENTS_DIR:-${home}/Library/LaunchAgents}"
  plist="${dir}/${TB_MAC_CT_AGENT_LABEL}.plist"
  want="$(_mac_ct_agent_plist "$bin" "$home" "$agent_log")"
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
  # launchd fails the job (EX_CONFIG) when its log's folder is missing.
  mkdir -p "$dir" "${agent_log%/*}" || error "Apple container: could not create ${dir} or ${agent_log%/*}."
  printf '%s\n' "$want" > "${plist}.tmp" && mv "${plist}.tmp" "$plist" \
    || { rm -f "${plist}.tmp"; error "Apple container: could not write ${plist}."; }
  # The log an earlier plist named, which nothing else removes: that one file, by its
  # exact path, and nothing beside it.
  old_log="${home}/${TB_MAC_CT_AGENT_OLD_LOG}"
  if [[ -f "$old_log" ]]; then
    rm -f "$old_log" || warn "Apple container: could not remove the login item's old log ${old_log}; remove it yourself."
  fi
  # Recorded before it loads: a run cut off here leaves an artefact delete knows.
  tb_record_write launch-agent "$TB_MAC_CT_AGENT_LABEL" "$plist"
  _bounded 30 launchctl bootstrap "gui/$(id -u)" "$plist" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || error "Apple container: launchd did not load the login item ${plist}, so the node would not come back after a reboot. It's safe to re-run this installer."
  log "Apple container: the login item ${TB_MAC_CT_AGENT_LABEL} is loaded and runs ${bin} node ensure every ${TB_MAC_CT_AGENT_INTERVAL} s."
}

# ── Part 4b: the runner's login item io.tracebloc.runner ────────────────────
#  The Apple-GPU runner (cli-dev#1305, RFC-0185 D2) is the CLI's hidden `tracebloc
#  runner`: a node of this Mac's own cluster that runs GPU jobs as sandboxed processes
#  on the Mac. A second login item keeps it running, beside io.tracebloc.node. It needs
#  the chart's ServiceAccount (apple-gpu-runner-rbac.yaml), so step e sets it up right
#  after the chart, not step c.
#    - DARK until the CLI carries the runner. The CLI step b installed is asked:
#      `tracebloc runner --released` exits 0 only in a release whose runner is switched
#      on. Any other answer, an older CLI's unknown flag included, is "not released":
#      no login item, and the chart's appleGpuRunner stays off. So the CLI's one
#      switch decides both, and an installer newer than its CLI adds nothing.
#    - Its kubeconfig names the API on 127.0.0.1:6443, the one server the runner dials,
#      with the node's CA, and reads the runner's token from a file beside it. The token
#      is a bound ServiceAccount token for TB_MAC_CT_RUNNER_TOKEN_S, issued again by every
#      run, so an upgrade renews it; the runner re-reads the file. Both files are 0600,
#      in a 0700 folder in the node's, so the runtime's removal takes them.
#    - KeepAlive: launchd starts the runner again when it ends, at most once every
#      TB_MAC_CT_RUNNER_THROTTLE_S. LimitLoadToSessionType Aqua and the environment as
#      io.tracebloc.node's.
#    - Not part of a CPU install: a runner that cannot be set up is a warning, and GPU
#      jobs then run on the CPU (D3). It's safe to re-run the installer.
TB_MAC_CT_RUNNER_LABEL="io.tracebloc.runner"
# The chart's ServiceAccount for the runner (tracebloc.appleGpuRunnerAccount).
TB_MAC_CT_RUNNER_ACCOUNT="tracebloc-runner"
TB_MAC_CT_RUNNER_TOKEN_S=31536000
TB_MAC_CT_RUNNER_THROTTLE_S=30
TRACEBLOC_MAC_CT_RUNNER_PROBE_S=30
# This run's answer to "does the CLI carry the runner?", asked once (_mac_ct_runner_on).
# Cleared where the lib is sourced, so a value in the environment decides nothing.
TRACEBLOC_MAC_CT_RUNNER_ON=""

# _mac_ct_runner_released BIN -- 0 when BIN, an absolute path to an executable, answers
# `runner --released` with exit 0 within TRACEBLOC_MAC_CT_RUNNER_PROBE_S; 1 for any other
# answer, a run past the bound included. Its output goes to the install log.
_mac_ct_runner_released() {
  local bin="$1" rc=0
  case "$bin" in /*) ;; *) return 1 ;; esac
  [[ -f "$bin" && -x "$bin" ]] || return 1
  TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_RUNNER_PROBE_S" "$bin" runner --released \
    </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

# _mac_ct_runner_on -- 0 when this run sets up the runner: the macOS node (native k3s on a
# Mac) and a CLI that carries it (TRACEBLOC_CLI_BIN, step b). Asked once a run; the chart's
# value and the login item read the same answer.
_mac_ct_runner_on() {
  if [[ -z "$TRACEBLOC_MAC_CT_RUNNER_ON" ]]; then
    TRACEBLOC_MAC_CT_RUNNER_ON=0
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]] \
      && _mac_ct_runner_released "${TRACEBLOC_CLI_BIN:-}"; then
      TRACEBLOC_MAC_CT_RUNNER_ON=1
    fi
  fi
  [[ "$TRACEBLOC_MAC_CT_RUNNER_ON" == 1 ]]
}

# _mac_ct_runner_off_why -- why _mac_ct_runner_on said no, from the same conditions it read
# (the CLI is not asked again): the substrate, the CLI's path, or the CLI's answer.
_mac_ct_runner_off_why() {
  local bin="${TRACEBLOC_CLI_BIN:-}"
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then
    printf 'it runs only on the macOS node (native k3s), and this Mac runs %s' "${TRACEBLOC_SUBSTRATE_RESOLVED:-no substrate}"
  elif [[ "$bin" != /* || ! -f "$bin" || ! -x "$bin" ]]; then
    printf 'this run has no tracebloc CLI to ask (%s)' "${bin:-none}"
  else
    printf 'the tracebloc CLI at %s did not report it as part of its release' "$bin"
  fi
}

_mac_ct_runner_dir() { local d; d="$(_mac_ct_node_dir)" || return 1; printf '%s/runner' "$d"; }
_mac_ct_runner_log() { local logs; logs="$(_mac_ct_log_root)" || return 1; printf '%s/tracebloc-runner.log' "$logs"; }

# The runner's engine bundle store (RFC-0185 D6, §8 Q16): the folder it keeps the verified
# macOS engine bundles in, HOME/Library/Application Support/tracebloc/engine-bundles, the
# daily user's own at mode 0700. It is the install record's engine-bundles entry, id the
# runner's label. The runner reads the record once, when it starts, and keeps no bundle
# where the record names no such folder of this user's own, so the folder is made and
# recorded before its login item loads. tracebloc delete removes it.
# _mac_ct_runner_bundles_dir HOME -- the folder's path under HOME.
_mac_ct_runner_bundles_dir() { printf '%s/Library/Application Support/tracebloc/engine-bundles' "$1"; }

# _mac_ct_runner_bundles_listed DIR -- 0 when the install record already lists DIR as the
# runner's engine-bundles folder.
_mac_ct_runner_bundles_listed() {
  local rec
  rec="$(tb_record_path)"
  [[ -f "$rec" ]] || return 1
  grep -qF "{\"kind\": \"engine-bundles\", \"id\": $(_tb_json "$TB_MAC_CT_RUNNER_LABEL"), \"path\": $(_tb_json "$1"), " "$rec"
}

# _mac_ct_runner_bundles DIR -- makes DIR, the runner's engine bundle store, 0700. Exit 1,
# printing why, when DIR is there and is not a folder of this user's own (a symbolic link,
# a file, another user's folder: the runner and delete refuse each), or cannot be made.
_mac_ct_runner_bundles() {
  local d="$1" saved_umask
  if [[ -L "$d" ]] || { [[ -e "$d" ]] && ! [[ -d "$d" && -O "$d" ]]; }; then
    echo "${d} is there and is not a folder of your own, so the runner has nowhere to keep the GPU engine"; return 1
  fi
  saved_umask="$(umask)"
  umask 077
  if ! { mkdir -p "$d" && chmod 0700 "$d"; }; then
    umask "$saved_umask"; echo "could not create ${d}"; return 1
  fi
  umask "$saved_umask"
}

# _mac_ct_runner_kubeconfig_yaml CA_DATA TOKEN_FILE NAMESPACE -- the runner's kubeconfig.
_mac_ct_runner_kubeconfig_yaml() {
  printf '%s\n' 'apiVersion: v1' 'kind: Config' 'clusters:' '- name: tracebloc' '  cluster:' \
    '    server: https://127.0.0.1:6443'
  printf '    certificate-authority-data: %s\n' "$1"
  printf '%s\n' 'users:' "- name: ${TB_MAC_CT_RUNNER_ACCOUNT}" '  user:'
  printf '    tokenFile: %s\n' "$2"
  printf '%s\n' 'contexts:' "- name: ${TB_MAC_CT_RUNNER_ACCOUNT}" '  context:' '    cluster: tracebloc' \
    "    user: ${TB_MAC_CT_RUNNER_ACCOUNT}"
  printf '    namespace: %s\n' "$3"
  printf 'current-context: %s\n' "$TB_MAC_CT_RUNNER_ACCOUNT"
}

# _mac_ct_runner_kubeconfig NAMESPACE -- issues the runner's token and writes it and the
# runner's kubeconfig, each 0600 in a 0700 folder; prints the kubeconfig's path. Exit 1,
# printing why, when the node's CA cannot be read, kubectl issues no token, or a file
# cannot be written. The token never reaches the log or the output.
_mac_ct_runner_kubeconfig() {
  local ns="$1" node dir ca tok rc=0 saved_umask
  node="$(_mac_ct_node_dir)" || { echo "cannot tell where the node's files are"; return 1; }
  dir="${node}/runner"
  ca="$(sed -n 's/^ *certificate-authority-data: *//p' "${node}/k3s.yaml" 2>/dev/null)" || ca=""
  ca="${ca%%$'\n'*}"
  [[ "$ca" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "the node's kubeconfig ${node}/k3s.yaml holds no certificate-authority-data"; return 1; }
  tok="$(_bounded 30 kubectl --kubeconfig "$(_native_k3s_kubeconfig_target)" --context "$(_native_k3s_context)" \
    -n "$ns" create token "$TB_MAC_CT_RUNNER_ACCOUNT" --duration="${TB_MAC_CT_RUNNER_TOKEN_S}s" --request-timeout=20s \
    </dev/null 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "kubectl could not issue a token for the ServiceAccount ${ns}/${TB_MAC_CT_RUNNER_ACCOUNT} (exit ${rc})"; return 1; }
  [[ "$tok" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
    || { echo "kubectl's answer for the ServiceAccount ${ns}/${TB_MAC_CT_RUNNER_ACCOUNT} is not one token"; return 1; }
  saved_umask="$(umask)"
  umask 077
  if ! { mkdir -p "$dir" && chmod 0700 "$dir"; }; then
    umask "$saved_umask"; echo "could not create ${dir}"; return 1
  fi
  if ! { printf '%s' "$tok" > "${dir}/token.tmp" && chmod 0600 "${dir}/token.tmp" && mv "${dir}/token.tmp" "${dir}/token"; }; then
    rm -f "${dir}/token.tmp"; umask "$saved_umask"; echo "could not write ${dir}/token"; return 1
  fi
  if ! { _mac_ct_runner_kubeconfig_yaml "$ca" "${dir}/token" "$ns" > "${dir}/kubeconfig.tmp" \
         && chmod 0600 "${dir}/kubeconfig.tmp" && mv "${dir}/kubeconfig.tmp" "${dir}/kubeconfig"; }; then
    rm -f "${dir}/kubeconfig.tmp"; umask "$saved_umask"; echo "could not write ${dir}/kubeconfig"; return 1
  fi
  umask "$saved_umask"
  printf '%s/kubeconfig' "$dir"
}

# _mac_ct_runner_plist BIN HOME LOG KUBECONFIG NAMESPACE -- the runner's login item, by
# setup-macos.sh's writer.
_mac_ct_runner_plist() {
  local extra
  extra="  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${TB_MAC_CT_RUNNER_THROTTLE_S}</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Standard</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${2}</string>
    <key>TRACEBLOC_SKIP_TELEMETRY</key><string>1</string>
  </dict>"
  _emit_launch_plist "$TB_MAC_CT_RUNNER_LABEL" "$extra" "$3" "$1" runner --kubeconfig "$4" --namespace "$5"
}

# _mac_ct_runner_loaded -- 0 when this user's GUI domain has the runner's login item, 1
# when it does not (launchctl's 113), 2 when launchctl cannot say.
_mac_ct_runner_loaded() {
  local rc=0
  _bounded 30 launchctl print "gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    113) return 1 ;;
    *) return 2 ;;
  esac
}

# _mac_ct_ensure_runner -- the runner's login item, when this run sets up the runner
# (_mac_ct_runner_on): its kubeconfig and token written, its engine bundle store made, its
# plist written, recorded as a launch-agent and loaded into this login session. A loaded
# item whose plist is already these bytes is left loaded, unless the record did not list
# the bundle store before this run: the runner read the record when it started, so it is
# unloaded, the store recorded, and the item loaded again to read it. Its token is issued again either way. Anything
# that stops it is a warning, never the install's failure: GPU jobs then run on the CPU.
_mac_ct_ensure_runner() {
  local ns="${TB_NAMESPACE:-}" bin="${TRACEBLOC_CLI_BIN:-}" home dir plist runner_log kcfg want have="" loaded=0 why
  local bundles listed=0 bad
  local cpu="GPU jobs run on the CPU. It's safe to re-run this installer."
  if ! _mac_ct_runner_on; then
    [[ "${OS:-}" != "Darwin" ]] || log "The Apple-GPU runner: $(_mac_ct_runner_off_why), so no runner login item."
    return 0
  fi
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" || -n "${TRACEBLOC_NO_AUTOSTART:-}" ]]; then
    warn "The Apple-GPU runner's login item skipped (TRACEBLOC_SKIP_AUTOSTART/TRACEBLOC_NO_AUTOSTART set): ${cpu}"
    return 0
  fi
  [[ -n "$ns" ]] || { warn "The Apple-GPU runner: this run has no namespace for it. ${cpu}"; return 0; }
  home="$(_mac_ct_agent_home)" || { warn "The Apple-GPU runner: ${home} ${cpu}"; return 0; }
  runner_log="$(_mac_ct_runner_log)" || { warn "The Apple-GPU runner: cannot tell where its login item logs. ${cpu}"; return 0; }
  kcfg="$(_mac_ct_runner_kubeconfig "$ns")" || { warn "The Apple-GPU runner: ${kcfg}. ${cpu}"; return 0; }
  # A plist string holds these only escaped, and the writer prints values as they are.
  case "${bin}${home}${runner_log}${kcfg}${ns}" in
    *[\&\<\>]*) warn "The Apple-GPU runner: '${bin}', '${home}', '${runner_log}' or '${kcfg}' holds &, < or >, which its login item's plist cannot hold as it is. ${cpu}"; return 0 ;;
  esac
  bundles="$(_mac_ct_runner_bundles_dir "$home")"
  if _mac_ct_runner_bundles_listed "$bundles"; then listed=1; fi
  bad="$(_mac_ct_runner_bundles "$bundles")" || { warn "The Apple-GPU runner: ${bad}. ${cpu}"; return 0; }
  dir="${TRACEBLOC_LAUNCHAGENTS_DIR:-${home}/Library/LaunchAgents}"
  plist="${dir}/${TB_MAC_CT_RUNNER_LABEL}.plist"
  want="$(_mac_ct_runner_plist "$bin" "$home" "$runner_log" "$kcfg" "$ns")"
  if [[ -e "$plist" ]]; then
    have="$(cat "$plist")" || { warn "The Apple-GPU runner: ${plist} cannot be read, so this run cannot tell what its login item runs. ${cpu}"; return 0; }
  fi
  _mac_ct_runner_loaded || loaded=$?
  if [[ "$loaded" -eq 2 ]]; then
    warn "The Apple-GPU runner: launchctl could not say whether ${TB_MAC_CT_RUNNER_LABEL} is loaded, so this run leaves it as it is. ${cpu}"
    return 0
  fi
  if [[ "$loaded" -eq 0 && "$have" == "$want" && "$listed" -eq 1 ]]; then
    tb_record_write launch-agent "$TB_MAC_CT_RUNNER_LABEL" "$plist"
    log "The Apple-GPU runner: its login item ${TB_MAC_CT_RUNNER_LABEL} is loaded; its token was issued again."
    return 0
  fi
  if [[ "$loaded" -eq 0 ]] && ! _bounded 30 launchctl bootout "gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; then
    warn "The Apple-GPU runner: could not unload ${TB_MAC_CT_RUNNER_LABEL} to rewrite it. Run launchctl bootout gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}, then re-run. Until then ${cpu}"
    return 0
  fi
  # Recorded once the old item is gone and before the new one loads: the runner reads the
  # record when it starts, and a run that stopped above must not leave it listed.
  tb_record_write engine-bundles "$TB_MAC_CT_RUNNER_LABEL" "$bundles"
  # launchd fails the job (EX_CONFIG) when its log's folder is missing.
  if ! mkdir -p "$dir" "${runner_log%/*}"; then
    warn "The Apple-GPU runner: could not create ${dir} or ${runner_log%/*}. ${cpu}"; return 0
  fi
  if ! { printf '%s\n' "$want" > "${plist}.tmp" && mv "${plist}.tmp" "$plist"; }; then
    rm -f "${plist}.tmp"; warn "The Apple-GPU runner: could not write ${plist}. ${cpu}"; return 0
  fi
  # Recorded before it loads: a run cut off here leaves an artefact delete knows.
  tb_record_write launch-agent "$TB_MAC_CT_RUNNER_LABEL" "$plist"
  why=0
  _bounded 30 launchctl bootstrap "gui/$(id -u)" "$plist" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || why=$?
  if [[ "$why" -ne 0 ]]; then
    warn "The Apple-GPU runner: launchd did not load ${plist} (exit ${why}). ${cpu}"; return 0
  fi
  log "The Apple-GPU runner: its login item ${TB_MAC_CT_RUNNER_LABEL} is loaded and runs ${bin} runner."
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
# The login item runs the CLI step b installed (TRACEBLOC_CLI_BIN, install-cli.sh). Without it
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
  [[ -n "${TRACEBLOC_CLI_BIN:-}" ]] \
    || error "The macOS node's login item runs the tracebloc CLI, and step b did not install it (above). Without the login item the node would not come back after a restart. Install the tracebloc CLI, then re-run this installer."
  _mac_ct_ensure_node
  _mac_ct_merge_kubeconfig
  # NO_PROXY before the gate (client-dev#1892), for the kubectl calls after it: the gate's
  # own probe of 127.0.0.1:6443 bypasses every proxy itself (client-dev#1914).
  _export_host_no_proxy
  _mac_ct_local_network_gate
  _mac_ct_ensure_agent "$TRACEBLOC_CLI_BIN"
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
#  The same helper forwards the local API's 127.0.0.1 port (TRACEBLOC_MAC_CT_LOCAL_API,
#  client-dev#2379), under the same grant: it is kept per bundle id, not per port. So
#  the wait reads the API's port alone; nothing answers on the local API's until the
#  chart has installed jobs-manager.

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
  info "macOS may now ask whether \"${TB_MAC_CT_LAN_HELPER}\" can find devices on your local network. It is part of Apple's container runtime: it makes the cluster's API reachable from this Mac only, on 127.0.0.1:${TB_MAC_CT_NODE_API_PORT}${TRACEBLOC_MAC_CT_LOCAL_API:+, and the local API the dashboard asks, on 127.0.0.1:${TRACEBLOC_MAC_CT_LOCAL_API%% *}}. Click Allow. This waits up to $(( TB_MAC_CT_LAN_WAIT_S / 60 )) minutes for your answer."
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
