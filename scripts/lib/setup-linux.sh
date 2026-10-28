#!/usr/bin/env bash
# =============================================================================
#  setup-linux.sh — Linux prerequisites: package manager, system deps,
#                   kubectl, helm, GPU dispatch, step b's dispatch and
#                   prepare-host's
# =============================================================================

# ── Tool-install target defaults ─────────────────────────────────────────────
# WHERE the tools below install, and whether that needs sudo. Default to the
# system location; _set_tools_target() overrides at runtime (Tier 0 flips these
# to a no-sudo ~/.local/bin). Defaulted here so any caller that reaches the
# install_* functions WITHOUT going through _set_tools_target — the bats suite,
# e2e harnesses — still gets the system behaviour, not an empty TRACEBLOC_TOOLS_DIR
# (kubectl → "/kubectl") or a spurious no-sudo branch (Bugbot #1175 r2).
: "${TRACEBLOC_TOOLS_DIR:=/usr/local/bin}"
: "${TRACEBLOC_TOOLS_SUDO:=sudo}"

# ── Package manager detection ────────────────────────────────────────────────
setup_pm() {
  # apt note: Ubuntu 22.04+ ships needrestart, which hooks `apt-get install` and
  # opens an interactive "restart services?" prompt that `-y` does NOT suppress.
  # Run inside spin_cmd (stdout/stderr redirected, process backgrounded) that
  # prompt is invisible and blocks reading the TTY → SIGTTIN → the install hangs
  # forever (the symptom was a spinner stuck on "still pulling conntrack" — a
  # package the installer no longer installs; the hang class is what matters).
  # DEBIAN_FRONTEND=noninteractive + NEEDRESTART_MODE=a make apt fully
  # non-interactive; they are passed *through*
  # `tb_root env` because sudo resets the environment by default.
  #
  # apt also waits *indefinitely* on the dpkg lock while apt-daily / unattended-
  # upgrades hold it on a freshly-booted host (#210); -o DPkg::Lock::Timeout
  # bounds that wait so the install fails with a clear error rather than hanging
  # silently behind the spinner. The waits (240 s update, 540 s install) sit just
  # under the spin_cmd_bounded deadlines (300 s / 600 s) the callers wrap them in
  # (client-dev#2048): a held lock then ends as apt's own lock error, handled as
  # a failed install, and never as the deadline's "mirror stalled".
  if   has apt-get; then PM_UPDATE="tb_root apt-get update -qq -o DPkg::Lock::Timeout=240"; PM_INSTALL="tb_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q -o DPkg::Lock::Timeout=540 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  elif has dnf;     then PM_UPDATE="tb_root dnf makecache -q";             PM_INSTALL="tb_root dnf install -y -q"
  elif has yum;     then PM_UPDATE="tb_root yum makecache -q";             PM_INSTALL="tb_root yum install -y -q"
  elif has zypper;  then PM_UPDATE="tb_root zypper refresh";               PM_INSTALL="tb_root zypper install -y"
  elif has pacman;  then PM_UPDATE="tb_root pacman -Sy --noconfirm";       PM_INSTALL="tb_root pacman -S --noconfirm"
  else error "No supported package manager found."; fi
}

# ── Wait out apt/dpkg lock holders before our apt calls ──────────────────────
# On a freshly-installed/booted Debian/Ubuntu host, the apt-daily and
# unattended-upgrades systemd units grab the dpkg lock at boot and can hold it
# for several minutes (longer when a kernel/security batch is pending). apt-get
# then blocks on the lock, and because we run it behind spin_cmd the
# "Waiting for cache lock…" line is hidden in the log — the installer looks
# frozen (#210). Surface the wait with a visible spinner and bound it; the
# per-command DPkg::Lock::Timeout (setup_pm) is the backstop if a holder appears
# mid-run. No-op when apt or fuser is absent, or when the lock is already free.
apt_wait_for_lock() {
  has apt-get && has fuser || return 0
  local locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock"
  tb_root fuser $locks >/dev/null 2>&1 || return 0   # free already → silent fast path
  spin_cmd "Waiting for background system updates to finish…" bash -c '
    waited=0
    while tb_root fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
      [ "$waited" -ge 600 ] && exit 0
      sleep 5; waited=$((waited + 5))
    done' || true
}

# ── Bounded package-manager calls (client-dev#2048) ──────────────────────────
# A package mirror that accepts the connection and then stops sending hangs
# apt/dnf/zypper with no timeout of their own, and behind spin_cmd that was a
# spinner with no message until something else killed the install. A healthy index
# refresh takes seconds to a minute or two and a package a few minutes, so 5 and
# 10 minutes are a stalled mirror, not a slow link. spin_cmd_bounded returns 124
# ONLY on the deadline, so a fast real failure keeps its own handling.
#
# _pm_update_bounded — refresh the package index, best-effort: a stale index
# usually still installs from cache, and a package that genuinely can't be found
# surfaces on the install that follows. Never fails.
_pm_update_bounded() {
  local _rc=0
  # shellcheck disable=SC2086  # PM_UPDATE is a command line that must word-split
  spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 300 "Updating package index…" $PM_UPDATE || _rc=$?
  if (( _rc == 124 )); then
    _pm_survivor_stop "the package index refresh"
    warn "The package index refresh did not finish within 5 minutes — the package mirror stalled. Continuing; installs will use the cached index."
  elif (( _rc != 0 )); then
    warn "Package index refresh failed — continuing; installs will use the cached index."
  fi
  return 0
}

