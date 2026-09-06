#!/usr/bin/env bash
#
#  bounded-docker-run.sh — run a command under a wall-clock bound and, when the
#  bound fires, say so in words the job log can carry (client#986).
#
#  WHY ONE WRAPPER. The installer-tests workflow runs the real network path
#  inside `docker run` in two jobs. A stalled mirror there used to run until the
#  job's timeout-minutes fired, and a job-level cap reports `cancelled` with no
#  readable step log. Bounding the container run turns that into a FAILED step
#  whose log ends with the command that stalled -- but the bound-and-report logic
#  was pasted into both steps, and the exit-code contract below has one subtle
#  case that must be right in every copy. So it lives here, once, and the
#  workflow guard (workflow-bounded-docker-run.sh) checks that every `docker run`
#  goes through it.
#
#  THE EXIT-CODE CONTRACT, measured (@saqlainsyed007 on client#988, coreutils 9.5):
#    124  the bound fired and the child honoured SIGTERM.
#    137  the bound fired, the child IGNORED SIGTERM, and --kill-after sent
#         SIGKILL. This is the LIKELY path for a container run: the docker CLI
#         proxies TERM to the container's PID 1, and a shell running as PID 1
#         with no handler discards it. A check for 124 alone therefore misses
#         exactly the mirror-stall case this exists for.
#  Both are reported as the bound firing; every other status is the command's own
#  and is passed through untouched, with no annotation.
#
#  FAILS CLOSED. No GNU `timeout` (or `gtimeout`) on PATH means the command
#  cannot be bounded, and an unbounded run is the defect -- refuse with exit 2
#  rather than run it anyway.
#
#  Usage: bounded-docker-run.sh <bound> <label> <command> [args...]
#    bound   a GNU timeout duration, e.g. 12m
#    label   what the command is, for the annotation (e.g. "prerequisite install
#            in ubuntu:24.04")
#    TB_KILL_AFTER  grace between SIGTERM and SIGKILL (default 30s); the unit
#                   tests shorten it.
#
set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <bound> <label> <command> [args...]" >&2
  exit 2
fi
bound="$1"; label="$2"; shift 2

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT=gtimeout
else
  echo "::error::bounded-docker-run.sh: no GNU timeout binary on PATH, so '$label' cannot be bounded -- refusing to run it unbounded" >&2
  exit 2
fi

"$TIMEOUT" --kill-after="${TB_KILL_AFTER:-30s}" "$bound" "$@"
rc=$?
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo "::error::$label exceeded the $bound step bound (timeout exit $rc) - the last lines above name the command that stalled (mirror connectivity, not this PR). Re-run this job."
fi
exit "$rc"
