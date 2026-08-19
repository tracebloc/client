#!/usr/bin/env bats
# Apple Silicon arch/emulation handling (#433). The client images are amd64-only.
# On Apple Silicon the installer must (a) start colima with VZ + Rosetta so amd64 is
# accelerated, and (b) SMOKE-TEST amd64 emulation once Docker is up — failing loudly
# with the exact Rosetta setting rather than letting an amd64-only pod crash-loop
# later. Runs on Linux CI too: behaviour is driven by ARCH / TB_MACOS_VER, not the
# host. A separate file from setup-macos.bats to avoid a file-add clash with #429.
load test_helper

setup() {
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/preflight.sh"   # _macos_vm_mem_gb (used by _install_docker_colima)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"
  LOG_FILE=/dev/null
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="docker colima"
  ARCH="arm64"; OS="Darwin"
  has()             { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd()        { local _m="$1"; shift; record "spin_cmd $*"; "$@"; }
  spin_cmd_bounded(){ local _s="$1" _m="$2"; shift 2; record "spin_cmd_bounded $_s $*"; "$@"; }
  _macos_vm_mem_gb(){ echo 6; }
  # assert_amd64_emulation now asks the engine rule (client#748): only the 5.7
  # image needs emulation. install-client-helm.sh is NOT sourced here, so mock the
  # two functions it would provide — default to 5.7 so the smoke-path tests below
  # are deterministic rather than passing because the function is undefined; the
  # 8.4 test overrides it.
  _mysql_engine_decision(){ echo "5.7 explicit"; }
  _client_values_file(){ echo ""; }
}

# ── _macos_supports_vz ───────────────────────────────────────────────────────
@test "_macos_supports_vz: macOS 13+ -> yes; 12 -> no; junk -> no (#433)" {
  TB_MACOS_VER=14.5; run _macos_supports_vz; [ "$status" -eq 0 ] || return 1
  TB_MACOS_VER=13.0; run _macos_supports_vz; [ "$status" -eq 0 ] || return 1
  TB_MACOS_VER=12.7; run _macos_supports_vz; [ "$status" -ne 0 ] || return 1
  TB_MACOS_VER=abc;  run _macos_supports_vz; [ "$status" -ne 0 ] || return 1
}

@test "_macos_supports_vz: undeterminable version (sw_vers empty) -> no (fail closed to QEMU) (#433)" {
  unset TB_MACOS_VER
  sw_vers() { echo ""; }               # can't read the version → treat as unsupported
  run _macos_supports_vz
  [ "$status" -ne 0 ] || return 1
}

# ── colima VZ/Rosetta flags ──────────────────────────────────────────────────
_colima_env() {
  # docker info fails until colima "starts" (creates the marker), so the function
  # runs its start path exactly once, then the post-start readiness check passes.
  # `colima list --json` reports an existing instance only when COLIMA_HAS_INSTANCE=1.
  colima() {
    case "$1" in
      list)  [[ "${COLIMA_HAS_INSTANCE:-0}" == 1 ]] && echo '{"name":"default","status":"Stopped"}' ;;
      start) record "colima $*"; touch "$BATS_TEST_TMPDIR/up" ;;
      *)     record "colima $*" ;;
    esac
  }
  docker() { case "$1" in info) [ -f "$BATS_TEST_TMPDIR/up" ] ;; *) return 0 ;; esac; }
}

@test "_install_docker_colima: Apple Silicon + macOS 13+ -> colima start with VZ + Rosetta (#433)" {
  _colima_env; ARCH=arm64; TB_MACOS_VER=14.0
  run _install_docker_colima
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"colima start"* ]] || return 1
  [[ "$output" == *"--vm-type vz --vz-rosetta"* ]] || return 1
}

@test "_install_docker_colima: Apple Silicon + macOS 13+ but an EXISTING VM -> no VZ flags (colima rejects vmType change) (#433 Bugbot)" {
  _colima_env; ARCH=arm64; TB_MACOS_VER=14.0; COLIMA_HAS_INSTANCE=1
  run _install_docker_colima
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"colima start"* ]] || return 1
  [[ "$output" != *"--vm-type vz"* ]] || return 1     # don't force a vmType change on the existing VM
  [[ "$output" != *"--vz-rosetta"* ]] || return 1
}

