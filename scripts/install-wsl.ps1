# =============================================================================
#  install-wsl.ps1 -- the Windows distro path (RFC-0175 D2, D7; client-dev#1810)
#
#  install.ps1 runs this as a child process (powershell.exe -File) when
#  TRACEBLOC_SUBSTRATE=k3s, where it would otherwise run install-k8s.ps1. It is
#  in install.ps1's $Files and in the signed manifest, so on the customer path it
#  runs only after install.ps1 has verified it.
#
#  -CoreDir is the one tree it may use:
#    - on the customer path, ONLY the temp dir install.ps1 has just verified
#      against the signed manifest (the sub-scripts plus manifest.sha256, laid
#      out as under scripts/);
#    - for e2e, a commit's own scripts/ directory, with that commit's
#      manifest.sha256, which CI holds current.
#  Either way, every file this script uses from the tree is checked again against
#  the tree's manifest.sha256, and a tree that fails is refused by name. Nothing
#  here or in install.ps1 skips that check. The signature over the manifest is
#  install.ps1's to check, before it hands the tree over.
#
#  It fetches nothing unverified: the distro image is checked against its pinned
#  length and sha256 before `wsl --import`.
#
#  Exit codes, which install.ps1 passes through unchanged:
#    0  done
#    1  a named refusal or a failure, already explained on screen
#    2  a restart is needed first, then the same install command again
#       (install-k8s.ps1's declared "restart, then re-run" code)
#
#  The path stays behind TRACEBLOC_SUBSTRATE=k3s until 3.3's cell is green on it
#  (D14 item 9). Its steps land in the numbered sections below, one PR each
#  (client-dev#1810 part 1).
# =============================================================================
#Requires -Version 5.1
param([string]$CoreDir)

# Byte-identical to install.ps1's helpers; a Pester test holds them so.
function Info($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green    -NoNewline; Write-Host " $m" }
function Warn($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow   -NoNewline; Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red      -NoNewline; Write-Host " $m" -ForegroundColor Red }

# Byte-identical to install.ps1's; a Pester test holds them so.
function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Find-ManifestDigest {
  param([string]$ManifestPath, [string]$Key)
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -eq $Key) {
      return $parts[0].ToLower()
    }
  }
  return $null
}

# Byte-identical to install.ps1's: someone at this console can answer a prompt.
function Test-BootstrapCanPrompt {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
  catch { return $false }
}

# What this script uses from -CoreDir, as manifest keys. This script is one of
# them: the tree it is handed must hold the same verified copy of it.
$CoreFiles = @('scripts/install-wsl.ps1')

# Refuses, by name, a -CoreDir it cannot verify against the manifest.sha256 in it.
function Confirm-CoreDir {
  param([string]$CoreDir, [string[]]$Files = $CoreFiles)
  if (-not $CoreDir) {
    throw "No installer tree was given (-CoreDir), so there is nothing verified to run."
  }
  if (-not (Test-Path -LiteralPath $CoreDir -PathType Container)) {
    throw "The installer tree $CoreDir does not exist."
  }
  $manifest = Join-Path $CoreDir 'manifest.sha256'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "$CoreDir is not a verified installer tree: it has no manifest.sha256, so nothing in it can be checked."
  }
  foreach ($f in $Files) {
    $expected = Find-ManifestDigest -ManifestPath $manifest -Key $f
    if (-not $expected) {
      throw "$CoreDir is not a verified installer tree: its manifest.sha256 lists no $f."
    }
    $local = Join-Path $CoreDir ($f -replace '^scripts/', '')
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
      throw "$CoreDir is not a verified installer tree: $f is missing from it."
    }
    if ((Get-Sha256 -Path $local) -ne $expected) {
      throw "$CoreDir is not a verified installer tree: $f does not match its manifest.sha256 entry."
    }
  }
}

# =============================================================================
#  1. WSL ready (RFC-0175 D7)
# =============================================================================
# The first step of the WSL path: WSL at or above the floor, or a plain stop.
# Enabling WSL needs an administrator once per machine, and no option avoids it
# (D7). So:
#   - WSL already at the floor: nothing to do.
#   - The daily user is not an administrator (or no one can answer the Windows
#     prompt): print the one IT command and stop. Nothing is elevated.
#   - The user is an administrator: Windows asks once (UAC), and ONLY the IT
#     command runs elevated. The installer itself never relaunches elevated, so
#     everything after this step runs as the user (D7), and an `irm | iex` run
#     needs no file to relaunch.
#   - Turning WSL on wants a restart: a resume marker is written, and the same
#     install command run again after the restart continues from here.
# Every answer this cannot read is "cannot tell", and "cannot tell" is never
# "ready": it takes the same branch as a missing WSL.
#
# The values S-W measures are named here, so its rows change values, not code.

# TODO(S-W row 1, backend#5416): the floor is RFC-0175 D7's, WSL 2.5 (cgroup v2
# by default). Row 1 records `wsl --version` on the managed laptop; set it here.
$WslMinVersion = '2.5'

# The one IT command D7 names. The refusal prints it, and the elevated step
# runs it, from this one list.
$WslInstallArgs = @('--install', '--no-distribution')
# TODO(S-W row 1): whether that command lifts an installed WSL that is below the
# floor, or IT needs `wsl --update` for that case. Until row 1 says, both cases
# get the one command.
$WslUpdateArgs = $WslInstallArgs

# TODO(S-W row 2): how many restarts turning WSL on takes. Row 2 records the
# boots and restarts after the IT step; one until it says.
$WslEnableMaxRestarts = 1
# TODO(S-W row 2): the exit code `wsl --install --no-distribution` returns when it
# needs a restart. 3010 and 1641 are Windows' "succeeded, restart needed /
# restarting" codes (install-k8s.ps1's INSTALLER_REBOOT_OK_CODES has them too),
# not a measurement of wsl.exe. Any other non-zero code is a failure.
$WslEnableOkCodes = @(0, 3010, 1641)

$WslProbeTimeoutSec  = 30
$WslEnableTimeoutSec = 1200

# "2.5" or "2.5.10.0" as a four-part [version], so 2.5.0 and 2.5.0.0 compare equal
# ([version] ranks a missing part below 0). $null for anything else.
function ConvertTo-WslVersion {
  param([AllowNull()][string]$Text)
  if ($Text -notmatch '^\d+(\.\d+){1,3}$') { return $null }
  $p = @($Text.Split('.') | ForEach-Object { $_ })
  while ($p.Count -lt 4) { $p += '0' }
  try { return [version]($p -join '.') } catch { return $null }
}

