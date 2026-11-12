# =============================================================================
#  install-wsl-distro.ps1 -- section 2 of install-wsl.ps1: the distro image,
#  its import and its disk, and the host's CA roots in the distro.
#
#  install-wsl.ps1 dot-sources this file from beside itself, at the place the
#  section stands in its order, and checks it through $CoreFiles; install.ps1
#  fetches and verifies it with the rest ($Files). The rootfs pins it reads,
#  $WSL_ROOTFS_*, stay stamped in install-wsl.ps1 (check-facts.sh).
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

# Receive-WslDistroImage's clock, one step: under the live line Show-Live drew
# ($Clock.Live), the progress after it, redrawn once a second (Write-WslDownloadTail);
# elsewhere a liveness dot every $Clock.TickSeconds. Then the stall bound: $false when
# under $Clock.StallBytes arrived in the last $Clock.StallSeconds (curl's
# --speed-limit 1024 --speed-time 60, the Mac kernel fetch's bound). A slow download
# that is still moving is never stopped.
function Test-WslDownloadMoving {
  param([hashtable]$Clock)
  $now = Get-Date
  if ($Clock.Live) {
    if (($now - $Clock.LastDot).TotalSeconds -ge 1) {
      Write-WslDownloadTail -Clock $Clock -Now $now
      $Clock.LastDot = $now
    }
  } elseif (($now - $Clock.LastDot).TotalSeconds -ge $Clock.TickSeconds) {
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

# What the WSL distro image's download brought in, as the core's live line shows it
# (download.sh, _tb_dl_tail): "  1m 05s · 63% · 8.4 MB/s". SECONDS spent; BYTES of
# TOTAL, the share rounded down (BYTES alone when TOTAL is 0); RATE bytes a second,
# none when $null. 1 MB = 1024 KB.
function Format-DownloadProgress {
  param([long]$Seconds, [long]$Bytes, [long]$Total, $Rate)
  $dot = [string][char]0x00B7
  $time = Format-DownloadTime $Seconds
  if ($Total -gt 0) { $what = "$([math]::Min(100, [math]::Floor($Bytes * 100.0 / $Total)))%" } else { $what = Format-DownloadBytes $Bytes }
  $text = "  $time $dot $what"
  if ($null -ne $Rate) { $text += " $dot $(Format-DownloadRate ([long]$Rate))" }
  return $text
}
# "12s", "1m 05s" (_tb_elapsed).
function Format-DownloadTime([long]$Seconds) {
  if ($Seconds -lt 60) { return "${Seconds}s" }
  return ('{0}m {1:00}s' -f [math]::Floor($Seconds / 60), ($Seconds % 60))
}
# "64 bytes", "640 KB", "312 MB", "1.2 GB", rounded down (_tb_dl_bytes).
function Format-DownloadBytes([long]$Bytes) {
  if ($Bytes -lt 1KB) { return "$Bytes bytes" }
  if ($Bytes -lt 1MB) { return "$([math]::Floor($Bytes / 1KB)) KB" }
  if ($Bytes -lt 1GB) { return "$([math]::Floor($Bytes / 1MB)) MB" }
  $t = [math]::Floor($Bytes * 10.0 / 1GB)
  return "$([math]::Floor($t / 10)).$($t % 10) GB"
}
# "640 KB/s", or MB/s to the nearest tenth, "8.4 MB/s" (_tb_dl_rate).
function Format-DownloadRate([long]$Rate) {
  $k = [math]::Floor(($Rate + 512) / 1KB)
  if ($k -lt 1024) { return "$k KB/s" }
  $t = [math]::Floor(($Rate * 10 + 524288) / 1MB)
  return "$([math]::Floor($t / 10)).$($t % 10) MB/s"
}

# Draw the clock's progress after what the line holds, over the last one: back over
# it, the new text, and spaces over what is left of a longer one. The speed is the
# average over the last 5 seconds, from the second sample on.
function Write-WslDownloadTail {
  param([hashtable]$Clock, [datetime]$Now)
  $t = ($Now - $Clock.Start).TotalSeconds
  [void]$Clock.Ring.Add(@($t, $Clock.Have))
  while ($Clock.Ring.Count -gt 2 -and ($t - $Clock.Ring[0][0]) -gt 5) { $Clock.Ring.RemoveAt(0) }
  $rate = $null
  $span = $t - $Clock.Ring[0][0]
  if ($span -gt 0) { $rate = [long][math]::Floor(($Clock.Have - $Clock.Ring[0][1]) / $span) }
  $text = Format-DownloadProgress -Seconds ([long][math]::Floor($t)) -Bytes $Clock.Have -Total $Clock.Total -Rate $rate
  $pad = [math]::Max(0, $Clock.Tail.Length - $text.Length)
  Write-Host -NoNewline (("`b" * $Clock.Tail.Length) + $text + (' ' * $pad) + ("`b" * $pad)) -ForegroundColor DarkGray
  $Clock.Tail = $text
}
# Take the progress off the line again, so the next line is printed where it began.
function Clear-WslDownloadTail {
  param([hashtable]$Clock)
  if (-not $Clock.Tail) { return }
  $n = $Clock.Tail.Length
  Write-Host -NoNewline (("`b" * $n) + (' ' * $n) + ("`b" * $n))
  $Clock.Tail = ''
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
    Live = [bool]$script:LiveLine; Start = $now; Total = $MaxBytes; Ring = [Collections.ArrayList]::new(); Tail = ''
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
  Clear-WslDownloadTail -Clock $clock
  if ($clock.Live -and $outcome -eq 'finished') {
    $spent = [long][math]::Floor(((Get-Date) - $clock.Start).TotalSeconds)
    Log "Downloaded the WSL distro image: $(Format-DownloadBytes $clock.Have) in $(Format-DownloadTime $spent)"
  }
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

# THE DISTRO'S DISK (S-W row 11). An imported distro's VHDX gets
# WSL's default virtual size, about 1 TiB, and the node's capacity is that, not
# what the host has. On S-W's machine the node reported 1,055,762,868 KiB while C:
# had 110 GB free, so kubelet's eviction (at 5 % of capacity free) could never
# fire before C: filled. The VHDX also grew by the 5 GiB written and did not
# shrink after the delete. So, right after `wsl --import` and BEFORE the distro
# first starts, Set-WslDistroDisk:
#   1. caps its virtual size at Get-WslDistroDiskCap's answer, so that the node's
#      capacity is what the host can give it, and eviction fires first;
#   2. makes the VHDX sparse, so that blocks the distro frees go back to the host.
# Both come before the first start: once the VHD is attached, WSL refuses them
# ($WslDiskHeldCodes, below), and only `wsl --shutdown` frees it (row 11: not a
# --terminate). Measured on S-W's STOCK ubuntu-noble-wsl 20240423 image; the VHDX
# is WSL's, not the image's, so ours is the same.
# THE CAP COMES FIRST: WSL CANNOT RESIZE A SPARSE DISK. On WSL 3.0.3 (3.3's distro
# leg on Windows Server 2025, 16 Oct) `--resize` after `--set-sparse true` was
# refused: "Virtual hard disk files must be uncompressed and unencrypted and must
# not be sparse", exit -1, Wsl/Service/ERROR_VIRTUAL_DISK_LIMITATION. So the cap
# runs first and sparse after it. A disk that is sparse already (a WSL that makes
# every new disk sparse) is made not sparse once, the cap runs again, and the
# sparse step makes it sparse after.
# NOT MEASURED YET: a sparse VHDX giving space back. 3.3's distro cell runs it.
# SPARSE IS BEST EFFORT; THE CAP IS NOT. Sparse only gives freed space back to
# Windows, and a correct install does not need it; the cap is what keeps the node
# off a full drive. So a sparse step that does not run cleanly is said and the
# install goes on to the cap (the coordinator's ruling, 15 Oct, on 3.3's distro
# leg); a cap that does not stops the install. WSL's refusal by policy (S-W's run
# of record, 13 Oct, row 11: WSL 2.7.11, "Sparse VHD support is currently disabled
# due to potential data corruption", exit -1, Wsl/Service/E_INVALIDARG) is said in
# its own words, with no command to run: the only one would be --allow-unsafe,
# which is never passed. Every other sparse failure is said with the commands that
# make the disk sparse by hand later.
# THE DISK STAYS ATTACHED AFTER THE IMPORT on WSL 3.0.3 (3.3's distro leg on
# Windows Server 2025): straight after `wsl --import`, with no start between them
# and nothing in `wsl --list --running`, `--set-sparse` was refused with
# ERROR_SHARING_VIOLATION (15 Oct) and `--resize` with WSL_E_DISTRO_NOT_STOPPED
# (16 Oct), both saying "the VHD is currently in use". So a disk step WSL refuses
# with either code ($WslDiskHeldCodes) frees the disk once, with `wsl --shutdown`,
# and runs that step again, but only when
# `wsl --list --running` was read and names no distro at all: the shutdown then
# stops nothing of the user's (Clear-WslHeldDisk). A distro that runs, a list that
# cannot be read, or a shutdown that does not run cleanly frees nothing, and says
# why. At most one shutdown and one second try per Set-WslDistroDisk.
# THE ORDER: the import step calls Set-WslDistroDisk between `wsl --import` and the
# logon task's first run (S-W row 5), because the task starts the distro and
# --set-sparse is refused from then on. Set-WslDistroDisk holds that itself: a
# distro `wsl --list --running` names is refused by name before any --manage step.
# When the cap stops the install, the import step unregisters the distro it just
# imported, so a re-run imports it afresh instead of taking the re-run path over a
# disk never capped.
# A RE-RUN over a distro that is already there calls Update-WslDistroDisk instead:
# it re-derives the cap and only GROWS the disk to it. The distro's own growth
# takes the host's free space, so a re-run often derives a smaller cap, and
# --resize is never asked to shrink a disk below the size it has. A re-run never
# fails on the disk: a size it cannot read, a smaller cap, or a growth wsl.exe
# refuses (the VHD stays attached while the distro runs, row 11, and the import
# made it sparse) each leave the cap the import set, and say so. A growth refused
# for a sparse disk also says the commands that grow it by hand: they stop every
# WSL distro, which a re-run never does by itself.
# NOT MEASURED YET either: whether WSL's "GB" in --resize is 1024^3 bytes, as
# PowerShell's 1GB is (a re-run compares the two).
# Import-WslDistro calls them, right after the import (below).

# The free space the cap leaves on the host's drive, and the smallest cap worth
# installing on, in GB: preflight.sh's PF_WARN_DISK_GB and PF_MIN_DISK_GB, the
# floors the core already holds a node's disk to. install-wsl.Tests.ps1 reads both
# defaults from preflight.sh and holds these to them.
$WslDiskReserveGb = 20
$WslDiskMinGb = 10

# WSL's refusal of --set-sparse by policy, as wsl.exe 2.7.11 printed it on the
# managed laptop (S-W's log, row 11), its four lines joined by one space as
# Set-WslDistroDisk joins what wsl.exe said. Only these exact words make the
# sparse step best effort.
$WslSparsePolicyRefusal = 'Sparse VHD support is currently disabled due to potential data corruption. To force a distribution to use a sparse VHD, please run: wsl.exe --manage <DistributionName> --set-sparse true --allow-unsafe Error code: Wsl/Service/E_INVALIDARG'

# The drive that holds PATH (its root, C:\ on Windows), or PATH itself when that
# cannot be told. What the refusals name.
function Get-WslDiskDrive {
  param([string]$Path)
  try {
    return [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
  } catch {
    return $Path
  }
}

# The bytes free to this user on the drive that holds PATH, or $null when that
# cannot be read. The tests' seam.
function Get-WslDiskFreeSpace {
  param([string]$Path)
  try {
    return [long]([System.IO.DriveInfo]::new((Get-WslDiskDrive -Path $Path)).AvailableFreeSpace)
  } catch {
    return $null
  }
}

# FREE bytes as a cap in whole GB: rounded down, less the reserve. The one sum
# both the import's cap and a re-run's growth make.
function ConvertTo-WslDiskCapGb {
  param([long]$Free, [int]$ReserveGb = $WslDiskReserveGb)
  $freeGb = [long][math]::Floor($Free / 1GB)
  $cap = $freeGb - $ReserveGb
  return $cap
}

# The distro VHDX's cap in whole GB: what is free on the drive that holds PATH,
# rounded down, less the reserve. Throws, by name, when the free space cannot be
# read, or when what is left is under the smallest cap worth installing on. The
# refusal is preflight.sh's disk refusal, in ASCII, for that drive and this floor
# (the reserve plus the smallest cap); install-wsl.Tests.ps1 holds it to those words.
function Get-WslDistroDiskCap {
  param(
    [string]$Path,
    [int]$ReserveGb = $WslDiskReserveGb,
    [int]$MinGb = $WslDiskMinGb
  )
  $drive = Get-WslDiskDrive -Path $Path
  $free = Get-WslDiskFreeSpace -Path $Path
  if ($null -eq $free) {
    Stop-Setup -What "Couldn't read how much disk space is free on $drive" -Reason "Disk: could not read how much space is free on $drive, so the WSL distro's disk cannot be sized. Check that the drive is there and readable, then re-run."
  }
  $cap = ConvertTo-WslDiskCapGb -Free $free -ReserveGb $ReserveGb
  if ($cap -lt $MinGb) {
    Stop-Setup -What "$($cap + $ReserveGb) GB free disk $Dot tracebloc needs $($ReserveGb + $MinGb) GB" -Next 'Free up disk space, then run the installer again:' -Reason "Disk: only $($cap + $ReserveGb) GB free on $drive - need >= $($ReserveGb + $MinGb) GB ($ReserveGb GB left to Windows, and at least $MinGb GB for tracebloc's WSL distro). Free up space or attach a larger disk, then re-run."
  }
  return $cap
}

# Whether `wsl --list --running` names DISTRO: $true only when a line of its answer
# is exactly the name. Anything else, a list that cannot be read included, is
# $false here: Set-WslDistroDisk's sparse step is then the check that decides, as
# WSL refuses it for a disk that is attached.
function Test-WslDistroRunning {
  param([string]$Distro = $WslDistroName, [string]$FilePath = 'wsl.exe')
  $l = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--list', '--running', '--quiet')
  if (-not $l.Started -or $l.TimedOut) { return $false }
  foreach ($line in ($l.Output -replace "`0", '') -split "`r?`n") {
    if ($line.Trim() -ceq $Distro) { return $true }
  }
  return $false
}

# A distro's name as WSL allows one (wsl --import refuses any other): letters,
# digits, '.', '_' and '-'. A line of `wsl --list` with a space in it is wsl.exe's
# own words, never a distro.
$WslDistroNamePattern = '^[A-Za-z0-9._-]+$'

# WSL's words when `wsl --list --running` finds nothing running. Only an empty
# answer with exit 0, or these words (with at most WSL's "Error code:" line after
# them), say that nothing runs; anything else cannot tell.
$WslNoneRunning = 'There are no running distributions.'

# How long a disk WSL still holds is waited for when what runs cannot be read, and
# how often the step is tried meanwhile. WSL stops its VM once no distro has run
# for vmIdleTimeout (60 s by default), which frees every disk. A bound, not a
# measured worst case.
$WslDiskReleaseWaitSec = 120
$WslDiskReleasePollSec = 10

# The codes wsl.exe gives a disk step it refuses because WSL still holds the disk
# (THE DISK STAYS ATTACHED AFTER THE IMPORT, above): --set-sparse's and --resize's.
# The codes, not the words: WSL translates its words, never its codes.
$WslDiskHeldCodes = @('ERROR_SHARING_VIOLATION', 'WSL_E_DISTRO_NOT_STOPPED')

# Whether SAID, what wsl.exe said refusing a disk step, says WSL still holds the
# disk: one of $WslDiskHeldCodes is in it.
function Test-WslDiskHeld {
  param([string]$Said)
  foreach ($code in $WslDiskHeldCodes) {
    if ($Said.IndexOf($code, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}

# What to do about the distro's disk when WSL still holds it after the import
# (Test-WslDiskHeld; THE DISK STAYS ATTACHED AFTER THE IMPORT, above), from
# `wsl --list --running`:
#   - it names a distro: nothing; only `wsl --shutdown` would free the disk, and that
#     would stop it. Running names them;
#   - it says, beyond doubt, that nothing runs: `wsl --shutdown`, which then stops
#     nothing of the user's. Why is '' once it ran cleanly;
#   - it cannot tell: Wait, and nothing is shut down, as a shutdown that cannot tell
#     might stop a distro of the user's.
# Why says what was not done, and why.
function Clear-WslHeldDisk {
  param([string]$FilePath = 'wsl.exe')
  $not = 'so WSL was not shut down to free it'
  $l = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--list', '--running', '--quiet')
  if (-not $l.Started) { return [pscustomobject]@{ Why = "which WSL distros run could not be read (wsl --list --running did not start: $($l.StartError)), $not"; Running = @(); Wait = $true } }
  if ($l.TimedOut) { return [pscustomobject]@{ Why = "which WSL distros run could not be read (wsl --list --running did not answer within $WslProbeTimeoutSec s), $not"; Running = @(); Wait = $true } }
  $text = ("$($l.Output)`n$($l.ErrorOutput)" -replace ([string][char]0xFEFF), '')
  $lines = @(($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $running = @($lines | Where-Object { $_ -cmatch $WslDistroNamePattern })
  if ($running.Count) { return [pscustomobject]@{ Why = "only 'wsl --shutdown' frees it, which would stop the WSL distros running now ($($running -join ', ')), $not"; Running = $running; Wait = $false } }
  # Ordinal: a culture's compare ignores a BOM or a NUL, and so would read words
  # that are not WSL's as WSL's.
  $isNone = { param($x) [string]::Equals($x, $WslNoneRunning, [System.StringComparison]::Ordinal) }
  $none = @($lines | Where-Object { & $isNone $_ }).Count -and -not @($lines | Where-Object { -not (& $isNone $_) -and -not $_.StartsWith('Error code: ', [System.StringComparison]::Ordinal) }).Count
  if (-not $none -and -not ($l.ExitCode -eq 0 -and -not $lines.Count)) {
    $said = ' and said nothing'
    if ($lines.Count) { $said = ": $($lines -join ' ')" }
    return [pscustomobject]@{ Why = "which WSL distros run could not be read (wsl --list --running exited $($l.ExitCode)$said), $not"; Running = @(); Wait = $true }
  }
  Info "WSL still holds the tracebloc WSL distro's disk after its import, and no WSL distro is running: shutting WSL down to free it (wsl --shutdown)."
  $s = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--shutdown') -TimeoutSec $WslDiskTimeoutSec
  $why = ''
  if (-not $s.Started) { $why = "'wsl --shutdown', run to free it, did not start ($($s.StartError))" }
  elseif ($s.TimedOut) { $why = "'wsl --shutdown', run to free it, did not finish within $WslDiskTimeoutSec s" }
  elseif ($s.ExitCode -ne 0) { $why = "'wsl --shutdown', run to free it, failed (exit $($s.ExitCode): $(("$($s.Output) $($s.ErrorOutput)" -replace '\s+', ' ').Trim()))" }
  return [pscustomobject]@{ Why = $why; Running = @(); Wait = $false }
}

# Cap DISTRO's VHDX's virtual size at CAPGB, then make it sparse, through wsl.exe
# (THE CAP COMES FIRST, above). Runs right after `wsl --import`, before the distro
# first starts (THE ORDER, above): a distro that already runs is refused by name
# before any step. A disk WSL still holds is freed once, and the step it refused
# runs again (Clear-WslHeldDisk). A disk WSL will not resize because it is sparse
# is made not sparse once, and the cap runs again. A cap that does not run cleanly
# throws, by name, with what wsl.exe said: an uncapped distro is the 1 TiB one row
# 11 measured. A sparse step that does not run cleanly is said, with what wsl.exe
# said, and the install goes on.
function Set-WslDistroDisk {
  param(
    [long]$CapGb,
    [string]$Distro = $WslDistroName,
    [string]$FilePath = 'wsl.exe'
  )
  if ($CapGb -le 0) {
    throw "The WSL distro's disk cap ($CapGb GB) is not a positive size, so the disk was not set. Tell tracebloc support."
  }
  if (Test-WslDistroRunning -Distro $Distro -FilePath $FilePath) {
    throw "The WSL distro $Distro is already running, so its disk can no longer be made sparse and capped: that has to happen after its import and before its first start. Nothing was changed, and nothing is retried. Re-run the install; if it says this again, tell tracebloc support."
  }
  $cap = @{ What = "capped at $CapGb GB"; Sparse = $false; Cap = $true; Arguments = @('--manage', $Distro, '--resize', "$($CapGb)GB") }
  $steps = [System.Collections.Generic.List[object]]::new()
  $steps.Add($cap)
  $steps.Add(@{ What = 'made sparse'; Sparse = $true; Cap = $false; Arguments = @('--manage', $Distro, '--set-sparse', 'true') })
  $sparse = $true
  # How often a disk WSL will not resize because it is sparse was made not sparse:
  # once at most.
  $unsparsed = 0
  # Clear-WslHeldDisk's answer: $null until a step finds the disk held, so it is
  # asked once at most. When it can only wait, the tries left are shared by both
  # steps, so the whole disk step waits $WslDiskReleaseWaitSec s at most.
  $held = $null
  $tries = 0
  for ($i = 0; $i -lt $steps.Count; $i++) {
    $s = $steps[$i]
    $cmd = "wsl $($s.Arguments -join ' ')"
    while ($true) {
      $said = ''
      $r = Invoke-WslProbe -FilePath $FilePath -ArgumentList $s.Arguments -TimeoutSec $WslDiskTimeoutSec
      if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -eq 0) { break }
      $said = ("$($r.Output) $($r.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim()
      if (-not (Test-WslDiskHeld -Said $said)) { break }
      if ($null -eq $held) {
        $held = Clear-WslHeldDisk -FilePath $FilePath
        if (-not $held.Why) { continue }
        if ($held.Wait) {
          $tries = [int][math]::Floor($WslDiskReleaseWaitSec / $WslDiskReleasePollSec)
          Info "WSL still holds the tracebloc WSL distro's disk after its import: waiting up to $WslDiskReleaseWaitSec s for WSL to free it."
        }
      }
      if ($tries -le 0) { break }
      $tries--
      Start-Sleep -Seconds $WslDiskReleasePollSec
    }
    if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0) { continue }
    if ($s.Cap -and $said -match 'ERROR_VIRTUAL_DISK_LIMITATION' -and $unsparsed -lt 1) {
      $unsparsed++
      Info "The tracebloc WSL distro's disk is sparse already, and WSL cannot resize a sparse disk: making it not sparse to cap it, then sparse again (wsl --manage $Distro --set-sparse false)."
      $steps.Insert($i + 1, @{ What = "made not sparse, so it was not capped at $CapGb GB (WSL cannot resize a sparse disk)"; Sparse = $false; Cap = $false; Arguments = @('--manage', $Distro, '--set-sparse', 'false') })
      $steps.Insert($i + 2, $cap)
      continue
    }
    $attached = ''
    if (Test-WslDiskHeld -Said $said) {
      $attached = " Its disk is still attached in WSL, even after 'wsl --shutdown'."
      if ($held.Wait) { $attached = " Its disk is still attached in WSL after waiting $WslDiskReleaseWaitSec s for WSL to free it, and $($held.Why)." }
      elseif ($held.Why) { $attached = " Its disk is still attached in WSL, and $($held.Why)." }
    }
    if ($s.Sparse) {
      $sparse = $false
      if ($said.Contains($WslSparsePolicyRefusal)) {
        # Its words are not echoed: they offer --allow-unsafe, which nothing here runs.
        Warn "WSL has turned sparse disks off on this computer ($cmd exited $($r.ExitCode)), so the tracebloc WSL distro's disk will not give the space it frees back to Windows. Its size is still capped."
        continue
      }
      $how = "failed (exit $($r.ExitCode)): $said"
      if (-not $r.Started) { $how = "did not start ($($r.StartError))" }
      elseif ($r.TimedOut) { $how = "did not finish within $WslDiskTimeoutSec s" }
      Warn "The tracebloc WSL distro's disk could not be made sparse ($cmd $how).$attached The install goes on, and the disk is still capped, but the space the distro frees will not go back to Windows."
      Hint "To make it sparse later: run 'wsl --shutdown' (it stops every WSL distro), then '$cmd', then 'Start-ScheduledTask -TaskName $KeepaliveTaskName' to start tracebloc again."
      continue
    }
    if (-not $r.Started) {
      throw "$cmd did not start ($($r.StartError)), so the WSL distro's disk was not $($s.What). Re-run; if it says this again, tell tracebloc support."
    }
    if ($r.TimedOut) {
      throw "$cmd did not finish within $WslDiskTimeoutSec s, so the WSL distro's disk was not $($s.What). Re-run; if it says this again, tell tracebloc support."
    }
    $limited = ''
    if ($s.Cap -and $unsparsed -and $said -match 'ERROR_VIRTUAL_DISK_LIMITATION') { $limited = " WSL refused it after 'wsl --manage $Distro --set-sparse false' too: a disk that is compressed or encrypted cannot be resized either." }
    $next = 'Re-run; if it says this again, tell tracebloc support.'
    if ((Test-WslDiskHeld -Said $said) -and $held.Running.Count) { $next = "Stop them, or run 'wsl --shutdown', which stops every WSL distro, then run the install again." }
    throw "$cmd failed (exit $($r.ExitCode)): $said The WSL distro's disk was not $($s.What), and an uncapped distro can fill this drive.$attached$limited $next"
  }
  if ($sparse) { Log "WSL distro disk: sparse, and capped at $CapGb GB" } else { Log "WSL distro disk: capped at $CapGb GB" }
}

# The virtual size in bytes of the VHDX at PATH, read from the file's own metadata,
# or $null when it cannot be read: no file, not a VHDX, or one WSL holds open.
# Never a guess. The VHDX format: the file identifier at 0, the region table at
# 192 KiB names the metadata region, and the metadata table there names the
# Virtual Disk Size item, a UINT64.
function Get-WslVhdxVirtualSize {
  param([string]$Path)
  $metadataRegion = [guid]'8b7ca206-4790-4b9a-b8fe-575f050f886e'
  $virtualDiskSize = [guid]'2fa54224-cd1b-4876-b211-5dbed83bf4b8'
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $r = [System.IO.BinaryReader]::new($fs)
    $ascii = [System.Text.Encoding]::ASCII
    if ($ascii.GetString($r.ReadBytes(8)) -ne 'vhdxfile') { return $null }
    $fs.Position = 192KB
    if ($ascii.GetString($r.ReadBytes(4)) -ne 'regi') { return $null }
    [void]$r.ReadUInt32()
    $regions = $r.ReadUInt32()
    [void]$r.ReadUInt32()
    if ($regions -gt 2047) { return $null }
    $at = $null
    for ($i = 0; $i -lt $regions; $i++) {
      $id = [guid]::new($r.ReadBytes(16))
      $offset = $r.ReadUInt64()
      [void]$r.ReadBytes(8)
      if ($id -eq $metadataRegion) { $at = [long]$offset }
    }
    if ($null -eq $at) { return $null }
    $fs.Position = $at
    if ($ascii.GetString($r.ReadBytes(8)) -ne 'metadata') { return $null }
    [void]$r.ReadUInt16()
    $items = $r.ReadUInt16()
    [void]$r.ReadBytes(20)
    for ($i = 0; $i -lt $items; $i++) {
      $id = [guid]::new($r.ReadBytes(16))
      $offset = $r.ReadUInt32()
      [void]$r.ReadBytes(12)
      if ($id -eq $virtualDiskSize) {
        $fs.Position = $at + $offset
        $size = $r.ReadUInt64()
        if ($size -gt 0) { return [long]$size }
        return $null
      }
    }
    return $null
  } catch {
    return $null
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

# A re-run over a distro that is already there: re-derive the cap from the host's
# free space and only GROW the disk to it (see THE DISTRO'S DISK above). PATH is
# the import directory, VHDX the disk WSL made there. Never throws: what it cannot
# do leaves the disk at the cap it has, and says so.
function Update-WslDistroDisk {
  param(
    [string]$Path,
    [string]$Vhdx = [System.IO.Path]::Combine($Path, 'ext4.vhdx'),
    [int]$ReserveGb = $WslDiskReserveGb,
    [string]$Distro = $WslDistroName,
    [string]$FilePath = 'wsl.exe'
  )
  $size = Get-WslVhdxVirtualSize -Path $Vhdx
  if ($null -eq $size) {
    Warn "Could not read the WSL distro's disk size from $Vhdx, so its cap is left as it is."
    return
  }
  $nowGb = [long][math]::Floor($size / 1GB)
  $hostFree = Get-WslDiskFreeSpace -Path $Path
  if ($null -eq $hostFree) {
    Warn "Disk: could not read how much space is free on $(Get-WslDiskDrive -Path $Path), so the WSL distro's disk stays capped at $nowGb GB."
    return
  }
  $want = ConvertTo-WslDiskCapGb -Free $hostFree -ReserveGb $ReserveGb
  if ($want -le $nowGb) {
    Log "WSL distro disk: kept at $nowGb GB (the host's free space now gives $want GB, and a cap is never shrunk)"
    return
  }
  $grow = @('--manage', $Distro, '--resize', "$($want)GB")
  $g = Invoke-WslProbe -FilePath $FilePath -ArgumentList $grow -TimeoutSec $WslDiskTimeoutSec
  if ($g.Started -and -not $g.TimedOut -and $g.ExitCode -eq 0) {
    Log "WSL distro disk: grown from $nowGb GB to $want GB"
    return
  }
  $why = "exit $($g.ExitCode): $(("$($g.Output) $($g.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim())"
  if (-not $g.Started) { $why = "did not start: $($g.StartError)" }
  elseif ($g.TimedOut) { $why = "did not finish within $WslDiskTimeoutSec s" }
  Warn "wsl $($grow -join ' ') did not grow the WSL distro's disk ($why), so it stays capped at $nowGb GB."
  if ($why -match 'ERROR_VIRTUAL_DISK_LIMITATION') {
    Hint "WSL cannot resize a sparse disk. To grow it by hand: run 'wsl --shutdown' (it stops every WSL distro), then 'wsl --manage $Distro --set-sparse false', 'wsl $($grow -join ' ')' and 'wsl --manage $Distro --set-sparse true', then 'Start-ScheduledTask -TaskName $KeepaliveTaskName' to start tracebloc again."
  }
}

# Fetch the WSL distro's root filesystem from ghcr.io into DEST by its pinned
# layer digest, and confirm it. Returns DEST, or throws a refusal that names what
# was wrong. The pins are the release's stamped WSL_ROOTFS_* unless passed. They
# are checked for shape first: a pin this cannot use is a broken release, refused
# before anything is downloaded. A download that failed part way leaves no file
# behind, so it is refused as missing, not as tampered.
function Get-WslDistroImage {
  param(
    [string]$Image = $WSL_ROOTFS_IMAGE,
    [string]$Sha256 = $WSL_ROOTFS_SHA256,
    [long]$Bytes = $WSL_ROOTFS_BYTES,
    [string]$Version = $WSL_ROOTFS_VERSION,
    [string]$Digest = $WSL_ROOTFS_DIGEST,
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
  Log "Downloading the WSL distro image $Version ($([math]::Round($Bytes / 1MB)) MB) from $Image..."
  Show-Live "Downloading the WSL distro ($([math]::Round($Bytes / 1MB)) MB)..."
  $fetched = Receive-WslDistroImage -Url "https://ghcr.io/v2/$repo/blobs/sha256:$Sha256" -Token $token -Dest $Dest -MaxBytes $Bytes
  if (-not $fetched) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
  Confirm-WslDistroImage -Path $Dest -Sha256 $Sha256 -Bytes $Bytes
  Log "WSL distro image $Version verified against its pinned length and sha256 (the layer of $Image@$Digest)"
  Ok "WSL distro downloaded and verified $Dot $([math]::Round($Bytes / 1MB)) MB"
  return $Dest
}

# `wsl --import` as S-W row 3 measured it, as the daily user, unelevated: 8.4 s on
# the managed laptop, with no consent.exe. 600 s is a bound, not a measured worst
# case.
$WslImportTimeoutSec = 600

# Whether `wsl --list --quiet` names DISTRO, read as Test-WslDistroRunning reads its
# list: State 'registered' or 'absent', or 'unread' when wsl.exe did not start or did
# not answer in time, with Why. Unread is never taken for absent: the import step
# stops on it, as a disk in the import folder may then be the live distro's, and
# nothing may be fetched on a guess. The exit code is not the answer:
# what wsl.exe exits with on a machine with no distro at all is not measured, and the
# list it printed is what it said.
function Get-WslDistroRegistration {
  param([string]$Distro = $WslDistroName, [string]$FilePath = 'wsl.exe')
  $listed = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--list', '--quiet')
  if (-not $listed.Started) { return [pscustomobject]@{ State = 'unread'; Why = "did not start ($($listed.StartError))" } }
  if ($listed.TimedOut) { return [pscustomobject]@{ State = 'unread'; Why = "did not answer within $WslProbeTimeoutSec s" } }
  foreach ($name in ($listed.Output -replace "`0", '') -split "`r?`n") {
    if ($name.Trim() -ceq $Distro) { return [pscustomobject]@{ State = 'registered'; Why = '' } }
  }
  return [pscustomobject]@{ State = 'absent'; Why = '' }
}

# Unregisters DISTRO after its disk step stopped the install, so that a re-run
# imports it afresh instead of taking the re-run path over a disk never capped
# (THE ORDER, above). Never throws: the disk step's refusal is what stops the
# install, and this only says whether the distro is gone.
function Remove-WslDistro {
  param([string]$Distro = $WslDistroName, [string]$FilePath = 'wsl.exe')
  $r = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--unregister', $Distro) -TimeoutSec $WslDiskTimeoutSec
  if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
    Info "Removed the WSL distro $Distro this run had just imported, so the next run imports it afresh."
    return
  }
  $why = "exit $($r.ExitCode): $(("$($r.Output) $($r.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim())"
  if (-not $r.Started) { $why = "did not start: $($r.StartError)" }
  elseif ($r.TimedOut) { $why = "did not finish within $WslDiskTimeoutSec s" }
  Warn "wsl --unregister $Distro did not remove the WSL distro this run had just imported ($why). Remove it with 'wsl --unregister $Distro' before running the install again, or the next run keeps its uncapped disk."
}

# The import step: the distro imported, with its disk set before anything starts
# it (THE ORDER, above), or the one already here. On a fresh machine:
#   1. the cap is read first, so a drive that is too full is refused before
#      anything is fetched, and a disk WSL left in the import folder with no distro
#      using it is refused before anything is imported over it;
#   2. the rootfs is fetched and confirmed (Get-WslDistroImage) into a file of its
#      own in the user's temp folder, deleted again whatever happens;
#   3. `wsl --import` into the import folder, as the daily user, unelevated;
#   4. Set-WslDistroDisk. When it stops the install, the distro just imported is
#      unregistered.
# A RE-RUN over a distro that is already registered imports nothing: only
# Update-WslDistroDisk. A list that cannot be read stops it first, before the disk
# check and before anything is fetched. Returns 'imported' or 'present'.
function Import-WslDistro {
  param([string]$FilePath = 'wsl.exe')
  $dir = Get-WslImportDir
  $reg = Get-WslDistroRegistration -FilePath $FilePath
  if ($reg.State -ceq 'unread') {
    throw "wsl --list $($reg.Why), so whether the tracebloc WSL distro is already on this machine cannot be told. Nothing was downloaded, imported or removed. Run the install again; if it says this again, tell tracebloc support."
  }
  if ($reg.State -ceq 'registered') {
    Log "The tracebloc WSL distro is already on this machine: it is kept, and nothing is imported."
    Update-WslDistroDisk -Path $dir -FilePath $FilePath
    Ok 'WSL distro installed already'

    return 'present'
  }
  $vhdx = Join-Path $dir 'ext4.vhdx'
  if (Test-Path -LiteralPath $vhdx) {
    throw "A WSL disk is already at $vhdx, but no WSL distro named $WslDistroName uses it, so nothing was imported over it. If nothing of yours is in that folder, delete the folder, then run the install again."
  }
  $cap = Get-WslDistroDiskCap -Path $dir
  $rootfs = Join-Path ([System.IO.Path]::GetTempPath()) ('tracebloc-wsl-rootfs-' + [guid]::NewGuid().ToString('N') + '.tar.gz')
  try {
    $null = Get-WslDistroImage -Dest $rootfs
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Log "Importing the tracebloc WSL distro into $dir..."
    Show-Live 'Installing the WSL distro...'
    $import = @('--import', $WslDistroName, (ConvertTo-WindowsArgument $dir), (ConvertTo-WindowsArgument $rootfs), '--version', '2')
    $cmd = "wsl --import $WslDistroName"
    $imp = Invoke-WslProbe -FilePath $FilePath -ArgumentList $import -TimeoutSec $WslImportTimeoutSec
    if (-not $imp.Started) {
      throw "$cmd did not start ($($imp.StartError)), so the tracebloc WSL distro was not imported. Run the install again; if it says this again, tell tracebloc support."
    }
    if ($imp.TimedOut) {
      throw "$cmd did not finish within $WslImportTimeoutSec s, so whether the tracebloc WSL distro was imported cannot be told. If 'wsl --list' names $WslDistroName, remove it with 'wsl --unregister $WslDistroName', then run the install again."
    }
    if ($imp.ExitCode -ne 0) {
      $wslSaid = ("$($imp.Output) $($imp.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim()
      throw "$cmd failed (exit $($imp.ExitCode)): $wslSaid The tracebloc WSL distro was not imported. Run the install again; if it says this again, tell tracebloc support."
    }
  } finally {
    Remove-Item -LiteralPath $rootfs -Force -ErrorAction SilentlyContinue
  }
  Log "Imported the tracebloc WSL distro into $dir"
  try {
    Set-WslDistroDisk -CapGb $cap -FilePath $FilePath
  } catch {
    Remove-WslDistro -FilePath $FilePath
    throw
  }
  Ok "WSL distro installed $Dot disk capped at $cap GB"
  return 'imported'
}

# THE HOST'S CA ROOTS IN THE DISTRO ("Proxy and
# CA"). Behind a proxy that inspects TLS, every TLS client in the distro (curl, and
# containerd's image pulls) has to trust the CA that IT put in the host's root
# store, and Ubuntu's own roots do not hold it. Add-WslHostRootTrust hands the
# host's roots in and proves they arrived, in this order:
#   1. the host's trusted roots, LocalMachine's and the user's, as one PEM file;
#   2. copied to $DistroRootsFile by `wsl --exec /usr/bin/cp`, the file's path a
#      plain argument. The first form, a quoted `sh -c` block through `wsl --`,
#      fails under Windows PowerShell 5.1, because the login shell takes its $0
#      (S-W row 9, on both machines);
#   3. the bundle rebuilt by /usr/sbin/update-ca-certificates, named by its path:
#      `wsl --exec` did not find it by name on S-W's laptop. A copy without the
#      rebuild leaves the bundle curl and containerd read without the roots, and
#      both then fail late, on an unknown issuer, naming nothing of ours. So a
#      rebuild that fails is refused by name;
#   4. the bundle, $DistroCaBundle, read back and held to every root handed in,
#      before k3s restarts;
#   5. k3s restarted when it is running or starting, because containerd reads the
#      roots once, when it starts: a k3s still activating has already read the old
#      bundle. The state is `systemctl is-active k3s`'s answer, never its exit
#      code, which is non-zero for activating too. A k3s that is not running reads
#      them when it next starts (a unit not installed yet answers inactive). Any
#      other answer, none included (systemd out of reach), is a refusal, never
#      read as stopped.
# No registries.yaml: with the bundle rebuilt, containerd pulled with none (S-W's
# Azure run). The laptop run that needed one never rebuilt the bundle.
# Invoke-WslInstall runs it right after the logon task's first start, with the
# distro running, and before the core's first run, where k3s first needs egress.
# The proxy (row 10) is part 1's other half.
$DistroRootsFile = '/usr/local/share/ca-certificates/tracebloc-windows-roots.crt'
$DistroCaBundle = '/etc/ssl/certs/ca-certificates.crt'
$DistroCp = '/usr/bin/cp'
$DistroUpdateCaCertificates = '/usr/sbin/update-ca-certificates'
$DistroSystemctl = '/usr/bin/systemctl'
# `systemctl restart k3s` returns once k3s says it has started. 300 s is a bound,
# not a measurement.
$WslK3sRestartTimeoutSec = 300
# `systemctl is-active`'s answers (systemd's unit active states): the ones that
# restart k3s, and the ones that leave it to read the roots when it next starts.
$K3sStatesRestart = @('active', 'activating', 'reloading', 'refreshing')
$K3sStatesStopped = @('inactive', 'failed', 'deactivating', 'maintenance')

# The host's trusted root certificates, LocalMachine's and the user's, each once
# (by thumbprint), in thumbprint order. A seam for the test suite: off Windows
# there is no Cert: drive, and the answer is none.
function Get-HostRootCertificate {
  $seen = @{}
  foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\Root')) {
    foreach ($c in @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue)) {
      if ($c.RawData -and -not $seen.ContainsKey($c.Thumbprint)) { $seen[$c.Thumbprint] = $c }
    }
  }
  return @($seen.Values | Sort-Object Thumbprint)
}

# CERTIFICATE's DER bytes as base64 on one line: the key the bundle check compares.
function ConvertTo-CertificateBody {
  param([object]$Certificate)
  return [Convert]::ToBase64String([byte[]]$Certificate.RawData)
}

# The certificates as one PEM text: base64, 64 characters a line, LF line ends.
function ConvertTo-PemText {
  param([object[]]$Certificate)
  $sb = New-Object System.Text.StringBuilder
  foreach ($c in $Certificate) {
    $b64 = ConvertTo-CertificateBody -Certificate $c
    [void]$sb.Append("-----BEGIN CERTIFICATE-----`n")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
      [void]$sb.Append($b64.Substring($i, [Math]::Min(64, $b64.Length - $i))).Append("`n")
    }
    [void]$sb.Append("-----END CERTIFICATE-----`n")
  }
  return $sb.ToString()
}

# Every certificate a PEM TEXT holds, as a set of one-line base64 bodies.
function Get-PemCertificateBody {
  param([AllowNull()][string]$Text)
  $bodies = @{}
  if (-not $Text) { return $bodies }
  foreach ($m in [regex]::Matches($Text, '-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+?)-----END CERTIFICATE-----')) {
    $bodies[($m.Groups[1].Value -replace '\s', '')] = $true
  }
  return $bodies
}

# What went wrong with one Invoke-WslProbe run, in words, for a refusal.
function Format-WslProbeFailure {
  param([object]$Probe, [int]$TimeoutSec)
  if (-not $Probe.Started) { return "it did not start: $($Probe.StartError)" }
  if ($Probe.TimedOut) { return "it did not finish within $TimeoutSec s" }
  $said = ("$($Probe.ErrorOutput) $($Probe.Output)" -replace "`0", '' -replace '\s+', ' ').Trim()
  if ($said) { return "exit $($Probe.ExitCode): $said" }
  return "exit $($Probe.ExitCode)"
}

# Hand the host's trusted roots to DISTRO and prove its trust bundle holds them, then
# restart k3s if it runs. Throws a refusal that names the step; never ends quietly
# with roots the bundle does not hold.
function Add-WslHostRootTrust {
  param([string]$Distro = $WslDistroName)
  $roots = @(Get-HostRootCertificate)
  if ($roots.Count -eq 0) {
    Warn "Could not read this computer's trusted root certificates, so the tracebloc WSL distro trusts only its own. Behind a proxy that inspects TLS, its downloads will fail on an unknown certificate issuer: share this output with tracebloc support."
    return
  }
  $asRoot = @('-d', $Distro, '-u', 'root', '--exec')
  $pem = Join-Path ([IO.Path]::GetTempPath()) ('tracebloc-host-roots-' + [guid]::NewGuid().ToString('N') + '.pem')
  [IO.File]::WriteAllText($pem, (ConvertTo-PemText -Certificate $roots), (New-Object System.Text.ASCIIEncoding))
  try {
    $from = ConvertTo-DistroPath -Path $pem
    $copy = Invoke-WslProbe -ArgumentList ($asRoot + @($DistroCp, (ConvertTo-WindowsArgument $from), $DistroRootsFile)) -TimeoutSec $WslDistroStartTimeoutSec
    if (-not $copy.Started -or $copy.TimedOut -or $copy.ExitCode -ne 0) {
      throw "This computer's trusted root certificates could not be copied into the tracebloc WSL distro ($(Format-WslProbeFailure $copy $WslDistroStartTimeoutSec)), so TLS inside it would fail behind a proxy that inspects TLS. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
    $rebuild = Invoke-WslProbe -ArgumentList ($asRoot + @($DistroUpdateCaCertificates)) -TimeoutSec $WslDistroStartTimeoutSec
    if (-not $rebuild.Started -or $rebuild.TimedOut -or $rebuild.ExitCode -ne 0) {
      throw "This computer's trusted root certificates were copied into the tracebloc WSL distro, but $DistroUpdateCaCertificates did not add them to its trust bundle ($(Format-WslProbeFailure $rebuild $WslDistroStartTimeoutSec)), so TLS inside the distro would fail on an unknown certificate issuer. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
    $read = Invoke-WslProbe -ArgumentList ($asRoot + @($DistroCat, $DistroCaBundle)) -TimeoutSec $WslDistroStartTimeoutSec
    if (-not $read.Started -or $read.TimedOut -or $read.ExitCode -ne 0) {
      throw "The tracebloc WSL distro's trust bundle ($DistroCaBundle) could not be read back ($(Format-WslProbeFailure $read $WslDistroStartTimeoutSec)), so whether it holds this computer's trusted root certificates cannot be told. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
    $held = Get-PemCertificateBody -Text $read.Output
    $missing = @($roots | Where-Object { -not $held.ContainsKey((ConvertTo-CertificateBody -Certificate $_)) })
    if ($missing.Count -gt 0) {
      throw "The tracebloc WSL distro's trust bundle ($DistroCaBundle) holds $($roots.Count - $missing.Count) of this computer's $($roots.Count) trusted root certificates after $DistroUpdateCaCertificates, so TLS inside the distro would fail on an unknown certificate issuer. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
  } finally {
    Remove-Item -LiteralPath $pem -Force -ErrorAction SilentlyContinue
  }
  Log "The tracebloc WSL distro trusts this computer's $($roots.Count) root certificates"
  $running = Invoke-WslProbe -ArgumentList ($asRoot + @($DistroSystemctl, 'is-active', 'k3s')) -TimeoutSec $WslDistroStartTimeoutSec
  $state = ''
  if ($running.Started -and -not $running.TimedOut -and $running.Output) {
    $state = "$(@($running.Output -split "`r?`n" | Where-Object { $_.Trim() })[0])".Trim()
  }
  if ($K3sStatesStopped -contains $state) { return }
  if ($K3sStatesRestart -notcontains $state) {
    throw "Whether k3s runs in the tracebloc WSL distro could not be told ($(Format-WslProbeFailure $running $WslDistroStartTimeoutSec)), so it was not restarted to read the new certificates. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  $restart = Invoke-WslProbe -ArgumentList ($asRoot + @($DistroSystemctl, 'restart', 'k3s')) -TimeoutSec $WslK3sRestartTimeoutSec
  if (-not $restart.Started -or $restart.TimedOut -or $restart.ExitCode -ne 0) {
    throw "k3s in the tracebloc WSL distro did not restart ($(Format-WslProbeFailure $restart $WslK3sRestartTimeoutSec)), so its image pulls may not trust this computer's root certificates yet. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  Log "Restarted k3s, so its image pulls trust them too"
}
