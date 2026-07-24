#!/usr/bin/env bash
# =============================================================================
#  setup-linux.sh — Linux prerequisites: package manager, Docker Engine,
#                   system deps, kubectl, k3d, helm, GPU dispatch
# =============================================================================

# ── Tool-install target defaults ─────────────────────────────────────────────
# WHERE kubectl/k3d/helm install, and whether that needs sudo. Default to the
# system location; _set_tools_target() overrides at runtime (Tier 0 flips these
# to a no-sudo ~/.local/bin). Defaulted here so any caller that reaches the
# install_* functions WITHOUT going through _set_tools_target — the bats suite,
# e2e harnesses — still gets the system behaviour, not an empty TB_TOOLS_DIR
# (kubectl → "/kubectl") or a spurious no-sudo branch (Bugbot #1175 r2).
: "${TB_TOOLS_DIR:=/usr/local/bin}"
: "${TB_TOOLS_SUDO:=sudo}"

# ── Package manager detection ────────────────────────────────────────────────
setup_pm() {
  # apt note: Ubuntu 22.04+ ships needrestart, which hooks `apt-get install` and
  # opens an interactive "restart services?" prompt that `-y` does NOT suppress.
  # Run inside spin_cmd (stdout/stderr redirected, process backgrounded) that
  # prompt is invisible and blocks reading the TTY → SIGTTIN → the install hangs
  # forever ("still pulling conntrack"). DEBIAN_FRONTEND=noninteractive +
  # NEEDRESTART_MODE=a make apt fully non-interactive; they are passed *through*
  # `sudo env` because sudo resets the environment by default.
  #
  # apt also waits *indefinitely* on the dpkg lock while apt-daily / unattended-
  # upgrades hold it on a freshly-booted host (#210); -o DPkg::Lock::Timeout=600
  # bounds that wait so the install fails with a clear error rather than hanging
  # silently behind the spinner.
  if   has apt-get; then PM_UPDATE="sudo apt-get update -qq -o DPkg::Lock::Timeout=600"; PM_INSTALL="sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  elif has dnf;     then PM_UPDATE="sudo dnf makecache -q";             PM_INSTALL="sudo dnf install -y -q"
  elif has yum;     then PM_UPDATE="sudo yum makecache -q";             PM_INSTALL="sudo yum install -y -q"
  elif has zypper;  then PM_UPDATE="sudo zypper refresh";               PM_INSTALL="sudo zypper install -y"
  elif has pacman;  then PM_UPDATE="sudo pacman -Sy --noconfirm";       PM_INSTALL="sudo pacman -S --noconfirm"
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
  sudo fuser $locks >/dev/null 2>&1 || return 0   # free already → silent fast path
  spin_cmd "Waiting for background system updates to finish…" bash -c '
    waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
      [ "$waited" -ge 600 ] && exit 0
      sleep 5; waited=$((waited + 5))
    done' || true
}

# ── Kernel modules Docker + k3s need ─────────────────────────────────────────
# Docker's bridge driver programs iptables NAT rules using the `addrtype` match
# (xt_addrtype), and k3s needs br_netfilter + overlay. On minimal RHEL/AlmaLinux
# cloud images (e.g. AWS EC2) these netfilter modules ship in kernel-modules-EXTRA,
# which is NOT installed by default (the base kernel-modules package does NOT
# carry xt_addrtype/iptable_nat/br_netfilter) — so dockerd dies on startup with
# "iptables … addrtype … missing kernel module". Install kernel-modules-extra,
# (re)load the modules, and persist them for reboots. Best-effort + idempotent.
#
# Caveat: kernel-modules-extra is only published for the repo's CURRENT kernel.
# If the running kernel is older (image hasn't been rebooted into the latest
# kernel yet), dnf installs the modules for the NEW kernel and they can't be
# modprobe'd until a reboot. We flag that (KMODS_REBOOT_REQUIRED) so the caller
# can tell the user to reboot + re-run; the modules-load.d entry then activates
# them on boot.
_ensure_kernel_modules() {
  local mods="overlay br_netfilter xt_addrtype iptable_nat ip_tables"
  local m missing=""
  for m in $mods; do sudo modprobe "$m" 2>/dev/null || missing=1; done
  if [[ -n "$missing" ]] && has dnf; then
    # The netfilter modules live in kernel-modules-extra, NOT the base
    # kernel-modules package. Install unversioned so dnf pulls the extra set
    # (and a matching newer kernel, if the repo has moved on) for the current repo.
    spin_cmd "Installing kernel modules for Docker/k3s…" \
      sudo dnf install -y -q kernel-modules-extra || true
    missing=""
    for m in $mods; do sudo modprobe "$m" 2>/dev/null || missing=1; done
  fi
  printf '%s\n' $mods | sudo tee /etc/modules-load.d/tracebloc.conf >/dev/null 2>&1 || true

  # Still unloadable, but the module file exists for a DIFFERENT (installed but
  # not-yet-booted) kernel → a reboot will bring it in via modules-load.d.
  if [[ -n "$missing" ]] \
     && ! find "/lib/modules/$(uname -r)" -name 'xt_addrtype.ko*' 2>/dev/null | grep -q . \
     &&   find /lib/modules                -name 'xt_addrtype.ko*' 2>/dev/null | grep -q .; then
    KMODS_REBOOT_REQUIRED=1
  fi
}

