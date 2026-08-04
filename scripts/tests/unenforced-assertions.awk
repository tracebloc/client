# unenforced-assertions.awk — list assertions that cannot fail their bats test.
#
# Bats runs a test body under errexit, but two classes of assertion escape it, so
# a failing one that is not the LAST command in the body is silently ignored:
#
#   [[ ... ]]   on bash 3.2 — the system bash on macOS — errexit does not fire
#               for a failing conditional expression
#   ! cmd       POSIX: errexit never propagates a status that was inverted with
#               '!', on every bash
#
# The suite's convention is that every standalone assertion inside an @test body
# ends in `|| return 1`; this reports the ones that don't. `[ ... ]` is held to
# the same convention: it does trip errexit today, but the reader cannot tell
# `[` from `[[` at a glance, so both carry the marker.
#
# Usage: awk -f unenforced-assertions.awk scripts/tests/*.bats
# Output: file:line: text   (empty output = clean)
#
# Reported:
#   - standalone `[[ ... ]]` / `[ ... ]`, negated or not, whether written on one
#     line or continued over several (trailing backslash, or a newline after an
#     `||`/`&&` inside the brackets). An `||` or `&&` INSIDE the brackets does
#     not make the assertion enforcing, so it does not buy an exemption; only a
#     top-level chain does. Multi-line assertions are reported, and printed
#     joined, at their FIRST line.
#   - standalone `! cmd ...` — a negated bare command.
#
# Deliberately NOT reported:
#   - plain bare commands (`grep -q ...`): errexit does fire for those
#   - control flow (if/elif/while/until/case) — a condition, not an assertion
#   - lines already chained at the top level with && or || (`[[ x ]] || fail`)
#   - anything outside an @test body: helpers and setup/teardown, where a bare
#     `return` means something different
#   - heredoc bodies, so a test that embeds example bats source (fixtures) is not
#     mistaken for real assertions

BEGIN { NOCLOSE = "\001" }        # sentinel: not a bracket, or bracket still open

function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

# Does s start with the bracket opener `op` followed by whitespace?
function opens(s, op,   nxt) {
    if (substr(s, 1, length(op)) != op) return 0
    nxt = substr(s, length(op) + 1, 1)
    return (nxt == " " || nxt == "\t")
}

# Text following the closer that matches `op`, or NOCLOSE when s does not open
# that bracket or the closer has not appeared yet. The closer only counts as a
# word of its own (blank before, blank or end-of-line after) so `]]` inside a
# quoted pattern is not mistaken for the end of the test.
function after_close(s, op, cl,   rest, p, hit, cp, before, after) {
    if (!opens(s, op)) return NOCLOSE
    rest = substr(s, length(op) + 1)
    p = 1
    while (p <= length(rest)) {
        hit = index(substr(rest, p), cl)
        if (hit == 0) return NOCLOSE
        cp = p + hit - 1
        before = (cp > 1) ? substr(rest, cp - 1, 1) : ""
        after = substr(rest, cp + length(cl))
        if ((before == " " || before == "\t") && (after == "" || after ~ /^[[:space:]]/))
            return after
        p = cp + 1
    }
    return NOCLOSE
}

# As after_close, for whichever bracket form the (trimmed, optionally negated)
# line uses. NOCLOSE when it is not a bracket assertion or is still open.
function bracket_tail(line,   s, r) {
    s = trim(line)
    sub(/^![[:space:]]*/, "", s)
    r = after_close(s, "[[", "]]")
    if (r == NOCLOSE) r = after_close(s, "[", "]")
    return r
}

# Is this a bracket assertion whose closer has not been reached yet? True whether
# the `[[`/`[` opens the whole line OR opens the LAST statement of a `;`-compound
# (`run x; [[ a ||` continued onto the next line) — the latter would otherwise never
# be joined, so a multi-line compound bracket stayed invisible (Bugbot).
function bracket_open(line,   s, seg_arr, n) {
    s = trim(line)
    sub(/^![[:space:]]*/, "", s)
    if (opens(s, "[[") || opens(s, "["))
        return (bracket_tail(line) == NOCLOSE)

    n = split_segments(strip_comment(line), seg_arr)
    if (n > 1) {
        s = trim(seg_arr[n])
        sub(/^![[:space:]]*/, "", s)
        if (opens(s, "[[") || opens(s, "["))
            return (bracket_tail(seg_arr[n]) == NOCLOSE)
    }
    return 0
}

