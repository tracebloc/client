# unenforced-assertions.awk — list assertions that cannot fail their bats test.
#
# Under Bats (verified 1.13.0) only the LAST command in a test body decides the
# result, so a failing assertion anywhere earlier is silently ignored. The suite's
# convention is that every standalone assertion inside an @test body ends in
# `|| return 1`; this reports the ones that don't.
#
# Usage: awk -f unenforced-assertions.awk scripts/tests/*.bats
# Output: file:line: text   (empty output = clean)
#
# Deliberately NOT reported:
#   - control flow (if/elif/while/until/case) — a condition, not an assertion
#   - lines already chained with && or ||
#   - anything outside an @test body: helpers and setup/teardown, where a bare
#     `return` means something different
#   - heredoc bodies, so a test that embeds example bats source (fixtures) is not
#     mistaken for real assertions

FILENAME != prev { prev = FILENAME; in_test = 0; in_heredoc = 0; heredoc_tag = "" }

# ── heredoc tracking: skip the body so embedded fixture code isn't scanned ──
in_heredoc {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*$/, "", line)
    if (line == heredoc_tag) { in_heredoc = 0; heredoc_tag = "" }
    next
}
/<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/ {
    tag = $0
    sub(/^.*<<-?[[:space:]]*/, "", tag)
    gsub(/['"]/, "", tag)
    sub(/[^A-Za-z0-9_].*$/, "", tag)
    if (tag != "") { in_heredoc = 1; heredoc_tag = tag }
    next
}

/^@test/ { in_test = 1; next }
/^}/     { in_test = 0; next }
!in_test { next }

/\|\| return 1/                          { next }   # already enforcing
/&&|\|\|/                                { next }   # already chained
/^[[:space:]]*#/                         { next }   # comment
/^[[:space:]]*(if|elif|while|until|case)\b/ { next } # control flow, not an assertion

# standalone [[ ... ]] or [ ... ], optionally negated, optional trailing comment
/^[[:space:]]*!?[[:space:]]*\[\[ .*\]\][[:space:]]*(#.*)?$/ ||
/^[[:space:]]*!?[[:space:]]*\[ .*\][[:space:]]*(#.*)?$/ {
    printf "%s:%d: %s\n", FILENAME, FNR, $0
}