# The WSL version from `wsl --version`'s output, or $null when this cannot tell.
# The labels are localized ("WSL version", "WSL-Version", "Version de WSL"), but
# every one keeps the word WSL, a colon and the number; the lines after it
# (Kernel, WSLg, MSRDC, ...) carry other words or other shapes. So: the first line
# of that shape, whole. Read defensively:
#   - wsl.exe writes UTF-16LE unless WSL_UTF8=1 reaches it, and an old wsl.exe
#     ignores the variable, so NULs are stripped (and a BOM) before matching.
#   - An old inbox wsl.exe answers --version with its usage text, which has no
#     such line: $null, never a guess.
function ConvertFrom-WslVersionText {
  param([AllowNull()][string]$Text)
  if (-not $Text) { return $null }
  $clean = ($Text -replace "`0", '') -replace ([string][char]0xFEFF), ''
  foreach ($line in ($clean -split "`r?`n")) {
    $m = [regex]::Match($line, '^[^:\uFF1A]*\bWSL\b[^:\uFF1A]*[:\uFF1A]\s*(\d+(?:\.\d+){2,3})\s*$')
    if ($m.Success) { return (ConvertTo-WslVersion $m.Groups[1].Value) }
  }
  return $null
}

# Runs one wsl.exe command, bounded, with WSL_UTF8=1, and reports what happened
# without judging it. The only function here that starts wsl.exe to read it.
# -FilePath is a seam for the test suite.
function Invoke-WslProbe {
  param([string]$FilePath = 'wsl.exe', [string[]]$ArgumentList = @('--version'), [int]$TimeoutSec = $WslProbeTimeoutSec)
  $r = [pscustomobject]@{ Started = $false; TimedOut = $false; ExitCode = $null; Output = ''; StartError = ''; NativeErrorCode = $null }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = ($ArgumentList -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.EnvironmentVariables['WSL_UTF8'] = '1'
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
  } catch {
    # A start failure is kept whole for Test-WslBlockedByPolicy: the message and,
    # for a Win32 refusal, its code.
    $e = $_.Exception
    while ($e.InnerException -and -not ($e -is [System.ComponentModel.Win32Exception])) { $e = $e.InnerException }
    $r.StartError = $e.Message
    if ($e -is [System.ComponentModel.Win32Exception]) { $r.NativeErrorCode = $e.NativeErrorCode }
    return $r
  }
  $r.Started = $true
  $out = $p.StandardOutput.ReadToEndAsync()
  $null = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $r.TimedOut = $true
    try { $p.Kill() } catch { $r.StartError = "could not stop it: $($_.Exception.Message)" }
    return $r
  }
  $p.WaitForExit()
  $r.ExitCode = $p.ExitCode
  $r.Output = [string]$out.Result
  return $r
}

# TODO(S-W row 2, backend#5470): the hook for an organisation's policy refusing
# wsl.exe (AppLocker or WDAC). How such a refusal looks on a managed laptop -- the
# start error, its code, an event-log entry -- is what row 2 records, so this does
# not guess: it answers "not blocked", and a blocked wsl.exe reads as "cannot tell",
# which stops with the IT command all the same. When row 2 says, this answers from
# the probe (Invoke-WslProbe's StartError, NativeErrorCode, ExitCode, Output), and
# the named refusal in Confirm-WslReady is already wired to it.
function Test-WslBlockedByPolicy {
  param([object]$Probe)
  $null = $Probe
  return $false
}

# Where WSL stands: ready, old (below the floor), blocked (by policy), or
# cannot-tell, with the reason in words. Only a version read whole from a clean
# exit can be ready.
function Get-WslState {
  param([string]$MinVersion = $WslMinVersion)
  $min = ConvertTo-WslVersion $MinVersion
  if (-not $min) { throw "The WSL floor '$MinVersion' is not a version." }
  $p = Invoke-WslProbe -ArgumentList @('--version')
  $v = $null
  if (-not $p.Started) {
    $why = "wsl.exe did not start ($($p.StartError))"
  } elseif ($p.TimedOut) {
    $why = "wsl --version did not answer within $WslProbeTimeoutSec seconds"
  } elseif ($p.ExitCode -ne 0) {
    $why = "wsl --version exited $($p.ExitCode)"
  } else {
    $v = ConvertFrom-WslVersionText -Text $p.Output
    if (-not $v) { $why = 'wsl --version printed no WSL version this installer can read' }
  }
  if ($v -and $v -ge $min) { return [pscustomobject]@{ State = 'ready'; Version = $v; Why = '' } }
  if (Test-WslBlockedByPolicy -Probe $p) { return [pscustomobject]@{ State = 'blocked'; Version = $v; Why = 'policy' } }
  if ($v) { return [pscustomobject]@{ State = 'old'; Version = $v; Why = "WSL $v is installed" } }
  return [pscustomobject]@{ State = 'cannot-tell'; Version = $null; Why = $why }
}

# The process token is elevated (an administrator who ran PowerShell as
# Administrator). The same test as install-k8s.ps1's admin gate.
function Test-BootstrapElevated {
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# whoami /groups /fo csv names BUILTIN\Administrators (S-1-5-32-544) for an
# administrator even when UAC has filtered it to "deny only", which the process's
# own group list leaves out. The headers and names are localized; the SID is not.
function Test-AdminSidListed {
  param([AllowNull()][string]$Text)
  return [bool]($Text -match '"S-1-5-32-544"')
}

# The user is an administrator, elevated or not. Anything unreadable is "no":
# that only means the IT command is printed instead of a prompt.
function Test-BootstrapUserIsAdmin {
  try { $g = (& whoami.exe /groups /fo csv 2>$null) -join "`n" } catch { return $false }
  return (Test-AdminSidListed -Text $g)
}

# Seconds since the epoch of the last boot, or $null when unreadable.
function Get-HostBootUnixTime {
  try {
    $b = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    return ([DateTimeOffset]::new($b.ToUniversalTime())).ToUnixTimeSeconds()
  } catch { return $null }
}

# TODO(S-W row 2): the resume marker. A JSON note in the user's own
# %LOCALAPPDATA%\tracebloc, written when turning WSL on wants a restart: when it
# was written (epoch seconds) and how many restarts the step has taken. A run that
# finds WSL ready deletes it. Row 2 says whether a RunOnce entry should also re-run
# the installer after the restart, as install-k8s.ps1 does; one would not carry
# TRACEBLOC_SUBSTRATE, so it waits for part 5's default.
function Get-WslResumeMarkerPath {
  return (Join-Path $env:LOCALAPPDATA 'tracebloc\wsl-resume.json')
}

function Write-WslResumeMarker {
  param([string]$Path, [int]$Restarts)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $note = [ordered]@{ step = 'wsl-enable'; written = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); restarts = $Restarts }
  [System.IO.File]::WriteAllText($Path, ($note | ConvertTo-Json -Compress))
}

# The marker, or $null. One that cannot be read is deleted and not trusted: the
# probe still decides readiness, so starting over only costs a prompt.
function Read-WslResumeMarker {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $n = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    if ($n.step -ne 'wsl-enable') { throw "step '$($n.step)'" }
    $written = [long]$n.written
    $restarts = [int]$n.restarts
    if ($written -le 0 -or $restarts -lt 0) { throw 'out of range' }
    return [pscustomobject]@{ Written = $written; Restarts = $restarts }
  } catch {
    Warn "Ignoring an unreadable resume note ($Path) and starting this step over."
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $null
  }
}

