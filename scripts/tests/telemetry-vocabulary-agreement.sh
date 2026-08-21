#!/usr/bin/env bash
#
#  telemetry-vocabulary-agreement.sh — prove telemetry.sh's closed sets are the
#  producers' sets (backend#1907).
#
#  WHY THIS EXISTS
#  ---------------
#  telemetry.sh's whole privacy and quality argument rests on four closed
#  vocabularies: the install phases, the client states, the installer's own
#  script names, and the error classes. A closed set that has drifted from what
#  actually produces its values does not fail loudly — it quietly reports
#  `unknown`, forever, on the exact runs somebody added the new value for. That
#  is backend#1729's class in its purest form: a mechanism that looks like it
#  verifies something while being disconnected from the thing it claims to
#  check.
#
#  THIS SCRIPT DERIVES. It parses install-k8s.sh, summary.sh and gen-manifest.sh
#  and compares them to telemetry.sh's declarations. It holds no fifth copy of
#  any vocabulary — a fresh hand-written list is the defect, not the fix (the
#  lesson env-vocabulary-agreement.sh was written for, in this same directory).
#
#  The error-class check is different in kind and deliberately so: there is no
#  second declaration to parse, so it EXERCISES telemetry_error_class over the
#  full cross-product of the two closed input sets and checks (a) every answer
#  is registered and (b) every registered class is reachable. Comparing the
#  declaration to itself would be self-consistent and therefore blind.
#
#  READ-ONLY. Exit 0 clean, 1 disagreement, 2 cannot tell (fail closed).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

TELEMETRY="$root/scripts/lib/telemetry.sh"
INSTALL_K8S="$root/scripts/install-k8s.sh"
SUMMARY="$root/scripts/lib/summary.sh"
GEN_MANIFEST="$root/scripts/gen-manifest.sh"

fail_closed() { printf 'ERROR: %s\n' "$1" >&2; exit 2; }

# An unreadable file is not evidence of agreement: zero parsed values compare
# equal to zero parsed values, and the run would report clean having read
# nothing. Refuse instead.
for f in "$TELEMETRY" "$INSTALL_K8S" "$SUMMARY" "$GEN_MANIFEST"; do
  [ -r "$f" ] || fail_closed "cannot read ${f#"$root"/} — refusing to report agreement between declarations one of which was not read"
done

# shellcheck source=/dev/null
source "$TELEMETRY"

status=0
disagree() { printf '  [x] %s\n' "$1" >&2; status=1; }

# sorted LIST — a space-separated vocabulary as sorted, unique lines.
sorted() {
  # Word-splitting the argument is the point: these vocabularies are
  # space-separated lists.
  # shellcheck disable=SC2086
  printf '%s\n' $1 | sed '/^$/d' | LC_ALL=C sort -u
}

compare() { # LABEL  DECLARED  DERIVED  SOURCE_DESCRIPTION
  local label="$1" declared="$2" derived="$3" src="$4" a b
  a="$(sorted "$declared")"
  b="$(sorted "$derived")"
  if [ -z "$b" ]; then
    fail_closed "parsed zero values for $label out of $src — the parse is inert, so this check proves nothing"
  fi
  if [ "$a" != "$b" ]; then
    disagree "$label disagrees with $src:"
    diff -u <(printf '%s\n' "$a") <(printf '%s\n' "$b") \
      | sed -e '1,2d' -e 's/^/      /' >&2 || true
    return 1
  fi
  printf '  ok: %s agrees with %s (%s values)\n' "$label" "$src" "$(printf '%s\n' "$a" | grep -c .)"
}

echo "== telemetry vocabulary agreement =="

# --- 1. install phases ← install-k8s.sh's own step_header letters ------------
# step_header IS the dispatcher for the phase clock (common.sh calls
# telemetry_phase_begin from it), so its letters are the input domain. A seventh
# step added to the run-through without a name here would be timed as `unknown`.
declared_letters=""
for pair in $TB_TELEMETRY_PHASES; do declared_letters="$declared_letters ${pair%%:*}"; done
derived_letters="$(sed -nE 's/^[[:space:]]*step_header[[:space:]]+([a-z])[[:space:]].*/\1/p' "$INSTALL_K8S")"
compare "phase letters" "$declared_letters" "$derived_letters" "install-k8s.sh's step_header calls"