# ── Corporate-proxy support for the host Docker daemon (#244) ────────────────
# dockerd pulls the k3d node image (rancher/k3s) and other images via the HOST
# daemon, which does NOT inherit the shell's HTTP_PROXY — it reads a systemd
# drop-in instead. Without it, `k3d cluster create` fails on a strict proxy-only
# host with "failed to pull rancher/k3s … i/o timeout", BEFORE the client is
# ever installed. Mirrors cluster.sh (k3d node env, #166) and
# install-client-helm.sh (chart values, #242): when the host has a proxy,
# propagate it to every layer that needs it. Idempotent — only restarts dockerd
# when the drop-in content actually changes, so a re-run never bounces a running
# cluster; and if the host proxy is later REMOVED, a re-run deletes the drop-in
# we wrote (tagged with a marker) so dockerd stops routing pulls through a dead
# proxy, while a foreign http-proxy.conf is left untouched. (Linux/systemd only;
# Docker Desktop on macOS manages its own proxy.)
_configure_docker_proxy() {
  has systemctl || return 0                       # only systemd-managed Docker
  local dir="${TB_DOCKER_DROPIN_DIR:-/etc/systemd/system/docker.service.d}"
  local conf="$dir/http-proxy.conf"
  local marker="# Managed by tracebloc installer (#244)"

  local proxy="" var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ -n "${!var:-}" ]] && { proxy="${!var}"; break; }
  done

  # No host proxy → remove a drop-in WE wrote on a previous run (the proxy was
  # removed since), so dockerd doesn't keep pulling through a proxy that no
  # longer exists. Only touch our own file (identified by the marker); a
  # user/IT-managed http-proxy.conf is left alone.
  if [[ -z "$proxy" ]]; then
    if [[ -f "$conf" ]] && sudo grep -qF "$marker" "$conf" 2>/dev/null; then
      sudo rm -f "$conf"
      sudo systemctl daemon-reload 2>/dev/null || true
      if sudo systemctl is-active --quiet docker 2>/dev/null; then
        spin_cmd "Removing stale Docker proxy settings…" sudo systemctl restart docker || true
      fi
      log "Removed stale tracebloc-managed Docker daemon proxy (no host proxy set)."
    fi
    return 0
  fi

  local https="${HTTPS_PROXY:-${https_proxy:-$proxy}}"
  local noproxy
  if declare -F _augment_no_proxy >/dev/null 2>&1; then
    noproxy="$(_augment_no_proxy)"                 # host NO_PROXY ∪ cluster-internal ranges
  else
    noproxy="${NO_PROXY:-${no_proxy:-}}"
  fi

  local desired
  printf -v desired '%s\n[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
    "$marker" "$proxy" "$https" "$noproxy"

  # Unchanged → leave dockerd alone (a restart would bounce a running cluster).
  # Compare with cmp, not "$(cat)" == , so a trailing newline isn't stripped by
  # command substitution (which would make the check always report "changed").
  if [[ -f "$conf" ]] && printf '%s' "$desired" | sudo cmp -s - "$conf" 2>/dev/null; then
    log "Docker daemon proxy already configured."
    return 0
  fi

  sudo mkdir -p "$dir"
  printf '%s' "$desired" | sudo tee "$conf" >/dev/null
  sudo systemctl daemon-reload 2>/dev/null || true
  # Restart only if the daemon is already up; on a fresh install the start in
  # install_docker_engine brings it up with the drop-in already in place.
  if sudo systemctl is-active --quiet docker 2>/dev/null; then
    spin_cmd "Applying Docker proxy settings…" sudo systemctl restart docker || true
  fi
  log "Configured Docker daemon proxy for image pulls behind a corporate proxy (HTTP_PROXY=$proxy)."
}

