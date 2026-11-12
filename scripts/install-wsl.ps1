# =============================================================================
#  install-wsl.ps1 -- the Windows distro path
#
#  install.ps1 runs this as a child process (powershell.exe -File): it is the one
#  Windows install path since the PowerShell core was retired. It is in install.ps1's $Files and in the signed manifest, so on the
#  customer path it runs only after install.ps1 has verified it.
#
#  -CoreDir is the one tree it may use:
#    - on the customer path, ONLY the temp dir install.ps1 has just verified
#      against the signed manifest (the sub-scripts plus manifest.sha256, laid
#      out as under scripts/);
#    - for e2e, a commit's own scripts/ directory, with a manifest.sha256
#      generated from that commit by scripts/gen-manifest.sh (it is never
#      committed).
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
#       (the declared "restart, then re-run" code, which the e2e harness reads)
#
#  Its steps are the numbered sections below, and Invoke-WslInstall, at the end,
#  runs them in order: WSL ready, the import and its disk,
#  the logon task, the host's CA roots, the core, the record, then the account's
#  example use case (Invoke-HostExample).
# =============================================================================
#Requires -Version 5.1
param([string]$CoreDir)

# The output helpers, the log, and the manifest checks this script shares with
# install.ps1 are defined once, in install-base.ps1 beside this file
# so the two cannot drift. install.ps1 verified it with this file before
# running it, and Confirm-CoreDir checks it again through $CoreFiles below.
. (Join-Path $PSScriptRoot 'install-base.ps1')

# The end of a run Windows needs a restart for: not a failure, so ⚠ and no log.
function Write-RestartNeeded {
  Write-SetupEnd -Glyph ([char]0x26A0) -Color Yellow -Head 'Restart Windows to finish turning on WSL' -Next 'Then run the installer again; it continues from here:' -NoLog
}

# What this script uses from -CoreDir, as manifest keys, beside the core's scripts
# (Get-CoreScriptKeys). This script is one of them: the tree it is handed must
# hold the same verified copy of it, and of each file it loads from beside itself.
$CoreFiles = @('scripts/install-wsl.ps1', 'scripts/install-base.ps1', 'scripts/install-wsl-distro.ps1', 'scripts/install-wsl-gpu.ps1', 'scripts/install-wsl-record.ps1', 'scripts/install-wsl-ready.ps1', 'scripts/install-wsl-account.ps1')

