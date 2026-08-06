#!/usr/bin/env bats
# Tests for scripts/lib/setup-linux.sh — RHEL Docker (#719), k3d secure_path
# (#718), conntrack package name (#720), package-manager detection.
load test_helper

setup() {
  load_lib setup-linux.sh
  # Fetch-test curl mocks write tiny fixture files; relax the #607 size floor
  # so _assert_download_size does not reject them (real floor applies in prod).
  export TB_MIN_DOWNLOAD_BYTES=0
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl conntrack"
  TEST_DISTRO=ubuntu
  USER=testuser
  PM_UPDATE="pmupdate"; PM_INSTALL="pminstall"

  has()       { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd()  { record "$*"; return 0; }
  # Same default as spin_cmd: record + succeed. Tests that need the deadline
  # semantics (rc 124) override it locally.
  spin_cmd_bounded() { record "spin_cmd_bounded $*"; return 0; }
  sudo()      { record "sudo $*"; return 0; }
  systemctl() { return 0; }
  usermod()   { return 0; }
  docker()    { return 0; }   # `docker info` succeeds → skip the sg-docker re-exec
  id()        { echo "testuser docker"; }
  curl()      { record "curl $*"; return 0; }

  # The execute-gate (#411) runs `<tool> version` after install, so the tool mocks
  # must be RUNNABLE, not merely "present" via has(). Silent (no record) so the
  # mock_calls assertions stay about the install/fetch, not the gate's probe — and
  # so these shadow any real tool on the dev host (the toolless CI runner has none).
  k3d()       { echo "k3d version v5.9.0"; }
  kubectl()   { echo "Client Version: v1.29.4"; }
  helm()      { echo "v4.2.3"; }

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
  [[ "$PM_INSTALL" == *"apt-get install"* ]] || return 1
}
# Ubuntu 22.04+ needrestart opens a hidden "restart services?" prompt under
# spin_cmd that `-y` doesn't suppress → the install hangs. apt must be fully
# non-interactive, with the env passed through `sudo env` (sudo resets env).
@test "setup_pm: apt is non-interactive (needrestart/debconf guard)" {
  PRESENT_CMDS="apt-get"
  setup_pm
  [[ "$PM_INSTALL" == *"DEBIAN_FRONTEND=noninteractive"* ]] || return 1
  [[ "$PM_INSTALL" == *"NEEDRESTART_MODE=a"* ]] || return 1
  [[ "$PM_INSTALL" == *"sudo env"* ]] || return 1
}
# apt must WAIT (bounded) for the dpkg lock instead of hanging forever behind
# apt-daily/unattended-upgrades on a freshly-booted host (#210).
@test "setup_pm: apt waits for the dpkg lock with a bounded timeout (#210)" {
  PRESENT_CMDS="apt-get"
  setup_pm
  [[ "$PM_INSTALL" == *"DPkg::Lock::Timeout="* ]] || return 1
  [[ "$PM_UPDATE"  == *"DPkg::Lock::Timeout="* ]] || return 1
}
@test "setup_pm: dnf detected" {
  PRESENT_CMDS="dnf"
  setup_pm
  [[ "$PM_INSTALL" == *"dnf install"* ]] || return 1
}
@test "setup_pm: none -> error" {
  PRESENT_CMDS=""
  run setup_pm
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"No supported package manager"* ]] || return 1
}

# ── install_system_deps: conntrack package name (#720) ─────────────────────
@test "install_system_deps: apt uses 'conntrack'" {
  PRESENT_CMDS="apt-get curl"      # apt present, conntrack binary absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"conntrack"* ]] || return 1
  [[ "$output" != *"conntrack-tools"* ]] || return 1
}
@test "install_system_deps: dnf uses 'conntrack-tools'" {
  PRESENT_CMDS="dnf curl"          # no apt-get, conntrack binary absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"conntrack-tools"* ]] || return 1
}
@test "install_system_deps: conntrack present -> not installed" {
  PRESENT_CMDS="apt-get curl conntrack"
  run install_system_deps
  run mock_calls
  [[ "$output" != *"Installing conntrack"* ]] || return 1
}
# Caught by the cross-distro CI matrix on Amazon Linux 2023: the Helm tarball
# needs tar + gzip to unpack, absent on minimal cloud images. openssl is no
# longer a dependency — the Helm download verifies with sha256sum since
# get-helm-3 was replaced by a direct fetch (#395).
@test "install_system_deps: ensures tar + gzip (helm unpack on minimal images), NOT openssl (#395)" {
  PRESENT_CMDS="dnf curl conntrack"   # tar + gzip absent
  run install_system_deps
  run mock_calls
  [[ "$output" == *"Installing tar"* ]] || return 1
  [[ "$output" == *"Installing gzip"* ]] || return 1
  [[ "$output" != *"Installing openssl"* ]] || return 1
}
@test "install_system_deps: tar + gzip already present -> not reinstalled" {
  PRESENT_CMDS="apt-get curl conntrack tar gzip"
  run install_system_deps
  run mock_calls
  [[ "$output" != *"Installing tar"* ]] || return 1
  [[ "$output" != *"Installing gzip"* ]] || return 1
}

# _ensure_helm_prereqs was removed with get-helm-3 (Bugbot #396): Helm no longer
# needs openssl, and tar/gzip are installed Tier-0-aware by _ensure_unpack_tools
# (covered by its own tests above), so the old fail-fast preflight is gone.

# ── install_docker_engine: branch selection ────────────────────────────────
@test "install_docker_engine: Amazon Linux -> dnf docker" {
  PRESENT_CMDS="dnf"; TEST_DISTRO=amzn; write_os_release
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"dnf install -y docker"* ]] || return 1
}
@test "install_docker_engine: Arch -> pacman docker" {
  PRESENT_CMDS="pacman"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"pacman -S --noconfirm docker"* ]] || return 1
}
@test "install_docker_engine: SUSE -> zypper docker" {
  PRESENT_CMDS="zypper"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"zypper install -y docker"* ]] || return 1
}
@test "install_docker_engine: RHEL clone (#719) -> docker-ce dnf repo" {
  PRESENT_CMDS=""; TEST_DISTRO=alma; write_os_release
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"docker-ce.repo"* ]] || return 1
  [[ "$output" == *"docker-ce docker-ce-cli containerd.io"* ]] || return 1
}
@test "install_docker_engine: Debian/Ubuntu -> get.docker.com" {
  PRESENT_CMDS="curl"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"get.docker.com"* ]] || return 1
  # the convenience script runs apt-get internally → must be non-interactive too
  [[ "$output" == *"DEBIAN_FRONTEND=noninteractive"* ]] || return 1
  [[ "$output" == *"NEEDRESTART_MODE=a"* ]] || return 1
}
# The get.docker.com script's internal apt/download.docker.com fetches carry no
# timeout of their own, so a stalled connection hung "Installing Docker…"
# silently until something else killed the process — in CI the 20-minute job
# timeout, three times on 2026-08-04 (#525/#592). The run must be bounded so a
# stall fails in minutes with a clear message instead.
@test "install_docker_engine: get.docker.com run is bounded with timeout (CI hang 2026-08-04)" {
  PRESENT_CMDS="curl"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" == *"spin_cmd_bounded 600 "* ]] || return 1
}

@test "install_docker_engine: docker already present -> no install" {
  PRESENT_CMDS="docker"; TEST_DISTRO=ubuntu
  run install_docker_engine
  run mock_calls
  [[ "$output" != *"get.docker.com"* ]] || return 1
  [[ "$output" != *"docker-ce.repo"* ]] || return 1
}

# ── install_docker_engine under prepare-host (#381 Bugbot) ───────────────────
# The admin runs prepare-host with sudo but no docker-group membership. The
# engine gate must verify the DAEMON via sudo and never (a) sg-re-exec — that
# re-runs the script WITHOUT the prepare-host argument, i.e. a silent FULL
# provision — nor (b) abort on the admin's unreachable non-root socket, nor
# (c) grant the ADMIN the socket (only TB_PREPARE_USER gets it, later).
@test "install_docker_engine: prepare-host mode verifies via sudo, no sg re-exec, exits 0 (#381)" {
  PRESENT_CMDS="curl docker"; TEST_DISTRO=ubuntu
  TB_PREPARE_HOST_MODE=1
  docker() { return 1; }                          # admin's non-root socket: unreachable
  sudo()   { record "sudo $*"; return 0; }        # sudo docker info succeeds
  sg()     { record "sg $*"; exit 97; }           # the escape this test forbids
  id()     { echo "admin docker"; }               # even WITH membership visible…
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"sudo docker info"* ]] || return 1
  [[ "$output" == *"systemctl enable docker"* ]] || return 1  # boot-enable survives a reboot (r5)
  [[ "$output" != *"sg "* ]] || return 1                      # …no re-exec ever fires
  TB_PREPARE_HOST_MODE=""
}

@test "install_docker_engine: prepare-host + active daemon that won't answer -> terminal error, no logout advice (#381)" {
  PRESENT_CMDS="curl docker"; TEST_DISTRO=ubuntu
  TB_PREPARE_HOST_MODE=1
  docker() { return 1; }
  sudo()   { record "sudo $*"
    case "$*" in
      "docker info") return 1 ;;          # even sudo can't reach it
      *is-active*)   return 0 ;;          # …but the daemon claims active
      *) return 0 ;;
    esac
  }
  sg() { record "sg $*"; exit 97; }
  run install_docker_engine
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"re-run prepare-host"* ]] || return 1
  [[ "$output" != *"logging out and back in"* ]] || return 1
  TB_PREPARE_HOST_MODE=""
}

@test "install_docker_engine: prepare-host + daemon down -> starts it via sudo, exits 0 (#381 r3)" {
  PRESENT_CMDS="curl docker"; TEST_DISTRO=ubuntu
  TB_PREPARE_HOST_MODE=1
  docker() { return 1; }
  STARTED_FLAG="$BATS_TEST_TMPDIR/docker-started"
  sudo() { record "sudo $*"
    case "$*" in
      "docker info")           if [ -f "$STARTED_FLAG" ]; then return 0; else return 1; fi ;;
      *"enable --now docker"*) touch "$STARTED_FLAG"; return 0 ;;
      *is-active*)             return 1 ;;
      *) return 0 ;;
    esac
  }
  sg() { record "sg $*"; exit 97; }
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"enable --now docker"* ]] || return 1
  TB_PREPARE_HOST_MODE=""
}

