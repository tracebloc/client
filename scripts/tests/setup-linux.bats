#!/usr/bin/env bats
# Tests for scripts/lib/setup-linux.sh — RHEL Docker (#719), k3d secure_path
# (#718), conntrack package name (#720), package-manager detection.
load test_helper

setup() {
  load_lib setup-linux.sh
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl conntrack"
  TEST_DISTRO=ubuntu
  USER=testuser
  PM_UPDATE="pmupdate"; PM_INSTALL="pminstall"

  has()       { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd()  { record "$*"; return 0; }
  sudo()      { record "sudo $*"; return 0; }
  systemctl() { return 0; }
  usermod()   { return 0; }
  docker()    { return 0; }   # `docker info` succeeds → skip the sg-docker re-exec
  id()        { echo "testuser docker"; }
  curl()      { record "curl $*"; return 0; }

  # macOS has no /etc/os-release, and a bash `[[ -f ]]` file-test can't be mocked
  # the way `grep` can — so install_docker_engine's amzn/RHEL-clone branches
  # short-circuited off-Linux and fell through to get.docker.com. Write a real
  # os-release fixture for $TEST_DISTRO and point the function at it via
  # TB_OS_RELEASE_FILE, so its distro detection (real `[[ -f ]]` + real `grep`)
  # is exercised on every dev host. Re-call after changing TEST_DISTRO in a test.
  write_os_release() {
    : "${TB_OS_RELEASE_FILE:=$(mktemp)}"
    case "$TEST_DISTRO" in
      amzn) printf '%s\n' 'NAME="Amazon Linux"' 'ID="amzn"'      'VERSION_ID="2023"'  ;;
      alma) printf '%s\n' 'NAME="AlmaLinux"'    'ID="almalinux"' 'VERSION_ID="9.4"'   ;;
      *)    printf '%s\n' 'NAME="Ubuntu"'        'ID=ubuntu'      'VERSION_ID="22.04"' ;;
    esac >"$TB_OS_RELEASE_FILE"
    export TB_OS_RELEASE_FILE
  }
  write_os_release   # default ($TEST_DISTRO=ubuntu); tests re-call for amzn/alma
}

# ── setup_pm ───────────────────────────────────────────────────────────────
@test "setup_pm: apt-get detected" {
  PRESENT_CMDS="apt-get"
  setup_pm
  [[ "$PM_INSTALL" == *"apt-get install"* ]]
}
# Ubuntu 22.04+ needrestart opens a hidden "restart services?" prompt under
# spin_cmd that `-y` doesn't suppress → the install hangs. apt must be fully
# non-interactive, with the env passed through `sudo env` (sudo resets env).
@test "setup_pm: apt is non-interactive (needrestart/debconf guard)" {
  PRESENT_CMDS="apt-get"
  setup_pm
  [[ "$PM_INSTALL" == *"DEBIAN_FRONTEND=noninteractive"* ]]
  [[ "$PM_INSTALL" == *"NEEDRESTART_MODE=a"* ]]
  [[ "$PM_INSTALL" == *"sudo env"* ]]
}
# apt must WAIT (bounded) for the dpkg lock instead of hanging forever behind
# apt-daily/unattended-upgrades on a freshly-booted host (#210).
@test "setup_pm: apt waits for the dpkg lock with a bounded timeout (#210)" {
  PRESENT_CMDS="apt-get"
  setup_pm
  [[ "$PM_INSTALL" == *"DPkg::Lock::Timeout="* ]]
  [[ "$PM_UPDATE"  == *"DPkg::Lock::Timeout="* ]]
}
@test "setup_pm: dnf detected" {
  PRESENT_CMDS="dnf"
  setup_pm
  [[ "$PM_INSTALL" == *"dnf install"* ]]
}
@test "setup_pm: none -> error" {
  PRESENT_CMDS=""
  run setup_pm
  [ "$status" -ne 0 ]
  [[ "$output" == *"No supported package manager"* ]]
}

# ── install_system_deps: conntrack package name (#720) ─────────────────────
@test "install_system_deps: apt uses 'conntrack'" {
  PRESENT_CMDS="apt-get curl"      # apt present, conntrack binary absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"conntrack"* ]]
  [[ "$output" != *"conntrack-tools"* ]]
}
@test "install_system_deps: dnf uses 'conntrack-tools'" {
  PRESENT_CMDS="dnf curl"          # no apt-get, conntrack binary absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"conntrack-tools"* ]]
}
@test "install_system_deps: conntrack present -> not installed" {
  PRESENT_CMDS="apt-get curl conntrack"
  run install_system_deps
  run mock_calls
  [[ "$output" != *"Installing conntrack"* ]]
}
# Caught by the cross-distro CI matrix on Amazon Linux 2023: helm's get-helm-3
# needs openssl (checksum) + tar (unpack), absent on minimal cloud images.
@test "install_system_deps: ensures openssl + tar (helm needs them on minimal images)" {
  PRESENT_CMDS="dnf curl conntrack"   # openssl + tar absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"Installing openssl"* ]]
  [[ "$output" == *"Installing tar"* ]]
}
@test "install_system_deps: openssl + tar already present -> not reinstalled" {
  PRESENT_CMDS="apt-get curl conntrack openssl tar"
  run install_system_deps
  run mock_calls
  [[ "$output" != *"Installing openssl"* ]]
  [[ "$output" != *"Installing tar"* ]]
}

