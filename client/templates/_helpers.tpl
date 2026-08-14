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

{{- define "tracebloc.secretName" -}}
{{ .Release.Name }}-secrets
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

{{- define "tracebloc.serviceAccountName" -}}
{{ .Release.Name }}-jobs-manager
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
{{ .Release.Name }}-resource-monitor
{{- end }}

{{- define "tracebloc.rbacName" -}}
{{ .Release.Name }}-jobs-manager-rbac
{{- end }}

{{- define "tracebloc.clientDataPvc" -}}
client-pvc
{{- end }}

{{- define "tracebloc.clientDataPvName" -}}
{{ .Release.Name }}-data-pv
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
{{ .Release.Name }}-logs-pv
{{- end }}

{{- define "tracebloc.clientLogsStorage" -}}
{{ .Values.pvc.logs | default "10Gi" }}
{{- end }}

{{- define "tracebloc.mysqlPvc" -}}
mysql-pvc
{{- end }}

{{- define "tracebloc.mysqlPvName" -}}
{{ .Release.Name }}-mysql-pv
{{- end }}

{{- define "tracebloc.mysqlStorage" -}}
{{ .Values.pvc.mysql | default "2Gi" }}
{{- end }}

{{- define "tracebloc.registrySecretName" -}}
{{ .Release.Name }}-regcred
{{- end }}

{{/*
  Release-scoped name shared by the auto-upgrade CronJob, ServiceAccount,
  ClusterRoleBinding, and the ConfigMap holding the upgrade script. Kept
  in one helper so the four resources stay in lockstep — the CRB references
  the SA by name, and the CronJob mounts the ConfigMap by name.
*/}}
{{- define "tracebloc.autoUpgradeName" -}}
{{ .Release.Name }}-auto-upgrade
{{- end }}

{{/*
  Release-scoped name shared by the image-refresh CronJob, ServiceAccount,
  Role, RoleBinding, and ConfigMap. Same lockstep reasoning as
  tracebloc.autoUpgradeName above. Distinct from auto-upgrade because the
  two CronJobs have different cadences, different RBAC scopes (image-refresh
  is namespace-scoped, auto-upgrade is cluster-admin), and customers may
  reasonably disable one but not the other.
*/}}
{{- define "tracebloc.imageRefreshName" -}}
{{ .Release.Name }}-image-refresh
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
{{ .Release.Name }}-image-refresh-node-agents
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
{{ .Release.Name }}-requests-proxy
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
    * an explicit `images.resourceMonitor.digest` pin, same signal as the other
      images, or
    * `resourceMonitor: false` — there is no DaemonSet at all, so there is
      nothing to reconcile and a cross-namespace `set image` would just fail.

  Nil-safe: `.Values.resourceMonitor` absent reads as enabled, matching the
  `ne .Values.resourceMonitor false` gate on the DaemonSet itself.
*/}}
{{- define "tracebloc.resourceMonitorRefreshPinned" -}}
{{- if eq .Values.resourceMonitor false -}}
true
{{- else if (default dict (default dict .Values.images).resourceMonitor).digest -}}
true
{{- end -}}
{{- end }}

{{- define "tracebloc.imageRefreshEnabled" -}}
{{- $ir := default dict .Values.imageRefresh -}}
{{- $imgs := default dict .Values.images -}}
{{- $jm := default dict $imgs.jobsManager -}}
{{- $pm := default dict $imgs.podsMonitor -}}
{{/*
  Per-image pin signal (means "skip auto-refresh for this image"):
  jobs-manager / pods-monitor are pinned when `digest` is set (non-empty) —
  the same signal the deployment uses to switch imagePullPolicy to
  IfNotPresent. The ingestor is no longer refreshed by this CronJob (it is
  spawned by jobs-manager from a floating tag — see the
  image-refresh-cronjob.yaml header and submit_ingestion_run in
  client-runtime), so the CronJob exists only to refresh the two class-1
  images: when BOTH are pinned there is nothing left for it to do.
*/}}
{{- $jmPinned := $jm.digest -}}
{{- $pmPinned := $pm.digest -}}
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

    1. An explicit `digest` pin -> IfNotPresent. The reference is immutable, so
       re-checking the registry can only ever return the same image. Updates
       come from changing the pin.
    2. Otherwise, if the image-refresh reconcile can actually drive updates on
       this edge -> IfNotPresent, because `set image` changes the REFERENCE and
       the kubelet pulls a digest it has never seen. Two conditions:
         * the CronJob renders at all (`imageRefresh.enabled`, and not every
           refreshed image already pinned), and
         * images come from docker.io. Under a `global.imageRegistry` mirror the
           script goes inert by design — it resolves digests from docker.io, and
           pinning one onto a mirrored reference could pin an image the mirror
           does not hold.
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

  Usage: {{ include "tracebloc.controlPlanePullPolicy" (dict "digest" $d "root" $) }}
