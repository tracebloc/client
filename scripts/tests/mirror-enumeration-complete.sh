#!/usr/bin/env bash
#
#  mirror-enumeration-complete.sh — the doc's pull-set enumeration must be
#  COMPLETE, and must FAIL rather than under-report (backend#2633).
#
#  The defect this guards against is silent and expensive: a blocked-registry
#  operator enumerates images, mirrors them, installs cleanly, signs off -- and
#  the first experiment ImagePullBackOffs on a run-time-spawned image nobody was
#  told to copy. Nothing in the install path can catch that, because the install
#  itself is genuinely fine.
#
#  So this guard checks the two halves that make the enumeration trustworthy:
#
#    A. THE DOC POINTS AT THE COMPLETE SOURCE. The enumeration command is read
#       out of docs/INSTALL.md itself -- not restated here -- and must invoke
#       list-images.sh. A bare `helm template | grep image:` is rejected by name,
#       because that is the exact command that shipped and under-reported.
#    B. THE SCRIPT IS COMPLETE AND FAILS CLOSED. It must emit the ingestor and
#       the training images as real image references, and must exit NON-ZERO on
#       every "we cannot tell" path rather than printing a short list.
#
#  Every section header asserted below is DERIVED from the doc's own example
#  block, so the doc and the script cannot drift apart on the grouping.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

DOC="docs/INSTALL.md"
SCRIPT="scripts/list-images.sh"
fails=0
checks=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok()   { checks=$((checks + 1)); }

[ -r "$DOC" ]    || { echo "FAIL: $DOC unreadable -- cannot tell, which is a finding (rule 3)" >&2; exit 1; }
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }

# NOTE on the matching style below: every test is `grep ... <<<"$var"`, never
# a printf piped into a quiet grep. Under `set -euo pipefail` a reader that
# closes early sends SIGPIPE upstream and the pipeline exits 141, which
# kills the whole script -- a guard that dies mid-run reports nothing at all
# rather than reporting a finding. This repo has a dedicated
# `quality / pipefail early-close` check for the class (backend#2264); it caught
# six occurrences in the first version of THIS file, having already caught four
# in list-images.sh.

