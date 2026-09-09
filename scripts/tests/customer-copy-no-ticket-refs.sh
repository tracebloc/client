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
# Internal tracker identifiers, REPO-AGNOSTIC (Saqlain, client#1020): `client#564`,
# `engine#972`, `e2e#459`, `.github#306`, `rfcs#80` are as internal as `backend#889`,
# and the org's RFC form is `RFC-BACKEND-0007` as well as `RFC-0001`. The leading
# character class keeps shell parameter expansion out of it: `${x#0}` is preceded
# by `{`, `$#` has no name, `${a[@]#1}` is preceded by `]`.
TOKEN_RE='(^|[^{[$A-Za-z0-9_.-])[A-Za-z.][A-Za-z0-9._-]*#[0-9]+|RFC-([A-Z]+-)?[0-9]{4}'

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
# derive_emitters LANG FILE — print the name of every function defined in FILE
# whose BODY (comments and string contents removed, here-documents skipped) calls
# an emitting primitive. One awk pass, brace-depth tracked, so a function closes
# where its braces balance -- at column 0, indented, or on the definition line --
# rather than only at a `}` in column 0 (Saqlain, client#1020: an indented close
# used to swallow every later function in the file into the running body).
#
# FAILS CLOSED, and a PARTIAL miss is a failure, not a smaller vocabulary: a
# definition whose `{` is not on its line or the next, a function still open at
# EOF, or a definition the classifier saw but never closed each abort with exit 3
# and the file:line, which the caller turns into a guard error. A helper the
# derivation cannot classify is a helper an offender could call unseen.
#
# LANG=bash: defs `name() {`, `function name {`, `function name() {`; emitters
#   `echo`/`printf` as a command word.
# LANG=ps:   defs `function Name {` / `function Name(...) {`; emitters `Write-Host|
#   Write-Warning|Write-Error|Write-Output`.
derive_emitters() {
  local lang="$1" file="$2" known="${3:-}"
  awk -v LANG="$lang" -v FILE="$file" -v KNOWN="$known" '
    function fail(msg) { failed = 1; printf("DERIVE ERROR %s:%d: %s\n", FILE, NR, msg) > "/dev/stderr"; exit 3 }
    # Remove string CONTENTS and a trailing comment, keeping quote marks, so braces
    # and `#` inside strings/comments cannot move the depth or fake an emitter.
    function code_only(line,   out, i, c, q) {
      out = ""; q = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q != "") { if (c == q) { q = ""; out = out c } ; continue }
        if (c == "\"" || c == "\047") { q = c; out = out c; continue }
        if (c == "#" && (i == 1 || substr(line, i-1, 1) ~ /[ \t;]/)) break   # not after `{`/`$`: ${#arr[@]}, $# are code
        out = out c
      }
      return out
    }
    function count(s, ch,   n, i) { n = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++; return n }
    BEGIN {
      if (LANG == "bash") { DEF = "^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\\(\\)|^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(\\{|$)"; EMIT = "(^|[^A-Za-z0-9_.-])(echo|printf" (KNOWN != "" ? "|" KNOWN : "") ")([^A-Za-z0-9_.-]|$)" }
      else { DEF = "^[ \t]*[Ff]unction[ \t]+[A-Za-z_][A-Za-z0-9_-]*"; EMIT = "(^|[^A-Za-z0-9_.-])(Write-(Host|Warning|Error|Output)" (KNOWN != "" ? "|" KNOWN : "") ")([^A-Za-z0-9_.-]|$)" }
      name = ""; depth = 0; body = ""; heredoc = ""; pending = 0
    }
    {
      line = $0
      if (heredoc != "") { if (line ~ ("^[ \t]*" heredoc "[ \t]*$")) heredoc = ""; next }
      code = code_only(line)
      if (name == "") {
        if (code !~ DEF) next
        n = code; sub(/^[ \t]*[Ff]unction[ \t]+/, "", n); sub(/^[ \t]*/, "", n); sub(/[^A-Za-z0-9_-].*$/, "", n)
        name = n; body = ""; depth = 0; pending = 1; defline = NR
      }
      if (pending) {
        if (code !~ /\{/) { if (code ~ /^[ \t]*$/ || NR == defline) next; else fail("definition of " name " at line " defline " has no opening brace on its line or the next") }
        pending = 0
      }
      depth += count(code, "{") - count(code, "}")
      body = body "\n" code
      # Here-document: the OPERATOR must be in code (not inside a string), but the
      # delimiter is read from the RAW line, because code_only has already emptied
      # a QUOTED delimiter (<<HELP written with quotes around HELP reads as two bare
      # quote marks after stripping). Bugbot on client#1020, third round: print_help
      # and the nested STORAGE / MYSQL84 blocks use the quoted spelling.
      # `(^|[^<])` keeps a here-STRING (`<<< "$a"`, whose string strips to `""`) from
      # reading as a quoted here-document -- _version_lt in common.sh tripped it.
      if (code ~ /(^|[^<])<<-?[ \t]*([\047"]?[A-Za-z_]|[\047"][\047"])([^<]|$)/) {
        h = line; sub(/.*<<-?[ \t]*/, "", h); q2 = substr(h, 1, 1)
        if (q2 == "\047" || q2 == "\"") { h = substr(h, 2); sub(q2 ".*$", "", h) } else { sub(/[^A-Za-z0-9_].*$/, "", h) }
        if (h ~ /^[A-Za-z_][A-Za-z0-9_]*$/) heredoc = h; else fail("here-document with an unreadable delimiter in " name)
      }
      if (LANG == "ps" && code ~ /@["\047][ \t]*$/) { heredoc = (code ~ /@"/) ? "\"@" : "\047@" }
      if (depth <= 0) { if (body ~ EMIT) print name; name = ""; body = "" }
    }
    END { if (failed) exit 3; if (name != "") fail("function " name " (defined at line " defline ") is still open at end of file: braces do not balance, so every later helper would be hidden") }
  ' "$file"
}

# TRANSITIVE, TO A FIXPOINT (Saqlain, client#1020): a helper that routes its text
# through a derived emitter (`_pf_opaque_fuse_warn` calling `warn`) is itself copy
# a customer sees, so each pass re-derives with the names found so far as extra
# primitives until no new name appears. Bounded; not converging is a guard error.
alt_names() { printf '%s\n' "$@" | sed 's/[][\.*^$]/\\&/g' | paste -sd'|' -; }
derive_all() { # $1 = lang, $2 = file glob suffix; prints the sorted closure
  local lang="$1" suffix="$2" known="" next pass=0 out
  while :; do
    pass=$((pass + 1)); [ "$pass" -le 12 ] || guard_error "the $lang emitter derivation did not converge in 12 passes"
    next=""
    for f in $shipped; do
      case "$f" in
        *"$suffix") out="$(derive_emitters "$lang" "$ROOT/$f" "$known")" || guard_error "could not derive the copy-emitting helpers of $f (see DERIVE ERROR above)"; next="$next $(printf '%s\n' "$out" | tr '\n' ' ')" ;;
      esac
    done
    # shellcheck disable=SC2086  # word-splitting the derived names is the point
    next="$(printf '%s\n' $next | sort -u | tr '\n' ' ')"
    # shellcheck disable=SC2086
    [ "$(alt_names $next)" = "$known" ] && break
    # shellcheck disable=SC2086
    known="$(alt_names $next)"
  done
  printf '%s' "$next"
}
bash_derived="$(derive_all bash .sh)"
ps_derived="$(derive_all ps .ps1)"
[ -n "${bash_derived// /}" ] || guard_error "derived ZERO copy-emitting bash helpers from the shipped .sh files — the derivation is broken"
[ -n "${ps_derived// /}" ]   || guard_error "derived ZERO copy-emitting PowerShell helpers from the shipped .ps1 files — the derivation is broken"

# Deliberately IN the vocabulary even though a reviewer might not call them
# "terminal copy": `log` writes ~/.tracebloc/*.log, which customers attach to
# support tickets, and value-returning helpers (`_backend_url`, `_mem_to_bytes`)
# echo for substitution -- a token in their arguments is implausible, and the
# guard accepts that false-positive bias over a missed customer-visible string.
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
# is then looked for on the code part of the WHOLE line: a token in an earlier
# command on the same line as an emitter is flagged too, which errs towards a
# false positive over a missed customer-visible string.
# `)` too: a one-line case arm (`pat) info "…"`, `2) warn "…"`) starts a command
# right after its pattern (Bugbot on client#1020, second round).
CMD_START='(^|[|&;{()]|(^|[[:space:]])(then|else|do))[[:space:]]*'
# shellcheck disable=SC2086
bash_line_re="${CMD_START}($(alt $bash_vocab))([[:space:]]|$)"
# shellcheck disable=SC2086
ps_line_re="${CMD_START}($(alt $ps_vocab))([[:space:]]|$)"

# strip_trailing_comment — cut each line at the first `#` that is OUTSIDE quotes and
# starts a comment (line start, or after whitespace / `;` / `(` / `{`). Quote-aware,
# so an apostrophe in the comment (`# we don't …`) no longer keeps the comment in
# scope, and a `#` inside a quoted string (`echo "issue #5"`) is never a comment
# (Saqlain, client#1020: the old `[^"']*$` stripper failed on exactly that pair).
strip_trailing_comment() {
  # Input lines carry grep's `NNN:` prefix; walk the text after it, so a comment
  # at column 1 (`1022:# …`) is still a comment.
  awk '{
    prefix = ""; text = $0
    if (match($0, /^[0-9]+:/)) { prefix = substr($0, 1, RLENGTH); text = substr($0, RLENGTH + 1) }
    out = ""; q = ""
    for (i = 1; i <= length(text); i++) {
      c = substr(text, i, 1)
      if (q != "") { if (c == q) q = ""; out = out c; continue }
      if (c == "\"" || c == "\047") { q = c; out = out c; continue }
      if (c == "#" && (i == 1 || substr(text, i-1, 1) ~ /[ \t;]/)) break
      out = out c
    }
    print prefix out
  }'
}