# _pm_survivor_stop <what> — after a deadline kill (rc 124), stop when the package
# manager is STILL running: it holds the package lock, so every later install would
# queue behind it with no word of why. Returns 0 when nothing survived, so a plain
# stall keeps its own best-effort handling.
_pm_survivor_stop() {
  [[ -n "${_TB_SPIN_SURVIVORS:-}" ]] || return 0
  local _rerun="the installer"
  [[ -n "${TB_PREPARE_HOST_RUN:-}" ]] && _rerun="prepare-host"
  error "$1 did not finish within its deadline, and the package manager is still running and holding the package lock. Wait for it to finish, check your network/proxy, then re-run ${_rerun}."
}

# _pm_install_stalled <what> — the fatal message for an install the deadline
# killed, with the re-run that resumes it: prepare-host under run_prepare_host
# (TB_PREPARE_HOST_RUN, which install_system_deps and the native-k3s prereqs run
# under), the installer otherwise.
_pm_install_stalled() {
  local _rerun="the installer"
  [[ -n "${TB_PREPARE_HOST_RUN:-}" ]] && _rerun="prepare-host"
  _pm_survivor_stop "Installing $1"
  error "Installing $1 did not finish within 10 minutes — the package mirror stalled. Check your network/proxy and re-run ${_rerun}; it resumes safely."
}

# ── System dependencies ─────────────────────────────────────────────────────
install_system_deps() {
  # conntrack is deliberately NOT here (removed 2026-09-09): nothing on the host
  # invokes it. If a host-side need ever appears, cite the caller here rather
  # than re-adding it on faith.
  MISSING_PKGS=()
  has curl      || MISSING_PKGS+=(curl)
  # Helm's release tarball is unpacked with tar + gzip; minimal cloud images
  # (Amazon Linux 2023, minimal RHEL) ship neither. openssl is NOT needed any
  # more — the Helm download is verified with sha256sum since get-helm-3 was
  # replaced by a direct fetch (#395; see _fetch_helm_release). Package names
  # are uniform across apt/dnf/yum/zypper/pacman.
  has tar       || MISSING_PKGS+=(tar)
  has gzip      || MISSING_PKGS+=(gzip)
  if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    # Guard the index refresh: under set -e an unguarded failure here aborts the
    # whole install, yet the per-package installs below are already guarded
    # (|| log) — so a flaky mirror refresh was MORE fatal than a failed install,
    # which is backwards. A stale index usually still installs from cache; if a
    # package genuinely can't be found, the guarded install below surfaces it.
    # Both bounded (client-dev#2048): see _pm_update_bounded / _pm_install_stalled.
    _pm_update_bounded
    local _pkg_rc
    for pkg in "${MISSING_PKGS[@]}"; do  # set-u-safe: inside the non-empty check
      # ${pkg}, braced: bash 3.2 in a UTF-8 locale reads the first byte of "…"
      # into an unbraced name and, under set -u, aborts "pkg\xE2: unbound variable".
      _pkg_rc=0
      # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
      spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 600 "Installing ${pkg}…" $PM_INSTALL "$pkg" || _pkg_rc=$?
      if (( _pkg_rc == 124 )); then
        _pm_install_stalled "${pkg}"
      elif (( _pkg_rc != 0 )); then
        log "Could not install $pkg — may already be satisfied by an alternative package."
      fi
    done
    log "Dependencies installed: ${MISSING_PKGS[*]}"  # set-u-safe: inside the non-empty check
  fi
  success "System dependencies"
}

# ── kubectl ──────────────────────────────────────────────────────────────────
# _set_tools_target — decide WHERE kubectl/helm install and whether that needs
# sudo, by the tier (RFC 0001 #1175). Tier 0 runs with no administrator rights
# (the macOS node, _mac_ct_install_macos, and a user adopting the k3s prepare-host
# set up for them, k3s.sh), so its tools MUST NOT sudo: a password prompt hidden
# under spin_cmd would hang the step. They go into ~/.local/bin (user-owned), put
# on this process's PATH. Otherwise the system location, with sudo. Sets
# TRACEBLOC_TOOLS_DIR + TRACEBLOC_TOOLS_SUDO.
_set_tools_target() {
  if [ "${INSTALL_TIER:-}" = "0" ]; then
    TRACEBLOC_TOOLS_DIR="${HOME}/.local/bin"
    TRACEBLOC_TOOLS_SUDO=""
    mkdir -p "$TRACEBLOC_TOOLS_DIR"
    case ":$PATH:" in *":$TRACEBLOC_TOOLS_DIR:"*) ;; *) export PATH="$TRACEBLOC_TOOLS_DIR:$PATH" ;; esac
  else
    TRACEBLOC_TOOLS_DIR="/usr/local/bin"
    TRACEBLOC_TOOLS_SUDO="sudo"
  fi
}

