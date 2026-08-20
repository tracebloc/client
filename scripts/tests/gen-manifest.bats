#!/usr/bin/env bats
# gen-manifest.sh — the installer's integrity surface (backend#1729, sweep 6).
#
# WHY THIS SUITE EXISTS
# ---------------------
# `scripts/install.sh` verifies every sub-script it fetches against
# `scripts/manifest.sha256` BEFORE running the privileged steps. gen-manifest.sh
# produces that manifest. It was one of only two scripts under scripts/ that no
# bats suite referenced — measured, 2 of 24 — and it is the one that matters
# most: nothing proved its guards fire.
#
# It carries three claims in its own comments, and this suite tests each of them
# rather than trusting them:
#
#   1. "Keep in lockstep with the FILES array in scripts/install.sh — the --check
#      mode below fails CI if a file the bootstrap fetches is missing from this
#      list (or vice versa)."
#   2. the same for install.ps1's $Files array.
#   3. --check is a CI gate that is non-zero on drift.
#
# All three turned out to be TRUE — worth saying, because this epic is mostly a
# record of such claims being false. What was missing was any test that would
# notice if they stopped being true. The cross-checks are awk extractions of
# another file's array literal, which is exactly the kind of parser that goes
# quietly stale when the file it parses is reformatted.
#
# One real gap was found and fixed alongside this suite: emptying FILES made the
# manifest cover nothing, and the script died on `set -u`'s "FILES[@]: unbound
# variable" — a failure by accident, with a message that says nothing about the
# integrity surface just lost. It now refuses explicitly.

setup() {
  REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # A copy, always: these tests deliberately corrupt install.sh / gen-manifest.sh
  # and must never touch the working tree.
  WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/genman.XXXXXX")"
  cp -R "$REPO/scripts" "$WORK/scripts"
  GM="$WORK/scripts/gen-manifest.sh"
}

teardown() {
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
  return 0
}

run_check() { ( cd "$WORK" && scripts/gen-manifest.sh --check ) }

@test "a clean tree passes --check" {
  run run_check
  [ "$status" -eq 0 ] || return 1
}

# --- claim 1: the bash bootstrap's array must match -----------------------

@test "an entry in install.sh that gen-manifest lacks fails --check" {
  # A script the bootstrap fetches with NO digest in the manifest is
  # unverified code running privileged steps. This is the case the comment
  # promises to catch.
  perl -0pi -e 's/^FILES=\(\n/FILES=(\n  "scripts\/lib\/newthing.sh"\n/m' "$WORK/scripts/install.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install.sh FILES array and gen-manifest.sh FILES differ"* ]] || return 1
}

@test "an entry in gen-manifest that install.sh lacks fails --check (the 'vice versa')" {
  perl -0pi -e 's/^FILES=\(\n/FILES=(\n  "scripts\/lib\/newthing.sh"\n/m' "$GM"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"differ"* ]] || return 1
}

@test "an install.sh whose FILES array cannot be parsed fails closed" {
  # The cross-check is an awk extraction of another file's array literal. If
  # install.sh is reformatted so the pattern stops matching, the extraction
  # yields NOTHING — and a guard that compares nothing to nothing would pass.
  # It must refuse instead.
  perl -0pi -e 's/^FILES=\(/FILE_LIST=(/m' "$WORK/scripts/install.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"differ"* ]] || return 1
}

# --- claim 2: the Windows bootstrap's array must match --------------------

@test "an install.ps1 \$Files divergence fails --check" {
  perl -0pi -e 's/^\$Files = @\(\n/\$Files = @(\n  "scripts\/other.ps1"\n/m' "$WORK/scripts/install.ps1"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install.ps1"* ]] || return 1
}

@test "an install.ps1 whose \$Files array cannot be parsed fails closed" {
  perl -0pi -e 's/^\$Files = @\(/\$FileList = @(/m' "$WORK/scripts/install.ps1"
  run run_check
  [ "$status" -ne 0 ] || return 1
}

# --- claim 3: --check is non-zero on drift -------------------------------