# Runs the IT command: through UAC when -Elevate, else in this (already elevated)
# console. Bounded; an elevated process cannot be stopped from here, so a timeout
# only stops the wait. Returns @{ State = ok | declined | timeout; ExitCode; Detail }.
function Invoke-WslEnable {
  param([string[]]$ArgumentList, [switch]$Elevate, [int]$TimeoutSec = $WslEnableTimeoutSec)
  $sp = @{ FilePath = 'wsl.exe'; ArgumentList = ($ArgumentList -join ' '); PassThru = $true; ErrorAction = 'Stop' }
  if ($Elevate) { $sp.Verb = 'RunAs' } else { $sp.NoNewWindow = $true }
  try {
    $p = Start-Process @sp
  } catch {
    # Start-Process -Verb RunAs throws when the prompt is declined, and so does a
    # launch that cannot start at all. Either way nothing ran.
    return @{ State = 'declined'; ExitCode = $null; Detail = $_.Exception.Message }
  }
  $null = $p.Handle   # cache the handle now, or ExitCode can read empty after the exit
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { return @{ State = 'timeout'; ExitCode = $null; Detail = '' } }
  return @{ State = 'ok'; ExitCode = $p.ExitCode; Detail = '' }
}

# 'ready', or 'restart' (a restart is needed first: the caller stops with the
# reboot handoff code). Every other outcome throws its own named refusal.
function Confirm-WslReady {
  param([string]$MarkerPath, [string]$MinVersion = $WslMinVersion, [int]$MaxRestarts = $WslEnableMaxRestarts)
  if (-not $MarkerPath) { $MarkerPath = Get-WslResumeMarkerPath }
  $itLead = 'Ask your IT team to run this once in an administrator PowerShell, then restart Windows if it asks:'
  $restartWords = 'Restart Windows, then run the same install command again: it continues from here.'

  $w = Get-WslState -MinVersion $MinVersion
  if ($w.State -eq 'ready') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    Ok "WSL $($w.Version) is ready ($MinVersion or newer)."
    return 'ready'
  }
  $enableArgs = if ($w.State -eq 'old') { $WslUpdateArgs } else { $WslInstallArgs }
  $cmd = 'wsl ' + ($enableArgs -join ' ')
  if ($w.State -eq 'blocked') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    throw "Your organisation's device policy blocks WSL (wsl.exe) on this computer, so tracebloc cannot set up its Linux environment here. Ask your IT team to allow wsl.exe for your account, and to run this once in an administrator PowerShell: $cmd"
  }

  # A second run: did the restart the last run asked for happen?
  $restarts = 0
  $marker = Read-WslResumeMarker -Path $MarkerPath
  if ($marker) {
    $boot = Get-HostBootUnixTime
    # An unreadable boot time counts as a restart, so the limit below still ends
    # the loop; never counting it would ask for restarts forever.
    if ($null -ne $boot -and $boot -le $marker.Written) {
      Warn "Windows still needs the restart that finishes turning on WSL. $restartWords"
      return 'restart'
    }
    $restarts = $marker.Restarts + 1
    if ($restarts -ge $MaxRestarts) {
      Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
      throw "WSL is still not ready after $restarts restart(s): $($w.Why). $itLead $cmd"
    }
  }

  $elevated = Test-BootstrapElevated
  if (-not $elevated) {
    if (-not ((Test-BootstrapUserIsAdmin) -and (Test-BootstrapCanPrompt))) {
      throw "This computer needs WSL $MinVersion or newer, and only an administrator can turn it on ($($w.Why)). $itLead $cmd -- then run this installer again as yourself."
    }
    Info "Turning on WSL needs administrator rights once. Windows will ask you to allow it."
  }
  $r = Invoke-WslEnable -ArgumentList $enableArgs -Elevate:(-not $elevated)
  if ($r.State -eq 'declined') {
    throw "The administrator step that turns on WSL did not start ($($r.Detail)). Run this installer again and allow the Windows prompt, or ask your IT team to run this once in an administrator PowerShell: $cmd"
  }
  if ($r.State -eq 'timeout') {
    throw "The administrator step that turns on WSL did not finish within $([int]($WslEnableTimeoutSec / 60)) minutes. $itLead $cmd"
  }
  if ($WslEnableOkCodes -notcontains $r.ExitCode) {
    throw "Turning on WSL failed: $cmd exited $($r.ExitCode). $itLead $cmd"
  }

  $w = Get-WslState -MinVersion $MinVersion
  if ($w.State -eq 'ready') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    Ok "WSL $($w.Version) is ready ($MinVersion or newer)."
    return 'ready'
  }
  Write-WslResumeMarker -Path $MarkerPath -Restarts $restarts
  Warn "Windows needs a restart to finish turning on WSL. $restartWords"
  return 'restart'
}

# =============================================================================
#  2. The distro image: the WSL distro's root filesystem.
#
#  On Windows the core is to run inside our own WSL distro, imported from a root
#  filesystem that 3.1 (client-dev#1809) publishes to ghcr.io. Get-WslDistroImage
#  fetches it by its layer digest, and Confirm-WslDistroImage refuses it unless it is
#  exactly the bytes the release pins: the length first, which is cheap and names
#  a truncated or padded download, then the sha256. A refused file is deleted at
#  once, so no later step can import it by mistake.
#
#  NOTHING CALLS THESE YET. The pins are stamped from facts.env as WSL_ROOTFS_*
#  when 3.1 publishes its first image (check-facts.sh refuses an empty pin, so the
#  keys land with their values), and the distro path stays behind the switch until
#  3.3 is green on it. Still to come, each waiting on the row of spike S-W
#  (backend#5416) that decides it:
#    TODO(S-W row 3): `wsl --import tracebloc "$env:LOCALAPPDATA\tracebloc\wsl"
#      <rootfs> --version 2` as the daily user, unelevated, after Confirm-WslDistroImage.
#    TODO(S-W row 5): the per-user logon task that keeps the distro running.
#    TODO(S-W rows 9 and 10): the proxy and the host's CA roots inside the distro.
#      The host-side fetch below honours HTTPS_PROXY like every bootstrap download.
#    TODO(S-W row 13): the GPU device the distro advertises.
#    TODO(part 5, after 3.3 is green): the PowerShell core's removal.
# =============================================================================

# The repository an image on ghcr.io names, or $null. Only ghcr.io: the anonymous
# token below is ghcr.io's. No tag or digest on the name (the digest is pinned on
# its own), and no '..'.
function ConvertTo-GhcrRepo {
  param([string]$Image)
  $m = [regex]::Match($Image, '^ghcr\.io/([a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)+)$')
  if (-not $m.Success -or $m.Groups[1].Value -match '\.\.') { return $null }
  return $m.Groups[1].Value
}

