#!/usr/bin/env bash
#
#  jobs-manager-waits-for-mysql.sh — jobs-manager must not race MySQL (backend#2913).
#
#  WHY THIS EXISTS. jobs-manager opens its database connection during
#  initialisation and EXITS when it fails, so a MySQL a few seconds behind it
#  crashlooped the container on a real run:
#
#    2003 (HY000): Can't connect to MySQL server on 'mysql-client:3306' (111)
#    Warning  BackOff  Back-off restarting failed container api
#
#  Errno 111 is connection refused. The pod then RECOVERS on its own, so by the
#  time anyone looks it is healthy and the reason survives only in the previous
#  container's log — which is why this was first mistaken for backend#2492.
#
#  RENDERED, NOT GREPPED FROM THE TEMPLATE. The bug this guards against is not
#  "the text is missing"; it is "the container does not RUN". `initContainers:`
#  opened inside `if .Values.hostPath.enabled`, so a template-text search would
#  have found the block while an edge without hostPath rendered no init
#  containers at all. Both values are rendered below for exactly that reason.
set -euo pipefail

cd "$(dirname "$0")/../.."

BASE=(--set clientId=x --set clientPassword=y --set storageClass.create=false)
fail=0

for hp in false true; do
  out=$(helm template t client "${BASE[@]}" --set hostPath.enabled="$hp")

  # The first initContainer of the jobs-manager Deployment, read out of the
  # RENDERED manifest.
  first=$(printf '%s' "$out" | python3 -c '
import sys, re
for doc in sys.stdin.read().split("\n---\n"):
    if "kind: Deployment" in doc and "jobs-manager" in doc and "initContainers:" in doc:
        names = re.findall(r"^      - name: ([\w-]+)", doc, re.M)
        print(names[0] if names else "")
        break
else:
    print("NO-DEPLOYMENT")
')

  if [ "$first" != "wait-for-mysql" ]; then
    echo "FAIL hostPath.enabled=$hp: first initContainer is '${first:-<none>}', want 'wait-for-mysql'."
    echo "     jobs-manager exits on its first failed DB connection, so without this it crashloops"
    echo "     whenever MySQL is a few seconds behind it."
    fail=1
  else
    echo "OK   hostPath.enabled=$hp: wait-for-mysql runs first"
  fi

  # BOUNDED. An unbounded wait converts a crashloop into a pod that hangs in
  # Init forever — quieter, and strictly worse.
  # A `case` RATHER THAN `grep -q`, and the reason is worth writing down: under
  # `set -o pipefail`, `printf '%s' "$out" | grep -q PATTERN` reports FAILURE on a
  # SUCCESSFUL match. `grep -q` exits the moment it matches, `printf` is killed by
  # SIGPIPE (141), and pipefail returns that. The check then fails exactly when the
  # thing it looks for is present — which is how it first appeared here.
  case "$out" in
    *'wait-for-mysql: FAIL mysql-client:3306 never accepted'*) ;;
    *)
      echo "FAIL hostPath.enabled=$hp: the wait has no expiry message, so it is either unbounded"
      echo "     or fails without saying what it waited for."
      fail=1 ;;
  esac
done

# ── No container may pin a UID on the arbitrary-UID path (Bugbot High, #942) ──
#
# OpenShift's `restricted` SCC assigns a uid from the project range, and this pod
# is built for that: its pod-level comment says "OpenShift arbitrary-UID", and
# neither `api` nor `pods-monitor-container` pins one. A SINGLE container pinned
# to a literal uid fails SCC admission for the WHOLE pod -- so `wait-for-mysql`
# with `runAsUser: 1000` would have turned a startup race into jobs-manager
# staying Pending forever on one of the four supported platforms.
#
# RENDERED WITH hostPath OFF, which is what makes this checkable at all:
# `init-writable-data` legitimately needs `runAsUser: 0` to chown a hostPath
# volume, and it renders only when that path is in use. Off, every remaining
# container is one that must accept an assigned uid.
out=$(helm template t client "${BASE[@]}" --set hostPath.enabled=false)
pinned=$(printf '%s' "$out" | python3 -c '
import sys, re
for doc in sys.stdin.read().split("\n---\n"):
    if "kind: Deployment" in doc and "jobs-manager" in doc:
        print("\n".join(re.findall(r"^\s*runAsUser: .*$", doc, re.M)))
        break
')
if [ -n "$pinned" ]; then
  echo "FAIL a jobs-manager container pins a uid on the arbitrary-UID path:"
  printf '     %s\n' "$pinned"
  echo "     One pinned container fails OpenShift SCC admission for the whole pod."
  fail=1
else
  echo "OK   no jobs-manager container pins a uid when hostPath is off"
fi

exit "$fail"
