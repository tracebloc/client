#!/usr/bin/env bash
# =============================================================================
#  setup-linux.sh — Linux prerequisites: package manager, Docker Engine,
#                   system deps, kubectl, k3d, helm, GPU dispatch
# =============================================================================

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
    sudo usermod -aG docker "$USER"
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

  if ! docker info &>/dev/null 2>&1; then
    # (a) Group not active in THIS shell yet → re-exec under the docker group.
    if [[ -z "${_K3S_INSTALL_REEXEC:-}" ]] && id -nG "$USER" 2>/dev/null | grep -qw docker; then
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
    spin_cmd "Updating package index…" $PM_UPDATE
    for pkg in "${MISSING_PKGS[@]}"; do
      spin_cmd "Installing $pkg…" $PM_INSTALL "$pkg" || \
        log "Could not install $pkg — may already be satisfied by an alternative package."
    done
    log "Dependencies installed: ${MISSING_PKGS[*]}"
  fi
  success "System dependencies"
}

# ── kubectl ──────────────────────────────────────────────────────────────────
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
  sudo mv "${tmpdir}/kubectl" /usr/local/bin/kubectl
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
install_k3d() {
  if has k3d; then
    log "k3d: $(k3d version | head -1)"
    return 0
  fi

  local k3d_script
  k3d_script="$(mktemp)"
  retry 3 5 curl -fsSL $CURL_SECURE \
    https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh -o "$k3d_script"
  chmod +x "$k3d_script"

  # Preserve PATH through sudo: the k3d install script verifies itself with
  # `command -v k3d` after copying the binary into /usr/local/bin. On RHEL-family
  # distros sudo's secure_path excludes /usr/local/bin, so that check fails and
  # the script aborts with "k3d not found". `sudo env PATH=$PATH` keeps it visible.
  if ! spin_cmd "Installing system tools…" sudo env "PATH=$PATH" bash "$k3d_script"; then
    rm -f "$k3d_script"
    error "System tool installation failed. See the install log for details."
  fi
  rm -f "$k3d_script"

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
    sudo chmod 755 "$helm_bin" 2>/dev/null || true
  fi
}

install_helm() {
  if ! has helm; then
    local helm_script
    helm_script="$(mktemp)"
    retry 3 5 curl -fsSL $CURL_SECURE \
      https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$helm_script"
    chmod +x "$helm_script"
    spin_cmd "Installing system tools…" bash "$helm_script"
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
install_linux() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  preflight_sudo
  setup_pm
  apt_wait_for_lock          # don't fight apt-daily/unattended-upgrades for the lock
  install_docker_engine
  install_system_deps

  # umask 077 (set in common.sh) would make binaries in /usr/local/bin/
  # executable only by root — relax to 022 for system tool installs
  local _saved_umask
  _saved_umask=$(umask)
  umask 022
  install_kubectl
  install_k3d
  install_helm
  umask "$_saved_umask"

  dispatch_gpu_setup
}