# Refuses, by name, a -CoreDir it cannot verify against the manifest.sha256 in it:
# FILES and every core script that manifest lists.
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
  # The core this path runs in the distro, by the manifest's own list. A manifest
  # that lists none of it cannot vouch for what section 5 would run.
  $core = @(Get-CoreScriptKeys -ManifestPath $manifest)
  if ($core.Count -eq 0) {
    throw "$CoreDir is not a verified installer tree: its manifest.sha256 lists none of the installer's core scripts."
  }
  foreach ($f in @($Files) + $core) {
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

# Section 1, WSL ready, is install-wsl-ready.ps1, beside this file.
. (Join-Path $PSScriptRoot 'install-wsl-ready.ps1')

# =============================================================================
#  2. The distro image: the WSL distro's root filesystem.
#
#  On Windows the core is to run inside our own WSL distro, imported from a root
#  filesystem that 3.1 publishes to ghcr.io. Get-WslDistroImage
#  fetches it by its layer digest, and Confirm-WslDistroImage refuses it unless it is
#  exactly the bytes the release pins: the length first, which is cheap and names
#  a truncated or padded download, then the sha256. A refused file is deleted at
#  once, so no later step can import it by mistake.
#
#  Import-WslDistro, at the end of this section, is the import step Invoke-WslInstall
#  runs: the rootfs fetched and confirmed, then `wsl --import tracebloc
#  "$env:LOCALAPPDATA\tracebloc\wsl" <rootfs> --version 2` as the daily user,
#  unelevated (S-W row 3: 8.4 s, no consent.exe), then the disk. The pins are
#  facts.env's WSL_ROOTFS_*, stamped below, and Get-WslDistroImage takes them unless
#  told otherwise.
#  Still to come, each waiting on the row of spike S-W that decides it:
#    The per-user logon task that keeps the distro running is section 3's.
#    The proxy inside the distro (row 10) crosses on the core's runs (section 5);
#      the host-side fetch below honours HTTPS_PROXY like every bootstrap
#      download. The host's CA roots (row 9) are Add-WslHostRootTrust's, below.
#    The GPU the distro advertises (S-W row 13): section 4b says which GPU WSL can
#      give it, and the core wires it (k3s-gpu.sh, _native_k3s_gpu_wsl_prepare).
# =============================================================================

# The rootfs this release pins: facts.env's WSL_ROOTFS_*, stamped here by
# check-facts.sh (--write stamps them, --check holds them to facts.env). The sha256
# and the length are the one layer an install fetches and Confirm-WslDistroImage
# holds the file to; the digest is the manifest that lists that layer, the one cosign
# signed; the version is that manifest's tag. scripts/wsl-rootfs-pin.sh bump moves
# them, through facts.env, never here by hand.
$WSL_ROOTFS_IMAGE = "ghcr.io/tracebloc/wsl-distro"
$WSL_ROOTFS_SHA256 = "0846a8bcb469c64c2821db614d4440508d6561b178371801c10d3b2ee3eb1f8d"
$WSL_ROOTFS_BYTES = "126330208"
$WSL_ROOTFS_DIGEST = "sha256:92bc181882bfb6492282ab9135f4ecbf959f7a89d0cd0332c14b166ba8588728"
$WSL_ROOTFS_VERSION = "ubuntu-24.04.5-20261017-v1.36.5-k3s1"

# The rest of this section, from the fetch to the import, the disk and the CA
# roots, is install-wsl-distro.ps1, beside this file.
. (Join-Path $PSScriptRoot 'install-wsl-distro.ps1')

# =============================================================================
#  3. The logon task: what keeps the distro running.
#
#  WSL stops a distro seconds after its last wsl.exe exits, and k3s with it (S-W
#  row 5a). A task of the daily user's own, at their logon, holds one wsl.exe open
#  in the distro for the session: `sleep infinity`, started by a launcher that
#  shows no window. It is the spike kit's block, the launcher
#  it chose, registered unelevated at the Task Scheduler root as
#  tracebloc-keepalive, which the install record names \tracebloc-keepalive.
#
#  It waits only for the distro to run. k3s Ready is the core's own wait, in its
#  cluster run, on the core's one TB_API_WAIT_S budget (180 s), so no wait here
#  may stand in for that one. That budget covers a distro start:
# our distro was Ready within 30-40 s of a host reboot in
#  five e2e runs, and S-W's stock image 22 s after `wsl --terminate` (its `ready`
#  row). The 191 s once cited here was one row-4 reading on that stock image, a
#  re-run with k3s already installed; S-W draws no timing from
#  row 4. Our distro carries no cloud-init and no snapd, which the stock image
#  runs at every start; wsl-distro.sh test refuses a build that does.
#
#  PROVISIONAL until rows 6-8 (idle, sleep, restart) hold on both S-W machines,
#  Windows 11 and Server 2025. Invoke-WslInstall runs it right after the import
#  (section 2): its start is the distro's first.
#    TODO(part 4): the install record's logon-task artefact, once cli-dev's
#      `delete` knows the kind, and with it the task's removal.
# =============================================================================

$KeepaliveTaskName = 'tracebloc-keepalive'
$KeepaliveTaskId = "\$KeepaliveTaskName"
$KeepaliveStartTimeoutSec = 60

# THE LAUNCHER, named here and nowhere else: a program under %WINDIR% and its
# arguments, put in front of wsl.exe. conhost --headless runs it with no console
# window (S-W row 5b, Windows 11); wsl.exe started directly showed
# one. @() starts wsl.exe directly.
$KeepaliveLauncher = @('System32\conhost.exe', '--headless')

# What the logon task runs: the launcher, then wsl.exe holding the distro open.
function Get-KeepaliveAction {
  $wsl = "$env:WINDIR\System32\wsl.exe"
  $hold = "-d $WslDistroName --exec /bin/sleep infinity"
  if (@($KeepaliveLauncher).Count -eq 0) { return [pscustomobject]@{ Execute = $wsl; Argument = $hold } }
  return [pscustomobject]@{ Execute = "$env:WINDIR\$($KeepaliveLauncher[0])"; Argument = "$($KeepaliveLauncher[1]) $wsl $hold" }
}

# The account the task runs as, as Windows names it: a seam, since the test
# suite's .NET has no Windows identity.
function Get-BootstrapIdentityName { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# The task's state and last result, for a refusal.
function Get-KeepaliveTaskState {
  $t = Get-ScheduledTask -TaskName $KeepaliveTaskName -ErrorAction SilentlyContinue
  if (-not $t) { return 'not registered' }
  $i = $t | Get-ScheduledTaskInfo
  return ('{0}, last result 0x{1:X8}' -f $t.State, [int64]$i.LastTaskResult)
}

# Registers the logon task for the user running this bootstrap, unelevated, and
# starts it now, so the distro runs before the core does. Re-registering replaces
# it. Refuses when the task cannot be registered or started, or when the distro
# has not started from it within TIMEOUTSEC.
function Register-KeepaliveTask {
  param([int]$TimeoutSec = $KeepaliveStartTimeoutSec)
  $act = Get-KeepaliveAction
  $a = New-ScheduledTaskAction -Execute $act.Execute -Argument $act.Argument
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -Hidden
  try {
    # The issue's form first, then the account as Windows names it (the kit's order).
    # A trigger only stores the name: Register-ScheduledTask resolves it, so a name
    # the scheduler refuses throws there, and the next one is tried. The last one's
    # refusal is the one named.
    $users = @("$env:USERDOMAIN\$env:USERNAME", (Get-BootstrapIdentityName))
    for ($i = 0; $i -lt $users.Count; $i++) {
      $t = New-ScheduledTaskTrigger -AtLogOn -User $users[$i]
      try {
        Register-ScheduledTask -TaskName $KeepaliveTaskName -Action $a -Trigger $t -Settings $s -Force -ErrorAction Stop | Out-Null
        # From here the task is on this machine, whatever its start or the wait
        # below says: a stop names it in what is left (Write-WslInstallLeft).
        $script:KeepaliveRegistered = $true
        break
      } catch {
        if ($i -eq $users.Count - 1) { throw }
      }
    }
    Start-ScheduledTask -TaskName $KeepaliveTaskName -ErrorAction Stop
  } catch {
    throw "The logon task that keeps the tracebloc WSL distro running could not be set up for this user ($($_.Exception.Message)). Run this installer again."
  }
  # Two clocks, as the core's waits keep them: the seconds slept, so a stubbed
  # sleep still ends it, and the wall clock, since each probe takes time too.
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $slept = 0
  while (-not (Test-WslDistroRunning)) {
    if ($slept -ge $TimeoutSec -or (Get-Date) -ge $deadline) {
      throw "The tracebloc WSL distro did not start from its logon task within $TimeoutSec seconds (the task: $(Get-KeepaliveTaskState)). Run this installer again."
    }
    Start-Sleep -Seconds 1
    $slept++
  }
  Ok "WSL distro running $Dot starts at each sign-in"
}

# =============================================================================
#  4. The host GPU check.
#
#  On the distro path the core runs inside WSL, but nvidia-smi.exe, the driver and
#  the GPUs Windows lists live on the Windows host, so the GPU check stays here
# (W21). Find-Gpu, Confirm-NvidiaDriver and Get-NvidiaFloorVerdict,
#  with everything they call, came over unchanged from the PowerShell core that
#  part 5 retired, and their behaviour is held by install-wsl-host.Tests.ps1. Info,
#  Ok and Warn are this file's own output helpers, which print the same lines
#  without the log.
#
#  Invoke-WslCore calls Find-Gpu before the core's first run, so both runs carry its
#  answer. The floors: check-facts.sh stamps them from facts.env.
#  The words (W17, W21): below the hard floor (the CUDA 13 minimum) or compute
#  capability 7.5 it runs CPU-only, and below the hard floor the hint names the
#  driver to install and says to re-run the installer. There is no warning band
#  (2026-10-18). Every line those branches say is the core's own (detect-gpu.sh's
#  _nvidia_gpu_floor_gate), a Pester case holds them so, with the dash written " -- "
#  in these ASCII files.
#    S-W row 14 has not measured a Windows driver: the floor is NVIDIA's CUDA 13
#    minimum, as on Linux.
#  The handover: inside the distro nvidia-smi answers for this Windows driver, whose
#  number the Linux floors must never judge. So Confirm-NvidiaDriver records its
#  verdict ($GPU_FLOOR_VERDICT), and both core runs carry it and the GPU_UNSUPPORTED_*
#  values on their line (New-CoreRunArguments). The core takes them as given
#  (detect-gpu.sh, _nvidia_gpu_wsl_verdict), and reads an empty or unknown verdict as
#  cannot tell: CPU-only. The words a verdict can be are declared once, as
#  detect-gpu.sh's _NVIDIA_GPU_FLOOR_VERDICTS, and a Pester case holds
#  Get-NvidiaFloorVerdict's returns to them.
#  Find-Gpu's own reports, a GPU that is not NVIDIA (not_nvidia) and an NVIDIA GPU on
#  arm64 (arch_unsupported), go on the same line as GPU_UNSUPPORTED_*, with no
#  verdict. In the distro, where WSL shows no PCI device, the core takes them from
#  there (detect-gpu.sh, _gpu_wsl_host_report).
#  The device half (S-W row 13) is the core's, and takes only that verdict and
#  section 4b's report from here: the host never advertises a GPU itself. In the
#  distro the chart's device plugin, v0.20.1 under the nvidia RuntimeClass, finds
#  WSL by /dev/dxg and advertises one shared device, all (W26, measured by S-W).
# =============================================================================

# The verdict's state, as Confirm-NvidiaDriver leaves it.
$NVIDIA_DRIVER_OK = $false
$GPU_SKIP_REASON  = ""
$GPU_UNSUPPORTED_REASON = ""
$GPU_UNSUPPORTED_NAME   = ""
$GPU_UNSUPPORTED_CODE   = ""
$GPU_FLOOR_VERDICT      = ""
$NVIDIA_GPU_NAMES       = ""
$NVIDIA_DRIVER_VERSION = ""

# The NVIDIA GPU floors (scripts/spec/facts.env NVIDIA_DRIVER_FLOOR_WINDOWS /
# NVIDIA_COMPUTE_CAP_FLOOR / NVIDIA_DRIVER_HARD_FLOOR_WINDOWS), and the pre-Turing
# families by name. Policy, so no TRACEBLOC_* override.
$NVIDIA_DRIVER_FLOOR = "580"
$NVIDIA_COMPUTE_CAP_FLOOR = "7.5"
$NVIDIA_DRIVER_HARD_FLOOR = "580"
$NVIDIA_PRE_TURING_NAME_RE = ' (GT|GTS) [0-9]{3,4}[A-Z]* | GTX [4-9][0-9]{2}[A-Z]* | GTX 10[0-9]{2}[A-Z]* | GTX TITAN | TITAN (X|XP|V|Z|BLACK) | MX[1-3][0-9]{2} | GEFORCE [6-9][0-9]{2}(M|MX|A) | QUADRO (K|M|G?P|GV)[0-9]+[A-Z]* | NVS [0-9]{3} | (TESLA|GRID) [KMPV][0-9]+[A-Z]* | (K80|K40M?|K20X?M?|M60|M40|M10|P100|P40|P6|P4|V100S?) '

# The vendor Find-Gpu found: none, nvidia, amd, or nvidia_unsupported and
# amd_unsupported for a GPU it leaves off.
$GPU_VENDOR       = "none"
# The vendors whose GPU counts as "a GPU, but not NVIDIA", matched against the NORMALISED name
# (ConvertTo-GpuNormalisedName). An allowlist, so a virtual or BMC display adapter (Hyper-V,
# VMware SVGA, ASPEED, Matrox, Parsec, Citrix) still reads as "no GPU". Intel counts, the
# integrated GPU included. detect-gpu.sh carries the SAME strings (detect-gpu.bats holds them equal).
$GPU_NOT_NVIDIA_VENDOR_RE   = ' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|INTEL|APPLE) '
$GPU_NOT_NVIDIA_DISCRETE_RE = ' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|APPLE) '

# The GPU check's functions, sections 4 and 4b, are install-wsl-gpu.ps1, beside
# this file.
. (Join-Path $PSScriptRoot 'install-wsl-gpu.ps1')

# Run a child process with a hard timeout, its arguments quoted for Win32.
# ConvertTo-Win32Arg quotes ONE argument so CommandLineToArgvW recovers it as a
# single token: one with no whitespace and no `"` goes as it is; otherwise it is
# wrapped in `"`, a `"` inside becomes `\"`, a run of N `\` before a `"` becomes
# 2N+1, a run of N `\` at the end becomes 2N, and any other `\` stays; the empty
# string becomes `""`. Callers pass raw arguments and never pre-quote.
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
      # instead of the character; Append([string]) is unambiguous.
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
  # OPT-IN on purpose. The merged .Output is what a caller quoting a failure wants:
  # stderr is where a program says why. But a caller that reads a VALUE from the
  # output cannot tolerate the merge: a warning the program writes to stderr lands in
  # the same string and the value no longer reads. The host GPU check's nvidia-smi
  # queries (section 4) are exactly that; the merge once made a FALSE REFUSAL after
  # the cluster was already up
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
  # process exits before or during the write -- a program refusing instantly, a
  # binary that rejects its args and returns, a stub in the suite -- the pipe is
  # already closed and .Write() raises "Broken pipe". That escaped this function as a
  # raw MethodInvocationException, which breaks the contract three lines below it:
  # every other arm RETURNS @{Code; Output}, and Start() and Kill() are both guarded
  # for exactly this reason. Only the stdin write was bare.
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
  # no return, ever. Measured: `/bin/cat` with a 200 KB payload and
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
    # its stderr away. The timeout arm below is the other failure path
    # and keeps its synthetic text for the same reason.
    $isolate = $StdoutOnly -and $proc.ExitCode -eq 0
    return [pscustomobject]@{ Code = $proc.ExitCode; Output = $(if ($isolate) { $outTask.Result } else { $outTask.Result + $errTask.Result }) }
  }
  # timed out -> kill the child so it can't keep running after we've moved on
  try { $proc.Kill() } catch {}
  return [pscustomobject]@{ Code = 124; Output = ($FileName + " " + $Arguments[0] + " timed out after " + $TimeoutSec + "s") }
}

