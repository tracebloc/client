#!/usr/bin/env bash
# =============================================================================
#  distro-prereqs.sh — cross-distro prerequisite-install smoke test
# -----------------------------------------------------------------------------
#  Runs the installer's REAL Linux prerequisite logic inside a fresh distro
#  container and asserts every prerequisite binary lands on PATH:
#
#    setup_pm            → correct package manager detected for this distro
#    install_system_deps → conntrack installed under the right package name (#720)
#    install_docker_engine → correct Docker branch taken (get.docker.com vs the
#                            docker-ce repo for RHEL rebuilds #719, dnf/yum/zypper/
#                            pacman), Docker package actually installed
#    _ensure_kernel_modules → netfilter modules loaded / kernel-modules fallback
#                            (Asad's AlmaLinux xt_addrtype case) — best-effort
#    install_kubectl / install_k3d (PATH-through-sudo #718) / install_helm
#
#  It deliberately does NOT start the Docker daemon or create a k3d cluster —
#  that needs a real kernel + systemd (covered by the e2e job on the Ubuntu
#  runners and by the local Lima/VM matrix). This proves each distro's BRANCH
#  does the right thing, which is where every installer bug we have shipped lived.
#
#  Usage (inside a container, as root):
#    bash scripts/tests/distro-prereqs.sh
#  Typically driven by CI:
#    docker run --rm -v "$PWD:/src:ro" -w /src <distro-image> bash scripts/tests/distro-prereqs.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

# ── Make the container resemble a real host ──────────────────────────────────
# Anyone running the real installer reached it via `curl | bash`, so curl always
# exists and the box has sudo. Minimal base images ship neither — install them
# up front (we are root here) so the rest of the run mirrors a real machine.
# These bootstrap installs run in an EPHEMERAL CI container against distro mirrors
# that occasionally STALL rather than fail. An unbounded package-manager call then
# hangs until the job's `timeout-minutes`, which GitHub reports as `cancelled` — NOT
# a red check — so the failure is silent (this is the exact class that bit the
# sibling path-persist job's opensuse leg on 2026-08-31; backend#2859). Bound each
# attempt and retry: a transient stall recovers, a dead mirror fails FAST with an
# honest error. `command -v` (not has()) because this runs BEFORE common.sh is
# sourced; notices go to stderr. NB: this bounds the harness's own bootstrap only —
# the real installer functions invoked below use common.sh's bounded probes.
_pm_run() { # bounded + retried package-manager invocation; $@ = the PM argv
  local i
  for i in 1 2 3; do
    if   command -v timeout  >/dev/null 2>&1; then timeout  "${TB_PM_TIMEOUT:-60}" "$@" && return 0
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "${TB_PM_TIMEOUT:-60}" "$@" && return 0
    else "$@" && return 0; fi
    echo "::warning::package-manager step stalled or failed (attempt $i/3): $*" >&2
    # No backoff after the LAST attempt, so a dead mirror fails RED here well under
    # the job's timeout-minutes rather than running the clock out into a silent
    # `cancelled` (the failure class of #2859).
    [ "$i" -lt 3 ] && sleep $((i * 5))
  done
  echo "::error::package-manager step failed after 3 bounded attempts: $* — distro-mirror connectivity inside the CI container, not this PR. Re-run this job." >&2
  return 1
}
_pm_install_one() { # install a single package with whatever PM exists
  if   command -v apt-get >/dev/null 2>&1; then _pm_run apt-get update -qq && _pm_run apt-get install -y -qq "$1"
  elif command -v dnf     >/dev/null 2>&1; then _pm_run dnf install -y -q "$1"
  elif command -v yum     >/dev/null 2>&1; then _pm_run yum install -y -q "$1"
  elif command -v zypper  >/dev/null 2>&1; then _pm_run zypper --non-interactive install "$1"
  elif command -v pacman  >/dev/null 2>&1; then _pm_run pacman -Sy --noconfirm "$1"
  fi
}
_bootstrap_host() {
  command -v curl >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && return 0
  echo "── bootstrapping curl + sudo ──"
  # Install sudo and curl independently. The installer calls `sudo` for every
  # privileged step (a real host has it); minimal images may not. Only add curl
  # if the binary is truly absent — RHEL 9 ships curl-minimal, which provides
  # curl, and `dnf install curl` would hit the curl/curl-minimal conflict.
  command -v sudo >/dev/null 2>&1 || _pm_install_one sudo
  command -v curl >/dev/null 2>&1 || _pm_install_one curl
}
_bootstrap_host

# shellcheck source=/dev/null
source "$LIB/common.sh"
# shellcheck source=/dev/null
source "$LIB/setup-linux.sh"

# The real entrypoint runs validate_config first, which guarantees $USER is set
# (usermod -aG docker "$USER" runs under `set -u`). Containers often don't export
# USER — mirror that precondition so we test the install path, not a missing env.
export USER="${USER:-$(id -un)}"

# ── Context banner ───────────────────────────────────────────────────────────
PRETTY="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "  distro : ${PRETTY}"
echo "  arch   : $(uname -m)  (ARCH_DL=${ARCH_DL})"
echo "  kernel : $(uname -r)"
echo "═══════════════════════════════════════════════════════════════════════"

# umask 077 (set by common.sh) would make /usr/local/bin tools root-exec-only;
# install_linux relaxes to 022 around the tool installs — mirror that here.
umask 022

# ── Run the real prereq path ─────────────────────────────────────────────────
setup_pm
echo "→ PM_INSTALL = ${PM_INSTALL}"

install_system_deps

# install_docker_engine installs the Docker package via the distro-specific
# branch, then gates on a *running* daemon — which cannot come up without
# systemd/a real kernel in a bare container. Tolerate that final gate; we only
# assert the binary was installed. (Daemon start-up is covered by the e2e job.)
echo "→ installing Docker (daemon start-up gate is expected to be skipped here)…"
( install_docker_engine ) || echo "  (docker daemon gate skipped — expected in a container)"

install_kubectl
install_k3d
install_helm

# ── Assertions ───────────────────────────────────────────────────────────────
echo ""
echo "── prerequisite check ─────────────────────────────────────────────────"
fail=0
for tool in docker kubectl k3d helm conntrack; do
  if path="$(command -v "$tool" 2>/dev/null)"; then
    ver="$("$tool" --version 2>/dev/null | head -1 || true)"
    printf '  ✔ %-9s %s  %s\n' "$tool" "$path" "${ver:-}"
  else
    printf '  ✖ %-9s MISSING\n' "$tool"
    fail=1
  fi
done
echo "───────────────────────────────────────────────────────────────────────"

if [[ $fail -ne 0 ]]; then
  echo "RESULT: FAIL — a prerequisite did not install on ${PRETTY}"
  exit 1
fi
echo "RESULT: PASS — all prerequisites installed on ${PRETTY}"
