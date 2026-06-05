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
  # Simulate /etc/os-release matching per TEST_DISTRO; delegate other greps.
  grep() {
    if [[ "$*" == *"/etc/os-release"* ]]; then
      case "$TEST_DISTRO" in
        amzn) [[ "$*" == *amzn* ]] ;;
        alma) [[ "$*" == *almalinux* ]] ;;
        *)    return 1 ;;
      esac
      return
    fi
    command grep "$@"
  }
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
  PRESENT_CMDS="dnf"; TEST_DISTRO=amzn
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
  PRESENT_CMDS=""; TEST_DISTRO=alma
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

# ── wait_apt_lock: visible wait on a held dpkg lock (#740) ─────────────────
# A fresh-VM unattended-upgrades hold makes apt block silently under the
# spinner → perceived freeze → users abort. wait_apt_lock surfaces the wait
# with a heartbeat and is bounded (proceed-or-timeout), never an infinite spin.
#
# The bats sandbox can't take a real kernel lock, so we mock at the function
# boundary: _apt_lock_held is the single lock probe, and we make it report
# "held" for the first N calls then "free" (simulating unattended-upgrades
# releasing the lock). `sleep` is stubbed so the loop doesn't actually wait.

# (a) lock clears after a few probes → emits wait message, then proceeds.
@test "wait_apt_lock: held lock emits a visible wait, then proceeds when it clears" {
  PRESENT_CMDS="apt-get"
  sleep() { :; }                         # don't actually wait between probes
  # locked for the first 2 probes, free afterwards
  _LOCK_PROBES=0
  _apt_lock_held() { _LOCK_PROBES=$((_LOCK_PROBES + 1)); [ "$_LOCK_PROBES" -le 2 ]; }
  run wait_apt_lock
  [ "$status" -eq 0 ]                     # proceeded (lock cleared)
  [[ "$output" == *"Waiting for the system package lock"* ]]   # (a) wait message
  [[ "$output" == *"released"* ]]         # (b) noticed it cleared and continued
}

# (b) lock NEVER clears → bounded timeout: warns with guidance, returns 1,
# does NOT loop forever. Tiny timeout keeps the test instant.
@test "wait_apt_lock: never-clearing lock times out cleanly (no infinite spin)" {
  PRESENT_CMDS="apt-get"
  sleep() { :; }
  _apt_lock_held() { return 0; }          # held forever
  pgrep() { return 1; }                    # holder-hint probe: generic fallback
  TRACEBLOC_APT_LOCK_TIMEOUT=10            # short bound for the test
  run wait_apt_lock
  [ "$status" -eq 1 ]                       # timed out (did not hang)
  [[ "$output" == *"still held after 10s"* ]]
  [[ "$output" == *"re-run this installer"* ]]   # actionable guidance
}

# (c) lock free from the start → completely silent fast-path (no noise on the
# common case where nothing holds the lock).
@test "wait_apt_lock: free lock is a silent no-op" {
  PRESENT_CMDS="apt-get"
  _apt_lock_held() { return 1; }           # never held
  run wait_apt_lock
  [ "$status" -eq 0 ]
  [ -z "$output" ]                         # nothing printed
}

# (d) non-apt package manager → no-op (scope is apt-only, #740). Even if a lock
# probe WOULD report held, dnf/yum/etc. must not wait on the apt lock.
@test "wait_apt_lock: non-apt distro skips the apt lock wait entirely" {
  PRESENT_CMDS="dnf"                       # apt-get absent
  _apt_lock_held() { return 0; }           # would block IF it were ever probed
  run wait_apt_lock
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# install_system_deps must run the lock wait BEFORE the spinner that would
# otherwise hide a blocked apt. Assert the wait fires (apt path, lock held once).
@test "install_system_deps: waits on the apt lock before the install spinner (#740)" {
  PRESENT_CMDS="apt-get curl"             # apt present, conntrack missing → installs
  sleep() { :; }
  _LOCK_PROBES=0
  _apt_lock_held() { _LOCK_PROBES=$((_LOCK_PROBES + 1)); [ "$_LOCK_PROBES" -le 1 ]; }
  run install_system_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"Waiting for the system package lock"* ]]
}

# _apt_lock_held: with no fuser available we cannot probe → report "free" so we
# never block on an unknowable state (apt's own waiting then takes over).
@test "_apt_lock_held: no fuser -> reports free (does not block)" {
  has() { [ "$1" != fuser ]; }            # everything present except fuser
  run _apt_lock_held
  [ "$status" -ne 0 ]                       # "free" (non-zero = lock not held)
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
