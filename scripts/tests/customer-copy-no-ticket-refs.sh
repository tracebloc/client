#!/usr/bin/env bash
# =============================================================================
#  customer-copy-no-ticket-refs.sh — no internal tracker identifier in a string
#  a customer can see.
#
#  WHY THIS EXISTS
#  ---------------
#  The installer's user-visible copy is what a customer reads on their terminal
#  and pastes into a support ticket. An internal tracker identifier in it
#  ("(backend#1234)", "(RFC-9942 D1)") points at a private repo the reader
#  cannot open, so it explains nothing to them and leaks the shape of our
#  internal tracking. One such warning shipped in cluster.sh, and two refusal
#  messages in install-client-helm.sh / install-k8s.ps1, before this guard
#  existed.
#
#  Code COMMENTS are deliberately out of scope. The public repo's comments are
#  public anyway, they are how the rationale for a guard survives, and a sweep
#  of them is a different (and much larger) decision than this one.
#
#  WHAT IT DERIVES (nothing here is a hand-kept list)
#  --------------------------------------------------
#    * the customer-shipped file set — parsed from scripts/manifest.sha256 (the
#      exact set the bootstraps fetch and verify), plus the two bootstraps
#      themselves, which cannot be in the manifest they verify.
#    * the copy-emitting vocabulary — every function defined in a shipped file
#      whose body calls the language's own output primitive (echo/printf in
#      bash; Write-Host/Write-Warning/Write-Error/Write-Output in PowerShell),
#      plus those primitives themselves and PowerShell's `throw`.
#
#  A line whose FIRST command word is in that vocabulary and which carries a
#  `backend#<n>` or `RFC-<nnnn>` token is an offender. A trailing `# comment`
#  on such a line (whitespace, `#`, no quote after it) is stripped first: the
#  customer does not see it. Known limit: a string continued onto a second
#  line is not seen either — its first word is not an emitter.
#
#  Usage:  customer-copy-no-ticket-refs.sh [REPO_ROOT] [--print-vocab bash|ps]
#  Exit 0 = clean, 1 = offenders found, 2 = the guard itself could not check
#  (fail-closed: unreadable or empty manifest, a listed file that is missing,
#  a vocabulary derivation that found nothing).
# =============================================================================
set -uo pipefail

ROOT=""
PRINT_VOCAB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-vocab) PRINT_VOCAB="${2:-}"; shift 2 ;;
    *) ROOT="$1"; shift ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MANIFEST="$ROOT/scripts/manifest.sha256"
BOOTSTRAPS="scripts/install.sh scripts/install.ps1"
TOKEN_RE='backend#[0-9]+|RFC-[0-9]{4}'

guard_error() { echo "[GUARD ERROR] $*" >&2; echo "              'could not check' is a finding, never 'clean'." >&2; exit 2; }

# ---- 1. the shipped set --------------------------------------------------------
[ -r "$MANIFEST" ] || guard_error "cannot read $MANIFEST"
shipped=""
while read -r _digest path _rest; do
  [ -n "${path:-}" ] || continue
  shipped="$shipped $path"
done < "$MANIFEST"
[ -n "$shipped" ] || guard_error "$MANIFEST lists zero files"
shipped="$shipped $BOOTSTRAPS"
for f in $shipped; do
  [ -r "$ROOT/$f" ] || guard_error "shipped file is missing or unreadable: $f"
done