# =============================================================================
#  5. The core: install-k8s.sh, run twice inside the distro.
#
#  The caller contract: the core builds its side to it. The design puts the account steps on the HOST
#  CLI, and `client create` is keyed on the cluster's kube-system UID, so:
#    0. the host CLI, installed for this user by its own installer;
#    1. the core's cluster run: checks, step b without the CLI, the cluster, and
#       its kubeconfig merged into the host's kubeconfig;
#    2. the account steps here, provision.sh's on the host CLI: `tracebloc login`;
#       `client create --plan`, which reads the client running in the cluster and
#       the account, so a client of another account is refused before anything is
#       minted and one of this account is reused by its name; then `client create
#       --credential-file` into a folder only this user can read;
#    3. the core's client run: the credential's bytes on its stdin, then Helm.
#  With TRACEBLOC_CLIENT_ID and TRACEBLOC_CLIENT_PASSWORD both set (provision.sh's
#  preset, for unattended installs), step 2 is skipped and that pair is the client
#  run's stdin. Nothing then needs the CLI, so a failed CLI install only warns.
#  The credential is never on wsl.exe's command line, which other processes can
#  read, and never in a line this script prints.
#
#  Invoke-WslInstall settles the preset pair before anything is written: a client ID
#  with no password gets it asked for at a console (Read-HostPresetPassword), and
#  half a pair or a value with a line break stops it before the import.
#  It runs Invoke-WslCore once the import and the logon task (sections 2 and 3) have
#  the distro running.
#  The cluster run hands the account steps what its stop-and-check gate found
#  (2c): this script names a file on that run's line, TRACEBLOC_WSL_HANDOVER, in a
#  folder only this user can open and deletes after the install, and reads it only
#  when the run exits 0. A file or line that is missing stops the install: the run
#  did not reach its end. On credential-rejected the account steps ask `client
#  create` for a new credential (--reissue, provision.sh's repair) and the client
#  run's line says so (TRACEBLOC_CREDENTIAL_REISSUED=1). A preset pair is never
#  reissued: provision.sh's preset path returns before its repair. It also hands
#  over tracebloc's kube context, which the account steps name to the host CLI: the
#  merge leaves the kubeconfig's current context alone, and the host record that
#  names it for the CLI is written only after the client run. And where this machine
#  runs, which the account steps put in `client create`'s environment, as
#  provision.sh does.
#    TODO(S-W): measure that /dev/tty answers in the distro while stdin is a pipe.
#    TODO(part 4): the refusal for another account's client names no removal
#      command yet: `tracebloc delete` removes the distro path's client once
#      cli-dev's `delete` knows the record's kinds.
# =============================================================================