# An anonymous pull token for ghcr.io/REPO, or $null. ghcr.io answers a blob
# request that carries none with 401, even for a public image. On $null,
# $script:GhcrTokenFailure says why, for the refusal: the HTTP status where there
# was an answer, or "no answer", then the error's own words. The installer asks
# the user to share its output with support, so a 429, a proxy's 407, a TLS
# failure and a name that does not resolve each read as themselves.
$script:GhcrTokenFailure = ''
function Get-GhcrPullToken {
  param([string]$Repo)
  $script:GhcrTokenFailure = ''
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  try {
    $answer = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:${Repo}:pull" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop @proxyArgs
  } catch {
    # PS 5.1 (WebException) and 7 (HttpResponseException) both carry the
    # response's StatusCode; a network error carries no response at all.
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
    $status = 'no answer'
    if ($code -gt 0) { $status = "HTTP $code" }
    $script:GhcrTokenFailure = "$status -- $($_.Exception.Message)"
    return $null
  }
  if ($answer -and $answer.token) { return [string]$answer.token }
  $script:GhcrTokenFailure = 'its answer held no token'
  return $null
}

# Receive-WslDistroImage's clock, one step: a liveness dot every $Clock.TickSeconds,
# and the stall bound. $false when under $Clock.StallBytes arrived in the last
# $Clock.StallSeconds (curl's --speed-limit 1024 --speed-time 60, the Mac kernel
# fetch's bound). A slow download that is still moving is never stopped (#468).
function Test-WslDownloadMoving {
  param([hashtable]$Clock)
  $now = Get-Date
  if (($now - $Clock.LastDot).TotalSeconds -ge $Clock.TickSeconds) {
    if (-not $Clock.Dotted) { Write-Host -NoNewline "  " }
    Write-Host -NoNewline "." -ForegroundColor DarkGray
    $Clock.Dotted = $true
    $Clock.LastDot = $now
  }
  if (($now - $Clock.WindowStart).TotalSeconds -ge $Clock.StallSeconds) {
    if ($Clock.Have - $Clock.WindowBytes -lt $Clock.StallBytes) { return $false }
    $Clock.WindowStart = $now
    $Clock.WindowBytes = $Clock.Have
  }
  return $true
}

# Wait for TASK, an HTTP answer or a read, under the clock. $false when the
# download stalled first. A task that failed throws here.
function Wait-WslDownloadTask {
  param($Task, [hashtable]$Clock)
  while (-not $Task.Wait(250)) {
    if (-not (Test-WslDownloadMoving -Clock $Clock)) { return $false }
  }
  return $true
}

# DEST, opened for writing only if it is not there yet. A function of its own so the
# tests can stand in a file whose close fails, as a full disk's does.
function Open-WslDownloadFile {
  param([string]$Path)
  return [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
}

# End one answer without reading what is left of its body: the request is aborted
# first, then the answer is closed, each guarded on its own. On Windows PowerShell
# 5.1 a Close() alone first reads the rest of the body, outside every bound here,
# so a redirect whose body never ends would never close. PowerShell 7 does not
# read it either way, so only the cases on this function can see the order.
function Close-WslDownloadAnswer {
  param($Request, $Answer)
  if ($Request) { try { $Request.Abort() } catch { } }
  if ($Answer) { try { $Answer.Close() } catch { } }
}

# Download URL to DEST with the pull token. It streams: each read goes to disk as
# it arrives, so both bounds are checked inside the read loop, on every read and on
# every wait, the same on Windows PowerShell 5.1 and on PowerShell 7. (5.1's
# Invoke-WebRequest -OutFile can hold the whole answer in memory until it ends,
# and a bound read off the file's length cannot see a download that is not on
# disk yet.)
#  - a stall, Test-WslDownloadMoving's bound, also while waiting for the answer;
#  - the length: DEST never holds more than the pin plus one byte, so an answer
#    that never ends cannot fill the disk or the memory, and the length refusal
#    names it.
# Returns $true when there is a file for Confirm-WslDistroImage to judge: the
# answer ended, or it passed the pin, which Confirm-WslDistroImage then refuses by
# its length. $false when the download failed or stalled, each named by Err.
# REDIRECTS ARE FOLLOWED HERE, NOT BY .NET: ghcr.io answers with a redirect to its
# blob storage, and the token goes on the first request only, so no redirect
# target ever sees it. At most $MaxRedirects of them. The TLS 1.2 floor is the
# process's own (Main sets it), and HTTPS_PROXY is honoured like every bootstrap
# download.
function Receive-WslDistroImage {
  param(
    [string]$Url,
    [string]$Token,
    [string]$Dest,
    [long]$MaxBytes,
    [int]$StallSeconds = 60,
    [long]$StallBytes = 61440,
    [int]$TickSeconds = 3,
    [int]$MaxRedirects = 5
  )
  $now = Get-Date
  $clock = @{
    Have = [long]0; WindowStart = $now; WindowBytes = [long]0; LastDot = $now; Dotted = $false
    StallSeconds = $StallSeconds; StallBytes = $StallBytes; TickSeconds = $TickSeconds
  }
  $outcome = 'failed'
  $why = ''
  $req = $null; $answer = $null; $body = $null; $file = $null
  try {
    $uri = [Uri]$Url
    for ($hop = 0; ; $hop++) {
      $req = [Net.HttpWebRequest]::Create($uri)
      $req.AllowAutoRedirect = $false
      $req.KeepAlive = $false
      if ($env:HTTPS_PROXY) { $req.Proxy = [Net.WebProxy]::new([string]$env:HTTPS_PROXY) }
      if ($hop -eq 0) { $req.Headers.Add('Authorization', "Bearer $Token") }
      $pending = $req.GetResponseAsync()
      if (-not (Wait-WslDownloadTask -Task $pending -Clock $clock)) { $outcome = 'stalled'; break }
      $answer = $pending.Result
      $code = [int]$answer.StatusCode
      if ($code -lt 300) { break }
      $location = $answer.Headers['Location']
      Close-WslDownloadAnswer -Request $req -Answer $answer
      $answer = $null
      if ($hop -ge $MaxRedirects) { $why = "more than $MaxRedirects redirects"; break }
      if (-not $location) { $why = "HTTP $code with no Location"; break }
      $uri = [Uri]::new($uri, $location)
    }
    if ($answer) {
      $body = $answer.GetResponseStream()
      $file = Open-WslDownloadFile -Path $Dest
      $buf = [byte[]]::new(65536)
      while ($true) {
        $pending = $body.ReadAsync($buf, 0, $buf.Length)
        if (-not (Wait-WslDownloadTask -Task $pending -Clock $clock)) { $outcome = 'stalled'; break }
        $n = [long]$pending.Result
        if ($n -le 0) { $outcome = 'finished'; break }
        $n = [Math]::Min($n, $MaxBytes + 1 - $clock.Have)
        $file.Write($buf, 0, [int]$n)
        $clock.Have += $n
        if ($clock.Have -gt $MaxBytes) { $outcome = 'past the pin'; break }
        if (-not (Test-WslDownloadMoving -Clock $clock)) { $outcome = 'stalled'; break }
      }
    }
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $why = $e.Message
  } finally {
    # Each cleanup is guarded on its own: a throw from one would skip the rest and
    # replace the outcome, and the caller would never delete the partial DEST, so
    # the next run would refuse it as already there.
    # Abort ends the transfer outright, on both runtimes. Closing alone may first
    # read what is left of an answer that has not ended, and one that never ends
    # would then never close. PowerShell 7 does not wait either way, so no test
    # here sees this line fail; it is for 5.1.
    if ($outcome -ne 'finished' -and $req) { try { $req.Abort() } catch { } }
    # Closing DEST writes its last buffered bytes, so a full disk fails here. What
    # is on disk is then not the answer, so a download that ended is now a failed
    # one; any earlier failure keeps its own reason.
    if ($file) {
      try { $file.Dispose() } catch {
        if ($outcome -eq 'finished' -or $outcome -eq 'past the pin') {
          $e = $_.Exception
          while ($e.InnerException) { $e = $e.InnerException }
          $outcome = 'failed'
          $why = $e.Message
        }
      }
    }
    if ($body) { try { $body.Dispose() } catch { } }
    if ($answer) { try { $answer.Close() } catch { } }
  }
  if ($clock.Dotted) { Write-Host "" }
  if ($outcome -eq 'finished' -or $outcome -eq 'past the pin') { return $true }
  if ($outcome -eq 'stalled') {
    Err "The WSL distro image download stalled (under $StallBytes bytes in ${StallSeconds}s) -- giving up: $Url"
  } else {
    Err "The WSL distro image download failed ($why): $Url"
  }
  return $false
}

# Refuse a WSL distro image that is not exactly the pinned bytes, each by name: no
# file, a length other than the pin, a sha256 other than the pin. The length is
# read first, so a truncated or padded file is named as such and never hashed. A
# file refused for either is deleted before the refusal is thrown.
function Confirm-WslDistroImage {
  param(
    [string]$Path,
    [string]$Sha256,
    [long]$Bytes
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "The WSL distro image did not download, so there is nothing to import. Check that this machine can reach ghcr.io and pkg-containers.githubusercontent.com, then re-run."
  }
  $have = (Get-Item -LiteralPath $Path).Length
  $why = ''
  if ($have -ne $Bytes) {
    $why = "The WSL distro image is $have bytes, but this release pins $Bytes"
  } elseif ((Get-Sha256 -Path $Path) -ne $Sha256) {
    $why = "The WSL distro image does not match its pinned sha256 ($Sha256)"
  }
  if ($why) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $fate = 'it was deleted'
    if (Test-Path -LiteralPath $Path) { $fate = "it could not be deleted: delete $Path yourself" }
    throw "$why, so it was not imported and $fate. Something between this machine and ghcr.io changed the download; re-run on a network that does not rewrite downloads."
  }
}