# ---------------------------------------------------------------------------
# A. The doc's own enumeration command.
#
# Extracted from the doc rather than assumed: the fenced bash block that follows
# the "List exactly what to copy" instruction is what an operator will actually
# run, so that block is the thing under test.
# ---------------------------------------------------------------------------
doc_cmd=$(awk '
  /List exactly what to copy/ { armed = 1; next }
  armed && /^```bash$/        { inblock = 1; next }
  inblock && /^```$/          { exit }
  inblock                     { print }
' "$DOC")

if [ -z "$doc_cmd" ]; then
  fail "no fenced bash block follows the 'List exactly what to copy' instruction in $DOC;
      the enumeration step is what this guard is about, so its absence is a failure"
else
  ok
  # Code lines only. A comment mentioning the old command must not satisfy -- or
  # fail -- either check: this repo has been bitten three times by a pattern that
  # matched prose in a comment instead of a declaration (backend#2632).
  doc_code=$(printf '%s\n' "$doc_cmd" | grep -vE '^[[:space:]]*#' || true)

  grep -q 'list-images\.sh' <<<"$doc_code" \
    || fail "$DOC's enumeration block does not invoke list-images.sh. Whatever it
      does invoke cannot see run-time-spawned images, which is the whole defect."
  ok

  if grep -qE 'helm template.*\|.*grep' <<<"$doc_code"; then
    fail "$DOC still enumerates with 'helm template | grep'. That command errors on
      default values, and even with values it reports ZERO of the training images
      and ZERO ingestor -- an operator following it mirrors an incomplete set."
  fi
  ok
fi

# The section headers the doc advertises, taken FROM the doc.
doc_headers=$(grep -oE '^# --- [^-]*(---)?[^-]*---$' "$DOC" | sort -u || true)
[ -n "$doc_headers" ] || fail "$DOC advertises no '# --- ... ---' section headers for the pull set"

# ---------------------------------------------------------------------------
# B. The script: complete output, and non-zero on every unknown.
#
# TRACEBLOC_TASK_REPOS keeps this offline -- the guard tests the ASSEMBLY and the
# refusals, not Docker Hub's availability. Two repos, one per arch, is enough to
# prove the path renders and prefixes them; the count is not what can drift
# silently, the presence of the section is.
# ---------------------------------------------------------------------------
export TRACEBLOC_TASK_REPOS="client-image_classification-cpu client-image_classification-gpu"

OUT=$(mktemp -t mirrorenum.XXXXXX)
ERR=$(mktemp -t mirrorenumerr.XXXXXX)
trap 'rm -f "$OUT" "$ERR"' EXIT INT TERM HUP

if ! "$SCRIPT" --env prod >"$OUT" 2>"$ERR"; then
  fail "$SCRIPT exited non-zero on a normal run:"; sed 's/^/      /' "$ERR" >&2
else
  ok
  # Every header the doc promises must actually appear in the output.
  # Compared on the STABLE PREFIX -- everything before the first " (" -- because
  # one header is parameterised by design: the training-image tag comes from the
  # render's CLIENT_ENV, so the doc cannot name a fixed value without being wrong
  # for every non-prod install. The prefix still pins the section's identity, so
  # renaming a section is caught while a differing tag is not a false failure.
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    prefix="${h%% (*}"
    grep -qF -- "$prefix" "$OUT" \
      || fail "$DOC advertises the section '$h' but $SCRIPT never emits anything
      starting '$prefix'"
    ok
  done <<< "$doc_headers"

  # The ingestor must be a REAL image reference, not prose. Helm preserves
  # template comments in rendered output and INGESTOR_IMAGE_REPOSITORY carries
  # six lines of them before its value -- an extractor that takes "the line after
  # the name" emits a sentence with a digest glued to it, and that is what the
  # first version of this script did.
  ing=$(awk '/^# --- spawned at run time: ingestor/{f=1;next} f&&/^# ---/{exit} f&&NF{print}' "$OUT")
  [ -n "$ing" ] || fail "$SCRIPT emits an EMPTY ingestor section"
  grep -qE '^[a-z0-9.:_/-]+(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$' <<<"$ing" \
    || fail "the ingestor entry is not a well-formed image reference (prose leaking
      from a rendered comment?): '$ing'"
  ok

  # The training images must be present, prefixed with the rendered host, and
  # carry the requested env tag. A path without the registry namespace does not
  # exist -- the first version printed 'docker.io/client-<task>-cpu'.
  train=$(awk '/^# --- spawned at run time: training images/{f=1;next} f&&NF{print}' "$OUT")
  [ -n "$train" ] || fail "$SCRIPT emits an EMPTY training-images section -- the exact
      under-report backend#2633 is about"
  grep -qE '/client-image_classification-cpu:prod$' <<<"$train" \
    || fail "training images are not emitted as <host>/<namespace>/<repo>:<env>: got '${train%%$'\n'*}'"
  grep -qE '^[^/]+/[^/]+/client-' <<<"$train" \
    || fail "training image path is missing the registry namespace segment;
      '<host>/client-<task>-<arch>' is not a repository that exists"
  ok

  grep -qE '^# [0-9]+ chart image\(s\), [0-9]+ training image\(s\)' "$OUT" \
    || fail "$SCRIPT does not report the counts the doc tells operators to trust"
  ok

  # -------------------------------------------------------------------------
  # THE CHART SECTION MUST BE COMPLETE, judged STRUCTURALLY.
  #
  # Why this is not "assert tracebloc/mysql-client is present": the defect was a
  # YAML FORM the extractor could not see (`- image:`, dash and key on one line),
  # not a missing image. Pinning the one image that happened to use that form
  # would go green again the day a fourth form appears -- and a test that
  # re-implements the extractor's own regex is a copy agreeing with itself
  # (CLAUDE.md rule 9).
  #
  # So the expected set is derived by PARSING the render: PyYAML walks every
  # mapping in every document and collects every `image` key, wherever it sits.
  # That has no notion of indentation, dashes or line shape, so it cannot share
  # the blind spot. Any image the chart renders and the script does not print is
  # an image an operator will not mirror.
  # -------------------------------------------------------------------------
  RENDER_T=$(mktemp -t mirrorrender.XXXXXX)
  if ! helm template "$ROOT/client" \
        --set storageClass.create=false \
        --set clientId=enumerate-only \
        --set clientPassword=enumerate-only >"$RENDER_T" 2>/dev/null; then
    fail "could not render the chart here, so completeness is UNVERIFIED. That is a
      finding, not a skip (rule 3): this assertion is the one that proves the
      extractor sees every YAML form the chart actually emits."
  else
    ok
    # VACUITY GUARD. If the chart no longer emits a one-line list item, this
    # whole assertion still passes -- but it would no longer be covering the
    # regression it was written for, and nobody would know. Say so loudly.
    if ! grep -qE '^[[:space:]]*-[[:space:]]+image:' "$RENDER_T"; then
      fail "the render contains no '- image:' list item any more. The extractor
      regression this pins (tracebloc/mysql-client silently dropped) is no longer
      reachable from the real chart, so this assertion has gone vacuous. Re-point
      it at a fixture rather than leaving a green check that proves nothing."
    fi
    ok

    rendered_images=$(python3 - "$RENDER_T" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")

found = set()

def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "image" and isinstance(value, str) and value.strip():
                found.add(value.strip())
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

with open(sys.argv[1], encoding="utf-8") as handle:
    for doc in yaml.safe_load_all(handle):
        walk(doc)

print("\n".join(sorted(found)))
PYEOF
    ) || fail "could not parse the render with PyYAML, so completeness is UNVERIFIED"

    if [ -z "$rendered_images" ]; then
      fail "PyYAML found no image keys in the render at all, which cannot be right
      for this chart -- an empty expectation would compare equal to an empty
      answer and pass for ever (rule 3)"
    else
      ok
      emitted=$(awk '/^# --- rendered by the chart ---/{f=1;next} f&&/^# ---/{exit} f&&NF{print}' "$OUT")
      missing=""
      while IFS= read -r img; do
        [ -n "$img" ] || continue
        # Compare on the bare reference: the script strips surrounding quotes,
        # PyYAML strips them too, so both sides are plain strings here.
        grep -qxF -- "$img" <<<"$emitted" || missing="${missing}${img}"$'\n'
      done <<< "$rendered_images"
      if [ -n "$missing" ]; then
        fail "$SCRIPT omits image(s) the chart actually renders. An operator following
      this list mirrors an incomplete set and the pod ImagePullBackOffs -- the
      backend#2633 failure, produced by the tool meant to prevent it:
