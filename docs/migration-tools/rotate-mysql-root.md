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

1. **`rotateMysqlRoot` is on for this fleet**, deployed, so the release Secret
   carries a `MYSQL_ROOT_PASSWORD` key. Confirm:
   ```bash
   kubectl -n <ns> get secret <release>-secrets -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | wc -c   # non-zero
   ```
   If it is zero, enable the gate first — `rotateMysqlRootByEnv` defaults to
   `false` for dev/stg/prod. On an unrotated fleet the mysql-client container has
   **no `env:` block at all**, so an empty read there is the correct "gate off"
   signal, not a broken query. `--set` persists across the fleet's hourly
   auto-upgrade, which uses `--reset-then-reuse-values`
   (`templates/auto-upgrade-cronjob.yaml`) and re-applies user-supplied values
   after resetting to chart defaults. This rolls the mysql pod once, so do it in
   a window. It does **not** rotate root — it only generates the new value.
   ```bash
   helm repo add tracebloc https://tracebloc.github.io/client && helm repo update tracebloc
   helm upgrade <release> tracebloc/client --version <chart> -n <ns> \
     --reset-then-reuse-values --set rotateMysqlRoot=true
   ```
   **If that fails with `apiservices … is forbidden`, it is not a real failure.**
   `resource-monitor-daemonset.yaml` preflights metrics-server via `lookup` on
   cluster-scoped `apiservices`, which Kubernetes' built-in `admin` ClusterRole
   excludes — so an operator whose EKS access entry is `AmazonEKSAdminPolicy`
   (namespace-scoped admin) **cannot render this chart at all**, for any change,
   related or not. That is **backend#2469**, and the escape hatch is its fix:
   ```bash
   helm upgrade ... --set rotateMysqlRoot=true --set nodeAgents.metricsServerPreflight=false
   ```
   Add that flag **only** after actually hitting the forbidden error — an
   operator with cluster scope should keep the check. It **persists** by the same
   `--reset-then-reuse-values` mechanism, so it quietly becomes a standing fleet
   setting; the render records
   `tracebloc.io/metrics-server-preflight: "skipped-by-values"` so a skipped
   check cannot be mistaken for a passed one. Restore it when the rotation is done.
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

- The **prod** leg needs `pods/exec` on the release namespace — not everyone's
  token has it. Whoever runs it needs the access checked in precondition 0.
- After all fleets are rotated, the `Dockerfile.mysql_client` ENV can drop the
  baked literal on the next image rebuild (gated on the client#454 freeze); the
  runtime override makes fresh installs correct in the meantime.