# --- 2. client states ← summary.sh's only two writers of CLIENT_STATE --------
# wait_for_client_ready assigns the literal `connected`; _diagnose_not_ready
# printf's every other state. Note what this caught when it was written: the
# CLIENT_STATE docstring in summary.sh listed five states and the function
# produces six (image_pull_ca, added by #424, was never added to the comment).
derived_states="$(
  {
    sed -nE 's/^[[:space:]]*CLIENT_STATE="([a-z_]+)".*/\1/p' "$SUMMARY"
    awk '/^_diagnose_not_ready\(\)/{f=1} f&&/^}/{f=0} f' "$SUMMARY" \
      | sed -nE "s/.*printf '([a-z_]+)'.*/\1/p"
  }
)"
compare "client states" "$TB_TELEMETRY_CLIENT_STATES" "$derived_states" \
  "summary.sh's CLIENT_STATE writers"

# --- 3. source basenames ← gen-manifest.sh's FILES array --------------------
# The manifest already declares, and cosign already signs, the exact set of
# scripts this installer runs. Reusing it means a script added to the installer
# is reportable the day it lands, and a basename that is not one of ours cannot
# be emitted at all.
derived_sources="$(
  {
    awk '/^FILES=\(/{f=1;next} /^\)/{f=0} f' "$GEN_MANIFEST" \
      | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' -e 's|.*/||'
    # install.sh is the bootstrap: it is the thing that VERIFIES the manifest,
    # so it is legitimately not in it, and a failure inside it is still ours.
    echo "install.sh"
  }
)"
compare "source basenames" "$TB_TELEMETRY_SOURCES" "$derived_sources" \
  "gen-manifest.sh's FILES array + the bootstrap"

# --- 4. error classes ← telemetry_error_class's actual behaviour ------------
# No second declaration exists to parse, so this exercises the classifier over
# the full cross-product of its closed input sets. Both directions matter:
# an unregistered answer is a namespace opening on its own, and a registered
# class nothing can produce is a dashboard row that will never populate.
#
# The re-run marker is the classifier's fourth input and it is a BOOLEAN, so the
# full input domain over it is both values — enumerated here rather than left at
# the default, because a vocabulary gap is exactly what mutation coverage cannot
# see (workspace CLAUDE.md rule 6). Leaving it out would make `unexpected_exit_2`
# unreachable and this section would say so; that reading is the check working.
phase_names="bootstrap unknown"
for pair in $TB_TELEMETRY_PHASES; do phase_names="$phase_names ${pair#*:}"; done
produced=""
for phase in $phase_names; do
  for state in "" $TB_TELEMETRY_CLIENT_STATES; do
    for code in 1 2 42 130; do
      for handoff in "" 1; do
        cls="$(telemetry_error_class "$code" "$phase" "$state" "$handoff")"
        produced="$produced $cls"
        case " $TB_TELEMETRY_ERROR_CLASSES " in
          *" $cls "*) ;;
          *) disagree "telemetry_error_class($code, $phase, '$state', '$handoff') returned '$cls', which is not in TB_TELEMETRY_ERROR_CLASSES" ;;
        esac
      done
    done
  done
done
[ -n "$(sorted "$produced")" ] || fail_closed "the classifier produced nothing — the cross-product is inert"
for cls in $TB_TELEMETRY_ERROR_CLASSES; do
  case " $(sorted "$produced" | tr '\n' ' ') " in
    *" $cls "*) ;;
    *) disagree "'$cls' is registered but no (phase, state) pair produces it — a dashboard row that can never populate" ;;
  esac
done
[ "$status" -eq 0 ] && printf '  ok: every error class is reachable and every answer is registered\n'

