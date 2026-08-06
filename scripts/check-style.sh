#!/usr/bin/env bash
# =============================================================================
#  check-style.sh — enforce the tracebloc terminal style system + terminology
#                   on the installer scripts. See STYLE.md.
#
#  Runs in CI (the "Static analysis" job) and locally:  bash scripts/check-style.sh
#  Exit 0 = clean, 1 = violations found, 2 = the guard itself errored (fail-closed).
#
#  Three mechanical checks (semantic calls — role misuse, judgement-y wording —
#  stay with CODEOWNERS review + STYLE.md; a grep can't police those). Emoji are
#  intentionally NOT policed — they're welcome (see STYLE.md):
#    1. No hardcoded brand colour outside the colour engine (scripts/lib/common.sh).
#    2. No 'workspace' in user-facing text — the term is "secure environment".
#       Internal identifiers (the DNS-1123 sanitisers) and comments are exempt.
#    3. No bare 'curl' — every fetch carries the minimum TLS version. INTERIM,
#       see the note on the check itself.
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
  # No 2>/dev/null: let a real grep error surface on stderr — rc>=2 below turns
  # it into a fail-closed exit, so the error is visible AND fatal, never a silent pass.
  # shellcheck disable=SC2086
  out="$(grep -rnE $flags --include='*.sh' --include='*.ps1' --exclude='check-style.sh' \
    --exclude-dir='tests' "$re" scripts/)"
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

# 2) Banned terminology in user-facing text: 'workspace' -> 'secure environment'.
#    Exempt: comments (content starts with #, anchored to the file:line: prefix)
#    and the internal DNS-1123 sanitiser identifiers.
scan 'workspace' '-i'
report "banned term 'workspace' in user-facing text — use 'secure environment' (see STYLE.md)" \
  "$(printf '%s' "$hits" \
      | grep -vE '(_sanitize_workspace_name|ConvertTo-WorkspaceName|[Ww]orkspace[_-]?[Nn]ame)' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"

# 3) Bare `curl` — the TLS floor must not be losable.
#
#    INTERIM CHECK. tracebloc/.github's shared code-quality workflow already
#    implements this properly (its `house-rules` job has quote-aware, heredoc-aware
#    `curl-tls` and `curl-timeout` rules — a lexer, not a grep). Retire this block
#    the moment this repo adds that caller; it exists only because that workflow
#    is not yet on `main` and cannot be referenced from here until it is.
#
#    Why it's worth an interim grep: the floor used to be a bare constant every
#    call site had to splice in by hand, and seven had silently lost it — one of
#    them the POST that carries the client's password (backend#1252). Calls now go
#    through curl_secure() in common.sh, which cannot be spliced in wrongly.
#
#    Mechanics: \bcurl\b matches the bare command word and NOT curl_secure /
#    curl_pid / nocurl. Exempt are (a) any line naming --tlsv1.2 itself — the
#    bootstrap scripts/install.sh is the trust root that FETCHES common.sh, so it
#    cannot source curl_secure and hardcodes the flags instead, as does the WSL
#    here-string in install-k8s.ps1; (b) comments; (c) `has curl` / `command -v
#    curl` presence tests; (d) the `curl … | sh` install one-liner we print for the
#    user to copy. The timeout half of the rule needs no grep: curl_secure supplies
#    default bounds to everything that can source it.
scan '\bcurl\b'
report "bare 'curl' — call curl_secure() from ${ENGINE} so the TLS floor and timeouts can't be lost (backend#1252)" \
  "$(printf '%s' "$hits" \
      | grep -vE -e '--tlsv1\.2' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | grep -vE '(has curl|command -v curl)' \
      | grep -vE 'curl[^|]*\|[[:space:]]*(sh|bash)' || true)"

# 4) Product name is lowercase 'tracebloc' in user-facing text — never capital-T
#    'Tracebloc'. The installer copy must feel one-to-one across platforms; the
#    bash script is the gold standard (#576). Exempt: comments, and PascalCase code
#    identifiers — function names (Get-Tracebloc… , matched by a leading '-') and
#    the 'TraceblocInstallerResume' resume key (matched by a following uppercase
#    letter). Opt out a real edge with a trailing `# style-guard: allow`.
scan 'Tracebloc'
report "capital-T 'Tracebloc' in user-facing text — the product name is lowercase 'tracebloc' (see STYLE.md)" \
  "$(printf '%s' "$hits" \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | grep -vE 'Tracebloc[A-Z]' \
      | grep -vE '[-]Tracebloc' || true)"

if [[ "$guard_error" -ne 0 ]]; then
  echo "  [!] the guard hit an internal error — failing closed (exit 2)" >&2
  exit 2
fi
if [[ "$fail" -eq 0 ]]; then
  echo "  ok: style + terminology clean"
fi
exit "$fail"
