#!/usr/bin/env bash
# =============================================================================
#  check-style.sh — enforce the tracebloc terminal style system + terminology
#                   on the installer scripts. See STYLE.md.
#
#  Runs in CI (the "Static analysis" job) and locally:  bash scripts/check-style.sh
#  Exit 0 = clean, 1 = violations found, 2 = the guard itself errored (fail-closed).
#
#  Three mechanical checks (semantic calls — role misuse, judgement-y wording —
#  stay with CODEOWNERS review + STYLE.md; a grep can't police those):
#    1. No hardcoded brand colour outside the colour engine (scripts/lib/common.sh).
#    2. No status / traffic-light emoji — the lime dot is the online indicator.
#    3. No 'workspace' in user-facing text — the term is "secure environment".
#       Internal identifiers (the DNS-1123 sanitisers) and comments are exempt.
#
#  A line may opt out of ANY check with a trailing  # style-guard: allow  marker.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# Fail CLOSED: a mis-run guard (wrong dir, missing tree) must never look like a
# pass — that would let regressions through the blocking gate silently.
[[ -d scripts ]] || { echo "check-style: scripts/ not found — refusing to report clean" >&2; exit 2; }

ENGINE='scripts/lib/common.sh'   # the one place raw brand colour legitimately lives
fail=0
guard_error=0
hits=''

# scan REGEX [EXTRA_FLAGS] — call in the PARENT shell (scan …, never $(scan …)),
# so the guard_error it sets on a grep internal error actually reaches the parent
# and the fail-closed exit below is reachable. Sets `hits` to the matches (this
# guard + opt-out lines removed). grep exit 2+ (bad regex/flags/tree) → fail closed.
scan() {
  local re="$1" flags="${2:-}" out rc
  # shellcheck disable=SC2086
  out="$(grep -rnE $flags --include='*.sh' --include='*.ps1' --exclude='check-style.sh' \
    --exclude-dir='tests' "$re" scripts/ 2>/dev/null)"
  rc=$?
  if [[ "$rc" -ge 2 ]]; then
    echo "check-style: grep errored (rc=$rc) on /$re/ — failing closed" >&2
    guard_error=1; hits=''; return
  fi
  hits="$(printf '%s' "$out" | grep -vE '# *style-guard: *allow' || true)"
}

report() { # TITLE  MATCHES
  [[ -z "$2" ]] && return 0
  printf '\n  [x] %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/      /'
  fail=1
}

echo "== tracebloc style guard =="

# 1) Hardcoded brand colour outside the engine (case-insensitive: #01A5CC too).
brand='#?(01a5cc|91e947|a7ed6c|01637a|578c2b|34b7d6)|38;2;(1;165;204|145;233;71|167;237;108|1;99;122|87;140;43)'
scan "$brand" '-i'
report "hardcoded brand colour — use the TB_* tones from ${ENGINE}, don't re-hardcode hex/RGB" \
  "$(printf '%s' "$hits" | grep -vE "^${ENGINE}:" || true)"

# 2) Status / traffic-light emoji. Pattern built from bytes so the guard's own
#    source stays emoji-free (green/red/yellow/orange circles).
emoji="$(printf '\360\237\237\242|\360\237\224\264|\360\237\237\241|\360\237\237\240')"
scan "$emoji"
report "status emoji — use the lime online dot (see STYLE.md), not traffic-light emoji" "$hits"

# 3) Banned terminology in user-facing text: 'workspace' -> 'secure environment'.
#    Exempt: comments (content starts with #, anchored to the file:line: prefix)
#    and the internal DNS-1123 sanitiser identifiers.
scan 'workspace' '-i'
report "banned term 'workspace' in user-facing text — use 'secure environment' (see STYLE.md)" \
  "$(printf '%s' "$hits" \
      | grep -vE '(_sanitize_workspace_name|ConvertTo-WorkspaceName|[Ww]orkspace[_-]?[Nn]ame)' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [[ "$guard_error" -ne 0 ]]; then
  echo "  [!] the guard hit an internal error — failing closed (exit 2)" >&2
  exit 2
fi
if [[ "$fail" -eq 0 ]]; then
  echo "  ok: style + terminology clean"
fi
exit "$fail"