# ── Docker Engine ────────────────────────────────────────────────────────────
install_docker_engine() {
  # os-release path is overridable (TB_OS_RELEASE_FILE) so the distro detection
  # below stays testable on hosts without one — e.g. macOS dev machines, where a
  # bash `[[ -f ]]` file-test can't be mocked the way a command like `grep` can.
  local os_release="${TB_OS_RELEASE_FILE:-/etc/os-release}"
  if ! has docker; then
    if [[ -f "$os_release" ]] && grep -qi 'amzn\|amazon' "$os_release"; then
      if has dnf; then spin_cmd "Installing Docker…" sudo dnf install -y docker
      else              spin_cmd "Installing Docker…" sudo yum install -y docker; fi
    elif has pacman; then
      spin_cmd "Installing Docker…" sudo pacman -S --noconfirm docker
    elif has zypper; then
      spin_cmd "Installing Docker…" sudo zypper install -y docker
    elif [[ -f "$os_release" ]] && grep -qiE '^ID="?(almalinux|rocky|ol|oracle)"?' "$os_release"; then
      # get.docker.com rejects RHEL rebuilds (almalinux/rocky/ol) with
      # "Unsupported distribution". Install docker-ce from Docker's official
      # CentOS repo instead — it is RHEL-compatible and works on these distros.
      spin_cmd "Installing Docker…" bash -c '
        set -e
        sudo dnf -y -q install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo dnf -y -q install docker-ce docker-ce-cli containerd.io'
    else
      local docker_script
      docker_script="$(mktemp)"
      retry 3 5 curl -fsSL $CURL_SECURE https://get.docker.com -o "$docker_script"
      chmod +x "$docker_script"
      # Same needrestart guard as setup_pm: get.docker.com runs `apt-get install`
      # internally, so under spin_cmd it can hit the same hidden prompt and hang.
      spin_cmd "Installing Docker…" sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a bash "$docker_script"
      rm -f "$docker_script"
    fi
    # Enable for boot only (no --now): starting is handled below, where a start
    # failure is diagnosed instead of aborting the whole script under `set -e`.
    sudo systemctl enable docker >/dev/null 2>&1 || true
    # prepare-host mode: the invoking ADMIN must not be granted the socket —
    # only the researcher named by TB_PREPARE_USER gets it, later (Bugbot on
    # #381; same least-privilege rule as the #377 SUDO_USER fix).
    [[ -n "${TB_PREPARE_HOST_MODE:-}" ]] || sudo usermod -aG docker "$USER"
    success "Docker"
  else
    success "Docker"
  fi

  # Load the kernel modules dockerd's bridge driver + k3s need BEFORE starting,
  # so minimal RHEL/AlmaLinux images don't fail with the "addrtype" iptables error.
  _ensure_kernel_modules

  # Give the host Docker daemon the corporate proxy BEFORE it starts and before
  # k3d uses it to pull rancher/k3s (#244) — dockerd doesn't read the shell env.
  _configure_docker_proxy

  # Clear any failed/throttled state from a previous attempt first — a crashed
  # daemon leaves the unit in "Start request repeated too quickly", which makes
  # systemctl refuse a plain start (so a bare re-run can never recover). Both
  # commands are best-effort; the `docker info` check below is the real gate.
  sudo systemctl reset-failed docker 2>/dev/null || true
  sudo systemctl start docker 2>/dev/null || true

  # prepare-host mode: the admin verifies the DAEMON via sudo and never joins
  # or re-execs into the docker group — the sg re-exec below re-runs the script
  # WITHOUT its arguments, which would silently turn a host-prep into a FULL
  # provision as the admin; and a non-root admin without socket access must not
  # abort before the TB_PREPARE_USER grant runs (Bugbot on #381).
  if [[ -n "${TB_PREPARE_HOST_MODE:-}" ]] && sudo docker info &>/dev/null; then
    log "Docker daemon running (verified via sudo — prepare-host mode)."
    return 0
  fi
  if ! docker info &>/dev/null 2>&1; then
    # (a) Group not active in THIS shell yet → re-exec under the docker group.
    if [[ -z "${TB_PREPARE_HOST_MODE:-}" && -z "${_K3S_INSTALL_REEXEC:-}" ]] && id -nG "$USER" 2>/dev/null | grep -qw docker; then
      SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
      log "Docker group not yet active in this session — re-executing script..."
      exec sg docker -c "_K3S_INSTALL_REEXEC=1 bash '$SELF'"
    fi
    # (b) The daemon itself isn't running → a Docker/host problem, not a group
    # one. Surface Docker's OWN error (a 'log out and back in' hint would just
    # send the user in circles, as it can't fix a crashing daemon).
    if ! sudo systemctl is-active --quiet docker 2>/dev/null; then
      echo ""
      # Modules were just installed for a newer, not-yet-booted kernel → the only
      # remedy is a reboot; a re-run without it would loop on the same failure.
      if [[ -n "${KMODS_REBOOT_REQUIRED:-}" ]]; then
        warn "Docker can't start yet: the netfilter kernel modules it needs were just installed"
        hint "for a newer kernel that isn't running. Reboot to load it, then re-run this installer:"
        hint "    sudo reboot"
        hint "(The modules are pinned in /etc/modules-load.d/tracebloc.conf and load automatically on boot.)"
        echo ""
        error "Reboot required to finish Docker setup. Reboot, then re-run this installer."
      fi
      warn "Docker is installed, but its daemon won't start — this is a Docker/host issue, not tracebloc."
      hint "If the error below mentions 'addrtype' / 'missing kernel module', the host lacks the"
      hint "netfilter modules Docker needs — try:  sudo dnf install -y kernel-modules-extra && sudo reboot"
      hint "Other causes: SELinux, an overlay storage-driver issue, or low /var/lib/docker disk. Docker's error:"
      { sudo systemctl status docker.service --no-pager -l 2>&1 | tail -6
        sudo journalctl -u docker.service --no-pager 2>/dev/null \
          | grep -iE 'level=(error|fatal)|failed to|cannot |unable |no such' | tail -12; } | sed 's/^/    /'
      echo ""
      error "Start Docker manually (fix the error above), then re-run this installer."
    fi
    error "Could not connect to Docker. Try logging out and back in, then re-run the script."
  fi
  log "Docker daemon running."
}