# Fetch the WSL distro's root filesystem from ghcr.io into DEST by its pinned
# layer digest, and confirm it. Returns DEST, or throws a refusal that names what
# was wrong. The pins are checked for shape first: a pin this cannot use is a
# broken release, refused before anything is downloaded. A download that failed
# part way leaves no file behind, so it is refused as missing, not as tampered.
function Get-WslDistroImage {
  param(
    [string]$Image,
    [string]$Sha256,
    [long]$Bytes,
    [string]$Dest
  )
  $repo = ConvertTo-GhcrRepo -Image $Image
  if (-not $repo) {
    throw "This installer's WSL distro image '$Image' is not an image on ghcr.io, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw "This installer's WSL distro sha256 '$Sha256' is not 64 lowercase hex digits, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if ($Bytes -le 0) {
    throw "This installer's WSL distro length ($Bytes bytes) is not a positive number, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if (Test-Path -LiteralPath $Dest) {
    throw "$Dest already exists -- refusing to download the WSL distro image over it."
  }
  $token = Get-GhcrPullToken -Repo $repo
  if (-not $token) {
    throw "ghcr.io gave no pull token for $Image ($($script:GhcrTokenFailure)). Check that this machine can reach ghcr.io, then re-run."
  }
  Info "Downloading the WSL distro image ($([math]::Round($Bytes / 1MB)) MB) from $Image..."
  $fetched = Receive-WslDistroImage -Url "https://ghcr.io/v2/$repo/blobs/sha256:$Sha256" -Token $token -Dest $Dest -MaxBytes $Bytes
  if (-not $fetched) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
  Confirm-WslDistroImage -Path $Dest -Sha256 $Sha256 -Bytes $Bytes
  Ok "WSL distro image verified against its pinned length and sha256"
  return $Dest
}

# =============================================================================
#  3. The logon task. TODO(S-W row 5): the task that keeps the distro running.
# =============================================================================

# =============================================================================
#  4. The host GPU check.
#
#  On the distro path the core runs inside WSL, but nvidia-smi.exe and the driver
#  live on the Windows host, so the driver and compute-capability verdict stays
#  here (RFC-0175 D2, W21). These are install-k8s.ps1's Confirm-NvidiaDriver and
#  Get-NvidiaFloorVerdict with everything they call, COPIED UNCHANGED: install-k8s.ps1
#  runs as a separate process and its Find-Gpu still calls its own copies, so the
#  originals stay until part 5 deletes the PowerShell core. Until then
#  install-wsl.Tests.ps1 holds every copied function, and every top-level variable
#  they read, byte-for-byte equal to install-k8s.ps1's (the set is derived from
#  install-k8s.ps1, never listed). Ok and Warn are this file's own output helpers,
#  which print the same lines without the log.
#
#  NOTHING CALLS THESE YET: the distro path stays behind the switch until 3.3 is
#  green on it.
#  The floors: check-facts.sh stamps install-k8s.ps1's from facts.env, and the
#  parity test holds these to those, so after `check-facts.sh --write` copy the
#  stamped lines here too (part 5 points check-facts at this file instead).
#    TODO(S-W row 14): the driver floor stays 570.65 until row 14 measures it.
#    TODO(part 3): hand the verdict ($NVIDIA_DRIVER_OK, $GPU_SKIP_REASON and the
#      GPU_UNSUPPORTED_* values) to the core in the distro.
# =============================================================================

# The verdict's state, as Confirm-NvidiaDriver leaves it.
$NVIDIA_DRIVER_OK = $false
$GPU_SKIP_REASON  = ""
$GPU_UNSUPPORTED_REASON = ""
$GPU_UNSUPPORTED_NAME   = ""
$GPU_UNSUPPORTED_CODE   = ""
$NVIDIA_GPU_NAMES       = ""
$NVIDIA_DRIVER_VERSION = ""

# The NVIDIA GPU floors (scripts/spec/facts.env NVIDIA_DRIVER_FLOOR_WINDOWS /
# NVIDIA_COMPUTE_CAP_FLOOR / NVIDIA_DRIVER_HARD_FLOOR_WINDOWS), and the pre-Turing
# families by name. Policy, so no TRACEBLOC_* override.
$NVIDIA_DRIVER_FLOOR = "570.65"
$NVIDIA_COMPUTE_CAP_FLOOR = "7.5"
$NVIDIA_DRIVER_HARD_FLOOR = "528.33"
$NVIDIA_PRE_TURING_NAME_RE = ' (GT|GTS) [0-9]{3,4}[A-Z]* | GTX [4-9][0-9]{2}[A-Z]* | GTX 10[0-9]{2}[A-Z]* | GTX TITAN | TITAN (X|XP|V|Z|BLACK) | MX[1-3][0-9]{2} | GEFORCE [6-9][0-9]{2}(M|MX|A) | QUADRO (K|M|G?P|GV)[0-9]+[A-Z]* | NVS [0-9]{3} | (TESLA|GRID) [KMPV][0-9]+[A-Z]* | (K80|K40M?|K20X?M?|M60|M40|M10|P100|P40|P6|P4|V100S?) '

