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

1. **client#822 is released and `rotateMysqlRoot` is on for this fleet**, deployed,
   so the release Secret carries a `MYSQL_ROOT_PASSWORD` key. Confirm:
   ```bash
   kubectl -n <ns> get secret <release>-secrets -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | wc -c   # non-zero
   ```
2. **Every root consumer is ready to take the new value** (rotation breaks anything
   still using the literal). The known set (backend#947 inventory):
   - `migrate-tenant.sh` operators — `MYSQL_ROOT_PW` (tenant-config.env) → the Secret value.
   - client#785 re-parent — `bootstrapDbPassword` pin → the Secret value (when re-parent is enabled).
   - the backend#723 migration runbook — its root password → the Secret value.
   - any ad-hoc `mysql -uroot` use.
   None of these are code-hardcoded to the literal; all are operator-supplied, so
   "ready" means whoever runs them knows to read the Secret now.

## Rotate (per fleet: dev → stg → prod)

Run from a shell with `kubectl` access to the fleet. Do **not** pass the password
as `-p<value>` (it shows in `ps`); use `MYSQL_PWD` and read the target from the
Secret so the literal is never typed.

```bash
NS=<ns>; REL=<release>; POD=$(kubectl -n "$NS" get pod -l app=mysql-client -o name | head -1)

# The new password the chart generated (never printed):
NEWPW=$(kubectl -n "$NS" get secret "$REL"-secrets -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)

# Align the live account to it. Authenticate as root@localhost over the socket
# with the CURRENT password (MYSQL_PWD), set the new one for both hosts:
kubectl -n "$NS" exec -i "${POD#pod/}" -- sh -c \
  'MYSQL_PWD="$CURPW" mysql -uroot -N <<SQL
ALTER USER "root"@"%"         IDENTIFIED BY "'"$NEWPW"'";
ALTER USER "root"@"localhost" IDENTIFIED BY "'"$NEWPW"'";
FLUSH PRIVILEGES;
SQL' CURPW="$CURPW"
```

(`CURPW` = the fleet's current root password — the baked literal on an unrotated
fleet, from the S0 snapshot / secret manager, exported in your shell, never
committed.)

## Verify (all must hold before moving to the next fleet)

```bash
# 1. the OLD password no longer authenticates (expect: ERROR 1045 Access denied)
kubectl -n "$NS" exec "${POD#pod/}" -- sh -c 'MYSQL_PWD="$CURPW" mysql -uroot -e "SELECT 1"' CURPW="$CURPW" ; echo "exit=$?"

# 2. the NEW password does
kubectl -n "$NS" exec "${POD#pod/}" -- sh -c 'MYSQL_PWD="$NEWPW" mysql -uroot -e "SELECT CURRENT_USER()"' NEWPW="$NEWPW"

# 3. the platform is unaffected — heartbeat still sees the FULL dataset count,
#    ingestion/training/mint still green (the #1528 acceptance gate). Watch a
#    real experiment cycle, not just "no errors".
```

## Rollback

Re-run the `ALTER` with the previous password (you have it as `CURPW`, and the
S0 snapshot records it). Root rotation is reversible; unlike the eventual
`DROP USER edgeuser`, nothing here is one-way.

## Notes

- **prod** (`tracebloc-templates-prod`) needs `pods/exec` on that namespace — not
  everyone's token has it. Whoever runs the prod leg needs that access.
- After all fleets are rotated, the `Dockerfile.mysql_client` ENV can drop the
  baked literal on the next image rebuild (gated on the client#454 freeze); the
  runtime override makes fresh installs correct in the meantime.
