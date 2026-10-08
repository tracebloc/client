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
#  Part 1 is the runtime on disk, and nothing calls it yet: part 2 starts it, and
#  part 6 makes the path reachable behind TRACEBLOC_SUBSTRATE=k3s on a Mac.
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

# _mac_ct_home -- the runtime's folder (D6). TRACEBLOC_MAC_CT_HOME is the TEST SEAM. A HOME
# that is empty, relative or / would put the runtime in a system folder, so it is refused.
_mac_ct_home() {
  if [[ -n "${TRACEBLOC_MAC_CT_HOME:-}" ]]; then printf '%s' "$TRACEBLOC_MAC_CT_HOME"; return 0; fi
  if [[ "${HOME:-}" != /?* ]]; then
    echo "Apple container: HOME is '${HOME:-}', not a home folder, so there is nowhere to unpack the runtime." >&2
    return 1
  fi
  printf '%s/Library/Application Support/tracebloc/container' "$HOME"
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
# check 3 again; anything else at that place is refused and left alone.
_mac_ct_ensure_runtime() {
  local dest why tmp pkg
  dest="$(_mac_ct_install_root)" || error "Apple container: cannot tell where to unpack the runtime (above)."
  if [[ -e "$dest" ]]; then
    if why="$(_mac_ct_check_marker "$dest")" && why="$(_mac_ct_check_binaries "$dest")"; then
      log "Apple container ${TB_APPLE_CONTAINER_VERSION}: reusing the checked runtime in ${dest}."
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
  log "Apple container ${TB_APPLE_CONTAINER_VERSION}: unpacked and checked in ${dest}."
}