# ── System dependencies ─────────────────────────────────────────────────────
install_system_deps() {
  # conntrack binary ships under different package names per distro:
  #   Debian/Ubuntu (apt) → "conntrack";  RHEL/SUSE/Arch (dnf/yum/zypper/pacman) → "conntrack-tools"
  local conntrack_pkg="conntrack-tools"
  has apt-get && conntrack_pkg="conntrack"
  MISSING_PKGS=()
  has curl      || MISSING_PKGS+=(curl)
  has conntrack || MISSING_PKGS+=("$conntrack_pkg")
  # helm's get-helm-3 verifies its download checksum with openssl and unpacks a
  # tarball with tar; minimal cloud images (Amazon Linux 2023, minimal RHEL) ship
  # neither, so the Helm install fails. Ensure both (package names are uniform
  # across apt/dnf/yum/zypper/pacman, unlike conntrack).
  has openssl   || MISSING_PKGS+=(openssl)
  has tar       || MISSING_PKGS+=(tar)
  if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    # Guard the index refresh: under set -e an unguarded failure here aborts the
    # whole install, yet the per-package installs below are already guarded
    # (|| log) — so a flaky mirror refresh was MORE fatal than a failed install,
    # which is backwards. A stale index usually still installs from cache; if a
    # package genuinely can't be found, the guarded install below surfaces it.
    spin_cmd "Updating package index…" $PM_UPDATE || \
      warn "Package index refresh failed — continuing; installs will use the cached index."
    for pkg in "${MISSING_PKGS[@]}"; do
      spin_cmd "Installing $pkg…" $PM_INSTALL "$pkg" || \
        log "Could not install $pkg — may already be satisfied by an alternative package."
    done
    log "Dependencies installed: ${MISSING_PKGS[*]}"
  fi
  success "System dependencies"
}

# ── kubectl ──────────────────────────────────────────────────────────────────
# _set_tools_target — decide WHERE kubectl/k3d/helm install and whether that
# needs sudo, based on the tier (RFC 0001 #1175). On Tier 0 (a usable runtime
# already exists, no admin) the tools MUST NOT sudo — a docker-group researcher
# without root would otherwise fail (or hit a hidden password prompt under
# spin_cmd) at the "zero privileged steps" step. Install them into ~/.local/bin
# (user-owned) and put it on this process's PATH so create_cluster finds them.
# Otherwise the system location, with sudo. Sets TB_TOOLS_DIR + TB_TOOLS_SUDO.
_set_tools_target() {
  if [ "${INSTALL_TIER:-}" = "0" ]; then
    TB_TOOLS_DIR="${HOME}/.local/bin"
    TB_TOOLS_SUDO=""
    mkdir -p "$TB_TOOLS_DIR"
    case ":$PATH:" in *":$TB_TOOLS_DIR:"*) ;; *) export PATH="$TB_TOOLS_DIR:$PATH" ;; esac
  else
    TB_TOOLS_DIR="/usr/local/bin"
    TB_TOOLS_SUDO="sudo"
  fi
}