*/}}
{{- define "tracebloc.controlPlanePullPolicy" -}}
{{- $mirror := (dig "imageRegistry" "docker.io" (.root.Values.global | default dict)) | default "docker.io" -}}
{{- if .digest -}}
IfNotPresent
{{- else if and (include "tracebloc.imageRefreshEnabled" .root) (eq $mirror "docker.io") -}}
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
{{ .Release.Name }}-storage-class
{{- else -}}
{{ .Values.storageClass.name }}
{{- end -}}
{{- end -}}

{{/* Whether to create registry secret and add imagePullSecrets. Only when dockerRegistry is present and create is true; omit dockerRegistry or set create: false for public images. */}}
{{- define "tracebloc.useImagePullSecrets" -}}
{{- if and .Values.dockerRegistry (default false .Values.dockerRegistry.create) -}}
true
{{- end -}}
{{- end }}

{{/*
Image reference — defaults to docker.io when no registry is provided.
When `digest` (sha256:...) is set, renders registry/repo@digest (immutable pin,
preferred for security). Otherwise falls back to registry/repo:tag, where tag
defaults to "prod" when CLIENT_ENV is omitted or empty.
Usage: {{ include "tracebloc.image" (dict "repository" "tracebloc/jobs-manager" "tag" (include "tracebloc.clientEnv" .) "digest" .Values.images.jobsManager.digest "registry" "docker.io") }}
NOTE the resolved tag. This example previously read `.Values.env.CLIENT_ENV`
and all four image call sites were copied from it, so a documented alias
became an image tag nothing publishes (backend#1723).
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
tracebloc.mirrorPrefix — registry prefix for images whose repository is a
registry-less path (docker.io implicit), e.g. the alpine/* utility-pod images.
When a private mirror is set via global.imageRegistry (#585), returns
"<registry>/" so an air-gapped install re-homes those images onto the mirror;
returns "" when no mirror is set, so default installs render byte-identically.
Nil-guarded for --reset-then-reuse-values upgrades that predate global. Call
with the ROOT context (e.g. `include "tracebloc.mirrorPrefix" $`).
*/}}
{{- define "tracebloc.mirrorPrefix" -}}
{{- with (dig "imageRegistry" "" (.Values.global | default dict)) }}{{ . }}/{{ end -}}
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

{{- define "tracebloc.clientEnv" -}}
{{- $raw := (default dict .Values.env).CLIENT_ENV | default "prod" -}}
{{- $aliases := dict "development" "dev" "staging" "stg" "production" "prod" -}}
{{- $resolved := $raw -}}
{{- if hasKey $aliases $raw -}}
{{- $resolved = get $aliases $raw -}}
{{- end -}}
{{- if not (has $resolved (list "dev" "stg" "prod")) -}}
{{- fail (printf "env.CLIENT_ENV: %q is not a recognized environment. Accepted: dev, stg, prod (canonical) or development, staging, production (aliases); empty/unset means prod. This value is the tag for the jobs-manager, pods-monitor and resource-monitor images, and it keys images.ingestor.channelTags, serviceDbAccountsByEnv and the prod digest pin -- an unrecognized value would pull unpublished tags, miss every one of those lookups and silently drop the pin. Note dev/stg are abbreviated: `develop` and `production` differ, and only the six listed spellings resolve." $raw) -}}
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