# The log line (no-op here: this script keeps no log file) and the dim hint line.
function Log($m)           { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -Encoding UTF8 -ErrorAction SilentlyContinue } }
function Hint($m)          { Write-Host "  $m" -ForegroundColor DarkGray; Log $m }

# A process exit code for a failure line, never blank.
function Format-ExitCode {
  param($Code)
  if ($null -eq $Code -or "$Code".Trim() -eq '') { return 'with no code reported' }
  return "$Code"
}

# The pure verdict and its helpers: the bash twins are detect-gpu.sh's _nvidia_* functions.
function ConvertTo-FloorVersion([string]$Text) {
  $t = ($Text -replace '\s', '')
  if ($t -notmatch '^\d+(\.\d+){0,3}$') { return $null }
  $parts = @($t.Split('.'))
  while ($parts.Count -lt 4) { $parts += '0' }
  try { return [version]($parts -join '.') } catch { return $null }
}

function ConvertTo-NvidiaNameNormalised([string]$Name) {
  $n = ($Name.ToUpperInvariant() -replace '[^A-Z0-9]+', ' ').Trim()
  return " $n "
}

function Get-NvidiaPreTuringName([string]$NameOutput) {
  foreach ($line in ([string]$NameOutput) -split "\r?\n") {
    if ((ConvertTo-NvidiaNameNormalised $line) -cmatch $NVIDIA_PRE_TURING_NAME_RE) { return $line.Trim() }
  }
  return $null
}

function Get-NvidiaFloorVerdict {
  param([string]$DriverOutput, [string]$CapOutput, [string]$DriverFloor, [string]$CapFloor, [string]$HardFloor, [string]$NameOutput)
  $df = ConvertTo-FloorVersion $DriverFloor
  $cf = ConvertTo-FloorVersion $CapFloor
  $hf = ConvertTo-FloorVersion $HardFloor
  if ($null -eq $df -or $null -eq $cf -or $null -eq $hf) { return "unreadable" }
  $lowest = {
    param([string]$Out)
    $low = $null
    foreach ($line in ([string]$Out).Trim() -split "\r?\n") {
      $v = ConvertTo-FloorVersion $line
      if ($null -eq $v) { return $null }
      if ($null -eq $low -or $v -lt $low) { $low = $v }
    }
    return $low
  }
  $drv = & $lowest $DriverOutput
  if ($null -eq $drv) { return "unreadable" }
  $cap = & $lowest $CapOutput
  if ($null -ne $cap -and $cap -lt $cf) { return "below-compute" }
  if ($null -eq $cap -and $null -ne (Get-NvidiaPreTuringName $NameOutput)) { return "below-compute" }
  if ($drv -lt $hf) { return "below-hard-floor" }
  if ($drv -lt $df) { return "below-driver" }
  if ($null -eq $cap) { return "unreadable" }
  return "ok"
}

function Get-NvidiaUnsupportedName {
  param([string]$NameOutput, [string]$CapOutput, [string]$CapFloor)
  $names = @(([string]$NameOutput) -split "\r?\n")
  $caps = @(([string]$CapOutput) -split "\r?\n")
  $cf = ConvertTo-FloorVersion $CapFloor
  $first = ""
  $capsReadable = $true
  foreach ($c in $caps) { if ($null -eq (ConvertTo-FloorVersion $c)) { $capsReadable = $false } }
  for ($i = 0; $i -lt $names.Count; $i++) {
    $n = $names[$i].Trim()
    if (-not $n) { continue }
    if (-not $first) { $first = $n }
    $c = if ($i -lt $caps.Count) { ConvertTo-FloorVersion $caps[$i] } else { $null }
    if ($null -ne $c -and $null -ne $cf -and $c -lt $cf) { return $n }
  }
  if (-not $capsReadable) { $old = Get-NvidiaPreTuringName $NameOutput; if ($old) { return $old } }
  return $first
}

