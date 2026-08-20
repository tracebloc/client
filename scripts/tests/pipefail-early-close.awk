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
# exit 141.
#
# The house idiom is a here-string (or capture-then-slice), never a pipe into an
# early-closing reader:
#     head -25 <<<"$captured"          # no pipe, nothing to SIGPIPE
#     first="${out%%$'\n'*}"           # pure-bash slicing
#
# OPTIONS ARE POSITIONAL, AND THEY GET TURNED OFF TOO (Asad on #763)
# ------------------------------------------------------------------
# An earlier version asked only "does this file ENABLE both options" and so had
# no idea that `set +e` exists. `run_diagnose()` opens with `set +e` precisely so
# no step can abort the bundle, and every line in it was flagged. Best-effort
# regions are a normal idiom here, so that model would need a hand-placed marker
# on each one — which is the opposite of encoding the rule.
#
# So the state is tracked LINE BY LINE: `set -e` / `set +e` / `set -o pipefail` /
# `set +o pipefail` / the combined `set -euo pipefail` all move it, and a line is
# an offender only if BOTH options are live where it sits.
#
# Function scoping is an approximation, deliberately. bash does NOT scope shell
# options to functions — a `set +e` inside one leaks to the caller — but treating
# it as restored at the function's closing brace is the conservative direction
# for a linter: it keeps asking about later code instead of going quiet after the
# first best-effort helper.
#
# `hazardous` (from pipefail-early-close.sh) seeds files that inherit both
# options from a sourcing script; those start with the state already on.
#
# Usage:  awk -v hazardous="<paths>" -f pipefail-early-close.awk FILE...
# Output: one `path:line: code` per offender.

function apply_set(line,   n, a, i, tok, sign, flags) {
  n = split(line, a, /[[:space:]]+/)
  for (i = 1; i <= n; i++) {
    if (a[i] == "set") break
  }
  for (i = i + 1; i <= n; i++) {
    tok = a[i]
    if (tok !~ /^[-+]/) continue
    sign = substr(tok, 1, 1)
    flags = substr(tok, 2)
    # `-o pipefail` / `+o pipefail` — the option name is the NEXT token.
    if (flags ~ /o$/ && (i + 1) <= n && a[i + 1] == "pipefail") {
      p_on = (sign == "-") ? 1 : 0
    }
    # `e` anywhere in a combined short flag (-e, -eu, -euo, +e …).
    if (flags ~ /e/) e_on = (sign == "-") ? 1 : 0
  }
}

function inherits(f) {
  return hazardous != "" && index(" " hazardous " ", " " f " ") > 0
}

FNR == 1 {
  curfile = FILENAME
  # A file that inherits both options from its sourcer starts with them live.
  e_on = inherits(curfile) ? 1 : 0
  p_on = inherits(curfile) ? 1 : 0
  in_fn = 0; save_e = 0; save_p = 0
}

{
  line = $0

  # Function boundaries, so a best-effort region ends with its function.
  if (line ~ /^[a-zA-Z_][a-zA-Z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*\{/) {
    save_e = e_on; save_p = p_on; in_fn = 1; next
  }
  if (line ~ /^\}/ && in_fn) { e_on = save_e; p_on = save_p; in_fn = 0; next }

  if (line ~ /^[[:space:]]*set[[:space:]]/) { apply_set(line); next }

  if (line ~ /#[[:space:]]*pipefail-guard:[[:space:]]*allow/) next
  if (line ~ /^[[:space:]]*#/) next

  # Already neutralised: the pipeline's status is discarded, so errexit cannot
  # act on the 141.
  if (line ~ /\|\|[[:space:]]*(true|:)([[:space:]]|$|\))/) next

  if (!(e_on && p_on)) next

  # The hazard: a pipe into a reader that closes early.
  #   `| head`        — closes after N lines
  #   `| grep -q`     — closes on the first match
  #   `| grep -m N`   — closes after N matches
  if (line ~ /\|[[:space:]]*head([[:space:]]|$)/ \
      || line ~ /\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*q/ \
      || line ~ /\|[[:space:]]*grep[^|]*[[:space:]]-[a-zA-Z]*m[[:space:]]*[0-9]/) {
    sub(/^[[:space:]]+/, "", line)
    print curfile ":" FNR ": " line
  }
}