# A daemon that won't start must stay terminal in PREPARE-HOST wording: the
# shared diagnostics end with "re-run this installer", which for the admin
# means a full provision as themselves — the outcome prepare-host exists to
# prevent (Bugbot r3).
@test "install_docker_engine: prepare-host + daemon won't start -> terminal, says re-run prepare-host (#381 r3)" {
  PRESENT_CMDS="curl docker"; TEST_DISTRO=ubuntu
  TB_PREPARE_HOST_MODE=1
  docker() { return 1; }
  sudo() { record "sudo $*"
    case "$*" in
      "docker info") return 1 ;;
      *is-active*)   return 1 ;;
      # Real `systemctl status` exits 3 for an inactive unit — the diagnostics
      # pipeline must swallow that (|| true) or set -e kills the script before
      # the re-run guidance ever prints (Bugbot r6).
      *"systemctl status"*) echo "docker.service: inactive (dead)"; return 3 ;;
      *) return 0 ;;
    esac
  }
  sg() { record "sg $*"; exit 97; }
  run install_docker_engine
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"re-run prepare-host"* ]] || return 1
  [[ "$output" != *"re-run this installer"* ]] || return 1
  [[ "$output" != *"logging out and back in"* ]] || return 1
  TB_PREPARE_HOST_MODE=""
}

@test "install_docker_engine: prepare-host mode skips the admin group-add on fresh install (#381)" {
  PRESENT_CMDS="curl"; TEST_DISTRO=ubuntu         # docker absent -> install branch
  TB_PREPARE_HOST_MODE=1
  docker() { return 1; }
  sudo()   { record "sudo $*"; return 0; }
  sg()     { record "sg $*"; exit 97; }
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"usermod -aG docker"* ]] || return 1       # the ADMIN is never granted the socket
  TB_PREPARE_HOST_MODE=""
}

# ── _fetch_kubectl: the ~50 MB binary must be stall-bounded ────────────────
# curl_secure supplies a default --max-time, and only steps aside when it SEES
# --speed-limit/--speed-time — so a large-binary fetch has to carry those flags at
# the call site or it inherits a hard deadline that fails a slow-but-healthy link
# (Bugbot on backend#1252; same reasoning as _fetch_k3d_release below).
@test "_fetch_kubectl: stall-bounded with no hard deadline (large binary)" {
  TB_TOOLS_DIR="$BATS_TEST_TMPDIR/bin"; TB_TOOLS_SUDO=""
  mkdir -p "$TB_TOOLS_DIR"
  curl() {                      # honour "-o <dest>" so the real chmod/mv succeed
    record "curl $*"
    local prev="" a
    for a in "$@"; do [ "$prev" = "-o" ] && printf 'x' >"$a"; prev="$a"; done
    return 0
  }
  sha256sum() { cat >/dev/null; return 0; }
  run _fetch_kubectl v1.29.4 amd64
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"--speed-limit 1024 --speed-time 60"* ]] || return 1
  [[ "$output" != *"--max-time"* ]] || return 1
  [[ "$output" == *"--tlsv1.2"* ]] || return 1
}

# retry emits its attempt notices on STDOUT, so a failed-then-successful
# stable.txt fetch used to concatenate the notice into KUBE_VER, corrupting the
# download URL. install_kubectl must isolate the clean version (Bugbot r3655543170).
@test "install_kubectl: retry notices on stdout do not pollute the captured version" {
  PRESENT_CMDS="curl"            # kubectl absent -> install path runs
  ARCH_DL=amd64
  retry()       { shift 2; "$@"; }   # passthrough: drop max_attempts + delay
  curl_secure() { printf '%s\n' "Attempt 1/3 failed. Retrying in 5s..." "v1.29.4"; }
  install_kubectl
  # spin_cmd (default mock) records "_fetch_kubectl <ver> <arch>" — the version
  # must be the clean token, not the retry notice.
  run mock_calls
  [[ "$output" == *"_fetch_kubectl v1.29.4 amd64"* ]] || return 1
  [[ "$output" != *"Retrying"* ]] || return 1
}

@test "install_kubectl: unresolvable version (only a retry notice) fails closed, no bad fetch" {
  PRESENT_CMDS="curl"
  ARCH_DL=amd64
  retry()       { shift 2; "$@"; }
  curl_secure() { printf '%s\n' "Command failed after 3 attempts: curl_secure"; }  # no version line
  run install_kubectl
  [ "$status" -ne 0 ] || return 1                       # regex rejects the notice -> error, not a broken URL
  run mock_calls
  [[ "$output" != *"_fetch_kubectl"* ]] || return 1
}

# ── install_k3d: pinned release, verified direct download (#382) ────────────
# The binary is fetched straight from the pinned release and verified against
# the release's checksums.txt — upstream's install.sh is NOT used (it performs
# no checksum verification, and its releases/latest lookup 404s under GitHub
# rate limiting on shared egress IPs; 2/9 distro CI jobs, 2026-07-21).
#
# Shared scaffolding: spin_cmd executes its command (so _fetch_k3d_release
# really runs); curl honors "-o <dest>" and writes fixtures; sha256sum is
# stubbed (SHA_RC) so no real hashing is needed.
_k3d_dl_setup() {
  PRESENT_CMDS="curl"
  ARCH_DL="amd64"
  TB_TOOLS_DIR="$BATS_TEST_TMPDIR/bin"; TB_TOOLS_SUDO=""
  mkdir -p "$TB_TOOLS_DIR"
  has() {
    if [ "$1" = k3d ]; then [ -f "$TB_TOOLS_DIR/k3d" ]
    else case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; fi
  }
  spin_cmd() { record "spin_cmd $*"; local _m="$1"; shift; "$@"; }
  sha256sum() { record "sha256sum $*"; cat >/dev/null; return "${SHA_RC:-0}"; }
  curl() {
    record "curl $*"
    local prev="" a out="" url=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      case "$a" in http*) url="$a" ;; esac
      prev="$a"
    done
    case "$url" in
      */checksums.txt)  [ -n "$out" ] && printf '%s  _dist/k3d-linux-amd64\n' "${CHECKSUM_LINE_SHA:-cafe01}" >"$out" ;;
      */k3d-linux-*)    [ -n "$out" ] && printf 'k3d-binary-bytes' >"$out" ;;
      */releases/latest) printf 'https://github.com/k3d-io/k3d/releases/tag/v9.9.9' ;;
    esac
    return 0
  }
}
@test "install_k3d: default pin -> verified direct download, no upstream script" {
  _k3d_dl_setup
  run install_k3d
  [ "$status" -eq 0 ] || return 1
  [ -f "$TB_TOOLS_DIR/k3d" ] || return 1                                   # installed where we said
  run mock_calls
  [[ "$output" == *"releases/download/${K3D_VERSION}/k3d-linux-amd64"* ]] || return 1
  [[ "$output" == *"releases/download/${K3D_VERSION}/checksums.txt"* ]] || return 1
  [[ "$output" == *"sha256sum --check"* ]] || return 1                     # verification ran
  [[ "$output" != *"install.sh"* ]] || return 1                            # upstream script gone
  [[ "$output" != *"releases/latest"* ]] || return 1                       # pinned path never resolves
}
@test "install_k3d: checksum mismatch fails closed, nothing installed (#382)" {
  _k3d_dl_setup
  SHA_RC=1
  run install_k3d
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"checksum verification failed"* ]] || return 1
  [ ! -f "$TB_TOOLS_DIR/k3d" ] || return 1
}
@test "install_k3d: asset missing from checksums.txt fails closed (#382)" {
  _k3d_dl_setup
  ARCH_DL="arm64"    # fixture checksums.txt only lists amd64 -> no matching line
  run install_k3d
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"checksum verification failed"* ]] || return 1
  [ ! -f "$TB_TOOLS_DIR/k3d" ] || return 1
}
@test "install_k3d: system path installs via sudo mv" {
  _k3d_dl_setup
  TB_TOOLS_SUDO="sudo"
  sudo() { record "sudo $*"; "$@"; }
  run install_k3d
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"sudo mv"* ]] || return 1
  [[ "$output" == *"$TB_TOOLS_DIR/k3d"* ]] || return 1
}
@test "install_k3d: K3D_VERSION=latest resolves the tag, then the same verified path" {
  _k3d_dl_setup
  K3D_VERSION=latest
  run install_k3d
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"releases/latest"* ]] || return 1                            # resolve-at-install-time
  [[ "$output" == *"releases/download/v9.9.9/k3d-linux-amd64"* ]] || return 1   # resolved tag used
  [[ "$output" == *"releases/download/v9.9.9/checksums.txt"* ]] || return 1     # still verified
  [[ "$output" != *"install.sh"* ]] || return 1
}
@test "install_k3d: malformed K3D_VERSION fails closed before any fetch (Bugbot r1)" {
  PRESENT_CMDS="curl"
  K3D_VERSION="../../evil/repo/main"    # would traverse out of k3d-io/k3d in the URL
  has() { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd() { record "$*"; return 0; }
  run install_k3d
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"K3D_VERSION must be a k3d release tag"* ]] || return 1
  run mock_calls
  [ -z "$output" ] || return 1                      # no curl, no spin_cmd — nothing ran
}

@test "install_k3d: already present -> skip" {
  has() { [ "$1" = k3d ]; }
  spin_cmd() { record "$*"; return 0; }
  run install_k3d
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [ -z "$output" ] || return 1
}

