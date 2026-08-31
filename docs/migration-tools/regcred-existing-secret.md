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

   ```bash
   helm get values "$REL" -n "$NS" -a | grep -A6 '^dockerRegistry:' \
     || echo "no dockerRegistry block -> nothing to migrate"
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
helm get values "$REL" -n "$NS" -a > /tmp/$REL-values-before.yaml
python3 - <<'PY' > /tmp/$REL-values-new.yaml
import os, sys, yaml
v = yaml.safe_load(open(f"/tmp/{os.environ['REL']}-values-before.yaml"))
v["dockerRegistry"] = {"create": False, "existingSecret": os.environ["NEW"]}
yaml.safe_dump(v, sys.stdout, sort_keys=False)
PY
./docs/migration-tools/regcred-preflight.sh "$REL" "$NS" "$CHART" /tmp/$REL-values-new.yaml
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
for n in <each namespace from the preflight>; do
  kubectl -n "$n" get secret "${REL}-regcred" -o yaml \
    | python3 ./docs/migration-tools/regcred-copy.py "$NEW" \
    | kubectl -n "$n" apply -f -
done
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
can absorb an error into a reassuring answer. That is deliberate: earlier
versions of this procedure used `cmd 2>/dev/null || echo "fine"` and
`... | shasum`, which reported a confident conclusion for a failed read and a
plausible fingerprint (`e3b0c442…`, the hash of the empty string) for a Secret
that did not exist.

```bash
# 1. the credential is out of release values
helm get values "$REL" -n "$NS" -a | grep -A4 '^dockerRegistry:'
# expect exactly: create: false / existingSecret: <NEW>

# 2. nothing anywhere still carries it
helm get values "$REL" -n "$NS" -a | grep -ci "<the registry username>"
# expect: 0

# 3. the chart's Secret is gone and the operator's remains, in every namespace
for n in <each namespace from the preflight>; do
  for s in "${REL}-regcred" "$NEW"; do
    v=$(kubectl -n "$n" get secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null)
    if [ -z "$v" ]; then printf '%-26s %-26s ABSENT\n' "$n" "$s"
    else printf '%-26s %-26s %s\n' "$n" "$s" "$(printf %s "$v" | shasum -a 256 | cut -c1-16)"; fi
  done
done
# expect: "${REL}-regcred" ABSENT everywhere; "$NEW" present with matching hashes
```

### 4. Force a real pull — this is the only step that proves the credential works

Checks 1–3 all pass with a **broken** credential, because every running pod
already has its images.

```bash
kubectl -n "$NS" delete pod -l app.kubernetes.io/name=tracebloc --wait=false
kubectl -n "$NS" get pods -w      # Ctrl-C once Running
kubectl -n "$NS" get events --field-selector reason=Failed | grep -i "pull\|401\|429" || echo "no pull failures"
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
