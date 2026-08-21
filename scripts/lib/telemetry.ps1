# =============================================================================
#  telemetry.ps1 — the Windows installer's outcome emitter (backend#2268).
#
#  THE TWIN OF scripts/lib/telemetry.sh, and a port of its CONTRACT, not of its
#  lines. `install-k8s.ps1` had zero telemetry — no event, no spool, nothing for
#  any transport to carry — while backend#1907 was closed on the strength of the
#  bash emitter and RFC-BACKEND-1872 listed `client installer` as a single row.
#  Every statement of the form "the installer now emits" was true of one platform
#  and false of the other.
#
#  READ telemetry.sh BEFORE CHANGING ANYTHING HERE. Its comments carry the
#  reasoning for each decision below — the `--help` latch, the declared-exit-2
#  handoff, why a skipped run stays skipped under Ctrl-C, why telemetry must
#  never create HOST_DATA_DIR. Those decisions are not re-argued here; they are
#  implemented, with a pointer to the twin. What IS documented here is every
#  place the platform forced a genuine difference, because that is what a
#  reviewer cannot check against the other file.
#
#  THE VOCABULARIES ARE DUPLICATED, AND THAT IS THE ONE THING A TEST MUST WATCH.
#  A PowerShell script cannot read the bash declarations at runtime, so the
#  closed sets below are a second copy — exactly the "restated, not derived"
#  shape that goes stale silently. scripts/tests/telemetry-vocabulary-agreement.sh
#  is therefore extended to parse BOTH twins and compare them; it holds no list
#  of its own either.
#
#  FAIL-SOFT IS LOAD-BEARING. No telemetry path may fail an install. Every
#  public function returns without throwing, and the callers are wrapped besides.
#  But the parity fixture's own history (client#772) is that a bare `catch {}` on
#  ps1 is how a Windows capability dies quietly, so failures here are swallowed
#  AND recorded: see Write-TelemetryDebug.
# =============================================================================

# DELIBERATELY NO `Set-StrictMode` HERE.
#
# It was the first line of this file and it was a live defect. Set-StrictMode is
# not file-scoped: dot-sourcing this lib applies it to the CALLER, so it would
# have imposed StrictMode Latest on all 6,600 lines of install-k8s.ps1 — code
# written without it, in which reading an absent property is ordinary and
# returns $null. Under StrictMode that becomes a TERMINATING error.
#
# The Pester run is what showed it: 560 sibling assertions failed with
# "The property 'override' cannot be found", nowhere near this file, because the
# mode had leaked across the whole session. In the field it would have surfaced
# as the installer dying somewhere unrelated to telemetry — the observer breaking
# the thing it observes, which is the one outcome this feature must never have.
#
# A lib the installer sources may not change the installer's language semantics.

# ── Identity (telemetry.sh:37-38) ────────────────────────────────────────────
$script:TbTelemetryService   = 'installer'
$script:TbTelemetryComponent = 'install'

# ── Closed vocabularies — must equal telemetry.sh's, char for char ───────────
$script:TbTelemetryPhases = @(
  'a:preflight', 'b:prerequisites', 'c:cluster', 'd:register', 'e:helm', 'f:connect'
)
$script:TbTelemetryEventNames = @(
  'install.run.succeeded', 'install.run.failed',
  'install.run.cancelled', 'install.run.skipped'
)
$script:TbTelemetryClientStates = @(
  'connected', 'starting', 'bad_creds', 'image_pull', 'image_pull_ca', 'crash'
)
$script:TbTelemetryErrorClasses = @(
  'unexpected_exit_2', 'bad_credentials', 'image_pull_failed',
  'image_pull_untrusted_ca', 'crash_loop', 'not_ready', 'bootstrap_failed',
  'preflight_failed', 'prerequisites_failed', 'cluster_create_failed',
  'registration_failed', 'helm_install_failed', 'unclassified'
)
# The Windows installer is one file, so this set is one entry — not the bash
# side's eighteen. It exists for the same reason: `tracebloc.install.source` may
# only ever name a script of ours.
$script:TbTelemetrySources = @('install-k8s.ps1', 'install.ps1', 'telemetry.ps1')

