#!/usr/bin/env bash
#
#  gpu-limit-semantics-documented.sh — the GPU keys' docs must not disagree
#  about what a limit does (backend#2657).
#
#  THE DEFECT. `GPU_LIMITS: nvidia.com/gpu=1` reads as "one GPU per training
#  pod". On the CDI path it is not: injection happens OUTSIDE the Kubernetes
#  resource limit, so the limit never reaches the container runtime as a device
#  restriction and the pod sees every GPU on the machine. The installer's WSL2
#  path sets `nvidia.com/gpu=all`, so that is the DEFAULT there.
#
#  The schema already explained the CDI path -- under `GPU_VISIBLE_DEVICES`, and
#  only there. `GPU_LIMITS` and `GPU_REQUESTS` read as unconditional. Same key,
#  two meanings, and the document that should have said so said it in the wrong
#  entry.
#
#  IT ALREADY PRODUCED A WRONG CONCLUSION, which is why this is a check and not a
#  style note: RFC-2610 OQ7 inferred "every pod sees one GPU, so DeepSpeed never
#  initialises, so the ~3 GB cudnn-devel base is free to drop" from `GPU_LIMITS`
#  alone. False on any multi-GPU Windows/WSL2 edge, where DeepSpeed already
#  initialises -- the saving would have broken those edges the day it shipped
#  (backend#2639).
#
#  WHAT IS CHECKED, and why it is conditional rather than a fixed string match.
#  The requirement is AGREEMENT between entries, so the trigger is derived from
#  the document itself: IF `GPU_VISIBLE_DEVICES` documents a CDI path, THEN
#  `GPU_LIMITS` and `GPU_REQUESTS` must say that the limit bounds scheduling and
#  not visibility. Drop the CDI path from the product and this check retires
#  itself instead of demanding prose about a mechanism that no longer exists.
#
#  FAILS CLOSED (rule 3): a missing schema, an unparseable one, or a missing key
#  is a FAILURE. "We could not read the descriptions" must never pass as "they
#  agree" -- zero compared pairs compare equal to zero compared pairs.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCHEMA="$ROOT/client/values.schema.json"

[ -r "$SCHEMA" ] || { echo "FAIL: $SCHEMA unreadable -- cannot tell, which is a finding" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required to read the schema" >&2; exit 1; }

python3 - "$SCHEMA" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        schema = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"FAIL: {path} is not readable JSON ({exc})", file=sys.stderr)
    sys.exit(1)

try:
    env = schema["properties"]["env"]["properties"]
except (KeyError, TypeError) as exc:
    print(f"FAIL: no properties.env.properties in the schema ({exc})", file=sys.stderr)
    sys.exit(1)

REQUIRED = ("GPU_LIMITS", "GPU_REQUESTS", "GPU_VISIBLE_DEVICES")
missing = [k for k in REQUIRED if k not in env]
if missing:
    print(
        f"FAIL: the schema no longer declares {missing}. If a GPU key was renamed, "
        "this check must be renamed with it rather than left comparing keys that "
        "are gone.",
        file=sys.stderr,
    )
    sys.exit(1)


def desc(key: str) -> str:
    value = env[key].get("description")
    if not isinstance(value, str) or not value.strip():
        print(
            f"FAIL: {key} has no description. An undocumented GPU key is exactly "
            "how the limit came to read as an isolation guarantee.",
            file=sys.stderr,
        )
        sys.exit(1)
    return value


visible = desc("GPU_VISIBLE_DEVICES")

# THE TRIGGER IS DERIVED. Only demand the scheduling/visibility note while the
# document itself still describes a CDI injection path.
cdi_documented = "CDI" in visible
if not cdi_documented:
    print(
        "gpu-limit-semantics: GPU_VISIBLE_DEVICES no longer documents a CDI path, "
        "so the scheduling-vs-visibility note is not required. Nothing to check."
    )
    sys.exit(0)

problems = []
for key in ("GPU_LIMITS", "GPU_REQUESTS"):
    text = desc(key)
    # Two claims, both needed: that the limit bounds SCHEDULING, and that it does
    # NOT bound visibility. Either alone still reads as an isolation guarantee.
    if "SCHEDULING" not in text.upper():
        problems.append(
            f"{key} does not say that it bounds SCHEDULING, while "
            "GPU_VISIBLE_DEVICES documents a CDI path where it bounds nothing else"
        )
    if "visibility" not in text.lower():
        problems.append(
            f"{key} does not mention visibility, so a reader cannot tell that on "
            "a CDI node the pod sees every GPU regardless of this value"
        )
    if "GPU_VISIBLE_DEVICES" not in text:
        problems.append(
            f"{key} does not point at GPU_VISIBLE_DEVICES, so the reader has no "
            "way to find the key that actually controls visibility"
        )

if problems:
    print("FAIL: the GPU keys' documentation disagrees about what a limit does:", file=sys.stderr)
    for p in problems:
        print(f"  [x] {p}", file=sys.stderr)
    print(
        "\n  backend#2657: GPU_LIMITS bounds scheduling; on the CDI path visibility "
        "is set by GPU_VISIBLE_DEVICES. Both keys must say so, or the value reads "
        "as an isolation guarantee it is not -- which has already produced a wrong "
        "conclusion once (RFC-2610 OQ7).",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    "gpu-limit-semantics: OK -- GPU_VISIBLE_DEVICES documents CDI, and both "
    "GPU_LIMITS and GPU_REQUESTS state that they bound scheduling rather than "
    "visibility."
)
PY
