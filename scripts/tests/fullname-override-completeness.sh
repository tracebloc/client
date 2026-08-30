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
  if RELEASE="$RELEASE" NS="$NS" OVERRIDE="$OVERRIDE" \
     python3 scripts/tests/fullname_override_assertions.py "$tmp/override.yaml" "$tmp/a.yaml"; then
    :
  else
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "[ERROR] fullnameOverride is incomplete in $failures profile check(s)"
  exit 1
fi
echo "[OK] fullnameOverride routes every resource name, and no exception followed it"