_fetch_kubectl() {
  local ver="$1" arch="$2"
  local tmpdir
  tmpdir="$(mktemp -d)"
  retry 3 5 curl -fsSL $CURL_SECURE \
    "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl" -o "${tmpdir}/kubectl"
  retry 3 5 curl -fsSL $CURL_SECURE \
    "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl.sha256" -o "${tmpdir}/kubectl.sha256"
  echo "$(cat "${tmpdir}/kubectl.sha256")  ${tmpdir}/kubectl" | sha256sum --check --quiet \
    || { rm -rf "$tmpdir"; error "System tool checksum verification failed"; }
  chmod +x "${tmpdir}/kubectl"
  # Tier 0 → no sudo (TB_TOOLS_SUDO empty, TB_TOOLS_DIR under $HOME).
  if [ -n "$TB_TOOLS_SUDO" ]; then
    sudo mv "${tmpdir}/kubectl" "$TB_TOOLS_DIR/kubectl"
  else
    mv "${tmpdir}/kubectl" "$TB_TOOLS_DIR/kubectl"
  fi
  rm -rf "$tmpdir"
}

install_kubectl() {
  if ! has kubectl; then
    KUBE_VER=$(retry 3 5 curl -fsSL $CURL_SECURE https://dl.k8s.io/release/stable.txt)
    spin_cmd "Installing system tools…" _fetch_kubectl "$KUBE_VER" "$ARCH_DL"
    log "kubectl $KUBE_VER installed."
  else
    log "kubectl: $(kubectl version --client --short 2>/dev/null || echo present)"
  fi
}

# ── k3d ──────────────────────────────────────────────────────────────────────
# Download the k3d release binary + checksums.txt at the given tag, verify, and
# install into TB_TOOLS_DIR (mirrors _fetch_kubectl; fail-closed). We install
# the binary OURSELVES because upstream's install.sh performs NO checksum
# verification — its downloadFile fetches the bare binary and installFile just
# chmod+cp's it (review of the pinned v5.9.0 script, PR #382) — so piping it
# through sudo would install unverified bytes on a privileged path.
# checksums.txt lines read "<sha256>  _dist/k3d-linux-amd64": match on the
# asset basename.
_fetch_k3d_release() {
  local tag="$1" arch="$2"
  local base="https://github.com/k3d-io/k3d/releases/download/${tag}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  # --connect-timeout + a stall floor (not --max-time: the binary is ~50 MB and
  # a hard cap would break slow-but-healthy links): a hung transfer under
  # spin_cmd would otherwise spin forever (Bugbot r2).
  retry 3 5 curl -fsSL $CURL_SECURE --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "${base}/k3d-linux-${arch}" -o "${tmpdir}/k3d"
  retry 3 5 curl -fsSL $CURL_SECURE --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
    "${base}/checksums.txt" -o "${tmpdir}/checksums.txt"
  local want
  want="$(awk -v asset="k3d-linux-${arch}" \
    '{ n = split($2, p, "/"); if (p[n] == asset) { print $1; exit } }' \
    "${tmpdir}/checksums.txt" 2>/dev/null)"
  if [ -z "$want" ] || ! echo "${want}  ${tmpdir}/k3d" | sha256sum --check --quiet; then
    rm -rf "$tmpdir"
    error "System tool checksum verification failed"
  fi
  chmod +x "${tmpdir}/k3d"
  # Tier 0 → no sudo (TB_TOOLS_SUDO empty, TB_TOOLS_DIR under $HOME).
  if [ -n "$TB_TOOLS_SUDO" ]; then
    sudo mv "${tmpdir}/k3d" "$TB_TOOLS_DIR/k3d"
  else
    mv "${tmpdir}/k3d" "$TB_TOOLS_DIR/k3d"
  fi
  rm -rf "$tmpdir"
}

install_k3d() {
  if has k3d; then
    log "k3d: $(k3d version | head -1)"
    return 0
  fi

  # Pin the k3d release (K3D_VERSION, common.sh) and fetch the binary DIRECTLY
  # from the pinned release, verified against the release's checksums.txt
  # (upstream's install.sh verifies nothing — see _fetch_k3d_release). The
  # direct download also never touches the releases/latest redirect, whose
  # GitHub rate limiting on shared egress IPs (CI runners, corporate NAT) took
  # down 2/9 distro CI jobs on 2026-07-21 with a bare "curl: 404" — so the
  # failure mode can't occur on the pinned (default) path at all.
  # K3D_VERSION=latest resolves the newest tag at install time via the plain
  # /releases/latest redirect (no API) and then takes the same verified path;
  # an empty value means the common.sh default pin (Bugbot r1). The tag lands
  # in a URL path, so anything that isn't a plain release tag fails closed —
  # a value carrying "/" could otherwise traverse outside k3d-io/k3d
  # (Bugbot r1).
  local _k3d_tag="${K3D_VERSION:-}"
  [[ "$_k3d_tag" == "latest" ]] && _k3d_tag=""
  [[ -z "$_k3d_tag" || "$_k3d_tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
    || error "K3D_VERSION must be a k3d release tag like v5.9.0, or 'latest' (got '${K3D_VERSION:-}')"
  if [ -z "$_k3d_tag" ]; then
    _k3d_tag="$(retry 3 5 curl -fsSLI $CURL_SECURE --connect-timeout 15 --max-time 30 \
      -o /dev/null -w '%{url_effective}' \
      "https://github.com/k3d-io/k3d/releases/latest" 2>/dev/null)" || _k3d_tag=""
    _k3d_tag="${_k3d_tag##*/}"
    [[ "$_k3d_tag" =~ ^v[0-9][A-Za-z0-9._-]*$ ]] \
      || error "Couldn't resolve the latest k3d release tag — set K3D_VERSION to a release tag (e.g. v5.9.0) and re-run."
  fi

  spin_cmd "Installing system tools…" _fetch_k3d_release "$_k3d_tag" "$ARCH_DL" \
    || error "System tool installation failed. See the install log for details."

  if ! has k3d; then
    error "System tool installation completed but not found on PATH."
  fi

  log "k3d: $(k3d version | head -1)"
}

# ── Helm ─────────────────────────────────────────────────────────────────────
_ensure_helm_executable() {
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -n "$helm_bin" && -f "$helm_bin" && ! -x "$helm_bin" ]]; then
    log "Making Helm executable (fixing permissions)..."
    # Tier 0 (no admin): helm is in the user's ~/.local/bin — a plain owner chmod
    # works and MUST NOT sudo (would prompt on the tty after the zero-privilege
    # promise, like the systemctl guard). Full flow: /usr/local/bin needs sudo.
    # TB_TOOLS_SUDO is set by _set_tools_target (empty on Tier 0), defaulted to
    # "sudo" at module scope for direct callers (Bugbot #1175 r3).
    if [[ -n "${TB_TOOLS_SUDO:-}" ]]; then
      sudo chmod 755 "$helm_bin" 2>/dev/null || true
    else
      chmod 755 "$helm_bin" 2>/dev/null || true
    fi
  fi
}

install_helm() {
  if ! has helm; then
    local helm_script
    helm_script="$(mktemp)"
    retry 3 5 curl -fsSL $CURL_SECURE \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$helm_script"
    chmod +x "$helm_script"
    # Tier 0 (no admin): get-helm-3 honours USE_SUDO + HELM_INSTALL_DIR — install
    # user-space, no sudo (RFC 0001 #1175). Otherwise the script's default
    # (USE_SUDO=true → /usr/local/bin).
    if [ -z "$TB_TOOLS_SUDO" ]; then
      spin_cmd "Installing system tools…" \
        env "USE_SUDO=false" "HELM_INSTALL_DIR=$TB_TOOLS_DIR" "PATH=$PATH" bash "$helm_script"
    else
      spin_cmd "Installing system tools…" bash "$helm_script"
    fi
    rm -f "$helm_script"
    _ensure_helm_executable
  else
    _ensure_helm_executable
  fi
  log "helm: $(helm version --short 2>/dev/null || echo installed)"
  success "System tools"
}

# ── GPU setup dispatch ───────────────────────────────────────────────────────
dispatch_gpu_setup() {
  case "$GPU_VENDOR" in
    nvidia) install_nvidia_drivers; install_nvidia_container_toolkit ;;
    amd)    install_rocm ;;
    *)      log "No GPU setup required." ;;
  esac
}

