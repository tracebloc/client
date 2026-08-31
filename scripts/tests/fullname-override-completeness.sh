#!/usr/bin/env bash
# fullnameOverride completeness — backend#2626.
#
# `fullnameOverride` renames the resources this chart creates, so a badly-named
# release is fixable without uninstall + reinstall. backend#2621 built the
# helper, proved the default render byte-identical, and REVERTED IT — because the
# helper is the easy half and completeness is the hard one. The release name
# appears ~174 times across these templates and is at least six different things;
# routing some and not others yields `prod-auto-upgrade` beside
# `myrel-jobs-manager`, which is harder to reason about than a badly-named
# release.
#
# So THIS GUARD is the deliverable, not the helper. Three assertions, and 2 and 3
# are a PAIR — either alone is satisfiable by breaking the other:
#
#   1. NO-OP   Setting the override to the release name renders identically to
#              leaving it unset. Pins that the default is `.Release.Name`
#              verbatim, which is the whole migration-safety argument.
#   2. MOVED   With a distinctive override, NO resource name still carries the
#              release name. Misses are reported BY NAME.
#   3. STAYED  With that same override every exception STILL carries the release
#              name. Without this half, (2) is trivially satisfied by renaming
#              everything — including the env `helm rollback` reads, which is
#              backend#2620 re-introduced by the fix for backend#2621.
#   4. NOTES    The install message names no stale release. Its own render, because
#              `helm template` does not emit NOTES.txt at all.
#
# (2) AND (3) SHARE ONE CLASSIFIER, and that is what closes the gap the first
# version had: (2) read doc-root `metadata.name` only, so every name-REFERENCE
# site — the `DEPLOYMENT_NAME` env `kubectl set image` targets, the Collector's
# filelog glob — could be un-routed with the guard staying green on all four
# profiles. It now walks every string scalar and asks `classify()` which
# exception licenses each release-name hit; (2) is "nothing unlicensed", (3) is
# "every class non-empty and correct". Adding a class cannot weaken (2) without
# also adding an obligation to (3).
#
# EVERY PLATFORM PROFILE, because the platform decides which templates render at
# all: `bm-values.yaml` sets `hostPath.enabled`, and the hostPath PVs plus the
# dataset directory — the on-disk paths this guard most needs to protect — exist
# in no other profile. An earlier single-profile version checked ONE of the four
# release-scoped paths and reported itself satisfied.
#
# Run: scripts/tests/fullname-override-completeness.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# DELIBERATELY LONG, and that is not cosmetic. Assertion 1 diffs two renders
# that BOTH pass through the helper, so a transformation applied uniformly --
# `| trunc N` on the default -- cancels out and is invisible to it. With a short
# release name it is invisible to assertion 1b as well: a mutation adding
# `trunc 3` to the helper SURVIVED the first version of this guard, because the
# release name was `rel`, exactly three characters, so the mutation was inert.
# 38 characters makes any truncation below that observable. (Helm caps release
# names at 53.)
RELEASE="relnamelongenoughtocatchatruncation38"
NS="tracebloc"
OVERRIDE="zzoverride"