# Report `logical` once if ANY of its top-level (`;`-separated) statements is an
# unhardened assertion. Splitting on unquoted `;` lets us see an assertion that is
# not the LAST command of a compound or one-line body — `run x; [[ y ]]`, or
# `@test "…" { run x; [ y ]; }` — which a line-start-only match would miss (Bugbot).
function classify(logical, fnr,   code, seg_arr, n, i) {
    # Strip any trailing/whole-line comment BEFORE splitting: a `;` inside a comment
    # (`# … run foo; [ x ]`) must not be treated as a statement separator, or the
    # comment's text is mis-read as a bare assertion.
    code = strip_comment(logical)
    n = split_segments(code, seg_arr)
    for (i = 1; i <= n; i++) {
        if (stmt_is_unhardened_assertion(trim(seg_arr[i]))) {
            printf "%s:%d: %s\n", FILENAME, fnr, logical
            return
        }
    }
}

# Is one statement a standalone `[[ … ]]` / `[ … ]` / `! cmd` that lacks a
# top-level `|| return 1`? An `||`/`&&` INSIDE the brackets does not exempt it
# (bracket_tail looks only AFTER the closer); a real top-level chain does.
function stmt_is_unhardened_assertion(seg,   word, tail) {
    if (seg == "")                     return 0
    if (is_enforcing(seg))             return 0   # a REAL, unquoted, uncommented `|| return 1`
    if (seg ~ /^#/)                    return 0   # comment

    # control flow — a condition, not an assertion. Compared as a word rather than
    # with \b, which is not portable across awk implementations.
    word = seg
    sub(/[[:space:]].*$/, "", word)
    if (word == "if" || word == "elif" || word == "while" || word == "until" || word == "case")
        return 0

    # standalone bracket assertion — internal ||/&& is not a top-level chain
    tail = bracket_tail(seg)
    if (tail != NOCLOSE && (trim(tail) == "" || trim(tail) ~ /^#/))
        return 1

    if (has_toplevel_chain(seg))       return 0   # already chained at top level

    # standalone negated bare command: `! cmd ...`
    if (seg ~ /^![[:space:]]*[^[:space:]]/)
        return 1
    return 0
}

# Is position `pos` of s inside a quoted string? Walks shell quoting state from the
# start of the line: '...' suppresses ", "..." suppresses ', and a backslash escapes
# the next character everywhere except inside single quotes.
function quoted_at(s, pos,   i, c, sq, dq) {
    sq = 0; dq = 0
    for (i = 1; i < pos; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)      { i++ }
        else if (c == "'" && !dq)  { sq = !sq }
        else if (c == "\"" && !sq) { dq = !dq }
    }
    return (sq || dq)
}

# The line with any UNQUOTED trailing comment removed: everything up to the first
# `#` that starts a word (line start or after whitespace) and sits outside quotes.
# A `#` inside a quoted pattern, or mid-word, is not a comment.
function strip_comment(s,   i, c, sq, dq) {
    sq = 0; dq = 0; i = 1
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)      { i += 2; continue }
        else if (c == "'" && !dq)  { sq = !sq }
        else if (c == "\"" && !sq) { dq = !dq }
        else if (c == "#" && !sq && !dq && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/))
            return substr(s, 1, i - 1)
        i++
    }
    return s
}

# Is the line actually hardened — a REAL `|| return 1` that is CODE, not text? A
# line-wide substring match spared an unhardened `[[ … *"|| return 1"* ]]` (the
# marker inside a quoted pattern) or `[[ … ]]  # … || return 1` (only in a trailing
# comment), since neither actually enforces (Bugbot). Require the `||` to be outside
# quotes and outside the comment.
function is_enforcing(logical,   code, i, p, pos) {
    code = strip_comment(logical)
    i = 1
    while ((p = index(substr(code, i), "|| return 1")) > 0) {
        pos = i + p - 1
        if (!quoted_at(code, pos)) return 1
        i = pos + 1
    }
    return 0
}

