# =============================================================================
#  install-wsl-record.ps1 -- sections 6 and 7 of install-wsl.ps1: the install
#  record, the host CLI's deadlines and ending a process tree.
#
#  install-wsl.ps1 dot-sources this file from beside itself, at the place the
#  sections stand in its order, and checks it through $CoreFiles; install.ps1
#  fetches and verifies it with the rest ($Files).
# =============================================================================

# =============================================================================
#  6. The install record: what `tracebloc delete` removes on Windows.
#
#  `tracebloc delete` on Windows reads the daily user's record, the schema's
#  x-tracebloc-record.user-path under %USERPROFILE%. The core keeps its own record
#  inside the distro, as root and with the distro's paths, and `wsl --unregister`
#  deletes it with everything it names. So the host record carries the core's
#  top-level fields, read back from the core's own record and never restated here,
#  and the artefacts the Windows path creates on the host, in the order it creates
#  them (the kinds and their ids are install-record.schema.json's):
#    wsl-distro    tracebloc, path its import folder, %LOCALAPPDATA%\tracebloc\wsl
#    logon-task    \tracebloc-keepalive, no path
#    kube-context  the context the core merged into the host kubeconfig, path that
#                  file as Windows names it
#  A re-run keeps an artefact the record already names, with its created_at, as
#  the core's writer does. Best-effort, like the core's: a record that cannot be
#  read or written is said, never fatal.
#
#  Invoke-WslInstall saves it after the client run (section 5), and after a stop
#  past the logon task too, once the core's own record can be read, so that
#  tracebloc delete finds what a failed install left.
# =============================================================================

# The record's place, as the schema's x-tracebloc-record.user-path names it: under
# %USERPROFILE% on the host, under root's home in the distro, where the core runs.
# Pester holds both to the schema.
$HostRecordRelPath = '.tracebloc\install-record.json'
$CoreRecordPath = '/root/.tracebloc/install-record.json'
# The top-level fields the host record takes from the core's. The rest are the
# host's own (user, updated_at, artefacts) or have no meaning on the host.
$CoreRecordFields = @('schema_version', 'substrate', 'cluster_name', 'kube_context', 'data_dir', 'namespace', 'installer_version')

# The folder the distro is imported into, which holds its virtual disk.
function Get-WslImportDir {
  return (Join-Path $env:LOCALAPPDATA 'tracebloc\wsl')
}

function Get-HostRecordPath {
  return (Join-Path $env:USERPROFILE $HostRecordRelPath)
}