# ── install_helm: pinned release, verified direct download (#395) ────────────
# The tarball is fetched straight from get.helm.sh and verified against its
# published .sha256sum — helm's get-helm-3 is NOT used (it floats on the
# mutable helm/helm@main, performs its checksum step with openssl, and minimal
# cloud images ship no openssl — Bugbot #383). Mirrors the install_k3d suite.
_helm_dl_setup() {
  PRESENT_CMDS="curl tar gzip"
  ARCH_DL="amd64"
  TB_TOOLS_DIR="$BATS_TEST_TMPDIR/bin"; TB_TOOLS_SUDO=""
  mkdir -p "$TB_TOOLS_DIR"
  has() {
    if [ "$1" = helm ]; then [ -f "$TB_TOOLS_DIR/helm" ]
    else case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; fi
  }
  spin_cmd() { record "spin_cmd $*"; local _m="$1"; shift; "$@"; }
  sha256sum() { record "sha256sum $*"; return "${SHA_RC:-0}"; }
  # The real code runs `tar -xzf <tarball> -C <dir> linux-amd64/helm`; the stub
  # materialises exactly that extraction result.
  tar() {
    record "tar $*"
    local prev="" a dest=""
    for a in "$@"; do [ "$prev" = "-C" ] && dest="$a"; prev="$a"; done
    mkdir -p "$dest/linux-${ARCH_DL}" && printf 'helm-binary' > "$dest/linux-${ARCH_DL}/helm"
  }
  curl() {
    record "curl $*"
    local prev="" a out="" url=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      case "$a" in http*) url="$a" ;; esac
      prev="$a"
    done
    case "$url" in
      *.tar.gz.sha256sum)     [ -n "$out" ] && printf '%s  %s\n' "${CHECKSUM_LINE_SHA:-cafe01}" "$(basename "${url%.sha256sum}")" >"$out" ;;
      *.tar.gz)               [ -n "$out" ] && printf 'helm-tarball-bytes' >"$out" ;;
      *helm-latest-version)   printf 'v9.9.9' ;;
    esac
    return 0
  }
}
@test "install_helm: default pin -> verified direct download, no get-helm-3 (#395)" {
  _helm_dl_setup
  run install_helm
  [ "$status" -eq 0 ] || return 1
  [ -f "$TB_TOOLS_DIR/helm" ] || return 1                                     # installed where we said
  run mock_calls
  [[ "$output" == *"get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"* ]] || return 1
  [[ "$output" == *"get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"* ]] || return 1
  [[ "$output" == *"sha256sum --check"* ]] || return 1                        # verification ran
  [[ "$output" != *"get-helm-3"* ]] || return 1                               # upstream script gone
  [[ "$output" != *"raw.githubusercontent.com"* ]] || return 1
  [[ "$output" != *"helm-latest-version"* ]] || return 1                      # pinned path never resolves
}
@test "install_helm: checksum mismatch fails closed, nothing installed (#395)" {
  _helm_dl_setup
  SHA_RC=1
  run install_helm
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"checksum verification failed"* ]] || return 1
  [ ! -f "$TB_TOOLS_DIR/helm" ] || return 1
}
@test "install_helm: system path installs via sudo mv" {
  _helm_dl_setup
  TB_TOOLS_SUDO="sudo"
  sudo() { record "sudo $*"; "$@"; }
  run install_helm
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"sudo mv"* ]] || return 1
  [[ "$output" == *"$TB_TOOLS_DIR/helm"* ]] || return 1
}
@test "install_helm: HELM_VERSION=latest resolves the tag, then the same verified path" {
  _helm_dl_setup
  HELM_VERSION=latest
  run install_helm
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"helm-latest-version"* ]] || return 1                          # resolve-at-install-time
  [[ "$output" == *"get.helm.sh/helm-v9.9.9-linux-amd64.tar.gz"* ]] || return 1   # resolved tag used
  [[ "$output" == *"helm-v9.9.9-linux-amd64.tar.gz.sha256sum"* ]] || return 1     # still verified
}
@test "install_helm: malformed HELM_VERSION fails closed before any fetch (#395)" {
  PRESENT_CMDS="curl tar gzip"
  HELM_VERSION="../../evil/path"        # would traverse out of get.helm.sh's release namespace
  has() { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd() { record "$*"; return 0; }
  run install_helm
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"HELM_VERSION must be a Helm release tag"* ]] || return 1
  run mock_calls
  [ -z "$output" ] || return 1                      # no curl, no spin_cmd — nothing ran
}
@test "install_helm: already present -> skip" {
  has() { [ "$1" = helm ]; }
  spin_cmd() { record "$*"; return 0; }
  run install_helm
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [ -z "$output" ] || return 1
}

# ── _ensure_unpack_tools: the installer installs tar/gzip itself (#395) ──────
# Tier 0 skips install_system_deps, so when the Helm unpack tools are missing
# we install them via the package manager rather than telling the user to —
# quietly with root/passwordless sudo, with an honest one-line reason when a
# password is needed, and an error ONLY when we truly can't get rights.
@test "_ensure_unpack_tools: tar + gzip present -> silent no-op" {
  PRESENT_CMDS="curl apt-get tar gzip"
  run _ensure_unpack_tools
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [ -z "$output" ] || return 1
}
@test "_ensure_unpack_tools: missing + passwordless sudo -> ONE combined install via the package manager (#395)" {
  PRESENT_CMDS="curl apt-get"           # tar + gzip absent
  # Option-led probes go through _real_sudo (the A2 shadow mangles them as
  # root) — stub the primitive, not the shadow (Bugbot #372 pattern).
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "_real_sudo $*"; return 0; }   # -n probe succeeds → quiet path
  run _ensure_unpack_tools
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  # One combined install call — a single sudo consumer (Bugbot r2), both pkgs on it.
  [[ "$output" == *"Installing tar gzip"* ]] || return 1
  [[ "$output" == *"apt-get install"*"tar gzip"* ]] || return 1
}
@test "_ensure_unpack_tools: password path primes sudo, waits out the dpkg lock, then installs (Bugbot r2)" {
  PRESENT_CMDS="curl apt-get fuser"     # tar + gzip absent; fuser present → lock wait live
  _have_sudo_bin() { return 0; }
  # -n fails (no cached ticket) → prompt path; -v succeeds; the keepalive loop's
  # own -n probes also fail, so it exits immediately (no stray child in bats).
  _real_sudo() { record "_real_sudo $*"; case "$1" in -v) return 0 ;; *) return 1 ;; esac; }
  apt_wait_for_lock() { record "apt_wait_for_lock"; }
  run _ensure_unpack_tools
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"_real_sudo -v"* ]] || return 1              # primed before any spinner
  [[ "$output" == *"apt_wait_for_lock"* ]] || return 1          # lock wait not skipped on Tier 0
  [[ "$output" == *"Installing tar gzip"* ]] || return 1
}
@test "_ensure_unpack_tools: no sudo rights -> honest error, names the packages" {
  PRESENT_CMDS="curl apt-get"           # tar + gzip absent
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "_real_sudo $*"; return 1; }   # -n probe AND -v both fail
  run _ensure_unpack_tools
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"administrator"* ]] || return 1
  [[ "$output" == *"tar"* ]] || return 1
}
@test "_ensure_unpack_tools: not root and no sudo binary -> honest error before any prompt" {
  PRESENT_CMDS="curl apt-get"           # tar + gzip absent
  _have_sudo_bin() { return 1; }                        # no sudo on the machine at all
  _real_sudo() { record "_real_sudo $*"; return 127; }
  run _ensure_unpack_tools
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no sudo"* ]] || return 1
  [[ "$output" == *"tar"* ]] || return 1
}
@test "_ensure_unpack_tools: never kills a preflight keepalive (Bugbot r3)" {
  PRESENT_CMDS="curl apt-get"           # tar + gzip absent (Tier 1/2 recovery case)
  SUDO_KEEPALIVE_PID=99999              # preflight_sudo's keepalive owns the global
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "_real_sudo $*"; return 0; }   # ticket cached → quiet path
  kill() { record "kill $*"; }
  run _ensure_unpack_tools
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"kill 99999"* ]] || return 1     # preflight's warm ticket left alone
}
@test "install_helm: HELM_VERSION=latest survives retry notices on stdout (Bugbot r3)" {
  _helm_dl_setup
  HELM_VERSION=latest
  # First helm-latest-version fetch fails -> the REAL retry warns on stdout
  # inside the command substitution; the resolver must still isolate the body.
  _lv_attempts="$BATS_TEST_TMPDIR/lv-attempts"
  curl() {
    record "curl $*"
    local prev="" a out="" url=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      case "$a" in http*) url="$a" ;; esac
      prev="$a"
    done
    case "$url" in
      *helm-latest-version)
        local n; n="$(cat "$_lv_attempts" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" >"$_lv_attempts"
        if [ "$n" -lt 2 ]; then return 22; fi
        printf 'v9.9.9' ;;
      *.tar.gz.sha256sum)   [ -n "$out" ] && printf '%s  %s\n' "cafe01" "$(basename "${url%.sha256sum}")" >"$out" ;;
      *.tar.gz)             [ -n "$out" ] && printf 'helm-tarball-bytes' >"$out" ;;
    esac
    return 0
  }
  retry() { local m="$1" d="$2"; shift 2
    local i=1
    while true; do
      if "$@"; then return 0; fi
      [ "$i" -ge "$m" ] && { warn "Command failed after $m attempts: $*"; return 1; }
      warn "Attempt $i/$m failed. Retrying in ${d}s..."   # STDOUT, like common.sh
      i=$((i+1))
    done
  }
  run install_helm
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"get.helm.sh/helm-v9.9.9-linux-amd64.tar.gz"* ]] || return 1   # clean tag despite the notice
}

@test "_ensure_unpack_tools: package install fails -> fatal (helm can't unpack without it)" {
  PRESENT_CMDS="curl apt-get gzip"      # only tar absent
  _have_sudo_bin() { return 0; }
  _real_sudo() { record "_real_sudo $*"; return 0; }
  spin_cmd() { record "$*"; case "$*" in *"apt-get install"*) return 1 ;; *) return 0 ;; esac; }
  run _ensure_unpack_tools
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't install tar"* ]] || return 1
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
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"daemon won't start"* ]] || return 1
  [[ "$output" != *"logging out"* ]] || return 1               # the misleading group hint is NOT used
}