# The heredoc tag this line opens, or "" if it opens none. A `<<TAG` INSIDE a quoted
# string is text, not a redirection: `printf "cat <<'EOF'"` was putting the scanner
# into heredoc-skip mode with no bare terminator to leave it again, so every later
# line in that file was silently ignored (Bugbot).
function heredoc_tag_of(line,   s, off, pos, tag) {
    s = line; off = 0
    while (match(s, /<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
        pos = off + RSTART
        # `<<<` is a herestring, not a heredoc: `run cmd <<< "r"` matched here from
        # the second `<` and opened a body that never closed (leftover-guard.bats).
        if (pos > 1 && substr(line, pos - 1, 1) == "<") { }
        else if (!quoted_at(line, pos)) {
            tag = substr(s, RSTART, RLENGTH)
            sub(/^<<-?[[:space:]]*/, "", tag)
            gsub(/['"]/, "", tag)
            sub(/[^A-Za-z0-9_].*$/, "", tag)
            return tag
        }
        off = off + RSTART + RLENGTH - 1
        s = substr(s, RSTART + RLENGTH)
    }
    return ""
}

# Split a line into its top-level statements on UNQUOTED `;`, filling arr[1..n]
# and returning n. A `;` inside a quoted pattern (`[[ "$x" == *";"* ]]`) or inside
# a `( … )` subshell / `$( … )` substitution (`! ( a; b ) || return 1`) does not
# split. This is how a compound / one-line body is broken into individually
# checkable assertions.
function split_segments(line, arr,   i, c, sq, dq, pd, start, n) {
    sq = 0; dq = 0; pd = 0; start = 1; n = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\\" && !sq)              { i++ }
        else if (c == "'" && !dq)          { sq = !sq }
        else if (c == "\"" && !sq)         { dq = !dq }
        else if (sq || dq)                 { continue }
        else if (c == "(")                 { pd++ }
        else if (c == ")")                 { if (pd > 0) pd-- }
        else if (c == ";" && pd == 0)      { n++; arr[n] = substr(line, start, i - start); start = i + 1 }
    }
    n++; arr[n] = substr(line, start)
    return n
}

# Net UNQUOTED brace balance of a line (`{` = +1, `}` = -1). Used to follow the
# test body across a nested `name() { … }` stub so its closing `}` is not mistaken
# for the end of the @test (Bugbot). `${var}` balances to 0; a brace in a quoted
# string is ignored, and callers pass strip_comment(line) so a brace in a trailing
# comment is ignored too.
function brace_delta(s,   i, c, sq, dq, d) {
    sq = 0; dq = 0; d = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)      { i++ }
        else if (c == "'" && !dq)  { sq = !sq }
        else if (c == "\"" && !sq) { dq = !dq }
        else if (c == "{" && !sq && !dq) { d++ }
        else if (c == "}" && !sq && !dq) { d-- }
    }
    return d
}

# The body of a `@test "name" { … }` line: everything after the first UNQUOTED `{`.
# "" when the line opens no brace.
function after_first_brace(s,   i, c, sq, dq) {
    sq = 0; dq = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)      { i++ }
        else if (c == "'" && !dq)  { sq = !sq }
        else if (c == "\"" && !sq) { dq = !dq }
        else if (c == "{" && !sq && !dq) return substr(s, i + 1)
    }
    return ""
}