_fetch_kubectl() {
  local ver="$1" arch="$2"
  # Download platform slug: defaults to linux, so Linux (and every bats fetch test
  # that leaves OS_DL unset) is byte-identical; the macOS path sets OS_DL=darwin so
  # the SAME pinned/verified fetch honors the pins there too (#429).
  local os="${OS_DL:-linux}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  # A stall floor, not a hard --max-time: kubectl is a ~50 MB binary, and a hard
  # cap would fail a slow-but-healthy link. These flags are also how curl_secure
  # knows not to add its default deadline here (Bugbot, backend#1252).
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "https://dl.k8s.io/release/${ver}/bin/${os}/${arch}/kubectl" -o "${tmpdir}/kubectl"
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "https://dl.k8s.io/release/${ver}/bin/${os}/${arch}/kubectl.sha256" -o "${tmpdir}/kubectl.sha256"
  # Catch a truncated/blocked transfer as a TRANSFER failure before the checksum
  # misreports it as tampering (#607). kubectl is ~50 MB; 20 MB is a safe floor.
  _assert_download_size "${tmpdir}/kubectl" 20000000 "kubectl" "$tmpdir"
  _verify_sha256 "$(cat "${tmpdir}/kubectl.sha256")" "${tmpdir}/kubectl" \
    || { rm -rf "$tmpdir"; error "System tool checksum verification failed"; }
  chmod +x "${tmpdir}/kubectl"
  # Tier 0 → no sudo (TRACEBLOC_TOOLS_SUDO empty, TRACEBLOC_TOOLS_DIR under $HOME).
  if [ -n "$TRACEBLOC_TOOLS_SUDO" ]; then
    sudo mv "${tmpdir}/kubectl" "$TRACEBLOC_TOOLS_DIR/kubectl"
  else
    mv "${tmpdir}/kubectl" "$TRACEBLOC_TOOLS_DIR/kubectl"
  fi
  rm -rf "$tmpdir"
}