$script:TbTelemetryOptOutVars = @('TRACEBLOC_NO_TELEMETRY', 'DO_NOT_TRACK')

# ── Shape tests ──────────────────────────────────────────────────────────────
#  ANCHORED \A..\z, NOT ^..$ — and this is the one porting detail most likely to
#  be "corrected" back into a bug. telemetry.sh switched from `grep` to `[[ =~ ]]`
#  because grep matches a LINE while the check must match the whole STRING. .NET
#  reintroduces that hole in a subtler spelling: without RegexOptions.Multiline,
#  `^` and `$` are string anchors, but `$` ALSO matches immediately before a
#  trailing newline. So "abc`n" satisfies '^[a-z]+$' in PowerShell, and a value
#  carrying a newline would reach the record — the exact bypass the bash comment
#  warns about, arrived at from the other direction. \z has no such exception.
$script:TbTelemetryTokenRe   = '\A[A-Za-z0-9._-]{1,64}\z'
$script:TbTelemetryIntRe     = '\A-?[0-9]{1,15}\z'
$script:TbTelemetryKeyRe     = '\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z'
$script:TbTelemetryVersionRe = '\Av[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?\z'
$script:TbTelemetryLineRe    = '\A[0-9]{1,7}\z'

$script:TbTelemetrySpoolMax = 50

# ── Clock ────────────────────────────────────────────────────────────────────
function Get-TelemetryNowMs {
  [OutputType([long])] param()
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

$script:TbTelemetryStartedMs      = Get-TelemetryNowMs
$script:TbTelemetryPhaseStartedMs = $script:TbTelemetryStartedMs
$script:TbTelemetryPhase          = 'bootstrap'
$script:TbTelemetryPhaseMs        = @{}
$script:TbTelemetryEmitted        = $false
$script:TbTelemetryRunStarted     = $false
$script:TbTelemetrySkipped        = $false
$script:TbTelemetryRerunHandoff   = $false

# service.instance.id — computed at LOAD time, like the bash side, so it is
# stable for the process. Four 16-bit draws; an id for telling two concurrent
# runs apart, not a secret.
$script:TbTelemetryInstanceId = -join (1..4 | ForEach-Object {
  '{0:x4}' -f (Get-Random -Minimum 0 -Maximum 65536)
})
if ([string]::IsNullOrWhiteSpace($script:TbTelemetryInstanceId)) {
  # Never a constant stand-in that would fuse every affected run into one row.
  $script:TbTelemetryInstanceId = 'unknown'
}

# ── Swallowed-but-not-silent ─────────────────────────────────────────────────
#  A bare `catch {}` is how machine sizing died on Windows without a single test
#  noticing (client#772's fixture records it). So every catch here routes through
#  one place, which stays quiet on the console — an installer must not print
#  telemetry noise at a user mid-failure — and leaves a trace when
#  TRACEBLOC_TELEMETRY_DEBUG is set.
function Write-TelemetryDebug {
  param([string]$Message)
  try {
    if ($env:TRACEBLOC_TELEMETRY_DEBUG) {
      Write-Host "telemetry(debug): $Message"
    }
  } catch { }
}

# ── Latches (telemetry.sh:193, :213, :250) ───────────────────────────────────
function Set-TelemetryRunStarted   { $script:TbTelemetryRunStarted   = $true }
function Set-TelemetryRunSkipped   { $script:TbTelemetrySkipped      = $true }
function Set-TelemetryRerunHandoff { $script:TbTelemetryRerunHandoff = $true }

# ── Opt-out (telemetry.sh:259) ───────────────────────────────────────────────
#  Anything other than the explicit "off" spellings counts as opting OUT: a user
#  who typed TRACEBLOC_NO_TELEMETRY=please meant it.
function Test-TelemetryEnabled {
  [OutputType([bool])] param()
  foreach ($name in $script:TbTelemetryOptOutVars) {
    $raw = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $raw) { continue }
    $v = ($raw -replace '\s', '').ToLowerInvariant()
    if ($v -eq '' -or $v -eq '0' -or $v -eq 'false') { continue }
    return $false
  }
  return $true
}

