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