# Asad's root cause: minimal AlmaLinux lacks xt_addrtype -> dockerd bridge init fails.
@test "_ensure_kernel_modules: modprobes modules + installs kernel-modules on a load failure" {
  has() { [[ "$1" == "dnf" ]]; }
  sudo() { record "sudo $*"; case "$*" in *modprobe*) return 1 ;; esac; return 0; }
  spin_cmd() { record "$*"; return 0; }
  run _ensure_kernel_modules
  run mock_calls
  [[ "$output" == *"modprobe overlay"* ]] || return 1
  [[ "$output" == *"modprobe xt_addrtype"* ]] || return 1
  [[ "$output" == *"kernel-modules-"* ]] || return 1           # RHEL fallback install fired
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
  [ "$status" -eq 0 ] || return 1
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ] || return 1
}

@test "_configure_docker_proxy: not systemd-managed -> no-op" {
  PRESENT_CMDS=""                                  # has systemctl -> false
  HTTP_PROXY="http://proxy.corp:3128"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  run _configure_docker_proxy
  [ "$status" -eq 0 ] || return 1
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ] || return 1
}

@test "_configure_docker_proxy: host proxy -> writes dockerd drop-in (HTTP/HTTPS/NO_PROXY)" {
  unset HTTPS_PROXY http_proxy https_proxy no_proxy
  PRESENT_CMDS="systemctl"
  HTTP_PROXY="http://proxy.corp:3128"; NO_PROXY="localhost,.corp"
  TB_DOCKER_DROPIN_DIR="$BATS_TEST_TMPDIR/dropin"
  sudo() { "$@"; }
  systemctl() { return 1; }                        # is-active false (fresh) -> no restart
  run _configure_docker_proxy
  [ "$status" -eq 0 ] || return 1
  f="$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
  [ -f "$f" ] || return 1
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
  [[ "$output" != *"restart docker"* ]] || return 1
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
  [ "$status" -eq 0 ] || return 1
  [ ! -e "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ] || return 1  # ours -> removed
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
  [ "$status" -eq 0 ] || return 1
  [ -f "$TB_DOCKER_DROPIN_DIR/http-proxy.conf" ] || return 1   # NOT ours -> left alone
  grep -q 'it-managed' "$TB_DOCKER_DROPIN_DIR/http-proxy.conf"
}

# ── _route_install_tier (RFC 0001 #1172) ─────────────────────────────────────
@test "_route_install_tier: Tier 2 + no sudo => actionable fail-fast" {
  INSTALL_TIER=2; PROBE_PRIVILEGE=no_sudo
  run _route_install_tier
  [ "$status" -ne 0 ] || return 1
  printf '%s\n' "$output" | grep -qF "administrator rights"
  printf '%s\n' "$output" | grep -qF "prepare this host"
}

@test "_route_install_tier: Tier 2 + root => proceeds (root can install a runtime)" {
  INSTALL_TIER=2; PROBE_PRIVILEGE=root
  run _route_install_tier
  [ "$status" -eq 0 ] || return 1
}

@test "_route_install_tier: Tier 0 + no sudo => proceeds (runtime already usable)" {
  INSTALL_TIER=0; PROBE_PRIVILEGE=no_sudo
  run _route_install_tier
  [ "$status" -eq 0 ] || return 1
}

@test "_route_install_tier: unset tier (stale bootstrap) => proceeds as before" {
  unset INSTALL_TIER PROBE_PRIVILEGE
  run _route_install_tier
  [ "$status" -eq 0 ] || return 1
}

@test "_route_install_tier: TB_FORCE_TIER overrides the detected tier" {
  INSTALL_TIER=0; PROBE_PRIVILEGE=no_sudo; TB_FORCE_TIER=2
  run _route_install_tier
  [ "$status" -ne 0 ] || return 1           # forced to Tier 2 + no_sudo => fail-fast
  printf '%s\n' "$output" | grep -qF "administrator rights"
}

# ── install_linux tier branching (RFC 0001 #1175) ────────────────────────────
# Stub every step so the branch is observable without a real install.
_stub_install_steps() {
  preflight_sudo()       { record "preflight_sudo"; }
  setup_pm()             { record "setup_pm"; }
  apt_wait_for_lock()    { record "apt_wait_for_lock"; }
  install_docker_engine(){ record "install_docker_engine"; }
  install_system_deps()  { record "install_system_deps"; }
  dispatch_gpu_setup()   { record "dispatch_gpu_setup"; }
  install_kubectl()      { record "install_kubectl"; }
  install_k3d()          { record "install_k3d"; }
  install_helm()         { record "install_helm"; }
}

@test "install_linux: Tier 0 skips every privileged step, installs only user-space tools" {
  MOCK_CALLS="$(mktemp)"
  INSTALL_TIER=0
  # Sandbox HOME: the Tier-0 branch runs the REAL _install_userspace_tools, whose
  # _set_tools_target mkdir's ~/.local/bin and _persist_tools_on_path appends a
  # PATH line to the shell rc — both would hit the developer's real home without
  # this (Bugbot #375). Matches the dedicated _set_tools_target/_persist tests.
  HOME="$BATS_TEST_TMPDIR"
  _stub_install_steps
  run install_linux
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q install_kubectl
  mock_calls | grep -q install_k3d
  mock_calls | grep -q install_helm
  ! mock_calls | grep -q preflight_sudo || return 1
  ! mock_calls | grep -q install_docker_engine || return 1
  ! mock_calls | grep -q install_system_deps || return 1
  ! mock_calls | grep -q dispatch_gpu_setup || return 1
}

@test "install_linux: Tier 1 runs the full privileged flow" {
  MOCK_CALLS="$(mktemp)"
  INSTALL_TIER=1; PROBE_PRIVILEGE=sudo_nopw
  _stub_install_steps
  run install_linux
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q preflight_sudo
  mock_calls | grep -q install_docker_engine
  mock_calls | grep -q install_kubectl
  mock_calls | grep -q dispatch_gpu_setup
}

@test "install_linux: unset tier (stale bootstrap) runs the full flow" {
  MOCK_CALLS="$(mktemp)"
  unset INSTALL_TIER PROBE_PRIVILEGE
  _stub_install_steps
  run install_linux
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q install_docker_engine
}

# ── install_linux: Tier 1 rootless routing (RFC 0001 #1177/#1219) ────────────
@test "install_linux: Tier 1 + TB_TIER1_ROOTLESS=1 routes to rootless, skips every privileged step" {
  MOCK_CALLS="$(mktemp)"
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  HOME="$BATS_TEST_TMPDIR"                 # _install_userspace_tools runs for real
  # Stub the subid gate and daemon setup — this test asserts install_linux ROUTES to
  # the rootless path; the gate's own behavior is covered by the _ensure_subid_ranges
  # tests below.
  _ensure_subid_ranges()    { record "_ensure_subid_ranges"; }
  install_rootless_docker() { record "install_rootless_docker"; }
  _stub_install_steps
  run install_linux
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q _ensure_subid_ranges            # gate runs before daemon setup
  mock_calls | grep -q install_rootless_docker
  mock_calls | grep -q install_kubectl                 # _install_userspace_tools ran
  ! mock_calls | grep -q preflight_sudo || return 1
  ! mock_calls | grep -q install_docker_engine || return 1
  ! mock_calls | grep -q install_system_deps || return 1
  ! mock_calls | grep -q dispatch_gpu_setup || return 1
}

@test "install_linux: Tier 1 WITHOUT the opt-in falls through to the legacy privileged flow (safe default)" {
  MOCK_CALLS="$(mktemp)"
  INSTALL_TIER=1; unset TB_TIER1_ROOTLESS; PROBE_PRIVILEGE=sudo_nopw
  install_rootless_docker() { record "install_rootless_docker"; }
  _stub_install_steps
  run install_linux
  [ "$status" -eq 0 ] || return 1
  ! mock_calls | grep -q install_rootless_docker || return 1       # opt-in off → rootless never runs
  mock_calls | grep -q preflight_sudo
  mock_calls | grep -q install_docker_engine
}

# ── install_rootless_docker (RFC 0001 #1219) ─────────────────────────────────
@test "install_rootless_docker: happy path installs no-sudo, starts the user daemon, exports DOCKER_HOST" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000
  # is-system-running echoes a state word ⇒ user-systemd present ⇒ systemd path (#1222)
  systemctl() { record "systemctl $*"; case "$*" in *is-system-running*) echo running ;; esac; }
  loginctl()  { record "loginctl $*"; }
  id()        { [ "${1:-}" = "-un" ] && echo testuser || echo "testuser docker"; }  # id -un → clean username (#452)
  install_rootless_docker                              # called directly to observe the exported DOCKER_HOST
  mock_calls | grep -q "dockerd-rootless-setuptool.sh install"
  mock_calls | grep -q "systemctl --user enable --now docker"
  mock_calls | grep -q "loginctl enable-linger testuser"
  [ "$DOCKER_HOST" = "unix://${XDG_RUNTIME_DIR}/docker.sock" ] || return 1
  ! mock_calls | grep -q sudo || return 1                          # no blanket sudo anywhere on the rootless path
}

@test "install_rootless_docker: DOCKER_HOST targets the XDG runtime-dir socket (systemd path)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000
  id()        { [ "${1:-}" = "-u" ] && echo 1000 || echo "testuser docker"; }
  systemctl() { case "$*" in *is-system-running*) echo running ;; esac; }
  loginctl()  { :; }
  install_rootless_docker
  [ "$DOCKER_HOST" = "unix:///run/user/1000/docker.sock" ] || return 1
}

@test "install_rootless_docker: prepends ~/bin so the rootless CLI resolves (get.docker.com fallback) (Bugbot)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl newuidmap newgidmap docker"       # no setuptool -> get.docker.com/rootless installs to ~/bin
  XDG_RUNTIME_DIR=/run/user/1000
  HOME="$BATS_TEST_TMPDIR"
  curl_secure() { record "curl_secure $*"; return 0; } # no network
  systemctl()   { case "$*" in *is-system-running*) echo running ;; esac; }
  loginctl()    { :; }
  install_rootless_docker
  case ":$PATH:" in *":$HOME/bin:"*) : ;; *) return 1 ;; esac   # ~/bin now on PATH for the run
}

