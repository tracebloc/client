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
#  `<repo>#<n>` or `RFC-[<AREA>-]<n>` token is an offender, and so is every line
#  of a here-document / here-string body (help text, multi-line notices). A
#  trailing `# comment` on a CODE line (whitespace, `#`, outside quotes) is
#  stripped first: the customer does not see it. Inside a here-document body a
#  `#` is text the customer reads, so nothing is stripped there -- unless the
#  here-document GENERATES A FILE (redirected into one, or assigned to a
#  variable): then its `#` lines are that file's comments, out of scope like
#  every other comment, and only its non-comment lines are copy. Known limit: a
#  string continued onto a second line is not seen — its first word is not an
#  emitter.
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
# and the org's RFC form is `RFC-BACKEND-0007` as well as `RFC-0001`. The RFC number
# is THREE OR MORE digits, not exactly four: `RFC-BACKEND-664` is a real one this
# repo cites (Saqlain, client#1020, second round). The leading character class
# keeps shell parameter expansion out of it: `${x#0}` is preceded by `{`, `$#` has
# no name, `${a[@]#1}` is preceded by `]`.
TOKEN_RE='(^|[^{[$A-Za-z0-9_.-])[A-Za-z.][A-Za-z0-9._-]*#[0-9]+|RFC-([A-Z]+-)?[0-9]{3,}'

guard_error() { echo "[GUARD ERROR] $*" >&2; echo "              'could not check' is a finding, never 'clean'." >&2; exit 2; }