@test "_install_docker_colima: Apple Silicon + macOS 12 -> QEMU default, no VZ flags (#433)" {
  _colima_env; ARCH=arm64; TB_MACOS_VER=12.7
  run _install_docker_colima
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"colima start"* ]] || return 1
  [[ "$output" != *"--vm-type vz"* ]] || return 1
  [[ "$output" != *"--vz-rosetta"* ]] || return 1
}

@test "_install_docker_colima: Intel Mac -> no VZ/Rosetta flags (amd64 native) (#433)" {
  _colima_env; ARCH=x86_64; TB_MACOS_VER=14.0
  run _install_docker_colima
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"colima start"* ]] || return 1
  [[ "$output" != *"--vm-type vz"* ]] || return 1
}

# ── assert_amd64_emulation (post-Docker smoke) ───────────────────────────────
@test "assert_amd64_emulation: Apple Silicon + engine resolves to 8.4 -> skips the smoke, no docker run (client#748)" {
  ARCH=arm64
  _mysql_engine_decision(){ echo "8.4 fresh"; }   # a fresh Mac serves 8.4 natively
  docker() { record "docker $*"; return 1; }       # would FAIL the smoke if it ran
  run assert_amd64_emulation
  [ "$status" -eq 0 ] || return 1                   # not refused
  [[ "$output" == *"runs the client images natively"* ]] || return 1
  run mock_calls
  [[ "$output" != *"docker run"* ]] || return 1     # emulation it does not need is never probed
}

@test "assert_amd64_emulation: Apple Silicon + engine 5.7 + broken emulation -> fails naming the 5.7 engine (client#748)" {
  ARCH=arm64
  _mysql_engine_decision(){ echo "5.7 existing-datadir"; }
  docker() { record "docker $*"; return 1; }
  run assert_amd64_emulation
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"MySQL 5.7 engine"* ]] || return 1   # accurate: it is the 5.7 image, not "all client images"
  [[ "$output" == *"Use Rosetta"* ]] || return 1
}

@test "assert_amd64_emulation: Intel Mac -> no-op, no docker run (#433)" {
  ARCH=x86_64
  docker() { record "docker $*"; return 0; }
  run assert_amd64_emulation
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"docker run"* ]] || return 1        # native amd64 — nothing to probe
}

@test "assert_amd64_emulation: Apple Silicon + working emulation -> forces linux/amd64, time-bounded, succeeds (#433)" {
  ARCH=arm64
  docker() { record "docker $*"; return 0; }
  run assert_amd64_emulation
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"amd64 emulation verified"* ]] || return 1
  run mock_calls
  [[ "$output" == *"docker run --rm --platform linux/amd64"* ]] || return 1
  [[ "$output" == *"busybox:1.36 true"* ]] || return 1
  [[ "$output" == *"spin_cmd_bounded 120 docker run"* ]] || return 1   # bounded, not an unbounded spin_cmd (#433 Bugbot)
}

@test "assert_amd64_emulation: Apple Silicon + broken emulation -> hard fail naming the Rosetta setting (#433)" {
  ARCH=arm64
  docker() { record "docker $*"; return 1; }   # exec-format error / no emulation
  run assert_amd64_emulation
  [ "$status" -ne 0 ] || return 1                           # error() exits — caught in the field before a crash-looping pod
  [[ "$output" == *"Use Rosetta for x86_64/amd64 emulation"* ]] || return 1   # names the exact setting
  [[ "$output" == *"colima start --vm-type vz --vz-rosetta"* ]] || return 1   # and the colima remedy
  [[ "$output" == *"TRACEBLOC_ALLOW_ARM64=1"* ]] || return 1                  # and the escape hatch
}

@test "assert_amd64_emulation: TRACEBLOC_ALLOW_ARM64 set -> skipped with a warning, no docker run (#433)" {
  ARCH=arm64; export TRACEBLOC_ALLOW_ARM64=1
  docker() { record "docker $*"; return 1; }
  run assert_amd64_emulation
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Skipping the amd64 emulation smoke test"* ]] || return 1
  run mock_calls
  [[ "$output" != *"docker run"* ]] || return 1
  unset TRACEBLOC_ALLOW_ARM64
}

@test "assert_amd64_emulation: smoke image is overridable via TB_AMD64_SMOKE_IMAGE (#433)" {
  ARCH=arm64; TB_AMD64_SMOKE_IMAGE="alpine:3.20"
  docker() { record "docker $*"; return 0; }
  run assert_amd64_emulation
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"--platform linux/amd64 alpine:3.20 true"* ]] || return 1
}
