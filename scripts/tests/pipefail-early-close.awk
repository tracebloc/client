# pipefail-early-close.awk — find pipelines that can SIGPIPE their own producer
# and abort the script (backend#1778).
#
# THE CLASS
# ---------
# Under `set -o pipefail` AND `set -e`, a diagnostic like `producer | head -n N`
# aborts its own caller once the producer's output outgrows the ~64KB pipe
# buffer: head closes the pipe, the producer takes SIGPIPE, the pipeline returns
# 141, and errexit kills the script — usually skipping the cleanup and the
# intended exit code that followed.
#
# It is SIZE-DEPENDENT, which is why instances survive review. Measured on the
# client#656 case: 50 matching lines exit 1 (fits the buffer, no signal), 20k
# exit 141. "Benign because the output is small today" is exactly how that one
# lasted, and it has now cost two separate incidents.
#
# The house idiom is a here-string (or capture-then-slice), never a pipe into an
# early-closing reader:
#     head -25 <<<"$captured"          # no pipe, nothing to SIGPIPE
#     first="${out%%$'\n'*}"           # pure-bash slicing
#
# WHAT IS FLAGGED
# ---------------
# A line piping into an early-closing reader (`head`, `grep -q`), in a file that
# enables BOTH errexit and pipefail. Both are required: pipefail alone makes the
# pipeline return 141 but nothing acts on it, and errexit alone never sees a
# non-zero because the last command (head) succeeded.
#
# NOT flagged, because the status is already neutralised or the risk is absent:
#   - a line ending in `|| true` (or `|| :`)
#   - comments
#   - files that do not enable both options
#   - a line carrying a trailing `# pipefail-guard: allow` marker
#
# Usage:  awk -f pipefail-early-close.awk FILE...
# Output: one `path:line: code` per offender. Exit status is always 0; the
#         caller decides (the bats gate treats any output as failure).

# A file runs under errexit+pipefail either because it sets both itself, or
# because a file that does SOURCES it — `scripts/lib/*.sh` are the whole
# installer and set neither (Bugbot on #763). The inherited set is resolved by
# pipefail-early-close.sh and passed in as `hazardous`; asking only the file's
# own `set` lines read the entire lib tree as safe.
function inherits(f) {
  return (hazardous != "" && index(hazardous, " " f " ") > 0) \
      || (hazardous != "" && index(" " hazardous, " " f " ") > 0)
}

function flush(  i) {
  if (nlines > 0 && ((has_errexit && has_pipefail) || inherits(curfile))) {
    for (i = 1; i <= nlines; i++) {
      print curfile ":" lineno[i] ": " text[i]
    }
  }
  nlines = 0
  has_errexit = 0
  has_pipefail = 0
}

FNR == 1 {
  if (curfile != "") flush()
  curfile = FILENAME
}

{
  line = $0

  # Shell options. Accept the combined short forms (-euo, -eo) and the long
  # forms, set anywhere in the file — including inside a function, which is
  # where check-drift.sh puts them.
  if (line ~ /^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e[a-zA-Z]*([[:space:]]|$)/) has_errexit = 1
  if (line ~ /^[[:space:]]*set[[:space:]]+-o[[:space:]]+errexit([[:space:]]|$)/) has_errexit = 1
  if (line ~ /pipefail/ && line ~ /^[[:space:]]*set[[:space:]]/) has_pipefail = 1

  # Strip a trailing comment only for the purpose of spotting the marker; the
  # code test below runs on the raw line so a `#` inside a string cannot hide it.
  if (line ~ /#[[:space:]]*pipefail-guard:[[:space:]]*allow/) next

  # Comment lines are prose about the hazard, not the hazard.
  if (line ~ /^[[:space:]]*#/) next

  # Already neutralised: the pipeline's status is discarded, so errexit cannot
  # act on the 141.
  if (line ~ /\|\|[[:space:]]*(true|:)([[:space:]]|$|\))/) next

  # The hazard: a pipe into a reader that closes early.
  #   `| head`        — closes after N lines
  #   `| grep -q`     — closes on the first match
  #   `| grep -m N`   — closes after N matches (same mechanism; found in
  #                     e2e-auto-upgrade.sh two lines below a -q instance)
  if (line ~ /\|[[:space:]]*head([[:space:]]|$)/ \
      || line ~ /\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*q/ \
      || line ~ /\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*m[[:space:]]*[0-9]/) {
    nlines++
    lineno[nlines] = FNR
    sub(/^[[:space:]]+/, "", line)
    text[nlines] = line
  }
}

END { if (curfile != "") flush() }