# install_kubectl [VERSION] -- with no VERSION, a kubectl already on PATH is kept and a
# missing one is fetched at dl.k8s.io's stable release. With VERSION (the macOS node's
# pinned kubectl, _mac_ct_install_macos), the copy in TRACEBLOC_TOOLS_DIR is kept only
# when it is that release, and fetched at VERSION otherwise; another kubectl elsewhere on
# PATH is left alone, and TRACEBLOC_TOOLS_DIR comes first on this process's PATH.
install_kubectl() {
  local pin="${1:-}" have=""
  if [[ -n "$pin" ]]; then
    if [[ -x "$TRACEBLOC_TOOLS_DIR/kubectl" ]]; then
      have="$(_bounded 30 "$TRACEBLOC_TOOLS_DIR/kubectl" version --client 2>/dev/null </dev/null | sed -n 's/^Client Version: //p')" || have=""
    fi
    if [[ "$have" != "$pin" ]]; then
      KUBE_VER="$pin"
      spin_cmd "Installing system tools…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
      log "kubectl $KUBE_VER installed."
      tb_record_write binary kubectl "$TRACEBLOC_TOOLS_DIR/kubectl"
    fi
  elif ! has kubectl; then
    # tail -1 + tr: retry's attempt notices go to STDOUT and, on a failed-then-
    # successful fetch, concatenate into the capture — polluting the version and
    # breaking the download URL. The endpoint body (the version) is the last line
    # either way; on total failure the last line is retry's notice, which the tag
    # regex below rejects → the honest error. Mirrors the Helm resolver in
    # install_helm (Bugbot r3655543170).
    KUBE_VER="$(retry 3 5 curl_secure -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null | tail -1 | tr -d '[:space:]')"
    [[ "$KUBE_VER" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
      || error "Couldn't resolve the kubectl version from dl.k8s.io/release/stable.txt — check network connectivity to dl.k8s.io and re-run."
    spin_cmd "Installing system tools…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
    log "kubectl $KUBE_VER installed."
    tb_record_write binary kubectl "$TRACEBLOC_TOOLS_DIR/kubectl"
  fi
  # Gate on both paths (fresh + already-present). --rm removes our TRACEBLOC_TOOLS_DIR copy
  # only if IT is the binary that failed (assert_tool_runs' -ef guard), so a broken
  # installer-placed kubectl self-heals on re-run while a pkg copy elsewhere is safe.
  assert_tool_runs --rm "$TRACEBLOC_TOOLS_DIR/kubectl" kubectl version --client
}

# ── Helm ─────────────────────────────────────────────────────────────────────
# _ensure_unpack_tools — Helm's release ships as a .tar.gz, so unpacking needs
# tar + gzip. The full flow guarantees them via install_system_deps, but the
# Tier 0 fast path skips that step — and minimal cloud images (Amazon Linux
# 2023, minimal RHEL) genuinely ship without them, so the Helm install would
# die mid-flight (Bugbot #383). Product call (#395): the installer takes care
# of its own requirements — install what's missing via the package manager
# instead of telling the user to go install tools. Root / passwordless sudo
# installs quietly; otherwise we say exactly why we're asking for a password
# this once (and only error as a last resort, when we truly can't get rights).
_ensure_unpack_tools() {
  local missing=() _unpack_keepalive=""
  has tar  || missing+=(tar)
  has gzip || missing+=(gzip)
  [ ${#missing[@]} -eq 0 ] && return 0
  setup_pm    # variable setup only (PM_UPDATE/PM_INSTALL); errors on unknown PM
  # PM_INSTALL leads with `tb_root` — the common.sh executor (A2): as root it
  # runs the command directly (fine with no sudo binary at all), so nothing to
  # strip here. The OPTION-led probes below must BYPASS the shadow via
  # _have_sudo_bin/_real_sudo — as root the shadow would execute "-n true" as a
  # command — mirroring preflight_sudo/_probe_privilege (Bugbot #372).
  if [ "${EUID:-1000}" -ne 0 ] && ! _real_sudo -n true 2>/dev/null; then
    _have_sudo_bin || error "Couldn't install ${missing[*]} (needed to unpack Helm): you aren't root and this machine has no sudo. Ask an administrator to install ${missing[*]}, then re-run this installer."  # set-u-safe: the empty-missing check above returns first
    # A password IS needed — prompt on a plain line (a spinner would garble the
    # sudo prompt), with the honest reason, before the spin_cmd installs below.
    info "Your machine is missing ${missing[*]} (needed once, to unpack Helm) — administrator password required to install ${missing[*]}."  # set-u-safe: the empty-missing check above returns first
    _real_sudo -v || error "Couldn't get administrator rights to install ${missing[*]}. Ask an administrator to install ${missing[*]}, then re-run this installer."  # set-u-safe: the empty-missing check above returns first
    # Tier 0 skips preflight_sudo, so keep the just-primed ticket warm ourselves:
    # the dpkg-lock wait below can outlast sudo's timestamp, and an expired
    # ticket re-prompts invisibly behind the spinner (Bugbot r2). Same pattern
    # as preflight_sudo; install_cleanup kills the pid on ANY exit, and we kill
    # it right after the installs — the zero-privilege tier shouldn't hold a
    # warm admin ticket a second longer than needed.
    ( while _real_sudo -n true 2>/dev/null; do sleep 50; done ) &
    _unpack_keepalive=$!
    # Register OUR pid for install_cleanup only when no preflight keepalive
    # owns the global — on the Tier 1/2 recovery path SUDO_KEEPALIVE_PID is
    # preflight_sudo's, and clobbering (or later killing) it would let the
    # remaining privileged steps re-prompt behind a spinner (Bugbot r3).
    if [ -z "${SUDO_KEEPALIVE_PID:-}" ]; then
      SUDO_KEEPALIVE_PID=$_unpack_keepalive
    fi
  fi
  # Tier 0 also skips the full flow's apt_wait_for_lock — on a freshly-booted
  # Debian/Ubuntu host apt-daily can hold the dpkg lock for minutes, and apt
  # would sit on it invisibly behind the spinner (Bugbot r2). Bounded + visible;
  # no-op off apt distros. Runs after the priming above so its own sudo calls
  # never prompt mid-spinner.
  apt_wait_for_lock
  # Mirror install_system_deps: refresh the index best-effort (a brand-new
  # minimal image has no package lists at all), gate on the install itself.
  _pm_update_bounded
  # ONE combined install (not per-package): a single sudo consumer right after
  # the priming, minimizing the window in which the ticket could lapse. Bounded
  # like the refresh (client-dev#2048).
  local _unpack_rc=0
  # shellcheck disable=SC2086  # PM_INSTALL is a command line that must word-split
  spin_cmd_bounded --grace "${TB_PM_KILL_GRACE:-60}" 600 "Installing ${missing[*]}…" $PM_INSTALL "${missing[@]}" || _unpack_rc=$?  # set-u-safe: the empty-missing check above returns first
  if (( _unpack_rc == 124 )); then
    _pm_install_stalled "${missing[*]}"  # set-u-safe: the empty-missing check above returns first
  elif (( _unpack_rc != 0 )); then
    error "Couldn't install ${missing[*]} (needed to unpack Helm). Install with your package manager, then re-run this installer."  # set-u-safe: the empty-missing check above returns first
  fi
  # Kill only the keepalive WE started — never a preflight_sudo one that the
  # rest of the full flow still relies on (Bugbot r3).
  if [ -n "$_unpack_keepalive" ]; then
    kill "$_unpack_keepalive" 2>/dev/null || true
    if [ "${SUDO_KEEPALIVE_PID:-}" = "$_unpack_keepalive" ]; then
      SUDO_KEEPALIVE_PID=""
    fi
  fi
  log "Dependencies installed: ${missing[*]}"  # set-u-safe: the empty-missing check above returns first
}

# _fetch_helm_release <tag> <arch> — download the Helm tarball for <tag> plus
# its published .sha256sum from get.helm.sh, verify (FAIL-CLOSED), unpack, and
# move the binary into TRACEBLOC_TOOLS_DIR. Runs under spin_cmd — no output of its own.
# Direct download replaces helm's get-helm-3: that script floats on the MUTABLE
# helm/helm@main (unpinned code executed on the host), needs openssl for its
# checksum step (absent on minimal images — Bugbot #383), and its own fetches
# are unbounded. sha256sum (coreutils) is present everywhere we run, get.helm.sh
# is Helm's official release CDN, and the pin keeps installs deterministic
# (#382).
_fetch_helm_release() {
  local tag="$1" arch="$2" tarball tmpdir
  local os="${OS_DL:-linux}"   # linux by default; darwin on the macOS path (#429)
  tarball="helm-${tag}-${os}-${arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  # --connect-timeout + a stall floor (not --max-time: the tarball is ~17 MB and
  # a hard cap would break slow-but-healthy links) — a hung transfer under
  # spin_cmd would otherwise spin forever.
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "https://get.helm.sh/${tarball}" -o "${tmpdir}/${tarball}"
  retry 3 5 curl_secure -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "https://get.helm.sh/${tarball}.sha256sum" -o "${tmpdir}/${tarball}.sha256sum"
  # The published file is "<sha256>  <tarball-name>" — pull the hash and verify the
  # tarball with the portable checker (sha256sum on Linux, shasum on macOS; #429).
  local want
  want="$(awk 'NR==1{print $1}' "${tmpdir}/${tarball}.sha256sum" 2>/dev/null)"
  # Transfer-vs-checksum distinction (#607): the Helm tarball is ~17 MB; 5 MB floor
  # catches a truncated/blocked download before the checksum misreports tampering.
  _assert_download_size "${tmpdir}/${tarball}" 5000000 "Helm" "$tmpdir"
  if [ -z "$want" ] || ! _verify_sha256 "$want" "${tmpdir}/${tarball}"; then
    rm -rf "$tmpdir"
    error "System tool checksum verification failed"
  fi
  tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir" "${os}-${arch}/helm"
  chmod +x "${tmpdir}/${os}-${arch}/helm"
  # Tier 0 → no sudo (TRACEBLOC_TOOLS_SUDO empty, TRACEBLOC_TOOLS_DIR under $HOME).
  if [ -n "$TRACEBLOC_TOOLS_SUDO" ]; then
    sudo mv "${tmpdir}/${os}-${arch}/helm" "$TRACEBLOC_TOOLS_DIR/helm"
  else
    mv "${tmpdir}/${os}-${arch}/helm" "$TRACEBLOC_TOOLS_DIR/helm"
  fi
  rm -rf "$tmpdir"
}

_ensure_helm_executable() {
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -n "$helm_bin" && -f "$helm_bin" && ! -x "$helm_bin" ]]; then
    log "Making Helm executable (fixing permissions)..."
    # Tier 0 (no admin): helm is in the user's ~/.local/bin — a plain owner chmod
    # works and MUST NOT sudo (would prompt on the tty after the zero-privilege
    # promise, like the systemctl guard). Full flow: /usr/local/bin needs sudo.
    # TRACEBLOC_TOOLS_SUDO is set by _set_tools_target (empty on Tier 0), defaulted to
    # "sudo" at module scope for direct callers (Bugbot #1175 r3).
    if [[ -n "${TRACEBLOC_TOOLS_SUDO:-}" ]]; then
      sudo chmod 755 "$helm_bin" 2>/dev/null || true
    else
      chmod 755 "$helm_bin" 2>/dev/null || true
    fi
  fi
}

install_helm() {
  if ! has helm; then
    # Pin the Helm release (HELM_VERSION, common.sh) and fetch the tarball
    # DIRECTLY from get.helm.sh, verified against its published .sha256sum —
    # get-helm-3 is gone (see _fetch_helm_release). HELM_VERSION=latest resolves
    # the newest release at install time via get.helm.sh/helm-latest-version and
    # takes the same verified path; an empty value means the common.sh pin. The
    # tag lands in a URL path, so anything that isn't a plain release tag fails
    # closed.
    local _helm_tag="${HELM_VERSION:-}"
    [[ "$_helm_tag" == "latest" ]] && _helm_tag=""
    [[ -z "$_helm_tag" || "$_helm_tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
      || error "HELM_VERSION must be a Helm release tag like v4.2.3, or 'latest' (got '${HELM_VERSION:-}')"

    # Unpack needs tar + gzip — make sure of them BEFORE spending the download,
    # installing them ourselves when missing (#395; Tier 0 skips system deps).
    _ensure_unpack_tools

    if [ -z "$_helm_tag" ]; then
      # tail -1: retry's attempt notices go to STDOUT and would concatenate into
      # the capture on a failed-then-successful fetch; the endpoint's body is
      # the last line either way (Bugbot r3). On total failure the last line is
      # retry's notice, which the tag regex below rejects → the honest error.
      _helm_tag="$(retry 3 5 curl_secure -fsSL --connect-timeout 15 --max-time 30 \
        "https://get.helm.sh/helm-latest-version" 2>/dev/null | tail -1 | tr -d '[:space:]')" || _helm_tag=""
      [[ "$_helm_tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
        || error "Couldn't resolve the latest Helm release tag — set HELM_VERSION to a release tag (e.g. v4.2.3) and re-run."
    fi

    spin_cmd "Installing system tools…" _fetch_helm_release "$_helm_tag" "$ARCH_DL" \
      || error "System tool installation failed. See the install log for details."

    if ! has helm; then
      error "System tool installation completed but not found on PATH."
    fi
    tb_record_write binary helm "$TRACEBLOC_TOOLS_DIR/helm"
  fi
  _ensure_helm_executable
  # bare `helm version` (not --short: it may be dropped like kubectl's was). --rm
  # removes our TRACEBLOC_TOOLS_DIR copy only if IT is the binary that failed (-ef guard),
  # never a pre-existing / pkg-managed helm elsewhere on PATH (#411 review).
  assert_tool_runs --rm "$TRACEBLOC_TOOLS_DIR/helm" helm version
}

# ── GPU setup dispatch ───────────────────────────────────────────────────────
# Step b's GPU setup on native k3s (k3s.sh _native_k3s_install_linux). When the GPU
# floor skips the GPU (detect_gpu judged it, and printed the remedy) there is no driver
# install, no toolkit and no wiring: TRACEBLOC_GPU_WIRED stays 0. A driver below the
# floor only warned, and is set up like any other. A driver install that put no driver
# in (install_nvidia_drivers returns 1, client-dev#1699) is CPU mode the same way:
# nothing past it runs. Otherwise the toolkit package and a CDI spec follow (k3s.sh
# _native_k3s_gpu_prepare, slim client 1.1i), and nothing touches a container
# runtime: k3s finds the toolkit when it first starts in step c, and step c's gate
# (_native_k3s_gpu_wire) is the only thing that sets TRACEBLOC_GPU_WIRED.
dispatch_gpu_setup() {
  case "$GPU_VENDOR" in
    nvidia) _nvidia_gpu_setup ;;
    amd)    install_rocm ;;
    *)      log "No GPU setup required." ;;
  esac
}

# _nvidia_gpu_setup -- dispatch_gpu_setup's NVIDIA half, which prepare-host runs too
# (k3s.sh _native_k3s_prepare_host): the floor, the driver, then the toolkit and a CDI
# spec.
_nvidia_gpu_setup() {
  if _gpu_floor_skips; then
    log "NVIDIA GPU below the floor (${TB_GPU_FLOOR_VERDICT}) — no driver, toolkit or GPU wiring; CPU mode."
  elif ! install_nvidia_drivers; then
    # No driver went in: it said so and how to install one; CPU mode, no toolkit.
    log "No NVIDIA driver — no toolkit or GPU wiring; CPU mode."
  else
    _native_k3s_gpu_prepare
  fi
}

# _tools_rc_for_shell — which POSIX rc file a *fresh* interactive shell of the
# user's $SHELL reads, so a PATH line we append is actually sourced. Mirrors
# install-cli.sh::_cli_rc_for_shell, kept local so this module stays testable on
# its own: zsh → ~/.zshrc; bash+macOS → ~/.bash_profile; bash+Linux → ~/.bashrc
# (a fresh non-login bash reads ~/.bashrc, NOT ~/.profile — the failure mode);
# anything else → POSIX ~/.profile. fish is NOT a POSIX shell (no `export`, reads
# ~/.config/fish, not these files) and is handled separately in
# _persist_tools_on_path — never routed here.
_tools_rc_for_shell() {
  case "$(basename "${SHELL:-sh}")" in
    zsh)  echo "${HOME}/.zshrc" ;;
    bash) if [ "${OS:-}" = "Darwin" ]; then echo "${HOME}/.bash_profile"; else echo "${HOME}/.bashrc"; fi ;;
    *)    echo "${HOME}/.profile" ;;
  esac
}

