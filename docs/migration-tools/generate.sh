#!/usr/bin/env bash
# =============================================================================
#  generate.sh — produces per-tenant migration artifacts from a config file
#  containing real secrets + PV IDs.
#
#  Reads tenant-config.env (or whatever TENANT_CONFIG points at) and emits
#  values.yaml + pvcs.yaml + storageclass.yaml for every tenant in the file,
#  into /tmp/tracebloc-migration-<tenant>/.
#
#  The config file must NOT be committed — it has CLIENT_PASSWORD and
#  Docker Hub PAT in it. See tenant-config.example.env for the format.
# =============================================================================
set -euo pipefail

CONFIG="${TENANT_CONFIG:-$(dirname "$0")/tenant-config.env}"
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG — copy tenant-config.example.env, fill it in, retry" >&2; exit 2; }

# shellcheck disable=SC1090
source "$CONFIG"

: "${DOCKER_USERNAME:?must be set in $CONFIG}"
: "${DOCKER_PASSWORD:?must be set in $CONFIG}"
: "${DOCKER_EMAIL:?must be set in $CONFIG}"
: "${EFS_FS:?must be set in $CONFIG}"
: "${RESOURCE_REQUESTS:?must be set in $CONFIG}"
: "${RESOURCE_LIMITS:?must be set in $CONFIG}"
: "${TENANTS:?must be set in $CONFIG}"

# Pull the chart version + name from Chart.yaml so the pre-create PVCs ship
# with labels matching whatever release is about to be installed. Hardcoding
# `1.1.0` here (as the original drop did) silently drifts every time the
# chart bumps and confuses later debugging — Helm adoption keys on the
# release-name annotation so adoption itself works, but `kubectl get pvc -L
# helm.sh/chart` lies until the next upgrade reconciles labels.
CHART_YAML="${CHART_YAML:-$(dirname "$0")/../../client/Chart.yaml}"
[[ -f "$CHART_YAML" ]] || { echo "missing $CHART_YAML — set CHART_YAML or run from the repo" >&2; exit 2; }
CHART_NAME=$(awk -F': *' '$1=="name"{print $2; exit}' "$CHART_YAML")
CHART_VERSION=$(awk -F': *' '$1=="version"{print $2; exit}' "$CHART_YAML")
[[ -n "$CHART_NAME" && -n "$CHART_VERSION" ]] || { echo "could not parse chart name/version from $CHART_YAML" >&2; exit 2; }
echo "using chart ${CHART_NAME}-${CHART_VERSION} for label stamping"

# Globals that ship with __PLACEHOLDER__ values in the example config.
# Catch them once up front before per-row processing.
case "$DOCKER_PASSWORD" in
  *__*__*) echo "DOCKER_PASSWORD still contains placeholder __...__ — set the real Docker Hub PAT in $CONFIG" >&2; exit 2 ;;
esac