# ---- 0. the ONE lexer every awk program below includes ------------------------------
# Three awk programs here walk quotes, comments and here-document openers: the
# vocabulary derivation, the here-document body lister and the comment stripper.
# They used to carry three verbatim copies of that walk, so a fix to one could
# silently miss the others (Saqlain, client#1020, second round). This string is
# prepended to each program; every function in it reads the -v LANG=bash|ps the
# caller passes.
#
#   lex(line, keep)        the code part of LINE: a trailing comment removed and,
#                          unless KEEP, string CONTENTS removed too (the quote
#                          marks stay). Escapes are honoured per language -- bash:
#                          a backslash escapes the next character outside single
#                          quotes; PowerShell: a backtick does, and a doubled
#                          quote inside a string is a literal quote -- so a brace
#                          inside `"he said \"go { deeper\" now"` stays inside the
#                          string instead of opening one (Saqlain, client#1020,
#                          second round: it used to abort the derivation, or
#                          close a helper early and hide every later one).
#   code_only(line)        lex(line, 0).
#   heredoc_delim(code, raw)  "" when CODE opens no here-document; else the
#                          delimiter, read from the RAW line because code_only
#                          has already emptied a QUOTED delimiter (<<'HELP' reads
#                          as two bare quote marks after stripping); "?" when the
#                          delimiter cannot be read. `(^|[^<])` keeps a here-STRING
#                          (`<<< "$a"`) from reading as a quoted here-document.
#   herestring_closer(code)  PowerShell: the closer of a here-string CODE opens
#                          (`"@` / `'@`), else "".
#   closes(line, closer)   does LINE end the open here-document / here-string?
#                          bash: the delimiter alone on its line; PowerShell: the
#                          closer at the start of the line (`"@.Trim()` closes).
AWK_LEX='
  function lex(line, keep,   out, i, c, q, esc, n) {
    out = ""; q = ""; esc = (LANG == "ps") ? "`" : "\\"; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (q != "") {
        if (c == esc && q == "\"") { if (keep) out = out c substr(line, i + 1, 1); i++; continue }
        if (c == q && LANG == "ps" && substr(line, i + 1, 1) == q) { if (keep) out = out c c; i++; continue }
        if (c == q) { q = ""; out = out c; continue }
        if (keep) out = out c
        continue
      }
      if (c == esc) { if (keep) out = out c substr(line, i + 1, 1); i++; continue }
      if (c == "\"" || c == "\047") { q = c; out = out c; continue }
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) break
      out = out c
    }
    return out
  }
  function code_only(line) { return lex(line, 0) }
  function heredoc_delim(code, raw,   h, q2) {
    if (code !~ /(^|[^<])<<-?[ \t]*([\047"]?[A-Za-z_]|[\047"][\047"])([^<]|$)/) return ""
    h = raw; sub(/.*<<-?[ \t]*/, "", h); q2 = substr(h, 1, 1)
    if (q2 == "\047" || q2 == "\"") { h = substr(h, 2); sub(q2 ".*$", "", h) } else { sub(/[^A-Za-z0-9_].*$/, "", h) }
    return (h ~ /^[A-Za-z_][A-Za-z0-9_]*$/) ? h : "?"
  }
  function herestring_closer(code) { return (code ~ /@"[ \t]*$/) ? "\"@" : (code ~ /@\047[ \t]*$/) ? "\047@" : "" }
  function closes(line, closer) { return (LANG == "ps") ? (line ~ ("^[ \t]*" closer)) : (line ~ ("^[ \t]*" closer "[ \t]*$")) }
'

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
  awk -v LANG="$lang" -v FILE="$file" -v KNOWN="$known" "$AWK_LEX"'
    function fail(msg) { failed = 1; printf("DERIVE ERROR %s:%d: %s\n", FILE, NR, msg) > "/dev/stderr"; exit 3 }
    function count(s, ch,   n, i) { n = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++; return n }
    BEGIN {
      if (LANG == "bash") { DEF = "^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\\(\\)|^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(\\{|$)"; EMIT = "(^|[^A-Za-z0-9_.-])(echo|printf" (KNOWN != "" ? "|" KNOWN : "") ")([^A-Za-z0-9_.-]|$)" }
      else { DEF = "^[ \t]*[Ff]unction[ \t]+[A-Za-z_][A-Za-z0-9_-]*"; EMIT = "(^|[^A-Za-z0-9_.-])(Write-(Host|Warning|Error|Output)" (KNOWN != "" ? "|" KNOWN : "") ")([^A-Za-z0-9_.-]|$)" }
      name = ""; depth = 0; body = ""; heredoc = ""; pending = 0
    }
    {
      line = $0
      if (heredoc != "") { if (closes(line, heredoc)) heredoc = ""; next }
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
      h = heredoc_delim(code, line)
      if (h == "?") fail("here-document with an unreadable delimiter in " name)
      if (h != "") heredoc = h
      if (LANG == "ps") { h = herestring_closer(code); if (h != "") heredoc = h }
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

# strip_trailing_comment LANG — cut each `NNN:<line>` at the first `#` that is
# OUTSIDE quotes and starts a comment (line start, or after whitespace / `;`).
# Quote-aware through the shared lexer, so an apostrophe in the comment (`# we
# don't …`) no longer keeps the comment in scope, and a `#` inside a quoted string
# (`echo "issue #5"`) is never a comment (Saqlain, client#1020: the old `[^"']*$`
# stripper failed on exactly that pair). Input lines carry grep's `NNN:` prefix;
# the text after it is walked, so a comment at column 1 (`1022:# …`) is still one.
strip_trailing_comment() {
  awk -v LANG="$1" "$AWK_LEX"'{
    prefix = ""; text = $0
    if (match($0, /^[0-9]+:/)) { prefix = substr($0, 1, RLENGTH); text = substr($0, RLENGTH + 1) }
    print prefix lex(text, 1)
  }'
}

# heredoc_body_lines LANG FILE — print `NNN:<line>` for every line inside a
# bash here-document (LANG=bash) or a PowerShell here-string (LANG=ps).
# Bash: operator detected on quote-stripped code (so a `<<` inside a string does
# not count, and `<<<` here-strings are excluded); delimiter taken from the raw
# line, quoted or not -- the same shared rule the derivation applies.
# PowerShell: an opener is an at-sign followed by a double or single quote at the
# end of a line (Write-Host, throw, or an assignment), the closer is that quote
# followed by an at-sign at the start of a line
# (Bugbot on client#1020, fourth round: Print-Help and the data-directory
# `throw` are here-strings a customer reads).
#
# TWO KINDS OF BODY. A here-document the installer PRINTS (`cat <<'HELP'`,
# `warn <<EOF`, `Write-Host @"`, `throw @"`) is text the customer reads in full:
# every line is printed as it stands, `#` included -- it used to be stripped as a
# comment, so `# migration required, see backend#4242` in a help text passed as
# clean (Saqlain, client#1020, second round). A here-document that GENERATES A
# FILE -- redirected into one (`cat <<EOF > "$values_file"` or `cat > "$f" <<EOF`,
# not `>&2`), assigned
# to a variable (`x=$(cat <<EOF`, `$block += @"`), or handed to
# Set-Content/Add-Content/Out-File -- is that file's content: its `#` lines are
# comments of the generated file (the values.yaml the installer writes carries
# the rationale for its defaults), out of scope like every other comment, and
# only its non-comment text is scanned. The comment rule there is the one YAML,
# shell and PowerShell share: `#` at the start of the line or after whitespace.
# Anything the classifier cannot place (`return @"`, a body piped to another
# command) is treated as printed text -- over-inclusive on purpose.
heredoc_body_lines() {
  local lang="$1" file="$2"
  awk -v LANG="$lang" -v FILE="$file" "$AWK_LEX"'
    function generates_a_file(code,   rest) {
      if (code ~ /^[ \t]*((local|export|readonly|declare)[ \t]+)?\$?[A-Za-z_][A-Za-z0-9_:]*(\[[^]]*\])?[ \t]*\+?=/) return 1
      if (code ~ /(^|[^A-Za-z0-9-])(Set-Content|Add-Content|Out-File)([^A-Za-z0-9-]|$)/) return 1
      if (LANG == "ps") return 0
      # bash: STDOUT redirected to a file -- `>`/`>>`, or `1>`. Not `2>` (only
      # stderr moves, the body still prints), not `>&2` (a stream), not a
      # /dev/ pseudo-file (`>/dev/stderr` prints, `>/dev/null` writes no file).
      # Any of those leaves the body classified as printed text (Bugbot on
      # client#1022: `2>/dev/null` used to read as a generated file).
      rest = code
      while (match(rest, />>?/)) {
        pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
        tgt = substr(rest, RSTART + RLENGTH); sub(/^[ \t]*/, "", tgt)
        rest = substr(rest, RSTART + RLENGTH)
        if (pre ~ /[0-9]/ && pre != "1") continue
        if (tgt == "" || tgt ~ /^[&>]/ || tgt ~ /^\/dev\//) continue
        return 1
      }
      return 0
    }
    function file_text(line) { sub(/(^|[ \t])#.*$/, "", line); return line }
    BEGIN { closer = ""; is_file = 0 }
    {
      if (closer != "") {
        if (closes($0, closer)) closer = ""; else printf("%d:%s\n", NR, is_file ? file_text($0) : $0)
        next
      }
      code = code_only($0)
      if (LANG == "ps") { closer = herestring_closer(code) } else {
        h = heredoc_delim(code, $0)
        if (h == "?") { printf("LEX ERROR %s:%d: here-document with an unreadable delimiter\n", FILE, NR) > "/dev/stderr"; exit 3 }
        closer = h
      }
      if (closer != "") is_file = generates_a_file(code)
    }
  ' "$file"
}

# Template + fail-closed: a bare `mktemp -d` can fail (BSD mktemp, an unwritable
# TMPDIR) and leave tmpd EMPTY, and the cleanup below would then expand to
# `rm -f /*` (Bugbot on client#1022). The trap is armed only once the directory
# exists.
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/copyrefs.XXXXXX")" && [ -d "$tmpd" ] || guard_error "could not create a scratch directory under ${TMPDIR:-/tmp}"
trap 'rm -f "$tmpd"/*; rmdir "$tmpd" 2>/dev/null' EXIT
offenders=0
for f in $shipped; do
  case "$f" in
    *.sh)  lang=bash; line_re="$bash_line_re" ;;
    *.ps1) lang='ps';   line_re="$ps_line_re" ;;
    *)     guard_error "shipped file with an unknown language, cannot pick a vocabulary: $f" ;;
  esac
  # STAGED, EACH THROUGH A FILE WITH ITS OWN STATUS -- never one pipeline. Under
  # `pipefail` a pipeline's status is the RIGHTMOST non-zero one, so
  # `grep | sed | grep` turned a first-grep failure (2: a bad line regex, an
  # unreadable path) into the trailing grep's no-match (1) and reported the
  # file clean (Bugbot on client#1020). Each stage's own exit code is checked
  # before the next runs; only grep's 1 (no match) may pass.
  code_lines="$tmpd/code"; body_lines="$tmpd/body"; scan="$tmpd/scan"
  # (a) code lines that start with an emitter
  grep -nE "$line_re" "$ROOT/$f" >"$code_lines"; rc=$?
  [ "$rc" -le 1 ] || guard_error "grep failed ($rc) selecting copy lines in $f"
  # (b) HERE-DOCUMENT / HERE-STRING BODIES ARE COPY TOO: `cat <<'HELP' … HELP` and
  # `Write-Host @" … "@` are how the installers print help and multi-line notices,
  # and none of those body lines starts with an emitter, so the grep above never
  # sees them.
  heredoc_body_lines "$lang" "$ROOT/$f" >"$body_lines" || guard_error "could not list here-document bodies in $f"
  # (c) a body line is TEXT the customer reads in full: it is never also a code
  # line, and no comment is stripped from it. A body line that happened to start
  # with an emitter word (`echo` in a usage text) used to be taken by BOTH (a) and
  # (b) -- printed twice, counted twice -- and `# …` in a body line used to be
  # stripped as a comment although the customer reads it (Saqlain, client#1020,
  # second round). The body list is read in BEGIN, not via NR==FNR, so an empty
  # body list cannot make every code line read as a body line.
  awk -F: -v BODY="$body_lines" 'BEGIN { while ((getline l < BODY) > 0) { split(l, a, ":"); body[a[1]] = 1 } } !($1 in body)' "$code_lines" >"$scan" || guard_error "could not separate code lines from here-document bodies in $f"
  strip_trailing_comment "$lang" <"$scan" >"$code_lines" || guard_error "comment stripping failed in $f"
  cat "$body_lines" >>"$code_lines" || guard_error "could not append here-document bodies in $f"
  # (d) the identifier scan
  hits="$(grep -E "$TOKEN_RE" "$code_lines")"; rc=$?
  [ "$rc" -le 1 ] || guard_error "grep failed ($rc) scanning $f for tracker identifiers"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$f:|"
    offenders=$((offenders + $(printf '%s\n' "$hits" | wc -l)))
  fi
done

if [ "$offenders" -gt 0 ]; then
  echo "[FAIL] $offenders user-visible line(s) carry an internal tracker identifier (<repo>#<n> / RFC-<n> / RFC-<AREA>-<n>)." >&2
  echo "       A customer cannot open those; say why in words instead." >&2
  exit 1
fi
echo "customer copy is free of internal tracker identifiers ($(echo "$shipped" | wc -w | tr -d ' ') shipped files scanned)."
