#!/usr/bin/env bash
#
#  collector-redaction-floor.sh — the Collector's redaction actually redacts the
#  secrets it claims to, proven by feeding it specimens (backend#1908).
#
#  WHY THIS EXISTS. The secret patterns live in THREE independent copies and
#  nothing derives from anything:
#
#    1. `client-runtime/controller.py`'s `_LOG_REDACTIONS` — the stated source.
#    2. `templates/telemetry-collector-configmap.yaml`'s OTTL `replace_pattern`
#       calls — a hand port of (1).
#    3. `tests/telemetry_collector_test.yaml`'s "carries all six of
#       controller.py's secret patterns" — six hand-written FRAGMENTS of (2).
#
#  (3) is the one that misleads: its title asserts agreement with controller.py,
#  and the mechanism cannot see controller.py at all. It greps the rendered
#  config for six substrings it holds itself, so it agrees with itself and
#  reports that as agreement with a file in another repository. Add a seventh
#  redaction to controller.py and every one of those assertions stays green while
#  the Collector ships the secret it does not know about. That is backend#1729
#  rule 1 exactly, and rule 9's corollary: a list checked against itself is blind.
#
#  WHY IT MATTERS MORE THAN IT LOOKS. Today the Collector carries Class A only —
#  containers this chart owns. backend#1908 opens Class B, which is TRAINING AND
#  INGESTION output: customer cell values and customer credentials. The redaction
#  floor is the whole thing standing between that and central storage. A floor
#  asserted by a check that cannot fail is not a floor.
#
#  WHAT THIS DOES INSTEAD. It never compares pattern TEXT. It parses the
#  `replace_pattern` regexes out of the RENDERED config — derived, so a pattern
#  added or removed in the template is seen — and applies them to SPECIMENS: real
#  secret-shaped strings written down independently of the matcher. The question
#  asked is behavioural: "would this line leave the cluster with the secret still
#  in it?" That is testable without knowing how anyone chose to spell the regex,
#  and it is what rule 6 means by deriving the input domain from the requirement
#  rather than from the implementation.
#
#  Plus a COUNT FLOOR, because specimens alone cannot see a removal that another
#  pattern happens to mask: a broadened pattern could swallow a specimen while
#  the specific protection it replaced quietly disappears.
#
#  FAILS CLOSED. A config that cannot be rendered or parsed, or zero patterns
#  found, is a finding — never "nothing to check, therefore fine".
#
#  WHAT IT STILL CANNOT SEE, stated rather than implied: copy (1). `controller.py`
#  lives in `client-runtime` and CI checks out only this repository, so a seventh
#  redaction added there is invisible here until someone adds its specimen below.
#  Closing that needs one declaration both repos consume — filed separately. This
#  guard shrinks the gap from "three copies, no checks" to "one cross-repo copy,
#  with the behavioural floor pinned on this side".
#  EVERY SECRET IN THIS FILE IS SYNTHETIC. A guard that proves redaction works
#  has to contain secret-SHAPED strings, and gitleaks cannot tell a specimen
#  from a leak — this path is allowlisted in `.gitleaks.toml`, which states the
#  cost of that. None of these values exists anywhere.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
CHART=client

command -v helm >/dev/null 2>&1 || { echo "[SKIP] helm not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 required" >&2; exit 1; }

echo "== collector redaction floor =="

CHK="$(mktemp -t redaction-floor.XXXXXX)"
trap 'rm -f "$CHK"' EXIT
cat >"$CHK" <<'PY'
import re
import sys

import yaml

