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
# the full cross-product of its two closed input sets. Both directions matter:
# an unregistered answer is a namespace opening on its own, and a registered
# class nothing can produce is a dashboard row that will never populate.
phase_names="bootstrap unknown"
for pair in $TB_TELEMETRY_PHASES; do phase_names="$phase_names ${pair#*:}"; done
produced=""
for phase in $phase_names; do
  for state in "" $TB_TELEMETRY_CLIENT_STATES; do
    for code in 1 2 42 130; do
      cls="$(telemetry_error_class "$code" "$phase" "$state")"
      produced="$produced $cls"
      case " $TB_TELEMETRY_ERROR_CLASSES " in
        *" $cls "*) ;;
        *) disagree "telemetry_error_class($code, $phase, '$state') returned '$cls', which is not in TB_TELEMETRY_ERROR_CLASSES" ;;
      esac
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
# fetch from anything else — so telemetry.sh reuses that exact regex, and this
# proves the two are byte-identical rather than merely similar.
BOOTSTRAP="$root/scripts/install.sh"
[ -r "$BOOTSTRAP" ] || fail_closed "cannot read scripts/install.sh"
boot_re="$(sed -nE 's/.*! "\$REF" =~ (\^v.*\$)\ ?\]\].*/\1/p' "$BOOTSTRAP" | head -1)"
[ -n "$boot_re" ] || fail_closed "could not find install.sh's release-tag regex — the parse is inert, so this check proves nothing"
if [ "$boot_re" != "$TB_TELEMETRY_VERSION_RE" ]; then
  disagree "TB_TELEMETRY_VERSION_RE and install.sh's release-tag gate disagree:"
  printf '      telemetry.sh: %s\n      install.sh:   %s\n' \
    "$TB_TELEMETRY_VERSION_RE" "$boot_re" >&2
else
  printf '  ok: the service.version shape is install.sh'"'"'s own release-tag regex\n'
fi

# --- 6. the documented opt-out ← telemetry.sh's real variables --------------
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

if [ "$status" -eq 0 ]; then
  echo "  ok: telemetry vocabularies agree with their producers"
fi
exit "$status"
