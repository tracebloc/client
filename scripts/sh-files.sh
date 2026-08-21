#!/usr/bin/env bash
# =============================================================================
#  sh-files.sh — print every shell file in the repo, one per line.
#
#  THE single definition of "which files are shell", read by the Makefile's
#  `shellcheck` target (severity=error, gating, run by the required
#  `Standard checks / Lint`) and by `lint-warnings` (severity=warning,
#  advisory). It is a file rather than a Make `define` because a multi-line
#  define cannot end in a line continuation without swallowing its own `endef`,
#  and a single-line Make variable cannot contain the `#!` of a shebang regex
#  without starting a Make comment. A script has neither problem, and is itself
#  both testable and lintable by the very sweep it feeds.
#
#  (That last line is deliberately not phrased with the linter's name first: a
#  comment STARTING with it is inline-directive syntax, and an unparseable
#  directive is an SC1073 *error* — which this file would then fail on, in the
#  gating sweep it defines. The org's code-quality.yml carries the same warning.)
#
#  Why one definition at all: #753 replaced a 19-entry SHELLCHECK_FILES list
#  with a derivation because the list had drifted past eight real scripts (the
#  SECOND such drift). The gating half got a zero-count guard; the advisory half
#  kept referencing the deleted variable, expanded to no operands, and went
#  permanently green behind `|| true`. Two sweeps over "the same file set"
#  diverge unless they literally read the same code.
#
#  The rule is the one `quality / shellcheck` applies (tracebloc/.github's
#  code-quality.yml): classify by extension, else by shebang; skip
#  .bats/.ps1/.psm1/.zsh.
#
#  Exit 0 = one or more files printed. Exit 1 = the derivation found NOTHING,
#  which is a broken derivation, not an empty repo — callers must treat it as a
#  failure rather than a clean sweep (backend#1729 rule 3, fail closed).
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

count=0
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh|*.bash|*.ksh) printf '%s\n' "$f"; count=$((count+1)) ;;
    *.bats|*.ps1|*.psm1|*.zsh) ;;
    *)
      if head -n 1 "$f" 2>/dev/null \
           | grep -Eq '^#![[:space:]]*[^[:space:]]*(/|[[:space:]])(ba|da|k)?sh([[:space:]]|$)'; then
        printf '%s\n' "$f"; count=$((count+1))
      fi
      ;;
  esac
done < <(git ls-files -z)

if [ "$count" -eq 0 ]; then
  echo "sh-files: classified ZERO shell files — the derivation is broken." >&2
  echo "          Refusing to report an empty set as success." >&2
  exit 1
fi