# The floor, as BEHAVIOUR. Each specimen is a line that must not leave a cluster
# with its secret intact, written independently of any pattern that catches it —
# if these were derived from the regexes they would agree with them by
# construction and prove nothing (backend#1729 rule 9).
#
# `secret` is the substring that must be gone afterwards. Adding a row here is
# how a NEW class of secret gets a floor; adding one that nothing catches is the
# intended way to discover that the Collector's patterns lag controller.py's.
SPECIMENS = [
    ("proxy credentials in a URL",
     "ERROR connecting to https://svc-account:hunter2@proxy.corp.example:3128/",
     "hunter2"),
    ("Azure ServiceBus shared access key",
     "Endpoint=sb://x.servicebus.windows.net/;SharedAccessKeyName=send;SharedAccessKey=aB3xQ9vZ0kLmNp2R=;EntityPath=q",
     "aB3xQ9vZ0kLmNp2R="),
    ("storage account key",
     "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5;EndpointSuffix=core",
     "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5"),
    ("authorization header",
     "authorization: Basic dXNlcjpwYXNzd29yZA==",
     "dXNlcjpwYXNzd29yZA=="),
    ("api-key header",
     "x-api-key: 8f14e45fceea167a5a36dedd4bea2543",
     "8f14e45fceea167a5a36dedd4bea2543"),
    ("bearer credential",
     "Retrying with Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
    ("DRF token",
     'headers={"X-Auth": "Token 9c8b7a6d5e4f3a2b1c0d9e8f"}',
     "9c8b7a6d5e4f3a2b1c0d9e8f"),
    # THE ENVIRONMENT-VARIABLE SHAPES. Every one of these leaked before this
    # guard existed: the generic pattern anchored its keyword with `\\b` on both
    # sides, and `_` is a word character, so a prefix or suffix removed the
    # boundary and the whole assignment fell out. These are not hypothetical
    # spellings — backend#2069 deliberately logs WHICH `AZURE_*` variable is
    # unset when edge-device provisioning fails.
    ("client_secret as an env var",
     "AZURE_CLIENT_SECRET=Qz~8Kd0-vN9pLr2sTuVw",
     "Qz~8Kd0-vN9pLr2sTuVw"),
    ("password as an env var",
     "MYSQL_PASSWORD=hunter2-not-real",
     "hunter2-not-real"),
    ("secret with a suffix",
     "DJANGO_SECRET_KEY=abc123def456",
     "abc123def456"),
    ("aws secret access key",
     "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
     "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"),
    ("quoted secret value",
     "SECRET_KEY='x9y8z7w6v5'",
     "x9y8z7w6v5"),
    ("password assignment",
     "psql: FATAL password=s3cr3t-p4ss for user tracebloc",
     "s3cr3t-p4ss"),
    ("aws access key id",
     "botocore.exceptions: credential AKIAIOSFODNN7EXAMPLE rejected",
     "AKIAIOSFODNN7EXAMPLE"),
]

# The count floor. Raise it deliberately when a pattern is added; a DROP is what
# this number exists to catch, including the drop that another pattern masks.
MIN_PATTERNS = 6

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs
       if d.get("kind") == "ConfigMap" and "telemetry-collector" in d["metadata"]["name"]]
if len(cms) != 1:
    sys.exit(f"[ERROR] expected exactly one Collector ConfigMap, found {len(cms)} "
             "— cannot check what cannot be located")

cfg = yaml.safe_load(cms[0]["data"]["config.yaml"])
tr = (cfg.get("processors") or {}).get("transform/redaction")
if not tr:
    sys.exit("[ERROR] the rendered config has no `transform/redaction` processor, so "
             "nothing scrubs a captured log before it is exported")

# Derived: the regexes come out of the config, never from a list held here.
statements = []
for block in tr.get("log_statements") or []:
    statements.extend(block.get("statements") or [])

pattern_re = re.compile(r'replace_pattern\(\s*body\s*,\s*"((?:[^"\\]|\\.)*)"')
patterns = []
for st in statements:
    m = pattern_re.search(st)
    if not m:
        continue
    # TWO levels of escaping, and getting this wrong silently weakens the guard
    # rather than breaking it. YAML plain scalars do NOT process backslashes, so
    # what the YAML parser hands back still contains the OTTL string literal's
    # own escaping: `\\s` for `\s`, `\"` for `"`. OTTL resolves that when it
    # parses the statement; this must do the same before compiling.
    #
    # The failure mode when it is skipped is instructive: `[^:/@\\s]` compiles
    # happily as "not colon, slash, at, BACKSLASH or s", which still matches
    # plenty — so the patterns look alive while quietly refusing every specimen
    # containing an `s`. Eight of ten specimens "leaked" on the first run here,
    # all of them this bug and none of them real.
    raw = m.group(1)
    patterns.append(raw.replace('\\\\', '\\').replace('\\"', '"'))