@test "install_rootless_docker: systemd/linger failure falls through to the verify, not a bare abort (Bugbot)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000
  HOME="$BATS_TEST_TMPDIR"
  systemctl() { case "$*" in *is-system-running*) echo degraded ;; *) return 1 ;; esac; }  # present, but enable refuses
  loginctl()  { return 1; }                            # linger blocked (polkit-locked)
  docker()    { return 0; }                            # ...but the daemon is actually up
  install_rootless_docker                              # must reach the export + verify, not set -e abort
  [ "$DOCKER_HOST" = "unix:///run/user/1000/docker.sock" ] || return 1
}

@test "install_rootless_docker: success line is honest about the admin touch (#458)" {
  PRESENT_CMDS="newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000; HOME="$BATS_TEST_TMPDIR"
  systemctl() { case "$*" in *is-system-running*) echo running ;; esac; }; loginctl() { :; }
  # Zero-root path (gate didn't touch sudo): claims no admin rights.
  MOCK_CALLS="$(mktemp)"; unset TB_ROOTLESS_ADMIN_TOUCH
  run install_rootless_docker
  [[ "$output" == *"no administrator rights were used"* ]] || return 1
  # Sudo-touch path (gate provisioned the range with sudo): must NOT claim zero-root.
  MOCK_CALLS="$(mktemp)"; TB_ROOTLESS_ADMIN_TOUCH=1
  run install_rootless_docker
  [[ "$output" != *"no administrator rights were used"* ]] || return 1
  [[ "$output" == *"one-time admin step"* ]] || return 1
}

# ── no-systemd fallback + Tier-2 fall-through (RFC 0001 #1222) ────────────────

@test "install_rootless_docker: no user-systemd -> Tier-2 prepare-host fall-through (nohup fallback descoped, #1222)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000; HOME="$BATS_TEST_TMPDIR"
  systemctl() { record "systemctl $*"; }                 # is-system-running → empty ⇒ no user manager
  loginctl()  { record "loginctl $*"; }
  run install_rootless_docker
  [ "$status" -ne 0 ] || return 1                                    # routes to Tier-2 and exits (no blind nohup bring-up)
  [[ "$output" == *"prepare-host"* ]] || return 1                    # the Tier-2 remedy
  [[ "$output" == *"no per-user systemd"* ]] || return 1             # accurate reason (not a vague setuptool failure)
  ! mock_calls | grep -q "systemctl --user enable" || return 1       # never attempted the user-systemd bring-up
  ! mock_calls | grep -q "dockerd-rootless-setuptool.sh install" || return 1   # gate is UPFRONT → no partial ~/bin install (Bugbot #485)
}

@test "install_rootless_docker: daemon never Ready -> Tier-2 prepare-host fall-through, not a silent proceed (#1222)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000; HOME="$BATS_TEST_TMPDIR"
  systemctl() { case "$*" in *is-system-running*) echo running ;; esac; }  # systemd present
  loginctl()  { :; }
  docker()    { return 1; }                              # daemon never answers on the socket
  run install_rootless_docker
  [ "$status" -ne 0 ] || return 1                                    # exits via fall-through, not onward
  [[ "$output" == *"prepare-host"* ]] || return 1                    # routes to the Tier-2 remedy
}

@test "install_rootless_docker: setuptool install failure -> Tier-2 fall-through, not a bare set -e abort (#485 r2)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="newuidmap newgidmap dockerd-rootless-setuptool.sh docker"
  XDG_RUNTIME_DIR=/run/user/1000; HOME="$BATS_TEST_TMPDIR"
  systemctl() { case "$*" in *is-system-running*) echo running ;; esac; }
  loginctl()  { :; }
  spin_cmd()  { record "$*"; case "$*" in *"dockerd-rootless-setuptool.sh install"*) return 1 ;; *) return 0 ;; esac; }
  run install_rootless_docker
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"prepare-host"* ]] || return 1                    # routed to the Tier-2 remedy…
  [[ "$output" == *"setup tool"* ]] || return 1                      # …naming the setuptool failure, not a spinner tail
}

@test "_tier2_fallthrough: names the researcher in the prepare-host remedy so prepare-host actually provisions them (Bugbot #485)" {
  id() { [ "${1:-}" = "-un" ] && echo researcher || echo "researcher"; }
  run _tier2_fallthrough "some reason"
  [ "$status" -ne 0 ] || return 1                                    # exits
  [[ "$output" == *"export TB_PREPARE_USER=researcher"* ]] || return 1   # names the researcher (run_prepare_host keys off this)
  [[ "$output" == *"tracebloc prepare-host researcher"* ]] || return 1   # CLI form names them too
  [[ "$output" == *"prepare it for 'researcher'"* ]] || return 1         # final error names them
}

# ── _ensure_subid_ranges: the Tier-1 subuid/subgid gate (RFC 0001 #1220) ─────
@test "_ensure_subid_ranges: present => proceeds with zero privileged calls" {
  MOCK_CALLS="$(mktemp)"
  PROBE_SUBID=1; PROBE_UIDMAP=1
  _provision_subid_ranges() { record "_provision_subid_ranges $*"; }
  run _ensure_subid_ranges
  [ "$status" -eq 0 ] || return 1
  ! mock_calls | grep -q _provision_subid_ranges || return 1
  ! mock_calls | grep -q sudo || return 1
}

@test "_ensure_subid_ranges: missing + unprivileged => hand off to prepare-host (naming the user), fail-fast, no sudo" {
  MOCK_CALLS="$(mktemp)"
  PROBE_SUBID=0; PROBE_UIDMAP=1; PROBE_PRIVILEGE=no_sudo
  id() { [ "$1" = "-un" ] && echo researcher || echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"   # empty -> next start 100000
  _provision_subid_ranges() { record "_provision_subid_ranges $*"; }
  run _ensure_subid_ranges
  [ "$status" -ne 0 ] || return 1                                  # honest fail-fast
  [[ "$output" == *prepare-host* ]] || return 1
  [[ "$output" == *"TB_PREPARE_USER=researcher"* ]] || return 1    # command names the researcher (#458)
  [[ "$output" == *"/etc/subuid"* ]] || return 1                   # the two literal remedy lines
  [[ "$output" == *"/etc/subgid"* ]] || return 1
  [[ "$output" == *"researcher:100000:65536"* ]] || return 1       # computed (non-hardcoded) start for this host
  ! mock_calls | grep -q _provision_subid_ranges || return 1       # never self-provisions unprivileged
  ! mock_calls | grep -q sudo || return 1
}

@test "_ensure_subid_ranges: missing + sudo available => exactly one announced provision (for id -un)" {
  MOCK_CALLS="$(mktemp)"
  PROBE_SUBID=0; PROBE_UIDMAP=1; PROBE_PRIVILEGE=sudo_nopw
  id() { [ "$1" = "-un" ] && echo researcher || echo 1000; }
  _provision_subid_ranges() { record "_provision_subid_ranges $*"; }
  run _ensure_subid_ranges
  [ "$status" -eq 0 ] || return 1
  [ "$(mock_calls | grep -c _provision_subid_ranges)" -eq 1 ] || return 1
  mock_calls | grep -q "_provision_subid_ranges researcher"   # id -un, not $USER
  [[ "$output" == *one-time* ]] || return 1                         # announced (A2 honest messaging)
}

@test "_ensure_subid_ranges: uidmap helpers absent => message includes the package-install hint" {
  MOCK_CALLS="$(mktemp)"
  PROBE_SUBID=1; PROBE_UIDMAP=0; PROBE_PRIVILEGE=no_sudo
  run _ensure_subid_ranges
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *uidmap* ]] || return 1
}

# ── _provision_subid_ranges: shared remediation body ─────────────────────────
# _idmap_helper_ok (real, via command -v) is stubbed here to control the usable /
# not-usable state; its own setuid/filecaps logic is unit-tested in probe.bats.
@test "_provision_subid_ranges: allocates a range and appends it (file-append path)" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok() { return 0; }                     # helpers usable -> no install
  sudo()    { "$@"; }                                  # pass-through so tee writes the fixture
  usermod() { return 0; }                              # `usermod --help` has no --add-subuids -> append path
  id()      { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  _provision_subid_ranges testuser
  grep -q '^testuser:100000:65536$' "$TB_SUBUID_FILE"
  grep -q '^testuser:100000:65536$' "$TB_SUBGID_FILE"
}

@test "_provision_subid_ranges: idempotent — an existing range is left untouched" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok() { return 0; }
  sudo()    { "$@"; }
  usermod() { return 0; }
  id()      { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'testuser:100000:65536\n' >"$TB_SUBUID_FILE"
  printf 'testuser:100000:65536\n' >"$TB_SUBGID_FILE"
  _provision_subid_ranges testuser
  [ "$(grep -c '^testuser:' "$TB_SUBUID_FILE")" -eq 1 ] || return 1   # not appended again
  [ "$(grep -c '^testuser:' "$TB_SUBGID_FILE")" -eq 1 ] || return 1
}

@test "_provision_subid_ranges: allocates a NON-overlapping block past an existing range" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok() { return 0; }
  sudo()    { "$@"; }
  usermod() { return 0; }
  id()      { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  printf 'someoneelse:100000:65536\n' >"$TB_SUBUID_FILE"   # 100000..165535 taken
  printf 'someoneelse:100000:65536\n' >"$TB_SUBGID_FILE"
  _provision_subid_ranges testuser
  grep -q '^testuser:165536:65536$' "$TB_SUBUID_FILE"       # next free start, no overlap
}

