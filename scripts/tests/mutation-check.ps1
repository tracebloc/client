<#
  mutation-check.ps1 — every installer guard must still catch the bug it was
  written for.

  1019 green assertions prove nothing on their own. Most of this repo's
  installer guards read a property off the SOURCE TEXT, and such a guard passes
  forever once the string it searches for drifts — "green" and "no longer
  looking" are the same colour. The org standard's rule is the answer: break the
  thing, watch the test redden, restore. This automates the watching.

  WHY IT EXISTS HERE, and it is not a general urge to add tooling. backend#2675
  and #2849 were each "already fixed":

    * #577 shipped a graceful-exit boundary and PR #588 touched install.ps1 —
      but only its message. Every `exit` was untouched, so the bootstrap still
      closed the user's console, and no test could see it: main sits behind
      `if (-not $env:TB_PESTER)` and every suite sets TB_PESTER=1, so NO test in
      this repo has ever executed a single `exit`.
    * install-k8s.ps1's own comment promised `WaitForExit()` "guarantees
      ExitCode is populated for every caller". It did not, and the guard that
      would have said so did not exist.

  Both were found by a human running the installer, not by CI. A guard nobody
  has ever seen fail is a guess.

  FOUR THINGS THIS REFUSES TO DO, each because it has gone wrong somewhere:

    * It never mutates the working tree. The repo is copied to a temp dir and
      the COPY is mutated — nothing to restore, nothing for a SIGKILL to strand,
      nothing a stray `git add` can stage.
    * It never trusts a marker that matches more than once. A refactor that
      duplicates a line becomes a loud STALE rather than a mutation quietly
      aimed at the wrong copy.
    * It never reports a catch without a green baseline. If the unmutated suite
      already fails, every mutation "reddens" by inheriting that failure and the
      whole run is decoration.
    * It never lets a mutation be a no-op. `Find` must be present and `Replace`
      must differ, checked before the suite runs.

  Usage:
    pwsh -File scripts/tests/mutation-check.ps1 -Dry   # markers only, seconds
    pwsh -File scripts/tests/mutation-check.ps1        # the real thing
#>
[CmdletBinding()]
param([switch]$Dry)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