# Reads the driver, the compute capability and the card names with nvidia-smi.exe
# (bounded), judges them, and leaves the verdict in the state above.
function Confirm-NvidiaDriver {
  try {
    $cmd = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    $nvSmi = if ($cmd) { $cmd.Source } else { $null }

    if (-not $nvSmi) {
      $found = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
        -Recurse -Filter "nvidia-smi.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
      $nvSmi = if ($found) { $found.FullName } else { $null }
    }
    if (-not $nvSmi) {
      Warn "NVIDIA drivers may not be installed."
      Hint "Download: https://www.nvidia.com/Download/index.aspx"
      return
    }

    # Bounded (installer external-call timeout rule / Bugbot): a wedged driver must not hang the
    # install -- and Find-Gpu now runs before the fast path, so an unbounded nvidia-smi would hang
    # every "nothing to do" re-run too.
    # -StdoutOnly on BOTH queries (Bugbot on client-dev#1447): the verdict reads every line
    # as a version and calls any other line unreadable, so a successful nvidia-smi that also
    # printed a warning to stderr would lose a working GPU. The bash twin reads stdout only
    # too (a command substitution, with 2>/dev/null). A failing query keeps its stderr.
    $dr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=driver_version","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    # 124 IS THE TIMEOUT, so the code is what separates the two causes this
    # message names -- "failed or timed out" made the operator guess which.
    if ($dr.Code -ne 0) {
      Warn "Couldn't query the NVIDIA driver (nvidia-smi exited $(Format-ExitCode $dr.Code); 124 means it timed out) -- GPU checks skipped."
      $script:GPU_SKIP_REASON = "the NVIDIA driver version could not be read (nvidia-smi exited $(Format-ExitCode $dr.Code)) -- running CPU-only"
      return
    }
    $driverVer = ([string]$dr.Output -split "`n" | Select-Object -First 1).Trim()
    $script:NVIDIA_DRIVER_VERSION = $driverVer   # quoted back in a GPU-skip reason (#616)
    # compute_cap is its own query: a driver too old to know it fails that query alone,
    # and the floor still reads the driver version.
    $cr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=compute_cap","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    $capOut = if ($cr.Code -eq 0) { [string]$cr.Output } else { "" }
    # The LOWEST compute capability, as the verdict judges it: on a mixed host the
    # message names the card that is too old, not whichever GPU nvidia-smi lists first.
    $capVer = @($capOut -split "\r?\n" | ForEach-Object { $_.Trim() } |
      Where-Object { $null -ne (ConvertTo-FloorVersion $_) } |
      Sort-Object { ConvertTo-FloorVersion $_ } | Select-Object -First 1)
    $capVer = if ($capVer.Count -gt 0) { [string]$capVer[0] } else { "unknown" }
    # The card's name: the verdict classifies it by name when the driver cannot report
    # compute_cap (client-dev#1631). A failed query is no name, never a guess.
    $nr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=name","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    $nameOut = if ($nr.Code -eq 0) { [string]$nr.Output } else { "" }
    $verdict = Get-NvidiaFloorVerdict -DriverOutput ([string]$dr.Output) -CapOutput $capOut -DriverFloor $NVIDIA_DRIVER_FLOOR -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR -HardFloor $NVIDIA_DRIVER_HARD_FLOOR -NameOutput $nameOut
    $script:GPU_UNSUPPORTED_REASON = ""; $script:GPU_UNSUPPORTED_NAME = ""
    $script:GPU_UNSUPPORTED_CODE = ""
    $script:NVIDIA_GPU_NAMES = $nameOut
    Log "GPU floor: $verdict (driver $driverVer, floor $NVIDIA_DRIVER_FLOOR, hard floor $NVIDIA_DRIVER_HARD_FLOOR; compute capability $capVer, floor $NVIDIA_COMPUTE_CAP_FLOOR)"
    if ($verdict -eq "ok" -or $verdict -eq "below-driver") {
      if ($verdict -eq "below-driver") {
        # A warning, not a skip (Lukas, 2026-09-30, client-dev#1355): the images admit
        # older drivers on datacenter cards, so the GPU stays on. Confirm-DockerGpu still
        # probes it, and a driver too old for the image fails there, with a reason.
        # A driver too old to answer compute_cap: the card itself could not be checked either.
        if ($capVer -eq "unknown") {
          Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_FLOOR, the driver tracebloc recommends for GPU training, and it cannot report this GPU's compute capability -- continuing with the GPU, but it may not work until the driver is updated."
        } else {
          Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_FLOOR, the driver tracebloc recommends for GPU training -- continuing with the GPU; if GPU training fails on this machine, update the driver."
        }
        Hint "To update: https://www.nvidia.com/Download/index.aspx, reboot, then re-run the installer."
      }
      $script:NVIDIA_DRIVER_OK = $true
      Ok "NVIDIA GPU ready (driver $driverVer)"
      # Expectation-setting only, never a gate (#387): entry-level cards pass
      # every check but are too small for real training (field: a 2 GB GT 710
      # installed fine and could never fit a model).
      try {
        $vr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=memory.total","--format=csv,noheader,nounits") -TimeoutSec 15
        $vramMiB = if ($vr.Code -eq 0) { [int](($vr.Output -split "`n" | Select-Object -First 1).Trim()) } else { 0 }
        if ($vramMiB -gt 0 -and $vramMiB -lt 8192) {
          Hint "This GPU has $([math]::Round($vramMiB / 1024, 1)) GB VRAM - fine for setup; real training typically needs 8 GB+."
        }
      } catch {}
    } elseif ($verdict -eq "below-compute") {
      $oldName = Get-NvidiaPreTuringName $nameOut
      if ($capVer -eq "unknown" -and $oldName) {
        # Classified by name: the driver could not report the compute capability
        # (client-dev#1631), so the card is named instead of a number.
        $script:GPU_SKIP_REASON = "this NVIDIA GPU ($oldName) is too old for tracebloc's GPU images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer -- running CPU-only"
        Warn "This NVIDIA GPU ($oldName) is too old for tracebloc's GPU images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer -- this machine will run in CPU mode."
        $script:GPU_UNSUPPORTED_REASON = "This GPU is too old for tracebloc's GPU training images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer (NVIDIA Turing or later), so this machine runs on CPU."
      } else {
        $script:GPU_SKIP_REASON = "this NVIDIA GPU (compute capability $capVer) is too old for tracebloc's GPU images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer -- running CPU-only"
        Warn "This NVIDIA GPU (compute capability $capVer) is too old for tracebloc's GPU images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer -- this machine will run in CPU mode."
        $script:GPU_UNSUPPORTED_REASON = "This GPU (compute capability $capVer) is too old for tracebloc's GPU training images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer (NVIDIA Turing or later), so this machine runs on CPU."
      }
      $script:GPU_UNSUPPORTED_CODE = "compute_too_old"
      $script:GPU_UNSUPPORTED_NAME = Get-NvidiaUnsupportedName -NameOutput $nameOut -CapOutput $capOut -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR
      Hint "GPU training needs a newer card (NVIDIA Turing or later). Everything else works on CPU."
    } elseif ($verdict -eq "below-hard-floor") {
      # Below the CUDA 12 minimum the images' torch cannot initialise CUDA at all, so the
      # GPU would be advertised and unusable (client-dev#1632).
      $script:GPU_SKIP_REASON = "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU images can use (CUDA 12) -- running CPU-only"
      Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU images can use (CUDA 12) -- this machine will run in CPU mode."
      $script:GPU_UNSUPPORTED_REASON = "The NVIDIA driver on this machine ($driverVer) is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU training images can use, so this machine runs on CPU until the driver is updated."
      $script:GPU_UNSUPPORTED_CODE = "driver_too_old"
      $script:GPU_UNSUPPORTED_NAME = Get-NvidiaUnsupportedName -NameOutput $nameOut -CapOutput $capOut -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR
      Hint "To use the GPU: install NVIDIA driver $NVIDIA_DRIVER_FLOOR or newer (https://www.nvidia.com/Download/index.aspx), reboot, then re-run the installer."
    } else {
      $script:GPU_SKIP_REASON = "the NVIDIA driver version and compute capability could not be read -- running CPU-only"
      Warn "Couldn't read this NVIDIA GPU's driver version and compute capability -- this machine will run in CPU mode to be safe."
      Hint "Check that 'nvidia-smi --query-gpu=driver_version,compute_cap --format=csv' works, then re-run the installer."
    }
  } catch {
    Warn "Could not verify NVIDIA driver: $_"
  }
}