# ── Phases ───────────────────────────────────────────────────────────────────
function Get-TelemetryPhaseName {
  param([string]$Letter)
  foreach ($pair in $script:TbTelemetryPhases) {
    $parts = $pair.Split(':', 2)
    if ($parts[0] -eq $Letter) { return $parts[1] }
  }
  return $null   # fail closed: an unknown letter invents no phase name
}

# Derived from TbTelemetryPhases, so a phase added there needs no second edit.
function Get-TelemetryPhaseNames {
  $names = [System.Collections.Generic.List[string]]::new()
  $names.Add('bootstrap'); $names.Add('unknown')
  foreach ($pair in $script:TbTelemetryPhases) { $names.Add($pair.Split(':', 2)[1]) }
  return $names.ToArray()
}

# Close the running phase's timer, open the next. Never throws: a timing
# bookkeeping error must not be able to end an install.
function Start-TelemetryPhase {
  param([string]$Letter)
  try {
    $now = Get-TelemetryNowMs
    $name = Get-TelemetryPhaseName -Letter $Letter
    if (-not $name) { return }
    $elapsed = $now - $script:TbTelemetryPhaseStartedMs
    if ($elapsed -lt 0) { $elapsed = 0 }
    $prev = $script:TbTelemetryPhase
    if ($script:TbTelemetryPhaseMs.ContainsKey($prev)) {
      $script:TbTelemetryPhaseMs[$prev] += $elapsed
    } else {
      $script:TbTelemetryPhaseMs[$prev] = $elapsed
    }
    $script:TbTelemetryPhase = $name
    $script:TbTelemetryPhaseStartedMs = $now
  } catch {
    Write-TelemetryDebug "phase begin failed: $_"
  }
}

# ── Error classification (telemetry.sh:368) ──────────────────────────────────
function Get-TelemetryErrorClass {
  param([int]$Code, [string]$Phase, [string]$State, [bool]$RerunHandoff)
  if ($Code -eq 2 -and -not $RerunHandoff) { return 'unexpected_exit_2' }
  switch ($State) {
    'bad_creds'     { return 'bad_credentials' }
    'image_pull'    { return 'image_pull_failed' }
    'image_pull_ca' { return 'image_pull_untrusted_ca' }
    'crash'         { return 'crash_loop' }
    'starting'      { return 'not_ready' }
  }
  switch ($Phase) {
    'bootstrap'     { return 'bootstrap_failed' }
    'preflight'     { return 'preflight_failed' }
    'prerequisites' { return 'prerequisites_failed' }
    'cluster'       { return 'cluster_create_failed' }
    'register'      { return 'registration_failed' }
    'helm'          { return 'helm_install_failed' }
    'connect'       { return 'not_ready' }
  }
  return 'unclassified'
}

# ── Environment (telemetry.sh:407) ───────────────────────────────────────────
#  Returns $null for an unrecognised environment, which DROPS the record (§3.2).
function Get-TelemetryEnvironment {
  $env_ = $env:CLIENT_ENV
  if ([string]::IsNullOrWhiteSpace($env_)) { $env_ = 'prod' }
  # tb_client_env's alias folding, where install-k8s.ps1 provides it.
  # Get-TraceblocClientEnv is install-k8s.ps1's alias folder (backend#1745:
  # development/staging/production -> dev/stg/prod). Looked up rather than
  # duplicated, so the emitter cannot disagree with the installer about which
  # environment a run belongs to. Absent when this lib is loaded on its own.
  if (Get-Command -Name 'Get-TraceblocClientEnv' -CommandType Function -ErrorAction SilentlyContinue) {
    try { $env_ = Get-TraceblocClientEnv $env_ } catch { Write-TelemetryDebug "env resolve failed: $_" }
  }
  if ($env_ -in @('dev', 'stg', 'prod')) { return $env_ }
  return $null
}

# ── Resource fields ──────────────────────────────────────────────────────────
function Get-TelemetryVersion {
  $v = $env:TB_VERSION
  if ([string]::IsNullOrEmpty($v) -or ($v -cnotmatch $script:TbTelemetryVersionRe)) {
    # §4: unknown is a VALUE, not an omission — 0.0.0-unknown is queryable.
    return '0.0.0-unknown'
  }
  return $v
}