# ── the registry ─────────────────────────────────────────────────────────────
# One entry per FIXED defect. `Find` must match exactly one line in `File`.
# `Suite` is the Pester file that claims to cover it.
$Mutations = @(
  @{ Name  = 'the reboot prompt asks even with nobody at the console (backend#2675)'
     Expect = 'Read-RebootChoice'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     After = 'function Read-RebootChoice {'; Within = 3
     Find  = '  if (-not (Test-CanPrompt)) { return "" }'
     Repl  = '  if ($false) { return "" }' }

  @{ Name  = 'TRACEBLOC_SKIP_REBOOT_PROMPT stops meaning -NoReboot (backend#2675)'
     Expect = 'TRACEBLOC_SKIP_REBOOT_PROMPT is the env twin'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = 'if ($env:TRACEBLOC_SKIP_REBOOT_PROMPT) { $NoReboot = $true }'
     Repl  = 'if ($env:TRACEBLOC_SKIP_REBOOT_PROMPT_UNUSED) { $NoReboot = $true }' }

  @{ Name  = 'the unattended credential refusal names neither variable (backend#2675)'
     Expect = 'refuses instead of spinning'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '      if (-not (Test-CanPrompt)) { Err (Get-UnattendedCredentialRefusal) }'
     Repl  = '      if ($false) { Err (Get-UnattendedCredentialRefusal) }' }

  @{ Name  = 'the exit-code slot can render empty again (backend#2849)'
     Expect = 'Format-ExitCode'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '  if ($null -eq $Code -or "$Code".Trim() -eq '''') { return ''with no code reported'' }'
     Repl  = '  if ($false) { return ''with no code reported'' }' }

  @{ Name  = 'the process handle is no longer cached, so ExitCode reads null (backend#2849)'
     Expect = 'Wait-ProcessWithDeadline exit-code reliability'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '  try { $null = $Process.Handle } catch {}'
     Repl  = '  try { $null = $Process.Id } catch {}' }

  @{ Name  = 'the Docker engine probe goes back to a bare, unbounded docker info (backend#2849)'
     Expect = 'is bounded'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '  $r = Invoke-DockerCli -DockerArgs @("info", "--format", "{{.ID}}") -TimeoutSec 15 -StdoutOnly'
     Repl  = '  $r = [pscustomobject]@{ Code = 0; Output = (docker info --format ''{{.ID}}'' 2>$null) }' }

  @{ Name  = 'the engine wait counts iterations again instead of wall-clock (backend#2849)'
     Expect = 'is bounded'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '    while ((Get-Date) -lt $dockerDeadline) {'
     Repl  = '    while ($f -lt 200) {' }

  @{ Name  = 'the CLI installer child is waited on with no deadline (backend#2849)'
     Expect = 'is bounded'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     # RE-AIMED after develop inverted this branch: Bugbot found that the
     # timeout overload does not drain the redirected streams, so the shape is
     # now `if (WaitForExit(ms)) { flush } else { kill }`. Same property, new line.
     Find  = '    if ($p.WaitForExit($cliWaitMs)) {'
     Repl  = '    if ($p.WaitForExit()) {' }

  # THE CLI WAIT'S OWN HANDLE + FLUSH (Bugbot on #931). The registry tracked the
  # handle-cache/empty-ExitCode class only on Wait-ProcessWithDeadline, and the
  # CLI wait only as a missing deadline -- so Install-TraceblocCli's two lines
  # were source-text assertions with nothing behind them. That is the exact hole
  # the class keeps recurring in: Bugbot found the missing flush on #917, INSIDE
  # the fix for the same class.
  @{ Name  = 'the CLI wait stops flushing its streams, so a success reads null (backend#2849)'
     Expect = 'Install-TraceblocCli'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     After = '    if ($p.WaitForExit($cliWaitMs)) {'
     Find  = '      try { $p.WaitForExit() } catch {}'
     Repl  = '      try { $null = $p.Id } catch {}' }

  @{ Name  = 'the CLI child''s handle is no longer cached before the wait (backend#2849)'
     Expect = 'Install-TraceblocCli'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     After = '  Info "Installing the tracebloc CLI..."'
     Find  = '    $null = $p.Handle'
     Repl  = '    $null = $p.StartTime' }

  @{ Name  = 'a dashboard link is hardcoded to production again (backend#2849)'
     Expect = 'dashboard link follows CLIENT_ENV'
     File  = 'scripts/install-k8s.ps1'; Suite = 'scripts/tests/install-k8s.Tests.ps1'
     Find  = '          Hint "Find your credentials at $(Get-TraceblocDashboardUrl)"'
     Repl  = '          Hint "Find your credentials at https://ai.tracebloc.io/clients"' }

  @{ Name  = 'the bootstrap closes the user''s console again (#577 / client#917)'
     Expect = 'must not close the user''s window'
     File  = 'scripts/install.ps1'; Suite = 'scripts/tests/install.Tests.ps1'
     Find  = '    Complete-Bootstrap -Code $LASTEXITCODE'
     Repl  = '    exit $LASTEXITCODE' }

  @{ Name  = 'the ref guard refuses every real branch again (client#917)'
     Expect = 'A branch ref may contain'
     File  = 'scripts/install.ps1'; Suite = 'scripts/tests/install.Tests.ps1'
     Find  = '    if (-not ($usingBranch -and $AllowUnverified)) {'
     Repl  = '    if ($true) {' }
)

# BYTE-IDENTICAL LINES CANNOT BE AIMED AT INDIVIDUALLY, so a mutation may name an
# `After` anchor: a unique line it must follow. `Test-CanPrompt` guards are the
# real case -- Read-RebootChoice and Read-ClientName carry the SAME guard line,
# and without an anchor a mutation would silently hit whichever came first while
# the registry looked complete.
function Get-MarkerIndex {
    param([string[]]$Lines, [string]$Find, [string]$After, [int]$Within = 20)
    $from = 0
    $to   = $Lines.Count - 1
    if ($After) {
        $anchors = @(0..($Lines.Count - 1) | Where-Object { $Lines[$_] -eq $After })
        if ($anchors.Count -ne 1) { return @{ Error = "anchor '$After' matches $($anchors.Count) lines, need exactly 1" } }
        $from = $anchors[0]
        # AN ANCHOR IS A SCOPE, NOT A LOWER BOUND (@saadqbal on #931). The search
        # used to run from the anchor to EOF, so `After 'function Read-RebootChoice {'`
        # still saw Read-ClientName's byte-identical guard 3900 lines later. A
        # window makes the anchor mean "this construct" rather than "somewhere
        # below here", and uniqueness is then enforced INSIDE it.
        $to = [Math]::Min($Lines.Count - 1, $from + $Within)
    }
    $hits = @($from..$to | Where-Object { $Lines[$_] -eq $Find })
    if ($hits.Count -eq 0) { return @{ Error = "no line matches -- the code moved and this mutation now proves nothing" } }
    # UNIQUENESS HOLDS WITH AN ANCHOR TOO (@saadqbal on #931). This read
    # `-not $After -and $hits.Count -gt 1`, so an anchored marker with two
    # matches silently took the first -- the exact thing the header says this
    # refuses to do, and 3 of 13 entries use anchors. An anchor NARROWS the
    # search; it does not license ambiguity inside the narrowed range.
    if ($hits.Count -gt 1) {
        $why = if ($After) { "$($hits.Count) lines match within $Within lines of the anchor -- narrow `Within` or pick a closer anchor" }
               else         { "$($hits.Count) lines match -- add an ``After`` anchor to narrow the search" }
        return @{ Error = $why }
    }
    return @{ Index = $hits[0] }
}

function Resolve-Marker {
    param([string]$Path, [string]$Find, [string]$After, [int]$Within = 20)
    $lines = [System.IO.File]::ReadAllLines($Path)
    $r = Get-MarkerIndex -Lines $lines -Find $Find -After $After -Within $Within
    if ($r.ContainsKey('Error')) { return "STALE: $($r.Error)" }
    return $null
}

$stale = @()
foreach ($m in $Mutations) {
    $full = Join-Path $RepoRoot $m.File
    if (-not (Test-Path $full)) { $stale += "$($m.Name): missing file $($m.File)"; continue }
    if ($m.Find -eq $m.Repl)    { $stale += "$($m.Name): mutation is a no-op"; continue }
    # NO ENTRY WITHOUT AN EXPECTATION. An entry with no `Expect` could only ever
    # be scored on a bare failure count, which is the defect this replaced.
    if (-not $m.ContainsKey('Expect') -or -not $m.Expect) { $stale += "$($m.Name): no Expect -- name the guard that must fail"; continue }
    $problem = Resolve-Marker -Path $full -Find $m.Find -After ($(if ($m.ContainsKey('After')) { $m.After } else { '' })) `
                              -Within ($(if ($m.ContainsKey('Within')) { $m.Within } else { 20 }))
    if ($problem) { $stale += "$($m.Name): $problem" }
}
if ($stale.Count -gt 0) {
    Write-Host "Refusing to run -- fix the markers first:" -ForegroundColor Red
    $stale | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host ("markers resolving: {0}/{0}" -f $Mutations.Count) -ForegroundColor Green
if ($Dry) { Write-Host "--dry: markers only. This is NOT evidence that anything still reddens." -ForegroundColor Yellow; exit 0 }

# ── baseline: the unmutated suites must be green ─────────────────────────────
# A FRESH PROCESS PER RUN, and this is not caution for its own sake. The first
# version ran every suite inside this one pwsh session and reported TWO baseline
# failures that do not reproduce when the same file is run on its own -- Pester
# state (dot-sourced script scope, mocks, $script: variables) survives between
# Invoke-Pester calls in a single process, so run N is not run 1. A harness whose
# own verdicts depend on how many times it has already run cannot be trusted to
# say whether a guard bit. Isolation makes each verdict mean one thing, and it
# is also how CI runs the suite.
function Invoke-Suite {
    param([string]$Root, [string]$Suite)
    $script = @"
Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Force
`$c = New-PesterConfiguration
`$c.Run.Path = '$((Join-Path $Root $Suite) -replace "'","''")'
`$c.Run.PassThru = `$true
`$c.Output.Verbosity = 'None'
`$env:TB_PESTER = '1'
`$r = Invoke-Pester -Configuration `$c
Write-Output ("RESULT PASS={0} FAIL={1}" -f `$r.PassedCount, `$r.FailedCount)
`$r.Failed | ForEach-Object { Write-Output ("FAILED " + `$_.ExpandedPath) }
"@
    # STDERR IS KEPT (@saadqbal on #931). This was `2>$null`, so when the child
    # died before printing RESULT the harness reported "no result line" with no
    # cause -- and under $ErrorActionPreference='Stop' it killed the run outright
    # on Asad's machine: exit 1, fourteen bytes of red, no diagnostic. A count
    # without a cause, which is the thing this harness exists to stop shipping.
    $err = $null
    $out = & pwsh -NoProfile -Command $script 2>&1 |
             ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $err = "$err`n$_"; } else { $_ } }
    $line = @($out | Where-Object { $_ -like 'RESULT *' }) | Select-Object -Last 1
    if (-not $line) {
        $tail = if ($err) { ($err -split "`n" | Where-Object { $_ } | Select-Object -Last 4) -join ' | ' }
                else      { (@($out) | Select-Object -Last 4) -join ' | ' }
        return @{ PassedCount = 0; FailedCount = -1
                  Failed = @("the suite produced no result line -- child said: $tail") }
    }
    $passed = [int]([regex]::Match($line, 'PASS=(\d+)').Groups[1].Value)
    $failed = [int]([regex]::Match($line, 'FAIL=(\d+)').Groups[1].Value)
    $names  = @($out | Where-Object { $_ -like 'FAILED *' } | ForEach-Object { $_.Substring(7) })
    return @{ PassedCount = $passed; FailedCount = $failed; Failed = $names }
}

foreach ($suite in ($Mutations.Suite | Sort-Object -Unique)) {
    $r = Invoke-Suite -Root $RepoRoot -Suite $suite
    if ($r.FailedCount -ne 0) {
        # NAME THEM. A bare count sends whoever reads this hunting, which is the
        # defect class this whole harness exists to close.
        Write-Host "BASELINE NOT GREEN ($suite): $($r.FailedCount) failing. A 'caught' verdict cannot be trusted." -ForegroundColor Red
        $r.Failed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "baseline green: $suite ($($r.PassedCount) passed)" -ForegroundColor DarkGray
}

# ── the real thing ───────────────────────────────────────────────────────────
$caught = 0; $survived = @(); $misattributed = @()
foreach ($m in $Mutations) {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("tb-mut-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        # THE WHOLE TREE, NOT JUST scripts/ (@saadqbal on #931, and this was the
        # defect that made the harness a liar). install-k8s.Tests.ps1 reads six
        # paths ABOVE scripts/ -- ../../docker/k3s-cuda/* and
        # ../../client/templates/resource-monitor-daemonset.yaml -- so a
        # scripts-only sandbox failed SEVEN drift guards before any mutation was
        # applied. With the old `if ($fails -gt 0)` predicate every
        # install-k8s.ps1 entry then "caught" on inherited failures alone: 11 of
        # 13 could not fail. Asad proved it by making the dashboard guard vacuous
        # and watching the run still report 13/13.
        #
        # .git is skipped because it is 106 MB of the 122, and no suite reads it.
        Get-ChildItem -LiteralPath $RepoRoot -Force |
          Where-Object { $_.Name -notin @('.git', '.venv', 'node_modules', '.claude') } |
          ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox $_.Name) -Recurse -Force }
        $target = Join-Path $sandbox $m.File
        $lines  = [System.IO.File]::ReadAllLines($target)
        $idx    = (Get-MarkerIndex -Lines $lines -Find $m.Find `
                     -After ($(if ($m.ContainsKey('After')) { $m.After } else { '' })) `
                     -Within ($(if ($m.ContainsKey('Within')) { $m.Within } else { 20 }))).Index
        $lines[$idx] = $m.Repl
        [System.IO.File]::WriteAllLines($target, $lines)
        $mr = Invoke-Suite -Root $sandbox -Suite $m.Suite
        $fails = $mr.FailedCount
        # ATTRIBUTION, NOT A COUNT (@saadqbal on #931: "the one that matters").
        #
        # `$fails -gt 0` credits a catch to ANY failure, so a mutation clears it on
        # a failure that has nothing to do with the guard -- an inherited one, or a
        # different guard breaking for an unrelated reason. Asad demonstrated the
        # end state: with the dashboard guard made vacuous AND the link
        # reintroduced, the run still printed `caught`. The number was measuring
        # noise.
        #
        # So each entry names the guard it EXPECTS to see fail, and only that
        # guard's failure counts. A mutation that reddens the suite via some other
        # test is MISATTRIBUTED -- reported as a failure of the registry, not as a
        # catch -- because it means the guard we believe protects this fix does not.
        $expected = @($mr.Failed | Where-Object { $_ -like "*$($m.Expect)*" })
        if ($expected.Count -gt 0) {
            $caught++
            Write-Host ("  caught   {0}" -f $m.Name) -ForegroundColor Green
            Write-Host ("             by: {0}" -f ($expected[0] -replace '^.*?\.', '')) -ForegroundColor DarkGray
        } elseif ($fails -gt 0) {
            $misattributed += "$($m.Name)  [reddened, but NOT via '$($m.Expect)' -- $fails other failure(s)]"
            Write-Host ("  MISATTRIB {0}" -f $m.Name) -ForegroundColor Red
            Write-Host ("             expected a failure matching '{0}'; got: {1}" -f $m.Expect, (($mr.Failed | Select-Object -First 2) -join '; ')) -ForegroundColor Red
        } else {
            $survived += $m.Name
            Write-Host ("  SURVIVED {0}" -f $m.Name) -ForegroundColor Red
        }
    } finally {
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host ("{0}/{1} mutations caught BY THE GUARD THAT CLAIMS THEM" -f $caught, $Mutations.Count)
if ($survived.Count -gt 0) {
    Write-Host "SURVIVED -- these guards do not bite, so the fix is unprotected:" -ForegroundColor Red
    $survived | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
if ($misattributed.Count -gt 0) {
    # Deliberately as loud as SURVIVED. A mutation that reddens the suite via some
    # OTHER test tells us nothing about the guard we think protects the fix, and a
    # harness that scores it as a pass is the defect it exists to close.
    Write-Host "MISATTRIBUTED -- the suite reddened, but not via the claiming guard:" -ForegroundColor Red
    $misattributed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
if ($survived.Count -gt 0 -or $misattributed.Count -gt 0) { exit 1 }
exit 0