function Get-RecordTimestamp {
  return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

# The core's record, read from the distro, or $null when it cannot be read. cat is
# named by its path: WSL did not find /usr/sbin's update-ca-certificates by name
# for `wsl -u root --exec` (S-W row 9), though the command's own PATH holds
# /usr/sbin (S-W's home row). So no program there is looked up by name.
$DistroCat = '/usr/bin/cat'
function Read-CoreInstallRecord {
  $r = Invoke-WslProbe -ArgumentList @('-d', $WslDistroName, '-u', 'root', '--exec', $DistroCat, $CoreRecordPath) -TimeoutSec $WslDistroStartTimeoutSec
  if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not $r.Output) { return $null }
  try { return ($r.Output | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# The record already on the host, or $null when there is none or it cannot be read.
function Read-HostInstallRecord {
  $path = Get-HostRecordPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# THE RETIRED WINDOWS INSTALL. This installer no
# longer sets up tracebloc's earlier Windows install, nor moves a machine off it.
# The distro beside one would be a second client, and both would want the
# Kubernetes API port on localhost. So one is refused by name before WSL is
# touched, read from its files first:
#   - the host record (above), when its substrate is one the schema retires on
#     Windows: x-tracebloc-substrate.retired.windows, which Pester holds these
#     keys to. A record that is there but cannot be read is "cannot tell",
#     refused too;
#   - the retired PowerShell core's state file, install-state.json in its default
#     data folder. Only that core wrote it; one that a custom
#     TRACEBLOC_HOST_DATA_DIR put elsewhere is not looked for;
#   - the context that install wrote into the user's kubeconfig: every file of
#     KUBECONFIG when it is set, else %USERPROFILE%\.kube\config. A name key whose
#     whole value is the context's name, in any spelling kubectl reads (block or flow
#     YAML, JSON, a quoted key, a trailing comment), and not on a comment line: the mark
#     the tracebloc CLI's delete trusts too. That file is the user's, not ours, so one that cannot be
#     read is no mark;
#   - with none of them, the containers Docker still has for the cluster that
#     context names (Get-RetiredClusterContainer): a record, a state file and a
#     context deleted by hand leave the cluster running.
# None of them: nothing is left to keep, and the install goes on.
# Each retired substrate, with the name a customer knew its install by and the
# context it wrote (the substrate, then settings.sh's default cluster name, as
# k3s-kubeconfig.sh's _native_k3s_context names the distro's): the one line here that
# names it.
$RetiredInstalls = [ordered]@{
  k3d = @{ Name = 'Docker Desktop with k3d'; Context = 'k3d-tracebloc' }
}
$RetiredInstallNames = @($RetiredInstalls.Values | ForEach-Object { $_.Name }) -join ' or '
$RetiredCoreStateRelPath = '.tracebloc\install-state.json'

# The path of the program NAME on PATH, or $null. Pester's seam for what is installed.
function Find-HostCommand {
  param([string]$Name)
  $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# The first container Docker lists, stopped ones too, under the label k3d gives
# every container of the cluster CLUSTER: '' when it lists none or no docker
# command is here, $null when it fails or does not answer while k3d is installed.
function Get-RetiredClusterContainer {
  param([string]$Cluster)
  $docker = Find-HostCommand 'docker'
  if (-not $docker) { return '' }
  $p = Invoke-WslProbe -FilePath $docker -ArgumentList @('ps', '-a', '--filter', "label=k3d.cluster=$Cluster", '--format', '{{.Names}}') -TimeoutSec $WslProbeTimeoutSec
  if ($p.Started -and -not $p.TimedOut -and $p.ExitCode -eq 0) {
    $names = @($p.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($names.Count -gt 0) { return [string]$names[0] }
    return ''
  }
  if (Find-HostCommand 'k3d') { return $null }
  return ''
}

# What Docker says on this machine: 'usable' when docker lists containers, 'absent' when
# there is no docker command, it cannot start, or it answers with a failure, and
# 'unknown' when it does not answer in time: a wedged daemon is not a gone one.
function Get-HostDockerState {
  $docker = Find-HostCommand 'docker'
  if (-not $docker) { return 'absent' }
  $p = Invoke-WslProbe -FilePath $docker -ArgumentList @('ps', '-q') -TimeoutSec $WslProbeTimeoutSec
  if ($p.TimedOut) { return 'unknown' }
  if ($p.Started -and $p.ExitCode -eq 0) { return 'usable' }
  return 'absent'
}

# The contexts: section of a kubeconfig, its header line included, and nothing else:
# a cluster or user named k3d-* is no context. JSON has no lines to split on: it
# is read for its contexts, and text that does not parse is returned whole.
function Get-KubeconfigContextsText {
  param([string]$Text)
  if ($Text -match '^\s*\{') {
    try {
      $j = $Text | ConvertFrom-Json -ErrorAction Stop
      return ('{"contexts":' + (ConvertTo-Json -InputObject @($j.contexts) -Depth 20 -Compress) + '}')
    } catch { return $Text }
  }
  $in = $false
  $keep = foreach ($line in ($Text -split "`n")) {
    if ($line -match '^[^ \t\r#-]') { $in = ($line -match '^contexts[ \t]*:') }
    if ($in) { $line }
  }
  return (@($keep) -join "`n")
}

# Whether kubeconfig TEXT has the context CONTEXT, in the spellings the header above
# lists. Only its contexts: are read: a cluster or user of that name is no context.
function Test-KubeconfigContext {
  param([string]$Text, [string]$Context)
  $named = '(?m)(?<![\w.@-])(?<!^[ \t]*#[^\r\n]*)["'']?name["'']?[ \t]*:[ \t]*["'']?' + [regex]::Escape($Context) + '["'']?(?=[ \t]*(?:[,}\]\r\n]|$)|[ \t]+#)'
  return ((Get-KubeconfigContextsText $Text) -match $named)
}

# The value VALUE of a kubeconfig key, as kubectl reads it: less a trailing comment
# and the quotes around it.
function ConvertFrom-KubeconfigValue {
  param([string]$Value)
  $v = ($Value -replace '[ \t]+#.*$', '').TrimEnd(" `t`r")
  if ($v.Length -ge 2 -and ($v[0] -eq '"' -or $v[0] -eq "'") -and $v[-1] -eq $v[0]) { $v = $v.Substring(1, $v.Length - 2) }
  return $v
}

# The kubeconfig text less the item under contexts: named CONTEXT, and a
# current-context that names it; every other context is the user's and stays. An
# item starts at a dash in its list's column, and its name is a key in the item's own
# column: a list nested in a context (its extensions) neither ends it nor names it.
# Block layout only, which kubectl and k3d write. reinstall.sh's twin:
# _reinstall_drop_context.
function Remove-KubeconfigContextText {
  param([string]$Text, [string]$Context)
  $named = {
    param([string]$l)
    if ($l -notmatch '^"?name"?[ \t]*:') { return $false }
    return ((ConvertFrom-KubeconfigValue ($l -replace '^"?name"?[ \t]*:[ \t]*', '')) -ceq $Context)
  }
  $out = New-Object System.Collections.ArrayList
  $buf = New-Object System.Collections.ArrayList
  $drop = $false
  $sec = ''
  $col = -1; $kcol = -1
  foreach ($line in ($Text -split "`n")) {
    if ($line -match '^[^ \t\r#-]') {
      if (-not $drop) { foreach ($b in $buf) { [void]$out.Add($b) } }
      $buf.Clear(); $drop = $false; $col = -1
      $sec = ($line -replace '[ \t]*:.*$', '').Replace('"', '').Trim()
      if ($sec -eq 'current-context' -and (ConvertFrom-KubeconfigValue ($line -replace '^[^:]*:[ \t]*', '')) -ceq $Context) { continue }
      [void]$out.Add($line); continue
    }
    if ($sec -eq 'contexts') {
      $lead = $line.Length - $line.TrimStart(" `t").Length
      $rest = $line.Substring($lead).TrimEnd("`r")
      if ($rest -match '^-([ \t]|$)' -and ($col -lt 0 -or $lead -eq $col)) {
        if (-not $drop) { foreach ($b in $buf) { [void]$out.Add($b) } }
        $buf.Clear(); $drop = $false; $col = $lead
        $after = $rest -replace '^-[ \t]*', ''
        $kcol = $lead + ($rest.Length - $after.Length)
        if ($after -eq '' -or $after.StartsWith('#')) { $kcol = -1 }
        elseif (& $named $after) { $drop = $true }
      } elseif ($col -ge 0 -and $rest -ne '' -and -not $rest.StartsWith('#')) {
        if ($kcol -lt 0) { $kcol = $lead }
        if ($lead -eq $kcol -and (& $named $rest)) { $drop = $true }
      }
      [void]$buf.Add($line); continue
    }
    [void]$out.Add($line)
  }
  if (-not $drop) { foreach ($b in $buf) { [void]$out.Add($b) } }
  return ($out -join "`n")
}

# With Docker absent, a k3d install's cluster is out of this run's reach: remove its
# context ($RetiredInstalls) from each kubeconfig, and no other, move the install
# record aside, say so in two lines; STATE, the retired core's state file, goes aside
# too. $true when done; $false when a file cannot be changed, which leaves the
# refusal to stand.
function Clear-RetiredK3dInstall {
  param([string]$Record, [string]$State, [string[]]$Kubeconfigs)
  # A failure puts every file back as it was, so the refusal's "Nothing was changed" holds.
  $saved = [System.Collections.Generic.List[object]]::new()
  $moved = [System.Collections.Generic.List[object]]::new()
  $undo = {
    foreach ($m in $moved) { try { Move-Item -LiteralPath $m[1] -Destination $m[0] -ErrorAction Stop } catch { $null = $_ } }
    foreach ($s in $saved) { try { [IO.File]::WriteAllText($s[0], $s[1]) } catch { $null = $_ } }
  }
  $context = $RetiredInstalls['k3d'].Context
  foreach ($kc in $Kubeconfigs) {
    if (-not (Test-Path -LiteralPath $kc)) { continue }
    try {
      $text = [IO.File]::ReadAllText($kc)
      $new = Remove-KubeconfigContextText -Text $text -Context $context
      if ($new -ne $text) {
        [void]$saved.Add(@($kc, $text))
        [IO.File]::WriteAllText($kc, $new)
      }
    } catch { & $undo; return $false }
  }
  $cluster = $context -replace '^k3d-', ''
  $done = "Deleted its kubectl context $context"; $aside = $null
  $stamp = '.k3d-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
  if (Test-Path -LiteralPath $Record) {
    $aside = $Record + $stamp
    try { Move-Item -LiteralPath $Record -Destination $aside -ErrorAction Stop } catch { & $undo; return $false }
    [void]$moved.Add(@($Record, $aside))
    $done += " and moved its install record to $aside"
  }
  # Left here, the state file would be read as that install on the next run, which
  # would then refuse the machine and name 'tracebloc delete' as the way out.
  if ($State -and (Test-Path -LiteralPath $State)) {
    try { Move-Item -LiteralPath $State -Destination ($State + $stamp) -ErrorAction Stop } catch { & $undo; return $false }
    $done += $(if ($aside) { ' and its ' } else { ' and moved its ' }) + (Split-Path -Leaf $State) + " to $State$stamp"
  }
  Info "Docker isn't available, so the old secure environment '$cluster' stays as it is. It shows as Offline on tracebloc."
  Info "$done."
  return $true
}

# Refuses, by name, a machine on the retired Windows install (above).
function Assert-NoRetiredInstall {
  # The way out, last in each message: delete that secure environment with
  # 'tracebloc delete', then the state file and the context if they are still there
  # (a delete that finds no install record leaves them), then this installer again.
  $state = Join-Path $env:USERPROFILE $RetiredCoreStateRelPath
  $contexts = @($RetiredInstalls.Values | ForEach-Object { $_.Context }) -join ' and '
  $move = 'To move it, delete that secure environment with ''tracebloc delete''. Then delete ' + $state + ' and the ' + $contexts + ' entries from your kubeconfig if they are still there, and run this installer again.'
  $record = Get-HostRecordPath
  $kubeconfigs = if ($env:KUBECONFIG) { @($env:KUBECONFIG -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @(Join-Path (Join-Path $env:USERPROFILE '.kube') 'config') }
  # Read as reinstall.sh's _reinstall_k3d_said reads it: a record decides alone (one of another
  # substrate, or one that cannot be read, is never cleared and meets the checks below), and
  # with none only the retired install's own context says k3d, never another k3d cluster's.
  $saysK3d = $false
  if (Test-Path -LiteralPath $record) {
    try { $saysK3d = ([string]((Get-Content -Raw -LiteralPath $record -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop).substrate) -eq 'k3d') } catch { $saysK3d = $false }
  } else {
    foreach ($kc in $kubeconfigs) {
      $t = $null
      try { $t = [IO.File]::ReadAllText($kc) } catch { $t = $null }
      if ($t -and (Test-KubeconfigContext $t $RetiredInstalls['k3d'].Context)) { $saysK3d = $true }
    }
  }
  if ($saysK3d -and (Get-HostDockerState) -eq 'absent' -and (Clear-RetiredK3dInstall -Record $record -State $state -Kubeconfigs $kubeconfigs)) { return }
  if (Test-Path -LiteralPath $record) {
    $rec = $null
    try { $rec = Get-Content -Raw -LiteralPath $record -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $rec = $null }
    $sub = if ($rec) { [string]$rec.substrate } else { '' }
    if (-not $sub) {
      Stop-Setup -What "Couldn't read this machine's install record" -Next "Fix or delete $record, then run the installer again:" -Reason "This machine has a tracebloc install record, $record, that this installer cannot read, so it cannot tell whether a secure environment on $RetiredInstallNames is still set up here, and the tracebloc WSL distro is never set up beside one. Fix or delete that file if no such secure environment is left, then re-run. Nothing was changed on this machine."
    }
    if ($RetiredInstalls.Contains($sub)) {
      Stop-Setup -What "This machine runs a secure environment on $($RetiredInstalls[$sub].Name)" -Next 'To move it to WSL, delete it, then run the installer again:' -Command 'tracebloc delete' -Reason "This machine has a secure environment on $($RetiredInstalls[$sub].Name) (its install record $record says so), and this installer no longer sets one up or moves one. Nothing was changed on this machine. $move"
    }
  }
  if (Test-Path -LiteralPath $state) {
    Stop-Setup -What "This machine runs a secure environment on $RetiredInstallNames" -Next 'To move it to WSL, delete it, then run the installer again:' -Command 'tracebloc delete' -Reason "This machine has a secure environment on $RetiredInstallNames ($state, which only its installer wrote, is here), and this installer no longer sets one up or moves one. Nothing was changed on this machine. If that secure environment is already gone, delete $state and re-run. $move"
  }
  foreach ($kc in $kubeconfigs) {
    $text = $null
    try { $text = [IO.File]::ReadAllText($kc) } catch { $text = $null }
    if (-not $text) { continue }
    foreach ($r in $RetiredInstalls.Values) {
      if (Test-KubeconfigContext $text $r.Context) {
        Stop-Setup -What "This machine runs a secure environment on $($r.Name)" -Next 'To move it to WSL, delete it, then run the installer again:' -Command 'tracebloc delete' -Reason "This machine has a secure environment on $($r.Name) (the kubeconfig $kc has its context, $($r.Context)), and this installer no longer sets one up or moves one. Nothing was changed on this machine. If that secure environment is already gone, delete the $($r.Context) entries from $kc and re-run. $move"
      }
    }
  }
  $r = $RetiredInstalls['k3d']
  if ($r) {
    $cluster = $r.Context -replace '^k3d-', ''
    $found = Get-RetiredClusterContainer $cluster
    if ($null -eq $found) {
      Stop-Setup -What "Docker didn't answer whether a secure environment on $($r.Name) is still here" -Next 'Start Docker Desktop, then run the installer again:' -Reason "k3d is installed on this machine, and Docker did not answer whether it has the containers of the cluster $cluster, so this installer cannot tell whether a secure environment on $($r.Name) is still set up here, and the tracebloc WSL distro is never set up beside one. Start Docker Desktop, then re-run. Nothing was changed on this machine."
    }
    if ($found) {
      Stop-Setup -What "This machine runs a secure environment on $($r.Name)" -Next 'To move it to WSL, delete it, then run the installer again:' -Command 'tracebloc delete' -Reason "This machine has a secure environment on $($r.Name) (Docker has the containers of its cluster $cluster, $found), and this installer no longer sets one up or moves one. Nothing was changed on this machine. $move"
    }
  }
}

# The host record: CORE's top-level fields, this user, and the host's artefacts.
# PRIOR's artefacts come first and are kept as they are; one already there (the
# same kind, id and path) is not added again. KUBECONFIG is the host file the core
# merged its context into.
function New-HostInstallRecord {
  param([object]$Core, [object]$Prior, [string]$Kubeconfig, [string]$Now)
  $arts = New-Object System.Collections.ArrayList
  if ($Prior -and $Prior.artefacts) { foreach ($a in @($Prior.artefacts | ForEach-Object { $_ })) { [void]$arts.Add($a) } }
  $want = @(
    [ordered]@{ kind = 'wsl-distro'; id = $WslDistroName; path = (Get-WslImportDir) }
    [ordered]@{ kind = 'logon-task'; id = $KeepaliveTaskId; path = $null }
  )
  if ($Core.kube_context) { $want += [ordered]@{ kind = 'kube-context'; id = [string]$Core.kube_context; path = $Kubeconfig } }
  foreach ($w in $want) {
    $have = @($arts | Where-Object { $_.kind -ceq $w.kind -and $_.id -ceq $w.id -and $_.path -ceq $w.path })
    if ($have.Count -eq 0) { $w.created_at = $Now; [void]$arts.Add([pscustomobject]$w) }
  }
  $rec = [ordered]@{}
  foreach ($f in $CoreRecordFields) {
    $rec[$f] = $Core.$f
    if ($f -eq 'substrate') { $rec['user'] = $env:USERNAME }
  }
  $rec['updated_at'] = $Now
  $rec['artefacts'] = @($arts)
  return $rec
}

# Writes RECORD to the host record path: UTF-8 with no BOM, through a temporary
# file in the same folder, so a reader never sees half a record.
function Write-HostInstallRecord {
  param([System.Collections.IDictionary]$Record)
  $path = Get-HostRecordPath
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = Join-Path $dir ('.install-record.' + [guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

# Records this install on the host, after the client run, or after a stop past the
# import. Never fatal; returns whether the record was written. -IfAny is a stop's:
# a core that has not written its own record yet leaves nothing to record, and that
# is not said, as the stop names what it left.
function Save-HostInstallRecord {
  param([string]$Kubeconfig, [switch]$IfAny)
  $core = Read-CoreInstallRecord
  if (-not $core) {
    if (-not $IfAny) { Warn "The tracebloc WSL distro's install record could not be read, so this install was not recorded on Windows. tracebloc delete will not find it; share this output with tracebloc support." }
    return $false
  }
  try {
    Write-HostInstallRecord -Record (New-HostInstallRecord -Core $core -Prior (Read-HostInstallRecord) -Kubeconfig $Kubeconfig -Now (Get-RecordTimestamp))
    return $true
  } catch {
    Warn "This install could not be recorded in $(Get-HostRecordPath) ($($_.Exception.Message)). tracebloc delete will not find it; share this output with tracebloc support."
    return $false
  }
}

# =============================================================================
#  7. Deadlines, and ending a process tree: the host CLI's runs with no terminal
#     (Invoke-HostCliNoInput, Invoke-HostExample).
# =============================================================================

# Each deadline's default, by the name the core reads it under: a Pester case holds
# each to every `${NAME:-default}` in lib/.
$ReinstallTimeouts = [ordered]@{
  TRACEBLOC_EXAMPLE_TIMEOUT = '15m'
}

# The deadline NAME as this run reads it: the variable NAME, else the default above.
# The text as given, for the words that name it.
function Get-ReinstallTimeout {
  param([string]$Name)
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ($v) { return $v }
  return $ReinstallTimeouts[$Name]
}

# The longest wait a .NET WaitForExit takes, in seconds: what 0 (no deadline, as
# timeout(1) reads it) becomes.
$NoDeadlineSec = [int][Math]::Floor([int]::MaxValue / 1000)

# NAME's deadline in seconds, read as timeout(1) reads it: a whole number, then s,
# m, h or d, or nothing for seconds. A value it cannot read is refused by name.
function Get-ReinstallTimeoutSeconds {
  param([string]$Name)
  $text = Get-ReinstallTimeout -Name $Name
  if ($text -cmatch '^([0-9]{1,9})([smhd]?)$') {
    $mult = switch -CaseSensitive ($Matches[2]) { 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { 1 } }
    $sec = [long]$Matches[1] * $mult
    if ($sec -eq 0 -or $sec -gt $NoDeadlineSec) { return $NoDeadlineSec }
    return [int]$sec
  }
  throw "$Name is not a deadline this installer can read (got '$text'). Set it to a whole number of seconds, or one ending in s, m, h or d."  # Windows only: timeout(1) reads it on the core's side
}

# Ends PROCESS and every process it started: a host CLI run stopped at its
# deadline must not leave what it started running. .NET's Kill(true) ends the
# tree; Windows PowerShell 5.1's .NET Framework has only Kill(), which ends PROCESS
# alone, so there taskkill /T ends the tree.
function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)
  $ended = $false
  if (Test-ProcessTreeKill) { try { Invoke-TreeKill -Process $Process; $ended = $true } catch { } }
  # Where Kill(true) is absent, or threw (a child it could not end), taskkill /T tries the tree.
  if (-not $ended) { Invoke-Taskkill -Arguments @('/T', '/F', '/PID', "$($Process.Id)") }
  try { $null = $Process.WaitForExit(10000) } catch { }
}

# Process.Kill(entireProcessTree) on PROCESS, where this .NET has it: a seam.
function Invoke-TreeKill { param([System.Diagnostics.Process]$Process) $Process.Kill($true) }

# Whether this .NET's Process.Kill takes entireProcessTree (.NET Core 3.0 on): a seam.
function Test-ProcessTreeKill { return [bool]([System.Diagnostics.Process].GetMethod('Kill', [type[]]@([bool]))) }

# taskkill under %WINDIR% with ARGUMENTS, its output dropped: a seam.
function Invoke-Taskkill {
  param([string[]]$Arguments)
  try { $null = & "$env:WINDIR\System32\taskkill.exe" @Arguments 2>&1 } catch { }
}