# Run a child process with a hard timeout, its arguments quoted for Win32
# (install-k8s.ps1's comments above its copies give the rules).
function ConvertTo-Win32Arg {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Arg)
  if ($Arg -ne "" -and $Arg -notmatch '[\s"]') { return $Arg }
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('"')
  $i = 0
  while ($i -lt $Arg.Length) {
    $nBackslash = 0
    while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $i++; $nBackslash++ }
    if ($i -eq $Arg.Length) {
      [void]$sb.Append('\' * ($nBackslash * 2))   # trailing run: double so the close quote survives
      break
    } elseif ($Arg[$i] -eq '"') {
      [void]$sb.Append('\' * ($nBackslash * 2 + 1)); [void]$sb.Append('"')
      $i++
    } else {
      # [string] cast, not the bare [char] from string indexing: under Windows
      # PowerShell 5.1 (the installer's relaunch host) the StringBuilder.Append
      # binder can bind a [char] to a numeric overload and write the code point
      # instead of the character; Append([string]) is unambiguous (Bugbot #845).
      [void]$sb.Append('\' * $nBackslash); [void]$sb.Append([string]$Arg[$i])
      $i++
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-BoundedProcess {
  # -StdoutOnly: return ONLY stdout in .Output on the success path, instead of the
  # usual stdout+stderr concatenation.
  #
  # OPT-IN on purpose. The merged .Output is load-bearing for most callers -- e.g.
  # Get-GpuBuildFailureReason classifies a docker build by matching stderr text -- so
  # isolating it globally would break the diagnosis those callers exist to produce.
  # But a caller that COMPARES output to an expected value cannot tolerate the merge:
  # any client-side docker warning lands in the same string and the comparison fails.
  # Assert-NodesSeeHostData is exactly that, and there the failure is a FALSE REFUSAL
  # after the cluster is already up (@saadqbal / Bugbot on #817).
  #
  # Only the success path is isolated. The failure/timeout paths keep their merged or
  # synthetic text, which is pure diagnostics -- and every caller checks .Code before
  # reading .Output for a value.
  param(
    [Parameter(Mandatory)][string]$FileName,
    [Parameter(Mandatory)][string[]]$Arguments,
    [int]$TimeoutSec = 120,
    [string]$Stdin = "",
    [switch]$StdoutOnly
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  # Quote+escape each arg (Bugbot): the args are joined into a single command line, so a value with
  # a space -- a registry username, a temp path under a profile like "C:\Users\First Last\..." --
  # would be split into two, and a value with a `"` would corrupt the parse. ConvertTo-Win32Arg
  # applies the exact CommandLineToArgvW rules so both survive as one token; callers pass raw args.
  $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($Stdin) { $psi.RedirectStandardInput = $true }
  try { $proc = [System.Diagnostics.Process]::Start($psi) }
  catch { return [pscustomobject]@{ Code = 1; Output = "could not start ${FileName}: $($_.Exception.Message)" } }
  # THE WRITE CAN LOSE A RACE WITH THE CHILD, and losing it must not throw. If the
  # process exits before or during the write -- `docker login` refusing instantly
  # because the daemon is down, a binary that rejects its args and returns, a stub in
  # the suite -- the pipe is already closed and .Write() raises "Broken pipe". That
  # escaped this function as a raw MethodInvocationException, which breaks the
  # contract three lines below it: every other arm RETURNS @{Code; Output}, and
  # Start() and Kill() are both guarded for exactly this reason. Only the stdin write
  # was bare.
  #
  # Swallowing is right here, and it is not a fail-open: a child that closed stdin has
  # already decided something, and its exit code and output are read below and
  # returned unchanged. The error we would raise is about OUR pipe, not about the
  # command -- reporting it would replace the child's real verdict with plumbing.
  #
  # Found on 2026-08-16: it took down `Pester (ubuntu-latest)` on client's `main` tip
  # right after a prod promotion, on a test whose assertion never ran.
  #
  # DRAIN BEFORE YOU WRITE. The readers start ahead of the stdin write, not after it.
  # With the order reversed, a child that BOTH reads stdin and writes output deadlocks
  # whenever the payload exceeds the OS pipe buffer (~64 KiB): the child fills its
  # stdout pipe, blocks because nobody is draining it yet, therefore stops reading
  # stdin, therefore our Write() blocks -- and WaitForExit() below is never reached, so
  # the HARD timeout this function exists to provide does not fire at all. Not 124:
  # no return, ever. Measured on backend#2246 -- `/bin/cat` with a 200 KB payload and
  # -TimeoutSec 20 ran past a 60s outer watchdog, while the same call with the readers
  # started first returns the child's real verdict. Starting a ReadToEndAsync() before
  # the write costs nothing and is the documented way out of the classic redirect
  # deadlock, so the ordering is load-bearing: do not "tidy" the readers back down.
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  if ($Stdin) {
    # Close() in `finally`, NOT chained after Write() in the same try. Chained, a throw
    # from Write() skipped the Close(), so the child never got its EOF and our write
    # handle stayed open -- and the ONE exception we actually observe here (broken pipe)
    # is swallowed, which means the skip was silent. The swallow itself stays: see the
    # paragraphs above for why a pipe error must not replace the child's verdict. The
    # inner try is because Close() flushes, so it can raise the same broken pipe.
    try { $proc.StandardInput.Write($Stdin) } catch { }
    finally { try { $proc.StandardInput.Close() } catch { } }
  }
  if ($proc.WaitForExit($TimeoutSec * 1000)) {
    # -StdoutOnly isolates stdout ONLY when the child SUCCEEDED (exit 0), per the
    # contract documented above. On a NON-ZERO exit the merged stdout+stderr is
    # returned regardless of -StdoutOnly, so a failing caller keeps the child's
    # stderr diagnostics -- gating on $StdoutOnly alone silently discarded them,
    # and the child then looked like it produced nothing rather than like we threw
    # its stderr away (client#828). The timeout arm below is the other failure path
    # and keeps its synthetic text for the same reason.
    $isolate = $StdoutOnly -and $proc.ExitCode -eq 0
    return [pscustomobject]@{ Code = $proc.ExitCode; Output = $(if ($isolate) { $outTask.Result } else { $outTask.Result + $errTask.Result }) }
  }
  # timed out -> kill the child so it can't keep running after we've moved on
  try { $proc.Kill() } catch {}
  return [pscustomobject]@{ Code = 124; Output = ($FileName + " " + $Arguments[0] + " timed out after " + $TimeoutSec + "s") }
}

# =============================================================================
#  5. The core. TODO: `wsl -d tracebloc -u root -- bash` on CoreDir's
#     install-k8s.sh, its output teed into %USERPROFILE%\.tracebloc\install-<stamp>.log.
#     Its files then join $CoreFiles, and install.ps1 fetches them.
# =============================================================================

# =============================================================================
#  The distro path, as far as it is built. Returns the exit code.
# =============================================================================
function Invoke-WslInstall {
  param([string]$CoreDir)
  Confirm-CoreDir -CoreDir $CoreDir
  # A restart stops with 2, install-k8s.ps1's declared "restart, then re-run"
  # code, which install.ps1 passes through and the e2e harness reads.
  if ((Confirm-WslReady) -eq 'restart') {
    Info "If you set TRACEBLOC_SUBSTRATE=k3s in this window only, set it again after the restart."
    return 2
  }
  throw "WSL is ready, but the rest of the TRACEBLOC_SUBSTRATE=k3s path is not available on Windows yet. Unset TRACEBLOC_SUBSTRATE to install with the current Windows path."
}

# =============================================================================
#  Main. $env:TRACEBLOC_PESTER lets the test suite dot-source this file to load the
#  functions without running them. A child process: `exit` here closes no window.
# =============================================================================
if (-not $env:TRACEBLOC_PESTER) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    exit (Invoke-WslInstall -CoreDir $CoreDir)
  } catch {
    Write-Host ""
    Err "Installation stopped: $_"
    Write-Host "  It's safe to re-run this installer. If it keeps failing, share the output above with tracebloc support." -ForegroundColor DarkGray
    exit 1
  }
}
