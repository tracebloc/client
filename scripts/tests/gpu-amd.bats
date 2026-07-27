#!/usr/bin/env bats
# Tests for scripts/lib/gpu-amd.sh — the AMD ROCm package-discovery helper.
#
# The load-bearing property: install-k8s.sh sources this lib under
# `set -euo pipefail`, so _find_package_name must NEVER fail the shell. Its
# callers all report failure themselves via `[[ -z "$name" ]] && error …`, and
# the RHEL path depends on a second call after an empty first one. A non-zero
# exit from this function aborts the installer before any of that runs.
#
# Two ways it used to fail (both fixed, both covered below):
#   1. a failed fetch propagated out of the command substitution
#   2. `head -1` closing the pipe SIGPIPE'd grep (141), which pipefail turns
#      into a pipeline failure even when a filename WAS found
#
# macOS-bats blindspot (see assess.bats): bash 3.2 can silently pass a failing
# bare `[[ … ]]` used as a test's last statement, so every assertion here ends
# in an explicit `return 1` and status checks use single brackets.
load test_helper

setup() {
  load_lib gpu-amd.sh
}

# Assert $1 equals $2, loudly, on every bash.
assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'expected: %s\ngot:      %s\n' "$2" "$1" >&2
    return 1
  fi
}

@test "returns the filename from a directory index" {
  curl_secure() { printf '<a href="amdgpu-install_6.2.60200-1_all.deb">x</a>\n'; }
  run _find_package_name "https://example.invalid/ubuntu/jammy/" deb
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" "amdgpu-install_6.2.60200-1_all.deb"
}

@test "returns only the FIRST match when the index lists several" {
  curl_secure() {
    printf '"amdgpu-install_1.0_all.deb" "amdgpu-install_2.0_all.deb" "amdgpu-install_3.0_all.deb"\n'
  }
  run _find_package_name "https://example.invalid/" deb
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" "amdgpu-install_1.0_all.deb"
}

@test "matches the requested extension only" {
  curl_secure() { printf '"amdgpu-install_1.0_all.deb" "amdgpu-install_1.0.el9.rpm"\n'; }
  run _find_package_name "https://example.invalid/" rpm
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" "amdgpu-install_1.0.el9.rpm"
}

# --- the two set -e / pipefail hazards -------------------------------------

@test "a failed fetch yields empty output and exit 0, so the caller can report it" {
  curl_secure() { return 22; }   # curl's HTTP-error exit code
  run _find_package_name "https://example.invalid/nope/" deb
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" ""
}

@test "a fetch that succeeds but matches nothing yields empty output and exit 0" {
  curl_secure() { printf '<html><body>Index of /</body></html>\n'; }
  run _find_package_name "https://example.invalid/" deb
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" ""
}

@test "survives a large index under pipefail (the old head -1 SIGPIPE'd grep)" {
  # Enough matches that grep's output comfortably exceeds the pipe buffer, which
  # is what made the old `| head -1` kill grep with SIGPIPE (141). Deterministic
  # here; on a real mirror it depended on the index size.
  curl_secure() {
    local i=0
    while [ "$i" -lt 20000 ]; do
      printf '"amdgpu-install_%d.0_all.deb"\n' "$i"
      i=$((i + 1))
    done
  }
  set -o pipefail
  run _find_package_name "https://example.invalid/big/" deb
  [ "$status" -eq 0 ] || return 1
  assert_eq "$output" "amdgpu-install_0.0_all.deb"
}

@test "does not abort a caller running under set -euo pipefail" {
  # The regression in full: emulate the caller's shape and prove the friendly
  # error is reached rather than the shell dying at the assignment.
  curl_secure() { return 22; }
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/gpu-amd.sh"
    LOG_FILE=/dev/null
    curl_secure() { return 22; }
    name="$(_find_package_name "https://example.invalid/" deb)"
    [[ -z "$name" ]] && { echo "REACHED_ERROR_PATH"; exit 3; }
    echo "WRONGLY_CONTINUED"
  '
  [ "$status" -eq 3 ] || return 1
  printf '%s\n' "$output" | grep -q REACHED_ERROR_PATH || return 1
}