@test "changing a covered file without regenerating fails --check" {
  # The whole point of the manifest: content drift must be visible.
  printf '\n# drift\n' >> "$WORK/scripts/lib/common.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
}

@test "regenerating after a change makes --check pass again" {
  printf '\n# drift\n' >> "$WORK/scripts/lib/common.sh"
  ( cd "$WORK" && scripts/gen-manifest.sh ) >/dev/null 2>&1
  run run_check
  [ "$status" -eq 0 ] || return 1
}

@test "a listed file missing from disk fails --check" {
  rm -f "$WORK/scripts/lib/probe.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"missing file"* ]] || return 1
}

# --- the empty-surface guard added with this suite ------------------------

@test "an empty FILES surface is refused with a diagnostic, not an unbound variable" {
  # Before the explicit guard this died on `set -u` with "FILES[@]: unbound
  # variable" — it failed, but by accident, and the message told an operator
  # nothing about what had just stopped being verified.
  perl -0pi -e 's/^FILES=\((?:.|\n)*?^\)/FILES=(\n)/m' "$GM"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"file surface is empty"* ]] || return 1
  [[ "$output" != *"unbound variable"* ]] || return 1
  # The message must say what was lost, not merely that something is empty.
  [[ "$output" == *"an empty manifest verifies nothing"* ]] || return 1
}

@test "an empty WINDOWS_FILES surface is refused too" {
  perl -0pi -e 's/^WINDOWS_FILES=\((?:.|\n)*?^\)/WINDOWS_FILES=(\n)/m' "$GM"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"file surface is empty"* ]] || return 1
}

# --- the manifest must actually cover both bootstraps --------------------

@test "the committed manifest lists every file both bootstraps fetch" {
  # Guards the premise rather than the mechanism: if the manifest were somehow
  # current AND short, every test above could pass while a fetched script had
  # no digest. Scrapes BOTH bootstraps — install.sh's bash FILES array and
  # install.ps1's PowerShell $Files array — with the same extractions
  # gen-manifest.sh uses, so a Windows-only fetch missing from the manifest is
  # caught here too, not just the bash surface.
  local manifest="$REPO/scripts/manifest.sha256"
  [ -r "$manifest" ] || return 1

  # The bash bootstrap's FILES=( ... ) entries. The trailing `|| true` keeps a
  # broken scrape (grep matching nothing) from aborting the assignment, so the
  # explicit emptiness guard below — not an incidental exit code — is what
  # decides the outcome.
  local bash_fetches
  bash_fetches="$(
    awk '/^FILES=\(/{f=1;next} /^\)/{f=0} f' "$REPO/scripts/install.sh" \
      | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' | grep -v '^$' || true
  )"
  # The Windows bootstrap's $Files = @( ... ) entries.
  local win_fetches
  win_fetches="$(
    awk '/^\$Files = @\($/{f=1;next} /^\)$/{f=0} f' "$REPO/scripts/install.ps1" \
      | sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p' | grep -v '^$' || true
  )"

  # A non-empty extract is the premise of this check, not an afterthought: an
  # empty list means the scrape broke (a bootstrap was reformatted so the awk
  # pattern stopped matching), NOT that coverage is complete. Both arrays are
  # non-empty in reality, so zero entries from EITHER is always a broken parser
  # — fail loudly rather than let missing=0 sail through having verified nothing.
  [ -n "$bash_fetches" ] || { echo "no fetch paths scraped from install.sh"; return 1; }
  [ -n "$win_fetches" ]  || { echo "no fetch paths scraped from install.ps1"; return 1; }

  local missing=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$f" "$manifest" || { echo "not in manifest: $f"; missing=1; }
  done < <(printf '%s\n%s\n' "$bash_fetches" "$win_fetches")
  [ "$missing" -eq 0 ] || return 1
}