if not patterns:
    sys.exit("[ERROR] no `replace_pattern(body, ...)` statements found in the "
             "redaction processor — zero patterns parsed is a broken guard, not a "
             "clean bill of health")

if len(patterns) < MIN_PATTERNS:
    sys.exit(f"[ERROR] the redaction floor dropped: {len(patterns)} pattern(s) in the "
             f"rendered config, floor is {MIN_PATTERNS}. A pattern was removed or "
             "merged away. If that was deliberate, lower MIN_PATTERNS in the same "
             "change and say which protection went with it.")

compiled = []
for p in patterns:
    try:
        # OTTL runs Go RE2; python `re` is a close enough superset for the
        # constructs these patterns use (inline (?i)/(?im) flags, \b, classes).
        # A pattern python cannot compile is reported rather than skipped —
        # silently dropping one would weaken the floor invisibly.
        compiled.append((p, re.compile(p)))
    except re.error as e:
        sys.exit(f"[ERROR] a redaction pattern does not compile here, so this guard "
                 f"cannot say whether it protects anything: {p!r} ({e})")

# THE OTHER DIRECTION. Redaction that eats the traceback is not a win: Class B
# exists so an ingestion failure is DIAGNOSABLE at full fidelity. A pattern
# widened to catch more secrets can quietly start swallowing the diagnosis, and
# nothing here would have noticed. These lines must come through untouched.
DIAGNOSIS = [
    "experiment=e0qaz0zi cycle=3 epoch=7",
    "status: COMPLETED",
    "Traceback (most recent call last):",
    "connection refused to 10.0.0.5:5432",
    "level=ERROR msg=training failed",
    "epoch=3 loss=0.412 accuracy=0.88",
    # The key NAME is not a secret and controller.py keeps it on purpose — its
    # own comment says so, and `test_scrubs_servicebus_key_but_keeps_key_name`
    # pins it. Added here because an earlier draft of the widened pattern DID
    # eat it and this guard said green: the specimen list was the gap, not the
    # mechanism. The secret half of the same line is covered above.
    "Endpoint=sb://x/;SharedAccessKeyName=RootManageSharedAccessKey;EntityPath=q",
]

uncovered = []
for label, line, secret in SPECIMENS:
    scrubbed = line
    for _, rx in compiled:
        # Replacement text is irrelevant to the question asked: what matters is
        # that the secret does not survive. Substituting a marker is enough and
        # avoids porting Go's $1 replacement syntax.
        scrubbed = rx.sub("***", scrubbed)
    if secret in scrubbed:
        uncovered.append((label, line, secret))

for label, _, _ in SPECIMENS:
    if label not in [u[0] for u in uncovered]:
        print(f"   ok    {label}")

damaged = []
for line in DIAGNOSIS:
    scrubbed = line
    for _, rx in compiled:
        scrubbed = rx.sub("***", scrubbed)
    if scrubbed != line:
        damaged.append((line, scrubbed))

if damaged:
    print("\n[ERROR] redaction is eating diagnosis, which is what Class B exists "
          "to preserve:", file=sys.stderr)
    for line, scrubbed in damaged:
        print(f"          {line!r}", file=sys.stderr)
        print(f"       -> {scrubbed!r}", file=sys.stderr)

if uncovered:
    print("\n[ERROR] these secrets survive the Collector's redaction and would be "
          "exported verbatim:", file=sys.stderr)
    for label, line, secret in uncovered:
        print(f"          {label}: {secret!r}", file=sys.stderr)
        print(f"            in: {line}", file=sys.stderr)

if uncovered or damaged:
    sys.exit(1)

print(f"  ok: all {len(SPECIMENS)} secret specimen(s) scrubbed and all "
       f"{len(DIAGNOSIS)} diagnosis line(s) preserved, by the {len(patterns)} "
       "pattern(s) the config actually carries")
PY

helm template t "$CHART" \
  --set clientId=x --set clientPassword=y \
  --set storageClass.create=false \
  --set telemetryCollector.enabled=true 2>/dev/null | python3 "$CHK"

echo "collector redaction floor: green"
