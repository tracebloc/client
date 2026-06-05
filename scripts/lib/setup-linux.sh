#!/usr/bin/env bash
# =============================================================================
#  setup-linux.sh — Linux prerequisites: package manager, Docker Engine,
#                   system deps, kubectl, k3d, helm, GPU dispatch
# =============================================================================
#
# ── Progress contract: no silent op longer than a few seconds ────────────────
# Anything that can block for more than ~5s MUST stay visibly alive — either a
# spin_cmd spinner (animates while a backgrounded command runs) or an explicit
# heartbeat (see wait_apt_lock below). A blocked step with no output reads as a
# freeze and gets aborted by users. Known long ops in the install journey:
#   • apt/dnf install + index update   → spin_cmd (animated)
#   • waiting on the dpkg/apt lock      → wait_apt_lock (heartbeat, NOT a spinner;
#                                         a spinner over a blocked apt is exactly
#                                         the freeze we are fixing — see #740)
#   • Docker / k3d / helm downloads     → spin_cmd / download_with_progress
#   • container image pulls, CLI pod    → handled in cluster.sh / install-cli.sh
# Rule of thumb: if a reader can't tell a step from a hang, it needs a heartbeat.

# ── Package manager detection ────────────────────────────────────────────────
setup_pm() {
  # apt note: Ubuntu 22.04+ ships needrestart, which hooks `apt-get install` and
  # opens an interactive "restart services?" prompt that `-y` does NOT suppress.
  # Run inside spin_cmd (stdout/stderr redirected, process backgrounded) that
  # prompt is invisible and blocks reading the TTY → SIGTTIN → the install hangs
  # forever ("still pulling conntrack"). DEBIAN_FRONTEND=noninteractive +
  # NEEDRESTART_MODE=a make apt fully non-interactive; they are passed *through*
  # `sudo env` because sudo resets the environment by default.
  if   has apt-get; then PM_UPDATE="sudo apt-get update -qq";           PM_INSTALL="sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  elif has dnf;     then PM_UPDATE="sudo dnf makecache -q";             PM_INSTALL="sudo dnf install -y -q"
  elif has yum;     then PM_UPDATE="sudo yum makecache -q";             PM_INSTALL="sudo yum install -y -q"
  elif has zypper;  then PM_UPDATE="sudo zypper refresh";               PM_INSTALL="sudo zypper install -y"
  elif has pacman;  then PM_UPDATE="sudo pacman -Sy --noconfirm";       PM_INSTALL="sudo pacman -S --noconfirm"
  else error "No supported package manager found."; fi
}

# ── apt lock — wait VISIBLY instead of letting a spinner hide a blocked apt ───
# On a fresh cloud VM, unattended-upgrades / apt-daily grab the dpkg frontend
# lock for the first few minutes after boot. apt-get then silently blocks on it.
# Run under spin_cmd (output redirected, animated) the install looks frozen for
# minutes and users abort ("still pulling conntrack" — see #740). Probe the lock
# directly and surface the wait BEFORE we hand apt to the spinner.

# True (0) while ANY apt/dpkg lock is held by another process; false otherwise.
# Split out as its own function so it can be stubbed at the boundary in tests
# (the bats suite can't take a real kernel lock). Uses fuser (psmisc, present on
# Debian/Ubuntu base images); if fuser is missing we can't probe → report "free"
# so we never block on an unknowable state, and let apt's own waiting take over.
_apt_lock_held() {
  has fuser || return 1
  local f
  for f in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock; do
    # fuser exits 0 only when at least one PID has the file open. stderr carries
    # the PID list, so silence it; we only care about the exit status.
    if fuser "$f" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# Best-effort: which service is most likely holding it, for the timeout hint.
_apt_lock_holder_hint() {
  if pgrep -a unattended-upgr >/dev/null 2>&1; then echo "unattended-upgrades"
  elif pgrep -a apt          >/dev/null 2>&1;  then echo "apt-daily"
  else echo "another package manager"; fi
}

# Block until the apt lock clears or TRACEBLOC_APT_LOCK_TIMEOUT seconds elapse,
# emitting a clear message + a periodic heartbeat so it is obviously alive.
# Returns 0 if the lock cleared (or was never held), 1 on timeout. apt-only.
wait_apt_lock() {
  has apt-get || return 0          # apt path only; other PMs out of scope (#740)
  _apt_lock_held || return 0       # fast path: lock is free, say nothing

  local timeout="${TRACEBLOC_APT_LOCK_TIMEOUT:-300}"
  local interval=5 waited=0

  info "Waiting for the system package lock — unattended-upgrades can hold it for"
  hint "a few minutes on a fresh VM. This is normal; the installer is not stuck."

  while _apt_lock_held; do
    if (( waited >= timeout )); then
      local holder; holder="$(_apt_lock_holder_hint)"
      echo ""
      warn "The system package lock is still held after ${timeout}s (likely ${holder})."
      hint "Continuing anyway — apt will queue behind it. If the next step stalls,"
      hint "let the background update finish, then re-run this installer. To inspect:"
      hint "    sudo lsof /var/lib/dpkg/lock-frontend"
      hint "    systemctl status unattended-upgrades apt-daily.service 2>/dev/null"
      return 1
    fi
    # Heartbeat on the same line so the screen doesn't scroll, with an elapsed
    # counter that visibly ticks (proof of life, not a frozen spinner).
    printf "\r  ${DIM}· still waiting for the package lock… %ds${RESET}" "$waited"
    sleep "$interval"
    waited=$(( waited + interval ))
  done

  printf "\r\033[K"                 # clear the heartbeat line
  info "System package lock released — continuing."
  return 0
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

# ── Docker Engine ────────────────────────────────────────────────────────────
install_docker_engine() {
  if ! has docker; then
    if [[ -f /etc/os-release ]] && grep -qi 'amzn\|amazon' /etc/os-release; then
      if has dnf; then spin_cmd "Installing Docker…" sudo dnf install -y docker
      else              spin_cmd "Installing Docker…" sudo yum install -y docker; fi
    elif has pacman; then
      spin_cmd "Installing Docker…" sudo pacman -S --noconfirm docker
    elif has zypper; then
      spin_cmd "Installing Docker…" sudo zypper install -y docker
    elif [[ -f /etc/os-release ]] && grep -qiE '^ID="?(almalinux|rocky|ol|oracle)"?' /etc/os-release; then
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
    # Surface a held dpkg lock BEFORE the spinner hides it (apt-only no-op
    # elsewhere). Without this, a fresh-VM unattended-upgrades hold makes the
    # update/install below look frozen for minutes → users abort (#740).
    wait_apt_lock
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