@test "_provision_subid_ranges: installs uidmap helpers when not usable, then proceeds" {
  MOCK_CALLS="$(mktemp)"
  ok="$BATS_TEST_TMPDIR/uidmap_ok"
  _idmap_helper_ok()    { [ -e "$ok" ]; }              # not usable until installed
  _install_uidmap_pkg() { record "install_uidmap"; : >"$ok"; }
  sudo()    { "$@"; }
  usermod() { return 0; }
  id()      { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  _provision_subid_ranges testuser
  mock_calls | grep -q install_uidmap
  grep -q '^testuser:100000:65536$' "$TB_SUBUID_FILE"  # proceeded after a successful install
}

@test "_provision_subid_ranges: helpers still not usable after install => returns non-zero (best-effort), no half-provision (#458)" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok()    { return 1; }                  # never usable (unknown distro / not setuid+no caps)
  _install_uidmap_pkg() { record "install_uidmap"; }
  sudo()    { record "sudo $*"; return 0; }
  id()      { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  run _provision_subid_ranges testuser
  [ "$status" -ne 0 ] || return 1                                  # returns non-zero (NOT exit) so callers decide
  [[ "$output" == *uidmap* ]] || return 1
  ! mock_calls | grep -q "tee -a" || return 1                      # never wrote a range on a broken host
}

@test "_provision_subid_ranges: a failed range write returns non-zero, not false success (#458)" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok() { return 0; }                     # helpers fine
  usermod() { return 0; }                              # no --add-subuids -> append path
  sudo() { case "$*" in tee*) return 1 ;; *) return 0 ;; esac; }  # the tee write FAILS
  id() { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  run _provision_subid_ranges testuser
  [ "$status" -ne 0 ] || return 1                                  # must surface the write failure, not print success
}

@test "_provision_subid_ranges: usermod --help nonzero exit still takes the usermod path (pipefail-safe, #458)" {
  MOCK_CALLS="$(mktemp)"
  _idmap_helper_ok() { return 0; }
  sudo() { record "sudo $*"; return 0; }
  # --help prints the flag but EXITS NON-ZERO (some shadow-utils builds do); the fix
  # captures output before grepping, so --add-subuids is still detected under pipefail.
  usermod() { if [ "$1" = "--help" ]; then printf -- '  --add-subuids\n'; return 2; fi; return 0; }
  id() { echo 1000; }
  TB_SUBUID_FILE="$(mktemp)"; TB_SUBGID_FILE="$(mktemp)"
  # Scope pipefail to a subshell — setting it in the @test body can leak into bats'
  # own harness pipelines and fail the run even when every test passes (bats footgun).
  ( set -o pipefail; _provision_subid_ranges testuser )
  mock_calls | grep -q "usermod --add-subuids"         # usermod path, not the append fallback
  ! mock_calls | grep -q "tee -a" || return 1
}

@test "_install_uidmap_pkg: apt-get distro installs 'uidmap' via the hardened PM_INSTALL (no bare apt hang, #458)" {
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="apt-get"
  unset PM_INSTALL PM_UPDATE            # Tier-1 skips setup_pm; force the real populate-then-install path
  _install_uidmap_pkg
  run mock_calls
  [[ "$output" == *"apt-get update"* ]] || return 1                # refreshes the index first (#458)
  [[ "$output" == *"apt-get install"* ]] || return 1
  [[ "$output" == *"uidmap"* ]] || return 1
  [[ "$output" == *"NEEDRESTART_MODE=a"* ]] || return 1            # needrestart guard (no spinner hang)
  [[ "$output" == *"DPkg::Lock::Timeout="* ]] || return 1          # bounded dpkg-lock wait (#210)
}

# ── _set_tools_target: Tier 0 tools must NOT sudo (Bugbot #1175) ─────────────
@test "_set_tools_target: Tier 0 => ~/.local/bin, no sudo, on PATH" {
  INSTALL_TIER=0; HOME="$BATS_TEST_TMPDIR"
  _set_tools_target
  [ "$TB_TOOLS_DIR" = "$HOME/.local/bin" ] || return 1
  [ -z "$TB_TOOLS_SUDO" ] || return 1           # zero-root: no sudo for the tools
  [ -d "$TB_TOOLS_DIR" ] || return 1            # created
  case ":$PATH:" in *":$TB_TOOLS_DIR:"*) : ;; *) return 1 ;; esac   # on PATH now
}

@test "_set_tools_target: full flow => /usr/local/bin with sudo" {
  INSTALL_TIER=1
  _set_tools_target
  [ "$TB_TOOLS_DIR" = "/usr/local/bin" ] || return 1
  [ "$TB_TOOLS_SUDO" = "sudo" ] || return 1
}

# ── _tools_rc_for_shell + _persist_tools_on_path: keep Tier-0 tools on PATH (#375) ─
@test "_tools_rc_for_shell: zsh/bash-linux/bash-mac/other" {
  HOME=/h
  SHELL=/bin/zsh;  [ "$(_tools_rc_for_shell)" = "/h/.zshrc" ] || return 1
  SHELL=/bin/bash; OS=Linux;  [ "$(_tools_rc_for_shell)" = "/h/.bashrc" ] || return 1
  SHELL=/bin/bash; OS=Darwin; [ "$(_tools_rc_for_shell)" = "/h/.bash_profile" ] || return 1
  SHELL=/bin/dash; OS=Linux;  [ "$(_tools_rc_for_shell)" = "/h/.profile" ] || return 1
}

@test "_persist_tools_on_path: Tier 0 appends ~/.local/bin to the shell rc (#375)" {
  HOME="$BATS_TEST_TMPDIR"; SHELL=/bin/bash; OS=Linux
  TB_TOOLS_DIR="$HOME/.local/bin"
  hint() { :; }
  _persist_tools_on_path
  grep -qF "$HOME/.local/bin" "$HOME/.bashrc"
}

@test "_persist_tools_on_path: idempotent — no double append (#375)" {
  HOME="$BATS_TEST_TMPDIR"; SHELL=/bin/bash; OS=Linux
  TB_TOOLS_DIR="$HOME/.local/bin"
  hint() { :; }
  _persist_tools_on_path
  _persist_tools_on_path
  [ "$(grep -cF '.local/bin' "$HOME/.bashrc")" -eq 1 ] || return 1
}

@test "_persist_tools_on_path: no-op for the full flow (/usr/local/bin) (#375)" {
  HOME="$BATS_TEST_TMPDIR"; SHELL=/bin/bash; OS=Linux
  TB_TOOLS_DIR="/usr/local/bin"
  hint() { echo "must-not-run"; }
  run _persist_tools_on_path
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$HOME/.bashrc" ] || return 1                 # nothing written
  [[ "$output" != *"must-not-run"* ]] || return 1      # no PATH hint emitted
}

@test "_persist_tools_on_path: fish gets fish_add_path, no dead export in ~/.profile (#375)" {
  HOME="$BATS_TEST_TMPDIR"; SHELL=/usr/bin/fish; OS=Linux
  TB_TOOLS_DIR="$HOME/.local/bin"
  hint() { echo "$*"; }
  run _persist_tools_on_path
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"fish_add_path"* ]] || return 1     # fish-correct guidance
  [ ! -f "$HOME/.profile" ] || return 1                # did NOT write a bash export fish can't read
}

# ── _tier0_gpu_flags: NVIDIA k3d flag reused only when the runtime exists (#375) ─
@test "_tier0_gpu_flags: nvidia + configured runtime => --gpus=all" {
  GPU_VENDOR=nvidia; K3D_GPU_FLAGS=()
  success() { :; }
  docker() { case "$*" in *Runtimes*) echo '{"nvidia":{"path":"nvidia-container-runtime"},"runc":{}}' ;; *) return 0 ;; esac; }
  _tier0_gpu_flags
  [ "${K3D_GPU_FLAGS[*]}" = "--gpus=all" ] || return 1
}

@test "_tier0_gpu_flags: nvidia + NO configured runtime => stays CPU-only (empty flags)" {
  GPU_VENDOR=nvidia; K3D_GPU_FLAGS=()
  warn() { :; }; hint() { :; }
  docker() { case "$*" in *Runtimes*) echo '{"runc":{}}' ;; *) return 0 ;; esac; }
  _tier0_gpu_flags
  [ "${#K3D_GPU_FLAGS[@]}" -eq 0 ] || return 1   # no --gpus flag → CPU-only cluster (safe, not a broken create)
}

@test "_tier0_gpu_flags: non-nvidia GPU => no-op" {
  GPU_VENDOR=none; K3D_GPU_FLAGS=()
  _tier0_gpu_flags
  [ "${#K3D_GPU_FLAGS[@]}" -eq 0 ] || return 1
}

# ── run_prepare_host (RFC 0001 #1178) ────────────────────────────────────────
@test "run_prepare_host: installs runtime prereqs + adds researcher to docker group, no cluster/CLI" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; TB_PREPARE_USER=researcher
  host_audit()          { :; }
  preflight_sudo()      { record preflight_sudo; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ record install_docker_engine; }
  install_system_deps() { record install_system_deps; }
  sudo()                { record "sudo $*"; return 0; }
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q install_docker_engine
  mock_calls | grep -q "sudo usermod -aG docker researcher"
  ! mock_calls | grep -qi "create_cluster" || return 1
  ! mock_calls | grep -qi "install_tracebloc_cli" || return 1
  # Grant succeeded => the no-admin promise is honest and shown (#377).
  printf '%s\n' "$output" | grep -qi "no administrator rights"
}

@test "run_prepare_host: TB_PREPARE_USER with stray whitespace is trimmed before the grant (#381 r3)" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; TB_PREPARE_USER="  researcher  "
  host_audit()          { :; }
  preflight_sudo()      { :; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ :; }
  install_system_deps() { :; }
  sudo()                { record "sudo $*"; return 0; }
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1
  # Untrimmed, the record would be "docker   researcher  " — single-space match
  # proves the value was trimmed before the gate and the grant.
  mock_calls | grep -q "sudo usermod -aG docker researcher"
  [[ "$output" == *"Added researcher to the docker group"* ]] || return 1
}

