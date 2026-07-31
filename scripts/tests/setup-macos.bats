#!/usr/bin/env bats
# Tests for macOS CLI-tool provisioning (#429). kubectl/k3d/helm now come from the
# SAME pinned, checksum-verified direct-download path as Linux (the shared fetchers,
# OS-aware via OS_DL) instead of bare `brew install`, which floated to latest and
# silently ignored the K3D_VERSION/HELM_VERSION pins. Also covers the portable
# _verify_sha256 (common.sh: sha256sum on Linux, shasum on macOS) and OS_DL platform
# selection in the shared fetchers. Runs on the Linux CI runner too: the OS-specific
# behaviour is driven by OS_DL, not by the host, so it is deterministic everywhere.
load test_helper

setup() {
  # Both OS libs are always sourced by the installer; the macOS path calls into the
  # shared (setup-linux.sh) fetchers, so this suite needs both.
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-linux.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"
  LOG_FILE=/dev/null
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="curl tar gzip"
  ARCH_DL="amd64"
  TB_TOOLS_DIR="$BATS_TEST_TMPDIR/bin"; TB_TOOLS_SUDO=""
  mkdir -p "$TB_TOOLS_DIR"
  has()      { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  spin_cmd() { record "spin_cmd $*"; local _m="$1"; shift; "$@"; }
  sudo()     { record "sudo $*"; "$@"; }
}

# ── _verify_sha256: portable, fail-closed (common.sh) ────────────────────────
@test "_verify_sha256: correct hash passes, wrong fails, empty expected fails closed (#429)" {
  local f="$BATS_TEST_TMPDIR/empty"; : > "$f"     # 0-byte file → the well-known empty sha256
  local empty_sha=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  run _verify_sha256 "$empty_sha" "$f"; [ "$status" -eq 0 ]        # matches (real sha256sum/shasum)
  run _verify_sha256 deadbeefdeadbeef "$f"; [ "$status" -ne 0 ]    # mismatch
  run _verify_sha256 "" "$f"; [ "$status" -ne 0 ]                  # empty expected → fail closed
}

@test "_verify_sha256: falls back to shasum when sha256sum is unavailable (macOS ships no sha256sum) (#429)" {
  local f="$BATS_TEST_TMPDIR/x"; printf 'data' > "$f"
  # Hide sha256sum from command -v; leave everything else resolvable.
  command() { case "$2" in sha256sum) return 1 ;; *) builtin command "$@" ;; esac; }
  shasum()  { record "shasum $*"; cat >/dev/null; return 0; }
  run _verify_sha256 abc123 "$f"
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"shasum -a 256 --check"* ]]     # the macOS fallback tool was used
}

# ── OS_DL platform selection in the shared fetchers ──────────────────────────
_k3d_dl_setup_darwin() {
  OS_DL="darwin"
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
      */checksums.txt) [ -n "$out" ] && printf '%s  _dist/k3d-darwin-amd64\n' "${CHECKSUM_LINE_SHA:-cafe01}" >"$out" ;;
      */k3d-darwin-*)  [ -n "$out" ] && printf 'k3d-binary-bytes' >"$out" ;;
    esac
    return 0
  }
}

@test "_fetch_k3d_release: OS_DL=darwin fetches + verifies the darwin asset, never the linux one (#429)" {
  _k3d_dl_setup_darwin
  run _fetch_k3d_release v5.9.0 amd64
  [ "$status" -eq 0 ]
  [ -f "$TB_TOOLS_DIR/k3d" ]
  run mock_calls
  [[ "$output" == *"releases/download/v5.9.0/k3d-darwin-amd64"* ]]   # darwin asset
  [[ "$output" == *"sha256sum --check"* ]]                           # still verified
  [[ "$output" != *"k3d-linux-"* ]]                                  # not the linux asset
}

@test "_fetch_k3d_release: OS_DL=darwin + checksum mismatch fails closed, nothing installed (#429)" {
  _k3d_dl_setup_darwin
  SHA_RC=1
  run _fetch_k3d_release v5.9.0 amd64
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum verification failed"* ]]
  [ ! -f "$TB_TOOLS_DIR/k3d" ]
}

@test "_fetch_kubectl: OS_DL=darwin uses the darwin download path (#429)" {
  OS_DL="darwin"
  sha256sum() { cat >/dev/null; return 0; }
  curl() {
    record "curl $*"
    local prev="" a
    for a in "$@"; do [ "$prev" = "-o" ] && printf 'x' >"$a"; prev="$a"; done
    return 0
  }
  run _fetch_kubectl v1.29.4 amd64
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"/bin/darwin/amd64/kubectl"* ]]
  [[ "$output" != *"/bin/linux/"* ]]
}

_helm_dl_setup_darwin() {
  OS_DL="darwin"
  sha256sum() { record "sha256sum $*"; return "${SHA_RC:-0}"; }
  tar() {
    record "tar $*"
    local prev="" a dest=""
    for a in "$@"; do [ "$prev" = "-C" ] && dest="$a"; prev="$a"; done
    mkdir -p "$dest/${OS_DL}-${ARCH_DL}" && printf 'helm-binary' > "$dest/${OS_DL}-${ARCH_DL}/helm"
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
      *.tar.gz.sha256sum) [ -n "$out" ] && printf '%s  %s\n' "${CHECKSUM_LINE_SHA:-cafe01}" "$(basename "${url%.sha256sum}")" >"$out" ;;
      *.tar.gz)           [ -n "$out" ] && printf 'helm-tarball-bytes' >"$out" ;;
    esac
    return 0
  }
}

@test "_fetch_helm_release: OS_DL=darwin fetches + unpacks the darwin tarball (#429)" {
  _helm_dl_setup_darwin
  run _fetch_helm_release v4.2.3 amd64
  [ "$status" -eq 0 ]
  [ -f "$TB_TOOLS_DIR/helm" ]
  run mock_calls
  [[ "$output" == *"get.helm.sh/helm-v4.2.3-darwin-amd64.tar.gz"* ]]
  [[ "$output" == *"helm-v4.2.3-darwin-amd64.tar.gz.sha256sum"* ]]
  [[ "$output" == *"sha256sum --check"* ]]
  [[ "$output" != *"-linux-"* ]]
}

# ── install_macos_cli_tools: routes through the shared pinned installers ──────
@test "install_macos_cli_tools: sets OS_DL=darwin + /usr/local/bin, delegates to the pinned installers, no bare brew (#429)" {
  sudo()          { record "sudo $*"; return 0; }   # don't touch the real /usr/local/bin
  install_kubectl() { record "install_kubectl OS_DL=$OS_DL DIR=$TB_TOOLS_DIR SUDO=$TB_TOOLS_SUDO"; }
  install_k3d()     { record "install_k3d OS_DL=$OS_DL"; }
  install_helm()    { record "install_helm OS_DL=$OS_DL"; success "System tools"; }
  brew()            { record "brew $*"; }            # must NOT be used for the CLI tools
  run install_macos_cli_tools
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"install_kubectl OS_DL=darwin DIR=/usr/local/bin SUDO=sudo"* ]]
  [[ "$output" == *"install_k3d OS_DL=darwin"* ]]
  [[ "$output" == *"install_helm OS_DL=darwin"* ]]
  [[ "$output" == *"sudo mkdir -p /usr/local/bin"* ]]
  [[ "$output" != *"brew install kubectl"* ]]        # pins no longer floated by brew
  [[ "$output" != *"brew install k3d"* ]]
  [[ "$output" != *"brew install helm"* ]]
}
