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

# Is this a bracket assertion whose closer has not been reached yet?
function bracket_open(line,   s) {
    s = trim(line)
    sub(/^![[:space:]]*/, "", s)
    if (!opens(s, "[[") && !opens(s, "[")) return 0
    return (bracket_tail(line) == NOCLOSE)
}

function classify(logical, fnr,   tail, word) {
    if (logical ~ /\|\| return 1/)                                  return  # enforcing
    if (logical ~ /^[[:space:]]*#/)                                 return  # comment

    # control flow — a condition, not an assertion. Compared as a word rather than
    # with \b, which is not portable across awk implementations.
    word = trim(logical)
    sub(/[[:space:]].*$/, "", word)
    if (word == "if" || word == "elif" || word == "while" || word == "until" || word == "case")
        return

    # standalone bracket assertion — internal ||/&& is not a top-level chain
    tail = bracket_tail(logical)
    if (tail != NOCLOSE && (trim(tail) == "" || trim(tail) ~ /^#/)) {
        printf "%s:%d: %s\n", FILENAME, fnr, logical
        return
    }

    if (logical ~ /&&|\|\|/)                                        return  # already chained

    # standalone negated bare command: `! cmd ...`
    if (logical ~ /^[[:space:]]*![[:space:]]*[^[:space:]]/)
        printf "%s:%d: %s\n", FILENAME, fnr, logical
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

FILENAME != prev { prev = FILENAME; in_test = 0; in_heredoc = 0; heredoc_tag = ""; pending = ""; parts = 0 }

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
    if (tag != "") { in_heredoc = 1; heredoc_tag = tag; pending = ""; parts = 0; next }
}

/^@test/ { in_test = 1; pending = ""; parts = 0; next }
/^}/     { in_test = 0; pending = ""; parts = 0; next }
!in_test { pending = ""; parts = 0; next }

{
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
            next
        }
    }
    pending = ""; parts = 0

    classify(logical, at)
}