# os.type — OTel's own name and its own value. The bash twin's closed set is
# darwin/linux/unknown because bash never runs here; `windows` is OTel's
# registered value for this platform, not a new namespace.
function Get-TelemetryOs { return 'windows' }

function Get-TelemetryArch {
  $a = $env:PROCESSOR_ARCHITECTURE
  if ([string]::IsNullOrWhiteSpace($a)) { $a = '' }
  switch ($a.ToUpperInvariant()) {
    'AMD64' { return 'amd64' }
    'ARM64' { return 'arm64' }
    'X86'   { return 'unknown' }   # 32-bit is unsupported; do not claim amd64
    default { return 'unknown' }
  }
}

function Get-TelemetryInstanceId { return $script:TbTelemetryInstanceId }

# ── The record ───────────────────────────────────────────────────────────────
$script:TbTelemetryBuf = [System.Collections.Generic.List[string]]::new()

function Reset-TelemetryBuffer { $script:TbTelemetryBuf.Clear() }

# Read the pending buffer. Exists for the tests: `$script:` state belongs to THIS
# file's scope, and a test that reached for it directly would read a variable in
# its own scope and silently assert against nothing.
function Get-TelemetryBufferForTest { return ($script:TbTelemetryBuf -join ',') }

# The single writer, and the whole privacy boundary (telemetry.sh:449).
# Refuses and DROPS, in this order: a malformed key, an empty value, a value that
# is not the shape Kind promises. It never trims, escapes or truncates — a value
# that had to be repaired to be safe is a value we did not understand.
function Add-TelemetryAttr {
  param([string]$Key, $Value, [string]$Kind = 'str')
  try {
    if ($null -eq $Key -or $Key -cnotmatch $script:TbTelemetryKeyRe) { return }
    if ($null -eq $Value) { return }
    $v = [string]$Value
    if ($v -eq '') { return }
    if ($Kind -eq 'int') {
      if ($v -cnotmatch $script:TbTelemetryIntRe) { return }
      $script:TbTelemetryBuf.Add('"' + $Key + '":' + $v)
    } else {
      if ($v -cnotmatch $script:TbTelemetryTokenRe) { return }
      $script:TbTelemetryBuf.Add('"' + $Key + '":"' + $v + '"')
    }
  } catch {
    Write-TelemetryDebug "attr $Key rejected: $_"
  }
}

# The script name out of a "file:line" location, if it is one of ours.
# Everything else, including the directory it came from, is discarded.
function Get-TelemetrySourceBasename {
  param([string]$Loc)
  if ([string]::IsNullOrEmpty($Loc)) { return $null }
  # SPLIT ON THE LAST COLON, not the first. The bash twin does `${1%%:*}` because
  # a POSIX path has no colon in it; a WINDOWS path opens with one —
  # `C:\Users\...\install-k8s.ps1:12` — so taking the first field returned the
  # drive letter `C`, which is in no source vocabulary, and the location was
  # dropped on every real Windows failure. The only genuinely platform-specific
  # bug in this port, and the reason the suite asserts against a full drive-letter
  # path rather than a bare filename.
  $parts = $Loc -split ':'
  if ($parts.Length -lt 2) { return $null }
  $base = ($parts[0..($parts.Length - 2)] -join ':')
  $base = $base -replace '.*[\\/]', ''
  if ($base -in $script:TbTelemetrySources) { return $base }
  return $null
}

function Get-TelemetrySourceLine {
  param([string]$Loc)
  if ([string]::IsNullOrEmpty($Loc)) { return $null }
  $parts = $Loc -split ':'
  $line = $parts[$parts.Length - 1]
  if ($line -cmatch $script:TbTelemetryLineRe) { return $line }
  return $null
}