# Drop a one-line @test's group-closing `}` — the LAST unquoted `}` — and anything
# after it. A bracket assertion sitting directly before it (`{ … [ a ] }`, or the
# no-space `[ a ]}` where the closer is not even recognised) would otherwise keep a
# `}` in its post-closer tail and read as non-standalone, so the one-liner stays
# invisible. (Valid bats needs a `;` before `}`, which already splits it off — this
# is belt-and-suspenders for the degenerate shapes, Bugbot.)
function strip_group_close(s,   i, c, sq, dq, last) {
    sq = 0; dq = 0; last = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)      { i++ }
        else if (c == "'" && !dq)  { sq = !sq }
        else if (c == "\"" && !sq) { dq = !dq }
        else if (c == "}" && !sq && !dq) last = i
    }
    return (last > 0) ? substr(s, 1, last - 1) : s
}

# Is there a `||` or `&&` at the TOP level — outside quotes AND outside a `( )` /
# `$( )`? A `||`/`&&` that appears only inside a pattern (`! grep -q "a||b"`) or a
# subshell is not a chain that makes the statement enforcing, so it must not buy an
# exemption (Bugbot).
function has_toplevel_chain(s,   i, c, sq, dq, pd) {
    sq = 0; dq = 0; pd = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && !sq)              { i++ }
        else if (c == "'" && !dq)          { sq = !sq }
        else if (c == "\"" && !sq)         { dq = !dq }
        else if (sq || dq)                 { continue }
        else if (c == "(")                 { pd++ }
        else if (c == ")")                 { if (pd > 0) pd-- }
        else if (pd > 0)                   { continue }
        else if (substr(s, i, 2) == "||" || substr(s, i, 2) == "&&") return 1
    }
    return 0
}

FILENAME != prev { prev = FILENAME; depth = 0; in_heredoc = 0; heredoc_tag = ""; pending = ""; parts = 0 }

# ── heredoc tracking: skip the body so embedded fixture code isn't scanned ──
in_heredoc {
    # Safety valve: a heredoc body cannot span an @test at column 0, so even a
    # mis-detected opener can never swallow more than one test's worth of lines.
    if ($0 ~ /^@test/) { in_heredoc = 0; heredoc_tag = "" }
    else {
        line = trim($0)
        if (line == heredoc_tag) { in_heredoc = 0; heredoc_tag = "" }
        next
    }
}
{
    tag = heredoc_tag_of($0)
    if (tag != "") {
        # Count this opener's own braces before skipping the body: the `{` of
        # `helm() { cat <<'EOF'` belongs to the test-body brace depth, but the
        # heredoc body we skip must not be counted.
        if (depth > 0) { depth += brace_delta(strip_comment($0)); if (depth < 0) depth = 0 }
        in_heredoc = 1; heredoc_tag = tag; pending = ""; parts = 0; next
    }
}

# ── @test opener: a one-line body, or the start of a multi-line one. Track the
# body by brace depth (not the first column-0 `}`) so a nested `name() { … }`
# closer does not end the scan early (Bugbot), and scan any inline body so
# one-line tests are not skipped (Bugbot). ──
/^@test/ {
    body = strip_group_close(after_first_brace(strip_comment($0)))
    if (trim(body) != "") classify(body, FNR)
    depth = brace_delta(strip_comment($0))
    if (depth < 0) depth = 0
    pending = ""; parts = 0; next
}

depth <= 0 { pending = ""; parts = 0; next }     # outside any @test body

# ── inside a test body ──
{
    d = brace_delta(strip_comment($0))

    cur = $0
    if (pending != "") {
        sub(/^[[:space:]]+/, "", cur)
        logical = pending " " cur
        at = pending_fnr
    } else {
        logical = cur
        at = FNR
    }

    # keep joining while the logical line is unfinished: trailing backslash, or a
    # bracket assertion whose closer is on a later line. Bounded so an unbalanced
    # line cannot swallow the rest of the body and hide real offenders.
    if (logical ~ /\\[[:space:]]*$/ || bracket_open(logical)) {
        if (parts < 8) {
            sub(/[[:space:]]*\\[[:space:]]*$/, "", logical)
            pending = logical; pending_fnr = at; parts++
            depth += d; if (depth <= 0) { depth = 0; pending = ""; parts = 0 }
            next
        }
    }
    pending = ""; parts = 0

    classify(logical, at)

    depth += d
    if (depth <= 0) depth = 0
}
