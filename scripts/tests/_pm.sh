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
# refused connection errors instantly; only a stalled one hangs like that, and
# apt's default socket timeout outlasts the external kill every time. So the
# bound was in the wrong place, not missing.
#
# WHY NOT THE FIX tracebloc-engine#1029 USED. That change found the specific
# cause on the RUNNER — the mirrorlist lists the archive over http first and
# https second, http stopped answering on 2026-09-11, and apt walked 52 index
# URLs before falling back — and fixed it by rewriting the mirrorlist to https.
# THAT MUST NOT BE COPIED HERE. These harnesses run inside a BARE distro
# container, and ubuntu:24.04 ships no ca-certificates: rewriting its sources to
# https makes every index fetch fail certificate verification. Measured, in the
# image the job actually uses:
#
#     W: Failed to fetch https://…/InRelease  Certificate verification failed:
#        The certificate is NOT trusted. The certificate issuer is unknown.
#     apt-get update  -> exit 0   (warnings only — it "succeeds" fetching nothing)
#     apt-get install -> exit 100, the package is not installed
#
# An update that exits 0 having fetched nothing is worse than the hang, because
# the failure moves to whatever needed the package. So https is not available to
# us until something installs ca-certificates, which needs apt, which is the
# circle. The bounds below are what IS available.
#
# They are adequate here in a way they were not on the runner. #1029 measured
# Timeout/Retries alone still stalling 29 minutes, but that was ~52 index URLs;
# a bare container lists four suites, so a total stall costs minutes and ends in
# an honest error rather than a 12-minute silent kill. Bounded to something
# useful, at this scale.
#
# apt-only, deliberately: dnf/yum/zypper/apk/pacman take none of these flags and
# would fail on an unknown option — turning a mirror stall on one distro into a
# hard argument error on five.
#
# NOTE `Acquire::http::Timeout` does not govern https connections (#1029), hence
# both. No ForceIPv4: an earlier version of this carried it on the theory that a
# blackholed AAAA caused the stall. #1029 then measured the real cause on the
# runner to be the SCHEME, not the address family. The flag was harmless but its
# stated reason was wrong, and a flag shipped on a contradicted hypothesis is
# the kind of thing that gets copied forward as fact.
_APT_BOUND='-o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=3'

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
