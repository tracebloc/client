#!/usr/bin/env bash
#
#  release-name-equals-namespace.sh — the installer names the Helm release after
#  the namespace, and `docs/INSTALL.md` says so (backend#2621).
#
#  WHY THIS EXISTS. `docs/INSTALL.md` now tells operators to use one string for
#  both, on the grounds that "the bundled installer already does this". That is a
#  claim about code, in prose, in the document an operator reads first — exactly
#  the shape that decays into advice for a behaviour the code stopped having
#  (backend#1729 rule 7). If the installer ever passes a different release name,
#  this reddens instead of the doc quietly becoming wrong.
#
#  AND IT IS THE CONVENTION ITSELF THAT MATTERS, not the doc. Helm cannot rename
#  a release, so every resource name is welded to whatever was typed once. The
#  self-service path is consistent because nobody chooses; the hand-managed fleet
#  is not, which is what backend#2621 is about. This guard protects the half that
#  currently works.
#
#  DERIVED, NOT RESTATED (rule 1). The two arguments are read out of the
#  installer's own `helm upgrade --install` invocation. This file holds no copy of
#  the expected name — it asserts the two are the SAME EXPRESSION, whatever that
#  expression is, so renaming the variable keeps the guard green and passing a
#  different value does not.
#
#  FAILS CLOSED (rule 3). If the invocation cannot be found or cannot be parsed,
#  that is a finding — an unreadable installer is not evidence of agreement.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

LIB=scripts/lib/install-client-helm.sh
DOC=docs/INSTALL.md

echo "== installer names the release after the namespace =="

[ -r "$LIB" ] || { echo "[ERROR] cannot read $LIB" >&2; exit 1; }
[ -r "$DOC" ] || { echo "[ERROR] cannot read $DOC" >&2; exit 1; }

# The release name is the first positional argument to `helm upgrade --install`;
# the namespace is the value of the `--namespace` flag on a following line. Read
# both from the same invocation block rather than from the file at large, so two
# unrelated occurrences cannot be paired by accident.
# ANCHORED TO THE START OF A LINE, so a COMMENT mentioning the command cannot be
# read as the command. The first version of this guard matched
# `# subsequent \`helm upgrade --install\` then fails with ...` on line 1025 and
# reported a parse failure — the same "prose satisfies a structural guard" class
# this file exists to prevent, hit while writing it.
BLOCK="$(awk '
  /^[[:space:]]*helm upgrade --install/ { inblock=1 }
  inblock { print; if ($0 !~ /\\$/) exit }
' "$LIB")"

[ -n "$BLOCK" ] || {
  echo "[ERROR] no \`helm upgrade --install\` invocation found in $LIB — the" >&2
  echo "        installer was restructured and this guard can no longer see" >&2
  echo "        what it names the release. Refusing to report agreement." >&2
  exit 1
}

# CAPTURE-THEN-SLICE, not `| head -1`. Piping into `head` under `errexit` +
# `pipefail` makes the whole assignment inherit `head`'s SIGPIPE kill once it
# closes early, so a *successful* parse can abort the script — the repo's
# `pipefail early-close` check flags exactly this. Collect every match, then take
# the first line with parameter expansion; no pipe, so no early-closing reader.
# Still fails closed: no match leaves the variable empty and the `-n` guards below
# turn that into a finding.
RELEASE_MATCHES="$(sed -nE 's/.*helm upgrade --install[[:space:]]+("?[^"[:space:]]+"?).*/\1/p' <<<"$BLOCK")"
NAMESPACE_MATCHES="$(sed -nE 's/.*--namespace[[:space:]]+("?[^"[:space:]]+"?).*/\1/p' <<<"$BLOCK")"
RELEASE="${RELEASE_MATCHES%%$'\n'*}"
NAMESPACE="${NAMESPACE_MATCHES%%$'\n'*}"

[ -n "$RELEASE" ]   || { echo "[ERROR] could not parse the release-name argument from: $BLOCK" >&2; exit 1; }
[ -n "$NAMESPACE" ] || { echo "[ERROR] could not parse the --namespace argument from: $BLOCK" >&2; exit 1; }

if [ "$RELEASE" != "$NAMESPACE" ]; then
  echo "[ERROR] the installer passes release=$RELEASE but --namespace=$NAMESPACE." >&2
  echo "        docs/INSTALL.md tells operators to use one string for both on the" >&2
  echo "        grounds that the installer does. Either restore the convention, or" >&2
  echo "        change the doc — but do not leave the doc claiming it." >&2
  exit 1
fi

# The doc must actually carry the claim this guard protects; a guard defending a
# section somebody deleted is a guard with nothing to defend.
grep -q 'release name equals the namespace' "$DOC" || {
  echo "[ERROR] $DOC no longer states the release-name convention, so this guard" >&2
  echo "        is protecting nothing. Restore the section or remove the guard." >&2
  exit 1
}

echo "  [OK] release and namespace are the same expression ($RELEASE), and the doc says so"