# The distro the core runs in, the substrate named on its command line (a Pester
# test holds it to install.ps1's $WslSubstrate), and the core's two runs (a Pester
# case holds the two phases to lib/host.sh's TB_WSL_PHASES).
$WslDistroName = 'tracebloc'
$CoreSubstrate = 'k3s'
$CorePhaseCluster = 'cluster'
$CorePhaseClient = 'client'

# What the core reads from this process's environment, carried onto its line,
# because no Windows variable crosses into the distro:
#   - the release the bootstrap resolved (lib/host.sh's TB_VERSION reads it);
#   - the stage, by the name lib/settings.sh's tb_client_env reads, so the core
#     installs against the backend the host CLI signs in to (Get-HostClientCredential
#     hands the login the same name). Without it the core falls back to prod while
#     the CLI mints the credential on stg;
#   - every telemetry opt-out the core honours (lib/telemetry.sh's
#     TB_TELEMETRY_OPT_OUT_VARS), so an opt-out set on Windows still opts out.
# Pester tests hold the stage names and the opt-outs to those declarations. Each
# goes on the line only when it is set, with the value as it was set: the core
# reduces the stage's spelling itself.
$CorePassThroughVars = @('TRACEBLOC_INSTALL_REF', 'TRACEBLOC_ENV', 'TRACEBLOC_SKIP_TELEMETRY', 'TRACEBLOC_NO_TELEMETRY', 'DO_NOT_TRACK')

# THE INSTALL'S OWN SETTINGS. install-k8s.sh's header and the core's --help name
# the settings a user sets for the install, each by its TRACEBLOC_ name, which is
# the one lib/settings.sh reads. The core reads them in the distro, so the ones that
# mean the same there go on its line too, as set, and the core resolves them itself:
#   - the secure-environment name, the namespace and Helm release the client goes
#     in (without it the client lands in 'tracebloc' whatever was set);
#   - what each training run may use;
#   - a forced reinstall;
#   - the leftover-data guard's answer, and skipping that guard.
# Each other one is in $CoreSettingsReadOnHost or $CoreSettingsNotUsed. A Pester
# case holds every name the header, the --help and settings.sh's resolution lines
# name to one of the three.
$CoreSettingVars = @('TRACEBLOC_NAMESPACE', 'TRACEBLOC_TRAINING_RESOURCES', 'TRACEBLOC_FORCE_REINSTALL', 'TRACEBLOC_LEFTOVER_ACTION', 'TRACEBLOC_SKIP_LEFTOVER_GUARD')
$CorePassThroughVars += $CoreSettingVars

# The settings the bootstrap reads on Windows itself, and does not carry:
#   - TRACEBLOC_SUBSTRATE: k3s is what runs this distro path (install.ps1);
#   - TRACEBLOC_SKIP_EXAMPLE: the host CLI that signed in sets up the example use
#     case (Get-ExampleOptOut); the distro's runs never do.
#   - TRACEBLOC_EXAMPLE_TIMEOUT: that same host-side setup is the one it bounds
#     (Invoke-HostExample, through Get-ReinstallTimeout).
$CoreSettingsReadOnHost = @('TRACEBLOC_SUBSTRATE', 'TRACEBLOC_SKIP_EXAMPLE', 'TRACEBLOC_EXAMPLE_TIMEOUT')

# The settings the distro path does not use, and why: one that is set is said
# (Write-CoreSettingsNotUsed), never dropped without a word. Only the
# TRACEBLOC_ names: the legacy ones are generic (CLUSTER_NAME, SERVERS) and can be
# set for other tools.
$CoreSettingsNotUsed = [ordered]@{
  TRACEBLOC_CLUSTER_NAME      = 'the tracebloc WSL distro runs one cluster, tracebloc'
  TRACEBLOC_SERVERS           = 'the tracebloc WSL distro runs one node'
  TRACEBLOC_AGENTS            = 'the tracebloc WSL distro runs one node'
  TRACEBLOC_K3D_VERSION       = 'the tracebloc WSL distro does not use k3d'
  TRACEBLOC_K8S_VERSION       = "the tracebloc WSL distro's image carries its Kubernetes version"
  TRACEBLOC_HELM_VERSION      = 'the tracebloc WSL distro uses the Helm version the installer pins'
  TRACEBLOC_STORAGE_MODE      = 'the tracebloc WSL distro keeps datasets inside its node'
  TRACEBLOC_HOST_DATA_DIR     = "tracebloc keeps its data on the tracebloc WSL distro's own disk"
  TRACEBLOC_HOST_DATASET_DIR  = 'a separate dataset folder is not supported on Windows yet'
  TRACEBLOC_LAUNCH_PATH       = "the core captures the distro's own launch PATH"
  TRACEBLOC_SKIP_REBOOT_PROMPT = 'nothing installs a GPU driver in the tracebloc WSL distro, so there is no reboot to skip'
}

# THE HOST'S PROXY IN THE DISTRO ("Proxy and
# CA"; NAT, with the proxy on k3s's unit). Both runs get every name
# lib/cluster.sh's _node_proxy_env hands a cluster node, and the NO_PROXY pair its
# _augment_no_proxy reads. Pester holds both lists to cluster.sh. Nothing is
# written here, because the core already owns the write:
#   - the cluster run hands these to k3s's install.sh, which writes them into
#     k3s.service.env, native k3s's proxy home, on every run. A file written from
#     this side would be rewritten from the core's environment. S-W's run pulled
#     with the proxy in that file, on NAT;
#   - the NO_PROXY there is the core's: the host's, unioned with cluster.sh's
#     TB_NO_PROXY_DEFAULTS (loopback, the RFC1918 ranges, the cluster's DNS
#     suffixes). k3s.bats holds both pod and service range pairs inside it, and
#     cluster.bats holds loopback;
#   - the client run hands them to the chart's proxy settings.
# They cross by WSLENV, never on the line. A proxy's URL can hold a password, and
# the line is wsl.exe's command line, which other processes can read. WSLENV names
# the variables wsl.exe copies from its own environment into the Linux process it
# starts (/u: from Windows to Linux only), so the values are in no argument and in
# no printed line. A wsl session reads no /etc/environment, so this is the only way
# in. Each name the core reads is listed when Windows finds it set, and Windows
# finds a name in any case. WSLENV's names are case-sensitive (Microsoft's WSL
# docs), so a variable crosses at least under the name it was set by, and the core
# reads both cases (cluster.sh), as on a Linux host. The same reader as the
# bootstrap's own downloads, which honour HTTPS_PROXY: a proxy set only in
# Windows' Internet settings is not read here either.
$CoreProxyVars = @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')
$CoreNoProxyVars = @('NO_PROXY', 'no_proxy')
$CoreWslEnvVars = $CoreProxyVars + $CoreNoProxyVars

