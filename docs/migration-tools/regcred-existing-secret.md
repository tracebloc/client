# Move a fleet to `dockerRegistry.existingSecret` (backend#2571)

Operational runbook for taking a fleet's registry credential **out of its Helm
release values** and into an operator-owned Secret the chart only references.

Everything below was measured on a k3d rehearsal of `client-1.9.86` on
2026-08-31, including the two failure modes in *Why a runbook*. Where a step
says a thing happens, it was observed happening.

## Why a runbook and not just `--set dockerRegistry.existingSecret=...`

**1. `helm upgrade` cannot tell you the migration is half-done.** The chart
references the pull Secret from **two** namespaces — the release namespace and
`nodeAgents.namespace.name`, whose default is the fixed string
`tracebloc-node-agents`, *not* a release-scoped one. Copy the Secret into only
one of them and the upgrade reports:

```
STATUS: deployed
REVISION: 4
```

…while workloads in the missed namespace reference a Secret that is not there.
Nothing warns, at any layer. `regcred-preflight.sh` exists to make that a
refusal instead of a silent success.

**2. The chart's own Secret is DELETED, not orphaned.** On the migrating
upgrade, Helm removes `<release>-regcred` from **both** namespaces, because the
chart no longer renders it. So flipping the values *before* copying does not
leave a harmless leftover — it leaves the fleet with no pull Secret at all.
Copy first. Always.

**3. The obvious new name collides.** The chart's Secret is
`{{ .Release.Name }}-regcred` (`tracebloc.createdRegistrySecretName`). Our
releases are called `tracebloc`, so `tracebloc-regcred` is *the chart's own
name* — applying a copy over it rewrites the live Helm-managed Secret in place
and strips its ownership metadata, breaking the next upgrade. Use
`tracebloc-ops-regcred`.

`regcred-copy.py` **refuses** this rather than relying on you reading the
paragraph above — it compares the requested name against the source Secret's own
name, so the rule holds whatever the chart calls its Secret.

## Preconditions

0. **You can reach the fleet, with `helm` and `kubectl` both tunnelled.** Our
   EKS API endpoints are private (RFC1918), so a direct `helm`/`kubectl` fails
   after ~30s with `kubernetes cluster unreachable: … dial tcp …:443: i/o
   timeout` — which reads like an outage and is only a missing tunnel. See
   `rotate-mysql-root.md` preconditions and `backend/docs/platform/access/CLUSTER-ACCESS.md`.
   Exporting `KUBECONFIG` in one shell does not cover a command run in another.

   `helm upgrade` of this chart needs `AmazonEKSClusterAdminPolicy`, not plain
   `Admin` — the chart templates cluster-scoped kinds and helm must read each to
   diff the release.

1. **This fleet actually has a chart-created registry credential.** Do not
   assume it. Measured 2026-08-31: the dev fleet has **none** — no
   `dockerRegistry` key, no dockerconfigjson Secret, no `imagePullSecrets` — and
   never had one. For such a fleet this runbook is a no-op; stop here.

   Reads once and judges on the **exit status**, because piping a failed `helm`
   into `grep` is the fail-open shape this whole runbook is about: an empty
   stdin matches nothing, and "nothing" is this check's *stop, no work here*
   signal. A missing tunnel would tell you the fleet is already clean.

   ```bash
   ( set -euo pipefail
     vals="$(helm get values "$REL" -n "$NS" -a -o yaml 2>&1)" \
       || { echo "STOP: could not read the release -- this is NOT 'nothing to migrate'."; exit 1; }
     if printf '%s\n' "$vals" | grep -A6 '^dockerRegistry:'; then
       echo "^ this fleet HAS a registry credential in release values -- continue"
     else
       echo "no dockerRegistry block -> nothing to migrate on this fleet"
     fi
   )
   kubectl -n "$NS" get secrets --field-selector type=kubernetes.io/dockerconfigjson
   ```

2. **Identify the release explicitly.** `helm list -n "$NS" -q` may return
   several — the templates namespace also holds `ingestor` releases. Set it by
   name.

## The migration