function Get-TelemetryPhaseMs {
  param([string]$Name, [string]$Current, [long]$Now)
  $acc = 0
  if ($script:TbTelemetryPhaseMs.ContainsKey($Name)) { $acc = $script:TbTelemetryPhaseMs[$Name] }
  if ($Name -eq $Current) {
    $open = $Now - $script:TbTelemetryPhaseStartedMs
    if ($open -lt 0) { $open = 0 }
    $acc += $open
  }
  # A phase never entered has no key at all (§1.2 omits an absent value); a phase
  # that ran always has one, including 0.
  if ($acc -eq 0 -and -not $script:TbTelemetryPhaseMs.ContainsKey($Name) -and $Name -ne $Current) {
    return $null
  }
  return $acc
}

# One contract-shaped JSON object, or $null when the environment is unrecognised.
# Pure: reads state, writes nothing, touches no file — which is what lets the
# tests assert on the real payload rather than on a re-implementation of it.
function Get-TelemetryEvent {
  param([int]$Code = 0)

  $env_ = Get-TelemetryEnvironment
  if (-not $env_) { return $null }

  # See telemetry.sh:501-585 for why each of these branches is what it is: a
  # DECLARED exit 2 is the "complete this step and re-run" handoff, an undeclared
  # one is a failure with its own error.type; 130/143 are the signal exits; and a
  # signal on a SKIPPED run is still skipped, while a skipped run that then fails
  # for real stays a failure.
  $event = switch ($Code) {
    0   { if ($script:TbTelemetrySkipped)      { 'install.run.skipped' }   else { 'install.run.succeeded' } }
    2   { if ($script:TbTelemetryRerunHandoff) { 'install.run.cancelled' } else { 'install.run.failed' } }
    130 { if ($script:TbTelemetrySkipped)      { 'install.run.skipped' }   else { 'install.run.cancelled' } }
    143 { if ($script:TbTelemetrySkipped)      { 'install.run.skipped' }   else { 'install.run.cancelled' } }
    default { 'install.run.failed' }
  }
  if ($event -notin $script:TbTelemetryEventNames) { return $null }

  $state = $env:CLIENT_STATE
  if ($state -notin $script:TbTelemetryClientStates) { $state = '' }

  $phase = $script:TbTelemetryPhase
  if ($phase -notin (Get-TelemetryPhaseNames)) { $phase = 'unknown' }

  Reset-TelemetryBuffer
  Add-TelemetryAttr 'event.name' $event
  Add-TelemetryAttr 'tracebloc.install.phase' $phase
  Add-TelemetryAttr 'tracebloc.install.exit_code' $Code 'int'

  # ONE clock read for the whole event, so the per-phase numbers and the total are
  # exactly consistent — an invariant the tests assert.
  $now = Get-TelemetryNowMs
  $total = $now - $script:TbTelemetryStartedMs
  if ($total -lt 0) { $total = 0 }
  Add-TelemetryAttr 'tracebloc.install.duration_ms' $total 'int'
  Add-TelemetryAttr 'tracebloc.install.client_state' $state

  if ($env:TB_CLI_ON_FRESH_PATH -in @('0', '1')) {
    Add-TelemetryAttr 'tracebloc.install.cli_on_path' $env:TB_CLI_ON_FRESH_PATH 'int'
  }

  foreach ($name in (Get-TelemetryPhaseNames)) {
    $ms = Get-TelemetryPhaseMs -Name $name -Current $phase -Now $now
    if ($null -ne $ms) {
      Add-TelemetryAttr "tracebloc.install.phase_${name}_ms" $ms 'int'
    }
  }

  if ($event -eq 'install.run.failed') {
    # §8.4 — a failure MUST carry error.type or it cannot be grouped.
    $class = Get-TelemetryErrorClass -Code $Code -Phase $phase -State $state `
      -RerunHandoff $script:TbTelemetryRerunHandoff
    if ($class -notin $script:TbTelemetryErrorClasses) { $class = 'unclassified' }
    Add-TelemetryAttr 'error.type' $class

    # ONE GATE FOR BOTH HALVES, derived from the source vocabulary's own answer.
    # A line number with no file is not a partial answer, it is a confident wrong
    # one — it reads, sorts and groups like information while pointing at line 9
    # of nothing (Bugbot on client#747).
    $loc = $env:TB_ERR_LOC
    if (-not [string]::IsNullOrEmpty($loc)) {
      $src = Get-TelemetrySourceBasename -Loc $loc
      if ($src) {
        Add-TelemetryAttr 'tracebloc.install.source' $src
        Add-TelemetryAttr 'tracebloc.install.source_line' (Get-TelemetrySourceLine -Loc $loc) 'int'
      }
    }
  }

  # TWO STATEMENTS, not `@(...) -join ','` on one line. That spelling left an
  # ARRAY here rather than a string, so the fields came out separated by $OFS —
  # a space — and the record was not valid JSON at all. Caught by the
  # ConvertFrom-Json assertion in the Pester suite, which is why that test is a
  # round-trip parse and not a regex.
  # EVERY ELEMENT PARENTHESISED, and this is not style. In PowerShell `,` binds
  # TIGHTER than `+`, so
  #     @( 'a:' + $x + '"', 'b:' + $y + '"' )
  # does not build a two-element array: the `,` binds to the adjacent string
  # operands, `+` gets an ARRAY as its right operand, and the whole thing
  # collapses into ONE string in which the parts are separated by $OFS — a space.
  # The record then rendered as
  #     {"resource":{"service.name":"installer" "tracebloc.component":"install" ...
  # which is not JSON at all. It looked completely plausible in a log and every
  # regex-based assertion passed; only the ConvertFrom-Json round-trip in the
  # Pester suite caught it, which is why that test parses rather than matches.
  $resourceFields = @(
    ('"service.name":"'           + $script:TbTelemetryService   + '"'),
    ('"tracebloc.component":"'    + $script:TbTelemetryComponent + '"'),
    ('"service.version":"'        + (Get-TelemetryVersion)       + '"'),
    ('"deployment.environment":"' + $env_                        + '"'),
    ('"os.type":"'                + (Get-TelemetryOs)            + '"'),
    ('"host.arch":"'              + (Get-TelemetryArch)          + '"'),
    ('"service.instance.id":"'    + (Get-TelemetryInstanceId)    + '"')
  )
  if ($resourceFields.Count -ne 7) {
    # Fail closed rather than ship a malformed record. If the array ever collapses
    # again — the `,`/`+` trap above is easy to reintroduce — drop the event
    # instead of emitting something no consumer can parse.
    Write-TelemetryDebug "resource fields collapsed to $($resourceFields.Count); dropping the record"
    return $null
  }
  $resource = $resourceFields -join ','

  return '{"resource":{' + $resource + '},"attributes":{' + ($script:TbTelemetryBuf -join ',') + '}}'
}

# ── Delivery ─────────────────────────────────────────────────────────────────
function Get-TelemetrySpoolDir {
  $root = $env:HOST_DATA_DIR
  if ([string]::IsNullOrWhiteSpace($root)) {
    $home_ = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($home_)) { $home_ = $HOME }
    if ([string]::IsNullOrWhiteSpace($home_)) { return $null }
    $root = Join-Path $home_ '.tracebloc'
  }
  return $root
}

function Get-TelemetrySpoolPath {
  $root = Get-TelemetrySpoolDir
  if (-not $root) { return $null }
  return (Join-Path (Join-Path $root 'telemetry') 'pending.jsonl')
}

# A directory whose contents survive this install. NOT HOST_DATA_DIR — telemetry
# must never create it (client#432/#441: an observer that changes the install's
# own preconditions is not an observer), and on the bash side a trap that did
# `mkdir -p` there re-enabled an NFS data dir the guard had just refused.
function Get-TelemetryFallbackSpool {
  try {
    $dir = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $HOME }
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = [IO.Path]::GetTempPath() }
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    $name = 'tracebloc-telemetry-' + $script:TbTelemetryInstanceId + '.jsonl'
    return (Join-Path $dir $name)
  } catch {
    Write-TelemetryDebug "fallback spool path failed: $_"
    return $null
  }
}

# Keep the data-dir spool bounded: nothing drains it until backend#2217, and an
# unbounded append on a customer's disk would be a defect shipped on purpose.
# DROP-OLDEST, deliberately unlike RFC-BACKEND-1872 D7's amended overflow row —
# D7 drops newest because `exporterhelper` sheds at the entrance and offers
# nothing else, a constraint on the Collector's queue rather than a preference.
# This spool is our own code, so it keeps the newest records, which are the ones
# describing the failure in progress. Nothing here can lose the record: it is
# already appended, so every failure path is swallowed.
function Limit-TelemetrySpool {
  param([string]$Spool)
  try {
    if (-not (Test-Path -LiteralPath $Spool)) { return }
    $lines = @(Get-Content -LiteralPath $Spool -ErrorAction Stop)
    if ($lines.Count -le $script:TbTelemetrySpoolMax) { return }
    $keep = $lines[-$script:TbTelemetrySpoolMax..-1]
    $tmp = "$Spool.tmp"
    Set-Content -LiteralPath $tmp -Value $keep -Encoding utf8 -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $Spool -Force -ErrorAction Stop
  } catch {
    Write-TelemetryDebug "spool trim failed: $_"
    try { Remove-Item -LiteralPath "$Spool.tmp" -Force -ErrorAction SilentlyContinue } catch { }
  }
}

# THE TRANSPORT SEAM (backend#1905). Today: the install log where there is one,
# plus a bounded local spool. Nothing is posted anywhere yet — the host transport
# is backend#2217, and NOT #1906's Collector, which is a pod inside the cluster
# and can reach neither of these files.
#
# A FAILED WRITE FALLS THROUGH rather than returning: HOST_DATA_DIR present but
# not writable is precisely when the log has already fallen back elsewhere, so a
# `return` here loses the record in the one case the fallback exists for
# (Bugbot on client#747, both halves reproduced). The single `return` below sits
# after a SUCCESSFUL append and nowhere else, so the record is written at most
# once with no flag to keep in step.
function Send-TelemetryRecord {
  param([string]$Json)

  # The install log gets it WHERE THERE IS ONE. `Log` is a no-op until
  # $script:LOG_FILE is set by Start-InstallLog, and that happens after the
  # pre-log guards (Confirm-Config, Initialize-ToolDir) —
  # which are exactly the failures the run-started latch exists to preserve.
  try {
    # -CommandType Function IS LOAD-BEARING, not tidiness. `Get-Command Log`
    # matches any `log` on PATH — on macOS that is /usr/bin/log, the system
    # logger — so without it this line shelled out to a completely unrelated
    # binary and printed its help. Found by running the suite on a non-Windows
    # host, which is where CI runs it too.
    if (Get-Command -Name 'Log' -CommandType Function -ErrorAction SilentlyContinue) {
      Log "telemetry: $Json"
    }
  } catch { Write-TelemetryDebug "log write failed: $_" }

  $root = $env:HOST_DATA_DIR
  if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
    try {
      $spool = Get-TelemetrySpoolPath
      if ($spool) {
        $dir = Split-Path -Parent $spool
        if (-not (Test-Path -LiteralPath $dir)) {
          New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -LiteralPath $spool -Value $Json -Encoding utf8 -ErrorAction Stop
        Limit-TelemetrySpool -Spool $spool
        return
      }
    } catch {
      Write-TelemetryDebug "data-dir spool failed, falling through: $_"
    }
  }

  try {
    $fallback = Get-TelemetryFallbackSpool
    if ($fallback) {
      Add-Content -LiteralPath $fallback -Value $Json -Encoding utf8 -ErrorAction Stop
    }
  } catch {
    Write-TelemetryDebug "fallback spool failed: $_"
  }
}

# ── The one event this install produces ──────────────────────────────────────
#  Emits at most once per process, and never throws. An installer that failed
#  because telemetry was unhappy would be a strictly worse installer.
function Send-TelemetryOutcome {
  param([int]$Code = 0)
  try {
    if ($script:TbTelemetryEmitted) { return }
    $script:TbTelemetryEmitted = $true
    # No latch, no event: the exit path also runs for -Help, which installs
    # nothing. A false success is worse here than a missing one.
    if (-not $script:TbTelemetryRunStarted) { return }
    if (-not (Test-TelemetryEnabled)) { return }
    $json = Get-TelemetryEvent -Code $Code
    if ([string]::IsNullOrEmpty($json)) { return }
    Send-TelemetryRecord -Json $json
  } catch {
    Write-TelemetryDebug "emit failed: $_"
  }
}
