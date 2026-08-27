#!/usr/bin/env bash
#
#  list-images.sh — the COMPLETE set of images an install pulls (backend#2633).
#
#  WHY THIS EXISTS. INSTALL.md told a blocked-registry operator to enumerate the
#  pull set with:
#
#      helm template tracebloc/client | grep -oE 'image: "[^"]+"' | sort -u
#
#  That command is wrong in three separate ways, all measured on develop:
#
#    1. IT ERRORS. With default values `helm template ./client` exits 1 on
#       `storageClass.provisioner is required` and then on `clientId is
#       required`. The operator gets a stack of Helm errors, not a list. If they
#       redirect stderr they get SILENCE, which reads as "no images to mirror".
#    2. IT CANNOT SEE RUN-TIME-SPAWNED IMAGES. The 32 `tracebloc/client-<task>-
#       <arch>` training images and the ingestor are named by jobs-manager at
#       spawn time, not by any chart template. `grep -c 'client-'` over the
#       rendered output is 0.
#    3. IT MISSES CONDITIONAL TEMPLATES. The GPU device plugins render only when
#       `gpu.devicePlugin.enabled=true`, which is not the default -- so a GPU
#       site enumerating with defaults silently omits them.
#
#  The consequence is the expensive kind: the control plane comes up completely
#  clean on a mirror, `helm test` passes, the install is signed off -- and the
#  FIRST EXPERIMENT ImagePullBackOffs on an image nobody was told to copy.
#
#  WHAT IS *NOT* BROKEN, because it was the ticket's headline claim and it is
#  false: `global.imageRegistry` DOES re-home the training images. The chart
#  derives `JOB_IMAGE_HOST` from it (templates/jobs-manager-deployment.yaml) and
#  `client/tests/global_image_registry_test.yaml` asserts exactly that, as it
#  does for `INGESTOR_IMAGE_REPOSITORY`. So the operator must NOT be told to set
#  `JOB_IMAGE_HOST` by hand -- it is derived, and setting it would be one more
#  thing to get wrong. The defect is knowing WHAT TO COPY, not how to re-home it.
#
#  EVERYTHING HERE IS DERIVED (CLAUDE.md rule 1). A hand-written list of 32 image
#  names would drift the first time a task is renamed -- and backend#2605 exists
#  because exactly that drift already went unnoticed for ~7 months.
#
#    chart images   <- `helm template` on YOUR values, so conditionals resolve
#    mirror prefix  <- the rendered JOB_IMAGE_HOST
#    ingestor       <- the rendered INGESTOR_IMAGE_REPOSITORY + TAG/DIGEST
#    training tasks <- the registry's own `<prefix>client-*` repository list
#
#  FAILS CLOSED (rule 3). A failed render, an unreadable registry, or a task
#  enumeration of zero is an ERROR, not an empty section. "We could not tell"
#  must never print as "nothing to mirror" -- that is the bug this replaces.
#
#  USAGE
#    scripts/list-images.sh [--env prod|stg|dev] [--chart <path-or-ref>] [-- <helm args>]
#
#    # a real mirrored install, enumerated with the operator's own values:
#    scripts/list-images.sh --env prod -- -f my-values.yaml --set global.imageRegistry=mirror.corp.example
#
#  TRACEBLOC_TASK_REPOS may hold a newline- or space-separated task-repo list to
#  bypass the registry call (used by the test suite; also an escape hatch on a
#  host that cannot reach the registry at all).
#
#  TRACEBLOC_REGISTRY_URL overrides the repository-list endpoint (a private
#  mirror of it, or a fixture in the test suite). TRACEBLOC_REGISTRY_NAMESPACE
#  overrides the namespace the task repos live under.

set -euo pipefail

ENV_TAG=""          # empty => derive from the render's CLIENT_ENV
ENV_TAG_EXPLICIT=0  # set when the operator passed --env
CHART=""
HELM_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --env)   ENV_TAG="${2:?--env needs a value}"; ENV_TAG_EXPLICIT=1; shift 2 ;;
    --chart) CHART="${2:?--chart needs a value}"; shift 2 ;;
    --)      shift; HELM_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) echo "list-images: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ "$ENV_TAG_EXPLICIT" -eq 1 ]; then
  case "$ENV_TAG" in
    prod|stg|dev) ;;
    *) echo "list-images: --env must be prod, stg or dev (got '$ENV_TAG')" >&2; exit 2 ;;
  esac
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -n "$CHART" ] || CHART="$ROOT/client"