# _persist_tools_on_path — when Tier 0 dropped kubectl/helm into the user's
# ~/.local/bin, that dir usually isn't on a fresh shell's PATH, so the summary's
# suggested `kubectl …` commands fail in a NEW terminal — and because the CLI can
# live in /usr/local/bin (already on PATH), nothing else triggers a PATH fix
# either (Bugbot #375). Persist the dir to the shell rc so future terminals
# resolve the tools. Idempotent (skips if the rc already references ~/.local/bin)
# and best-effort — a PATH-persist hiccup must never fail an otherwise-good
# install. No-op unless we actually used the user-local dir (i.e. Tier 0).
_persist_tools_on_path() {
  [ "${TRACEBLOC_TOOLS_DIR:-}" = "${HOME}/.local/bin" ] || return 0
  # fish reads ~/.config/fish, not the POSIX rc files, and uses `set`/fish_add_path
  # rather than `export PATH=`. Appending a bash `export` line to ~/.profile would
  # be dead (fish never loads it), so hint the fish-correct command instead — it
  # persists (a universal var) AND applies to the current shell (Bugbot #375).
  if [ "$(basename "${SHELL:-sh}")" = "fish" ]; then
    hint "Add ${HOME}/.local/bin to your PATH so kubectl and helm resolve:  fish_add_path \"${HOME}/.local/bin\""
    return 0
  fi
  local rc; rc="$(_tools_rc_for_shell)"
  # Already referenced (a prior run, or the user's/distro's own line) → leave it:
  # a fresh shell already finds the tools, and we must not double-append.
  if [ -f "$rc" ] && grep -qF '.local/bin' "$rc" 2>/dev/null; then return 0; fi
  {
    printf '\n# Added by tracebloc installer (RFC 0001 #1175): user-local tools\n'
    printf 'export PATH="%s/.local/bin:$PATH"\n' "$HOME"
  } >> "$rc" 2>/dev/null || return 0
  log "Added ${HOME}/.local/bin to your PATH in ${rc}: a new terminal (or 'source ${rc}') resolves kubectl and helm."
}

