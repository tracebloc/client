#!/usr/bin/env bash
# =============================================================================
#  check-style.sh — enforce the tracebloc terminal style system + terminology
#                   on the installer scripts. See STYLE.md.
#
#  Runs in CI as part of the REQUIRED "Source-of-truth drift" check (via
#  `make drift`), and locally:  bash scripts/check-style.sh
#  It used to run in the "Static analysis" job, which is required on no branch —
#  so until 2026-08-19 a violation here printed red and merged anyway.
#  Exit 0 = clean, 1 = violations found, 2 = the guard itself errored (fail-closed).
#
#  Seven mechanical checks (semantic calls — role misuse, judgement-y wording —
#  stay with CODEOWNERS review + STYLE.md; a grep can't police those). Emoji are
#  intentionally NOT policed — they're welcome (see STYLE.md):
#    1. No hardcoded brand colour outside the colour engine (scripts/lib/common.sh).
#    2. No 'workspace' in user-facing text — the term is "secure environment".
#       Internal identifiers (the DNS-1123 sanitisers) and comments are exempt.
#    3. No bare 'curl' — every fetch carries the minimum TLS version. INTERIM,
#       see the note on the check itself.
#    4. No capital-T 'Tracebloc' in user-facing text — the product name is
#       lowercase. Comments and PascalCase identifiers are exempt.
#    5. No unbounded DAEMON READ in scripts/lib/ — 'docker info|ps|inspect|version'
#       all route through _docker_answers / _bounded (common.sh) so a wedged daemon
#       can't hang the installer (#741, #744; widened past 'info' in client#984,
#       where a bare `docker ps` sat two lines above a gate and defeated it).
#    6. No unbounded 'k3d cluster list' in scripts/lib/ — same daemon, same rule;
#       a wedged engine blocks the call rather than failing it, so `|| true` is
#       not a bound (client#974, the bash twin of client#930).
#    7. Rule 6's CENSUS — rule 6 must find at least the call sites known to exist,
#       so a scan gone vacuous (a renamed file, a nudged regex) reddens instead of
#       reporting coverage it no longer has (backend#2849's house rule).
#
#  This count is asserted by scripts/tests/check-style.bats: it said "Three" while
#  four rules were live (backend#1924). A gate whose own description undercounts
#  it is how a rule gets dropped without anyone noticing.
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
  local re="$1" flags="${2:-}" root="${3:-scripts/}" out rc
  # No 2>/dev/null: let a real grep error surface on stderr — rc>=2 below turns
  # it into a fail-closed exit, so the error is visible AND fatal, never a silent pass.
  # A narrower root (e.g. scripts/lib/) scopes a rule to one subtree; default is the
  # whole scripts/ tree so existing callers are unchanged.
  # shellcheck disable=SC2086
  out="$(grep -rnE $flags --include='*.sh' --include='*.ps1' --exclude='check-style.sh' \
    --exclude-dir='tests' "$re" "$root")"
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

# 5) Unbounded `docker info` in scripts/lib/ — every daemon probe must route through
#    _docker_answers() (yes/no) or _bounded() (needs output) from ${ENGINE}. A bare
#    `docker info` does NOT return against a WEDGED daemon, which is exactly the state
#    that reaches these probes — so it froze the installer with no output (#741, #744).
#    This encodes Bugbot's learned rule ("installer probes must be bounded") as a gate,
#    so it stops recurring in review (.cursor/BUGBOT.md).
#
#    Scope: scripts/lib/ only (the shell installer libs). install-k8s.ps1 bounds its own
#    probes in PowerShell, and kubectl/helm carry their own --request-timeout / --timeout,
#    so this rule stays on docker info rather than redden those other, differently-bounded
#    call sites.
#
#    Match an INVOCATION: `docker info` followed by whitespace-then-flag/redirection/pipe/
#    comment ([-&>|;12#]), a closing paren, or end of line. The `#` catches the bare
#    `docker info   # note` spelling, which otherwise matched none of the alternatives and
#    slipped the gate (Bugbot/LukasWodka, #744). It does NOT loosen the discriminator:
#    whole-line comments are dropped by the `^…:[[:space:]]*#` filter below, and every
#    string mention we exempt ("## docker info", 'sudo docker info', "docker info OK") has a
#    quote or letter as its next char, not `#`. A line counts as bounded only when
#    _bounded / timeout / gtimeout appears BEFORE the probe on it (`…[^#]*docker …info`), so
#    a stray "timeout" in a trailing comment can't mask an unbounded call;
#    `# style-guard: allow` opts out a genuine edge.
#    WIDENED PAST `info` (LukasWodka, client#984). `docker info` was never the only
#    subcommand that talks to the daemon, and the gap was not theoretical: the first
#    cut of client#974 bounded a `k3d cluster list` inside the --diagnose bundle
#    while a bare `docker ps -a` two lines ABOVE it kept the whole group hanging, and
#    this rule could not see it — rule 5 matched only `info`, rule 6 only
#    `k3d cluster list`. The set is the daemon READS on the installer's probe paths:
#    info, ps, inspect, version (`docker version` reports the SERVER version, so it
#    blocks like the others). Mutating subcommands (run/exec/pull/update) carry
#    their own, very different budgets and are deliberately out of this rule.
#    The follow-set includes a QUOTED or EXPANDED first argument (`"` `'` `$`), which
#    is how five of this tree's `docker inspect "k3d-…-server-0"` reads are spelled —
#    a flag-only follow-set walked straight past every one of them. It also includes a
#    line-continuation backslash, the arm rule 6 documents.
docker_probe='docker[[:space:]]+(info|ps|inspect|version)([[:space:]]+[-&>|;12#"'"'"'$]|[[:space:]]*[)]|[[:space:]]+\\[[:space:]]*$|[[:space:]]*$)'
scan "$docker_probe" '' 'scripts/lib/'
report "unbounded daemon read in scripts/lib/ — route 'docker info|ps|inspect|version' through _docker_answers (yes/no) or _bounded (needs output) from ${ENGINE} so a wedged daemon can't hang the installer (#744, client#984)" \
  "$(printf '%s' "$hits" \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
      | grep -vE '(_bounded|_bounded_root|timeout|gtimeout)[^#]*docker[[:space:]]+(info|ps|inspect|version)' || true)"