# ── Main Linux installer ────────────────────────────────────────────────────
# _route_install_tier — honor the detected install tier (set by run_host_probes
# in main's step a, RFC 0001) and fail fast when the host genuinely cannot run
# containers without administrator rights AND there is no way to get them.
# Extracted so the bats suite can exercise the decision without running the whole
# install. TB_FORCE_TIER overrides the detected tier (QA / support).
#
# This is the routing SKELETON (#1172): it adds tier detection + the honest
# fail-fast to the flow. Per-tier optimisation of the body — Tier 0 skipping the
# privileged steps (#1175), Tier 1 setting up rootless Docker (#1177) — lands on
# top; until then every proceeding tier runs the existing full flow below.
_route_install_tier() {
  [ -n "${TB_FORCE_TIER:-}" ] && INSTALL_TIER="$TB_FORCE_TIER"
  # Tier 2 = the kernel can't run an unprivileged container (no cgroup v2 /
  # unprivileged userns). If we also can't become root, no amount of retrying
  # helps — fail with the actionable remedy instead of a cryptic mid-install
  # crash minutes later. Tier 0 (runtime usable) and Tier 1 (rootless-capable)
  # proceed. When probe.sh wasn't loaded (stale bootstrap) INSTALL_TIER is unset
  # and we proceed exactly as before.
  if [ "${INSTALL_TIER:-}" = "2" ] && [ "${PROBE_PRIVILEGE:-}" = "no_sudo" ]; then
    error "This machine can't run containers without administrator rights — its kernel lacks cgroup v2 / unprivileged user namespaces, and you are neither root nor able to sudo. Ask an administrator to prepare this host once (install a container runtime + enable the kernel prerequisites), then re-run this installer as yourself. Details: docs/rfcs/0001-least-privilege-install.md"
  fi
  return 0
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

# _persist_tools_on_path — when Tier 0 dropped kubectl/k3d/helm into the user's
# ~/.local/bin, that dir usually isn't on a fresh shell's PATH, so the summary's
# suggested `kubectl …` commands fail in a NEW terminal — and because the CLI can
# live in /usr/local/bin (already on PATH), nothing else triggers a PATH fix
# either (Bugbot #375). Persist the dir to the shell rc so future terminals
# resolve the tools. Idempotent (skips if the rc already references ~/.local/bin)
# and best-effort — a PATH-persist hiccup must never fail an otherwise-good
# install. No-op unless we actually used the user-local dir (i.e. Tier 0).
_persist_tools_on_path() {
  [ "${TB_TOOLS_DIR:-}" = "${HOME}/.local/bin" ] || return 0
  # fish reads ~/.config/fish, not the POSIX rc files, and uses `set`/fish_add_path
  # rather than `export PATH=`. Appending a bash `export` line to ~/.profile would
  # be dead (fish never loads it), so hint the fish-correct command instead — it
  # persists (a universal var) AND applies to the current shell (Bugbot #375).
  if [ "$(basename "${SHELL:-sh}")" = "fish" ]; then
    hint "Add ${HOME}/.local/bin to your PATH so kubectl/k3d/helm resolve:  fish_add_path \"${HOME}/.local/bin\""
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
  hint "Added ${HOME}/.local/bin to your PATH in ${rc} — open a new terminal (or run 'source ${rc}') so kubectl/k3d/helm resolve."
}

# _install_userspace_tools — download kubectl / k3d / helm into the user's bin
# (no root: install-cli-style ~/.local/bin fallback). Shared by the Tier-0 fast
# path and the full flow so they can't drift. umask 077 (common.sh) would make
# the binaries executable only by their owner — relax to 022 for the installs.
_install_userspace_tools() {
  _set_tools_target          # RFC 0001 #1175: Tier 0 → ~/.local/bin, no sudo
  local _saved_umask
  _saved_umask=$(umask)
  umask 022
  install_kubectl
  install_k3d
  install_helm
  umask "$_saved_umask"
  _persist_tools_on_path     # RFC 0001 #1175: keep ~/.local/bin on PATH for new shells (Bugbot #375)
}

# _tier0_gpu_flags — on Tier 0 we skip the privileged GPU driver/toolkit install,
# but create_cluster still needs K3D_GPU_FLAGS to expose an NVIDIA GPU to the k3d
# cluster (--gpus=all). Without it a GPU host gets a CPU-only cluster even when the
# toolkit is already installed (Bugbot #375). Reuse the flag ONLY when Docker's
# NVIDIA runtime is already configured — expected on a GPU host with a usable
# Docker; we can't (and won't) install/configure it here without admin. Otherwise
# stay CPU-only and tell the user how to enable it. (AMD uses the device plugin
# only — no k3d flag — so it needs nothing here.)
_tier0_gpu_flags() {
  [ "${GPU_VENDOR:-none}" = "nvidia" ] || return 0
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    K3D_GPU_FLAGS=("--gpus=all")
    success "Reusing the NVIDIA container runtime already configured — your environment will have GPU access."
  else
    warn "NVIDIA GPU detected, but Docker's NVIDIA runtime isn't configured (installing the toolkit needs admin) — your environment will be CPU-only."
    hint "To enable GPU, have an admin install and configure nvidia-container-toolkit on this host, then re-run."
  fi
}

install_linux() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  _route_install_tier        # RFC 0001: honour the tier + honest fail-fast

  # ── Tier 0 — a usable container runtime already exists → ZERO privileged
  # steps (RFC 0001 #1175). Skip sudo priming, the Docker engine install, the
  # system-package + kernel-module setup, and the privileged GPU-driver install
  # entirely; just drop the user-space tools in and let create_cluster reuse the
  # runtime. The biggest unlock for shared/managed hosts (a researcher in the
  # `docker` group installs with no admin at all). We still set the k3d GPU flag
  # from the ALREADY-configured runtime (_tier0_gpu_flags) so a GPU host isn't
  # silently downgraded to a CPU-only cluster; only the privileged driver/toolkit
  # INSTALL is skipped.
  if [ "${INSTALL_TIER:-}" = "0" ]; then
    info "Using the container runtime already on this machine — no administrator rights needed."
    _install_userspace_tools
    _tier0_gpu_flags
    return 0
  fi

  # ── Tier 1/2 (or unknown / stale bootstrap) — the full privileged flow.
  preflight_sudo
  setup_pm
  apt_wait_for_lock          # don't fight apt-daily/unattended-upgrades for the lock
  install_docker_engine
  install_system_deps
  _install_userspace_tools
  dispatch_gpu_setup
}