# curl_secure() carries the repo's TLS floor and timeout bounds (backend#1252).
# A bare `curl` here would be an unbounded, un-floored fetch, and the style guard
# rejects one by name -- correctly: this call reaches the public internet.
# shellcheck source=scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"

command -v helm >/dev/null 2>&1 || { echo "list-images: helm is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. The chart-rendered set.
#
# The two values below are required by the chart and carry no defaults, so a
# bare `helm template` errors. They are placeholders for ENUMERATION ONLY --
# image names do not depend on them -- and the operator's own `-- -f values.yaml`
# overrides them. Passing them is what turns the doc's error into a list.
# ---------------------------------------------------------------------------
RENDER=$(mktemp); ERRLOG=$(mktemp)
trap 'rm -f "$RENDER" "$ERRLOG"' EXIT INT TERM HUP

if ! helm template "$CHART" \
      --set storageClass.create=false \
      --set clientId=enumerate-only \
      --set clientPassword=enumerate-only \
      "${HELM_ARGS[@]+"${HELM_ARGS[@]}"}" >"$RENDER" 2>"$ERRLOG"; then
  echo "list-images: helm template failed, so the pull set is UNKNOWN." >&2
  echo "  Refusing to print a partial list -- an incomplete mirror is the failure" >&2
  echo "  this tool exists to prevent (backend#2633)." >&2
  sed 's/^/  helm: /' "$ERRLOG" >&2
  exit 1
fi

chart_images=$(grep -hoE '^[[:space:]]*image:[[:space:]]*"?[^"[:space:]]+' "$RENDER" \
               | sed -E 's/^[[:space:]]*image:[[:space:]]*"?//' | sort -u)

if [ -z "$chart_images" ]; then
  echo "list-images: the render produced no image: lines at all, which cannot be" >&2
  echo "  right for this chart. Refusing to report an empty pull set." >&2
  exit 1
fi

# The prefix jobs-manager stamps onto spawned images, read from the render rather
# than reconstructed -- so a mirror set via global.imageRegistry is reflected here
# automatically, and this tool cannot disagree with the chart about it.
# `awk ... exit` rather than piping into an early-closing reader: such a reader
# sends SIGPIPE upstream, and under `set -o pipefail` that becomes exit 141 and
# kills the whole script. This repo has a dedicated
# `quality / pipefail early-close` check for that class (backend#2264) -- and
# the first version of this script tripped it in four places.
# Scans forward to the first `value:` after the `name:`, rather than taking the
# next line. Helm PRESERVES TEMPLATE COMMENTS in rendered output, and
# INGESTOR_IMAGE_REPOSITORY carries six lines of them between its name and its
# value -- so "the next line" returned a comment and the ingestor entry came out
# as prose with a digest glued on. Measured, not guessed: /tmp render line 2351.
first_env_value() {   # $1 = env var name; prints the rendered value, or nothing
  awk -v want="name: $1" '
    $0 ~ want { found = 1; next }
    found && /^[[:space:]]*value:/ {
      sub(/^[[:space:]]*value:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print; exit
    }
    found && /^[[:space:]]*- name:/ { exit }   # ran past the entry: no value
  ' "$RENDER"
}

job_host=$(first_env_value JOB_IMAGE_HOST)
[ -n "$job_host" ] || { echo "list-images: JOB_IMAGE_HOST is absent from the render, so the training-image host is UNKNOWN." >&2; exit 1; }

ing_repo=$(first_env_value INGESTOR_IMAGE_REPOSITORY)
ing_tag=$(first_env_value INGESTOR_IMAGE_TAG)
ing_digest=$(first_env_value INGESTOR_IMAGE_DIGEST)
[ -n "$ing_repo" ] || { echo "list-images: INGESTOR_IMAGE_REPOSITORY is absent from the render." >&2; exit 1; }

# ---------------------------------------------------------------------------
# The training-image TAG comes from the render, not from a default.
#
# Bugbot, High, and correct: the first version defaulted --env to prod and
# stamped that onto the task images while every other line in the output came
# from the render. A values file selecting `stg` therefore produced `:prod` task
# images beside `:stg` control-plane images -- the operator mirrors the wrong
# training set and the first non-prod experiment ImagePullBackOffs. That is the
# exact failure this tool exists to prevent, reintroduced by the one value that
# was not derived (rule 1).
#
# CLIENT_ENV is what jobs-manager stamps as the tag, so it is the authority.
# --env stays as an explicit override for enumerating a DIFFERENT environment
# than the values describe, but a disagreement is reported rather than silently
# resolved: a mismatch is far more likely a mistake than an intention.
# ---------------------------------------------------------------------------
rendered_env=$(first_env_value CLIENT_ENV)

if [ -z "$ENV_TAG" ]; then
  if [ -z "$rendered_env" ]; then
    echo "list-images: CLIENT_ENV is absent from the render, so the training-image tag is UNKNOWN." >&2
    echo "  Refusing to guess: a wrong tag mirrors the wrong training set, which is the" >&2
    echo "  failure this tool exists to prevent. Pass --env prod|stg|dev to state it." >&2
    exit 1
  fi
  ENV_TAG="$rendered_env"
elif [ -n "$rendered_env" ] && [ "$rendered_env" != "$ENV_TAG" ]; then
  echo "list-images: --env says '$ENV_TAG' but the render's CLIENT_ENV says '$rendered_env'." >&2
  echo "  Those produce different training images. Drop --env to follow the values" >&2
  echo "  (the usual case), or fix the values if '$ENV_TAG' is what you meant." >&2
  exit 2
fi

case "$ENV_TAG" in
  prod|stg|dev) ;;
  *) echo "list-images: resolved environment '$ENV_TAG' is not one of prod|stg|dev." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 2. The run-time-spawned training images.