# 6) Unbounded `k3d cluster list` in scripts/lib/ — the same rule as 5, for the same
#    daemon (client#974, the bash twin of client#930). `k3d cluster list` talks to the
#    Docker engine, so a WEDGED daemon does not FAIL it, it BLOCKS — and every one of
#    the seven pre-fix call sites carried `2>/dev/null || true`, which handles k3d
#    FAILING and was therefore never reached on the input that matters. Three of them
#    were on the main install path (_cluster_presence) and one was inside the --diagnose
#    support bundle, the run collected BECAUSE the machine is already broken.
#    client#973 widened the PowerShell AST guard from `docker` to `docker|k3d`; this is
#    the bash half of that widening, kept as its own rule so rule 5's message stays
#    exactly as specific as it is.
#
#    Mechanics mirror rule 5's: match an INVOCATION — `k3d cluster list` followed by
#    whitespace-then-flag/redirection/pipe/comment, a closing paren, a line-continuation
#    backslash, or end of line. Mentions we must NOT flag all have a quote, a backtick
#    or a letter as the next char ("## k3d cluster list", 'k3d cluster list' in prose,
#    "k3d cluster list did not complete"). The continuation arm is deliberate: rule 5
#    has no such arm, so a `docker info \` spanning two lines would slip it — a `k3d
#    cluster list \` here does not. A line counts as bounded only when _bounded /
#    timeout / gtimeout appears BEFORE the call on it, so a "timeout" in a trailing
#    comment cannot excuse it; `# style-guard: allow` opts out a genuine edge.
k3d_list_probe='k3d[[:space:]]+cluster[[:space:]]+list([[:space:]]+[-&>|;12#]|[[:space:]]*[)]|[[:space:]]+\\[[:space:]]*$|[[:space:]]*$)'
scan "$k3d_list_probe" '' 'scripts/lib/'
k3d_list_sites="$(printf '%s' "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
report "unbounded 'k3d cluster list' in scripts/lib/ — wrap it in _bounded (see gpu-nvidia.sh) so a wedged Docker daemon can't hang the installer or the support bundle (client#974)" \
  "$(printf '%s' "$k3d_list_sites" \
      | grep -vE '(_bounded|timeout|gtimeout)[^#]*k3d[[:space:]]+cluster[[:space:]]+list' || true)"

# 7) THE CENSUS for rule 6 — did rule 6 actually LOOK?
#
#    This is the house rule of backend#2849 applied to this file: a check that cannot
#    distinguish "clean" from "didn't look" is the dominant defect class here. Rule 6
#    is a text scan, and a text scan that matches NOTHING prints exactly as clean as
#    one that matched every site and found them all bounded. Rename scripts/lib/cluster.sh,
#    move _cluster_presence into a file the `--include` misses, or nudge the invocation
#    regex, and rule 6 goes vacuous while still reporting coverage it structurally
#    cannot provide — which is worse than having no rule, because it is believed.
#
#    So rule 6 must also find AT LEAST the sites known to exist. A FLOOR, not an
#    equality: check-style.bats plants extra fixture files under scripts/lib/ to drive
#    rule 6 both ways, and an equality would redden on its own tests. Raise the floor
#    deliberately when a new call site lands — never lower it to make this green, that
#    is the vacuity this rule exists to catch.
#
#    The 8: seven bounded by client#974 (cluster.sh ×5, assess.sh, diagnose.sh) plus
#    gpu-nvidia.sh's, which #431 had already bounded and which is the in-tree precedent
#    the seven were written against.
K3D_LIST_SITES_FLOOR=8
k3d_list_found="$(printf '%s' "$k3d_list_sites" | grep -c . || true)"
report "rule 6 went VACUOUS — it found ${k3d_list_found} 'k3d cluster list' call site(s) under scripts/lib/ but at least ${K3D_LIST_SITES_FLOOR} are known to exist. A scan that matches nothing reports 'clean' identically to one that checked everything; fix the scan (or raise the floor if a site was legitimately removed) rather than trusting this" \
  "$( [[ "$k3d_list_found" -lt "$K3D_LIST_SITES_FLOOR" ]] && printf 'found %s call site(s), floor is %s\n' "$k3d_list_found" "$K3D_LIST_SITES_FLOOR" || true )"

if [[ "$guard_error" -ne 0 ]]; then
  echo "  [!] the guard hit an internal error — failing closed (exit 2)" >&2
  exit 2
fi
if [[ "$fail" -eq 0 ]]; then
  echo "  ok: style + terminology clean"
fi
exit "$fail"