# ---- 2. the vocabulary, derived ---------------------------------------------------
# derive_emitters FILE DEF_RE EMIT_RE — print the name of every function defined in
# FILE (a line matching DEF_RE, name in group 1) whose body matches EMIT_RE. A body
# is the rest of the definition line when the line also closes the function
# (one-liner: `warn() { echo ...; }`), else every line down to the `}` at column 0.
derive_emitters() {
  local file="$1" def_re="$2" emit_re="$3" line name="" body=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$name" ]; then
      [[ "$line" =~ $def_re ]] || continue
      name="${BASH_REMATCH[1]}"
      body="${line#*\{}"
      if [[ "$line" =~ \}[[:space:]]*(#.*)?$ ]]; then
        [[ "$body" =~ $emit_re ]] && printf '%s\n' "$name"
        name=""
      fi
    else
      body="$body"$'\n'"$line"
      if [[ "$line" =~ ^\}[[:space:]]*(#.*)?$ ]]; then
        [[ "$body" =~ $emit_re ]] && printf '%s\n' "$name"
        name=""
      fi
    fi
  done < "$file"
}

BASH_DEF_RE='^([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*\{'
BASH_EMIT_RE='(^|[^A-Za-z0-9_])(echo|printf)([^A-Za-z0-9_]|$)'
PS_DEF_RE='^function[[:space:]]+([A-Za-z][A-Za-z0-9-]*)[[:space:]]*(\([^)]*\))?[[:space:]]*\{'
PS_EMIT_RE='Write-(Host|Warning|Error|Output)'

bash_derived=""; ps_derived=""
for f in $shipped; do
  case "$f" in
    *.sh)  bash_derived="$bash_derived $(derive_emitters "$ROOT/$f" "$BASH_DEF_RE" "$BASH_EMIT_RE" | tr '\n' ' ')" ;;
    *.ps1) ps_derived="$ps_derived $(derive_emitters "$ROOT/$f" "$PS_DEF_RE" "$PS_EMIT_RE" | tr '\n' ' ')" ;;
  esac
done
# shellcheck disable=SC2086  # word-splitting the derived names is the point
bash_derived="$(printf '%s\n' $bash_derived | sort -u | tr '\n' ' ')"
# shellcheck disable=SC2086
ps_derived="$(printf '%s\n' $ps_derived | sort -u | tr '\n' ' ')"
[ -n "${bash_derived// /}" ] || guard_error "derived ZERO copy-emitting bash helpers from the shipped .sh files — the derivation is broken"
[ -n "${ps_derived// /}" ]   || guard_error "derived ZERO copy-emitting PowerShell helpers from the shipped .ps1 files — the derivation is broken"

bash_vocab="echo printf $bash_derived"
ps_vocab="Write-Host Write-Warning Write-Error Write-Output throw $ps_derived"

if [ -n "$PRINT_VOCAB" ]; then
  # shellcheck disable=SC2086  # one name per line is the point
  case "$PRINT_VOCAB" in
    bash) printf '%s\n' $bash_vocab ;;
    ps)   printf '%s\n' $ps_vocab ;;
    *)    guard_error "--print-vocab takes 'bash' or 'ps'" ;;
  esac
  exit 0
fi

# ---- 3. the scan ------------------------------------------------------------------
alt() { printf '%s\n' "$@" | sed 's/[][\.*^$]/\\&/g' | paste -sd'|' -; }
# An emitter counts wherever a SIMPLE COMMAND starts, not only at column 0: house
# error lines are often `… || error "…"`, `… || { echo "[ERROR] …"; exit 1; }`,
# `if …; then warn "…"; fi` (Bugbot on client#1020). So the emitter may follow the
# line start, a control operator (`||`, `&&`, `;`, `|`), an opening brace or
# parenthesis, or one of the compound keywords `then`/`else`/`do`. The identifier
# is then looked for on the WHOLE line (minus a trailing `# comment`): a token in
# an earlier command on the same line as an emitter is flagged too, which errs
# towards a false positive over a missed customer-visible string.
CMD_START='(^|[|&;{(]|(^|[[:space:]])(then|else|do))[[:space:]]*'
# shellcheck disable=SC2086
bash_line_re="${CMD_START}($(alt $bash_vocab))([[:space:]]|$)"
# shellcheck disable=SC2086
ps_line_re="${CMD_START}($(alt $ps_vocab))([[:space:]]|$)"

offenders=0
for f in $shipped; do
  case "$f" in
    *.sh)  line_re="$bash_line_re" ;;
    *.ps1) line_re="$ps_line_re" ;;
    *)     guard_error "shipped file with an unknown language, cannot pick a vocabulary: $f" ;;
  esac
  hits="$(grep -nE "$line_re" "$ROOT/$f" | sed -E "s/[[:space:]]+#[^\"']*$//" | grep -E "$TOKEN_RE")"
  rc=$?
  [ "$rc" -le 1 ] || guard_error "grep failed ($rc) scanning $f"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$f:|"
    offenders=$((offenders + $(printf '%s\n' "$hits" | wc -l)))
  fi
done

if [ "$offenders" -gt 0 ]; then
  echo "[FAIL] $offenders user-visible line(s) carry an internal tracker identifier (backend#<n> / RFC-<nnnn>)." >&2
  echo "       A customer cannot open those; say why in words instead." >&2
  exit 1
fi
echo "customer copy is free of internal tracker identifiers ($(echo "$shipped" | wc -w | tr -d ' ') shipped files scanned)."