#
# The task list lives in NEITHER the chart nor this repo -- jobs-manager builds
# `tracebloc/client-<task>-<arch>` from the experiment's category. The registry's
# own repository list is therefore the authority available here, and it is the
# right one for mirroring: what is PUBLISHED is what can be copied. (A host that
# cannot reach the registry cannot mirror from it either, so needing registry
# access for this step is not an extra constraint.)
# ---------------------------------------------------------------------------
# The registry namespace the task repositories live under. It is the SAME value
# used to query the repository list below, so the printed path and the
# enumeration cannot disagree about it. jobs-manager builds
# `tracebloc/client-<task>-<arch>` (client-runtime/jobs_manager.py:292) and
# prefixes JOB_IMAGE_HOST, so the full path is <host><namespace>/<repo>:<env>.
# The first version dropped the namespace and printed
# `docker.io/client-<task>-cpu`, which does not exist.
REGISTRY_NAMESPACE="${TRACEBLOC_REGISTRY_NAMESPACE:-tracebloc}"
task_repos=""

if [ -n "${TRACEBLOC_TASK_REPOS:-}" ]; then
  task_repos=$(printf '%s\n' "$TRACEBLOC_TASK_REPOS" | tr ' ' '\n' | sed '/^$/d' | sort -u)
else
  command -v curl >/dev/null 2>&1 || { echo "list-images: curl is required to enumerate task images (or set TRACEBLOC_TASK_REPOS)" >&2; exit 1; }
  # Preflighted rather than discovered mid-loop: an absent interpreter used to be
  # indistinguishable from "the registry returned no more pages".
  command -v python3 >/dev/null 2>&1 || { echo "list-images: python3 is required to parse the registry response (or set TRACEBLOC_TASK_REPOS)" >&2; exit 1; }
  page_n=1
  # Overridable so the fail-closed path below is TESTABLE, and so a site with a
  # private mirror of the repository list can point at it. Without a knob here the
  # refusal could only be reasoned about, never exercised -- and an unexercised
  # guard is indistinguishable from one that does not work (rule 5). Note that
  # common.sh prepends the system PATH, so stubbing `curl` is not an option.
  page="${TRACEBLOC_REGISTRY_URL:-https://hub.docker.com/v2/repositories/${REGISTRY_NAMESPACE}/?page_size=100}"
  while [ -n "$page" ]; do
    body=$(curl_secure -fsS "$page" 2>/dev/null) || {
      echo "list-images: could not read the registry repository list, so the training-image set is UNKNOWN." >&2
      echo "  Refusing to print a list that omits them (backend#2633). Set TRACEBLOC_TASK_REPOS to override." >&2
      exit 1
    }
    # FAILS CLOSED (rule 3). Bugbot, High, and correct: the first version wrote
    # `2>/dev/null || echo ""` and `|| true` here, and never preflighted python3.
    # A missing interpreter, a truncated body, or a later page that failed to
    # parse all read as "no more names" -- so after ONE successful page the
    # script printed a PARTIAL training list and exited 0. A partial list is
    # worse than no list: it looks complete and mirrors the wrong set.
    #
    # One interpreter call now emits the next-page URL and the names together,
    # so a parse failure cannot half-succeed, and its exit status is checked.
    parsed=$(printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("next") or "")
