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
#  Part 1 puts the runtime on disk, and part 2 (below) starts it. Nothing calls either
#  yet: part 6 makes the path reachable behind TRACEBLOC_SUBSTRATE=k3s on a Mac.
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
# root is ours and its install root ROOT is one of this installer's version folders),
# or "foreign". launchctl exits 113 for a service it does not know; any other failure
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
  have_app="$(awk -F' => ' '$1 ~ /^[[:space:]]*CONTAINER_APP_ROOT$/ { print $2; exit }' <<<"$out")"
  have_root="$(awk -F' => ' '$1 ~ /^[[:space:]]*CONTAINER_INSTALL_ROOT$/ { print $2; exit }' <<<"$out")"
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