```bash
# EXPORTED, not just set: the helper below reads them from the environment, and a
# plain assignment is not visible to a child process.
export NS=<release namespace>
export REL=<release name>
export NEW=tracebloc-ops-regcred          # must NOT be "${REL}-regcred"
export CHART=<the chart ref you already deploy>
```

### 1. Record what the upgrade will reference

```bash
# `-o yaml`, and NOT `-a`, and mode 0600. All three matter (Bugbot on client#916):
#
#   default output is `table`, which prefixes `COMPUTED VALUES:` -- that line parses
#     as a top-level key called "COMPUTED VALUES", and this file is fed straight to
#     `helm upgrade -f`. Measured on helm v4.1.1: `yaml.safe_load` returns
#     ['COMPUTED VALUES', 'foo', 'nested'].
#   `-a` dumps COMPUTED values, so every current chart default is frozen here as a
#     user-supplied value. A later auto-upgrade tick with
#     `--reset-then-reuse-values` would keep those frozen defaults instead of the
#     new chart's. A rollback snapshot wants what the OPERATOR set, nothing else.
#   `umask 077` because the next line writes the live registry password in
#     cleartext. Without it the file lands world-readable under the process umask,
#     in a predictable path, on a shared bastion -- which is the exposure this
#     whole migration exists to remove.
umask 077
# A SUBSHELL WITH `set -e`, SO "STOP" ACTUALLY STOPS. Printing STOP and carrying
# on is what the previous revision did: a failed snapshot said STOP, and the
# rewrite below then truncated the new values file and preflight ran on it
# anyway. A subshell is what makes this paste-safe -- `exit 1` leaves the
# subshell, never your terminal.
( set -euo pipefail
  # THE ROLLBACK IS THE ONE READ THAT MUST NOT FAIL SILENTLY. `>` creates the
  # file whether or not helm succeeds, so an unjudged read leaves an EMPTY
  # rollback -- found at the worst moment, having already migrated. Worse, an
  # empty file handed to `helm upgrade -f` sets every value to the chart default.
  helm get values "$REL" -n "$NS" -o yaml > "/tmp/$REL-values-before.yaml" \
    || { echo "STOP: could not read the release -- no rollback captured."; exit 1; }
  [ -s "/tmp/$REL-values-before.yaml" ] \
    || { echo "STOP: the rollback snapshot is EMPTY."; exit 1; }
  echo "rollback captured: $(wc -l < "/tmp/$REL-values-before.yaml") line(s)"

  python3 - > "/tmp/$REL-values-new.yaml" <<'PY' \
    || { echo "STOP: the values rewrite failed -- no PyYAML, or an unreadable snapshot."; exit 1; }
# SURGICAL TEXT EDIT, NOT A YAML ROUND-TRIP (Bugbot on client#916).
#
# safe_load + safe_dump re-encodes EVERY scalar in the file, and PyYAML and helm's
# Go YAML do not agree on one form. Measured with a chart that prints `kindOf`:
#
#   value in the snapshot   PyYAML dumps as   helm reads as
#   the string "1e5"        1e5  (UNQUOTED)   float64 => 100000
#
# PyYAML emits it bare because ITS loader needs a decimal point for a float, so
# the file round-trips inside python and changes meaning on the way into helm.
# Thirteen other ambiguous forms ('yes', 'true', '0755', '~', '0x1f', '.inf' …)
# were checked and PyYAML quotes all of them correctly -- so this is one narrow
# cross-parser disagreement, not a general re-encoding problem. But a
# clientPassword of `1e5` would reach the chart as the number 100000, and present
# as an unexplained auth failure in the middle of a credential migration.
#
# The fix is not to quote harder -- a denylist of ambiguous forms is the defect,
# not the fix. It is to STOP RE-ENCODING WHAT WE WERE NOT ASKED TO CHANGE. Only
# the dockerRegistry block is rewritten; every other byte is passed through
# untouched, and the script asserts that before printing anything.
import os, re, sys, yaml

src = open(f"/tmp/{os.environ['REL']}-values-before.yaml").read()
if not isinstance(yaml.safe_load(src), dict):
    sys.exit("the snapshot did not parse as a mapping -- refusing to build values from it")

block = "dockerRegistry:\n  create: false\n  existingSecret: %s\n" % os.environ["NEW"]
# A top-level key, its nested lines, and any blank lines between them.
pat = re.compile(r"^dockerRegistry:[^\n]*\n(?:(?:[ \t]+[^\n]*|[ \t]*)\n)*", re.M)
out, n = pat.subn(block, src)
if n == 0:
    out = src + ("" if src.endswith("\n") else "\n") + block
elif n > 1:
    sys.exit("found %d dockerRegistry blocks -- refusing to guess which to rewrite" % n)

# EVERY OTHER KEY MUST BE BYTE-IDENTICAL. This is the assertion the round-trip
# could not make: compare the two files with the dockerRegistry block removed
# from each, and refuse if a single byte elsewhere moved.
#
# DEFENCE IN DEPTH, stated as such. With the surgical edit above nothing else CAN
# change, so its own mutation in the verdicts suite comes back green -- the suite
# asserts the same property on the output, which a regex bug would fail first. It
# is kept because an operator runs this script directly: if the regex ever
# over-matches, they get a refusal instead of a values file that quietly lost a key.
if pat.sub("", src) != pat.sub("", out):
    sys.exit("the rewrite changed bytes outside dockerRegistry -- refusing")
check = yaml.safe_load(out)
if check.get("dockerRegistry") != {"create": False, "existingSecret": os.environ["NEW"]}:
    sys.exit("the rewritten dockerRegistry block does not read back as intended -- refusing")
sys.stdout.write(out)
PY
  # `>` truncated the target before python3 ran, so a failed rewrite leaves an
  # EMPTY file -- the exact input this runbook warns resets every value.
  [ -s "/tmp/$REL-values-new.yaml" ] \
    || { echo "STOP: the rewritten values file is EMPTY."; exit 1; }

  ./docs/migration-tools/regcred-preflight.sh "$REL" "$NS" "$CHART" "/tmp/$REL-values-new.yaml"
)
```