# The WSLENV a core run starts with: the user's own entries first, as set, then
# NAME/u for each of $CoreWslEnvVars that is set and not listed already (a name
# the user lists keeps the user's flag). Names only: never a value.
function Get-CoreWslEnv {
  param([AllowNull()][string]$Existing = $env:WSLENV)
  $entries = [System.Collections.Generic.List[string]]::new()
  $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($e in @("$Existing" -split ':' | Where-Object { $_ })) {
    $entries.Add($e)
    [void]$listed.Add(($e -split '/')[0])
  }
  foreach ($name in $CoreWslEnvVars) {
    if ($listed.Contains($name) -or -not [Environment]::GetEnvironmentVariable($name)) { continue }
    $entries.Add("$name/u")
    [void]$listed.Add($name)
  }
  return ($entries -join ':')
}

# Why VALUE, one proxy variable's value, is not a proxy the cluster can use, or
# $null when it is. The rule is Go's proxy reader, which containerd and k3s read
# these variables with: a URL with a scheme and a host, or else host[:port] with
# http:// assumed. The schemes Go's transport dials are http, https, socks5 and
# socks5h. A value with a space in it is never one.
$ProxySchemes = @('http', 'https', 'socks5', 'socks5h')
function Get-ProxyValueProblem {
  param([string]$Value)
  # Never trimmed: the line carries the value as set, and Go reads a padded one as
  # no proxy address.
  $v = $Value
  if ($v -match '\s') { return 'it has a space in it' }
  $text = $v
  if ($v -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $text = "http://$v" }
  $uri = $null
  if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) { return 'it is neither a URL nor a host[:port]' }
  if (-not $uri.Host) { return 'it names no host' }
  if ($ProxySchemes -notcontains $uri.Scheme) { return "its scheme, $($uri.Scheme), is not $(($ProxySchemes[0..($ProxySchemes.Count - 2)]) -join ', ') or $($ProxySchemes[-1])" }
  return $null
}

# Refuses, by the variable's name, a host proxy the cluster could not use, before
# anything is written: k3s and containerd would otherwise fail their first pull
# late, naming nothing of ours. The value is never repeated, since a proxy's URL
# can hold a password. No proxy set, or a NO_PROXY alone, is nothing to check.
function Assert-HostProxy {
  foreach ($name in $CoreProxyVars) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value) { continue }
    $problem = Get-ProxyValueProblem -Value $value
    if ($problem) {
      throw "$name is set, but the tracebloc cluster cannot use it as a proxy: $problem. Set $name to your proxy's address, like http://proxy.example.com:3128, or remove it, then run the install again."
    }
  }
}

# The tracebloc CLI's own Windows installer.
$TRACEBLOC_CLI_INSTALL_URL = "https://github.com/tracebloc/cli/releases/latest/download/install.ps1"

# The cluster run's handover (2c): the variable that names the file, the file's
# name in its folder, the five lines the core writes (lib/host.sh's
# tb_wsl_handover_write), the reason that asks for a new credential, and the flag
# the client run gets then (provision.sh's). The second line is tracebloc's kube
# context, which k3s.sh's kubeconfig merge added. The last three are where this
# machine runs (provision.sh's _registration_machine_facts), by the names
# provision.sh puts in its own `client create`'s environment, which the host's create
# gets the same way. Pester holds each to the core's.
$CoreHandoverVar = 'TRACEBLOC_WSL_HANDOVER'
$CoreHandoverFile = 'handover.env'
$CoreHandoverKey = 'INSTALL_STATE_REASON'
$CoreHandoverContextKey = 'TRACEBLOC_KUBE_CONTEXT'
$CoreHandoverFactKeys = @('TRACEBLOC_MACHINE_KIND', 'TRACEBLOC_CLOUD_PROVIDER', 'TRACEBLOC_HOST_OS')
$CredentialRejectedReason = 'credential-rejected'
# The client run's handover: its file, in the same folder, and the one line the core
# writes (lib/host.sh's tb_wsl_client_state_write). Invoke-HostExample runs only on
# the connected state. Pester holds each to the core's.
$CoreClientHandoverFile = 'client.env'
$CoreClientStateKey = 'TRACEBLOC_CLIENT_STATE'
$ClientConnectedState = 'connected'
# The machine name and provider `client create` sets, by the names provision.sh puts
# in its own create's environment. Pester holds them to provision.sh's.
$MachineLabelKeys = @('TRACEBLOC_MACHINE_NAME', 'TRACEBLOC_CLIENT_PROVIDER')
$CredentialReissuedVar = 'TRACEBLOC_CREDENTIAL_REISSUED'

