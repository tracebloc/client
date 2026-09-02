#!/usr/bin/env python3
# mysql-auth-probe.py — the real-driver MySQL auth probe for the backend#723
# native-8.4 e2e (scripts/tests/e2e-mysql.sh). Runs as an in-cluster Job using
# the SAME driver the tracebloc clients use (mysql-connector-python), because
# the Deployment's only health probe is `mysqladmin ping`, which passes
# regardless of the account's auth plugin — so it cannot catch the ERROR 2061
# regression this test exists for.
#
# What it proves (backend#723, decision D2):
#   * a COLD-CACHE first connect as edgeuser over plaintext (ssl_disabled=True),
#     with NO explicit auth_plugin — exactly how the clients connect — SUCCEEDS.
#     Under 8.4's default caching_sha2_password this throws on the cold cache
#     (the ERROR 2061 class); mysql_native_password (baked by the image, D2)
#     makes it succeed. The caller runs this probe a SECOND time after a
#     `rollout restart` (strategy: Recreate wipes the server-side cache) to
#     cover the recurring-failure case.
#   * the information_schema enumeration sql_utils.py depends on runs.
#   * max_allowed_packet is the chart ConfigMap's 256M (not the 8.4 default of
#     64M), and a multi-MB LONGBLOB actually round-trips through the driver.
#
# Env: MYSQL_HOST/USER/PASSWORD/DATABASE (all defaulted to the baked contract).
# Exit 0 + "AUTH-PROBE-PASS" on success; non-zero with a reason otherwise.
import os
import sys

import mysql.connector

HOST = os.environ.get("MYSQL_HOST", "mysql-client")
USER = os.environ.get("MYSQL_USER", "edgeuser")
PW = os.environ.get("MYSQL_PASSWORD", "Edg9@Tr@ce")
DB = os.environ.get("MYSQL_DATABASE", "training_test_datasets")
EXPECT_MAJOR = os.environ.get("MYSQL_EXPECT_MAJOR", "8.4")
EXPECT_PACKET = int(os.environ.get("MYSQL_EXPECT_PACKET", str(256 * 1024 * 1024)))
BLOB_BYTES = int(os.environ.get("MYSQL_BLOB_BYTES", str(16 * 1024 * 1024)))


def main() -> int:
    # Cold cache: this pod has never connected before, and ssl_disabled forces
    # the plaintext path that caching_sha2 cannot satisfy without RSA/TLS.
    conn = mysql.connector.connect(
        host=HOST, user=USER, password=PW, database=DB, ssl_disabled=True
    )
    cur = conn.cursor()

    cur.execute("SELECT 1")
    if cur.fetchone()[0] != 1:
        print("FAIL: SELECT 1 did not return 1", file=sys.stderr)
        return 1

    cur.execute("SELECT VERSION()")
    version = cur.fetchone()[0]
    if not str(version).startswith(EXPECT_MAJOR):
        print(f"FAIL: server version {version} is not {EXPECT_MAJOR}.x", file=sys.stderr)
        return 1

    # The enumeration sql_utils.py runs against the dataset schema.
    cur.execute(
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=%s", (DB,)
    )
    table_count = cur.fetchone()[0]

    # max_allowed_packet must be the chart ConfigMap's value, not the 8.4 default
    # — otherwise a real dataset blob would be truncated/rejected at write time.
    cur.execute("SELECT @@max_allowed_packet")
    packet = int(cur.fetchone()[0])
    if packet != EXPECT_PACKET:
        print(
            f"FAIL: max_allowed_packet={packet}, expected {EXPECT_PACKET} "
            "(the mysql-client-config ConfigMap is not in effect)",
            file=sys.stderr,
        )
        return 1

    # A real multi-MB LONGBLOB round-trip through the driver.
    cur.execute("CREATE TEMPORARY TABLE tb_blob_probe (id INT, payload LONGBLOB)")
    payload = b"\xa5" * BLOB_BYTES
    cur.execute("INSERT INTO tb_blob_probe VALUES (1, %s)", (payload,))
    cur.execute("SELECT payload FROM tb_blob_probe WHERE id=1")
    got = cur.fetchone()[0]
    if len(got) != BLOB_BYTES or bytes(got) != payload:
        print(
            f"FAIL: LONGBLOB round-trip mismatch (got {len(got)} of {BLOB_BYTES} bytes)",
            file=sys.stderr,
        )
        return 1

    cur.close()
    conn.close()
    print(
        f"[ok] cold-cache plaintext connect as {USER}; version={version}; "
        f"information_schema tables in {DB}={table_count}; "
        f"max_allowed_packet={packet}; LONGBLOB {BLOB_BYTES} bytes round-tripped"
    )
    print("AUTH-PROBE-PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