It will list every `(namespace, secret)` pair the upgrade would reference and
report `MISSING` for each — that is expected at this point, and **that list is
your copy list**. Do not hand-write it: an overridden `nodeAgents.namespace.name`
would make a hand-written list wrong.

`/tmp/$REL-values-before.yaml` is the rollback. It contains the credential in
plaintext — keep it off shared drives and delete it once the fleet is confirmed
good.

> `dockerRegistry.server/username/password/email` must be **removed**, not
> blanked, which is what rewriting the block above does. The schema says
> `if create == true then required [server, username, password, email]` and
> `if required[existingSecret] then create == false`, so a blanked block either
> keeps the credential in values or makes Helm reject the release at load.

### 2. Copy the Secret into every namespace the preflight listed

```bash
# `set -euo pipefail` and an explicit per-namespace check (Bugbot on client#916).
# This loop is the ONLY write of the credential. Without pipefail a failed
# `kubectl get`, a refusal from regcred-copy.py, or a failed `apply` in ONE
# namespace is discarded -- `for` continues, the step prints nothing, and a
# PARTIAL copy looks exactly like a finished one. The preflight in step 3 would
# catch it, but only if you run it; the copy step must not look successful when it
# was not.
# A SUBSHELL, like every other block here. A runbook is PASTED into the operator's
# shell: a top-level `set -e` would change their session for everything after it,
# and the `exit 1` below would CLOSE THEIR TERMINAL rather than stopping the step.
# Inside `( )` the exit leaves the subshell and nothing else.
( set -euo pipefail
for n in <each namespace from the preflight>; do
  if kubectl -n "$n" get secret "${REL}-regcred" -o yaml \
    | python3 ./docs/migration-tools/regcred-copy.py "$NEW" \
    | kubectl -n "$n" apply -f -
  then
    echo "copied into $n"
  else
    # `exit 1` on the SAME line as the STOP: the suite keys on that shape, because a
    # runbook is pasted and a STOP that prints without aborting is how the previous
    # two Highs on this PR happened.
    echo "STOP: the copy into $n FAILED -- the credential is now in some namespaces and not others." >&2; exit 1
  fi
done )
```