# --- 5. the version shape ← install.sh's own immutable-release-tag gate ------
# service.version is the one resource field a shell variable feeds, and the
# generic token shape is not enough on its own: `v1.9.3-<64 arbitrary chars>`
# satisfies it, which would make the version column a 64-byte free-text channel.
# The bootstrap already decides what a release tag looks like — it refuses to
# fetch from anything else — so telemetry.sh reuses that exact regex.
#
# THIS CHECK USED TO COMPARE BYTES, AND BYTES WERE THE WRONG PROPERTY. It read
# the two regexes and asserted they were the same string, then reported "the
# service.version shape is install.sh's own release-tag gate" — a claim about
# BEHAVIOUR that byte-identity does not support, because the two sides did not
# match with the same operator. install.sh used `[[ =~ ]]` (whole string);
# telemetry.sh used `grep -qE` (whole LINE), so `v1.9.3\n<anything>` was refused
# by the bootstrap and admitted by the emitter — from identical regexes, with
# this check green throughout. Exactly backend#1729's class: a guard passing on a
# property it does not actually check. (saadqbal on client#747.)
#
# So it now checks both, in this order:
#   (a) the two declarations are still byte-identical — cheap, and it localises
#       the failure to "somebody edited one of them";
#   (b) they AGREE ON VERDICTS over a corpus of inputs, each side evaluated by
#       the operator the file that owns it actually uses. (b) is the check the
#       header sentence promises; (a) alone never was.
#
# The corpus is written down here rather than derived, and that is deliberate:
# it is the input domain, not a copy of either rule (workspace CLAUDE.md rule 6 —
# a vocabulary gap is invisible to mutation coverage, so the inputs have to be
# enumerated independently of the matcher). It must contain at least one input
# that separates line-matching from string-matching, or (b) degenerates into (a).
BOOTSTRAP="$root/scripts/install.sh"
[ -r "$BOOTSTRAP" ] || fail_closed "cannot read scripts/install.sh"
boot_re="$(sed -nE 's/.*! "\$REF" =~ (\^v.*\$)\ ?\]\].*/\1/p' "$BOOTSTRAP" | head -1)"
[ -n "$boot_re" ] || fail_closed "could not find install.sh's release-tag regex — the parse is inert, so this check proves nothing"
if [ "$boot_re" != "$TB_TELEMETRY_VERSION_RE" ]; then
  disagree "TB_TELEMETRY_VERSION_RE and install.sh's release-tag gate are not the same regex:"
  printf '      telemetry.sh: %s\n      install.sh:   %s\n' \
    "$TB_TELEMETRY_VERSION_RE" "$boot_re" >&2
else
  printf '  ok: the service.version regex is byte-identical to install.sh'"'"'s\n'
fi

# The bootstrap's verdict, reached the way install.sh reaches it (:203).
_boot_admits() { [[ $1 =~ $boot_re ]]; }
# The emitter's verdict, reached the way telemetry.sh reaches it: through the
# real function, on the real variable. Not a re-implementation of the rule —
# a mutation of _telemetry_version has to redden this (workspace CLAUDE.md
# rule 9), which it cannot if this line spells the match out again.
_emitter_admits() {
  local rendered
  rendered="$( TB_VERSION="$1"; _telemetry_version )"
  [ "$rendered" != "0.0.0-unknown" ]
}

version_corpus=(
  'v1.9.3'                       # a plain release tag: both must admit
  'v1.9.3-rc.1'                  # the pre-release suffix the regex allows
  'v1.9.3.post1'                 # the dotted suffix it allows
  'main'                         # a branch name: both must refuse
  'v1.9'                         # two segments: both must refuse
  'v1.9.3-'"$(printf '%064d' 0)"  # 64 trailing chars: both must refuse
  'v1.9.3 ; rm -rf /'            # a space: both must refuse
  $'v1.9.3\nmain'                # THE SEPARATOR — a first line that matches and
                                 # a second that does not. grep says yes, [[ =~ ]]
                                 # says no. Without this input the behavioural
                                 # check is just the byte check again.
  $'main\nv1.9.3'                # …and the other way round
  $'v1.9.3\n","injected":"yes'   # the actual forgery from the review
)
separator_seen=0
for candidate in "${version_corpus[@]}"; do
  case "$candidate" in *$'\n'*) separator_seen=1 ;; esac
  if _boot_admits "$candidate"; then b=admit; else b=refuse; fi
  if _emitter_admits "$candidate"; then e=admit; else e=refuse; fi
  if [ "$b" != "$e" ]; then
    disagree "the two version gates DISAGREE on $(printf '%q' "$candidate"): install.sh would $b, telemetry.sh does $e"
  fi