# ── Main Linux installer ────────────────────────────────────────────────────
# install_linux -- step b on Linux: native k3s (RFC-0175 D3), which k3s.sh sets up
# (_native_k3s_install_linux). The resolver refuses every other substrate before step
# a; a run that reached step b with one anyway (a caller that set the substrate
# itself) is refused here by name, whatever the retired map or the WSL probe says.
install_linux() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then
    _native_k3s_install_linux
    return 0
  fi

  error "This installer sets up native ${TB_SUBSTRATE_FRESH_LINUX} on Linux, not '${TRACEBLOC_SUBSTRATE_RESOLVED:-}'. Unset TRACEBLOC_SUBSTRATE and re-run."
}

# refuse_sudo_wrapped_install — a full provision must run as the DAILY (non-root)
# user; the installer elevates each privileged step itself (RFC-0002). A
# `sudo bash install.sh` runs the WHOLE thing as root: ~/.tracebloc, ~/.kube/config
# and the chmod-600 credential would land root-owned under /root — locking the
# daily user out, with no chown anywhere to undo it (#427). Refuse it early, before
# any file is created.
# Exemptions: a genuine root login (no SUDO_USER) is fine — /root IS its home; and
# prepare-host (the admin path) has already dispatched-and-exited in main() before
# this runs. Admins provisioning for someone else use prepare-host / TB_PREPARE_USER.
refuse_sudo_wrapped_install() {
  # `id -u` (the EFFECTIVE uid) rather than $EUID: EUID is read-only in bash, so the
  # test suite can't shadow it — id() can be mocked.
  [[ "$(id -u 2>/dev/null)" == "0" ]] || return 0
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] || return 0
  error "Don't run the installer with sudo. It elevates each privileged step itself, and running the whole thing as root would root-own ${SUDO_USER}'s ~/.tracebloc + ~/.kube. Re-run WITHOUT sudo as '${SUDO_USER}'. Admin setting up for someone else? Name the RESEARCHER (not yourself), and prepare-host sets k3s up for them:  export TB_PREPARE_USER=<researcher-username>  &&  curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host"
}