@test "run_prepare_host: no target user => best-effort, still prepares the host" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; unset TB_PREPARE_USER SUDO_USER
  host_audit()          { :; }
  preflight_sudo()      { :; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ record install_docker_engine; }
  install_system_deps() { :; }
  sudo()                { record "sudo $*"; return 0; }
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q install_docker_engine
  ! mock_calls | grep -q "usermod" || return 1      # nobody to add
  # No grant happened => must NOT falsely promise a no-admin install (#377).
  ! printf '%s\n' "$output" | grep -qi "can now install tracebloc with no administrator rights" || return 1
}

@test "run_prepare_host: subid provisioning failure is best-effort — warns, still prepares the host (#458)" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; TB_PREPARE_USER=researcher
  host_audit()          { :; }
  preflight_sudo()      { :; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ record install_docker_engine; }
  install_system_deps() { :; }
  sudo()                { record "sudo $*"; return 0; }
  _provision_subid_ranges() { return 1; }              # can't provision (e.g. unknown distro / helpers unfixable)
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1                                  # best-effort: the whole prep must NOT abort (#458)
  [[ "$output" == *"Couldn't provision subuid/subgid"* ]] || return 1   # honest warning, not a hard exit
  mock_calls | grep -q install_docker_engine           # host still prepared
}

@test "run_prepare_host: usermod fails => no false no-admin promise, still exits 0 (#377)" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; TB_PREPARE_USER=researcher
  host_audit()          { :; }
  preflight_sudo()      { :; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ record install_docker_engine; }
  install_system_deps() { :; }
  # sudo succeeds for everything EXCEPT the usermod grant.
  sudo()                { case "$*" in usermod*) return 1 ;; *) return 0 ;; esac; }
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1                                 # best-effort: prep still succeeds
  printf '%s\n' "$output" | grep -qi "Couldn't add"   # honest warning
  ! printf '%s\n' "$output" | grep -qi "can now install tracebloc with no administrator rights" || return 1
}

@test "run_prepare_host: does NOT grant docker-group to SUDO_USER (the admin), only TB_PREPARE_USER (#377)" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; unset TB_PREPARE_USER; SUDO_USER=admin
  host_audit()          { :; }
  preflight_sudo()      { :; }
  setup_pm()            { :; }
  apt_wait_for_lock()   { :; }
  install_docker_engine(){ record install_docker_engine; }
  install_system_deps() { :; }
  sudo()                { record "sudo $*"; return 0; }
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q install_docker_engine   # host still prepared
  ! mock_calls | grep -q "usermod" || return 1             # the ADMIN (SUDO_USER) is NOT added
}

@test "run_prepare_host: non-Linux errors with a Docker Desktop / WSL2 pointer" {
  OS=Darwin
  run run_prepare_host
  [ "$status" -ne 0 ] || return 1
  printf '%s\n' "$output" | grep -qiE "Docker Desktop|WSL2"
}

# ── cgroup delegation drop-in (RFC 0001 #1221) ────────────────────────────────

@test "_write_cgroup_delegation: writes the exact [Service] Delegate drop-in + daemon-reload" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"
  sudo()      { "$@"; }                              # passthrough: really mkdir/tee/cmp
  systemctl() { record "systemctl $*"; }
  _write_cgroup_delegation
  run cat "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  [[ "$output" == *"[Service]"* ]] || return 1
  [[ "$output" == *"Delegate=cpu cpuset io memory pids"* ]] || return 1
  run mock_calls
  [[ "$output" == *"systemctl daemon-reload"* ]] || return 1
}

@test "_write_cgroup_delegation: idempotent when content already matches (no daemon-reload)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; mkdir -p "$TB_USER_UNIT_DROPIN_DIR"
  printf '%s\n[Service]\nDelegate=cpu cpuset io memory pids\n' \
    '# Managed by tracebloc installer (RFC 0001 #1221)' > "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  sudo()      { "$@"; }
  systemctl() { record "systemctl $*"; }
  _write_cgroup_delegation
  run mock_calls
  [[ "$output" != *"daemon-reload"* ]] || return 1              # unchanged -> no user-manager churn
}

@test "_ensure_cgroup_delegation: no_sudo -> hands off with the exact path + content, writes nothing" {
  local d; d="$(mktemp -d)/user@.service.d"
  TB_USER_UNIT_DROPIN_DIR="$d"; PROBE_PRIVILEGE=no_sudo
  sudo() { record "sudo $*"; }                       # must NOT be used to write
  run _ensure_cgroup_delegation
  [ "$status" -ne 0 ] || return 1                                # non-fatal signal to the caller
  [[ "$output" == *"Delegate=cpu cpuset io memory pids"* ]] || return 1
  [[ "$output" == *"$d/delegate.conf"* ]] || return 1
  [ ! -e "$d/delegate.conf" ] || return 1
}

@test "_ensure_cgroup_delegation: root -> writes the drop-in + records the one admin touch" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; PROBE_PRIVILEGE=root
  sudo()      { "$@"; }
  systemctl() { record "systemctl $*"; }
  TB_ROOTLESS_ADMIN_TOUCH=0
  _ensure_cgroup_delegation
  grep -qF 'Delegate=cpu cpuset io memory pids' "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  [ "$TB_ROOTLESS_ADMIN_TOUCH" = "1" ] || return 1
}

@test "_ensure_cgroup_delegation: already delegated -> no privileged call (fast path)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; mkdir -p "$TB_USER_UNIT_DROPIN_DIR"
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  PROBE_PRIVILEGE=no_sudo
  sudo() { record "sudo $*"; }
  _ensure_cgroup_delegation
  run mock_calls
  [ -z "$output" ] || return 1                                   # nothing invoked at all
}

# ── rootless-daemon corporate proxy: user-scoped, no sudo (carry-in, #452) ────

@test "_configure_docker_proxy user: writes user-scoped drop-in via systemctl --user, no sudo" {
  local d; d="$(mktemp -d)/docker.service.d"
  TB_DOCKER_USER_DROPIN_DIR="$d"
  unset HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  HTTP_PROXY="http://proxy.example:3128"
  has()       { return 0; }                          # systemd present
  sudo()      { record "sudo $*"; }                  # must NOT be called in user scope
  systemctl() { record "systemctl $*"; return 1; }   # is-active: fresh daemon, not up
  _configure_docker_proxy user
  run cat "$d/http-proxy.conf"
  [[ "$output" == *'HTTP_PROXY=http://proxy.example:3128'* ]] || return 1
  run mock_calls
  [[ "$output" == *"systemctl --user daemon-reload"* ]] || return 1
  [[ "$output" != *"sudo "* ]] || return 1                       # user scope never elevates
}

# ── carry-in: tools install user-space on rootless Tier 1 (no sudo mv crash) ──

@test "_set_tools_target: rootless Tier 1 -> ~/.local/bin, no sudo (carry-in #452)" {
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  HOME="$(mktemp -d)"
  _set_tools_target
  [ "$TB_TOOLS_DIR" = "$HOME/.local/bin" ] || return 1
  [ -z "$TB_TOOLS_SUDO" ] || return 1
  case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) return 1 ;; esac
}

# ── carry-in: persist DOCKER_HOST for the user's shell (#452) ──────────────────

@test "_persist_docker_host: rootless -> persists DOCKER_HOST to the shell rc, idempotently" {
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  HOME="$(mktemp -d)"; SHELL=/bin/bash; OS=Linux     # _tools_rc_for_shell -> ~/.bashrc
  _persist_docker_host
  run cat "$HOME/.bashrc"
  [[ "$output" == *'export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"'* ]] || return 1
  _persist_docker_host                               # second run must not double-append
  run bash -c "grep -c 'DOCKER_HOST=' '$HOME/.bashrc'"
  [ "$output" = "1" ] || return 1
}

@test "_persist_docker_host: flag OFF -> no-op (no rc write)" {
  INSTALL_TIER=1; unset TB_TIER1_ROOTLESS
  HOME="$(mktemp -d)"; SHELL=/bin/bash; OS=Linux
  _persist_docker_host
  [ ! -e "$HOME/.bashrc" ] || return 1
}

@test "_persist_docker_host: foreign DOCKER_HOST present -> warns, does NOT clobber or double-write (Asad/Bugbot #478)" {
  INSTALL_TIER=1; TB_TIER1_ROOTLESS=1
  HOME="$(mktemp -d)"; SHELL=/bin/bash; OS=Linux
  printf 'export DOCKER_HOST="tcp://10.0.0.5:2375"\n' > "$HOME/.bashrc"   # user's own remote daemon
  run _persist_docker_host
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"already sets DOCKER_HOST"* ]] || return 1                 # warned, not silent
  grep -q 'tcp://10.0.0.5:2375' "$HOME/.bashrc"                   # their line left untouched
  [ "$(grep -c 'DOCKER_HOST=' "$HOME/.bashrc")" -eq 1 ] || return 1           # we did NOT append the rootless line
}


# ── #427: docker-group grant is not gated on a fresh install ────────────────
@test "install_docker_engine: pre-installed Docker + user NOT in group -> still grants (#427)" {
  PRESENT_CMDS="docker curl conntrack"; TEST_DISTRO=ubuntu
  id() { echo "testuser"; }                 # NOT yet in the docker group
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "sudo usermod -aG docker testuser"
}
@test "install_docker_engine: pre-installed Docker + user already in group -> no redundant grant (#427)" {
  PRESENT_CMDS="docker curl conntrack"; TEST_DISTRO=ubuntu
  id() { echo "testuser docker"; }          # already a member
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  ! mock_calls | grep -q "usermod -aG docker" || return 1
}
@test "install_docker_engine: fresh install still grants the invoking user (#427 regression)" {
  PRESENT_CMDS="curl conntrack"; TEST_DISTRO=ubuntu   # docker ABSENT -> fresh install
  id() { echo "testuser"; }
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "sudo usermod -aG docker testuser"
}
@test "install_docker_engine: prepare-host mode never grants the invoking admin (#427/#381)" {
  PRESENT_CMDS="docker curl conntrack"; TEST_DISTRO=ubuntu
  TB_PREPARE_HOST_MODE=1
  id() { echo "admin"; }
  run install_docker_engine
  ! mock_calls | grep -q "usermod -aG docker admin" || return 1
}
@test "install_docker_engine: grants the INVOKING user, not TB_PREPARE_USER (#427 Bugbot)" {
  PRESENT_CMDS="docker curl conntrack"; TEST_DISTRO=ubuntu
  TB_PREPARE_USER=researcher                # a leftover export must NOT redirect the grant
  id() { echo "testuser"; }                 # invoker ($USER) not in group
  run install_docker_engine
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "sudo usermod -aG docker testuser"   # $USER, matches the sg re-exec + socket owner
  ! mock_calls | grep -q "usermod -aG docker researcher" || return 1
}

