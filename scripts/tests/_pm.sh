# shellcheck shell=bash
# =============================================================================
#  _pm.sh — the bounded package-manager runner, shared by the container harnesses
# -----------------------------------------------------------------------------
#  Sourced by scripts/tests/distro-prereqs.sh and scripts/tests/path-persist.sh.
#  Both run INSIDE a plain distro container with the repo mounted at /src, so a
#  sibling source is just a local file read — it needs no network and no tools
#  beyond the shell that is already running.
#
#  WHY THIS FILE EXISTS. The two harnesses each carried their own copy of
#  `_pm_run`, identical in logic and already drifted in prose. When the apt
#  socket bounds below were added to fix a 12-minute silent hang, they landed on
#  ONE copy — so `Prereqs` was fixed and `PATH persist`, which fails the same
#  way, was not. Bugbot caught that inside the very PR that introduced it
#  (client#1051). One copy, sourced twice, is the only version of this that
#  cannot half-ship.
#
#  What is NOT here: each harness's own `_pm_install_one`. Those genuinely
#  differ — path-persist supports apk, distro-prereqs does not — and folding
#  them together would invent a package-manager matrix neither one tests.
# =============================================================================

# APT NEEDS ITS OWN SOCKET BOUND, not just the external one _pm_run applies.
#
# `timeout 60` around apt kills a stalled fetch, but apt never learns anything:
# it emits NO output, retries nothing, and the next attempt stalls identically.
# The observed failure is three attempts of pure silence — no `Err:`, no `W:`,
# no `E:` — then the job's outer bound killing the container with exit 137. A
# refused connection errors instantly; only a BLACKHOLED route (packets dropped,
# not rejected) hangs like that, and apt's default socket timeout outlasts the
# external kill every time. So the bound was in the wrong place, not missing.
#
# Timeout + Retries are what tracebloc-engine's test workflow already applies to
# its own `apt-get update`, which does not exhibit this failure.
#
# ForceIPv4 is the MITIGATION FOR THE LIKELY CAUSE, not a proven one: a container
# with no working IPv6 egress resolves an AAAA, connects, and waits — the exact
# silent-hang signature. A stalled run emits no apt output, so nothing in the
# logs proves it. It is here because it is cheap and cannot hurt an IPv4-only
# path, not because it was measured.
#
# apt-only, deliberately: dnf/yum/zypper/apk/pacman take none of these flags and
# would fail on an unknown option — turning a mirror stall on one distro into a
# hard argument error on five.
_APT_BOUND='-o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=3 -o Acquire::ForceIPv4=true'

# Bounded + retried package-manager invocation; "$@" = the PM argv.
#
# `command -v` (not has()) because this runs BEFORE common.sh is sourced;
# notices go to stderr.
_pm_run() {
  local i
  for i in 1 2 3; do
    if   command -v timeout  >/dev/null 2>&1; then timeout  "${TB_PM_TIMEOUT:-60}" "$@" && return 0
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "${TB_PM_TIMEOUT:-60}" "$@" && return 0
    else "$@" && return 0; fi
    echo "::warning::package-manager step stalled or failed (attempt $i/3): $*" >&2
    # No backoff after the LAST attempt, so a dead mirror fails RED here well
    # under the job's timeout-minutes rather than running the clock out into a
    # silent `cancelled` (the failure class of backend#2859).
    [ "$i" -lt 3 ] && sleep $((i * 5))
  done
  echo "::error::package-manager step failed after 3 bounded attempts: $* — the package manager could not reach its mirrors from inside the CI container. This is NOT this PR's diff. Re-running often does NOT help: two consecutive attempts failed identically on 2026-09-11. If apt, the attempts above should carry Acquire::* bounds; if they did not, that is the bug." >&2
  return 1
}