# _prepare_host_named_user WHAT -- set TB_PREPARE_TARGET to the user prepare-host is
# run for: TB_PREPARE_USER, trimmed. WHAT finishes the warning's "prepare-host ..."
# for this path. The user must be named EXPLICITLY: never $SUDO_USER, which is the
# ADMIN who ran prepare-host, not the researcher (granting the admin would report
# success while the researcher still can't install; Bugbot #377).
#
# TB_PREPARE_USER is the ONLY name read here, although the other CLI hand-off names
# also accept a TRACEBLOC_ spelling. Every `tracebloc prepare-host` clears an
# inherited TB_PREPARE_USER and sets it only when a researcher was named, so a bare
# `tracebloc prepare-host` grants nobody. Older CLIs clear only that spelling, and
# they run this same live installer: a TRACEBLOC_PREPARE_USER left in the admin's
# shell would pass straight through them, and reading it here would hand k3s
# cluster-admin to a user the admin did not name on this run. So that spelling is
# reported, never read.
TB_PREPARE_TARGET=""
_prepare_host_named_user() {
  local target="${TB_PREPARE_USER:-}"
  # Trim surrounding whitespace BEFORE the non-empty gate: a pasted value with
  # stray spaces passes [[ -n ]], fails usermod, and skips the honest no-grant
  # messaging even though a real username was intended (Bugbot r3).
  target="${target#"${target%%[![:space:]]*}"}"; target="${target%"${target##*[![:space:]]}"}"
  # A CLI that sets both spellings sets them equal, so only a DIFFERENT value
  # (or one with no TB_PREPARE_USER beside it) is worth a warning.
  local _canon="${TRACEBLOC_PREPARE_USER:-}"
  _canon="${_canon#"${_canon%%[![:space:]]*}"}"; _canon="${_canon%"${_canon##*[![:space:]]}"}"
  if [[ -n "$_canon" && "$_canon" != "$target" ]]; then
    warn "Ignoring TRACEBLOC_PREPARE_USER: prepare-host ${1} the user named in TB_PREPARE_USER (or on the tracebloc prepare-host command line)."
  fi
  TB_PREPARE_TARGET="$target"
}

# _prepare_host_print — `prepare-host --print` (RFC-0175 D3, client-dev#1541):
# run_prepare_host itself, with TRACEBLOC_ROOT_PLAN set, so each privileged command it
# would run is listed by the root executor (common.sh's tb_root) and none runs.
# The list cannot drift from a run: it IS the run's own calls. The dry run's
# messages go to the log, stdin is /dev/null (nothing is read from the installer
# under `curl | bash`), and a refusal still reaches the terminal, on stderr. Prints
# the plan, numbered, and exits 0; a dry run that stopped prints no plan.
_prepare_host_print() {
  local dir plan rc=0 n=0 line
  tb_scratch_dir dir tracebloc-plan \
    || error "prepare-host --print: couldn't make a private directory for the plan. Nothing ran."
  plan="${dir}/plan"
  : > "$plan" || error "prepare-host --print: couldn't write the plan under ${dir}. Nothing ran."
  # The subshell reaps what it makes itself (a subshell starts with no EXIT trap),
  # from an empty list, so the plan's own directory is never among them. Its exit
  # goes through tb_exit_rc (client-dev#1752): on bash 3.2 an abort in the dry run
  # would otherwise exit 0 here and show a partial plan as the whole one.
  ( export TRACEBLOC_ROOT_PLAN="$plan"; _TB_SCRATCH_DIRS=""; _tb_done=0
    trap '_tb_rc=$?; tb_scratch_reap; exit "$(tb_exit_rc "$_tb_rc")"' EXIT
    run_prepare_host && _tb_done=1 ) \
    </dev/null >>"${LOG_FILE:-/dev/null}" || rc=$?
  if [[ -e "${plan}.broken" ]]; then
    tb_scratch_rm "$dir"
    error "prepare-host --print: a line of the plan could not be written, so no plan is shown. Nothing ran."
  fi
  if [[ "$rc" -ne 0 ]]; then
    tb_scratch_rm "$dir"
    error "prepare-host --print stopped before the end of its plan (above), so no plan is shown. Nothing ran. It reads this machine as $(id -un 2>/dev/null), without sudo; to plan for files only root can read, run it as root."
  fi
  echo ""
  info "prepare-host --print: what prepare-host would run as root on this machine, in order. None of it ran."
  info "Not listed: the reads it makes first (getent, systemctl is-active, the k3s config read and the like). --print made them as $(id -un 2>/dev/null), without sudo."
  info "Not made: the downloads. The run checks each against its pinned sha256 before it uses it."
  echo ""
  while IFS= read -r line; do
    n=$((n + 1))
    printf '  %3d  %s\n' "$n" "$line"
  done < "$plan"
  [[ "$n" -gt 0 ]] || echo "  (nothing: this machine needs no command run as root)"
  echo ""
  info "To run them: the same command without --print."
  tb_scratch_rm "$dir"
  return 0
}

# run_prepare_host — the standalone, admin-run step (RFC 0001 #1178). An
# administrator runs this ONCE (`curl … | bash -s -- prepare-host`, or
# `tracebloc prepare-host`) to set native k3s up FOR the researcher named in
# TB_PREPARE_USER, who then installs with no administrator rights (k3s.sh,
# _native_k3s_prepare_host; RFC-0175 D3). It never mints a credential or installs
# the CLI, so an admin can safely run it on a shared host without provisioning
# anything as themselves.
run_prepare_host() {
  if [[ "$OS" != "Linux" ]]; then
    error "prepare-host is for Linux hosts. On a Mac or on Windows, run the installer itself."
  fi
  # --print: this same function, once more, under the plan (_prepare_host_print).
  if [[ "${TRACEBLOC_PREPARE_PRINT:-}" == 1 ]] && ! tb_root_planning; then
    _prepare_host_print
    return $?
  fi
  TB_PREPARE_HOST_RUN=1   # for _pm_install_stalled: a stall here is re-run as prepare-host, never the full installer
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

  # Native k3s is the one runtime prepare-host sets up. The resolver refuses every
  # other substrate before this; a run that reached here with one is refused too.
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] \
    || error "prepare-host sets up native ${TB_SUBSTRATE_FRESH_LINUX} on Linux, not '${TRACEBLOC_SUBSTRATE_RESOLVED:-}'. Unset TRACEBLOC_SUBSTRATE and re-run prepare-host."
  _prepare_host_named_user "sets k3s up only for"
  _native_k3s_prepare_host "$TB_PREPARE_TARGET"
  return $?
}