# ── #427: refuse a sudo-wrapped full install ────────────────────────────────
@test "refuse_sudo_wrapped_install: EUID 0 + SUDO_USER -> refuses, names the user (#427)" {
  error() { printf 'ERR: %s\n' "$*"; return 1; }
  id() { echo 0; }
  SUDO_USER=alice run refuse_sudo_wrapped_install
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Don't run the installer with sudo"* ]] || return 1
  [[ "$output" == *"alice"* ]] || return 1
  # the prepare-host remedy must name TB_PREPARE_USER (bare prepare-host grants nobody),
  # but with a RESEARCHER placeholder — never the admin's $SUDO_USER, which would grant
  # the admin and recreate the #377 footgun (#427 Bugbot r2).
  [[ "$output" == *"TB_PREPARE_USER=<researcher-username>"* ]] || return 1
  [[ "$output" != *"TB_PREPARE_USER=alice"* ]] || return 1
}
@test "refuse_sudo_wrapped_install: genuine root login (no SUDO_USER) is allowed (#427)" {
  error() { printf 'ERR: %s\n' "$*"; return 1; }
  id() { echo 0; }
  SUDO_USER="" run refuse_sudo_wrapped_install
  [ "$status" -eq 0 ] || return 1
}
@test "refuse_sudo_wrapped_install: SUDO_USER=root (sudo -i) is allowed (#427)" {
  error() { printf 'ERR: %s\n' "$*"; return 1; }
  id() { echo 0; }
  SUDO_USER=root run refuse_sudo_wrapped_install
  [ "$status" -eq 0 ] || return 1
}
@test "refuse_sudo_wrapped_install: non-root run is allowed (#427)" {
  error() { printf 'ERR: %s\n' "$*"; return 1; }
  id() { echo 1000; }
  SUDO_USER=alice run refuse_sudo_wrapped_install
  [ "$status" -eq 0 ] || return 1
}

@test "install_docker_engine: sg-docker re-exec guard keys off _grant_user, not bare \$USER (#427 reviewer)" {
  # The grant target and the in-session re-exec guard must agree, or the USER-unset
  # edge grants but never re-execs -> the dead-end loop returns.
  f="$BATS_TEST_DIRNAME/../lib/setup-linux.sh"
  grep -qE 'id -nG "\$_grant_user"[^|]*\| grep -qw docker' "$f"
  ! grep -qE 'id -nG "\$USER"[^|]*\| grep -qw docker' "$f" || return 1
}

# ── #496: cgroup delegation is VERIFIED, not assumed ────────────────────────
# The delegation check MUST read the user MANAGER's node (user@$UID.service), not the
# enclosing slice — the slice lists cpu/io by default (DefaultCPUAccounting) and would
# read "active" before the drop-in takes effect (#514 Bugbot, High).
@test "_cgroup_controllers_path: points at user@\$UID.service (not the bare slice) (#514)" {
  run _cgroup_controllers_path
  [[ "$output" == *"/user@$(id -u).service/cgroup.controllers" ]] || return 1
  [[ "$output" != *".slice/cgroup.controllers" ]] || return 1   # NOT the slice-level node
}
@test "_cgroup_controllers_active: true only when cpu+cpuset+io are all present (#496)" {
  cf="$(mktemp)"; TB_USER_CGROUP_CONTROLLERS="$cf"
  echo "cpuset cpu io memory pids" > "$cf"
  run _cgroup_controllers_active; [ "$status" -eq 0 ] || return 1
  echo "memory pids" > "$cf"                              # cpu/cpuset/io absent (systemd default)
  run _cgroup_controllers_active; [ "$status" -ne 0 ] || return 1
}
@test "_cgroup_controllers_active: unreadable controllers file -> not active (#496)" {
  TB_USER_CGROUP_CONTROLLERS="/no/such/cgroup/controllers"
  run _cgroup_controllers_active; [ "$status" -ne 0 ] || return 1
}
@test "_write_cgroup_delegation: controllers NOT active -> warns limits unenforced + recreate (#496)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"
  cf="$(mktemp)"; echo "memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"   # not delegated yet
  sudo() { "$@"; }; systemctl() { :; }
  run _write_cgroup_delegation
  [[ "$output" == *"NOT active in this session"* ]] || return 1
  [[ "$output" == *"recreate the cluster"* ]] || return 1
  [[ "$output" == *"k3d cluster delete"* ]] || return 1
  [[ "$output" != *"active in this session."* ]] || return 1   # never the plain-success wording
}
@test "_write_cgroup_delegation: controllers active -> success, no scary warn (#496)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"
  cf="$(mktemp)"; echo "cpuset cpu io memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"
  sudo() { "$@"; }; systemctl() { :; }
  run _write_cgroup_delegation
  [[ "$output" == *"active in this session"* ]] || return 1
  [[ "$output" != *"NOT active"* ]] || return 1
}

@test "_write_cgroup_delegation: re-run over an existing drop-in still verifies (no silent fast path) (#496 Bugbot)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; mkdir -p "$TB_USER_UNIT_DROPIN_DIR"
  printf '%s\n[Service]\nDelegate=cpu cpuset io memory pids\n' \
    '# Managed by tracebloc installer (RFC 0001 #1221)' > "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"   # already present
  cf="$(mktemp)"; echo "memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"   # not delegated
  sudo() { "$@"; }; systemctl() { record "systemctl $*"; }
  run _write_cgroup_delegation
  [[ "$output" == *"NOT active in this session"* ]] || return 1   # report ran even on the idempotent path
  run mock_calls
  [[ "$output" != *"daemon-reload"* ]] || return 1                # …and it was the no-reload idempotent path
}
@test "_write_cgroup_delegation: prepare-host mode -> researcher-login wording, no cluster-delete (#496 Bugbot)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"
  TB_PREPARE_HOST_MODE=1
  cf="$(mktemp)"; echo "memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"   # admin's slice is irrelevant here
  sudo() { "$@"; }; systemctl() { :; }
  run _write_cgroup_delegation
  [[ "$output" == *"researcher's next login"* ]] || return 1
  [[ "$output" != *"k3d cluster delete"* ]] || return 1           # prepare-host creates no cluster
  [[ "$output" != *"NOT active in this session"* ]] || return 1   # doesn't judge on the admin's own slice
}

# _ensure_cgroup_delegation is the ONLY full-install caller, and it short-circuits at
# its own fast path BEFORE reaching _write_cgroup_delegation. So the #496 "re-surface
# an inactive drop-in on re-run" guarantee has to hold on THAT path too, or the whole
# fix is dead on every 2nd+ full install (the exact #514 reviewer catch).
@test "_ensure_cgroup_delegation: drop-in present but NOT active -> fast path re-surfaces the warning, still no privileged call (#514)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; mkdir -p "$TB_USER_UNIT_DROPIN_DIR"
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  cf="$(mktemp)"; echo "memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"   # written last run, not live yet
  PROBE_PRIVILEGE=no_sudo
  sudo() { record "sudo $*"; }
  run _ensure_cgroup_delegation
  [[ "$output" == *"NOT active in this session"* ]] || return 1   # NOT a silent "already present" log
  [[ "$output" == *"k3d cluster delete"* ]] || return 1           # full-install remedy (not prepare-host mode here)
  run mock_calls
  [ -z "$output" ] || return 1                                     # …and still no sudo/systemctl (unprivileged read only)
}

@test "_ensure_cgroup_delegation: drop-in present AND active -> fast path confirms active, no privileged call (#514)" {
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"; mkdir -p "$TB_USER_UNIT_DROPIN_DIR"
  printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$TB_USER_UNIT_DROPIN_DIR/delegate.conf"
  cf="$(mktemp)"; echo "cpuset cpu io memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"
  PROBE_PRIVILEGE=no_sudo
  sudo() { record "sudo $*"; }
  run _ensure_cgroup_delegation
  [[ "$output" == *"active in this session"* ]] || return 1
  [[ "$output" != *"NOT active"* ]] || return 1
  run mock_calls
  [ -z "$output" ] || return 1
}

# The prepare-host caller resets TB_PREPARE_HOST_MODE right after install_docker_engine,
# so without re-setting it around the cgroup write the report would judge the ADMIN's
# live slice and print the "recreate the cluster" advice prepare-host can't act on
# (#514 reviewer). Drive the REAL run_prepare_host, not _write_cgroup_delegation direct.
@test "run_prepare_host: cgroup drop-in is reported in prepare-host mode — researcher wording, no cluster-delete, admin slice ignored (#514)" {
  MOCK_CALLS="$(mktemp)"
  OS=Linux; TB_PREPARE_USER=researcher
  TB_USER_UNIT_DROPIN_DIR="$(mktemp -d)/user@.service.d"
  cf="$(mktemp)"; echo "memory pids" > "$cf"; TB_USER_CGROUP_CONTROLLERS="$cf"   # admin's own slice: inactive
  host_audit()           { :; }
  preflight_sudo()       { :; }
  setup_pm()             { :; }
  apt_wait_for_lock()    { :; }
  install_docker_engine(){ :; }
  install_system_deps()  { :; }
  systemctl()            { :; }
  sudo()                 { record "sudo $*"; return 0; }   # fakes the drop-in write (idempotent path)
  run run_prepare_host
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"researcher's next login"* ]] || return 1      # mode-aware wording, not judged on the admin
  [[ "$output" != *"k3d cluster delete"* ]] || return 1           # prepare-host creates no cluster to recreate
  [[ "$output" != *"NOT active in this session"* ]] || return 1
}
