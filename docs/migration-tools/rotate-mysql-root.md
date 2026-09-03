# Rotate the mysql-client root password (backend#947 · backend#1528 Phase 0)

Operational runbook for rotating a live edge's MySQL `root` password off the
image-baked literal, once the `rotateMysqlRoot` chart gate (client#822) is
enabled on that fleet.

## Why a runbook and not just the chart

The chart (`rotateMysqlRoot: true`) generates a random root password into the
release Secret (`MYSQL_ROOT_PASSWORD` key) and injects it as
`MYSQL_ROOT_PASSWORD` on the mysql-client deployment. But the mysql entrypoint
reads that env **only at fresh-datadir init** — every live edge has an existing
datadir, so its live `root` password stays the baked literal until the one-time
`ALTER USER` below aligns it to the generated Secret value. The chart cannot run
that DDL itself: it would have to authenticate as `root` with the *current*
literal (re-introducing it) or hit a chicken/egg once rotated.

Because that step is manual and mandatory, from chart `1.9.89` the chart no
longer lets the flip render as a bare flag on an existing fleet (backend#2879):
enabling `rotateMysqlRoot` where a MySQL datadir already exists **fails the
render**, naming this runbook, unless you pass
`mysqlRootRotationAcknowledged=true` to acknowledge you will run the `ALTER USER`
below. So the gate and this migration are coupled in the chart now, not only in
prose — a fresh install on a live cluster is still born rotated with no operator
action.

The chart sees "a datadir already exists" by looking the `mysql-pvc`
PersistentVolumeClaim up **in the live cluster**. Under any **cluster-less**
renderer — ArgoCD's default (non–server-side) render, Flux post-render,
`helm template`, `--dry-run=client` — that look-up returns nothing, so the chart
cannot tell whether a datadir exists. Rather than mint blindly, the guard **fails
closed** there (backend#2892, chart `1.9.90`): a cluster-less render on the mint
path **refuses**, naming this runbook. So a GitOps fleet that flips the gate on
gets a loud render failure, not a silent 1045 — but it also means you must set the
rotation up deliberately. If this fleet is GitOps-managed — **including a `dev`
fleet, which ships rotation on by default** — do the
[pre-flight for GitOps-managed fleets](#pre-flight-for-gitops-managed-fleets)
below **before** you enable the gate.

## Pre-flight for GitOps-managed fleets

Read this before enabling `rotateMysqlRoot` if this fleet is rendered by ArgoCD
(default, non–server-side), Flux, or any pipeline that renders without a live
cluster — **including a `dev` fleet**, which defaults rotation on. On such a
render the chart cannot see the cluster, so on the mint path it **fails closed**
(backend#2892): it refuses rather than mint a password it can neither confirm safe
nor preserve. Two consequences:

- You will **not** get a silent 1045 — you get a render failure naming this
  runbook. That is the guard working.
- A cluster-less mint can never converge anyway: the chart preserves a generated
  `MYSQL_ROOT_PASSWORD` across upgrades with a live `lookup` of the Secret
  (tier 2), which is empty cluster-less — the same limit the chart documents for
  `clientId`/`clientPassword` — so a bare mint re-randomises every render. To
  actually rotate you must give root's value a cluster-less-stable source.

Pick one:

- **B — render server-side (recommended).** ArgoCD server-side render
  (`argocd-repo-server` against the live cluster), or any renderer with cluster
  access. The chart then sees the datadir and preserves the value, exactly as a
  live `helm upgrade` does — no extra value needed. Choose it if **every** render
  of the fleet is server-side.
- **A — pin the root password.** Set `mysqlRootPassword` to a fixed alphanumeric
  value in the fleet's overlay (tier 1 — deterministic across renders, and it
  bypasses the mint guard). Run the `ALTER USER` below to that value. This is how
  you rotate a fleet you cannot render server-side.

`mysqlDatadirExists` is **not** how you rotate. It is a narrow explicit assertion
(chart `>= 1.9.90`) for a **live** render whose datadir PVC the `lookup` cannot
see, and to make a cluster-less refusal name the existing-datadir migration
specifically instead of the generic message. It does not converge a rotation —
pin or go server-side for that.

Once you have a stable-value path **and** have run the `ALTER USER`,
`mysqlRootRotationAcknowledged=true` lets the render through. On a cluster-less
fleet it does **not** self-expire (tier 2 is empty every render, so it would stay
set and permanently disarm the guard — see `values.yaml`), which is the other
reason to prefer the pin or server-side path. Everything below then applies; a
GitOps fleet commits these values to its overlay instead of running the
`helm upgrade` shown.

## Pre-flight every step with `--dry-run=server`, never plain `--dry-run`

On this chart a client-side dry-run **fabricates every generated secret**. Helm's
`lookup` returns nil without a cluster, so the chart's preserve-existing branch is
skipped and a fresh value is rendered each time.

The practical consequence, measured on the prod run: two consecutive
`--dry-run` renders produced **different** `POD_TOKEN_SIGNING_SECRET` values,
which reads as "this upgrade rotates the pod token signing secret on prod". It
does not. Under `--dry-run=server` the value matched the LIVE Secret exactly and
was stable across renders.

Use `--dry-run=server` for every pre-flight in this runbook. A client-side
dry-run here does not just omit information — it invents a change that is not
going to happen, and the correct reaction to that invented change is to stop.

## Capture `CURPW` BEFORE you flip the gate (backend#2991)

**Do this first, in the window, before the `helm upgrade` in Preconditions 1.**

The rotation needs the fleet's CURRENT root password. Two facts make it
unavailable later, and neither is obvious until you are stuck:

* the value lives **only** in the mysql-client image's baked env, and the flip
  renders an `env:` block that OVERRIDES it — so the moment the mysql pod rolls,
  the running pod no longer knows the old password;
* "take it from the S0 snapshot" does not work if S0 was taken **correctly**. The
  S0 discipline for this migration is that a capture never prints a password
  (`prod-s0.sh` deliberately does not), so a correct S0 does not contain it.

Measured on the prod run (backend#2800): S0 was clean, the value was therefore
only in the pod, and the flip was ~4 minutes from overwriting it.

```bash
NS=<ns>
POD=$(kubectl -n "$NS" get pod -l app=mysql-client -o name | head -1); POD=${POD#pod/}
export CURPW=$(kubectl -n "$NS" exec "$POD" -c mysql-client -- printenv MYSQL_ROOT_PASSWORD)
echo "CURPW captured: ${#CURPW} chars, sha256 $(printf %s "$CURPW" | shasum -a 256 | cut -c1-12)"
```

Keep that shell open until the `ALTER USER` below has run. Record the fingerprint
(not the value) in the ticket, so the rotation can be verified later without ever
printing a secret.

**If you have already flipped and lost it:** the literal is recoverable from the
image config (`docker buildx imagetools inspect <mysql-client digest>`), which is
the same exposure backend#947 tracks — convenient here, alarming in general.

## Preconditions (per fleet, do in order)

0. **You can actually reach the fleet, with the permissions these steps need.**
   If the edge sits on a cluster whose API server is not reachable directly (a
   private endpoint behind a bastion/tunnel), both `kubectl` **and** `helm` must
   point at the tunnelled kubeconfig. Exporting it in one shell does not cover a
   `helm` command run in another: with a default `~/.kube/config` helm dials the
   private endpoint and fails after ~30s with
   `kubernetes cluster unreachable: … dial tcp …:443: i/o timeout`, which reads
   like a cluster outage but is only a missing `KUBECONFIG`.

   Then confirm the three permissions the rotation needs. Use the **per-verb**
   form: on EKS, `kubectl auth can-i --list` under-reports against access-entry
   RBAC and lists neither `secrets` nor `pods/exec` even when both are permitted,
   so `--list` will talk you out of a rotation you can actually perform.
   ```bash
   kubectl -n <ns> auth can-i list secrets     # -> yes
   kubectl -n <ns> auth can-i update secrets   # -> yes
   kubectl -n <ns> auth can-i create pods/exec # -> yes
   ```

1. **The edge is on chart `>= 1.9.71`, and `rotateMysqlRoot` is on for this
   fleet**, deployed, so the release Secret carries a `MYSQL_ROOT_PASSWORD` key.

   **Check the chart version before anything else in this step. Below `1.9.71`
   this runbook cannot work, and it fails silently.**
   ```bash
   helm -n <ns> list --filter '^<release>$' -o json | grep -o '"chart":"[^"]*"'   # -> client-1.9.71 or later
   ```
   `rotateMysqlRoot` did not exist before `client-1.9.71` (client#822), and the
   chart's `values.schema.json` does not close `additionalProperties` — so on an
   older chart `helm upgrade ... --set rotateMysqlRoot=true` is **accepted and
   exits 0** while rendering no `MYSQL_ROOT_PASSWORD` at all. Measured on
   `client-1.9.63`: exit 0, zero occurrences of the key. The Secret read below
   then returns zero, and the paragraph after it tells you to remedy that by
   enabling the gate — the step you just ran. There is no exit from that loop and
   nothing in it names the real cause, which is the chart version.

   If the edge is older, **upgrade the chart first, as its own change in its own
   window** — see `client/MIGRATION.md`, *Upgrading to 1.9.71*, for what that
   upgrade touches. Do not bundle it with the rotation: the two have different
   blast radii and different rollback stories.

   Then confirm the gate is live:
   ```bash
   kubectl -n <ns> get secret <release>-secrets -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | wc -c   # non-zero
   ```
   If it is zero **and the version check above passed**, enable the gate first.
   `rotateMysqlRootByEnv` is `true` for **dev** (baked under backend#1528 S3) and
   `false` for **stg** and **prod** — so a zero read on a dev fleet means
   something is wrong with the install rather than that the gate is simply off,
   while on stg/prod it is the expected default. On an unrotated fleet the mysql-client container has
   **no `env:` block at all**, so an empty read there is the correct "gate off"
   signal, not a broken query. `--set` persists across the fleet's hourly
   auto-upgrade, which uses `--reset-then-reuse-values`
   (`templates/auto-upgrade-cronjob.yaml`) and re-applies user-supplied values
   after resetting to chart defaults. This rolls the mysql pod once, so do it in
   a window. It does **not** rotate root — it only generates the new value.

   `mysqlRootRotationAcknowledged=true` is **required on an existing fleet** from
   chart `1.9.89` (backend#2879). Because this fleet already has a datadir, the
   chart would otherwise mint a root password the live database does not have and
   break auth, so it **refuses to render** `rotateMysqlRoot=true` here unless you
   acknowledge that you will run the `ALTER USER 'root'` step below in the same
   window. Without it the upgrade fails at template time with a message naming
   this runbook — by design, so the flip cannot land as a silent 1045. The flag
   is inert on a fresh install (no datadir yet → born rotated) and ignored by
   charts older than `1.9.89` (schema is open), so it is safe to pass
   unconditionally. On a **GitOps-managed** fleet, commit these values to the
   fleet's overlay instead of running this `helm upgrade`, and do the
   [pre-flight](#pre-flight-for-gitops-managed-fleets) first — cluster-less,
   `mysqlRootRotationAcknowledged=true` clears the guard but does not by itself
   give a converging rotation, so pin `mysqlRootPassword` (pre-flight path A) or
   render server-side (path B).
   ```bash
   helm repo add tracebloc https://tracebloc.github.io/client && helm repo update tracebloc
   helm upgrade <release> tracebloc/client --version <chart> -n <ns> \
     --reset-then-reuse-values \
     --set rotateMysqlRoot=true --set mysqlRootRotationAcknowledged=true
   ```
   **Let this upgrade FINISH before you act on its result.** While a `helm
   upgrade` runs, the release sits in `pending-upgrade` — and that is the same
   state a killed upgrade leaves behind. The hourly auto-upgrade CronJob no longer
   confuses the two (tracebloc/client#2877): it leaves a release that has only
   recently entered `pending-upgrade` untouched, and only reclaims one that has
   been stuck there past `autoUpgrade.pendingWedgeMinAge` (default 45m). So do the
   flip in a window and let it converge to `STATUS: deployed`; do **not** leave a
   half-finished manual upgrade parked in `pending-upgrade` for longer than that
   threshold, or the next tick will treat it as an abandoned wedge and roll it
   back (it logs a loud warning with the discarded revision when it does — read
   the CronJob Pod's log to recover the values). If you must hold a manual upgrade
   open longer, raise `pendingWedgeMinAge` or set `autoUpgrade.suspend=true` for
   the duration.

   **This upgrade needs an identity with cluster scope. Plain `admin` is not
   enough, and no combination of `--set` flags substitutes for it.** The chart
   templates seven cluster-scoped kinds — Namespace, PersistentVolume,
   StorageClass, PriorityClass, ClusterRole, ClusterRoleBinding and the OpenShift
   SecurityContextConstraints — and helm must at minimum *read* each one to diff
   a release. Kubernetes' built-in `admin` ClusterRole contains no cluster-scoped
   rules at all, so an operator holding only `admin` fails on the first such kind
   and then on the next. Two of those failures look like this:
   ```
   apiservices.apiregistration.k8s.io "v1beta1.metrics.k8s.io" is forbidden:
     User "..." cannot get resource "apiservices" ... at the cluster scope
   priorityclasses.scheduling.k8s.io "tracebloc-data-plane" is forbidden:
     User "..." cannot get resource "priorityclasses" ... at the cluster scope
   ```
   The first has a values-level opt-out (`nodeAgents.metricsServerPreflight=false`,
   the fix shipped for **backend#2469**) because it is only a template `lookup`.
   **Do not read that as a general escape hatch** — it clears exactly one wall of
   several, and the ClusterRole/ClusterRoleBinding the chart's own RBAC depends on
   have no opt-out at all. Chasing them with flags trades a blocked upgrade for
   permanent, unaudited config drift and still does not finish.

   In-cluster, the auto-upgrade CronJob's ServiceAccount holds a ClusterRole
   enumerating precisely those kinds (plus `escalate`/`bind`, without which
   Kubernetes' privilege-escalation prevention blocks re-applying the chart's own
   RBAC) — see `templates/auto-upgrade-rbac.yaml`. That is why the hourly upgrade
   succeeds where a human `admin` cannot. For a manual upgrade, use an identity
   with equivalent cluster scope (on EKS: `AmazonEKSClusterAdminPolicy`, not
   `AmazonEKSAdminPolicy`), and drop back afterwards.

   Note that on EKS an access-scope of `type=cluster` does **not** mean
   "cluster-scoped resources" — it means the policy applies across all
   namespaces. `AmazonEKSAdminPolicy` at `type=cluster` is still namespace-level
   admin everywhere, with zero access to the kinds above. The two readings are
   easy to confuse and the symptom is exactly the errors printed above.
2. **Every root consumer is ready to take the new value** (rotation breaks anything
   still using the literal). The known set (backend#947 inventory):
   - `migrate-tenant.sh` operators — `MYSQL_ROOT_PW` (tenant-config.env) → the Secret value.
   - client#785 re-parent — `bootstrapDbPassword` pin → the Secret value (when re-parent is enabled).
   - the backend#723 migration runbook — its root password → the Secret value.
   - any ad-hoc `mysql -uroot` use.
   None of these are code-hardcoded to the literal; all are operator-supplied, so
   "ready" means whoever runs them knows to read the Secret now.

## Rotate (per fleet: dev → stg → prod)

Run from a shell with `kubectl` access to the fleet. **No password ever touches a
process's argv** — not as `-p<value>` and not embedded in a `sh -c` string (both
show in the node's `ps`). Instead every secret travels only over the `exec` stdin
stream (encrypted): the auth password via a mode-600 `--defaults-extra-file`
written and deleted inside the pod, and the new password via `mysql`'s own stdin.

`NEWPW` is alphanumeric — the chart generates `randAlphaNum` and **enforces**
`[A-Za-z0-9]+` on any `mysqlRootPassword` pin precisely because it lands in the
`ALTER USER … IDENTIFIED BY '…'` below — so the single-quoted SQL is safe.

**Put this in a file and run the file; do not paste it.** It is a heredoc
containing two nested heredocs, and pasted into an interactive shell it may not
terminate — measured on the prod run, the shell sat at `>` and nothing executed.
That particular failure is safe, but a *partially* pasted rotation is not, and
you cannot tell which one you got from the prompt. Passwords still travel only
over the exec stdin stream when it runs from a file.

Two refusals worth keeping at the top of that file, beyond the `${var:?}` guards
below:

* abort if `CURPW` is not exported (you are in the wrong shell);
* abort if `CURPW == NEWPW` — the no-op case. Without it the rotation "succeeds",
  prints `rotation applied`, and changes nothing.

```bash
NS=<ns>; REL=<release>
POD=$(kubectl -n "$NS" get pod -l app=mysql-client -o name | head -1); POD=${POD#pod/}

# NEWPW = the value the chart generated (read from the Secret, never printed).
# CURPW = the fleet's CURRENT root password (baked literal on an unrotated fleet,
#         from the S0 snapshot / secret manager). Export both; never commit them.
NEWPW=$(kubectl -n "$NS" get secret "$REL"-secrets -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)

# Refuse an empty password before we build any ALTER. An empty NEWPW (wrong
# NS/REL, or rotateMysqlRoot is not actually on so the Secret has no
# MYSQL_ROOT_PASSWORD key) would rotate root to an EMPTY password; an empty CURPW
# can't authenticate. `${var:?msg}` aborts THIS command with msg — safe to paste
# interactively, it won't exit your shell — the same fail-fast intent as
# migrate-tenant.sh's MYSQL_ROOT_PW guard.
: "${CURPW:?export CURPW — the fleet's current root password — before rotating}"
: "${NEWPW:?empty: check NS/REL and that rotateMysqlRoot is enabled on this fleet (the Secret must carry MYSQL_ROOT_PASSWORD); refusing to rotate root to an empty password}"

# `sh -s` reads the script from stdin; CURPW/NEWPW are expanded LOCALLY into that
# stdin stream, so they reach the pod over the exec channel — never in any argv.
kubectl -n "$NS" exec -i "$POD" -- sh -s <<SCRIPT
set -e                                    # a failed ALTER must abort, not report success
umask 077
trap 'rm -f /tmp/rot.cnf' EXIT            # always wipe the password file, even on failure
cat > /tmp/rot.cnf <<CNF
[client]
host=127.0.0.1
user=root
password=${CURPW}
CNF
mysql --defaults-extra-file=/tmp/rot.cnf <<SQL
ALTER USER 'root'@'%'         IDENTIFIED BY '${NEWPW}';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEWPW}';
FLUSH PRIVILEGES;
SQL
echo "rotation applied"
SCRIPT
```

`set -e` + the EXIT trap are load-bearing: without `set -e` a failed `ALTER`
would still exit 0 (the trailing cleanup succeeds), so `kubectl exec` reports
success while root silently stays on the old password and the Secret diverges.
A non-zero exit here means the rotation did **not** take — stop and investigate.

**Every `mysql` call connects over TCP (`host=127.0.0.1`), never the default unix
socket.** This image writes its socket to `/var/lib/mysql/mysql.sock`, not the
client default, so a socket connection can't reach a healthy `mysqld` — the same
reason the deployment probes are pinned to `-h 127.0.0.1`. TCP as `root` matches
`root@'%'`; make sure mysqld has finished restarting after the gate-on roll
before running these.

## Verify (all must hold before moving to the next fleet)

Same stdin / `--defaults-extra-file` / TCP discipline — no password in argv.

```bash
# 1. the OLD password no longer AUTHENTICATES. Distinguish a real rejection
#    (ERROR 1045, access denied) from a connection error (mysqld restarting,
#    wrong host): only 1045 proves rotation took. A bare "any failure = rejected"
#    check is fail-open — a 2003 would masquerade as success.
kubectl -n "$NS" exec -i "$POD" -- sh -s <<SCRIPT
umask 077
trap 'rm -f /tmp/v.cnf' EXIT
printf '[client]\nhost=127.0.0.1\nuser=root\npassword=%s\n' '${CURPW}' > /tmp/v.cnf
if err=\$(mysql --defaults-extra-file=/tmp/v.cnf -e 'SELECT 1' 2>&1); then
  echo 'FAIL: old password still authenticates — rotation did NOT take'; exit 1
fi
case "\$err" in
  *1045*) echo 'OK: old password rejected (access denied)';;
  *)      echo "INCONCLUSIVE: not a 1045 rejection — investigate: \$err"; exit 1;;
esac
SCRIPT

# 2. the NEW password does (expect: root@%). set -e so a failure here
#    (new pw doesn't work, or mysqld unreachable) exits non-zero, not "fine".
kubectl -n "$NS" exec -i "$POD" -- sh -s <<SCRIPT
set -e
umask 077
trap 'rm -f /tmp/v.cnf' EXIT
printf '[client]\nhost=127.0.0.1\nuser=root\npassword=%s\n' '${NEWPW}' > /tmp/v.cnf
mysql --defaults-extra-file=/tmp/v.cnf -e 'SELECT CURRENT_USER()'
SCRIPT

# 3. the platform is unaffected — heartbeat still sees the FULL dataset count,
#    ingestion/training/mint still green (the #1528 acceptance gate). Watch a
#    real experiment cycle, not just "no errors".
```

## Rollback

Re-run the `ALTER` with the two passwords swapped: authenticate with the
generated value (still in `<release>-secrets`) and set root back to `CURPW`.
Root rotation is reversible; unlike the eventual `DROP USER edgeuser`, nothing
here is one-way.

**The S0 snapshot is not a rollback source for the password.** `SHOW GRANTS`
emits privileges and account names only — no password and no password hash — so
a snapshot taken per the steps above cannot give `CURPW` back. Keep `CURPW`
yourself until the fleet is confirmed healthy; once the `ALTER` has run and
`CURPW` is lost, the only remaining path is a datadir-level root reset
(`--skip-grant-tables`), which is a different and much more disruptive
operation.

## Notes

### Before you enable `bootstrapDbReparent`, check root's LIVE password (backend#2991)

`scripts/tests/reparent-requires-rotation.sh` refuses the half-baked combination
`bootstrapDbReparent=true` with `rotateMysqlRoot=false` at review time. That is
the **gate pairing**, and it cannot know whether the `ALTER USER` above actually
ran on a given fleet.

If the gate is on but the DDL was skipped, `DB_BOOTSTRAP_PASSWORD` is the
generated value while root still holds the old one: jobs-manager authenticates as
root, gets `1045`, and CrashLoops. The chart's own guard protects the *rotation*
step from that shape; nothing protects the re-parent.

One command closes it — three values, no secrets printed, all three must agree:

```bash
# rendered by the chart
helm upgrade <rel> tracebloc/client --version <chart> -n <ns> \
  --reset-then-reuse-values --set bootstrapDbReparentByEnv.<env>=true --dry-run=server \
  | grep -E '^\s+(MYSQL_ROOT_PASSWORD|DB_BOOTSTRAP_PASSWORD):' \
  | sed -E 's/^\s+([A-Z_]+): *"?([A-Za-z0-9+/=]+)"?.*/\1/'   # names only; hash the values yourself

# what root actually authenticates with, live
kubectl -n <ns> exec <mysql-pod> -c mysql-client -- printenv MYSQL_ROOT_PASSWORD \
  | tr -d '\n' | shasum -a 256 | cut -c1-12
```

On the prod run all three were `94aab915ebf4`, which is why the re-parent came up
clean first time.

### Do not name migration artifacts after the strings your checks grep for

Probe datasets named `edgeuser_cycle_probe_*` produced **49** hits for
`grep -iE '1045|access denied|edgeuser'` on jobs-manager immediately after the
REVOKE — every one the token `edgeuser` inside Kubernetes JSON, none of them real.
`edgeuser-drop-readiness.sh` was not fooled (its pattern matches warning text, not
the bare token), but an operator's ad-hoc grep is, at exactly the moment they are
looking hardest for breakage. Name probes something orthogonal — `drop_gate_*`.


- The **prod** leg needs `pods/exec` on the release namespace — not everyone's
  token has it. Whoever runs it needs the access checked in precondition 0.
- After all fleets are rotated, the `Dockerfile.mysql_client` ENV can drop the
  baked literal on the next image rebuild (gated on the client#454 freeze); the
  runtime override makes fresh installs correct in the meantime.
