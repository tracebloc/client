{{- define "imagePullSecret" }}
{{- with .Values.dockerRegistry }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .server .username .password .email (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}

{{- define "tracebloc.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "tracebloc.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
  tracebloc.fullname — the prefix every resource name this chart creates is built
  from. backend#2626.

  DEFAULTS TO `.Release.Name` VERBATIM, and verbatim is load-bearing: no `trunc`,
  no `trimSuffix`, no normalisation. Those are defensible in a fresh chart and
  wrong here, because the whole migration-safety argument is that an UNSET
  override renders byte-identical to the chart before this existed. A `trunc 63`
  firing only for release names over 63 characters is a behaviour change hiding
  behind a default nobody exercises until it breaks an install.

  WHAT MAY USE IT is not a style question -- backend#2621 was reverted over
  exactly this. The release name appears ~174 times across these templates and is
  at least six different things:

    MAY follow the override -- names of resources THIS CHART CREATES, and
    anything referencing one of those names (an env naming a Deployment to
    restart; a log glob matching pod directories, because pod directories are
    named after the DaemonSet).

    MUST NOT follow it:
      * `app.kubernetes.io/instance`     Helm convention: it IS the release
      * `meta.helm.sh/release-name`      Helm's own ownership bookkeeping
      * `RELEASE_NAME` / `RELEASE` env   a HELM IDENTITY -- `helm status`,
                                         `helm rollback`. Rename it and
                                         auto-upgrade hunts a release that does
                                         not exist and fails every tick: that is
                                         backend#2620, re-introduced by the fix
                                         for backend#2621.
      * on-disk paths                    a LOCATION, not a name. Renaming
                                         orphans a tenant's data.
      * `.Release.Namespace`             unrelated

  `scripts/tests/fullname-override-completeness.sh` keeps that table true: it
  renders with a distinctive override and fails on any resource name still
  carrying the release name, and in the same pass on any exception that STOPPED
  carrying it. Both halves are required -- without the second, the guard is
  satisfied by breaking auto-upgrade.
*/}}
{{- define "tracebloc.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride -}}
{{- end -}}

{{- define "tracebloc.secretName" -}}
{{ include "tracebloc.fullname" . }}-secrets
{{- end }}

{{/*
  tracebloc.sealCheckLabels — the seal-check enumeration contract
  (RFC-0003 §8.2 / backend#1184; consumed by the tracebloc CLI, cli#393).

  Every runnable conformance check in this chart is a `helm.sh/hook: test` Job
  carrying these two labels, so tooling can enumerate the suite without
  hardcoding job names:

    tracebloc.io/seal-check: "true"        — membership marker
    tracebloc.io/seal-check-name: <check>  — stable per-check identifier

  Current check names: egress-enforcement, backend-reachability,
  storage-assertions.

  Enumerate without running anything:   helm get hooks <release>
  While a `helm test` run is live:      kubectl get jobs,pods -n <ns> \
                                          -l tracebloc.io/seal-check=true

  CONTRACT RULES — the label keys and existing check names are public API:
  never rename them; add new checks under new names. Apply this helper to the
  hook Job metadata AND its pod template (pod-level lets the CLI stream logs by
  label). Do NOT apply it to auxiliary hook resources (ServiceAccounts, RBAC) —
  only runnable checks are enumerable. See docs/SEAL-CHECK.md.

  Usage:
    {{- include "tracebloc.sealCheckLabels" (dict "name" "storage-assertions") | nindent 4 }}
*/}}
{{- define "tracebloc.sealCheckLabels" -}}
tracebloc.io/seal-check: "true"
tracebloc.io/seal-check-name: {{ .name | quote }}
{{- end }}

{{/*
  tracebloc.sealTimeout — the per-check seal budget annotation.

  Every runnable seal check (every `helm test` hook Job or Pod) declares, in
  whole seconds, the longest a healthy run of it may take end to end:
  scheduling, image pull, the check itself. The tracebloc CLI runs each check
  with `helm test --timeout` = max(its own --timeout, this value), so the CLI's
  budget can never be smaller than the chart's own declared worst case.

  The argument is the check's budget as an EXPRESSION derived from the bounds
  the check's own script uses (the storage check passes the same value its
  activeDeadlineSeconds reads) — never a number typed a second time.
  scripts/tests/seal-timeout-declared.sh fails any runnable test hook that
  renders without it.

  Usage:
    {{- include "tracebloc.sealTimeout" $budget | nindent 4 }}
*/}}
{{- define "tracebloc.sealTimeout" -}}
"tracebloc.io/seal-timeout": {{ int . | toString | quote }}
{{- end }}

{{- define "tracebloc.serviceAccountName" -}}
{{ include "tracebloc.fullname" . }}-jobs-manager
{{- end }}

{{/*
  Name of the shared ServiceAccount the parent chart creates for ingestor
  subchart releases. Single source of truth — used by:
    - templates/ingestor-serviceaccount.yaml (creates the SA)
    - templates/ingestion-authz-configmap.yaml (default authz entry)
  The ingestor subchart's post-install hook runs as this SA; jobs-manager
  validates its token via TokenReview against `ingestionAuthz.allowed`.
  Nil-guarded: pre-#129 stored values from `--reuse-values` upgrades won't
  have `ingestionAuthz.serviceAccountName`, so default to "ingestor".
*/}}
{{- define "tracebloc.ingestorServiceAccountName" -}}
{{- (default dict .Values.ingestionAuthz).serviceAccountName | default "ingestor" -}}
{{- end }}

{{/*
  Release-scoped name for the resource-monitor DaemonSet, ServiceAccount,
  ClusterRoleBinding subject, and selector/pod labels. Multiple releases
  on the same cluster share the tracebloc-node-agents namespace; before
  this naming, two releases collided on the literal `tracebloc-resource-monitor`
  name and Helm refused the second install with "exists, not owned".
  See the v1.2.0 release notes / tenant-d-prod migration case study.
*/}}
{{- define "tracebloc.resourceMonitorName" -}}
{{ include "tracebloc.fullname" . }}-resource-monitor
{{- end }}

{{/*
  tracebloc.resourceMonitorEnabled — the SINGLE reader of "is the resource-monitor
  on", coalescing the two value shapes during the RFC-0076 alias window
  (remove_by: 2026-12-31, client#1009):

    legacy scalar   resourceMonitor: <bool>
    new object      resourceMonitor.enabled: <bool>   (D2: <component>.enabled)

  This is a bool→object rename, so a stored values.yaml or a bare
  `--set resourceMonitor=true` still arrives as a SCALAR. Reading
  `.Values.resourceMonitor.enabled` blindly would `fail` with "can't evaluate
  field enabled in interface {}" on the scalar and, on a `--reuse-values`
  upgrade that carries the scalar forward, silently drop the setting. So decide
  the shape with kindIs and prefer the new `.enabled` form:

    map     -> .enabled, defaulting to true when the key is absent
    bool    -> the scalar itself
    absent  -> enabled (the historical default: `ne <nil> false` was true)

  Effective behaviour is unchanged: resourceMonitor.enabled=true does exactly
  what resourceMonitor=true did. Emits "true" or nothing, so callers use
  `(include "tracebloc.resourceMonitorEnabled" .)` in an `and`/`or` and
  `not (include ...)` for the disabled case — the same idiom as
  tracebloc.nodeAgentsInUse.
*/}}
{{- define "tracebloc.resourceMonitorEnabled" -}}
{{- $rm := .Values.resourceMonitor -}}
{{- if kindIs "map" $rm -}}
{{- if ne (dig "enabled" true $rm) false -}}true{{- end -}}
{{- else if kindIs "invalid" $rm -}}
{{- "true" -}}
{{- else -}}
{{- if ne $rm false -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
  The host path whose free/total space becomes the cockpit's Storage meter
  (backend#3762), defaulting to the node's root filesystem.

  A HELPER RATHER THAN AN INLINE LOOKUP, for the same reason
  tracebloc.resourceMonitorEnabled is one: `resourceMonitor` is still accepted
  in its legacy SCALAR form (`resourceMonitor: true`, alias window
  remove_by: 2026-12-31), and a bool has no fields. The obvious nil-guard,
  `(default dict .Values.resourceMonitor).hostStoragePath`, does NOT cover that
  case -- `default` substitutes only when a value is EMPTY, and `true` is not
  empty -- so it renders "can't evaluate field hostStoragePath in type bool" and
  fails templating for every operator still on the scalar form. Measured, not
  reasoned: that is the error the first version of this produced.

  The else branch also covers `kindIs "invalid"` (the key absent entirely),
  which is what `helm upgrade --reuse-values` hands us on an install whose
  stored values predate this key.
*/}}
{{- define "tracebloc.resourceMonitorHostStoragePath" -}}
{{- $rm := .Values.resourceMonitor -}}
{{- if kindIs "map" $rm -}}
{{- dig "hostStoragePath" "/" $rm -}}
{{- else -}}
{{- "/" -}}
{{- end -}}
{{- end }}

{{/*
  The SECOND filesystem the Storage meter measures, or empty (backend#3916).

  The meter reports the client's storage -- every filesystem this client stores
  on -- and `hostStoragePath` above can only name one. An install that relocated
  its datasets off the local tree therefore has a disk the meter cannot see, and
  that is not a narrow case: it is exactly the HOST_DATASET_DIR flow (backend#743),
  where the installer bind-mounts the customer's network volume at /tracebloc-data
  and points `hostPath.datasetPath` there, while mysql + logs stay local. Both are
  consumed client storage; measuring either alone reports a plausible wrong number.

  EMPTY UNLESS THE DATASET TREE ACTUALLY MOVED, and both halves of that matter:

  - `hostPath.enabled` false means dynamic CSI volumes and `datasetPath` is inert
    -- shared-images-pvc.yaml reads tracebloc.clientDataHostPath only under that
    flag -- so mounting it would measure a path holding no datasets.
  - `datasetPath` is NOT an "unset means no" key: values.yaml ships the historical
    local default /tracebloc, so a plain truth test renders this mount on EVERY
    install. That is not a cosmetic difference. The mount is `type: Directory`,
    the DaemonSet tolerates every taint, and /tracebloc need not exist on an
    AKS/EKS node -- so a truth test parks resource-monitor in ContainerCreating
    fleet-wide, with no probe to flag it. Comparing against the default is what
    keeps this to installs that moved the tree somewhere real.

  The collector de-duplicates by backing device, so a datasetPath that turns out
  to share a disk with the root mount is measured once rather than doubled --
  this helper does not have to prove the two are distinct filesystems, only that
  an operator pointed datasets somewhere of their own choosing.

  `default dict` alone IS the right nil-guard here, unlike two helpers up: the
  trap there is `resourceMonitor`'s legacy SCALAR form, where `default` does not
  substitute because `true` is not empty and the field lookup then hits a bool.
  `hostPath` has no scalar form -- values.schema.json types it object-only, and
  shared-images-pvc.yaml has read `.enabled` through this same idiom since it
  shipped -- so the only case to cover is the key being absent entirely, which
  is what `default dict` covers.
*/}}
{{- define "tracebloc.resourceMonitorDatasetPath" -}}
{{- $hp := default dict .Values.hostPath -}}
{{- if $hp.enabled -}}
{{- $ds := $hp.datasetPath | default "/tracebloc" -}}
{{- if ne $ds "/tracebloc" -}}{{- $ds -}}{{- end -}}
{{- end -}}
{{- end }}

{{- define "tracebloc.rbacName" -}}
{{ include "tracebloc.fullname" . }}-jobs-manager-rbac
{{- end }}

{{- define "tracebloc.clientDataPvc" -}}
client-pvc
{{- end }}

{{- define "tracebloc.clientDataPvName" -}}
{{ include "tracebloc.fullname" . }}-data-pv
{{- end }}

{{/*
  The claim the mysql Deployment mounts as its datadir. Unset (the default) it is
  the chart's own `tracebloc.mysqlPvc`, so every existing install renders exactly
  as before.

  `mysqlClaimName` names a claim this release does NOT render — a datadir
  provisioned outside the chart, for example by an in-cluster engine migration
  that restores into a fresh volume. The Deployment then mounts that claim, and
  `tracebloc.mysqlPvc` keeps being rendered (and kept) alongside it. That is
  deliberate, not residue:
    - a `helm rollback` of a failed upgrade rebuilds the previous revision from
      its manifest, and fails on any object the release still has that the
      failed revision did not render — so a claim the chart stopped rendering
      would make the rollback back onto it impossible;
    - the root-password guards decide "this release already has MySQL data" by
      looking up `tracebloc.mysqlPvc` by name;
    - a claim that stopped being rendered and was then deleted would come back
      empty on the next apply, and on a WaitForFirstConsumer class stay Pending
      with no pod to bind it, failing every later `--atomic` apply.
  Never delete `tracebloc.mysqlPvc` while this is set; empty it in place instead.

  hostPath mode pre-binds its one static MySQL volume to `tracebloc.mysqlPvc`, so
  there is no second volume to mount there: that combination fails the render.
*/}}
{{- define "tracebloc.mysqlDataClaim" -}}
{{- $claim := .Values.mysqlClaimName | default "" -}}
{{- if and $claim (default dict .Values.hostPath).enabled -}}
{{- fail "mysqlClaimName is not supported with hostPath.enabled=true: hostPath mode pre-binds its one static MySQL volume to the claim the chart renders, so there is no second volume to mount." -}}
{{- end -}}
{{- $claim | default (include "tracebloc.mysqlPvc" .) -}}
{{- end }}

{{/*
  jobs-manager's replica count. It is a single-writer controller on ReadWriteOnce
  volumes (Recreate strategy), so the only meaningful values are 1 (the default)
  and 0 — scaled down through the release's values, so that a later `helm upgrade`
  keeps it at 0 instead of reverting live drift back to the template. Nil-guarded
  rather than `default 1`, because `default` treats 0 as unset and would turn a
  deliberate 0 back into 1.
*/}}
{{- define "tracebloc.jobsManagerReplicas" -}}
{{- $r := .Values.jobsManagerReplicas -}}
{{- if kindIs "invalid" $r -}}1{{- else -}}{{- int $r -}}{{- end -}}
{{- end }}

{{- define "tracebloc.clientDataStorage" -}}
{{ .Values.pvc.data | default "50Gi" }}
{{- end }}

{{/*
  hostPath base for the DATASET (shared-images) PV ONLY. Defaults to the
  historical local path /tracebloc so installs without a network dataset mount
  render byte-identically. When the installer bind-mounts a customer network
  (NFS) dir at /tracebloc-data (HOST_DATASET_DIR set), it passes
  hostPath.datasetPath=/tracebloc-data to relocate datasets onto that mount,
  while mysql + logs ALWAYS stay on the local /tracebloc tree (InnoDB over NFS
  is unsafe — backend#743). The /<release>/data suffix is appended here.
  Nil-guarded (default dict) for `--reuse-values` upgrades predating this key.
*/}}
{{- define "tracebloc.clientDataHostPath" -}}
{{ printf "%s/%s/data" ((default dict .Values.hostPath).datasetPath | default "/tracebloc") .Release.Name }}
{{- end -}}

{{- define "tracebloc.clientLogsPvc" -}}
client-logs-pvc
{{- end }}

{{- define "tracebloc.clientLogsPvName" -}}
{{ include "tracebloc.fullname" . }}-logs-pv
{{- end }}

{{- define "tracebloc.clientLogsStorage" -}}
{{ .Values.pvc.logs | default "10Gi" }}
{{- end }}

{{- define "tracebloc.mysqlPvc" -}}
mysql-pvc
{{- end }}

{{/*
  Name of the "this edge was born rotated" marker (backend#947). A CONSTANT
  literal, deliberately NOT fullname/override-following -- like tracebloc.mysqlPvc
  and unlike tracebloc.secretName -- so tracebloc.bakedRootRotationOn may `lookup`
  it without tripping fullname-override-completeness.sh (backend#2626), which
  refuses only Secret lookups on the override-following secretName. See the marker
  template (mysql-root-rotated-marker.yaml) and bakedRootRotationOn for why it
  exists: the PVC alone cannot tell a born-rotated edge from an existing un-rotated
  one, and that ambiguity un-rotated a fresh stg/prod install on its next upgrade.
*/}}
{{- define "tracebloc.mysqlRootRotatedMarker" -}}
mysql-root-rotated
{{- end }}

{{- define "tracebloc.mysqlPvName" -}}
{{ include "tracebloc.fullname" . }}-mysql-pv
{{- end }}

{{- define "tracebloc.mysqlStorage" -}}
{{ .Values.pvc.mysql | default "2Gi" }}
{{- end }}

{{/*
  The pull Secret's name. `<release>-regcred` when the chart makes it -- release
  scoped, because two releases in one namespace must not share a Secret -- or
  the operator's own name when they brought their own.

  Every imagePullSecrets block in the chart and the IMAGE_PULL_SECRET_NAME that
  jobs-manager stamps onto training pods both read THIS, so the name cannot
  disagree between the pod that creates the Secret and the pod that uses it.
*/}}
{{/*
  The name the CHART creates, whatever `existingSecret` says. Not the same
  question as `registrySecretName`, and RBAC is where the difference bites
  (Bugbot on client#751).

  The auto-upgrade Role in the GPU device-plugin namespace -- `kube-system` by
  default -- pins `get`/`update`/`patch`/`delete` to a `resourceNames` list so
  Helm can reconcile the mirrored pull Secret. Resolving that list through
  `registrySecretName` would hand the auto-upgrade ServiceAccount read AND
  delete on the OPERATOR's own dockerconfigjson in kube-system -- a privilege
  over a Secret this chart does not own and was never asked to touch.

  It also keeps the migration honest in the other direction: switching a release
  from `create: true` to `existingSecret` leaves the previously mirrored
  `<release>-regcred` behind, and Helm has to be able to delete it. A list that
  followed `existingSecret` would stop naming the orphan, so the delete would
  403 and stall auto-upgrade on every later tick.
*/}}
{{- define "tracebloc.createdRegistrySecretName" -}}
{{ include "tracebloc.fullname" . }}-regcred
{{- end }}

{{- define "tracebloc.registrySecretName" -}}
{{- $reg := .Values.dockerRegistry | default dict -}}
{{- if $reg.existingSecret -}}
{{ $reg.existingSecret }}
{{- else -}}
{{ include "tracebloc.fullname" . }}-regcred
{{- end -}}
{{- end }}

{{/*
  Name of the GPU device-plugin DaemonSet, by vendor. Takes the resolved vendor
  string as its context, NOT the root scope:
    {{ include "tracebloc.gpuDevicePluginName" "nvidia" }}

  These names are NOT release-scoped on purpose — they match the upstream
  manifests the installer used to `kubectl apply`, so an installer re-run adopts
  an existing DaemonSet in place instead of orphaning it (client#564).

  Kept in ONE helper because two templates must agree on them: gpu-device-plugin
  .yaml renders the DaemonSet, and auto-upgrade-rbac.yaml grants the auto-upgrade
  ServiceAccount update/patch/delete restricted to exactly these resourceNames
  (backend#1992). If those two ever disagreed, an `helm upgrade --atomic` tick
  would 403 in the GPU namespace, roll back, and silently kill auto-upgrade on
  every GPU edge — the failure this narrow Role exists to prevent. Deriving both
  from here makes that drift impossible rather than merely unlikely.

  Any vendor other than "amd" resolves to the NVIDIA name; gpu-device-plugin.yaml
  `fail`s the render for a vendor outside {nvidia, amd} before that can matter.
*/}}
{{- define "tracebloc.gpuDevicePluginName" -}}
{{- if eq . "amd" -}}
amdgpu-device-plugin-daemonset
{{- else -}}
nvidia-device-plugin-daemonset
{{- end -}}
{{- end }}

{{/*
  Release-scoped name shared by the auto-upgrade CronJob, ServiceAccount,
  ClusterRoleBinding, and the ConfigMap holding the upgrade script. Kept
  in one helper so the four resources stay in lockstep — the CRB references
  the SA by name, and the CronJob mounts the ConfigMap by name.
*/}}
{{- define "tracebloc.autoUpgradeName" -}}
{{ include "tracebloc.fullname" . }}-auto-upgrade
{{- end }}

{{/*
  Release-scoped name shared by the image-refresh CronJob, ServiceAccount,
  Role, RoleBinding, and ConfigMap. Same lockstep reasoning as
  tracebloc.autoUpgradeName above. Distinct from auto-upgrade because the
  two CronJobs have different cadences, different RBAC scopes (image-refresh
  is namespace-scoped; auto-upgrade is namespace-scoped plus a narrow
  ClusterRole for the chart's cluster kinds — backend#953, no longer
  cluster-admin), and customers may reasonably disable one but not the other.
*/}}
{{- define "tracebloc.imageRefreshName" -}}
{{ include "tracebloc.fullname" . }}-image-refresh
{{- end }}

{{/*
  Name for the image-refresh Role + RoleBinding in the NODE-AGENTS namespace
  (#569). DISTINCT from tracebloc.imageRefreshName on purpose.

  `nodeAgents.namespace.name` pointing back at the release namespace is a
  supported layout — node-agents-namespace.yaml documents it and explicitly
  skips creating the Namespace in that case. Reusing the release-namespace name
  here collided with it: two Roles and two RoleBindings with the SAME name in
  the SAME namespace. Helm either refuses the release or the later
  DaemonSet-only Role overwrites the deployments Role, at which point
  image-refresh silently loses patch on jobs-manager and requests-proxy — and
  since those pods now render IfNotPresent, they would have no update path left
  at all (Bugbot, High).

  A separate name is correct in BOTH layouts: split namespaces get one Role
  each, and the collapsed layout gets two complementary Roles (deployments,
  daemonsets) bound to the same ServiceAccount, which is exactly the intended
  grant.
*/}}
{{- define "tracebloc.imageRefreshNodeAgentsName" -}}
{{ include "tracebloc.fullname" . }}-image-refresh-node-agents
{{- end }}

{{/*
  jobs-manager Role/RoleBinding pair in the node-agents namespace. Distinct from
  tracebloc.rbacName so the pairs cannot collide when that namespace IS the
  release namespace.
*/}}
{{- define "tracebloc.rbacNodeAgentsName" -}}
{{ include "tracebloc.fullname" . }}-jobs-manager-node-agents
{{- end }}

{{/*
  Name of the requests-proxy Deployment. ONE definition, because #569 gave it a
  second consumer: image-refresh reconciles it by name with `kubectl set image`,
  so a rename that reached only the Deployment would leave the CronJob patching
  a workload that does not exist — failing the tick, freezing the digest record,
  and eventually tripping the shared flap lockout for every control-plane image.

  This is the third instance on #569 of one side of a two-sided contract moving
  without the other (the requests-proxy digest pin and the resource-monitor pin
  signal were the first two, both found in review). Same remedy: collapse to a
  single definition rather than keep two literals in sync by hand.

  The jobs-manager Deployment has the same shape — image-refresh's
  DEPLOYMENT_NAME re-derives `<release>-jobs-manager` with its own printf, and
  five other call sites spell it out too (NOTES.txt, the PDB,
  tracebloc.serviceAccountName, ...). Unifying THAT is a mechanical refactor
  across templates this change does not otherwise touch, so it is deliberately
  left for its own PR; a contract test pins the two sides here in the meantime.
*/}}
{{- define "tracebloc.requestsProxyName" -}}
{{ include "tracebloc.fullname" . }}-requests-proxy
{{- end }}

{{/*
  Whether the image-refresh CronJob has anything to do. When ALL THREE
  managed images (jobs-manager, pods-monitor, resource-monitor) are
  digest-pinned, the operator has explicitly opted into reproducible
  pinning for every image this CronJob would refresh, so we render
  nothing — no CronJob, no RBAC, no ConfigMap. When at least one is
  unpinned, the CronJob is rendered and the script skips the pinned
  images at runtime via env flags.

  The three have changed over time: #154 started with jobs-manager +
  pods-monitor, #158 added the ingestor, the floating-tag migration
  retired the ingestor pass, and #569 brought resource-monitor under
  refresh (it had no deliberate update path before). Keep this list in
  sync if more images come under auto-refresh in future.

  Nil-guarded with `default dict` on every dereference: these are
  newer top-level keys, and a customer who runs
  `helm upgrade --reuse-values` (instead of the recommended
  --reset-then-reuse-values that autoUpgrade itself uses) could replay
  stored values from before the keys existed. Without the guard,
  `.Values.imageRefresh.enabled` would still nil-coalesce safely, but
  `.Values.images.<image>.digest` could crash if `.Values.images` were
  ever absent. Belt-and-suspenders — see the "nil-guard every new
  top-level value key" rule in CLAUDE.md.
*/}}
{{/*
  tracebloc.resourceMonitorRefreshPinned — whether image-refresh has nothing to
  do for resource-monitor. Renders "true" when so, nothing when not.

  ONE definition, because there are TWO consumers that must agree:
  `tracebloc.imageRefreshEnabled` (does the CronJob render at all?) and the
  CronJob's own RESOURCE_MONITOR_PINNED env (does the script skip this image?).
  The first cut of #569 wrote the rule twice and they disagreed: the helper
  checked only the digest while the env also treated `resourceMonitor: false` as
  pinned. With the DaemonSet disabled and both class-1 images pinned, the CronJob
  therefore kept rendering a job that skipped every image and exited green every
  tick, forever — where before #569 that combination retired it (Bugbot).

  Two ways to have nothing to do:
    * an HONOURED `images.resourceMonitor.digest` pin (tracebloc.pinFor -- a
      pin resolved on a registry this release does not pull from is ignored,
      so the DaemonSet floats and the CronJob keeps re-pinning it from the
      live registry), same signal as the other images, or
    * `resourceMonitor: false` — there is no DaemonSet at all, so there is
      nothing to reconcile and a cross-namespace `set image` would just fail.

  Nil-safe via tracebloc.resourceMonitorEnabled, which absent reads as enabled,
  matching the gate on the DaemonSet itself and honouring both the legacy scalar
  and the new resourceMonitor.enabled object form.
*/}}
{{- define "tracebloc.resourceMonitorRefreshPinned" -}}
{{- if not (include "tracebloc.resourceMonitorEnabled" .) -}}
true
{{- else if (include "tracebloc.pinFor" (dict "image" "resourceMonitor" "root" .)) -}}
true
{{- end -}}
{{- end }}

{{- define "tracebloc.imageRefreshEnabled" -}}
{{- $ir := default dict .Values.imageRefresh -}}
{{/*
  Per-image pin signal (means "skip auto-refresh for this image"):
  jobs-manager / pods-monitor are pinned when tracebloc.pinFor HONOURS their
  `digest` -- set, and resolved on the registry this release pulls from. That
  is the same decision that renders `repo@digest` and switches imagePullPolicy
  to IfNotPresent, so a pin the render ignored (registry mismatch) is unpinned
  here too and the CronJob stays to re-pin it from the live registry. The
  ingestor is no longer refreshed by this CronJob (it is spawned by
  jobs-manager from a floating tag — see the image-refresh-cronjob.yaml header
  and submit_ingestion_run in client-runtime), so the CronJob exists only to
  refresh the two class-1 images: when BOTH are pinned there is nothing left
  for it to do.
*/}}
{{- $jmPinned := include "tracebloc.pinFor" (dict "image" "jobsManager" "root" .) -}}
{{- $pmPinned := include "tracebloc.pinFor" (dict "image" "podsMonitor" "root" .) -}}
{{/*
  #569: resource-monitor came under refresh too, so it joins the "nothing left
  to do" test. requests-proxy deliberately does NOT: it runs the SAME
  tracebloc/jobs-manager image and follows the jobs-manager digest, so
  `$jmPinned` already covers it. (`images.requestsProxy.digest` remains an
  operator override that pins requests-proxy alone; it is checked at runtime,
  not here, because pinning only requests-proxy still leaves jobs-manager
  itself to refresh.)

  "Follows the jobs-manager digest" is only true because
  requests-proxy-deployment.yaml FALLS BACK to `images.jobsManager.digest` when
  its own key is empty. Without that fallback this test is a silent trap
  (Bugbot): retiring the CronJob here on a jobs-manager pin would leave the
  proxy rendering the floating tag with nothing left to reconcile it, running a
  different build of the same image forever. If that fallback is ever removed,
  requests-proxy must get its own entry in this test.
*/}}
{{- $rmPinned := include "tracebloc.resourceMonitorRefreshPinned" . -}}
{{- if not $ir.enabled -}}
{{- else if and $jmPinned $pmPinned $rmPinned -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{/*
  tracebloc.controlPlanePullPolicy — the pull policy for the four always-running
  control-plane images (jobs-manager, pods-monitor, requests-proxy,
  resource-monitor). ONE definition so the four call sites cannot disagree.

  #569 set out to make these pods survive an offline Docker/WSL restart:
  `Always` forces a registry round-trip on every (re)start, so a restart without
  the registry lands in ImagePullBackOff even with the image cached in
  containerd. The fix is IfNotPresent.

  But `Always` is not just fragility — on a floating tag it IS an update path:
  restart the pod and the kubelet re-resolves the tag. The first cut of #569
  made IfNotPresent UNCONDITIONAL, which silently removed that path from every
  edge where the replacement (image-refresh's `kubectl set image repo@digest`)
  cannot run — those edges would have frozen on their cached image forever, with
  a green CronJob and no signal (Bugbot, High). So the policy tracks whether an
  update path actually exists:

    1. An HONOURED `digest` pin (tracebloc.effectivePin: set, resolved on the
       registry this release pulls from; requests-proxy inherits the
       jobs-manager pin) -> IfNotPresent. The reference is immutable, so
       re-checking the registry can only ever return the same image. Updates
       come from changing the pin. A pin the render IGNORED (registry
       mismatch) is not a pin here either: that workload floats, so it takes
       branch 2 or 3 like an unpinned one.
    2. Otherwise, if the image-refresh reconcile can actually drive updates on
       this edge -> IfNotPresent, because `set image` changes the REFERENCE and
       the kubelet pulls a digest it has never seen. Two conditions:
         * the CronJob renders at all (`imageRefresh.enabled`, and not every
           refreshed image already pinned), and
         * the images come from a registry the script can resolve digests on
           anonymously (tracebloc.imageRefreshResolvableRegistries: docker.io,
           ghcr.io — wherever tracebloc.tbRegistry points). Under a
           `global.imageRegistry` mirror the script goes inert by design — it
           cannot resolve there, and pinning a digest resolved elsewhere onto a
           mirrored reference could pin an image the mirror does not hold.
    3. Otherwise -> Always. No reconcile, no pin, so a floating tag plus a
       restart is the ONLY way that edge can ever move. This is exactly the
       pre-#569 behaviour, kept for exactly the edges that still depend on it:
       mirror installs (sync the mirror, restart) and `imageRefresh.enabled:
       false` (restart manually), which is what values.schema.json has always
       promised those operators.

  The trade is deliberate and worth stating plainly: offline-restart safety is
  delivered precisely where the digest reconcile can deliver updates. An edge
  that opts out of the mechanism keeps the old semantics rather than silently
  freezing — a frozen control plane with no signal is worse than a restart that
  needs the network.

  Usage: {{ include "tracebloc.controlPlanePullPolicy" (dict "image" "jobsManager" "root" $) }}
  Takes the IMAGE KEY, not a digest: the helper asks tracebloc.effectivePin
  itself, so a call site cannot hand it a raw values digest the image site
  did not render.
*/}}
{{- define "tracebloc.controlPlanePullPolicy" -}}
{{- if include "tracebloc.effectivePin" . -}}
IfNotPresent
{{- else if and (include "tracebloc.imageRefreshEnabled" .root) (include "tracebloc.imageRefreshResolvable" .root) -}}
IfNotPresent
{{- else -}}
Always
{{- end -}}
{{- end }}

{{/*
  StorageClass name: when storageClass.create is true, use a release-unique name
  so each release gets its own StorageClass (avoids Helm ownership conflicts).
  When create is false, use the user-provided storageClass.name for an existing class.
*/}}
{{- define "tracebloc.storageClassName" -}}
{{- if .Values.storageClass.create -}}
{{ include "tracebloc.fullname" . }}-storage-class
{{- else -}}
{{ .Values.storageClass.name }}
{{- end -}}
{{- end -}}

{{/*
  Whether this release HAS a registry pull Secret -- whoever made it. True when
  the chart creates one (`dockerRegistry.create: true`) or when the operator
  points at one they made themselves (`dockerRegistry.existingSecret`). Omit
  `dockerRegistry` entirely, or set `create: false` with no `existingSecret`,
  for public images: nothing renders and every pull is anonymous by declaration.

  `existingSecret` exists because of a config this chart never supported and
  never noticed (Asad on client#751): `create: false` plus a Secret hand-made in
  the namespace and literally named `regcred`. That worked for exactly one pod
  -- the training pod -- because client-runtime's `job.yaml` carried `regcred`
  as a hardcoded literal, while every chart-rendered pod got no imagePullSecrets
  at all. So those installs were half-authenticated by accident, and the moment
  backend#2119 replaces that literal with the injected name they would fall to
  an anonymous pull with nothing louder than an INFO log -- the same silent
  downgrade this PR exists to remove, moved rather than fixed.

  This is the ONE helper every consumer consults, which is why the
  contradiction check lives here: it cannot be bypassed by adding a template.
*/}}
{{- define "tracebloc.useImagePullSecrets" -}}
{{- $reg := .Values.dockerRegistry | default dict -}}
{{- if and (default false $reg.create) $reg.existingSecret -}}
{{- fail (printf "dockerRegistry.create is true AND dockerRegistry.existingSecret is %q. Those contradict: one asks the chart to build the Secret from the credentials in values, the other says one already exists. Pick one -- drop `create` to use your own Secret, or drop `existingSecret` to let the chart build it." $reg.existingSecret) -}}
{{- end -}}
{{- if or (default false $reg.create) $reg.existingSecret -}}
true
{{- end -}}
{{- end }}

{{/*
  Whether the CHART renders the Secret, as opposed to merely referencing one.
  Split out from `useImagePullSecrets` because those two questions had the same
  answer until `existingSecret` existed and now do not: gating the Secret
  template on "a Secret exists" would make the chart overwrite the operator's
  hand-made one with credentials from values it does not have -- turning a
  supported config into a broken pull on the first upgrade.
*/}}
{{- define "tracebloc.createRegistrySecret" -}}
{{- $reg := .Values.dockerRegistry | default dict -}}
{{- if default false $reg.create -}}
true
{{- end -}}
{{- end }}

{{/*
Image reference — defaults to docker.io when no registry is provided.
When `digest` (sha256:...) is set, renders registry/repo@digest (immutable pin,
preferred for security). Otherwise falls back to registry/repo:tag, where tag
defaults to "prod" when CLIENT_ENV is omitted or empty.
Usage: {{ include "tracebloc.image" (dict "repository" "library/busybox" "tag" .Values.images.busybox.tag "digest" .Values.images.busybox.digest "registry" "docker.io") }}
NOTE the resolved tag. This example previously read `.Values.env.CLIENT_ENV`
and all four image call sites were copied from it, so a documented alias
became an image tag nothing publishes (backend#1723).
CONTROL-PLANE IMAGES DO NOT CALL THIS DIRECTLY. jobs-manager, pods-monitor,
resource-monitor and requests-proxy go through tracebloc.controlPlaneImage,
which decides FIRST whether the values pin may be rendered at all
(tracebloc.pinFor: only on the registry it was resolved on). Passing
`.Values.images.jobsManager.digest` straight in here -- the shape this example
used to show -- is how a Docker Hub digest was rendered onto ghcr.io.
*/}}
{{- define "tracebloc.image" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $digest := .digest | default "" -}}
{{- if $digest -}}
{{ $registry }}/{{ .repository }}@{{ $digest }}
{{- else -}}
{{ $registry }}/{{ .repository }}:{{ .tag | default "prod" }}
{{- end -}}
{{- end }}

{{/*
tracebloc.thirdPartyImageDefaults -- THE chart-side copy of every values-backed
third-party image reference, keyed by its path in values.yaml. It is read ONLY
by tracebloc.thirdPartyPinDecision (below): for the nil path, and for the
identity of the chart's own pin.

WHY A COPY EXISTS AT ALL. A template cannot read values.yaml's defaults when
the block is absent: `.Values` is the merged result, and on a `--reuse-values`
upgrade from a release that predates the block (or an explicit `<block>: null`)
the chart default never reaches the render. `.Files` does not serve values.yaml
either (measured: `len (.Files.Get "values.yaml")` renders 0). So the nil path
needs its own declaration of the default -- the digest included.

`digestFor` IS THE IDENTITY OF THE CHART PIN: the `<repository>:<tag>` the
row's `digest` was resolved for. It is what the pin rule compares the rendered
repository:tag against when the operator has not declared an identity of their
own, so a pin can never be applied to an image it was not resolved for. An
unpinned row (`digest: ""`) declares none.

WHY THIS COPY CANNOT DRIFT UNSEEN. Every image site used to restate its own
defaults inline, and every one defaulted `digest` to "" -- so a nil block
rendered `registry/repo:tag` where values.yaml pins `@sha256:...`, silently,
and the AMD site still said `latest` after values.yaml had moved off it.
Now there is ONE copy, and scripts/tests/third-party-image-defaults-agreement.sh
(a DRIFT_GUARDS entry) holds it field-for-field against values.yaml, holds each
`digestFor` against its own row's repository:tag, holds its keys against the
`site` of every call below, refuses any template that hands a values digest to
tracebloc.image directly, and renders every override shape per site. Bumping a
pin in values.yaml means bumping it here in the same PR; the guard names both
places when you forget.

The table body is plain YAML with no template actions, on purpose: the guard
parses it as YAML straight out of this file.
*/}}
{{- define "tracebloc.thirdPartyImageDefaults" -}}
egressProxy.image:
  registry: docker.io
  repository: ubuntu/squid
  tag: "6.6-24.04_beta"
  digest: "sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029"
  digestFor: "ubuntu/squid:6.6-24.04_beta"
sealCheck.storageAssertions.image:
  registry: docker.io
  repository: alpine/k8s
  tag: "1.30.5"
  digest: "sha256:0d03af14f8539df28e51e8afc12ee6d78891c630b88226243307f08a6fab3538"
  digestFor: "alpine/k8s:1.30.5"
autoUpgrade.image:
  registry: docker.io
  repository: alpine/helm
  tag: "3.16.4"
  digest: "sha256:9b25e60ae264940b276e32866d37e3088e70c4e2d1784b964dc3f90346281a74"
  digestFor: "alpine/helm:3.16.4"
imageRefresh.image:
  registry: docker.io
  repository: alpine/k8s
  tag: "1.30.5"
  digest: "sha256:0d03af14f8539df28e51e8afc12ee6d78891c630b88226243307f08a6fab3538"
  digestFor: "alpine/k8s:1.30.5"
gpu.devicePlugin.amd:
  registry: docker.io
  repository: rocm/k8s-device-plugin
  tag: "1.31.0.11"
  digest: "sha256:e4df5dc9a7fa34e2344852256dcc5762171a6d68f1f9a34026ce26786ae335e2"
  digestFor: "rocm/k8s-device-plugin:1.31.0.11"
gpu.devicePlugin.nvidia:
  registry: nvcr.io
  repository: nvidia/k8s-device-plugin
  tag: "v0.14.5"
  digest: ""
  digestFor: ""
telemetryCollector.image:
  registry: ghcr.io
  repository: open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib
  tag: "0.159.0"
  digest: ""
  digestFor: ""
images.busybox:
  registry: docker.io
  repository: library/busybox
  tag: "1.35"
  digest: "sha256:98ad9d1a2be345201bb0709b0d38655eb1b370145c7d94ca1fe9c421f76e245a"
  digestFor: "library/busybox:1.35"
{{- end -}}

{{/*
tracebloc.thirdPartyPinDecision -- THE ONE decision for a values-backed
third-party image site: which reference it renders, and whether a digest was
dropped on the way. Renders JSON:

  ref       the image reference the site renders
  digest    the digest in effect before the rule (block's own, else the chart's)
  identity  the rendered `<repository>:<tag>` (registry excluded, see below)
  for       the identity the digest is deemed resolved for
  dropped   true when a digest was set but NOT rendered

Arguments: `site` (the block's path in values.yaml; must be a key of
tracebloc.thirdPartyImageDefaults -- an unknown site FAILS the render, a typo
must not silently render some default) and `root`. The block is read HERE, by
walking `site` through `.Values`, and nowhere else: the image sites
(tracebloc.thirdPartyImage) and NOTES (tracebloc.droppedThirdPartyPins) both
call this function, so what NOTES reports is exactly what the sites rendered.

THE PIN RULE -- the tracebloc.pinFor mould, with repository:tag in the place of
the registry. A digest names the bytes of ONE image; applied to another it
does not pull, or -- in a mirror that happens to hold it -- pulls something
other than what the operator named. So a digest is honoured only for the image
it was resolved for:

  <site>.digest     the pin (block's own; the chart's when the block has none,
                    which is the nil path: an empty block renders the chart
                    default reference IN FULL, digest included)
  <site>.digestFor  `<repository>:<tag>` the digest was resolved for

  honoured  <=>  digest non-empty AND for == rendered repository:tag
  dropped   otherwise: the site renders `registry/repository:tag` and NOTES
            names the site, the digest's identity and the rendered one.

  `for` is `digestFor` when the block declares one. When it does not:
    * the digest IS the chart's      -> the chart row's `digestFor` (so a
      chart pin survives only while repository AND tag equal the chart
      defaults: an operator who re-homes the image and leaves the digest
      alone gets their repo:tag, not our digest on their image);
    * the digest is the operator's own -> the rendered identity (they wrote
      digest and image together; it is always honoured).

  A PATH-REWRITING MIRROR (e.g. `harbor.corp` + `dockerhub/alpine/helm`)
  holding the SAME bytes keeps the chart pin by declaring it:
  `digestFor: "dockerhub/alpine/helm:3.16.4"`. A render cannot tell that mirror
  from a different image, so it has to be said.

  REGISTRY IS NOT PART OF THE IDENTITY. `registry` and global.imageRegistry
  (#585) re-home the same repository path, and a mirror of it carries the same
  digests, so the pin survives a registry-only re-home -- global.imageRegistry
  wins over every per-site registry, as before.

NEVER `fail` on values. Dropping to the tag is the safe state, as it is for
tracebloc.pinFor; refusing to render would wedge an auto-upgrade over a pin.
*/}}
{{- define "tracebloc.thirdPartyPinDecision" -}}
{{- $all := include "tracebloc.thirdPartyImageDefaults" . | fromYaml -}}
{{- if not (hasKey $all .site) -}}
{{- fail (printf "tracebloc.thirdPartyImage: no chart default declared for image site %q; add it to tracebloc.thirdPartyImageDefaults" .site) -}}
{{- end -}}
{{- $d := index $all .site -}}
{{- $node := .root.Values -}}
{{- range $k := splitList "." .site -}}
{{- if kindIs "map" $node -}}
{{- $node = index $node $k -}}
{{- else -}}
{{- $node = dict -}}
{{- end -}}
{{- end -}}
{{- $b := dict -}}
{{- if kindIs "map" $node -}}
{{- $b = $node -}}
{{- end -}}
{{- $chartDigest := $d.digest | default "" -}}
{{- $digest := $chartDigest -}}
{{- if hasKey $b "digest" -}}
{{- $digest = $b.digest | default "" -}}
{{- end -}}
{{- $repository := $b.repository | default $d.repository -}}
{{- $tag := toString ($b.tag | default $d.tag) -}}
{{- $identity := printf "%s:%s" $repository $tag -}}
{{- $for := $b.digestFor | default "" -}}
{{- if not $for -}}
{{- if eq $digest $chartDigest -}}
{{- $for = $d.digestFor | default "" -}}
{{- else -}}
{{- $for = $identity -}}
{{- end -}}
{{- end -}}
{{- $honoured := "" -}}
{{- if and $digest (eq $for $identity) -}}
{{- $honoured = $digest -}}
{{- end -}}
{{- $registry := (dig "imageRegistry" "" (.root.Values.global | default dict)) | default ($b.registry | default $d.registry) -}}
{{- $ref := include "tracebloc.image" (dict "repository" $repository "tag" $tag "digest" $honoured "registry" $registry) -}}
{{- dict "ref" $ref "digest" $digest "identity" $identity "for" $for "dropped" (and (ne $digest "") (eq $honoured "")) | toJson -}}
{{- end -}}

{{/*
tracebloc.thirdPartyImage -- the image reference for a values-backed
third-party image site: tracebloc.thirdPartyPinDecision's `ref`, nothing else.
Every such site calls this, with its values path as `site`.
Usage: {{ include "tracebloc.thirdPartyImage" (dict "site" "autoUpgrade.image" "root" $) }}
*/}}
{{- define "tracebloc.thirdPartyImage" -}}
{{- (include "tracebloc.thirdPartyPinDecision" . | fromJson).ref -}}
{{- end -}}

{{/*
tracebloc.droppedThirdPartyPins -- one entry per third-party image site whose
digest tracebloc.thirdPartyPinDecision DROPPED, for NOTES.txt. Every row of the
defaults table is read, whether or not its workload is enabled: an entry means
the values for that site name a digest the site will not render, which is
worth knowing before the workload is switched on too. Renders nothing when no
pin was dropped.
*/}}
{{- define "tracebloc.droppedThirdPartyPins" -}}
{{- $root := . -}}
{{- range $site := (include "tracebloc.thirdPartyImageDefaults" $root | fromYaml | keys | sortAlpha) -}}
{{- $dec := include "tracebloc.thirdPartyPinDecision" (dict "site" $site "root" $root) | fromJson -}}
{{- if $dec.dropped }}
  - {{ $site }}.digest = {{ $dec.digest }}
    resolved for {{ $dec.for | default "(no identity)" }}; this release renders {{ $dec.identity }}, so it pulls {{ $dec.ref }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
tracebloc.mirrorPrefix — registry prefix for images whose repository is a
registry-less path (docker.io implicit), e.g. the alpine/* utility-pod images.
When a private mirror is set via global.imageRegistry (#585), returns
"<registry>/" so an air-gapped install re-homes those images onto the mirror;
returns "" when no mirror is set, so default installs render byte-identically.
Nil-guarded for --reset-then-reuse-values upgrades that predate global. Call
with the ROOT context (e.g. `include "tracebloc.mirrorPrefix" $`).

NO CALLERS IN THIS CHART since backend#4160 moved the last three sites
(auto-upgrade, image-refresh, storage-assertions) onto `tracebloc.image`, which
always names a registry and is what a new site should use. Retained, not
deleted: a chart that vendors this one can `include` it, and deleting a defined
template is a breaking change to that contract, not a cleanup. If you are adding
an image site, this is the wrong helper — `tracebloc.image` is the one
`scripts/tests/one-image-helper.sh` requires.
*/}}
{{- define "tracebloc.mirrorPrefix" -}}
{{- with (dig "imageRegistry" "" (.Values.global | default dict)) }}{{ . }}/{{ end -}}
{{- end -}}

{{/*
tracebloc.imageRefreshResolvableRegistries — the registries the image-refresh
script can resolve a floating tag to a digest on WITHOUT a credential: the
public token endpoints it knows (`get_token` / `get_latest_digest` in
image-refresh-cronjob.yaml carry one arm per entry). Space-separated, ONE
declaration: `tracebloc.imageRefreshResolvable` (below) and the
`tracebloc.controlPlanePullPolicy` decision both read it, and the CronJob
renders the verdict into the script's env as IMAGE_REGISTRY_RESOLVABLE — so the
pods' pull policy and the script's "can I reconcile here" guard cannot disagree.
Adding a registry here without a matching token arm in the script would make
the pods IfNotPresent while every tick WARNs "unknown registry"; the unit tests
pin the arms to this list.
*/}}
{{- define "tracebloc.imageRefreshResolvableRegistries" -}}
docker.io ghcr.io
{{- end -}}

{{/*
tracebloc.tbRegistry — the registry the tracebloc-PUBLISHED images are pulled
from: the control-plane images (tracebloc/jobs-manager, tracebloc/pods-monitor,
tracebloc/resource-monitor, and the requests-proxy, which runs the jobs-manager
image) AND the host jobs-manager stamps onto every training image it spawns
(JOB_IMAGE_HOST, rendered as "<registry>/" on both jobs-manager containers).

ONE precedence chain, so the four control-plane call sites, the two
JOB_IMAGE_HOST sites, the image-refresh CronJob and NOTES.txt cannot disagree
about where those images live:

  1. `global.imageRegistry`      — a private mirror re-homes EVERY image the
                                    chart pulls (#585), tracebloc/* included.
                                    It always wins.
  2. `images.traceblocRegistry`  — the tracebloc-only knob: moves the
                                    tracebloc-published images -- control plane
                                    and training-image host TOGETHER -- leaving
                                    busybox, squid, alpine/*, the device plugins
                                    and the ingestor where they are. Also the
                                    per-edge rollback: set it to the previous
                                    registry.
  3. "ghcr.io"                   — the chart default since the GHCR migration.
                                    The images are still dual-published to
                                    Docker Hub at the same digests, so
                                    "docker.io" is the documented rollback.

ROUTED THROUGH HERE SINCE D1 STEP 6 (backend#3397): `tracebloc/mysql-client`.
It used to be excluded because it was "published only to Docker Hub", and step 6
ends that -- the image is copied to ghcr.io at the same digests and
`build-mysql-client.yml` publishes there. Leaving it out would give the chart two
answers to "where do the tracebloc-published images live", which is the split
this helper exists to close. It is still FROZEN and digest-pinned; what changed
is the host, not the bytes, and `images.traceblocRegistry: docker.io` rolls it
back with everything else (the Hub namespace is retained, frozen, never deleted
-- RFC-BACKEND-2610 step 7).

NOT routed through here, on purpose: the third-party images (each has its own
`registry` key), and the ingestor, which is named by full repository
(images.ingestor.repository, already on ghcr.io) and follows only the global
mirror.

Every read is nil-guarded and `| default`-chained: values.yaml ships
`global.imageRegistry: ""` (the key EXISTS, so `dig`'s own fallback never
applies — the trap image_refresh_test.yaml pins), and an edge upgrading with
`--reuse-values` from before `images.traceblocRegistry` existed has no such key
at all. Both must render the default, never "". The literal below RESTATES
values.yaml's `images.traceblocRegistry` default -- unavoidably, since a
template cannot read the chart's defaults apart from the merged values -- so
tests/tracebloc_registry_test.yaml pins both to one value: the chart-default
tests read values.yaml, the EMPTY-knob tests read this literal.

Call with the ROOT context: {{ include "tracebloc.tbRegistry" . }}
*/}}
{{- define "tracebloc.tbRegistry" -}}
{{- $mirror := dig "imageRegistry" "" (.Values.global | default dict) -}}
{{- $own := dig "traceblocRegistry" "" (.Values.images | default dict) -}}
{{- $mirror | default ($own | default "ghcr.io") -}}
{{- end -}}

{{/*
tracebloc.imageRefreshResolvable — "true" when the image-refresh script can
reconcile on this edge: the registry tracebloc.tbRegistry resolves to is one of
tracebloc.imageRefreshResolvableRegistries. Empty otherwise (a private mirror,
or a registry the script has no token arm for). Call with the ROOT context.
*/}}
{{- define "tracebloc.imageRefreshResolvable" -}}
{{- if has (include "tracebloc.tbRegistry" .) (splitList " " (include "tracebloc.imageRefreshResolvableRegistries" .)) -}}
true
{{- end -}}
{{- end -}}

{{/*
tracebloc.controlPlaneImages — THE declaration of the four always-running
control-plane images that share one pinning contract: the values key under
`images.` -> the repository. JSON, because a template can only return a string;
consumers `fromJson` it. ONE declaration so the image sites, the pin decision,
the image-refresh env flags and the NOTES.txt warning all iterate the same set:
a fifth image added here is pinned, refreshed and reported everywhere at once,
and a key that is not here fails the render (a template bug, never an operator
input -- see tracebloc.controlPlaneRepository).

requests-proxy runs the jobs-manager IMAGE and, when it carries no honoured pin
of its own, follows the jobs-manager pin (tracebloc.effectivePin).
*/}}
{{- define "tracebloc.controlPlaneImages" -}}
{"jobsManager":"tracebloc/jobs-manager","podsMonitor":"tracebloc/pods-monitor","resourceMonitor":"tracebloc/resource-monitor","requestsProxy":"tracebloc/jobs-manager"}
{{- end -}}

{{- define "tracebloc.controlPlaneRepository" -}}
{{- $repos := include "tracebloc.controlPlaneImages" . | fromJson -}}
{{- $repo := index $repos (.image | default "") -}}
{{- if not $repo -}}
{{- fail (printf "tracebloc.controlPlaneRepository: %q is not a control-plane image key (known: %s) -- a template bug, not a values problem" (.image | default "") (keys $repos | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $repo -}}
{{- end -}}

{{/*
tracebloc.legacyPinRegistry — the registry a values pin is deemed resolved on
when `images.<image>.digestRegistry` is empty or absent: docker.io, the ONLY
registry the chart pulled the control-plane images from before the key
existed, so every pin written before it was, by construction, resolved there.
ONE literal; tracebloc.pinDeclaredRegistry is its only reader.
*/}}
{{- define "tracebloc.legacyPinRegistry" -}}
docker.io
{{- end -}}

{{/*
tracebloc.pinDeclaredRegistry — the registry a control-plane values pin claims
to have been resolved on: `images.<image>.digestRegistry`, else the legacy rule
above. Renders the bare host. Only meaningful beside a non-empty digest; the
NOTES.txt warning names it when a pin is ignored.
Usage: {{ include "tracebloc.pinDeclaredRegistry" (dict "image" "jobsManager" "root" $) }}
*/}}
{{- define "tracebloc.pinDeclaredRegistry" -}}
{{- $img := default dict (index (default dict .root.Values.images) .image) -}}
{{- $img.digestRegistry | default (include "tracebloc.legacyPinRegistry" .root) -}}
{{- end -}}

{{/*
tracebloc.pinFor — THE ONE decision: does this control-plane image render its
values digest pin, and to which digest? Renders the digest (`sha256:...`) when
the pin is HONOURED, nothing when there is no pin or the pin is IGNORED.

A digest names bytes on the registry it was resolved on. Nothing guarantees any
other registry ever held them, and a pod told to pull a digest its registry
does not have never starts -- so a pin resolved on one registry and rendered
onto another is not "the same image elsewhere", it is an unpullable reference.
That is how a digest pin outlived its registry: an operator pin resolved on
Docker Hub, the chart default moved to ghcr.io, the image site rendered
`ghcr.io/tracebloc/jobs-manager@sha256:<x>` for a digest ghcr.io never had, and
every auto-upgrade timed out and rolled back for two days -- one killed attempt
left the edge with no jobs-manager at all -- while the image-refresh script,
which by design never edits an operator pin, correctly reported the pin stale
and did nothing else.

THE RULE. A pin is honoured only on the registry it was resolved against:

  images.<image>.digest          the pin
  images.<image>.digestRegistry  the registry it was resolved on (bare host,
                                 spelled exactly as `images.traceblocRegistry`
                                 or `global.imageRegistry` would be)

  honoured  <=>  digest is non-empty AND digestRegistry == tracebloc.tbRegistry
                 (the registry this release actually pulls from)
  ignored   otherwise: the workload renders the channel tag, image-refresh
            treats the image as unpinned and re-pins it from the LIVE registry,
            and NOTES.txt carries a warning naming the image, the pin's registry
            and the effective one (tracebloc.ignoredPins).

LEGACY RULE. `digest` set and `digestRegistry` empty is a pin written before the
key existed. Every such pin was resolved on docker.io -- the only registry the
control-plane images were pulled from until then -- so it is read as
`digestRegistry: docker.io`: honoured when the effective registry is docker.io
(the documented rollback), ignored at the ghcr.io default. That IS the incident
case, and the fallback is the fix: on a registry that has no such digest, the
channel tag is the only reference that can pull.

NEVER `fail`. An install or auto-upgrade must not be blocked by a stale pin --
the tag is the safe state, and refusing to render would have wedged exactly the
fleet this exists to unwedge.

ONE FUNCTION, four consumers, so "pinned" and "rendered digest" cannot disagree:
  * tracebloc.controlPlaneImage           -> the image reference at every site
  * tracebloc.controlPlanePullPolicy      -> IfNotPresent on a pin
  * tracebloc.imageRefreshEnabled and
    tracebloc.resourceMonitorRefreshPinned -> whether the CronJob has work
  * image-refresh-cronjob.yaml env        -> the *_PINNED / *_PIN the script reads
The chart tests exercise the consumers; none of them re-derives the rule.

Nil-guarded on every dereference for `--reuse-values` replays that predate the
`images` block or the new key. Fails the render only on an unknown IMAGE KEY
(a template bug -- tracebloc.controlPlaneRepository), never on values.

Usage: {{ include "tracebloc.pinFor" (dict "image" "jobsManager" "root" $) }}
*/}}
{{- define "tracebloc.pinFor" -}}
{{- $_ := include "tracebloc.controlPlaneRepository" . -}}
{{- include "tracebloc.honouredPin" . -}}
{{- end -}}

{{/*
tracebloc.honouredPin — THE RULE ITSELF, with no control-plane membership
check: renders `images.<image>.digest` when it is non-empty AND
`tracebloc.pinDeclaredRegistry` equals the registry this release pulls from,
nothing otherwise. Every word of tracebloc.pinFor's contract above applies
here; pinFor is this function plus "and the key must be a control-plane image".

EXTRACTED, NOT COPIED (backend#3397, CLAUDE.md rule 9). D1 step 6 routes
`tracebloc/mysql-client` through tracebloc.tbRegistry like every other
tracebloc-published image, so a SECOND image outside the control-plane set now
needs the pin decision. Re-spelling `and $digest (eq ...)` at that site would
have been a copy of the rule that the mutation tests for pinFor cannot see --
break pinFor and the mysql site goes on rendering, green. One function, both
callers, so a change to the rule reaches both or neither.

Usage: {{ include "tracebloc.honouredPin" (dict "image" "mysqlClient" "root" $) }}
*/}}
{{- define "tracebloc.honouredPin" -}}
{{- $img := default dict (index (default dict .root.Values.images) .image) -}}
{{- $digest := $img.digest | default "" -}}
{{- if and $digest (eq (include "tracebloc.pinDeclaredRegistry" .) (include "tracebloc.tbRegistry" .root)) -}}
{{- $digest -}}
{{- end -}}
{{- end -}}

{{/*
tracebloc.pinIgnored — "1" when this image HAS a values digest pin that
tracebloc.pinFor did NOT honour (resolved on a registry this release does not
pull from), else "". The image-refresh CronJob reads it per image: an ignored
pin is NOT a fresh install -- the operator pinned this image on purpose and a
pinned image was never refreshed, so it carries no refresh annotation for that
reason, not because it was just born. The first tick after the pin is ignored
therefore re-pins the workload from the live registry instead of leaving it on
the channel tag until the next upstream digest change (the fresh-install skip
applied to the wrong case). Derived from the same decision as the render
(pinFor), so "ignored" here is exactly what NOTES reports and what the image
sites did.
Usage: {{ include "tracebloc.pinIgnored" (dict "image" "jobsManager" "root" $) }}
*/}}
{{- define "tracebloc.pinIgnored" -}}
{{- $img := default dict (index (default dict .root.Values.images) .image) -}}
{{- if and ($img.digest | default "") (not (include "tracebloc.pinFor" .)) -}}
1
{{- end -}}
{{- end -}}

{{/*
tracebloc.effectivePin — the digest a WORKLOAD renders: its own honoured pin
(tracebloc.pinFor), except that requests-proxy, which runs the jobs-manager
image, follows the honoured jobs-manager pin when it has no honoured pin of its
own -- so the two pods cannot run different builds of one image (the skew #569
closed). An IGNORED requests-proxy pin is not a pin, so it falls through to the
jobs-manager decision exactly like an empty one; that is what "follows the
jobs-manager pin" has always meant. Renders the digest or nothing.
Usage: {{ include "tracebloc.effectivePin" (dict "image" "requestsProxy" "root" $) }}
*/}}
{{- define "tracebloc.effectivePin" -}}
{{- $own := include "tracebloc.pinFor" . -}}
{{- if $own -}}
{{- $own -}}
{{- else if eq .image "requestsProxy" -}}
{{- include "tracebloc.pinFor" (dict "image" "jobsManager" "root" .root) -}}
{{- end -}}
{{- end -}}

{{/*
tracebloc.controlPlaneImage — the ONE image reference for a control-plane
workload: <tbRegistry>/<repository>@<effectivePin> when a pin is honoured,
<tbRegistry>/<repository>:<resolved CLIENT_ENV> otherwise. Every control-plane
image site calls this and nothing else, so no site can hand a raw
`.Values.images.<image>.digest` past the pin rule -- the shape that rendered
the unpullable reference. Third-party images keep calling tracebloc.image
directly; their digests have their own registry keys.
Usage: {{ include "tracebloc.controlPlaneImage" (dict "image" "jobsManager" "root" $) }}
*/}}
{{/*
tracebloc.controlPlaneSeedDigest — client-runtime#199. The digest a control-plane
image renders when it carries NO honoured operator pin (tracebloc.effectivePin is
empty), so a `helm upgrade` re-renders the digest image-refresh last applied
instead of reverting to the bare `:tag` — the #199 revert that dropped
image-refresh's out-of-band `kubectl set image` pin and, on a node with a stale
`:tag` layer, silently ran an OLD image.

Read from the LIVE workload spec, NOT the `last-refreshed-*` annotation: the live
spec IS what image-refresh actually applied, so this can never render a digest
the live spec has already moved past — which closes the flap-lockout DOWNGRADE
(annotations stuck at D0 while the workload runs D1; @shujaatTracebloc on #1013).

Gated on image-refresh being the update path (enabled AND resolvable) — the SAME
gate as controlPlanePullPolicy's IfNotPresent branch, so the pull policy and the
rendered reference cannot disagree. Returns a digest ONLY when the live ref is
`<tbRegistry>/<repository>@sha256:…` for THIS release's current registry; a bare
`:tag` (fresh install), an empty `lookup` (`helm template` / `helm diff` / the
first install), or a ref on a DIFFERENT registry (a mirror flip image-refresh has
not yet re-pinned) all yield "" → `:tag`, never a cross-registry ref the kubelet
rejects with InvalidImageName. The auto-upgrade SA that runs the upgrade `lookup`
already reads these workloads (its release-ns and node-agents Roles grant all
verbs), so this adds no RBAC and cannot hit the backend#2469 bootstrap lockout.

Args: (dict "image" <jobsManager|podsMonitor|requestsProxy|resourceMonitor> "root" $)
*/}}
{{- define "tracebloc.controlPlaneSeedDigest" -}}
{{- $root := .root -}}
{{- $imgKey := .image -}}
{{- if and (not (include "tracebloc.effectivePin" .)) (include "tracebloc.imageRefreshEnabled" $root) (include "tracebloc.imageRefreshResolvable" $root) -}}
{{- $kind := "Deployment" -}}
{{- $ns := $root.Release.Namespace -}}
{{- $name := printf "%s-jobs-manager" (include "tracebloc.fullname" $root) -}}
{{- $container := "api" -}}
{{- if eq $imgKey "podsMonitor" -}}{{- $container = "pods-monitor-container" -}}{{- end -}}
{{- if eq $imgKey "requestsProxy" -}}{{- $name = include "tracebloc.requestsProxyName" $root -}}{{- $container = "proxy" -}}{{- end -}}
{{- if eq $imgKey "resourceMonitor" -}}{{- $kind = "DaemonSet" -}}{{- $name = include "tracebloc.resourceMonitorName" $root -}}{{- $ns = $root.Values.nodeAgents.namespace.name -}}{{- $container = "tracebloc-resource-monitor" -}}{{- end -}}
{{- $wl := lookup "apps/v1" $kind $ns $name -}}
{{- if $wl -}}
{{- $live := "" -}}
{{- range $c := (dig "spec" "template" "spec" "containers" (list) $wl) -}}
{{- if eq (dig "name" "" $c) $container -}}{{- $live = (dig "image" "" $c) -}}{{- end -}}
{{- end -}}
{{- $prefix := printf "%s/%s@" (include "tracebloc.tbRegistry" $root) (include "tracebloc.controlPlaneRepository" .) -}}
{{- if hasPrefix $prefix $live -}}
{{- last (splitList "@" $live) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "tracebloc.controlPlaneImage" -}}
{{- $digest := include "tracebloc.effectivePin" . -}}
{{- if not $digest -}}{{- $digest = include "tracebloc.controlPlaneSeedDigest" . -}}{{- end -}}
{{- include "tracebloc.image" (dict "repository" (include "tracebloc.controlPlaneRepository" .) "tag" (include "tracebloc.clientEnv" .root) "digest" $digest "registry" (include "tracebloc.tbRegistry" .root)) -}}
{{- end -}}

{{/*
tracebloc.ignoredPins — one entry per control-plane pin that is SET but IGNORED
by tracebloc.pinFor (registry mismatch), for the NOTES.txt warning. Derived from
the same declaration (tracebloc.controlPlaneImages) and the same decision
(pinFor) the workloads use, so the warning cannot name a pin the render
honoured, nor miss one it dropped. Renders nothing when every pin is honoured
or absent. Call with the ROOT context.
*/}}
{{- define "tracebloc.ignoredPins" -}}
{{- $root := . -}}
{{- $eff := include "tracebloc.tbRegistry" $root -}}
{{- range $image := (include "tracebloc.controlPlaneImages" $root | fromJson | keys | sortAlpha) -}}
{{- $img := default dict (index (default dict $root.Values.images) $image) -}}
{{- if and $img.digest (not (include "tracebloc.pinFor" (dict "image" $image "root" $root))) }}
  - images.{{ $image }}.digest = {{ $img.digest }}
    resolved on {{ include "tracebloc.pinDeclaredRegistry" (dict "image" $image "root" $root) }}{{ if not $img.digestRegistry }} (digestRegistry unset -- a legacy pin, deemed docker.io){{ end }}; this release pulls from {{ $eff }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
tracebloc.ingestorDigest — the ONE effective digest for the spawned ingestor
image. Renders the digest to pin to, or nothing at all to float on
`images.ingestor.tag`. Every consumer of the ingestor image must go through
this helper so every consumer of the ingestor image (jobs-manager's spawned
ingestion Jobs, any manual backfill Job) agrees on which image is authoritative.

Precedence (most specific first):
  1. `images.ingestor.digest` non-empty  -> that digest, in ANY environment.
     The long-standing per-edge opt-in pin; unchanged semantics.
  2. otherwise the prod gate: `images.ingestor.prodPin` (default TRUE when the
     key is absent) AND the resolved CLIENT_ENV == "prod"  -> `prodDigest`.
  3. otherwise empty -> float on `tag` with imagePullPolicy=Always.

Why the gate is on CLIENT_ENV (backend#1245): dev and staging installs carry
`env.CLIENT_ENV: dev|stg` in their user-supplied values while the chart defaults
CLIENT_ENV to "prod", so this pins prod and floats non-prod with zero per-edge
action — and because `prodDigest` is a chart DEFAULT, a republished pin reaches
installed edges through `helm upgrade --reset-then-reuse-values` (the fleet
auto-upgrade path), which an install-time `-f` overlay never could.

`prodPin` defaults to TRUE when the key is absent so a `--reuse-values` upgrade
from a release predating the key still pins prod, rather than silently
defeating the pin. Every read is nil-guarded for the same reason.

Usage: {{ include "tracebloc.ingestorDigest" . }}
*/}}
{{/*
  Resolved CLIENT_ENV, with the documented aliases normalized to the
  canonical dev|stg|prod keys.

  ONE definition on purpose. Bugbot caught the first cut normalizing inside
  tracebloc.ingestorTag only, so CLIENT_ENV=production selected the prod
  float tag while tracebloc.ingestorDigest still compared the RAW value to
  "prod" and returned nothing -- silently dropping the reproducibility pin
  (backend#1028/#1245) on an edge that looked correctly configured. Any future
  consumer of CLIENT_ENV must go through here rather than re-deriving it, the
  same reason ENV_ALIASES lives once in client-runtime proxy_config.

  THE VOCABULARY IS CLOSED, and this is the second of two guards.

  values.schema.json carries the `enum` -- that is the primary gate and it
  gives the better error. This `fail` is the backstop: the enum is only checked
  where the packaged schema is read, and `helm template/install/upgrade
  --skip-schema-validation` skips it, as does a chart repackaged without the
  schema. This helper is the single chokepoint every consumer already goes
  through (see the paragraph above), so an unrecognized value that gets past
  the enum still cannot reach an image tag. Verified both ways in
  scripts/tests/chart-env-vocabulary.sh -- and it has to live there rather than
  in client/tests/: helm-unittest validates values against the packaged schema
  and reports a violation as a plugin-level ERROR, so `failedTemplate` cannot
  assert the enum, and it offers no flag to skip validation and reach this
  `fail`.

  WHY FAIL AT ALL, rather than pass the value through. Passing through was not
  a graceful degradation, it was a silent reconfiguration of the edge in four
  places at once -- three control-plane image tags pointing at tags no producer
  publishes, a missed `channelTags` lookup, a missed `serviceDbAccountsByEnv`
  lookup, and a dropped prod digest pin (the pin applies only where the env
  resolves to exactly "prod"). The only validator that existed was
  client-runtime jobs_manager.py's `sys.exit(1)` on "Unknown CLIENT_ENV", which
  lives INSIDE the container that cannot start, so it cannot help. Failing at
  `helm upgrade` is consistent with the chart's own conventions: it already
  fails on placeholder clientId, empty training CIDRs, non-alphanumeric service
  passwords, perDatasetPvcs without clusterScope, and a missing metrics API.
*/}}
{{/*
  Whether the dedicated tb_meta / tb_ingest DB identities are on for THIS edge
  (backend#1528, backend#1752).

  Resolution, highest first:
    1. `serviceDbAccounts` — an explicit operator override, true or false.
    2. `serviceDbAccountsByEnv[<resolved CLIENT_ENV>]` — the fleet default.

  WHY THIS IS KEYED ON THE ENVIRONMENT AT ALL. #1151 records the rollout as
  "flip per environment, dev first", but there was no mechanism for that: the
  value was one global boolean, so "per environment" meant editing every edge's
  values by hand and remembering which fleet was where. Nobody could see the
  fleet's posture in one place, and nothing tested it.

  That gap had teeth. data-ingestors#468 removed the ingestor's edgeuser
  fallback, making DB_USER/DB_PASSWORD required, on the stated precondition
  that this flag was "on fleet-wide". It was on nowhere. dev and staging edges
  float on the :dev/:stg ingestor channels, picked the change up the same day,
  and every ingestion Job now fails at Config() before reading a byte
  (backend#1752). Prod escaped only because its ingestor is digest-pinned to
  the 0.7 line -- a caution engineered for D16, not for this, and one that
  client#490 is about to spend.

  Resolving through `tracebloc.clientEnv` (not the raw value) so a documented
  alias like `staging` maps to `stg` and cannot silently miss its entry --
  backend#1723 was exactly that failure.
*/}}
{{- define "tracebloc.serviceDbAccounts" -}}
{{- $override := (default dict .Values).serviceDbAccounts -}}
{{- if not (kindIs "invalid" $override) -}}
{{- if $override }}true{{ end -}}
{{- else -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- $byEnv := default dict .Values.serviceDbAccountsByEnv -}}
{{- if get $byEnv $env }}true{{ end -}}
{{- end -}}
{{- end }}

{{/*
  Whether jobs-manager mints a throwaway MySQL account per experiment
  (backend#1528 D10) for THIS edge.

  Resolves identically to tracebloc.serviceDbAccounts / bootstrapDbReparent /
  tracebloc.rotateMysqlRoot -- operator override first, else the
  per-environment default -- and shares the CLIENT_ENV normalization
  (backend#1723) so a documented alias like `staging` cannot silently miss its
  entry.

  WHY IT WAS THE ODD ONE OUT, AND WHY THAT MATTERED. Every other gate in this
  rollout resolved through a helper with a `…ByEnv` map; this one was read as a
  bare `.Values.perExperimentDbCreds` in five templates. So the flag that
  backend#1528's LAST step is gated on was the one flag whose fleet posture the
  chart could not record. A fleet that had been taken to the per-experiment
  credential shape held that fact only in its stored release values, where a
  values-resetting upgrade drops it -- and dropping it puts the account mint
  back on edgeuser, the account the whole ticket exists to retire.
*/}}
{{- define "tracebloc.perExperimentDbCreds" -}}
{{- $override := (default dict .Values).perExperimentDbCreds -}}
{{- if not (kindIs "invalid" $override) -}}
{{- if $override }}true{{ end -}}
{{- else -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- $byEnv := default dict .Values.perExperimentDbCredsByEnv -}}
{{- if get $byEnv $env }}true{{ end -}}
{{- end -}}
{{- end }}

{{/*
  Whether to re-parent the account-minting bootstrap off edgeuser onto MySQL
  root (backend#1528 S3). Resolves identically to tracebloc.serviceDbAccounts —
  operator override first, else the per-environment default — so the fleet's S3
  posture reads out of one place the same way, and the CLIENT_ENV normalization
  (backend#1723) is shared. This is the LAST, edgeuser-retiring step. dev has run
  the whole ladder and its posture is verified, so a fresh dev install
  should come up retired rather than re-walk the flips by hand. Now baked ON for
  dev, stg and prod (all three fleets retired) -- but on the baked path it resolves
  on ONLY for a fresh or already-rotated edge (tracebloc.bakedRootRotationOn),
  exactly like rotateMysqlRoot, so a baked default re-parents a fresh install while
  leaving an existing un-rotated (blind) edge alone rather than hard-failing its
  render. It MUST move in lockstep with rotate: reparent derives DB_BOOTSTRAP_PASSWORD
  from the rotation (backend#2738), so gating both on the same helper keeps them
  consistent -- reparent=true with rotate=false has no password to fall back on and
  hard-fails the render. An explicit override is unchanged (the manual path).
*/}}
{{- define "tracebloc.bootstrapDbReparent" -}}
{{- $override := (default dict .Values).bootstrapDbReparent -}}
{{- if not (kindIs "invalid" $override) -}}
{{- if $override }}true{{ end -}}
{{- else -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- $byEnv := default dict .Values.bootstrapDbReparentByEnv -}}
{{- /* Baked reparent follows rotate's RESOLVED value, not bakedRootRotationOn
       directly: reparent derives DB_BOOTSTRAP_PASSWORD from the rotation
       (backend#2738), so it must be on iff rotate is on. Gating on
       bakedRootRotationOn alone left reparent baked-on when an operator explicitly
       set rotateMysqlRoot=false on an already-rotated edge (Secret still holds
       MYSQL_ROOT_PASSWORD), and reparent then hard-failed the render with no
       password to derive -- caught by the k3d auto-upgrade e2e's rotation-off
       restore. Following the resolved rotate value keeps them in lockstep in every
       case: fresh->on, blind/un-rotated->off, and explicit rotate-off->off. */ -}}
{{- if and (get $byEnv $env) (include "tracebloc.rotateMysqlRoot" .) }}true{{ end -}}
{{- end -}}
{{- end }}

{{/*
  Whether to narrow edgeuser to USAGE only at jobs-manager startup (backend#1528
  S3 close-out). Resolves identically to its three siblings -- operator override
  first, else the per-environment default -- sharing the CLIENT_ENV normalization
  (backend#1723).

  WHAT IT IS FOR. mysql-client-initdb/10-edgeuser-bridge-grants.sql re-grants
  edgeuser its broad privileges at every FRESH datadir init and cannot branch on a
  runtime flag: it is COPYd into a digest-frozen image and the mysql entrypoint
  runs it before jobs-manager exists. So a fleet that completed the whole
  retirement can be handed a root-equivalent edgeuser again by a reinstall, with
  nothing to notice it by. With this on, jobs-manager REVOKEs it back to USAGE on
  every boot -- so the retired posture is self-sustaining rather than a property
  of the last person who ran a REVOKE by hand.

  It REVOKES; it never DROPs. The account keeps existing with USAGE only, which is
  reversible from the S0 SHOW GRANTS snapshot. DROP USER stays an operator step.

  BAKED ON FOR dev, stg AND prod, and the pairing below is enforced
  rather than documented: this is the last step of the last stage, so it is only
  legal where every predecessor gate is already on -- which every fleet now is
  (backend#947, the consumer migration off edgeuser verified live on stg and prod),
  so all three carry it as a default. The conditional below still declines the
  default on any edge whose posture is incomplete, so a single-gate override does
  not hard-fail the render.
*/}}
{{- define "tracebloc.narrowEdgeuser" -}}
{{- $override := (default dict .Values).narrowEdgeuser -}}
{{- if not (kindIs "invalid" $override) -}}
{{- /*
    EXPLICIT REQUEST: honoured as given, and refused LOUDLY by
    tracebloc.assertNarrowEdgeuserIsSafe if the posture cannot carry it. An
    operator who typed this flag gets an answer, never a silent no-op.
  */ -}}
{{- if $override }}true{{ end -}}
{{- else -}}
{{- /*
    BAKED DEFAULT: tracks the posture instead of asserting over it.
    A default says "a retired fleet narrows", and narrowing is a CONSEQUENCE of
    being retired, not an independent choice. So the default is conditional on
    the three predecessors, and an operator who steps back from the posture on one
    edge -- `perExperimentDbCreds=false` while debugging, say -- simply stops
    narrowing. They do not have to discover a second flag they never set.
    A flat `true` here made every single-gate override on a baked environment a
    HARD RENDER FAILURE (found by baking dev: it broke 5 chart tests and the
    gate-byenv-resolution guard, which renders each gate OFF by design).
    Silence is the safe direction here and only here: NOT narrowing leaves
    edgeuser's grants intact and breaks nothing, while narrowing too early
    degrades the heartbeat silently. The dangerous direction is still refused.
  */ -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- $byEnv := default dict .Values.narrowEdgeuserByEnv -}}
{{- if get $byEnv $env -}}
{{-   if and (include "tracebloc.bootstrapDbReparent" .) (include "tracebloc.serviceDbAccounts" .) (include "tracebloc.perExperimentDbCreds" .) -}}
true
{{-   end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
  Refuse a narrowing that this fleet cannot survive, AT RENDER TIME.

  jobs-manager refuses the same combinations at startup with a RuntimeError, and
  that refusal is the real safety net. This one exists because the render happens
  BEFORE the Deployment is patched: an operator who mis-pairs the gates gets
  `helm upgrade` refusing, rather than a CrashLooping jobs-manager on a fleet
  whose previous pod has already been terminated.

  Each condition is a way narrowing would break a consumer still authenticating
  as edgeuser -- and because the heartbeat's information_schema enumeration is
  privilege-filtered, over-revoking does not error, it silently stops returning
  datasets. That is why "the operator asked for it" is not sufficient.
*/}}
{{- define "tracebloc.assertNarrowEdgeuserIsSafe" -}}
{{- /*
    Asserts over the RESOLVED value, deliberately, and that is the whole reason it
    still exists. tracebloc.narrowEdgeuser already declines when a BAKED default
    meets an incomplete posture, so in practice this fires only for an explicit
    `.Values.narrowEdgeuser: true` -- which makes it look redundant, and a mutation
    confirmed no test can tell the two apart today.
    It is kept resolved-value-scoped anyway: scoping it to the explicit override
    would mean that if the resolver were ever made unconditional again, a baked
    default with a broken posture would render NARROW_EDGEUSER=1 with NOTHING
    checking it -- the dangerous case, silently. One mechanism guarding the other
    beats two mechanisms where the second can disable the first.
  */ -}}
{{- if (include "tracebloc.narrowEdgeuser" .) -}}
{{-   $missing := list -}}
{{-   if not (include "tracebloc.bootstrapDbReparent" .) -}}
{{-     $missing = append $missing "bootstrapDbReparent is off, so the account-minting bootstrap still authenticates AS edgeuser -- the REVOKE would strip the privileges of the connection issuing it, mid-flight" -}}
{{-   end -}}
{{-   if not (include "tracebloc.serviceDbAccounts" .) -}}
{{-     $missing = append $missing "serviceDbAccounts is off, so the metadata and dataset data plane still connects as edgeuser" -}}
{{-   end -}}
{{-   if not (include "tracebloc.perExperimentDbCreds" .) -}}
{{-     $missing = append $missing "perExperimentDbCreds is off, so training pods still receive the shared edgeuser credential" -}}
{{-   end -}}
{{-   if $missing -}}
{{-     fail (printf "narrowEdgeuser is on but this fleet is not ready to narrow edgeuser (backend#1528 S3). Blocking reasons: %s. Narrowing now would break a live consumer, and because the heartbeat's information_schema enumeration is privilege-filtered it would degrade SILENTLY rather than error -- datasets would simply stop being listed. Complete the posture first (serviceDbAccounts, then perExperimentDbCreds, then bootstrapDbReparent, verified per fleet with docs/migration-tools/edgeuser-drop-readiness.sh), or leave narrowEdgeuser off." (join "; " $missing)) -}}
{{-   end -}}
{{- end -}}
{{- end }}

{{/*
  Whether a BAKED-DEFAULT rotateMysqlRoot / bootstrapDbReparent may resolve ON for
  THIS render without wedging an existing un-rotated edge (backend#947; @LukasWodka
  sign-off 2026-09-02; pre-marker case backend#3189). Consulted ONLY on the
  baked-default path -- an explicit operator override bypasses this and keeps the
  backend#2879 fail-closed guard (the deliberate manual-rotation path for our own
  accessible existing clusters).

  The cases, per the sign-off:
    - ALREADY born rotated -- the marker ConfigMap (tracebloc.mysqlRootRotatedMarker)
      is present -> ON. This is the case the PVC alone could not see, and getting it
      wrong is a ONE-WAY DOOR (backend#947, @LukasWodka): a fresh stg/prod install
      born-rotates and mints root into the Secret, but the chart also CREATES the
      mysql-pvc on that first install (resource-policy: keep), so a PVC-only freshness
      test flips OFF on the very next auto-upgrade -- rotate/reparent both resolve off,
      secrets.yaml stops emitting MYSQL_ROOT_PASSWORD/DB_BOOTSTRAP_PASSWORD, root's
      generated password is lost and jobs-manager reverts to minting as edgeuser (the
      posture this PR retires). The marker is written iff rotation resolved on (see
      mysql-root-rotated-marker.yaml), under a CONSTANT name so this lookup is
      rename-safe.
    - ALREADY rotated BEFORE the marker shipped (backend#3189) -- the live Secret
      carries a baked MYSQL_ROOT_PASSWORD, minted under the EARLIER
      serviceDbAccountsByEnv / rotateMysqlRootByEnv bake, but no marker was ever laid
      down: that mechanism post-dates the rotation, so those edges never got one.
      -> ON. The marker `lookup` is blind to them; without this case the marker/PVC/
      cluster arms all read "not rotated" on their next auto-upgrade and trip the same
      one-way door described above -- a SILENT loss of root on fleets that were
      already rotated. The live Secret's MYSQL_ROOT_PASSWORD key is the only signal
      that separates such an edge from an existing un-rotated one, so it is read here
      (see the refusal in the define for why that Secret lookup is rename-safe). This
      render also resolves rotation on, so it lays the marker down -- backfilling it,
      after which every later render resolves via the rename-safe marker arm instead.
    - NEW / fresh datadir on a live cluster (no marker yet, no mysql-pvc, no baked
      root, kube-system visible) -> ON. The tier-3 mint in secrets.yaml generates root
      into the Secret, the edge is born rotated, and this same render lays down the
      marker so every later render stays on.
    - EXISTING datadir (mysql-pvc present, no marker, no baked root in the Secret), OR
      a BLIND / cluster-less render that cannot prove the datadir fresh -> OFF. Fall
      back to the edge's existing password (the image-baked literal); no mint, no wedge.

  An accessible existing edge we DO want rotated carries an explicit
  `rotateMysqlRoot=true` override (the manual-rotation path -- how dev and edge 713
  hold it), which bypasses this helper entirely, so its rotated posture is preserved
  by the override, not re-derived here.

  A tier-1 `mysqlRootPassword` PIN also resolves ON: it is an explicit operator
  assertion of root's password (deterministic, no tier-3 mint), so it is the
  cluster-less/blind way to opt a fleet into rotation and it keeps this decidable
  under `helm template` / helm-unittest (backend#2892's existing escape hatch).
*/}}
{{- define "tracebloc.bakedRootRotationOn" -}}
{{- if .Values.mysqlRootPassword -}}
true
{{- else -}}
{{- $marker := (lookup "v1" "ConfigMap" .Release.Namespace (include "tracebloc.mysqlRootRotatedMarker" .)) -}}
{{- $pvc := (lookup "v1" "PersistentVolumeClaim" .Release.Namespace (include "tracebloc.mysqlPvc" .)) -}}
{{- $clusterVisible := (lookup "v1" "Namespace" "" "kube-system") -}}
{{- $secret := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.secretName" .)) -}}
{{- /*
    The datadir's presence, live OR declared. `mysqlDatadirExists` is the same
    values-level surrogate secrets.yaml's root-mint guard uses (backend#2892): it
    OR-s the live PVC `lookup` so this arm is provable under `helm template` /
    helm-unittest and also covers a LIVE render whose PVC `lookup` cannot see the
    datadir (a not-yet-bound or renamed claim the operator knows exists).
*/ -}}
{{- $datadirPresent := (or $pvc .Values.mysqlDatadirExists) -}}
{{- if and $marker (not .Values.mysqlRootRotationAcknowledged) -}}
{{- /*
    BORN-ROTATED, looked up FIRST (backend#947, backend#3226). The marker is
    written under a CONSTANT name and kept across a helm uninstall
    (resource-policy: keep), so it is the rename-safe "already rotated" signal.
    Consulting it BEFORE the datadir/Secret refusal below means a reinstall over a
    kept datadir whose marker survived resolves ON from the marker and never trips
    the refusal on the Secret that the uninstall deleted.

    GATED ON `mysqlRootRotationAcknowledged` (backend#3255). This marker
    (resource-policy: keep) can OUTLIVE the rotation it recorded: an old,
    pre-rotation Secret restored over a datadir whose marker survived leaves the
    marker present but the Secret without MYSQL_ROOT_PASSWORD. Treating the marker as
    absolute there armed rotation the ack could not clear, and secrets.yaml then
    minted a root password the live database never accepted (1045). With the ack SET
    the marker no longer forces ON: control falls through to the Secret-evidence arms
    below, which keep a still-provably-rotated edge ON (its baked Secret) but resolve
    OFF when the marker's rotation is no longer backed by the Secret -- leaving that
    edge image-baked, the ack's documented meaning. UNSET, the marker still wins (the
    safe born-rotated default), so backend#947 / backend#3189 are unchanged.

    This is NOT the deleted-Secret reinstall guard: secrets.yaml's credential-
    collision refusal (backend#2571) already owns a LIVE render with mysql-pvc
    present and the Secret GONE (copy it back to the name this render wants, or delete
    the datadir), independently of this ack. And the ack makes the SURVIVING marker
    yield WITHOUT deleting it, so an image-baked edge is durable only while the ack
    stays set unless the operator also deletes the leftover marker AND clears the ack
    afterwards (it does not self-expire and replays through --reset-then-reuse-values;
    values.yaml documents both, and why a left-set ack stops the marker backstopping
    a later root-key loss).
*/ -}}
true
{{- else -}}
{{- /*
    RENAME-SAFE BY REFUSAL, not by avoidance (backend#3189). The Secret's name
    follows fullnameOverride, so a rename moves it and a bare `lookup` would MISS
    and silently read "not rotated" -- exactly the reason the born-rotated signal
    was first recorded in a constant-named marker instead of the Secret. With no
    marker (a pre-marker rotated edge, or a genuinely un-rotated one) the Secret is
    the only signal left; it is read WITH the refusal that turns that silent miss
    into a loud fail. If the datadir is present but no Secret resolves under the
    current name, that is a rename, or a reinstall over a kept datadir whose
    uninstall deleted the Secret. GATED ON `mysqlRootRotationAcknowledged`: that
    flag clears ALL of the guard's refuse arms (values.yaml -- the same three in
    secrets.yaml's mint), this one included, so an operator reinstalling over a kept
    datadir of an UN-ROTATED edge (no marker, Secret gone) can acknowledge and
    proceed on the image-baked password instead of being wedged (backend#3226).
    This is also what scripts/tests/fullname-override-completeness.sh (backend#2626)
    requires of any Secret lookup keyed on the override-following name. Inert on
    every legitimate render: a fresh install has no datadir, an ordinary upgrade has
    the Secret, and a cluster-less render (helm template / helm-unittest / GitOps)
    has neither the PVC nor the Secret, so none of them fail here.
*/ -}}
{{- if and $datadirPresent (not $secret) (not .Values.mysqlRootRotationAcknowledged) -}}
{{-   fail (printf "release %q in namespace %q has MySQL data (PersistentVolumeClaim %q) but no Secret named %q -- the name this render resolves to -- and no born-rotated marker. bakedRootRotationOn cannot read root's rotation state from a Secret that is not there, and treating the miss as \"not rotated\" would drop MYSQL_ROOT_PASSWORD and revert jobs-manager to the root-equivalent edgeuser this epic retires. TWO CAUSES look like this. (1) A RENAME (fullnameOverride changed on a live release): the Secret still exists under the OLD name -- copy it to the name this render wants, then re-run (secrets.yaml prints the exact kubectl/jq command), or put fullnameOverride back to the value this release was last rendered with. (2) A REINSTALL over a kept datadir whose uninstall DELETED the Secret (docs/MIGRATIONS.md): there is no Secret to copy. A born-rotated edge keeps its marker across the uninstall and this render resolves rotated from it; an un-rotated edge has no marker, so set mysqlRootRotationAcknowledged=true to proceed on the image-baked password -- the ack clears this arm the same way it clears the secrets.yaml mint arms. See docs/MIGRATIONS.md." .Release.Name .Release.Namespace (include "tracebloc.mysqlPvc" .) (include "tracebloc.secretName" .)) -}}
{{- end -}}
{{- /*
    PRE-MARKER ROTATED (backend#3189): the live Secret already carries a baked
    MYSQL_ROOT_PASSWORD, minted under the EARLIER serviceDbAccountsByEnv /
    rotateMysqlRootByEnv bake, but no marker was ever laid down -- that mechanism
    post-dates the rotation. Same `and $secret $secret.data (hasKey ...)` shape as
    secrets.yaml's tier-2 reads, so an empty offline lookup is nil-safe.
*/ -}}
{{- $bakedRoot := (and $secret $secret.data (hasKey $secret.data "MYSQL_ROOT_PASSWORD")) -}}
{{- if $bakedRoot -}}
true
{{- else if and $clusterVisible (not $datadirPresent) -}}
true
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
  Whether the chart manages the mysql-client root password from a generated
  Secret instead of the image's baked default (backend#947 / backend#1528 Phase
  0). Operator override first (unchanged -- the manual-rotation path, still guarded
  by backend#2879); else the per-environment default, AND ONLY on a fresh or
  already-rotated edge (tracebloc.bakedRootRotationOn). Baked TRUE for dev, stg and
  prod now that all three fleets are retired -- but the datadir gate means a baked
  default born-rotates a fresh install while leaving an existing un-rotated (blind)
  edge on its current password rather than wedging its render. An existing edge we
  can reach is rotated by the explicit override + the one-time `ALTER USER 'root'`.
*/}}
{{- define "tracebloc.rotateMysqlRoot" -}}
{{- $override := (default dict .Values).rotateMysqlRoot -}}
{{- if not (kindIs "invalid" $override) -}}
{{- if $override }}true{{ end -}}
{{- else -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- $byEnv := default dict .Values.rotateMysqlRootByEnv -}}
{{- if and (get $byEnv $env) (include "tracebloc.bakedRootRotationOn" .) }}true{{ end -}}
{{- end -}}
{{- end }}

{{/*
  RFC-0076 settings-naming (S3): TRACEBLOC_ENV is the canonical name for this
  var, CLIENT_ENV the legacy one. Read alias-first -- a non-empty
  env.TRACEBLOC_ENV wins, else a non-empty env.CLIENT_ENV, else "prod" -- so a
  customer values file that still says CLIENT_ENV keeps rendering unchanged.
  A BLANK value on either name is "unset", same as before this alias existed
  (env.CLIENT_ENV="" has always meant prod, per the schema's own closed enum
  and chart-env-vocabulary.sh; TRACEBLOC_ENV="" gets the identical treatment,
  not the stricter "present-but-blank fails validation" some other RFC-0076
  readers use, because that would change an existing, tested contract).
  remove_by: 2026-12-31, after which only TRACEBLOC_ENV is read.
*/}}
{{- define "tracebloc.clientEnv" -}}
{{- $envVals := default dict .Values.env -}}
{{- $source := "TRACEBLOC_ENV (defaulted)" -}}
{{- if $envVals.TRACEBLOC_ENV -}}
{{- $source = "TRACEBLOC_ENV" -}}
{{- else if $envVals.CLIENT_ENV -}}
{{- $source = "CLIENT_ENV" -}}
{{- end -}}
{{- $raw := $envVals.TRACEBLOC_ENV | default $envVals.CLIENT_ENV | default "prod" -}}
{{- $aliases := dict "development" "dev" "staging" "stg" "production" "prod" -}}
{{- $resolved := $raw -}}
{{- if hasKey $aliases $raw -}}
{{- $resolved = get $aliases $raw -}}
{{- end -}}
{{- if not (has $resolved (list "dev" "stg" "prod")) -}}
{{- fail (printf "env.%s: %q is not a recognized environment. Accepted: dev, stg, prod (canonical) or development, staging, production (aliases); empty/unset means prod. This value is the tag for the jobs-manager, pods-monitor and resource-monitor images, and it keys images.ingestor.channelTags, serviceDbAccountsByEnv and the prod digest pin -- an unrecognized value would pull unpublished tags, miss every one of those lookups and silently drop the pin. Note dev/stg are abbreviated: `develop` and `production` differ, and only the six listed spellings resolve." $source $raw) -}}
{{- end -}}
{{- $resolved -}}
{{- end }}

{{/*
  Effective floating tag for spawned ingestion Jobs (backend#1360).

  Precedence, mirroring tracebloc.ingestorDigest:
    1. `images.ingestor.tag`          explicit override, any environment
    2. `images.ingestor.channelTags[CLIENT_ENV]`   per-environment channel
    3. `$fallbacks[CLIENT_ENV]`       last-resort literals, so a release that
                                      predates these keys still renders under
                                      `--reuse-values`

  Only consulted when no digest applies: jobs-manager builds `repo@digest`
  when tracebloc.ingestorDigest is non-empty, and `repo:tag` otherwise
  (client-runtime submit_ingestion_run._build_image_reference).

  dev/stg resolve to the UNSIGNED internal channels. Prod is a semver float,
  not a `:prod` tag — none is published.

  WHY THE FALLBACK IS KEYED ON THE ENVIRONMENT, not a single literal.

  This used to be a bare `"0.8"` for every environment, which made a dev or
  staging edge whose `channelTags` are absent — the `--reuse-values` replay
  this branch exists for — spawn the PROD line. That inverts the entire point
  of backend#1360: dev/stg channels exist so an ingestor change can be
  validated on a real edge without a prod release, and an edge silently
  validating prod's image reports on the wrong artifact. It also crosses the
  signing boundary in the safe direction only by accident.

  It is worse than a wrong tag today. The prod float has moved past the
  ordering ceiling documented at values.yaml `prodDigest` (backend#1853): the
  0.8 line no longer carries the ingestor's `edgeuser` DB_USER default that
  data-ingestors#468 removed. `serviceDbAccountsByEnv` supplies DB_USER on
  dev/stg, so those two survive it — but the coupling is accidental, and the
  same literal is what an out-of-vocabulary CLIENT_ENV lands on, where
  `serviceDbAccountsByEnv` misses too and nothing supplies DB_USER. That is
  backend#1752 reconstructed from a typo.

  KEEP THE `prod` ENTRY IN SYNC with values.yaml `channelTags.prod`. It is a
  second copy of the same float and there is no way to read the first from
  here: `--reuse-values` (unlike `--reset-then-reuse-values`) does not adopt
  new chart defaults, so a values lookup would be nil on exactly the releases
  this branch serves. ingestor_channel_tag_test.yaml pins both, so a bump that
  touches only one fails CI rather than drifting.
*/}}
{{- define "tracebloc.ingestorTag" -}}
{{- $ing := default dict .Values.images.ingestor -}}
{{- $explicit := $ing.tag | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $clientEnv := include "tracebloc.clientEnv" . -}}
{{- $channels := default dict $ing.channelTags -}}
{{- $channel := get $channels $clientEnv | default "" -}}
{{- if $channel -}}
{{- $channel -}}
{{- else -}}
{{- $fallbacks := dict "dev" "dev" "stg" "stg" "prod" "0.8" -}}
{{- get $fallbacks $clientEnv | default "0.8" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "tracebloc.ingestorDigest" -}}
{{- $ing := default dict .Values.images.ingestor -}}
{{- $explicit := $ing.digest | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $prodPin := true -}}
{{- if hasKey $ing "prodPin" -}}
{{- $prodPin = $ing.prodPin -}}
{{- end -}}
{{- $clientEnv := include "tracebloc.clientEnv" . -}}
{{- if and $prodPin (eq $clientEnv "prod") -}}
{{- $ing.prodDigest | default "" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
tracebloc.proxyEnv — corporate-proxy env for egress-needing workloads.
Derives HTTP(S)_PROXY + an auto-augmented NO_PROXY from .Values.env.HTTP_PROXY_*
so workload pods can reach the backend / registries through a corporate proxy.
Renders nothing when HTTP_PROXY_HOST is unset (non-proxy installs unchanged).
NO_PROXY always carries the cluster-internal ranges so in-cluster + MySQL
traffic never traverses the proxy (mirrors scripts/lib/cluster.sh defaults).
Usage inside a container's env: list:
  {{- include "tracebloc.proxyEnv" . | nindent 8 }}
*/}}
{{- define "tracebloc.proxyEnv" -}}
{{- if .Values.env.HTTP_PROXY_HOST }}
{{- $host := .Values.env.HTTP_PROXY_HOST -}}
{{- $port := .Values.env.HTTP_PROXY_PORT | default "" -}}
{{- $user := .Values.env.HTTP_PROXY_USERNAME | default "" -}}
{{- $pass := .Values.env.HTTP_PROXY_PASSWORD | default "" -}}
{{- $hostport := $host -}}
{{- if $port }}{{- $hostport = printf "%s:%v" $host $port -}}{{- end -}}
{{- $cred := "" -}}
{{- if $user }}{{- $cred = printf "%s:%s@" $user $pass -}}{{- end -}}
{{- $url := printf "http://%s%s" $cred $hostport -}}
{{- $noProxy := "localhost,127.0.0.1,0.0.0.0,169.254.169.254,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local,host.k3d.internal" -}}
{{- with .Values.env.NO_PROXY }}{{- $noProxy = printf "%s,%s" . $noProxy -}}{{- end }}
- name: HTTP_PROXY
  value: {{ $url | quote }}
- name: HTTPS_PROXY
  value: {{ $url | quote }}
- name: http_proxy
  value: {{ $url | quote }}
- name: https_proxy
  value: {{ $url | quote }}
- name: NO_PROXY
  value: {{ $noProxy | quote }}
- name: no_proxy
  value: {{ $noProxy | quote }}
{{- end }}
{{- end -}}

{{/*
tracebloc.mysqlEngineMajor — the MySQL engine major the chart is about to run,
for the mysql-format-guard init container (backend#723). Resolution mirrors
tracebloc.image's digest-wins precedence:
  digest set   -> the known 5.7-lineage pin maps to "5.7"; any other digest is
                  "unknown" (custom pin — the guard stands down).
  digest empty -> derive from the tag: ""/prod/5.7* -> 5.7, 8.4* -> 8.4,
                  8.0* -> 8.0, anything else -> unknown.
The sha256 literal below MUST equal the images.mysqlClient.digest default in
values.yaml — mysql_test.yaml pins the default render to "5.7", so re-pinning
the digest without updating this helper fails CI instead of silently
disarming the guard.
*/}}
{{- define "tracebloc.mysqlEngineMajor" -}}
{{- $digest := .Values.images.mysqlClient.digest | default "" -}}
{{- $tag := .Values.images.mysqlClient.tag | default "prod" -}}
{{- if $digest -}}
{{- if eq $digest "sha256:f546e47fb339e0982c902cef063b081ccf2cbbaf35b475287d583b9bf3163354" -}}
5.7
{{- else -}}
unknown
{{- end -}}
{{- else if or (eq $tag "prod") (hasPrefix "5.7" $tag) -}}
5.7
{{- else if hasPrefix "8.4" $tag -}}
8.4
{{- else if hasPrefix "8.0" $tag -}}
8.0
{{- else -}}
unknown
{{- end -}}
{{- end -}}

{{/*
tracebloc.durationSeconds — parse a Go/Helm duration string (as accepted by
`helm --timeout`, e.g. "10m", "30m", "1h", "600s", "1h30m") into a whole
number of seconds. Sums every `<int><unit>` component so compound durations
work; recognises s/m/h/d, ignores anything else. Empty/nil input -> 0.
Used by auto-upgrade-cronjob.yaml (#555) so the Job's activeDeadlineSeconds
can be kept above the configured helm timeout.
*/}}
{{- define "tracebloc.durationSeconds" -}}
{{- $d := . | toString -}}
{{- $total := 0 -}}
{{- range regexFindAll "[0-9]+[smhd]" $d -1 -}}
{{- $num := regexFind "[0-9]+" . | atoi -}}
{{- $unit := regexFind "[smhd]" . -}}
{{- if eq $unit "s" -}}{{- $total = add $total $num -}}
{{- else if eq $unit "m" -}}{{- $total = add $total (mul $num 60) -}}
{{- else if eq $unit "h" -}}{{- $total = add $total (mul $num 3600) -}}
{{- else if eq $unit "d" -}}{{- $total = add $total (mul $num 86400) -}}
{{- end -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{/*
  tracebloc.telemetryCollectorName — the edge Collector's resource name
  (backend#1906). Same shape as tracebloc.resourceMonitorName: release-scoped, so
  two releases on one cluster do not collide in the shared node-agents namespace.
*/}}
{{- define "tracebloc.telemetryCollectorName" -}}
{{- printf "%s-telemetry-collector" (include "tracebloc.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  tracebloc.telemetryStatusName — the ConfigMap that records what the Collector
  decided, and why (templates/telemetry-collector-status.yaml). ONE resolver for
  its two readers: the status template that writes it and the auto-upgrade
  CronJob that reads it back out of the stored release manifest to decide whether
  a same-version re-render is due (backend#3550). Deliberately NOT under the
  `telemetry-collector` prefix — see the status template for why five shell gates
  depend on that.
*/}}
{{- define "tracebloc.telemetryStatusName" -}}
{{- printf "%s-telemetry-status" (include "tracebloc.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  tracebloc.telemetryStateAnnotation — the annotation key the status ConfigMap
  carries its resolved state under. Shared by the writer (status template) and the
  reader (auto-upgrade script, which greps it out of `helm get manifest` and out of
  a server-side dry-run render) so the two cannot disagree about the spelling.
*/}}
{{- define "tracebloc.telemetryStateAnnotation" -}}
tracebloc.io/telemetry-collector-state
{{- end -}}

{{/*
  tracebloc.telemetryTokenLegacyName — the pre-backend#2625 fixed Secret name.

  It has TWO temporary jobs, and it is the single source for both so they cannot
  drift apart: it is the sentinel that tracebloc.telemetryTokenSecretName rewrites
  to a release-scoped name (below), and it is the name the daemonset's pre-flight
  ALSO accepts while an edge is mid-migration and jobs-manager has not yet written
  the release-scoped Secret (telemetry-collector-daemonset.yaml).

  REMOVAL CONDITION — this helper AND the daemonset's legacy acceptance are deleted
  together, once no edge still holds a Secret under this name: every collecting edge
  has upgraded past the chart that introduced the release-scoped write (backend#2625)
  AND jobs-manager has re-authenticated at least once on each, populating the
  release-scoped Secret. That state is observable as the absence of any
  `tracebloc-telemetry-token` Secret across the fleet's node-agents namespaces
  (`kubectl get secret -A --field-selector metadata.name=tracebloc-telemetry-token`).
  Deleting it before then re-wedges exactly the edge acceptance (b) protects — the
  backend#2400 deadlock in a new costume: the pre-flight would look only for the
  release-scoped name, find nothing (jobs-manager has not written it yet), and
  refuse the upgrade on the one edge already collecting.
*/}}
{{- define "tracebloc.telemetryTokenLegacyName" -}}
tracebloc-telemetry-token
{{- end -}}

{{/*
  tracebloc.telemetryTokenSecretName — the name of the Secret jobs-manager writes
  the edge Collector's ingest token into, and that the Collector then mounts and
  reads (backend#2274). The one resolver behind all four consumers — the writer's
  env, the reader's guard and volume, and the RBAC resourceName — so they cannot
  disagree about which Secret they mean (scripts/tests/telemetry-token-agreement.sh).

  RELEASE-SCOPED (backend#2625). The name used to be a fixed
  `tracebloc-telemetry-token` in the SHARED node-agents namespace, so two releases
  on one cluster wrote one Secret — last writer wins, and the loser's Collector
  authenticated as the wrong tenant. Scoping the name to the release makes each
  edge's Secret distinct, exactly as tracebloc.telemetryCollectorName scopes the
  DaemonSet that reads it.

  THE LEGACY FIXED NAME IS "MIGRATE ME", not an operator override. Nobody chose
  `tracebloc-telemetry-token`; it was the chart default, and `helm upgrade
  --reuse-values` bakes that default into every existing release's stored values —
  the same replay the daemonset's reuse-values nil-guard is about. So defaulting
  only an ABSENT name would leave every already-installed edge on the colliding
  fixed name forever; rewriting the legacy sentinel to the release-scoped name is
  what actually migrates them. A DIFFERENT explicit name is a real choice, honoured.
*/}}
{{- define "tracebloc.telemetryTokenSecretName" -}}
{{- $tc := default (dict) .Values.telemetryCollector -}}
{{- $name := (default (dict) $tc.tokenSecret).name | default "" -}}
{{- if or (eq $name "") (eq $name (include "tracebloc.telemetryTokenLegacyName" .)) -}}
{{- printf "%s-telemetry-token" (include "tracebloc.fullname" .) -}}
{{- else -}}
{{- $name -}}
{{- end -}}
{{- end -}}

{{/*
  tracebloc.telemetryTokenPresent — "yes" / "no" / "unknown".

  "unknown" IS A THIRD ANSWER, not a tidier "no". `lookup` returns empty during
  `helm template` (no cluster to ask), and treating that as absence would make
  offline rendering disagree with what a real install does — the silent-zero shape
  this whole epic keeps finding. Callers must branch on all three.

  Accepts the legacy fixed name as well as the release-scoped one, for the reason
  telemetryTokenSecretName sets out: an edge mid-migration holds only the old one
  until jobs-manager next re-authenticates, and refusing it would wedge exactly the
  edge that is already collecting.
*/}}
{{/*
  The token Secret's name BEFORE `fullnameOverride` was set — i.e. what a release
  installed without one is still carrying (Bugbot, Medium, on client#911).

  `telemetryTokenSecretName` follows the override, so on a renamed release the
  lookup below missed the live Secret and `telemetryCollectorState` hard-FAILED
  for an operator who had explicitly enabled the Collector: the token exists, it
  is simply under `<release>-telemetry-token`. The legacy fallback did not cover
  it either — that is a different, FIXED name (`tracebloc-telemetry-token`), not
  the release-scoped one.

  Accepted rather than refused, and that is deliberately the opposite call from
  the credentials Secret. There, a name miss means SILENTLY MINTING a new
  password against a datadir that holds the old one, so refusing is the only safe
  answer. Here the token is server-side and re-derivable — jobs-manager writes it
  (backend#2274) — so finding the existing one is both safe and what the operator
  meant. Same reasoning as the legacy name this sits beside.
*/}}
{{- define "tracebloc.telemetryTokenPreOverrideName" -}}
{{- printf "%s-telemetry-token" .Release.Name -}}
{{- end -}}

{{- define "tracebloc.telemetryTokenPresent" -}}
{{- if not (lookup "v1" "Namespace" "" "kube-system") -}}
unknown
{{- else -}}
{{- $ns := .Values.nodeAgents.namespace.name -}}
{{- if or (lookup "v1" "Secret" $ns (include "tracebloc.telemetryTokenSecretName" .)) (lookup "v1" "Secret" $ns (include "tracebloc.telemetryTokenLegacyName" .)) (lookup "v1" "Secret" $ns (include "tracebloc.telemetryTokenPreOverrideName" .)) -}}
yes
{{- else -}}
no
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  tracebloc.telemetryCollectorState — the ONE decider for whether the Collector
  renders, and why. Returns exactly one of:

    enabled                    render it
    disabled-by-operator       the operator said no
    skipped-no-token           nobody chose; the token Secret is not there yet
    skipped-incomplete-values  nobody chose; the Class A lists are missing, so
                               there is nothing coherent to collect

  THE SECOND SKIP IS NOT DEFENSIVENESS, it is the same wedge one guard further
  along, and the chart's own tests caught it. `helm upgrade --reuse-values`
  DELETES a key set to null and does not coalesce chart defaults back, so a
  release predating this block arrives with the whole `telemetryCollector` map
  gone — `enabled` absent (fleet mode, correctly) and `classAContainers` absent
  too. Rendering then dies on the configmap's own `fail`, which is exactly the
  unattended hard-stop this helper exists to prevent, just relocated. Fleet mode
  therefore requires a COMPLETE config, not merely a token.

  The attended path is untouched: an operator who set `enabled: true` with those
  lists nulled still gets the loud configmap failure naming the list, because
  that branch never reaches these checks.

  WHY THIS IS NOT A BOOLEAN, and why `telemetryCollector.enabled` has no default
  in values.yaml any more (backend#1906).

  The chart could not previously tell "an operator deliberately enabled this" from
  "this arrived as a new chart default", and the right answer differs sharply:

    * An operator who set the flag is WATCHING. A missing token Secret must refuse
      the release, loudly, naming the Secret — that is actionable, and silently
      installing nothing would be the backend#2400 deadlock again.

    * A value that arrived as a chart default has NOBODY watching: auto-upgrade is
      a CronJob. Refusing there does not inform anyone, it costs that edge every
      future upgrade — including security fixes — because `helm upgrade` fails at
      RENDER time, before `--atomic` can roll anything back, and an edge whose
      jobs-manager predates backend#2400 will never write the Secret that would
      unwedge it. That is a permanent stop, delivered by a checklist item.

  `--reset-then-reuse-values` (what auto-upgrade runs) makes the two
  distinguishable, and this is MEASURED, not assumed — on a real cluster, upgrading
  a release onto a chart whose values.yaml omits the key:

    never set the flag    -> key ABSENT      (kindOf "invalid")
    --set enabled=true    -> true, preserved
    --set enabled=false   -> false, preserved

  Old chart DEFAULTS are not carried forward; operator CHOICES are, both ways. So
  `kindIs "bool"` is exactly "an operator chose this", and the absent case is the
  fleet default the chart itself gets to decide.

  THE SKIP IS RECORDED, never silent — see templates/telemetry-collector-status.yaml.
  A component that quietly does nothing is the failure this epic exists to remove;
  a skip nobody can see is not safer than a crash, only quieter.
*/}}
{{- define "tracebloc.telemetryCollectorState" -}}
{{- $tc := default (dict) .Values.telemetryCollector -}}
{{- if kindIs "bool" $tc.enabled -}}
{{- if $tc.enabled -}}
{{- if eq (include "tracebloc.telemetryTokenPresent" .) "no" -}}
{{- fail (printf "telemetryCollector.enabled is true but its token Secret does not exist in namespace %q — looked for %q, the legacy %q, and the pre-fullnameOverride %q. The Collector's exporter authenticates with it, and jobs-manager writes it (backend#2274). IF YOU JUST CHANGED fullnameOverride FROM ONE VALUE TO ANOTHER, the token is under the PREVIOUS override's name and this render cannot guess it: nothing records what the last one was, and enumerating the namespace would be worse than guessing, because the Collector's volume and the RBAC's resourceNames both name ONLY the first Secret above, so a token found under any other name is one nothing is permitted to read. Two ways forward, and neither is a reinstall: copy the existing Secret to the first name above in that namespace (kubectl get secret <old> -o json | jq '.metadata.name=\"<new>\" | del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences)' | kubectl apply -f -), or leave telemetryCollector.enabled unset for one upgrade and let jobs-manager re-mint it under the new name on its next re-authentication — the Collector's mount is optional, so it waits and buffers rather than crash-looping. Otherwise create it, or set telemetryCollector.enabled: false — enabling without it buys a DaemonSet that spools to every node's disk and delivers nothing." .Values.nodeAgents.namespace.name (include "tracebloc.telemetryTokenSecretName" .) (include "tracebloc.telemetryTokenLegacyName" .) (include "tracebloc.telemetryTokenPreOverrideName" .)) -}}
{{- end -}}
enabled
{{- else -}}
disabled-by-operator
{{- end -}}
{{- else -}}
{{- if or (not $tc.classAContainers) (not $tc.classANodeAgentContainers) -}}
skipped-incomplete-values
{{- else if eq (include "tracebloc.telemetryTokenPresent" .) "no" -}}
skipped-no-token
{{- else -}}
enabled
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  tracebloc.backendUrl — the tracebloc API base URL for this CLIENT_ENV, with a
  trailing slash.

  Resolved through `tracebloc.clientEnv` rather than the raw value, so a
  documented alias (`staging`) lands on the same host as its canonical form and
  cannot silently route an install at the wrong backend — the backend#1745 defect.

  A FOURTH COPY OF THIS MAPPING, and saying so is the point. It also lives in
  `scripts/lib/install-client-helm.sh::_backend_url`,
  `scripts/lib/preflight.sh::_pf_backend_host`, and inline in
  `templates/egress-reachability-check.yaml`. Helm cannot read the shell ones and
  they cannot read this, so there is no single source available here; this is the
  single source for TEMPLATES, and pointing the reachability check at it is a
  refactor that belongs in its own PR rather than riding on a feature.
*/}}
{{- define "tracebloc.backendUrl" -}}
{{- $env := include "tracebloc.clientEnv" . -}}
{{- if eq $env "dev" -}}
https://dev-api.tracebloc.io/
{{- else if eq $env "stg" -}}
https://stg-api.tracebloc.io/
{{- else -}}
https://api.tracebloc.io/
{{- end -}}
{{- end -}}

{{/*
  tracebloc.nodeAgentsInUse — true when a POD-BEARING tenant of
  nodeAgents.namespace is enabled (backend#1906, @saadqbal's review of #779;
  narrowed from "anything the chart owns" by backend#2400).

  ONE PREDICATE, not N readers. Five templates put something in that namespace
  and each carried its own copy of "is resource-monitor on"; when the Collector
  became a second tenant, two of them were widened and the rest were not, so the
  configuration this feature exists to enable — resourceMonitor off, Collector on
  — created the namespace, landed the DaemonSet, and left the RBAC that manages it
  behind. Adding a third POD-BEARING tenant should be one line here, not an audit.

  "POD-BEARING" IS THE LOAD-BEARING WORD, and it is narrower than the sentence
  this docstring used to open with. Every consumer left is about pods: RBAC that
  patches or deletes DaemonSets there, and the image pull Secret they pull with.
  backend#2400 added an occupant with no pods — telemetry-token-rbac.yaml's Role
  and RoleBinding, which let jobs-manager write the Collector's token Secret
  before anyone can enable the Collector, and therefore render unconditionally.
  Widening this helper to cover it would make it a constant `true`: measured, that
  grants auto-upgrade and image-refresh DaemonSet rights in a namespace that has
  no DaemonSets (4 extra RBAC objects) and leaves a question that can only be
  answered one way. The Namespace object no longer asks it either — with a
  pod-less occupant always present, the namespace is always required.

  So: a new occupant belongs here only if it brings PODS. One that does not gates
  itself, and says why it does not gate on this.

  THE NIL-GUARD IS LOAD-BEARING, which is the other reason this is central. A bare
  `.Values.telemetryCollector.enabled` throws "nil pointer evaluating
  interface {}.enabled" for anyone running `helm upgrade --reuse-values` from a
  chart that predates the key — a very common operator habit, and it fails before
  a single resource lands. Guarded once here instead of five times.

  Emits the string "true" or nothing, so callers use it as
  `(include "tracebloc.nodeAgentsInUse" .)` inside an `and`.
*/}}
{{- define "tracebloc.nodeAgentsInUse" -}}
{{- /*
  THE COLLECTOR TENANT IS ASKED THROUGH ITS OWN DECIDER, not through the raw
  `enabled` key (Bugbot, client#905). `telemetryCollectorState` exists precisely
  because `enabled` stopped being the answer: in FLEET MODE the key is ABSENT and
  the state is still `enabled`, so the DaemonSet renders. Reading `$tc.enabled`
  here therefore said "no pod-bearing tenant" about a namespace that was about to
  receive a DaemonSet -- and on an edge with `resourceMonitor: false` and a
  mirrored registry that is a Collector with no image pull Secret, i.e.
  ImagePullBackOff on every node.
  
  This is the exact failure the docstring above describes happening once already:
  "each carried its own copy of 'is resource-monitor on'; when the Collector
  became a second tenant, two of them were widened and the rest were not." The
  tri-state made `enabled` a second copy of the answer for a third time.
*/ -}}
{{- if or (include "tracebloc.resourceMonitorEnabled" .) (eq (include "tracebloc.telemetryCollectorState" .) "enabled") }}true{{ end -}}
{{- end -}}

{{/*
tracebloc.gpuEnv -- the jobs-manager's GPU_REQUESTS / GPU_LIMITS env pair, rendered
ONCE for both containers (api and pods-monitor) so the request == limit invariant
lives in one place (Saqlain, client#996). Three situations, not two (backend#2216):

  * `env.GPU_LIMITS` absent            -> emits NEITHER var; the runtime keeps its
                                          legacy assume-a-GPU default. A lone
                                          `env.GPU_REQUESTS` is IGNORED here on
                                          purpose: GPU_LIMITS is the gate, and an
                                          edge that carried a lone empty
                                          GPU_REQUESTS on an older chart must not
                                          flip to CPU-only on upgrade.
  * `env.GPU_LIMITS: ""`               -> both empty: the operator declared CPU-only.
  * `env.GPU_LIMITS: nvidia.com/gpu=N` -> both set; GPU_REQUESTS takes the
                                          operator's value when given, else
                                          GPU_LIMITS' own (client#995: it used to
                                          take a literal "nvidia.com/gpu=1", which
                                          the API server rejects beside any other
                                          limit). Two different explicit values are
                                          written as given; the runtime warns once.
*/}}
{{- define "tracebloc.gpuEnv" -}}
{{- if hasKey .Values.env "GPU_LIMITS" }}
- name: GPU_REQUESTS
  value: {{ if hasKey .Values.env "GPU_REQUESTS" }}{{ .Values.env.GPU_REQUESTS | default "" | quote }}{{ else }}{{ .Values.env.GPU_LIMITS | default "" | quote }}{{ end }}
- name: GPU_LIMITS
  value: {{ .Values.env.GPU_LIMITS | default "" | quote }}
{{- end }}
{{- end }}