for r in d.get("results", []):
    print(r["name"])
' 2>/dev/null) || {
      echo "list-images: could not parse the registry response for page ${page_n}, so the" >&2
      echo "  training-image set is INCOMPLETE and therefore UNKNOWN. Refusing to print a" >&2
      echo "  partial list -- that is exactly the failure backend#2633 is about." >&2
      echo "  Set TRACEBLOC_TASK_REPOS to bypass the registry entirely." >&2
      # The interpreter's own traceback is suppressed in favour of this: the
      # first bytes of what actually came back are the useful diagnostic (an
      # HTML error page, a rate-limit notice, an empty body). Suppressing
      # STDERR is safe precisely because the EXIT STATUS is checked -- the
      # original defect was `|| echo ""`, which discarded the status.
      printf '  first 200 bytes of the response: %s\n' "$(printf '%s' "${body:0:200}")" >&2
      exit 1
    }
    page="${parsed%%$'\n'*}"
    names="${parsed#*$'\n'}"
    [ "$names" = "$parsed" ] && names=""   # single-line response: no names at all
    task_repos=$(printf '%s\n%s\n' "$task_repos" "$names" | sed '/^$/d' | grep -E '^client-' | sort -u || true)
    page_n=$((page_n + 1))
    if [ "$page_n" -gt 50 ]; then
      echo "list-images: registry pagination did not terminate after 50 pages. Refusing to" >&2
      echo "  loop forever or to print whatever was collected so far." >&2
      exit 1
    fi
  done
fi

if [ -z "$task_repos" ]; then
  echo "list-images: enumerated ZERO training-image repositories." >&2
  echo "  That is not a plausible answer for this product, and an empty section" >&2
  echo "  here is precisely the failure backend#2633 is about. Refusing." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Output.
# ---------------------------------------------------------------------------
n_chart=$(printf '%s\n' "$chart_images" | sed '/^$/d' | wc -l | tr -d ' ')
n_task=$(printf '%s\n' "$task_repos" | sed '/^$/d' | wc -l | tr -d ' ')

echo "# Complete pull set for this install (chart + run-time-spawned)."
echo "# Copy each into your mirror under the SAME repository path and tag/digest."
echo "#"
echo "# ${n_chart} chart image(s), ${n_task} training image(s), 1 ingestor."
echo "# Training images and the ingestor are spawned by jobs-manager at run time"
echo "# and are invisible to \`helm template\` -- that is why this script exists."
echo
echo "# --- rendered by the chart ---"
printf '%s\n' "$chart_images"
echo
echo "# --- spawned at run time: ingestor ---"
if [ -n "$ing_digest" ]; then
  echo "${ing_repo}@${ing_digest}"
else
  echo "${ing_repo}:${ing_tag}"
fi
echo
echo "# --- spawned at run time: training images (tag :${ENV_TAG}) ---"
printf '%s\n' "$task_repos" | while IFS= read -r r; do
  [ -n "$r" ] && echo "${job_host}${REGISTRY_NAMESPACE}/${r}:${ENV_TAG}"
done