The credential is never decoded, printed, or retyped — `.data` passes through
byte for byte. Re-entering the PAT would put it in shell history and argv, which
is the exposure this migration removes.

### 3. Preflight again — it must say `safe:` before you go on

```bash
./docs/migration-tools/regcred-preflight.sh "$REL" "$NS" "$CHART" /tmp/$REL-values-new.yaml
```

Exit 0 and `safe: every referenced pull Secret exists…` is the gate. Exit 1
means a namespace is still missing. Exit 2 means it could not tell — treat that
as a stop, never as a pass.

### 4. Upgrade

```bash
helm upgrade "$REL" "$CHART" -n "$NS" -f /tmp/$REL-values-new.yaml --wait --timeout 10m
```

**No chart upgrade is required.** `existingSecret` and the schema exclusion are
present in the deployed line — keep your version pin and change only the values.
Doing both at once leaves you unable to say which caused a problem.

## Verify

Each check below either prints a value or says `ABSENT`/`FAILED` — none of them
can absorb an error into a reassuring answer. **Two of them did not honour that
until client#916's third round** (Bugbot): check 2's `grep -ci` counted zero
matches in the empty output of a *failed* `helm get values`, and check 3's
`2>/dev/null` mapped every kubectl error to the empty string, which it reported as
`ABSENT` — the success signal for the old Secret. An unreachable cluster printed a
clean bill of health for the entire table. Both now test the exit status first, and
distinguish `NotFound` from every other failure. That is deliberate: earlier
versions of this procedure used `cmd 2>/dev/null || echo "fine"` and
`... | shasum`, which reported a confident conclusion for a failed read and a
plausible fingerprint (`e3b0c442…`, the hash of the empty string) for a Secret
that did not exist.

```bash
# 1. the credential is out of release values -- READ ONCE, then judge. A failed
#    helm call would otherwise print nothing, and "no dockerRegistry block" is
#    indistinguishable from "the credential is gone", which is what this check
#    is looking for.
( set -euo pipefail
  dr="$(helm get values "$REL" -n "$NS" -a -o yaml 2>&1)" \
    || { echo "STOP: could not read the release -- this is NOT 'the credential is gone'."; exit 1; }
  printf '%s\n' "$dr" | grep -A4 '^dockerRegistry:' \
    || echo "no dockerRegistry block at all -- unexpected here, investigate"
)
# expect exactly: create: false / existingSecret: <NEW>

# 2. nothing anywhere still carries it -- READ ONCE, then judge (Bugbot on #916).
#    `helm get values | grep -ci <user>` printed 0 on a FAILED helm call, because
#    grep counts zero matches in empty stdin. An unreachable cluster read as
#    "credential gone", which is this check's success signal.
if vals=$(helm get values "$REL" -n "$NS" -a 2>&1); then
  printf 'occurrences of the registry username in release values: %s\n' \
    "$(printf '%s' "$vals" | grep -ci "<the registry username>")"   # expect 0
else
  printf 'FAILED to read release values -- this check is INCONCLUSIVE, not a pass\n%s\n' "$vals"
fi

# 3. the chart's Secret is gone and the operator's remains, in every namespace
for n in <each namespace from the preflight>; do
  for s in "${REL}-regcred" "$NEW"; do
    # EXIT STATUS FIRST, then emptiness (Bugbot on #916). `2>/dev/null` mapped every
    # kubectl error to the empty string, and empty was reported as ABSENT -- which is
    # the SUCCESS signal for "${REL}-regcred". An unreachable cluster printed a clean
    # bill of health for the whole table.
    if ! v=$(kubectl -n "$n" get secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' 2>&1); then
      case "$v" in
        *NotFound*) printf '%-26s %-26s ABSENT\n' "$n" "$s" ;;
        *)          printf '%-26s %-26s FAILED (%s)\n' "$n" "$s" "$(printf '%s' "$v" | head -1)" ;;
      esac
    elif [ -z "$v" ]; then
      printf '%-26s %-26s PRESENT-BUT-EMPTY\n' "$n" "$s"
    else
      printf '%-26s %-26s %s\n' "$n" "$s" "$(printf %s "$v" | shasum -a 256 | cut -c1-16)"
    fi
  done
done
# expect: "${REL}-regcred" ABSENT everywhere; "$NEW" present with matching hashes
```