$(sed 's/^/        /' <<<"$missing")"
      fi
      ok
    fi
  fi
  rm -f "$RENDER_T"
fi

# --- the refusals. Each must be non-zero AND must not print a partial list. ---
refuses() {   # $1 = human label; rest = argv/env-prefixed command
  local label="$1"; shift
  local out rc
  out=$("$@" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: exited 0. 'We could not tell' must never print as a pull set (rule 3)."
  elif [ -n "$out" ]; then
    fail "$label: refused with exit $rc but still wrote a list to stdout"
  fi
  ok
}

# Both of the refusals below were Bugbot HIGH findings on the first version of
# list-images.sh, and both were the fail-open shape its own header claimed to
# avoid -- so they get permanent coverage rather than a fix and a promise.
BADJSON=$(mktemp -t badbody.XXXXXX); printf 'not json at all\n' >"$BADJSON"

# A GOOD page whose `next` points at the bad one. This is the fixture the
# regression actually needs, and the single-bad-page case below does NOT
# substitute for it (Bugbot, client#881): with only one unparseable page the
# script collects zero names, so the LATER zero-repos check produces the same
# observables `refuses` asserts -- non-zero exit, empty stdout -- and deleting
# the parser's `exit 1` leaves this suite green.
#
# One good page then a bad one is the shape list-images.sh's own comment
# describes: "after ONE successful page the script printed a PARTIAL training
# list and exited 0". Here `task_repos` is non-empty when page 2 fails, so the
# zero-repos check cannot mask the difference -- without the parser's exit
# status the loop just ends and section 3 prints the partial list at exit 0.
GOODTHENBAD=$(mktemp -t goodpage.XXXXXX)
printf '{"next": "file://%s", "results": [{"name": "client-a-cpu"}]}\n' "$BADJSON" >"$GOODTHENBAD"

trap 'rm -f "$OUT" "$ERR" "$BADJSON" "$GOODTHENBAD"' EXIT INT TERM HUP

# A registry page that does not parse must not read as "no more pages". The
# original discarded the interpreter's exit status with `|| echo ""`, so after
# one good page it printed a PARTIAL list and exited 0 -- worse than no list,
# because it looks complete.
# `env -u TRACEBLOC_TASK_REPOS` is load-bearing: this file exports that variable
# globally to keep the rest of the checks offline, and with it set the registry
# branch is never entered at all -- so the refusal under test is unreachable and
# the script exits 0. The guard caught exactly that in its own setup.
refuses "unparseable registry response" \
  env -u TRACEBLOC_TASK_REPOS TRACEBLOC_REGISTRY_URL="file://$BADJSON" "$SCRIPT"

# A FETCH failure AFTER a good page, which is a different path from a fetch
# failure on the FIRST page and was the one case not pinned (Bugbot, medium).
#
# Why the distinction matters: a first-page miss is already caught downstream by
# the zero-repositories check, so replacing the fetch's `exit 1` with a loop
# `break` left both existing refusals green while the script printed a PARTIAL
# training list and exited 0. The guard proved the parse path and merely looked
# like it proved the fetch path.
#
# Page 1 resolves and yields one repo; its `next` points at a file that does not
# exist, so page 2's fetch fails with a non-empty accumulator. Nothing may be
# printed and the exit must be non-zero.
PAGE1=$(mktemp -t page1.XXXXXX)
MISSING="${PAGE1}.absent-on-purpose"
rm -f "$MISSING"
printf '{"next":"file://%s","results":[{"name":"client-image_classification-cpu"}]}\n' \
  "$MISSING" >"$PAGE1"
trap 'rm -f "$OUT" "$ERR" "$BADJSON" "$PAGE1"' EXIT INT TERM HUP

refuses "registry fetch failing AFTER a good page" \
  env -u TRACEBLOC_TASK_REPOS TRACEBLOC_REGISTRY_URL="file://$PAGE1" "$SCRIPT"

# A fetch failure must SHOW curl's own diagnostic and name the remedy that fits
# it. Bugbot, medium: this branch discarded curl's stderr and suggested
# TRACEBLOC_TASK_REPOS unconditionally, so a TLS-inspecting site -- one of the two
# audiences this whole tool exists for -- was shown the one remedy that cannot
# help, and never pointed at TRACEBLOC_CA_BUNDLE which docs/INSTALL.md documents
# for exactly that case. Same "clean symptom, wrong cause" shape as the defect
# this PR fixes.
#
# `file://` to a missing path is used rather than a network failure: it is
# deterministic and offline, and it exercises the same branch. The TLS and DNS
# arms are matched on curl's message, which needs a real endpoint, so those are
# not asserted here -- stated rather than implied.
diagnoses() {   # $1 = human label; $2 = a regex the stderr must match; rest = cmd
  local label="$1" want="$2"; shift 2
  local err rc
  err=$("$@" 2>&1 >/dev/null) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: exited 0 where a refusal was expected"
  elif ! grep -qE "$want" <<<"$err"; then
    fail "$label: stderr does not match /$want/. An operator sees only this, so a
      missing diagnostic is a wrong remedy. Got:
$(sed 's/^/        /' <<<"$err")"
  fi
  ok
}

diagnoses "fetch failure shows curl's own error" '^  curl: ' \
  env -u TRACEBLOC_TASK_REPOS TRACEBLOC_REGISTRY_URL="file:///nonexistent/tb-registry.json" "$SCRIPT"

diagnoses "fetch failure names a usable remedy" 'TRACEBLOC_REGISTRY_URL|TRACEBLOC_CA_BUNDLE|CURL_CA_BUNDLE' \
  env -u TRACEBLOC_TASK_REPOS TRACEBLOC_REGISTRY_URL="file:///nonexistent/tb-registry.json" "$SCRIPT"

# EVERY KNOB THE REFUSAL NAMES MUST BE ONE THIS SCRIPT ACTUALLY READS.
#
# The bug (Bugbot medium x2, @aptracebloc on #881): the TLS arm told operators to
# export TRACEBLOC_CA_BUNDLE -- the variable docs/INSTALL.md documents -- while
# curl_secure() reads only CURL_CA_BUNDLE / SSL_CERT_FILE and wire_ca_trust()
# lives in a lib this script never sources. A site that had already set the
# documented variable was pointed at a knob that was on and inert, and still got
# an x509 failure. "Advice naming a lever that is not wired to anything" is the
# same shape as a guard not wired to what it claims to check.
#
# BOTH SIDES DERIVED, neither restated: the variable names come out of the
# refusal messages themselves, and the answer to "is it read?" comes from the
# script's own non-message code. Add a fourth remedy naming a fourth variable and
# this covers it with no edit here.
remedy_vars=$(sed -n '/^ *case "\$(tr -d/,/^ *esac/p' "$SCRIPT" \
              | grep -oE 'TRACEBLOC_[A-Z_]+' | sort -u || true)
if [ -z "$remedy_vars" ]; then
  fail "could not extract any TRACEBLOC_* variable from $SCRIPT's fetch-failure
      remedies. Either the refusal stopped naming a remedy -- which would leave a
      blocked-registry operator with nothing to do -- or this extraction drifted.
      Both are findings (rule 3)."
else
  ok
  # Code that CONSUMES a variable, as opposed to code that prints its name:
  # comments and the message lines themselves are removed, so what is left is
  # expansion, assignment and tests.
  script_code=$(grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' || true)
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    grep -qF -- "$v" <<<"$script_code" \
      || fail "$SCRIPT's refusal tells the operator to set $v, but no code in the
      script ever reads it. That is advice pointing at an inert knob: the operator
      sets it, nothing changes, and the diagnostic still blames the wrong thing."
    ok
  done <<< "$remedy_vars"
fi

# THE ONE THAT PINS THE PARSER. Mutation-checked: replacing the parser's
# `exit 1` with `:` leaves the case above passing and reddens only this one.
refuses "a good page followed by an unparseable one (no partial list, no exit 0)" \
  env -u TRACEBLOC_TASK_REPOS TRACEBLOC_REGISTRY_URL="file://$GOODTHENBAD" "$SCRIPT"

# The training tag must come from the render's CLIENT_ENV, not from a default.
# The original defaulted to prod and stamped that onto the task images while
# every other line came from the render, so a `stg` values file produced :prod
# task images beside :stg control-plane images.
prod_render_env=$(env TRACEBLOC_TASK_REPOS="client-x-cpu" "$SCRIPT" 2>/dev/null \
                   | sed -n 's/^# --- spawned at run time: training images (tag :\([a-z]*\)).*/\1/p')
if [ -z "$prod_render_env" ]; then
  fail "could not read the derived environment out of the output, so the
      derive-from-CLIENT_ENV behaviour is unverified"
else
  ok
  # Ask for a DIFFERENT environment than the render describes: that must be
  # refused, not silently resolved one way or the other.
  other="stg"; [ "$prod_render_env" = "stg" ] && other="dev"
  refuses "--env disagreeing with the render's CLIENT_ENV" \
    env TRACEBLOC_TASK_REPOS="client-x-cpu" "$SCRIPT" --env "$other"
  # Agreeing is fine, and must still work.
  if ! env TRACEBLOC_TASK_REPOS="client-x-cpu" "$SCRIPT" --env "$prod_render_env" >/dev/null 2>&1; then
    fail "--env agreeing with the render's CLIENT_ENV ('$prod_render_env') was refused"
  fi
  ok
fi

refuses "unrenderable chart"      "$SCRIPT" --chart "$ROOT/does-not-exist"
refuses "zero task repositories"  env TRACEBLOC_TASK_REPOS=" " "$SCRIPT"
refuses "invalid --env"           "$SCRIPT" --env nonsense

if [ "$fails" -ne 0 ]; then
  echo "mirror-enumeration-complete: $fails failure(s) across $checks assertion(s)" >&2
  exit 1
fi
# A guard that ran zero assertions is not a green guard (rule 3).
if [ "$checks" -lt 15 ]; then
  echo "mirror-enumeration-complete: only $checks assertion(s) ran; expected 15+.
  A collapsed run must not report success." >&2
  exit 1
fi
echo "mirror-enumeration-complete: OK ($checks assertions)"