profiles=(client/ci/*-values.yaml)
if [ ! -e "${profiles[0]}" ]; then
  echo "[ERROR] no client/ci/*-values.yaml found — this guard would check nothing."
  echo "        Cannot tell is not OK."
  exit 1
fi

echo "== fullnameOverride completeness =="
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failures=0

# NOTES NEEDS ITS OWN RENDER, AND EVERY OBVIOUS ROUTE IS CLOSED. Measured on the
# CI-pinned helm v3.15.4:
#
#   helm template …                                  omits NOTES entirely
#   helm template … --show-only templates/NOTES.txt  "could not find template"
#                                                    (NOTES is not in the
#                                                    manifest set)
#   helm install … --dry-run                         "Kubernetes cluster
#                                                    unreachable"
#   helm install … --dry-run=client                  ALSO needs a cluster on
#                                                    3.15.4, and with a reachable
#                                                    one it fails ownership
#                                                    validation against real
#                                                    objects -- so the guard's
#                                                    verdict would depend on
#                                                    whose kubeconfig ran it
#
# So: render a COPY of the chart in which NOTES.txt is an ordinary template. That
# keeps the real template engine and the real values, needs no cluster, and gives
# the same answer on a laptop and on CI. `--debug` is required because NOTES
# carries ANSI escapes and helm refuses to emit output it cannot parse as YAML
# ("control characters are not allowed"); `--debug` renders it anyway.
# KUBECONFIG=/dev/null is belt-and-braces: it makes the hermeticity a property of
# the command rather than of the machine.
probe="$tmp/notes-probe"
mkdir -p "$probe"
cp -R client "$probe/chart"
mv "$probe/chart/templates/NOTES.txt" "$probe/chart/templates/zz-notes-probe.txt"

# EXIT CODE 1 IS EXPECTED HERE, and swallowing it is deliberate rather than lazy.
# `--debug` prints the render AND still exits non-zero, because helm considers
# unparseable output an error even when asked to emit it anyway. Under
# `set -euo pipefail` that killed the whole guard silently after the first
# profile. So the exit code is discarded and EMPTINESS is the failure signal
# instead — checked by the caller, which is the honest test of "did we get a
# render": a non-zero exit here means nothing, an empty file means we checked
# nothing.
render_notes() {
  KUBECONFIG=/dev/null helm template "$RELEASE" "$probe/chart" --namespace "$NS" \
    --set clientId=x --set clientPassword=p -f "$VALUES" "$@" \
    --show-only templates/zz-notes-probe.txt --debug 2>/dev/null || true
}

for VALUES in "${profiles[@]}"; do
  prof=$(basename "$VALUES" -values.yaml)
  echo "-- profile: $prof"

  render() {
    helm template "$RELEASE" ./client --namespace "$NS" \
      --set clientId=x --set clientPassword=p -f "$VALUES" "$@"
  }
  render                                    > "$tmp/a.yaml"
  render                                    > "$tmp/b.yaml"
  render --set fullnameOverride="$RELEASE"  > "$tmp/explicit.yaml"
  render --set fullnameOverride="$OVERRIDE" > "$tmp/override.yaml"

  notes()  { render_notes "$@"; }
  notes                                    > "$tmp/notes-default.txt"
  notes --set fullnameOverride="$OVERRIDE" > "$tmp/notes-override.txt"
  for f in notes-default notes-override; do
    if ! [ -s "$tmp/$f.txt" ]; then
      echo "   [ERROR] rendering NOTES produced nothing ($f). Cannot tell is not OK."
      failures=$((failures + 1))
    fi
  done

  # --- 1. NO-OP -------------------------------------------------------------
  # NON-DETERMINISM IS MEASURED, NOT LISTED. secrets.yaml mints credentials with
  # `randAlphaNum` when nothing supplies them, so two renders of identical inputs
  # already differ. A hand-kept key list goes stale the day a credential is
  # added — and the template's variable names do not even map to the rendered
  # data keys (`$podTokenSecret` renders as `POD_TOKEN_SIGNING_SECRET`). So ask
  # the chart: any line differing between two IDENTICAL renders cannot be
  # evidence about naming.
  nondet=$(diff "$tmp/a.yaml" "$tmp/b.yaml" 2>/dev/null | grep -E '^[<>]' \
           | sed -E 's/^[<>][[:space:]]*//; s/:.*$//; s/^[[:space:]]+//' \
           | sort -u | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || true)
  if [ -n "$nondet" ]; then
    pat=$(printf '%s\n' "$nondet" | paste -sd'|' -)
    strip() { grep -vE "^[[:space:]]*($pat):" "$1"; }
  else
    strip() { cat "$1"; }
  fi

  if diff <(strip "$tmp/a.yaml") <(strip "$tmp/explicit.yaml") > "$tmp/noop.diff"; then
    echo "   [OK] override == release name renders identically to unset"
  else
    echo "   [ERROR] setting fullnameOverride to the release name CHANGED the render."
    echo "           The default is not '.Release.Name' verbatim, so an existing"
    echo "           install would be renamed by an upgrade that set nothing."
    head -30 "$tmp/noop.diff"
    failures=$((failures + 1))
  fi

  # --- 2 and 3 --------------------------------------------------------------
  # Exit 2 is "could not check" (PyYAML absent), NOT "the chart is incomplete" —
  # reported separately so a missing dependency never reads as a chart defect.
  set +e
  RELEASE="$RELEASE" NS="$NS" OVERRIDE="$OVERRIDE" \
    python3 scripts/tests/fullname_override_assertions.py \
      "$tmp/override.yaml" "$tmp/a.yaml" \
      "$tmp/notes-override.txt" "$tmp/notes-default.txt"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "[ERROR] the guard could not run (see above). This is NOT a verdict on the chart."
    exit 2
  fi
  [ "$rc" -eq 0 ] || failures=$((failures + 1))
done

# --- 5. THE GUARD REFUSES TO RUN HALF OF ITSELF -----------------------------
# A self-check, because assertion 4's "no rendered NOTES was passed" branch is
# unreachable from the loop above (which always passes both files) — and an
# unreachable refusal is one nobody notices has stopped refusing. Measured:
# deleting that branch left the whole guard green.
#
# So invoke the assertions directly with the NOTES arguments MISSING and require
# a non-zero exit. If this ever passes, a future caller could quietly drop the
# NOTES render and the guard would report three assertions as four.
if RELEASE="$RELEASE" NS="$NS" OVERRIDE="$OVERRIDE" \
   python3 scripts/tests/fullname_override_assertions.py \
     "$tmp/override.yaml" "$tmp/a.yaml" >/dev/null 2>&1; then
  echo "[ERROR] the assertions PASSED with no rendered NOTES supplied, so a caller"
  echo "        that drops the NOTES render would get a green guard that checked"
  echo "        three things while documenting four."
  failures=$((failures + 1))
else
  echo "-- self-check: the assertions refuse to run without the NOTES render [OK]"
fi

if [ "$failures" -ne 0 ]; then
  echo "[ERROR] fullnameOverride is incomplete in $failures profile check(s)"
  exit 1
fi
echo "[OK] fullnameOverride routes every resource name, and no exception followed it"