# --- claim 4: the manifest covers what install-k8s.sh actually SOURCES -------
#
# backend#2205. The two cross-checks above compare two DECLARATIONS to each
# other; both can agree and both be wrong, because neither was ever compared to
# what the installer sources. Every case here asserts the SPECIFIC message, not
# merely a non-zero exit — the practice the function's own comment invokes and
# which the first version of this PR described without implementing (Asad, #770).
# Two of these six failed on that version.

@test "a lib sourced by install-k8s.sh but absent from FILES fails --check" {
  # The #2205 hole itself: neither fetched by the bootstrap nor covered by the
  # manifest, so at install time it is missing or runs UNVERIFIED.
  printf '#!/usr/bin/env bash\n_probe(){ :; }\n' > "$WORK/scripts/lib/probe-2205.sh"
  perl -0pi -e 's{(source "\$\{LIB_DIR\}/diagnose\.sh")}{$1\nsource "\$\{LIB_DIR\}/probe-2205.sh"}' \
    "$WORK/scripts/install-k8s.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"SOURCED BUT NOT COVERED"* ]] || return 1
}

@test "a lib in FILES that nothing sources fails --check (the over-fetched arm)" {
  # The other direction: a removed lib left listed. Harmless at install time but
  # it means the declaration and the installer have parted company.
  # DELETE the line, do not comment it. The derivation is line-anchored now, but a
  # commented source used to still count -- `grep -oE` ignores what precedes the
  # match -- so commenting was an INERT mutation and this case passed for the
  # wrong reason (it tripped the manifest-stale check instead). Deleting is the
  # input the over-fetched arm actually responds to.
  perl -0pi -e 's{^source "\$\{LIB_DIR\}/diagnose\.sh"\n}{}m' "$WORK/scripts/install-k8s.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"sources a different set of libs than the manifest covers"* ]] || return 1
}

@test "a derivation pattern that matches nothing fails closed, not green" {
  # A silent no-op is exactly what a broken derivation looks like from outside.
  perl -pi -e 's/LIB_DIR\\\}\/\[A-Za-z0-9_-\]\+/LIB_DIR\\}\/[Z]+/' "$GM"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"ZERO sourced libs"* ]] || return 1
}

@test "an unreadable install-k8s.sh says 'could not read', not 'derivation is broken'" {
  # This FAILED before #770's review. Under pipefail the status is the rightmost
  # non-zero and the second grep's 1 masked the first's 2, so a missing installer
  # was reported as a broken pattern — sending the reader to the wrong place.
  rm -f "$WORK/scripts/install-k8s.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"could not read scripts/install-k8s.sh"* ]] || return 1
  [[ "$output" != *"ZERO sourced libs"* ]] || return 1
}

@test "a lib that sources another lib is refused (the transitivity assumption)" {
  # The derivation walks install-k8s.sh only. That is complete exactly while no
  # lib sources a lib, so the assumption is a check rather than a comment.
  printf '\nsource "${LIB_DIR}/common.sh"\n' >> "$WORK/scripts/lib/summary.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no longer complete"* ]] || return 1
}

@test "an unreadable lib glob is refused, not assumed clean" {
  # This FAILED before #770's review: `|| true` swallowed the error, so the
  # transitivity check passed on a failed read — and it is the assumption that
  # makes the non-transitive derivation valid, so failing open here lets the
  # derivation go quietly partial.
  rm -rf "$WORK/scripts/lib"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Refusing to assume none"* || "$output" == *"could not scan"* ]] || return 1
}

@test "a COMMENTED-OUT source does not count as sourced" {
  # The derivation's own regression test. `grep -oE` ignores what precedes the
  # match, so before the select was line-anchored `#source "${LIB_DIR}/x.sh"`
  # still counted as sourced: the sets stayed equal, this check passed, and the
  # run failed later on the manifest digest instead — a different code path than
  # the one under test. Asserting the SPECIFIC message is what separates them.
  perl -0pi -e 's{^(source "\$\{LIB_DIR\}/diagnose\.sh")}{#$1}m' "$WORK/scripts/install-k8s.sh"
  run run_check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"sources a different set of libs than the manifest covers"* ]] || return 1
}