### 4. Force a real pull — this is the only step that proves the credential works

Checks 1–3 all pass with a **broken** credential, because every running pod
already has its images.

The selector is `app.kubernetes.io/instance=$REL` on the **workloads**, and that
is not interchangeable with what the pods carry. The chart's pod templates are
labelled `app: manager`, `app: mysql-client`, `app: egress-proxy` and so on —
they carry **no** `app.kubernetes.io/*` identity at all, and the chart's
`app.kubernetes.io/name` is `client`, not `tracebloc`. A `delete pod -l
app.kubernetes.io/name=tracebloc` therefore matches nothing, deletes nothing,
and prints `No resources found` — after which the events check below reports a
clean pull for a restart that never happened.

```bash
( set -euo pipefail
  # DISCOVER FIRST, AND JUDGE THAT. `rollout restart` over a selector matching
  # nothing prints "No resources found" and exits 0, so testing ITS output for
  # emptiness never fires: the output is not empty, it is a sentence saying there
  # was nothing to do. `get -o name` writes matched objects to stdout and nothing
  # else, so an empty capture is a real empty match.
  targets="$(kubectl -n "$NS" get deploy,daemonset \
               -l "app.kubernetes.io/instance=$REL" -o name)"
  [ -n "$targets" ] \
    || { echo "STOP: the selector matched NO workloads -- nothing to restart, nothing pulled."; exit 1; }
  printf 'restarting:\n%s\n' "$targets"

  # Deliberate word-splitting: one argument per discovered object.
  # shellcheck disable=SC2086
  kubectl -n "$NS" rollout restart $targets \
    || { echo "STOP: rollout restart failed -- nothing was proved."; exit 1; }
  # ONE `rollout status` PER OBJECT, and the reason is robustness rather than a
  # bug being fixed. `kubectl rollout status` historically refused more than one
  # resource ("rollout status is only supported on individual resources and
  # resource collections", kubernetes#72216); that is FIXED in current kubectl --
  # measured on v1.37.0, where a Deployment and a DaemonSet passed together, a
  # multi-match `-l` selector, and a bare kind all succeed and exit 0. So the
  # multi-arg form is not broken on anything we ship against.
  #
  # The loop is kept anyway because it costs nothing and buys two things: it works
  # on an operator's older kubectl whatever its version, and a failure NAMES the
  # object that did not roll out instead of failing the whole set anonymously.
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    kubectl -n "$NS" rollout status "$obj" --timeout=5m \
      || { echo "STOP: $obj did not roll out -- look for ImagePullBackOff."; exit 1; }
  done <<ROLLOUT
$targets
ROLLOUT
  echo "restarted and rolled out: the images above were pulled fresh."
)
```

Then read the events **once** and judge on the exit status, not on an empty
pipeline — `grep` finding nothing in the output of a *failed* `kubectl` is
indistinguishable from `grep` finding nothing in a healthy cluster:

```bash
( set -euo pipefail
  ev="$(kubectl -n "$NS" get events --field-selector reason=Failed 2>&1)" \
    || { echo "STOP: could not read events -- this is NOT 'no pull failures'."; exit 1; }
  if printf '%s\n' "$ev" | grep -i -E "pull|401|429"; then
    echo "^ PULL FAILURES -- the credential did not work"
  else
    echo "no pull failures"
  fi
)
```

## Rollback

```bash
helm upgrade "$REL" "$CHART" -n "$NS" -f /tmp/$REL-values-before.yaml --wait
```

Verified on the rehearsal: the chart's Secret is recreated with the same
credential, workloads flip back, and the operator Secret survives inertly — leave
it in place, you will want it on the retry.

## What this does and does not achieve

It removes the credential from all **future** release revisions. It does **not**
clear what is already stored: every existing revision retains its values, and
`helm get values --revision N` still returns them. That is the history problem in
backend#2571, it needs revision pruning, and it is the reason the credential
should still be rotated afterwards.