# ── install_docker_engine: branch selection ────────────────────────────────
@test "install_docker_engine: Amazon Linux -> dnf docker" {
  PRESENT_CMDS="dnf"; TEST_DISTRO=amzn; write_os_release
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"dnf install -y docker"* ]]
}
@test "install_docker_engine: Arch -> pacman docker" {
  PRESENT_CMDS="pacman"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"pacman -S --noconfirm docker"* ]]
}
@test "install_docker_engine: SUSE -> zypper docker" {
  PRESENT_CMDS="zypper"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"zypper install -y docker"* ]]
}
@test "install_docker_engine: RHEL clone (#719) -> docker-ce dnf repo" {
  PRESENT_CMDS=""; TEST_DISTRO=alma; write_os_release
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"docker-ce.repo"* ]]
  [[ "$output" == *"docker-ce docker-ce-cli containerd.io"* ]]
}
@test "install_docker_engine: Debian/Ubuntu -> get.docker.com" {
  PRESENT_CMDS="curl"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"get.docker.com"* ]]
  # the convenience script runs apt-get internally → must be non-interactive too
  [[ "$output" == *"DEBIAN_FRONTEND=noninteractive"* ]]
  [[ "$output" == *"NEEDRESTART_MODE=a"* ]]
}
@test "install_docker_engine: docker already present -> no install" {
  PRESENT_CMDS="docker"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" != *"get.docker.com"* ]]
  [[ "$output" != *"docker-ce.repo"* ]]
}

# ── install_k3d: PATH preserved through sudo (#718) ────────────────────────
@test "install_k3d: installs via 'sudo env PATH=' (#718)" {
  PRESENT_CMDS="curl"
  has() {
    if [ "$1" = k3d ]; then [ -f "$BATS_TEST_TMPDIR/k3di" ]
    else case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; fi
  }
  spin_cmd() { record "$*"; touch "$BATS_TEST_TMPDIR/k3di"; return 0; }
  run install_k3d
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"sudo env"* ]]
  [[ "$output" == *"PATH="* ]]
  [[ "$output" == *"bash"* ]]
}
@test "install_k3d: already present -> skip" {
  has() { [ "$1" = k3d ]; }
  spin_cmd() { record "$*"; return 0; }
  run install_k3d
  [ "$status" -eq 0 ]
  run mock_calls
  [ -z "$output" ]
}

# ── install_docker_engine: dead daemon vs group-not-active (Asad's Alma9 case) ──
@test "install_docker_engine: daemon won't start -> Docker's error, not the group hint" {
  PRESENT_CMDS="docker"          # docker present -> skip install
  docker() { return 1; }         # docker info fails
  id() { echo "testuser"; }      # NOT in docker group -> no sg re-exec
  sudo() {
    case "$*" in *"is-active"*) return 1 ;; esac   # daemon not active
    record "sudo $*"; return 0
  }
  run install_docker_engine
  [ "$status" -ne 0 ]
  [[ "$output" == *"daemon won't start"* ]]
  [[ "$output" != *"logging out"* ]]               # the misleading group hint is NOT used
}

# Asad's root cause: minimal AlmaLinux lacks xt_addrtype -> dockerd bridge init fails.
@test "_ensure_kernel_modules: modprobes modules + installs kernel-modules on a load failure" {
  has() { [[ "$1" == "dnf" ]]; }
  sudo() { record "sudo $*"; case "$*" in *modprobe*) return 1 ;; esac; return 0; }
  spin_cmd() { record "$*"; return 0; }
  run _ensure_kernel_modules
  run mock_calls
  [[ "$output" == *"modprobe overlay"* ]]
  [[ "$output" == *"modprobe xt_addrtype"* ]]
  [[ "$output" == *"kernel-modules-"* ]]           # RHEL fallback install fired
}

# ── _configure_docker_proxy (#244: host proxy -> dockerd systemd drop-in) ────
# These tests run `sudo` as a pass-through so tee/cat/mkdir actually touch a
# temp drop-in dir (TB_DOCKER_DROPIN_DIR), letting us assert the file content.
@test "_configure_docker_proxy: no host proxy -> no drop-in written" {
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
  PRESENT_CMDS="systemctl"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  run _configure_docker_proxy
  [ "$status" -eq 0 ]
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ]
}