# Parse TENANTS line by line, ignoring comments + blank lines.
while IFS= read -r LINE; do
  LINE="${LINE# }"; LINE="${LINE% }"
  [[ -z "$LINE" || "$LINE" == \#* ]] && continue
  IFS='|' read -r TENANT RELEASE NS CLIENT_ID CLIENT_PASSWORD SC_NAME PV_MYSQL PV_LOGS PV_DATA <<<"$LINE"
  TENANT="$(echo "$TENANT" | xargs)"
  RELEASE="$(echo "$RELEASE" | xargs)"
  NS="$(echo "$NS" | xargs)"
  CLIENT_ID="$(echo "$CLIENT_ID" | xargs)"
  CLIENT_PASSWORD="$(echo "$CLIENT_PASSWORD" | xargs)"
  SC_NAME="$(echo "$SC_NAME" | xargs)"
  PV_MYSQL="$(echo "$PV_MYSQL" | xargs)"
  PV_LOGS="$(echo "$PV_LOGS" | xargs)"
  PV_DATA="$(echo "$PV_DATA" | xargs)"

  for v in TENANT RELEASE NS CLIENT_ID CLIENT_PASSWORD SC_NAME PV_MYSQL PV_LOGS PV_DATA; do
    [[ -n "${!v}" ]] || { echo "row missing $v: $LINE" >&2; exit 2; }
  done

  # Refuse to expand placeholders accidentally left in tenant-config.env.
  # Every per-row field that ships with __PLACEHOLDER__ markers gets checked
  # individually so the error message names the offending field. Without this
  # the literal __FOO__ ends up in values.yaml/pvcs.yaml and surfaces later
  # as an opaque kubectl apply / helm install failure.
  for v in CLIENT_ID CLIENT_PASSWORD SC_NAME PV_MYSQL PV_LOGS PV_DATA; do
    case "${!v}" in
      *__*__*) echo "row $TENANT field $v still contains placeholder __...__ — fill in real values in $CONFIG" >&2; exit 2 ;;
    esac
  done

  OUT=/tmp/tracebloc-migration-$TENANT
  mkdir -p "$OUT"

  cat > "$OUT/values.yaml" <<YAML
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by docs/migration-tools/generate.sh
# Tenant: $TENANT  |  release: $RELEASE  |  namespace: $NS
#
# Migrating $RELEASE in $NS from eks-1.0.x to client-1.x via Option C of
# docs/MIGRATIONS.md. mysql PVC is being renamed $TENANT-mysql-pvc -> mysql-pvc;
# client-pvc + client-logs-pvc names already match the new chart.
# StorageClass $SC_NAME is re-created from storageclass.yaml between
# uninstall and install.

env:
  CLIENT_ENV: prod
  RESOURCE_REQUESTS: "$RESOURCE_REQUESTS"
  RESOURCE_LIMITS: "$RESOURCE_LIMITS"
  GPU_REQUESTS: "nvidia.com/gpu=1"
  GPU_LIMITS: "nvidia.com/gpu=1"

clientId: "$CLIENT_ID"
clientPassword: "$CLIENT_PASSWORD"

storageClass:
  create: false
  name: $SC_NAME
  provisioner: efs.csi.aws.com
  reclaimPolicy: Retain
  volumeBindingMode: Immediate
  allowVolumeExpansion: true
  parameters:
    fileSystemId: $EFS_FS

pvc:
  data: 50Gi
  logs: 10Gi
  mysql: 2Gi

pvcAccessMode: ReadWriteMany

clusterScope: true

# Default false until you have verified the chart you're installing has
# release-scoped resource-monitor names (client-1.2.0+). Older charts
# collide on the literal tracebloc-resource-monitor SA name when more
# than one release shares a cluster. Flip to true on 1.2.0+.
resourceMonitor: false

nodeAgents:
  namespace:
    create: false
    name: tracebloc-node-agents

namespace:
  create: false

networkPolicy:
  training:
    enabled: false

dockerRegistry:
  create: true
  server: https://index.docker.io/v1/
  username: $DOCKER_USERNAME
  password: $DOCKER_PASSWORD
  email: $DOCKER_EMAIL

priorityClass:
  create: false
  name: tracebloc-data-plane
  value: 1000000

podDisruptionBudget:
  mysql:
    create: true
  jobsManager:
    create: true
YAML

  cat > "$OUT/storageclass.yaml" <<YAML
# Re-created after \`helm uninstall\` deletes the original. Identical to what
# the old eks-1.0.x release templated, so PVs that reference it by name
# continue to bind. Not Helm-owned — values.yaml uses storageClass.create:
# false so the new release references it externally.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $SC_NAME
provisioner: efs.csi.aws.com
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  fileSystemId: $EFS_FS
YAML

  cat > "$OUT/pvcs.yaml" <<YAML
# client-pvc and client-logs-pvc keep the same names they had in the old
# release. mysql-pvc is the rename: old PVC was $TENANT-mysql-pvc, new
# chart hardcodes mysql-pvc. Helm ownership stamp matches what
# \`helm template $RELEASE ./client\` would render, so the upcoming
# \`helm install\` adopts these instead of erroring "exists, not owned".
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: client-logs-pvc
  namespace: $NS
  labels:
    app.kubernetes.io/name: client
    app.kubernetes.io/instance: $RELEASE
    app.kubernetes.io/version: "$CHART_VERSION"
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: $CHART_NAME-$CHART_VERSION
  annotations:
    helm.sh/resource-policy: keep
    meta.helm.sh/release-name: $RELEASE
    meta.helm.sh/release-namespace: $NS
spec:
  storageClassName: $SC_NAME
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Gi
  volumeName: $PV_LOGS
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: client-pvc
  namespace: $NS
  labels:
    app.kubernetes.io/name: client
    app.kubernetes.io/instance: $RELEASE
    app.kubernetes.io/version: "$CHART_VERSION"
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: $CHART_NAME-$CHART_VERSION
  annotations:
    helm.sh/resource-policy: keep
    meta.helm.sh/release-name: $RELEASE
    meta.helm.sh/release-namespace: $NS
spec:
  storageClassName: $SC_NAME
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 50Gi
  volumeName: $PV_DATA
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc           # was $TENANT-mysql-pvc in the old release
  namespace: $NS
  labels:
    app.kubernetes.io/name: client
    app.kubernetes.io/instance: $RELEASE
    app.kubernetes.io/version: "$CHART_VERSION"
    app.kubernetes.io/managed-by: Helm
    helm.sh/chart: $CHART_NAME-$CHART_VERSION
  annotations:
    helm.sh/resource-policy: keep
    meta.helm.sh/release-name: $RELEASE
    meta.helm.sh/release-namespace: $NS
spec:
  storageClassName: $SC_NAME
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 2Gi
  volumeName: $PV_MYSQL
YAML

  echo "generated $OUT/{values,storageclass,pvcs}.yaml"
done <<<"$TENANTS"