# run_prepare_host — the standalone, admin-run Tier-2 step (RFC 0001 #1178). An
# administrator runs this ONCE (`curl … | bash -s -- prepare-host`, or
# `tracebloc prepare-host`) on a host a researcher can't install on unprivileged
# — no usable runtime — after which the researcher installs at Tier 0 with NO
# admin. It does ONLY the privileged prerequisites, reusing the exact functions
# the full install uses (install the container runtime + system deps + kernel
# modules) and then grants the researcher docker-group access. It never mints a
# credential, creates a cluster, or installs the CLI — so an admin can safely run
# it on a shared host without provisioning anything as themselves.
run_prepare_host() {
  if [[ "$OS" != "Linux" ]]; then
    error "prepare-host is for Linux hosts. On macOS/Windows, install Docker Desktop (or enable WSL2) as an administrator, then run the installer normally."
  fi
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

  step_header a "Preparing this host for tracebloc (one-time administrator step)"
  if declare -F host_audit >/dev/null 2>&1; then host_audit; fi
  echo ""

  preflight_sudo
  setup_pm
  apt_wait_for_lock
  # Prepare-host reuses the full install's engine setup, but the ADMIN must
  # never be granted the socket or sg-re-exec'd into the script (which drops
  # the prepare-host argument and runs a FULL provision) — the daemon check
  # runs via sudo instead (Bugbot on #381).
  TB_PREPARE_HOST_MODE=1
  install_docker_engine
  TB_PREPARE_HOST_MODE=""
  install_system_deps

  # Grant the researcher docker-group access so THEIR later install is Tier 0
  # (zero root). The researcher must be named EXPLICITLY via TB_PREPARE_USER — we
  # must NOT fall back to $SUDO_USER, which is the ADMIN who ran prepare-host, not
  # the researcher (adding the admin would report success while the researcher
  # still can't install; Bugbot #377). Best-effort: never fail the prep over it.
  local target="${TB_PREPARE_USER:-}"
  local granted=0
  if [[ -n "$target" && "$target" != "root" ]]; then
    if sudo usermod -aG docker "$target" 2>/dev/null; then
      success "Added ${target} to the docker group — they can now install with no admin."
      granted=1
    else
      warn "Couldn't add ${target} to the docker group; add it manually:  sudo usermod -aG docker ${target}"
    fi
  else
    hint "To let a non-admin user install at Tier 0, grant them docker-group access:"
    hint "  set TB_PREPARE_USER=<their-username> when running prepare-host, or run:  sudo usermod -aG docker <their-username>"
  fi

  echo ""
  success "Host prepared."
  # Only promise a no-admin install when a researcher actually got docker-group
  # access. Without a successful grant (no TB_PREPARE_USER, or usermod failed)
  # the user still can't reach the socket, so claiming "no administrator rights"
  # would be a lie that sends them into an install that then demands sudo
  # (Bugbot #377).
  if [[ "$granted" == 1 ]]; then
    info "The researcher can now install tracebloc with no administrator rights:"
    echo "    curl -fsSL https://tracebloc.io/i.sh | bash"
    info "(A fresh login may be needed for docker-group membership to take effect.)"
  else
    info "The container runtime and prerequisites are installed. Once a researcher"
    info "has docker-group access (see above), they can install with no admin rights:"
    echo "    curl -fsSL https://tracebloc.io/i.sh | bash"
  fi
  return 0
}