done
# Fail closed on an inert corpus: without an embedded-newline input the
# behavioural check proves nothing the byte check did not already prove, and it
# would report clean forever.
[ "$separator_seen" -eq 1 ] || fail_closed "the version corpus contains no embedded-newline input — the behavioural check cannot separate line-matching from string-matching, so it proves nothing"
[ "$status" -eq 0 ] && printf '  ok: the two version gates agree on every input in the corpus (%s inputs), not just byte-for-byte\n' "${#version_corpus[@]}"

# --- 6. event names ← telemetry_render_event's own case statement ------------
# §6.2 requires the set of event names a service can emit to be finite and
# enumerable by grep. TB_TELEMETRY_EVENT_NAMES is that enumeration; this proves
# it is the set the renderer actually produces, from two independent directions.
#
# It cannot check the other half — that each third segment is a §6.4 registered
# outcome verb — because the verb registry lives in the rfcs repo, which is not
# checked out here. Copying the verbs into this file would be a fifth declaration
# of somebody else's vocabulary, i.e. the defect this script exists to prevent.
# The §6.1 GRAMMAR is checkable from here, so it is checked.
declared_names="$TB_TELEMETRY_EVENT_NAMES"

# (a) the literals in the case statement.
parsed_names="$(sed -nE 's/.*[^A-Za-z_]event="(install\.[a-z0-9_.]+)".*/\1/p' "$TELEMETRY")"
compare "event names" "$declared_names" "$parsed_names" \
  "the literals in telemetry_render_event's case statement"