@test "_configure_docker_proxy: not systemd-managed -> no-op" {
  PRESENT_CMDS=""                                  # has systemctl -> false
  HTTP_PROXY="http://proxy.corp:3128"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  run _configure_docker_proxy
  [ "$status" -eq 0 ]
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ]
}

@test "_configure_docker_proxy: host proxy -> writes dockerd drop-in (HTTP/HTTPS/NO_PROXY)" {
  unset HTTPS_PROXY http_proxy https_proxy no_proxy
  PRESENT_CMDS="systemctl"
  HTTP_PROXY="http://proxy.corp:3128"; NO_PROXY="localhost,.corp"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  systemctl() { return 1; }                        # is-active false (fresh) -> no restart
  run _configure_docker_proxy
  [ "$status" -eq 0 ]
  f="$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
  [ -f "$f" ]
  grep -q 'Environment="HTTP_PROXY=http://proxy.corp:3128"' "$f"
  grep -q 'Environment="HTTPS_PROXY=http://proxy.corp:3128"' "$f"
  grep -q 'Environment="NO_PROXY=localhost,.corp"' "$f"
  grep -qF '# Managed by tracebloc installer' "$f"   # marker → safe to remove later
}

@test "_configure_docker_proxy: authenticated proxy URL preserved verbatim" {
  unset HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
  PRESENT_CMDS="systemctl"
  HTTP_PROXY="http://user:p@ss@proxy.corp:3128"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  systemctl() { return 1; }
  run _configure_docker_proxy
  grep -q 'Environment="HTTP_PROXY=http://user:p@ss@proxy.corp:3128"' "$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
}

@test "_configure_docker_proxy: idempotent -> unchanged config does not restart docker" {
  unset HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
  PRESENT_CMDS="systemctl"
  HTTP_PROXY="http://proxy.corp:3128"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  systemctl() { record "systemctl $*"; return 0; }  # is-active -> true (running)
  _configure_docker_proxy                           # 1st: writes (+restart, since active)
  : > "$MOCK_CALLS"                                 # reset records
  run _configure_docker_proxy                       # 2nd: unchanged -> early return
  run mock_calls
  [[ "$output" != *"restart docker"* ]]
}

# Bugbot #245: proxy removed since last run -> the stale drop-in we wrote must
# be deleted, else dockerd keeps pulling through a proxy that no longer exists.
@test "_configure_docker_proxy: host proxy removed -> deletes our stale drop-in" {
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
  PRESENT_CMDS="systemctl"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  mkdir -p "$TB_DOCKER_DROPIN_DIR"
  printf '# Managed by tracebloc installer (#244)\n[Service]\nEnvironment="HTTP_PROXY=http://old:3128"\n' \
    > "$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
  sudo() { "$@"; }
  systemctl() { return 1; }                         # not active -> no restart
  run _configure_docker_proxy
  [ "$status" -eq 0 ]
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ]  # ours -> removed
}

@test "_configure_docker_proxy: host proxy removed -> leaves a foreign drop-in untouched" {
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
  PRESENT_CMDS="systemctl"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  mkdir -p "$TB_DOCKER_DROPIN_DIR"
  printf '[Service]\nEnvironment="HTTP_PROXY=http://it-managed:3128"\n' \
    > "$TB_DOCKER_DROPIN_DIR/http-proxy.conf"      # no tracebloc marker
  sudo() { "$@"; }
  run _configure_docker_proxy
  [ "$status" -eq 0 ]
  [ -f "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ]   # NOT ours -> left alone
  grep -q 'it-managed' "$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
}

# ── _route_install_tier (RFC 0001 #1172) ─────────────────────────────────────
@test "_route_install_tier: Tier 2 + no sudo => actionable fail-fast" {
  INSTALL_TIER=2; PROBE_PRIVILEGE=no_sudo
  run _route_install_tier
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF "administrator rights"
  printf '%s\n' "$output" | grep -qF "prepare this host"
}

@test "_route_install_tier: Tier 2 + root => proceeds (root can install a runtime)" {
  INSTALL_TIER=2; PROBE_PRIVILEGE=root
  run _route_install_tier
  [ "$status" -eq 0 ]
}

@test "_route_install_tier: Tier 0 + no sudo => proceeds (runtime already usable)" {
  INSTALL_TIER=0; PROBE_PRIVILEGE=no_sudo
  run _route_install_tier
  [ "$status" -eq 0 ]
}

@test "_route_install_tier: unset tier (stale bootstrap) => proceeds as before" {
  unset INSTALL_TIER PROBE_PRIVILEGE
  run _route_install_tier
  [ "$status" -eq 0 ]
}

@test "_route_install_tier: TB_FORCE_TIER overrides the detected tier" {
  INSTALL_TIER=0; PROBE_PRIVILEGE=no_sudo; TB_FORCE_TIER=2
  run _route_install_tier
  [ "$status" -ne 0 ]           # forced to Tier 2 + no_sudo => fail-fast
  printf '%s\n' "$output" | grep -qF "administrator rights"
}