# One Windows command-line argument, quoted so that CommandLineToArgvW, and the
# .NET runtime on any OS, reads back exactly VALUE. wsl.exe --exec hands the
# words it reads to the command as they are, with no shell between.
function ConvertTo-WindowsArgument {
  param([string]$Value)
  if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($c in $Value.ToCharArray()) {
    if ($c -eq [char]92) { $slashes++; continue }
    if ($c -eq [char]34) {
      [void]$sb.Append([char]92, 2 * $slashes + 1)
      [void]$sb.Append([char]34)
    } else {
      if ($slashes) { [void]$sb.Append([char]92, $slashes) }
      [void]$sb.Append($c)
    }
    $slashes = 0
  }
  if ($slashes) { [void]$sb.Append([char]92, 2 * $slashes) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# The host kubeconfig the core merges into: the first file of KUBECONFIG, else
# %USERPROFILE%\.kube\config. That is the core's own rule on Linux
# (_native_k3s_kubeconfig_target), applied on the host. Its folder is created.
function Get-HostKubeconfigTarget {
  $first = $null
  if ($env:KUBECONFIG) { $first = @($env:KUBECONFIG -split ';' | Where-Object { $_.Trim() })[0] }
  if (-not $first) { $first = Join-Path (Join-Path $env:USERPROFILE '.kube') 'config' }
  $dir = Split-Path -Parent $first
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $first
}

# PATH as the distro sees it (wslpath -u, run inside the distro), or a refusal by
# name: the core reads every host path through this, never a path computed here.
# The first call starts the distro, so each gets the start's budget.
function ConvertTo-DistroPath {
  param([string]$Path)
  $r = Invoke-WslProbe -ArgumentList @('-d', $WslDistroName, '-u', 'root', '--exec', 'wslpath', '-u', (ConvertTo-WindowsArgument $Path)) -TimeoutSec $WslDistroStartTimeoutSec
  if ($r.TimedOut) {
    # The log only: which state the distro was in tells a stopped, missing or stuck one apart.
    $l = Invoke-WslProbe -ArgumentList @('-l', '-v')
    Log "wsl -l -v after the wslpath timeout (exit $($l.ExitCode), timed out $($l.TimedOut)): $($l.Output -replace "`0", '')"
    throw "The tracebloc WSL distro did not start within $WslDistroStartTimeoutSec seconds, so the core cannot be started. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  $out = ''
  if ($r.Output) { $out = @($r.Output -split "`r?`n" | Where-Object { $_ })[0] }
  if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $out -notmatch '^/') {
    throw "The tracebloc WSL distro could not translate $Path into its own path, so the core cannot be started. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  return $out.Trim()
}

# wsl.exe's words for one run of the core. Every path is the distro's own. The
# host GPU check's verdict and its three platform values go on every run's line
# (section 4), empty when this host judged no NVIDIA GPU. -Handover names the
# run's handover file. -CredentialStdin tells the core to read the
# credential from its stdin first, and -CredentialReissued that the account steps
# asked for a new one.
function New-CoreRunArguments {
  param(
    [string]$Phase,
    [string]$Core,
    [string]$Kubeconfig,
    [string]$LogDir,
    [string]$Handover,
    [switch]$CredentialStdin,
    [switch]$CredentialReissued
  )
  $a = @('-d', $WslDistroName, '-u', 'root', '--exec', 'env',
    "TRACEBLOC_SUBSTRATE=$CoreSubstrate",
    "TRACEBLOC_WSL_PHASE=$Phase",
    'TRACEBLOC_BANNER_SHOWN=1',
    "TRACEBLOC_INSTALL_CMD=$InstallCommand",
    "KUBECONFIG=$Kubeconfig",
    "TRACEBLOC_LOG_DIR=$LogDir",
    "TRACEBLOC_WSL_GPU_VERDICT=$script:GPU_FLOOR_VERDICT",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE=$script:GPU_UNSUPPORTED_CODE",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME=$script:GPU_UNSUPPORTED_NAME",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_REASON=$script:GPU_UNSUPPORTED_REASON")
  foreach ($name in $CorePassThroughVars) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $a += "$name=$value" }
  }
  if ($Handover) { $a += "$CoreHandoverVar=$Handover" }
  if ($CredentialStdin) { $a += 'TRACEBLOC_CREDENTIAL_STDIN=1' }
  if ($CredentialReissued) { $a += "$CredentialReissuedVar=1" }
  $a += @('bash', "$Core/install-k8s.sh")
  return $a
}

# Says each setting in $CoreSettingsNotUsed that is set, and why the distro path
# does not use it. Once, before the core's first run.
function Write-CoreSettingsNotUsed {
  foreach ($name in $CoreSettingsNotUsed.Keys) {
    if ([Environment]::GetEnvironmentVariable($name)) {
      Warn "$name is set, but the install in the tracebloc WSL distro does not use it: $($CoreSettingsNotUsed[$name])."
    }
  }
}

# The console's input encoding, read and set: seams for Invoke-CoreRun, since the
# test suite's .NET Core console never has a preamble to take out.
function Get-ConsoleInputEncoding { return [Console]::InputEncoding }
function Set-ConsoleInputEncoding {
  param([System.Text.Encoding]$Encoding)
  [Console]::InputEncoding = $Encoding
}

# Runs the core once: FILEPATH (wsl.exe; a seam for the test suite) with
# ARGUMENTLIST, each word quoted for the command line. The console stays the
# core's: its output is not redirected, and stdin is redirected only to hand in
# STDIN, which is written and then closed. Returns the core's exit code.
function Invoke-CoreRun {
  param(
    [string[]]$ArgumentList,
    [byte[]]$Stdin,
    [string]$FilePath = 'wsl.exe'
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
  $psi.UseShellExecute = $false
  # The host's proxy crosses by WSLENV, in the child's environment only (section 5).
  $wslenv = Get-CoreWslEnv
  if ($wslenv) { $psi.EnvironmentVariables['WSLENV'] = $wslenv }
  $psi.RedirectStandardInput = ($null -ne $Stdin)
  # .NET Framework's Process.Start (Windows PowerShell 5.1) wraps a redirected stdin
  # in a writer on the console's input encoding and flushes it at once, which puts
  # that encoding's preamble in the pipe before a byte of STDIN: on a console set to
  # UTF-8 (code page 65001, the only console code page with one), a BOM in front of
  # the credential. 5.1's ProcessStartInfo has no StandardInputEncoding, so for the
  # start only, the console's input encoding is UTF-8 without a BOM. .NET Core drops
  # the preamble itself.
  $restore = $null
  if ($null -ne $Stdin) {
    $enc = Get-ConsoleInputEncoding
    if ($enc.GetPreamble().Length -gt 0) {
      try {
        Set-ConsoleInputEncoding -Encoding (New-Object System.Text.UTF8Encoding $false)
      } catch {
        throw "The credential could not be handed to the tracebloc WSL distro without a byte-order mark in front of it: this console's input encoding could not be changed ($($_.Exception.Message)). Run this installer again in a new PowerShell window."
      }
      $restore = $enc
    }
  }
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  } finally {
    if ($null -ne $restore) { Set-ConsoleInputEncoding -Encoding $restore }
  }
  try {
    if ($null -ne $Stdin) {
      # A child that exits before it has read its stdin (a refusal, a crash) has
      # closed the pipe, so the write fails as a broken pipe. Its exit code is
      # what says why, so that failure is not thrown here; the stream is closed
      # whatever happened.
      try {
        $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length)
        $p.StandardInput.BaseStream.Flush()
      } catch [System.IO.IOException] {
        $null = $_
      } finally {
        try { $p.StandardInput.Close() } catch [System.IO.IOException] { $null = $_ }
      }
    }
    $p.WaitForExit()
    return $p.ExitCode
  } finally {
    $p.Dispose()
  }
}

# The host CLI and the account steps, section 5's middle, are
# install-wsl-account.ps1, beside this file.
. (Join-Path $PSScriptRoot 'install-wsl-account.ps1')

# The CLI installed, then the core run twice in the distro with the account steps
# between, or the operator's preset pair in their place. CORE is the verified
# -CoreDir. Returns the exit code of the run that ended it: the cluster run's when
# it failed, else the client run's. The credential's bytes are wiped whatever
# happened.
function Invoke-WslCore {
  param([string]$CoreDir)
  $credential = Get-HostPresetCredential
  try {
    $cli = Install-HostCli -Optional:($null -ne $credential)
    Clear-RetiredToolPath
    # Install-HostCli keeps an older CLI when its update fails: one below the
    # floor stops here, before the distro is touched.
    if ($cli) { Assert-HostCliFloor -Cli $cli -CoreDir $CoreDir }
    $core = ConvertTo-DistroPath -Path $CoreDir
    $kubeconfig = ConvertTo-DistroPath -Path (Get-HostKubeconfigTarget)
    $logHost = Get-HostLogDir
    if (-not (Test-Path -LiteralPath $logHost)) { New-Item -ItemType Directory -Path $logHost -Force | Out-Null }
    $logDir = ConvertTo-DistroPath -Path $logHost
    # The host GPU check (section 4), before the first run: both runs carry its answer,
    # with WSL's own rules for the GPU it can give the distro (section 4b).
    Find-Gpu
    Confirm-NvidiaWslGpu
    Write-CoreSettingsNotUsed

    # The cluster run's handover, in a folder only this user can open, deleted after
    # the install whatever happened.
    $handDir = Join-Path (Join-Path $env:LOCALAPPDATA 'tracebloc') ('handover-' + [guid]::NewGuid().ToString('N'))
    New-PrivateDirectory -Path $handDir
    try {
      $handover = (ConvertTo-DistroPath -Path $handDir) + '/' + $CoreHandoverFile
      Log "Setting up the cluster in the tracebloc WSL distro..."
      Write-SectionEnd
      $rc = Invoke-CoreRun -ArgumentList (New-CoreRunArguments -Phase $CorePhaseCluster -Core $core -Kubeconfig $kubeconfig -LogDir $logDir -Handover $handover)
      if ($rc -ne 0) { return $rc }
      $handed = Read-CoreHandover -Path (Join-Path $handDir $CoreHandoverFile)
      Write-SectionEnd

      if ($null -ne $credential) {
        # As provision.sh's preset path, which returns before its credential-rejected
        # repair: a supplied pair is never reissued.
        $reissue = $false
        Info "Using the Client ID you set, skipping browser sign-in."
      } else {
        $reissue = $handed.Reason -ceq $CredentialRejectedReason
        Log "Registering this machine with tracebloc..."
        Write-Host '  Sign in to connect this machine to tracebloc.'
        Write-Host ""
        $credential = Get-HostClientCredential -Cli $cli -Reissue:$reissue -Facts $handed.Facts -KubeContext $handed.KubeContext
        # Signed in to the account that owns this client: see Invoke-HostExample.
        $script:HostSignedInCli = $cli
        $script:HostKubeContext = $handed.KubeContext
      }
      Log "Installing tracebloc in the tracebloc WSL distro..."
      Write-SectionEnd
      $clientHandover = (ConvertTo-DistroPath -Path $handDir) + '/' + $CoreClientHandoverFile
      $rc = Invoke-CoreRun -ArgumentList (New-CoreRunArguments -Phase $CorePhaseClient -Core $core -Kubeconfig $kubeconfig -LogDir $logDir -Handover $clientHandover -CredentialStdin -CredentialReissued:$reissue) -Stdin $credential
      # The client run exits 0 still starting too: see Invoke-HostExample.
      $script:HostClientState = Read-CoreClientState -Path (Join-Path $handDir $CoreClientHandoverFile)
      return $rc
    } finally {
      Remove-Item -LiteralPath $handDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  } finally {
    if ($null -ne $credential) { [Array]::Clear($credential, 0, $credential.Length) }
  }
}

# The variable that switches the account's example use case off, or $null:
# TRACEBLOC_SKIP_EXAMPLE, then TRACEBLOC_NO_EXAMPLE, set to anything but '', '0' or
# 'false' once trimmed, in any case. The CLI's rule, as lib/install-cli.sh's _example_opt_out.
function Get-ExampleOptOut {
  $vars = [ordered]@{ TRACEBLOC_SKIP_EXAMPLE = $env:TRACEBLOC_SKIP_EXAMPLE; TRACEBLOC_NO_EXAMPLE = $env:TRACEBLOC_NO_EXAMPLE }
  foreach ($name in $vars.Keys) {
    if ("$($vars[$name])".Trim().ToLowerInvariant() -notin @('', '0', 'false')) { return $name }
  }
  return $null
}

# After a connected install, `tracebloc data ingest --example` on CLI, the host CLI this
# run signed in ($null: none did, and nothing runs), on tracebloc's KUBECONTEXT
# (Get-HostKubeContextArgs). ClientState is what the client run handed over; anything
# but connected runs nothing. Never throws. The bash twin is lib/install-cli.sh's
# setup_example_use_case, which the distro's runs skip.
function Invoke-HostExample {
  param([string]$Cli, [string]$ClientState, [string]$KubeContext)
  if (-not $Cli) {
    Log 'Example use case: not set up, as this run did not sign the tracebloc CLI in.'
    return
  }
  if ($ClientState -cne $ClientConnectedState) {
    Log "Example use case: not set up, as the client is not connected yet (state '$ClientState')."
    return
  }
  $why = Get-ExampleOptOut
  if ($why) {
    Info "Skipping the example use case: $why is set."
    return
  }
  $rc = $null
  $err = ''
  $deadline = 0
  try {
    # A CLI without --example refuses the flag even beside --help, and help changes nothing.
    $probe = Invoke-HostCliProbe -Cli $Cli -ArgumentList @('data', 'ingest', '--example', '--help')
    if ($probe.ExitCode -ne 0) {
      $late = ''
      if ($probe.TimedOut) { $late = ", no answer within $($probe.TimeoutSec) s" }
      Log "Example use case: not set up, as 'tracebloc data ingest --example --help' exited $(Format-ExitCode $probe.ExitCode)$late."
      return
    }
    Write-SectionEnd
    Write-Section 'Setting up your example use case'
    Write-Host "  We'll ingest synthetic data and start a model"
    Write-Host '  training so you can explore tracebloc.'
    Write-Host ""
    # With nobody at this console no Ctrl-C can come, so a run that does not end is
    # stopped: lib/install-cli.sh's setup_example_use_case.
    if (-not (Test-BootstrapCanPrompt)) { $deadline = Get-ReinstallTimeoutSeconds -Name 'TRACEBLOC_EXAMPLE_TIMEOUT' }
    $rc = Invoke-HostCliNoInput -Cli $Cli -ArgumentList (@('data', 'ingest', '--example') + (Get-HostKubeContextArgs $KubeContext)) -TimeoutSec $deadline
  } catch {
    $err = $_.Exception.Message
  }
  if ($rc -eq 0) {
    Write-Host ""
    Write-Host '  Your training results will appear on your'
    Write-Host '  use case in the dashboard.'
    return
  }
  if ($rc -eq 130) {
    Info 'Stopped setting up the example use case.'
    return
  }
  if ($rc -eq 124 -and $deadline -gt 0) {
    Warn "Stopped setting up the example use case after $(Get-ReinstallTimeout -Name 'TRACEBLOC_EXAMPLE_TIMEOUT') with no terminal attached - your secure environment is set up fine."
    return
  }
  Warn "Couldn't set up the example use case - your secure environment is set up fine."
  # This script keeps no log, so the reason is shown.
  if ($err) {
    Hint "The tracebloc CLI could not be run: $err"
  } else {
    Hint "tracebloc data ingest --example exited $(Format-ExitCode $rc)."
  }
}

# Sections 6 and 7, the install record and the deadlines, are
# install-wsl-record.ps1, beside this file.
. (Join-Path $PSScriptRoot 'install-wsl-record.ps1')

# =============================================================================
#  The distro path, end to end. Returns the exit code.
# =============================================================================

# LocalSystem's SID. WSL refuses that account for anything that touches a distro
# ("Running WSL as local system is not supported", WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED:
# S-W row 2 on Windows Server 2025, WSL 3.0.3), and the distro, its logon task and
# its credential are the signed-in user's, so a deployment tool's SYSTEM run could
# set up nothing that user could use. The check reads the account, not WSL:
# `wsl --version` still answers as SYSTEM, so WSL would read as ready. A
# Windows-only Pester case holds it to .NET's own WellKnownSidType.LocalSystemSid.
$LocalSystemSid = 'S-1-5-18'

# The SID of the account running this bootstrap, or $null where Windows cannot
# say (off Windows, the test suite).
function Get-BootstrapUserSid {
  try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $null }
}

# What a stop past the import leaves on this machine, and how it goes: a re-run
# reuses it, and once the core has written its own record, the host record names it
# for tracebloc delete. Before that, the stop prints the removal by hand, as the
# user can run it unelevated, naming only what this run created: the distro
# Import-WslDistro imports and, once Register-ScheduledTask has registered it, the
# task Register-KeepaliveTask sets up at the Task Scheduler root, even when its
# start or the distro's first start then fails. Pester cases hold both commands to
# what those producers did.
function Write-WslInstallLeft {
  param([switch]$Task, [switch]$Recorded)
  $what = "the tracebloc WSL distro (in $(Get-WslImportDir))"
  $how = "wsl --unregister $WslDistroName"
  if ($Task) {
    $what += " and its logon task $KeepaliveTaskId"
    $how += ", then Unregister-ScheduledTask -TaskName $KeepaliveTaskName -Confirm:`$false"
  }
  if ($Recorded) { $how = 'tracebloc delete' }
  Log "Left on this machine: $what. Run this installer again to finish (it reuses them), or remove them with: $how"
}

function Invoke-WslInstall {
  param([string]$CoreDir)
  Write-Section 'Preparing Windows'
  if ((Get-BootstrapUserSid) -eq $LocalSystemSid) {
    Stop-Setup -What "WSL doesn't run as the Windows SYSTEM account" -Next 'Run the installer as the person who signs in to this machine:' -Reason "This installer is running as the Windows SYSTEM account, which WSL does not support. tracebloc runs in the signed-in user's own WSL distro, so run the install command as that user. A deployment tool (Intune, Configuration Manager) has to run it in the user's context, not as SYSTEM."
  }
  Confirm-CoreDir -CoreDir $CoreDir
  # A client ID with no password: its password is asked for at this console, and the
  # pair checked, before anything is written (section 5).
  Read-HostPresetPassword -CoreDir $CoreDir
  # The operator's preset pair (section 5): half a pair, or a value with a line
  # break, is refused before anything is written.
  Assert-HostPresetCredential
  # The host's proxy, which both core runs carry (section 5): a value the cluster
  # could not use is refused before anything is written.
  Assert-HostProxy
  # NAT only: a user's mirrored .wslconfig is refused before anything is written.
  Assert-WslNetworkingNat
  # Never the distro beside a retired Windows install (section 6): refused by
  # name, from the files it left, before WSL is touched.
  Assert-NoRetiredInstall
  # A restart stops with 2, the declared "restart, then re-run" code, which
  # install.ps1 passes through and the e2e harness reads.
  if ((Confirm-WslReady) -eq 'restart') {
    return 2
  }
  # The distro (section 2): imported, with its disk set before anything starts it,
  # or the one already here on a re-run.
  $null = Import-WslDistro
  # From here the distro is on this machine, so a stop says what it left.
  $step = 'task'
  # Register-KeepaliveTask sets this once the task is registered, before it starts
  # it and waits, so a refusal there still names the task it left.
  $script:KeepaliveRegistered = $false
  # Invoke-WslCore sets these once its account steps signed the host CLI in, and
  # once the client run handed over the client's state.
  $script:HostSignedInCli = $null
  $script:HostKubeContext = ''
  $script:HostClientState = $null
  try {
    # Its first start, and every sign-in's (section 3).
    Register-KeepaliveTask
    $step = 'core'
    # The host's CA roots, before the core's first download (S-W row 9).
    Add-WslHostRootTrust
    # The core, run twice, with the account steps between (section 5).
    $rc = Invoke-WslCore -CoreDir $CoreDir
  } catch {
    $recorded = $false
    if ($step -eq 'core') { $recorded = Save-HostInstallRecord -Kubeconfig (Get-HostKubeconfigTarget) -IfAny }
    Write-WslInstallLeft -Task:($step -eq 'core' -or $script:KeepaliveRegistered) -Recorded:$recorded
    throw
  }
  # The record (section 6), whether the core finished or not: it is what
  # tracebloc delete removes.
  $recorded = Save-HostInstallRecord -Kubeconfig (Get-HostKubeconfigTarget) -IfAny:($rc -ne 0)
  if ($rc -ne 0) {
    Write-WslInstallLeft -Task -Recorded:$recorded
    # The core has said why. 1, never its own code: 2 is the restart code.
    return 1
  }
  # The user's own WSL memory cap, measured with the platform running. Advice only: it
  # never turns a finished install into a failure.
  try { Write-WslMemoryCapWarning } catch { Log "Memory: could not check WSL's memory cap ($($_.Exception.Message))." }
  # The client run exits 0 connected or still starting. Last, after the record: a
  # Ctrl-C stops this script, as anywhere in it, and then costs only the example.
  Invoke-HostExample -Cli $script:HostSignedInCli -ClientState $script:HostClientState -KubeContext $script:HostKubeContext
  return 0
}

# =============================================================================
#  Main. $env:TRACEBLOC_PESTER lets the test suite dot-source this file to load the
#  functions without running them. A child process: `exit` here closes no window.
# =============================================================================
# One run of this script, its exit code included: the main block's body, a function
# so the copy catalog's Windows scenarios run it as a person does.
function Invoke-WslMain {
  param([string]$CoreDir)
  try {
    return (Invoke-WslInstall -CoreDir $CoreDir)
  } catch {
    Write-SetupStopped $_
    return 1
  }
}

if (-not $env:TRACEBLOC_PESTER) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  exit (Invoke-WslMain -CoreDir $CoreDir)
}