# (b) what the function actually renders, over the exit codes the installer
# produces: 0, a bare 2, an ordinary failure, and both signals. 2 is swept here
# with the re-run marker UNSET, which is the ordinary-tool case — the marker's own
# effect on the render is (d5)'s job, because it is a behaviour and not a name.
# Read by the sourced telemetry.sh, not by this file — telemetry_render_event
# needs a recognised environment or it renders nothing at all (§3.2), which would
# make the comparison below inert.
# shellcheck disable=SC2034
CLIENT_ENV=prod
# shellcheck disable=SC2034
OS=Linux
# shellcheck disable=SC2034
ARCH=x86_64
# shellcheck disable=SC2034
TB_VERSION=v1.9.3
rendered_names=""
for code in 0 1 2 42 130 143; do
  for skipped in "" 1; do
    _TB_TELEMETRY_SKIPPED="$skipped"
    ev="$(telemetry_render_event "$code" | sed -nE 's/.*"event\.name":"([^"]*)".*/\1/p')"
    [ -n "$ev" ] || disagree "telemetry_render_event $code rendered no event.name"
    rendered_names="$rendered_names $ev"
  done
done
_TB_TELEMETRY_SKIPPED=""
compare "event names rendered" "$declared_names" "$rendered_names" \
  "telemetry_render_event exercised over the installer's exit codes"

# (c) §6.1's grammar: exactly three segments, lowercase, no runtime value.
name_re='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2}$'
for ev in $declared_names; do
  [[ $ev =~ $name_re ]] || disagree "'$ev' is not a legal contract event name (§6.1: three segments, ^[a-z][a-z0-9_]*)"
done

# (d) THE RE-RUN HANDOFF IS A MARKER, NOT THE NUMBER 2.
#
# gpu-nvidia.sh exits 2 after a SUCCESSFUL driver install to ask for a reboot, and
# install_cleanup has treated 2 as its own outcome since client#681 — so an exit 2
# that renders `failed` fabricates a prerequisite failure on every unattended GPU
# host's first install. That much this check always proved.
#
# What it did not: `2` is also a status ORDINARY TOOLS produce (grep on a file
# error, curl on a failed init, tar on a fatal, and cluster.sh's `exit "$create_rc"`
# re-raising whatever k3d returned). Keying on the number filed those as
# `cancelled` with no error.type — removed from the numerator, not misfiled in it.
# So the checked property is now agreement between the marker's PRODUCERS, the
# emitter's BRANCH, and the RENDER, in that order. (saadqbal on client#747.)
#
# Still derived from install_cleanup's own branch as the premise: if common.sh
# stops treating 2 specially, this whole section retires itself loudly rather than
# guarding a rule that no longer exists.
COMMON="$root/scripts/lib/common.sh"
[ -r "$COMMON" ] || fail_closed "cannot read scripts/lib/common.sh"
grep -qE '^\s*if \[\[ \$exit_code -eq 2 \]\]; then' "$COMMON" \
  || fail_closed "could not find install_cleanup's exit-2 branch in common.sh — this check's premise is gone, so it proves nothing"

# (d1) the variable the emitter's exit-2 branch actually tests, read out of the
# branch itself. Not written down here: a second spelling of the name is how this
# check would go on passing after a rename that broke the handoff.
handoff_var="$(awk '/^  case "\$code" in/{c=1} c&&/^    2\)/{b=1} b&&match($0,/_TB_[A-Z_]+/){print substr($0,RSTART,RLENGTH); exit}' "$TELEMETRY")"
[ -n "$handoff_var" ] || fail_closed "could not find the variable telemetry_render_event's exit-2 branch tests — the parse is inert, so this check proves nothing"

# (d2) the SETTER: the one-line function in telemetry.sh whose body assigns that
# variable — the same shape as its two sibling latches (telemetry_run_started,
# telemetry_run_skipped). Derived, so a rename moves both sides at once or reddens
# here. Deliberately NOT "the nearest preceding function header": the top-level
# `<var>=""` init line would then be attributed to whichever latch was defined
# above it, and this check would go on green while pointing at the wrong function.
# Reformatting the setter across several lines makes this parse inert, and inert
# fails closed below rather than passing.
handoff_fn="$(sed -nE "s/^([a-z_]+)\(\) \{[^}]*${handoff_var}=.*/\1/p" "$TELEMETRY" | head -1)"
[ -n "$handoff_fn" ] || fail_closed "no function in telemetry.sh assigns $handoff_var — the marker has no setter, so nothing can declare a handoff"
declare -F "$handoff_fn" >/dev/null 2>&1 \
  || fail_closed "$handoff_fn was parsed out of telemetry.sh but is not defined after sourcing it"

# (d3) the marker must be CLEARED at source time. This is the fail-open hole one
# level down: read as an inherited environment value, `<var>=1` in a user's shell
# would turn every real failure into a cancel.
grep -qE "^${handoff_var}=(\"\"|'')?\$" "$TELEMETRY" \
  || disagree "$handoff_var is not cleared at telemetry.sh's top level — an inherited environment value could pose as a declared handoff"

# (d4) EVERY deliberate `exit 2` in the installer runtime declares the handoff.
# The runtime is install-k8s.sh plus the libs it sources: those are the files that
# run under install_cleanup's EXIT trap, and therefore the only ones whose exit
# status telemetry ever sees. A NEW handoff site added without the setter books
# itself as a failure — the safe direction, but still wrong, and this is what
# says so.
#
# Fails closed on ZERO sites, because that is the shape this whole change exists
# to prevent: install_cleanup still reads TRACEBLOC_DOCKER_FIRST_RUN_EXIT, whose
# only producer was deleted in 8c3a3d4 (March) — a live branch keyed on a marker
# nothing sets, passing forever. Zero producers here means the marker has quietly
# become that, and "no sites to check" must never read as agreement.
handoff_sites=0 undeclared=""
while IFS= read -r hit; do
  f="${hit%%:*}"; rest="${hit#*:}"; n="${rest%%:*}"
  handoff_sites=$(( handoff_sites + 1 ))
  # The declaration must be in the same block, immediately before the exit. Three
  # lines is the window: the guarded call is one line, and a `log` line before it
  # is the existing shape at gpu-nvidia.sh's site.
  if ! awk -v s="$(( n > 3 ? n - 3 : 1 ))" -v e="$n" -v fn="$handoff_fn" \
        'NR>=s && NR<e && index($0, fn) { found=1 } END { exit !found }' "$f"; then
    undeclared="$undeclared ${f#"$root"/}:$n"
  fi
done < <(grep -nE '^[[:space:]]*exit 2[[:space:]]*(#.*)?$' \
           "$INSTALL_K8S" "$root"/scripts/lib/*.sh 2>/dev/null || true)
if [ "$handoff_sites" -eq 0 ]; then
  fail_closed "no \`exit 2\` site exists in the installer runtime, so nothing calls $handoff_fn — the marker is dead and the emitter's cancelled branch is unreachable (the TRACEBLOC_DOCKER_FIRST_RUN_EXIT shape)"
fi
if [ -n "$undeclared" ]; then
  disagree "these \`exit 2\` sites do not call $handoff_fn, so telemetry will book them as failures:$undeclared"
else
  printf '  ok: all %s deliberate `exit 2` site(s) declare the handoff via %s\n' "$handoff_sites" "$handoff_fn"
fi

# (d5) and the render agrees with the marker, in BOTH directions — through the
# real functions, on the real variable, so a mutation of either has to redden this
# (workspace CLAUDE.md rule 9). The undeclared direction is the one the number-
# keyed version got wrong, and it is asserted first.
eval "$handoff_var=''"
ev2_bare="$(telemetry_render_event 2)"
case "$(printf '%s' "$ev2_bare" | sed -nE 's/.*"event\.name":"([^"]*)".*/\1/p')" in
  '')       disagree "an undeclared exit 2 rendered no event at all" ;;
  *.failed) case "$ev2_bare" in
              *'"error.type"'*) printf '  ok: an undeclared exit 2 is a failure and carries error.type (§8.4)\n' ;;
              *) disagree "an undeclared exit 2 renders failed but carries no error.type — §8.4 requires one, and a failure that cannot be grouped is the reason this contract exists" ;;
            esac ;;
  *)        disagree "an undeclared exit 2 renders '$(printf '%s' "$ev2_bare" | sed -nE 's/.*"event\.name":"([^"]*)".*/\1/p')' — an ordinary tool's status 2 escaping under \`set -e\` must land in the numerator, not be silently cancelled" ;;
esac

"$handoff_fn"
ev2_marked="$(telemetry_render_event 2)"
case "$(printf '%s' "$ev2_marked" | sed -nE 's/.*"event\.name":"([^"]*)".*/\1/p')" in
  *.failed) disagree "a DECLARED exit 2 renders failed — install_cleanup treats it as its own outcome (\"Re-run required\") and gpu-nvidia.sh exits 2 after a driver install SUCCEEDED" ;;
  '')       disagree "a declared exit 2 rendered no event at all" ;;
  *)        case "$ev2_marked" in
              *'"error.type"'*) disagree "a declared exit 2 carries error.type — it is not a failure, and §8.4 attaches error.type to failures" ;;
              *) printf '  ok: a declared exit 2 renders %s, not a failure\n' "$(printf '%s' "$ev2_marked" | sed -nE 's/.*"event\.name":"([^"]*)".*/\1/p')" ;;
            esac ;;
esac
# The marker is process state and the sections below render more events: leave it
# the way telemetry.sh sourced it, or (b)'s name sweep silently runs half-marked.
eval "$handoff_var=''"

# --- 7. the documented opt-out ← telemetry.sh's real variables --------------
# A stale doc here is worse than none: a user who exports the variable
# `--help` names believes they have opted out, and nothing else would ever tell
# them otherwise. The declaration is in telemetry.sh and the promise is in
# common.sh's print_help, so neither file can be edited alone.
HELP_SRC="$root/scripts/lib/common.sh"
[ -r "$HELP_SRC" ] || fail_closed "cannot read scripts/lib/common.sh"
documented="$(awk '/^print_help\(\)/{f=1} f&&/^HELP$/{f=0} f' "$HELP_SRC" \
  | sed -nE 's/^[[:space:]]*([A-Z_]+)=1[[:space:]].*/\1/p')"
[ -n "$documented" ] || fail_closed "print_help names no opt-out variable — either the section was removed (then remove this check) or its shape changed and this parse is inert"
compare "opt-out variables" "$TB_TELEMETRY_OPT_OUT_VARS" "$documented" \
  "the environment variables print_help tells users to set"

# --- 8. THE WINDOWS TWIN ← telemetry.ps1's own arrays -----------------------
# backend#2268. install-k8s.ps1 had no emitter at all, and the parity harness
# built after a Windows capability died silently (client#772) could not see it:
# that harness compares VERDICTS for cases both twins implement, so it cannot
# express "this twin does not implement the capability".
#
# The ps1 emitter therefore holds a SECOND COPY of these closed sets, because a
# PowerShell script cannot read bash declarations at runtime. That duplication is
# the restated-not-derived shape this whole file exists to catch, so it is checked
# here rather than trusted: both sides are parsed, neither is written down, and a
# value added to one twin alone is a disagreement.
#
# NOT the source vocabulary. TB_TELEMETRY_SOURCES lists the eighteen bash files
# and the ps1 lists its own three — they SHOULD differ, and comparing them would
# be a check that has to fail. `tracebloc.install.source` is still closed on both
# sides; it is closed over a different set on each, which is the correct answer
# for "is this location one of MY scripts".
TELEMETRY_PS1="$root/scripts/lib/telemetry.ps1"
[ -r "$TELEMETRY_PS1" ] || fail_closed "cannot read scripts/lib/telemetry.ps1 — the Windows emitter is part of this contract since backend#2268; refusing to report agreement having read one twin"

# ps1_array NAME — the single-quoted members of a `$script:NAME = @( ... )`
# literal, space-separated.
#
# HANDLES BOTH SHAPES, and the one-line one is why this is not a two-line awk.
# The first version did `next` after matching the opening line, which is correct
# for a multi-line array and silently wrong for `= @('A', 'B')`: it skipped the
# only line with the values, never saw a closing paren at line start, and went on
# to swallow every quoted string in the rest of the file — regexes, log messages,
# JSON fragments. The emptiness guard below could not catch it because the parse
# returned MORE than it should, not less. A non-empty wrong answer is the third
# failure mode, so this prints the opening line too and stops at the paren that
# closes it, and the caller checks the shape of what came back.
ps1_array() {
  awk -v want="$1" '
    !inside && $0 ~ ("\\$script:" want "[[:space:]]*=[[:space:]]*@\\(") {
      inside = 1
      print
      # A same-line close means the whole array was on this line.
      if ($0 ~ /\)[[:space:]]*$/) exit
      next
    }
    inside && /^[[:space:]]*\)/ { exit }
    inside                       { print }
  ' "$TELEMETRY_PS1" \
    | grep -oE "'[^']+'" | tr -d "'" | tr '\n' ' '
}

for pair in \
  "TbTelemetryPhases|$TB_TELEMETRY_PHASES|install phases" \
  "TbTelemetryEventNames|$TB_TELEMETRY_EVENT_NAMES|event names" \
  "TbTelemetryClientStates|$TB_TELEMETRY_CLIENT_STATES|client states" \
  "TbTelemetryErrorClasses|$TB_TELEMETRY_ERROR_CLASSES|error classes" \
  "TbTelemetryOptOutVars|$TB_TELEMETRY_OPT_OUT_VARS|opt-out variables"
do
  ps1_name="${pair%%|*}"
  rest="${pair#*|}"
  bash_val="${rest%%|*}"
  label="${rest#*|}"
  ps1_val="$(ps1_array "$ps1_name")"
  # A parse that found nothing is a finding, not agreement: the awk above depends
  # on the ps1 keeping `$script:Name = @(` on one line, and a reformat that broke
  # that would otherwise silently compare two empty sets and report clean.
  [ -n "$ps1_val" ] || fail_closed "parsed zero values for \$script:$ps1_name out of telemetry.ps1 — the parse is inert, so the twins are not actually being compared"
  # A runaway parse is as wrong as an empty one and looks nothing like it: bound
  # the answer, so a reformat that breaks the range scan is a finding rather than
  # a 400-line diff. No vocabulary here is anywhere near this size.
  ps1_count="$(printf '%s\n' $ps1_val | grep -c .)"
  [ "$ps1_count" -le 40 ] || fail_closed "parsed $ps1_count values for \$script:$ps1_name out of telemetry.ps1 — the range scan has run away past the array, so this comparison is meaningless"
  compare "$label (bash twin)" "$bash_val" "$ps1_val" "telemetry.ps1's \$script:$ps1_name"
done

if [ "$status" -eq 0 ]; then
  echo "  ok: telemetry vocabularies agree with their producers"
fi
exit "$status"