# heredoc_body_lines FILE — print `NNN:<line>` for every line inside a bash
# here-document. Operator detected on quote-stripped code (so a `<<` inside a
# string does not count, and `<<<` here-strings are excluded); delimiter taken
# from the raw line, quoted or not -- the same rule derive_emitters applies.
heredoc_body_lines() {
  awk '
    function code_only(line,   out, i, c, q) {
      out = ""; q = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (q != "") { if (c == q) { q = ""; out = out c } ; continue }
        if (c == "\"" || c == "\047") { q = c; out = out c; continue }
        if (c == "#" && (i == 1 || substr(line, i-1, 1) ~ /[ \t;]/)) break
        out = out c
      }
      return out
    }
    BEGIN { heredoc = "" }
    {
      if (heredoc != "") { if ($0 ~ ("^[ \t]*" heredoc "[ \t]*$")) heredoc = ""; else printf("%d:%s\n", NR, $0); next }
      code = code_only($0)
      if (code ~ /(^|[^<])<<-?[ \t]*([\047"]?[A-Za-z_]|[\047"][\047"])([^<]|$)/) {
        h = $0; sub(/.*<<-?[ \t]*/, "", h); q2 = substr(h, 1, 1)
        if (q2 == "\047" || q2 == "\"") { h = substr(h, 2); sub(q2 ".*$", "", h) } else { sub(/[^A-Za-z0-9_].*$/, "", h) }
        if (h ~ /^[A-Za-z_][A-Za-z0-9_]*$/) heredoc = h
      }
    }
  ' "$1"
}

offenders=0
for f in $shipped; do
  case "$f" in
    *.sh)  line_re="$bash_line_re" ;;
    *.ps1) line_re="$ps_line_re" ;;
    *)     guard_error "shipped file with an unknown language, cannot pick a vocabulary: $f" ;;
  esac
  # THREE STAGES, EACH THROUGH A FILE WITH ITS OWN STATUS -- never one pipeline.
  # Under `pipefail` a pipeline's status is the RIGHTMOST non-zero one, so
  # `grep | sed | grep` turned a first-grep failure (2: a bad line regex, an
  # unreadable path) into the trailing grep's no-match (1) and reported the
  # file clean (Bugbot on client#1020). Each stage's own exit code is checked
  # before the next runs; only grep's 1 (no match) may pass.
  stage1="$(mktemp)"; stage2="$(mktemp)"
  grep -nE "$line_re" "$ROOT/$f" >"$stage1"; rc=$?
  [ "$rc" -le 1 ] || { rm -f "$stage1" "$stage2"; guard_error "grep failed ($rc) selecting copy lines in $f"; }
  # HERE-DOCUMENT BODIES ARE COPY TOO (bash only): `cat <<'HELP' … HELP` is how the
  # installers print help and multi-line notices, and none of those lines starts
  # with an emitter, so the grep above never sees them. Append every body line of
  # every here-document (same operator/delimiter rule as the derivation).
  case "$f" in *.sh)
    heredoc_body_lines "$ROOT/$f" >>"$stage1" || { rm -f "$stage1" "$stage2"; guard_error "could not list here-document bodies in $f"; }
  esac
  strip_trailing_comment <"$stage1" >"$stage2" || { rm -f "$stage1" "$stage2"; guard_error "comment stripping failed in $f"; }
  hits="$(grep -E "$TOKEN_RE" "$stage2")"; rc=$?
  rm -f "$stage1" "$stage2"
  [ "$rc" -le 1 ] || guard_error "grep failed ($rc) scanning $f for tracker identifiers"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$f:|"
    offenders=$((offenders + $(printf '%s\n' "$hits" | wc -l)))
  fi
done

if [ "$offenders" -gt 0 ]; then
  echo "[FAIL] $offenders user-visible line(s) carry an internal tracker identifier (<repo>#<n> / RFC-<nnnn> / RFC-<AREA>-<nnnn>)." >&2
  echo "       A customer cannot open those; say why in words instead." >&2
  exit 1
fi
echo "customer copy is free of internal tracker identifiers ($(echo "$shipped" | wc -w | tr -d ' ') shipped files scanned)."
