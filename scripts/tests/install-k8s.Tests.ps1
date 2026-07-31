# Pester tests for scripts/install-k8s.ps1 (Windows installer).
# Dot-sources the script with $env:TB_PESTER set so the admin gate + main() are
# skipped and only the functions load. Run: Invoke-Pester scripts/tests/

BeforeAll {
  $env:TB_PESTER = "1"
  . "$PSScriptRoot/../install-k8s.ps1"
  # Stubs so Pester can mock external commands that the functions invoke.
  # kubectl defaults to a successful exit so the bounded API-reachability probe
  # (Test-ApiReachable) passes in tests that don't explicitly mock it; tests that
  # care about an unreachable API Mock kubectl to set a non-zero exit.
  function kubectl { $global:LASTEXITCODE = 0 }
  function docker { }
  function helm { }
  function k3d { }
  function tracebloc { }   # Test-TraceblocCli (#738) calls `& tracebloc version`;
                           # Pester can only Mock a command that already exists.
}

Describe "Get-BackendUrl" {
  AfterEach { $env:CLIENT_ENV = $null }
  It "defaults to prod when CLIENT_ENV is unset" {
    $env:CLIENT_ENV = $null
    Get-BackendUrl | Should -Be "https://api.tracebloc.io/"
  }
  It "dev" { $env:CLIENT_ENV = "dev"; Get-BackendUrl | Should -Be "https://dev-api.tracebloc.io/" }
  It "stg" { $env:CLIENT_ENV = "stg"; Get-BackendUrl | Should -Be "https://stg-api.tracebloc.io/" }
  It "unknown -> prod" { $env:CLIENT_ENV = "whatever"; Get-BackendUrl | Should -Be "https://api.tracebloc.io/" }
}

Describe "Daily-user provisioning (#418)" {
  It "Get-WslConfigMemoryGb caps at physical - 4 GB" {
    Get-WslConfigMemoryGb -HostGb 16 | Should -Be 12
    Get-WslConfigMemoryGb -HostGb 32 | Should -Be 28
  }
  It "Get-WslConfigMemoryGb floors at 1 GB on a tiny host" {
    Get-WslConfigMemoryGb -HostGb 4 | Should -Be 1
  }
  It "Get-WslConfigContent writes the [wsl2] memory stanza" {
    $c = Get-WslConfigContent -MemoryGb 12
    $c | Should -Match '(?m)^\[wsl2\]'
    $c | Should -Match 'memory=12GB'
  }
  It "Add-WslMemorySetting creates a [wsl2] stanza from empty content" {
    $c = Add-WslMemorySetting -Existing "" -MemoryGb 12
    $c | Should -Match '(?m)^\[wsl2\]'
    $c | Should -Match 'memory=12GB'
  }
  It "Add-WslMemorySetting keeps an existing memory= (returns null -> don't clobber)" {
    Add-WslMemorySetting -Existing "[wsl2]`r`nmemory=6GB`r`nprocessors=4`r`n" -MemoryGb 12 | Should -Be $null
  }
  It "Add-WslMemorySetting inserts under an existing [wsl2] header, preserving other settings" {
    $c = Add-WslMemorySetting -Existing "[wsl2]`r`nprocessors=4`r`nswap=8GB`r`n" -MemoryGb 12
    $c | Should -Match 'memory=12GB'
    $c | Should -Match 'processors=4'   # other tuning survives
    $c | Should -Match 'swap=8GB'
  }
  It "Add-WslMemorySetting appends a [wsl2] section when none exists, preserving other sections" {
    $c = Add-WslMemorySetting -Existing "[experimental]`r`nsparseVhd=true`r`n" -MemoryGb 12
    $c | Should -Match '(?m)^\[experimental\]'
    $c | Should -Match 'sparseVhd=true'  # other sections survive
    $c | Should -Match '(?m)^\[wsl2\]'
    $c | Should -Match 'memory=12GB'
  }
  It "Get-UserProfileDir returns null for a user who has never signed in" {
    Get-UserProfileDir -User 'nonexistent-user-9d2f' | Should -Be $null
  }
  It "Test-NameInGroupOutput matches on the bare name (domain-stripped, case-insensitive)" {
    Test-NameInGroupOutput -Output @('Administrator','MACHINE\JDoe') -User 'CORP\jdoe' | Should -BeTrue
    Test-NameInGroupOutput -Output @('Administrator','Guest')        -User 'jdoe'      | Should -BeFalse
  }
  It "Test-NameInGroupOutput is false for empty output or empty user" {
    Test-NameInGroupOutput -Output @()          -User 'jdoe' | Should -BeFalse
    Test-NameInGroupOutput -Output @('jdoe')    -User ''     | Should -BeFalse
  }
  It "Resolve-DailyUser prefers the param and strips the domain" {
    Resolve-DailyUser -Param 'CORP\jdoe' -CurrentUser 'admin' | Should -Be 'jdoe'
  }
  It "Resolve-DailyUser falls back to the current user" {
    Resolve-DailyUser -Param '' -CurrentUser 'researcher' | Should -Be 'researcher'
  }
}

Describe "Daily-user provisioning wiring (#418 source guards)" {
  BeforeAll { $script:PSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "adds the daily user to docker-users" {
    $script:PSRC | Should -Match 'net localgroup docker-users'
  }
  It "verifies docker-users membership by state query, not by string-matching net /add output" {
    $script:PSRC | Should -Match "Test-LocalGroupMember -Group 'docker-users'"
    $script:PSRC | Should -Not -Match "already a member"   # no locale-fragile stderr parse
    $script:PSRC | Should -Not -Match 'net localgroup docker-users .* /add 2>&1'
  }
  It "warns loudly (never green) when the critical docker-users step fails" {
    $script:PSRC | Should -Match 'Could NOT add .* to docker-users'
    # the green "Configured for" summary is gated behind dockerUsersOk
    $script:PSRC | Should -Match 'if \(-not \$dockerUsersOk\)'
  }
  It "merges a sized .wslconfig via Add-WslMemorySetting (preserves other settings)" {
    $script:PSRC | Should -Match 'Add-WslMemorySetting -Existing'
    $script:PSRC | Should -Match '\(\?im\)\^\\s\*memory\\s\*='   # preserves an existing memory= line
  }
  It "notes .wslconfig as a manual step when the daily user has no profile yet" {
    $script:PSRC | Should -Match 'no profile for .* yet'
  }
  It "notes .wslconfig as a manual step when host RAM can't be detected (no silent skip)" {
    $script:PSRC | Should -Match "couldn't detect host RAM"
  }
  It "notes .wslconfig as a manual step when the write itself throws (no silent catch)" {
    $script:PSRC | Should -Match "couldn't write .wslconfig"
  }
  It "sanitizes the prompted daily-user name before it hits net localgroup + paths" {
    $script:PSRC | Should -Match '\$other = ConvertTo-SanitizedInput \$other'
  }
  It "forwards -DailyUser through self-elevation so it survives the UAC relaunch" {
    $script:PSRC | Should -Match 'Invoke-SelfElevate .* -DailyUser \$DailyUser'
    $script:PSRC | Should -Match "\-DailyUser', "   # Get-ElevationCommand appends it to the forwarded switches
  }
  It "is warn-only, opt-out-able, and wired into the elevated run" {
    $script:PSRC | Should -Match 'Set-DailyUserProvisioning'
    $script:PSRC | Should -Match 'TRACEBLOC_SKIP_DAILY_USER'
  }
}

Describe "Install-state pure helpers (#420)" {
  It "New-InstallState is not-completed at the current schema" {
    $s = New-InstallState
    $s.schema    | Should -Be 1
    $s.completed | Should -BeFalse
  }
  It "Test-InstallStateCurrent is true only for a matching schema" {
    Test-InstallStateCurrent -State (New-InstallState) | Should -BeTrue
    Test-InstallStateCurrent -State $null              | Should -BeFalse
    Test-InstallStateCurrent -State ([pscustomobject]@{ schema = 99 }) | Should -BeFalse
  }
  It "ConvertTo-InstallState round-trips a completed state" {
    $s = [pscustomobject]@{ schema = 1; completed = $true }
    $r = ConvertTo-InstallState -Json ($s | ConvertTo-Json -Compress)
    $r.schema    | Should -Be 1
    $r.completed | Should -BeTrue
  }
  It "ConvertTo-InstallState returns a fresh (not-completed) state on corrupt / empty / wrong-schema JSON" {
    (ConvertTo-InstallState -Json '{not json').completed | Should -BeFalse
    (ConvertTo-InstallState -Json '').schema             | Should -Be 1
    $wrong = @{ schema = 99; completed = $true } | ConvertTo-Json -Compress
    (ConvertTo-InstallState -Json $wrong).completed | Should -BeFalse
  }
}

Describe "Test-ClusterRunningInList (#420 Bugbot: running, not just present)" {
  It "is true only when the named cluster has >=1 server running" {
    $up = '[{"name":"tracebloc","serversCount":1,"serversRunning":1}]'
    Test-ClusterRunningInList -Json $up -Name 'tracebloc' | Should -BeTrue
  }
  It "is false for a present-but-stopped cluster (serversRunning=0)" {
    $stopped = '[{"name":"tracebloc","serversCount":1,"serversRunning":0}]'
    Test-ClusterRunningInList -Json $stopped -Name 'tracebloc' | Should -BeFalse
  }
  It "is false when the named cluster is absent" {
    $other = '[{"name":"other","serversRunning":1}]'
    Test-ClusterRunningInList -Json $other -Name 'tracebloc' | Should -BeFalse
  }
  It "is false for empty / corrupt / shape-without-running-count JSON" {
    Test-ClusterRunningInList -Json ''            -Name 'tracebloc' | Should -BeFalse
    Test-ClusterRunningInList -Json '{not json'   -Name 'tracebloc' | Should -BeFalse
    Test-ClusterRunningInList -Json '[{"name":"tracebloc"}]' -Name 'tracebloc' | Should -BeFalse
  }
}

Describe "Test-ClientHealthy (#420 Bugbot: verify workloads Ready, not just cluster)" {
  It "Get-ClientDeploymentNames lists the three client workloads for a namespace" {
    Get-ClientDeploymentNames -Namespace 'acme' |
      Should -Be @('mysql-client','acme-jobs-manager','acme-requests-proxy')
  }
  It "is false when no client release can be found (unknown / no namespace)" {
    Mock Get-InstalledClientInfo { [pscustomobject]@{ Id=''; Ns=''; Name=''; UnreadableNs=''; ListUnknown=$true } }
    Test-ClientHealthy | Should -BeFalse
    Mock Get-InstalledClientInfo { [pscustomobject]@{ Id=''; Ns=''; Name=''; UnreadableNs=''; ListUnknown=$false } }
    Test-ClientHealthy | Should -BeFalse
  }
  It "is true only when every client deployment rolls out Ready" {
    Mock Get-InstalledClientInfo { [pscustomobject]@{ Id='c1'; Ns='acme'; Name='acme'; UnreadableNs=''; ListUnknown=$false } }
    Mock kubectl { $global:LASTEXITCODE = 0 }   # all rollouts Ready
    Test-ClientHealthy | Should -BeTrue
  }
  It "is false when any client deployment is not Ready" {
    Mock Get-InstalledClientInfo { [pscustomobject]@{ Id='c1'; Ns='acme'; Name='acme'; UnreadableNs=''; ListUnknown=$false } }
    Mock kubectl { $global:LASTEXITCODE = 1 }   # rollout not Ready
    Test-ClientHealthy | Should -BeFalse
  }
}

Describe "Get-ResumeCommand (#420 resume-after-reboot)" {
  It "carries -File, forwarded switches, and -Resume for a durable script path" {
    $real = (Resolve-Path "$PSScriptRoot/../install-k8s.ps1").Path   # a real, non-temp file
    $c = Get-ResumeCommand -ScriptPath $real -DailyUser 'jdoe'
    $c | Should -Match '^powershell\.exe '
    $c | Should -Match '-File "'
    $c | Should -Match '-DailyUser "jdoe"'
    $c | Should -Match '-Resume$'
  }
  It "does NOT append -Resume to the irm|iex one-liner (shim has no param block, #421)" {
    $c = Get-ResumeCommand -ScriptPath 'C:\does\not\exist.ps1'   # forces the one-liner fallback
    $c | Should -Match 'irm https://tracebloc.io/i.ps1 \| iex'
    $c | Should -Not -Match '-Resume'
  }
}

Describe "Install-state I/O round-trip (#420)" {
  # Mock the path to TestDrive (Pester mocks reach dot-sourced callers regardless of
  # scope) and no-op the profile-dir mkdir so nothing touches the real home dir.
  BeforeAll {
    Mock Get-InstallStatePath { Join-Path "$TestDrive" 'install-state.json' }
    Mock New-Item { }
  }
  BeforeEach { Remove-Item (Join-Path "$TestDrive" 'install-state.json') -ErrorAction SilentlyContinue }

  It "Read-InstallState returns a fresh (not-completed) state when no file exists" {
    $r = Read-InstallState
    $r.schema    | Should -Be 1
    $r.completed | Should -BeFalse
  }
  It "Set-InstallComplete persists completed=true, reloadable by Read-InstallState" {
    Set-InstallComplete
    $r = Read-InstallState
    $r.completed | Should -BeTrue
    $r.schema    | Should -Be 1
  }
  It "Clear-InstallCompleted resets completed=false (disarms a stale fast path)" {
    Set-InstallComplete
    (Read-InstallState).completed | Should -BeTrue
    Clear-InstallCompleted
    (Read-InstallState).completed | Should -BeFalse
  }
  It "a corrupt state file degrades to a fresh state instead of throwing" {
    Set-Content -Path (Get-InstallStatePath) -Value '{ broken' -Encoding ASCII
    $r = Read-InstallState
    $r.schema    | Should -Be 1
    $r.completed | Should -BeFalse
  }
}

Describe "Completion vs exit predicates (#420 reviewer: 'starting' is not 'done')" {
  AfterAll { $script:ClientState = 'starting' }   # restore the module default
  It "Test-InstallConnected (arms the fast path) is true ONLY for connected" {
    $script:ClientState = 'connected'; Test-InstallConnected | Should -BeTrue
    foreach ($s in 'starting','crash','bad_creds','image_pull','image_pull_ca') {
      $script:ClientState = $s
      Test-InstallConnected | Should -BeFalse -Because "'$s' is not a fully-up client, so completion must not arm the fast path"
    }
  }
  It "Test-InstallSucceeded (exit code) also allows starting, but never a failure state" {
    $script:ClientState = 'connected'; Test-InstallSucceeded | Should -BeTrue
    $script:ClientState = 'starting';  Test-InstallSucceeded | Should -BeTrue
    foreach ($s in 'crash','bad_creds','image_pull','image_pull_ca','stopped') {
      $script:ClientState = $s
      Test-InstallSucceeded | Should -BeFalse -Because "'$s' is a failure that must exit non-zero"
    }
  }
}

Describe "Resume-after-reboot wiring (#420 source guards)" {
  BeforeAll { $script:PSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "adds a -Resume switch to the param block and forwards it through elevation" {
    $script:PSRC | Should -Match 'param\(\[switch\]\$Help.*\[switch\]\$Resume\)'
    $script:PSRC | Should -Match "if \(\`$Resume\)\s+\{ \`$switches \+= '-Resume' \}"
  }
  It "registers a RunOnce continuation at the reboot exit" {
    $script:PSRC | Should -Match 'Register-ResumeAfterReboot -ScriptPath \$PSCommandPath'
  }
  It "warns that resume is tied to the current account in the split -DailyUser case" {
    $script:PSRC | Should -Match '\$DailyUser -and \(\$DailyUser -ne \$env:USERNAME\)'
    $script:PSRC | Should -Match 'Resume is registered for'
  }
  It "completes ONLY when connected, and CLEARS a stale completed on any other outcome" {
    $script:PSRC | Should -Match 'if \(Test-InstallConnected\) \{ Set-InstallComplete \} else \{ Clear-InstallCompleted \}'
    # the exit code is deliberately more lenient (starting is OK) but a failure exits 1
    $script:PSRC | Should -Match 'if \(-not \(Test-InstallSucceeded\)\) \{ exit 1 \}'
  }
  It "does not leave dead per-step stage checkpoints behind (reviewer: stages dropped)" {
    $script:PSRC | Should -Not -Match "Set-StageComplete"
    $script:PSRC | Should -Not -Match "function Add-CompletedStage"
  }
  It "gates the fast nothing-to-do path on tools + running cluster + HEALTHY client" {
    $script:PSRC | Should -Match '\$script:InstallState\.completed -and \(Test-ToolsPresent\) -and \(Test-ClusterRunning\) -and \(Test-ClientHealthy\)'
    $script:PSRC | Should -Match 'already installed and the client is healthy -- nothing to do'
  }
  It "names the ACTUAL state-file path in the force-reinstall hint (honours HOST_DATA_DIR)" {
    # Must interpolate Get-InstallStatePath, not hard-code ~\.tracebloc\install-state.json.
    $script:PSRC | Should -Match 'Delete \$\(Get-InstallStatePath\)'
    $script:PSRC | Should -Not -Match 'Delete ~\\\.tracebloc\\install-state\.json'
  }
  It "bounds the k3d fast-path probe with a job + deadline (no unbounded k3d call)" {
    # Test-ClusterRunning must run k3d inside a timed job, never a bare foreground call.
    $script:PSRC | Should -Match 'function Test-ClusterRunning[\s\S]*Start-Job[\s\S]*Wait-JobWithProgress[\s\S]*Remove-Job'
  }
  It "bounds the fast-path client health check (short rollout deadline, not the full wait)" {
    $script:PSRC | Should -Match 'function Test-ClientHealthy[\s\S]*rollout status[\s\S]*--timeout=5s'
  }
}

Describe "Get-ElevationCommand (#421 self-elevate)" {
  It "returns a single command-line STRING (PS 5.1 quoting-safe, Bugbot #421)" {
    Get-ElevationCommand -ScriptPath "" | Should -BeOfType [string]
  }
  It "re-runs an on-disk script with a QUOTED -File path + forwards the switches" {
    $c = Get-ElevationCommand -ScriptPath $PSCommandPath -NoReboot -Diagnose   # durable, non-temp
    $c | Should -Match '-File "'          # path is quoted (survives spaces)
    $c | Should -Match '-NoReboot'
    $c | Should -Match '-Diagnose'
  }
  It "re-fetches the one-liner when there's no script on disk (irm|iex)" {
    $c = Get-ElevationCommand -ScriptPath ""
    $c | Should -Match 'irm https://tracebloc\.io/i\.ps1 \| iex'
    $c | Should -Not -Match '-File'
  }
  It "a bootstrap TEMP-dir script -> re-fetches the one-liner, not -File (deleted-temp, Bugbot #421)" {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-k8s.ps1"
    Set-Content -Path $tmp -Value "x" -Force
    try {
      $c = Get-ElevationCommand -ScriptPath $tmp
      $c | Should -Not -Match '-File'
      $c | Should -Match 'irm https://tracebloc\.io/i\.ps1'
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
  It "does NOT bind switches to the paramless shim on the one-liner path (Bugbot #421)" {
    # & ([scriptblock]::Create((irm ...))) -Diagnose would fail (shim has no param
    # block); an iex launch can't have set a switch anyway. Keep plain irm|iex.
    $c = Get-ElevationCommand -ScriptPath "" -Diagnose
    $c | Should -Match 'irm https://tracebloc\.io/i\.ps1 \| iex'
    $c | Should -Not -Match 'scriptblock'
  }
  It "omits switches that weren't passed" {
    $c = Get-ElevationCommand -ScriptPath ""
    $c | Should -Not -Match '-NoReboot'
    $c | Should -Not -Match '-Diagnose'
  }
}

Describe "Self-elevation gate (#421 source guards)" {
  BeforeAll { $script:ESRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "offers to relaunch elevated (UAC) before falling back to instructions" {
    $script:ESRC | Should -Match 'Invoke-SelfElevate -ScriptPath \$PSCommandPath'
    $script:ESRC | Should -Match "Start-Process -FilePath 'powershell' -Verb RunAs"
  }
  It "only prompts when interactive, else prints the manual Terminal (Admin) steps" {
    $script:ESRC | Should -Match 'UserInteractive -and -not \[Console\]::IsInputRedirected'
    $script:ESRC | Should -Match 'Terminal \(Admin\)'
  }
}

Describe "Get-ToolSummaryLine (#422 honest per-tool progress)" {
  It "name + version + size + elapsed" {
    Get-ToolSummaryLine -Name "kubectl" -Version "v1.31.0" -Size "~60 MB" -ElapsedSec 12 |
      Should -Be "kubectl v1.31.0 (~60 MB, 12s)"
  }
  It "name + version only (no meta parens)" {
    Get-ToolSummaryLine -Name "helm" -Version "v4.2.3" | Should -Be "helm v4.2.3"
  }
  It "name only" { Get-ToolSummaryLine -Name "k3d" | Should -Be "k3d" }
  It "size without elapsed" {
    Get-ToolSummaryLine -Name "k3d" -Version "v5.9.0" -Size "~25 MB" |
      Should -Be "k3d v5.9.0 (~25 MB)"
  }
  It "elapsed 0 is shown (not treated as absent)" {
    Get-ToolSummaryLine -Name "helm" -Version "v4.2.3" -ElapsedSec 0 |
      Should -Be "helm v4.2.3 (0s)"
  }
}

Describe "Invoke-WithHeartbeat (#422 no silent window)" {
  It "returns the operation output" {
    (Invoke-WithHeartbeat -Message "adding" -PollSeconds 1 -Script { 40 + 2 }) | Should -Be 42
  }
  It "throws when the operation fails (so callers keep retry/abort flow)" {
    { Invoke-WithHeartbeat -Message "boom" -PollSeconds 1 -Script { throw "kaboom" } } | Should -Throw
  }
  It "passes ArgumentList into the job scriptblock" {
    (Invoke-WithHeartbeat -Message "args" -PollSeconds 1 -ArgumentList @("a","b") -Script { param($x,$y) "$x$y" }) |
      Should -Be "ab"
  }
  It "job runspaces get the TLS 1.2 floor (Bugbot #422)" {
    # Jobs don't inherit the parent's SecurityProtocol; JobInit must re-apply it,
    # else in-job HTTPS downloads fail on TLS-1.2-only hosts.
    (Invoke-WithHeartbeat -Message "tls" -PollSeconds 1 -Script { [Net.ServicePointManager]::SecurityProtocol.ToString() }) |
      Should -Match 'Tls12'
  }
  It "surfaces the real failure detail, not just a generic message (Bugbot #422)" {
    # A failed job's real error must reach the caller (log + Err), not be swallowed.
    { Invoke-WithHeartbeat -Message "op" -PollSeconds 1 -Script { throw "REAL_REASON_XYZ" } } |
      Should -Throw -ExpectedMessage "*REAL_REASON_XYZ*"
  }
}

Describe "Step honesty (#422 split check vs install)" {
  BeforeAll { $script:SRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "runs six steps, not five" {
    $script:SRC | Should -Match 'Step 6 \$script:INSTALL_STEPS\.Count "'
    $script:SRC | Should -Not -Match 'Step [0-9] 5 "'
  }
  It "has a dedicated 'Installing system tools' step" {
    $script:SRC | Should -Match 'Step 2 \$script:INSTALL_STEPS\.Count "Installing system tools"'
  }
  It "the k3d start path runs as a killable process with output to the log, not streamed (Bugbot #422)" {
    # No bare streaming form; k3d start is a tracked process with its raw INFO[...]
    # redirected to temp files (logged), so nothing streams to the console.
    $script:SRC | Should -Not -Match '(?m)^\s*k3d cluster start \$CLUSTER_NAME\s*$'
    $script:SRC | Should -Match 'Start-Process -FilePath "k3d" -ArgumentList @\("cluster","start"'
    $script:SRC | Should -Match 'RedirectStandardError \$startErrFile'
  }
  It "k3d start Errs on timeout or non-zero exit, never a false 'started' (Bugbot #422)" {
    # A deadline that KILLS the process (no orphan) plus an exit-code check both
    # gate the "started" line.
    $script:SRC | Should -Match 'Wait-ProcessWithDeadline -Process \$sp'
    $script:SRC | Should -Match '\$sp\.ExitCode -ne 0'
  }
  It "the Docker installer runs as a killable, output-capturing process, not an orphan-prone job (Bugbot #422 / #500)" {
    # The direct install now goes through Invoke-TrackedInstall (killable via
    # Wait-ProcessWithDeadline INSIDE the helper, output captured) and Errs on any
    # non-ok outcome (timeout / failed / spawn-failed).
    $script:SRC | Should -Match 'Invoke-TrackedInstall -FilePath \$installer[\s\S]{0,220}-Tag "docker-direct"'
    $script:SRC | Should -Match "'timeout'\s+\{ Err"
    $script:SRC | Should -Match 'function Invoke-TrackedInstall[\s\S]*Wait-ProcessWithDeadline'
  }
  It "k3d/helm print their green summary only after the execute-gate (Bugbot #422)" {
    # A corrupt/wrong-arch binary must fail Assert-ToolRuns before any green Ok;
    # the summary is deferred to after the gate (kubectl already does this).
    $script:SRC | Should -Match 'Assert-ToolRuns -Name "k3d"[\s\S]{0,80}if \(\$k3dSummary\) \{ Ok'
    $script:SRC | Should -Match 'Assert-ToolRuns -Name "helm"[\s\S]{0,80}if \(\$helmSummary\) \{ Ok'
  }
  It "the winget Docker path is killable, output-captured, falls back, and fails loudly (Bugbot #422 / #500)" {
    # winget runs through the killable, output-capturing wrapper; a non-ok state
    # falls back to the direct download, and a final Test-Path guard Errs if nothing
    # landed.
    $script:SRC | Should -Match 'Docker\.DockerDesktop'
    $script:SRC | Should -Match 'Invoke-TrackedInstall -FilePath "winget" -ArgumentList \$wingetArgs'
    $script:SRC | Should -Match 'will try direct download\): state='
    $script:SRC | Should -Match "Docker Desktop installation didn't complete"
  }
}

Describe "Docker Desktop install flags (#419 zero GUI interaction)" {
  BeforeAll { $script:DSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "winget path passes Docker's installer flags via a quoted --override (PS 5.1 safe)" {
    # winget's manifest defaults can't set the backend or accept the license; --override
    # passes Docker Desktop's own installer args. The value must be a single quoted
    # argument in a command-line STRING (array elements aren't quoted on PS 5.1).
    $script:DSRC | Should -Match '--override "install --quiet --accept-license --backend=wsl-2 --always-run-service"'
    # the --override string still flows as a single verbatim arg via $wingetArgs, now
    # through the output-capturing Invoke-TrackedInstall wrapper (#500).
    $script:DSRC | Should -Match 'Invoke-TrackedInstall -FilePath "winget" -ArgumentList \$wingetArgs'
  }
  It "direct path installs unattended with the WSL2 backend" {
    $script:DSRC | Should -Match 'install --quiet --accept-license --backend=wsl-2 --always-run-service'
  }
  It "both install paths select the WSL2 backend explicitly (no implicit choice)" {
    ([regex]::Matches($script:DSRC, 'backend=wsl-2')).Count | Should -BeGreaterOrEqual 2
  }
  It "both paths run the engine service unattended (zero GUI first-run)" {
    ([regex]::Matches($script:DSRC, 'always-run-service')).Count | Should -BeGreaterOrEqual 2
  }
}

Describe "Install roadmap single-source (#500 no drift)" {
  BeforeAll { $script:RSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "INSTALL_STEPS lists all six steps, including the tools phase" {
    $script:INSTALL_STEPS.Count | Should -Be 6
    $script:INSTALL_STEPS | Should -Contain 'Install system tools'
  }
  It "Print-Roadmap renders every step, numbered, from INSTALL_STEPS" {
    $out = (Print-Roadmap 6>&1 | Out-String)
    for ($i = 0; $i -lt $script:INSTALL_STEPS.Count; $i++) {
      $out | Should -Match ([regex]::Escape("$($i+1). $($script:INSTALL_STEPS[$i])"))
    }
  }
  It "every Step header derives its total from INSTALL_STEPS.Count (no hard-coded /6)" {
    $script:RSRC | Should -Not -Match 'Step [0-9] 6 "'
    ([regex]::Matches($script:RSRC, 'Step [0-9] \$script:INSTALL_STEPS\.Count ')).Count | Should -Be 6
  }
  It "the number of runtime Step calls equals INSTALL_STEPS.Count (roadmap can't drift)" {
    ([regex]::Matches($script:RSRC, '(?m)^\s*Step [0-9] ')).Count | Should -Be $script:INSTALL_STEPS.Count
  }
}

Describe "Invoke-TrackedInstall (#500 capture installer output)" {
  BeforeAll { $script:ISRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "redirects both stdout and stderr to temp files" {
    $script:ISRC | Should -Match 'function Invoke-TrackedInstall[\s\S]*-RedirectStandardOutput[\s\S]*-RedirectStandardError'
  }
  It "folds captured output into the log (stderr first, matching #423 ordering)" {
    $script:ISRC | Should -Match 'function Invoke-TrackedInstall[\s\S]*Get-Content \$errF[\s\S]*Get-Content \$outF'
    $script:ISRC | Should -Match 'function Invoke-TrackedInstall[\s\S]*if \(\$log\) \{ Log'
  }
  It "all four winget/installer installs go through the capturing wrapper" {
    foreach ($tag in 'docker-winget','docker-direct','k3d-winget','helm-winget') {
      $script:ISRC | Should -Match "Invoke-TrackedInstall[\s\S]{0,300}-Tag `"$tag`""
    }
  }
  It "returns ok with the exit code when the process succeeds" {
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t"
    $r.State | Should -Be 'ok'; $r.ExitCode | Should -Be 0
  }
  It "returns failed with the exit code when the process exits non-zero" {
    Mock Start-Process { [pscustomobject]@{ ExitCode = 3; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t"
    $r.State | Should -Be 'failed'; $r.ExitCode | Should -Be 3
  }
  It "returns timeout when the deadline is hit" {
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $false } }
    Mock Wait-ProcessWithDeadline { $false }
    (Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t").State | Should -Be 'timeout'
  }
  It "returns spawn-failed when the process can't start" {
    Mock Start-Process { throw "no such file" }
    (Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t").State | Should -Be 'spawn-failed'
  }
}

Describe "Get-ErrDetailLines (#423 honest failure output)" {
  BeforeEach { $script:LOG_FILE = "C:\Users\x\.tracebloc\install-20260729-000000.log" }
  AfterEach  { $script:LOG_FILE = $null }

  It "always names the log path and the -Diagnose support bundle" {
    $out = (Get-ErrDetailLines $null) -join "`n"
    $out | Should -Match ([regex]::Escape($script:LOG_FILE))
    $out | Should -Match '-Diagnose'
  }
  It "no detail -> no '--- details ---' section" {
    (Get-ErrDetailLines $null) | Should -Not -Contain "--- details ---"
  }
  It "surfaces the real error excerpt when detail is supplied" {
    $detail = "pulling image`nrpc error`nx509: certificate signed by unknown authority"
    $out = (Get-ErrDetailLines $detail)
    $out | Should -Contain "--- details ---"
    ($out -join "`n") | Should -Match 'x509: certificate signed by unknown authority'
  }
  It "caps the excerpt at the last 5 non-empty lines" {
    $detail = (1..9 | ForEach-Object { "line$_" }) -join "`n"
    $out = (Get-ErrDetailLines $detail)
    ($out -join "`n") | Should -Match 'line9'
    ($out -join "`n") | Should -Match 'line5'
    ($out -join "`n") | Should -Not -Match 'line4\b'   # only last 5 (line5..line9)
  }
  It "drops blank lines from the excerpt" {
    $detail = "real reason`n`n`n   `n"
    $out = (Get-ErrDetailLines $detail)
    ($out -join "`n") | Should -Match 'real reason'
    # trailing blank lines must not become excerpt entries
    ($out | Where-Object { $_ -eq "" }).Count | Should -Be 0
  }
  It "omits the log line when no log file is set yet" {
    $script:LOG_FILE = $null
    $out = (Get-ErrDetailLines "boom") -join "`n"
    $out | Should -Not -Match 'Full log:'
    $out | Should -Match '-Diagnose'   # next-step hint still present
  }
  It "keeps the real Error: line and strips PS 5.1 ErrorRecord chrome (Bugbot #423)" {
    # helm failures arrive as `native 2>&1 | Out-String`; on PS 5.1 that decorates
    # stderr with position/CategoryInfo/FullyQualifiedErrorId lines. The excerpt
    # must surface the actual Error, not the formatter noise.
    $detail = @"
helm : Error: looks like "https://bad" is not a valid chart repository or cannot be reached
At line:1 char:14
+ `$addOutput = (helm repo add tracebloc https://bad --force-update 2>&1 ...
+              ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (Error:...:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError
"@
    $out = (Get-ErrDetailLines $detail) -join "`n"
    $out | Should -Match 'Error: looks like'
    $out | Should -Not -Match 'FullyQualifiedErrorId'
    $out | Should -Not -Match 'CategoryInfo'
    $out | Should -Not -Match 'At line:1 char:14'
  }
  It "Err is the single source of the log path — no inline 'Full log:' hints (Bugbot #423)" {
    # Err now always prints the log path via Get-ErrDetailLines; an inline
    # `Hint "Full log:"` right before an Err would print it twice.
    $src = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $src | Should -Not -Match 'Hint "Full log:'
  }
  It "single-line result enumerates as one intact line, never per-character (Bugbot #423)" {
    # The bare-Err path (no detail, no LOG_FILE — e.g. a Confirm-Config failure
    # before Start-InstallLog) returns just the support-bundle line. Enumerating it
    # must yield that whole line, not a stream of single characters.
    $script:LOG_FILE = $null
    $lines = @(Get-ErrDetailLines $null)
    $lines.Count | Should -Be 1
    $lines[0]    | Should -Be "Support bundle: re-run with -Diagnose"
    foreach ($l in @(Get-ErrDetailLines $null)) { $l.Length | Should -BeGreaterThan 1 }
  }
}

Describe "Test-Credentials" {
  It "HTTP 200 -> valid" {
    Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    Test-Credentials -ClientId x -ClientPassword y | Should -Be "valid"
  }
  It "HTTP 400 -> invalid" {
    Mock Invoke-WebRequest {
      $resp = [pscustomobject]@{ StatusCode = 400 }
      $ex = [System.Exception]::new("400"); $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
      throw $ex
    }
    Test-Credentials -ClientId x -ClientPassword y | Should -Be "invalid"
  }
  It "HTTP 401 -> inactive" {
    Mock Invoke-WebRequest {
      $resp = [pscustomobject]@{ StatusCode = 401 }
      $ex = [System.Exception]::new("401"); $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
      throw $ex
    }
    Test-Credentials -ClientId x -ClientPassword y | Should -Be "inactive"
  }
  It "connection failure -> unverified" {
    Mock Invoke-WebRequest { throw [System.Exception]::new("connection refused") }
    Test-Credentials -ClientId x -ClientPassword y | Should -Be "unverified"
  }
  It "non-200 success -> unverified" {
    Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 204 } }
    Test-Credentials -ClientId x -ClientPassword y | Should -Be "unverified"
  }
}

Describe "Get-NotReadyState" {
  It "jobs-manager auth error -> bad_creds" {
    Mock kubectl { if ($args -match 'logs') { "Authentication failed: Unable to log in" } else { "" } }
    Get-NotReadyState -Namespace ns | Should -Be "bad_creds"
  }
  It "ImagePullBackOff -> image_pull" {
    Mock kubectl { if ($args -match 'logs') { "booting" } else { "x 0/1 ImagePullBackOff" } }
    Get-NotReadyState -Namespace ns | Should -Be "image_pull"
  }
  It "CrashLoopBackOff -> crash" {
    Mock kubectl { if ($args -match 'logs') { "booting" } else { "x 0/1 CrashLoopBackOff" } }
    Get-NotReadyState -Namespace ns | Should -Be "crash"
  }
  It "still creating -> starting" {
    Mock kubectl { if ($args -match 'logs') { "booting" } else { "x 0/1 ContainerCreating" } }
    Get-NotReadyState -Namespace ns | Should -Be "starting"
  }
  It "captures the x509 pull event into NotReadyDetail (#425)" {
    Mock kubectl {
      if ($args -match 'logs') { return "booting" }
      if ($args -match 'events') { return 'Failed to pull image "ghcr.io/x": x509: certificate signed by unknown authority' }
      return "foo 0/1 ImagePullBackOff 0 30s"
    }
    Get-NotReadyState -Namespace ns | Should -Be "image_pull_ca"
    $script:NotReadyDetail | Should -Match 'x509'
  }
  It "captures a non-x509 pull event into NotReadyDetail and stays image_pull (#425)" {
    Mock kubectl {
      if ($args -match 'logs') { return "booting" }
      if ($args -match 'events') { return 'Failed to pull image "ghcr.io/x": 403 Forbidden' }
      return "foo 0/1 ErrImagePull 0 30s"
    }
    Get-NotReadyState -Namespace ns | Should -Be "image_pull"
    $script:NotReadyDetail | Should -Match '403 Forbidden'
  }
  It "falls back to the failing pod line when there is no pull event (#425)" {
    Mock kubectl {
      if ($args -match 'logs') { return "booting" }
      if ($args -match 'events') { return "" }
      return "foo 0/1 ImagePullBackOff 0 30s"
    }
    Get-NotReadyState -Namespace ns | Should -Be "image_pull"
    $script:NotReadyDetail | Should -Match 'ImagePullBackOff'
  }
}

Describe "Write-NotReadyDetail (#425 failure copy carries the event text)" {
  AfterAll { $script:NotReadyDetail = "" }
  It "prints the captured cluster detail under a labelled block" {
    $script:NotReadyDetail = "Failed to pull image `"ghcr.io/x`": x509: certificate signed by unknown authority`nfoo 0/1 ImagePullBackOff"
    $out = Write-NotReadyDetail 6>&1 | Out-String
    $out | Should -Match 'What the cluster reported'
    $out | Should -Match 'x509'
    $out | Should -Match 'ImagePullBackOff'
  }
  It "is a no-op when there is no detail (never an empty labelled block)" {
    $script:NotReadyDetail = ""
    ((Write-NotReadyDetail 6>&1 | Out-String).Trim()) | Should -BeNullOrEmpty
  }
}

Describe "Print-Summary" {
  BeforeEach { $script:TB_NAMESPACE = "ns"; $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false }
  It "connected: Connected + trust claim" {
    $script:ClientState = "connected"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "Connected to tracebloc"
    $out | Should -Match "data never leaves"
  }
  It "starting: still starting, no trust claim" {
    $script:ClientState = "starting"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "still starting"
    $out | Should -Not -Match "data never leaves"
  }
  It "bad_creds: rejected, no trust claim" {
    $script:ClientState = "bad_creds"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "rejected"
    $out | Should -Not -Match "data never leaves"
  }
  It "crash: crash-loop message" {
    $script:ClientState = "crash"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "crash loop"
  }
  It "connected: shows the client version" {
    $script:ClientState = "connected"
    Mock helm { "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4" }
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "Version"
    $out | Should -Match "1\.4\.4"
  }
}

Describe "ConvertTo-WorkspaceName" {
  It "lowercases + dashes spaces/underscores" { ConvertTo-WorkspaceName -Input_ "My Team_1" | Should -Be "my-team-1" }
  It "all-invalid -> default" { ConvertTo-WorkspaceName -Input_ "@@@" | Should -Be "default" }
}

Describe "Install-TraceblocCli" {
  # Step 5 of the installer: install the tracebloc CLI via its own released
  # installer, run in a CHILD powershell process. The load-bearing property is
  # NON-FATAL — a failure must Warn (not throw), since the client is already up.
  BeforeEach {
    Mock RefreshPath {}
    Mock Has { $false }   # tracebloc not already on PATH
  }
  # Fake the System.Diagnostics.Process that Start-Process -PassThru returns:
  # the function caches .Handle, calls .WaitForExit(), then reads .ExitCode.
  It "non-fatal: warns (does not throw) when the CLI installer exits non-zero" {
    Mock Start-Process {
      $o = [pscustomobject]@{ ExitCode = 1 }
      $o | Add-Member ScriptProperty Handle { [IntPtr]::Zero }
      $o | Add-Member ScriptMethod WaitForExit { }
      $o
    }
    $out = Install-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "Couldn't install the tracebloc CLI"
  }
  It "non-fatal: warns (does not throw) when Start-Process itself throws" {
    Mock Start-Process { throw "network down" }
    $out = Install-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "Couldn't install the tracebloc CLI"
  }
  It "reports success only when the installer exits 0" {
    Mock Start-Process {
      $o = [pscustomobject]@{ ExitCode = 0 }
      $o | Add-Member ScriptProperty Handle { [IntPtr]::Zero }
      $o | Add-Member ScriptMethod WaitForExit { }
      $o
    }
    $out = Install-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "tracebloc CLI (ready|installed)"   # happy verdict is "ready", edge is "installed"
  }
  It "warns on a failed re-install even when a CLI is already on PATH" {
    Mock Start-Process {
      $o = [pscustomobject]@{ ExitCode = 1 }
      $o | Add-Member ScriptProperty Handle { [IntPtr]::Zero }
      $o | Add-Member ScriptMethod WaitForExit { }
      $o
    }
    Mock Has { $true }    # a CLI is already present, but the installer failed…
    $out = Install-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "Couldn't install the tracebloc CLI"   # …so it must still warn
  }
}

Describe "Test-TraceblocCli" {
  # Post-install self-verification (#738). Proves the CLI is usable from a fresh
  # terminal and prints a VERIFIED next command, or the Windows-correct fix if a
  # new shell wouldn't find it. Load-bearing property: NON-FATAL (never throws).
  BeforeEach { Mock RefreshPath {} }

  It "fresh-shell success: reports a VERIFIED verdict, not 'open a new terminal so'" {
    Mock Has { $true }                       # a fresh shell resolves tracebloc
    Mock tracebloc { "tracebloc 0.2.0" }
    $out = Test-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "run 'tb'"          # usable-now verdict (was "verified on your PATH")
    $out | Should -Match "0.2.0"             # real proof via `tracebloc version`
    $out | Should -Not -Match "open a new terminal so"   # the old, useless line is gone
  }

  It "CLI-missing-from-fresh-shell: prints an actionable hint (install dir)" {
    Mock Has { $false }                      # installed, but not yet resolvable
    $out = Test-TraceblocCli 6>&1 | Out-String
    $out | Should -Match "open a new PowerShell window"
    $out | Should -Match "Installed to:"     # the exact location, not a vague hint
  }

  It "non-fatal: does not throw even if RefreshPath blows up" {
    Mock RefreshPath { throw "registry unavailable" }
    Mock Has { $false }
    { Test-TraceblocCli 6>&1 | Out-Null } | Should -Not -Throw
  }
}

Describe "Get-WindowsArch" {
  AfterEach { $env:PROCESSOR_ARCHITECTURE = "AMD64" }
  It "AMD64 -> amd64" { $env:PROCESSOR_ARCHITECTURE = "AMD64"; Get-WindowsArch | Should -Be "amd64" }
  It "ARM64 -> arm64" { $env:PROCESSOR_ARCHITECTURE = "ARM64"; Get-WindowsArch | Should -Be "arm64" }
  It "unknown -> Err" {
    Mock Err { throw "err" }
    $env:PROCESSOR_ARCHITECTURE = "sparc"
    { Get-WindowsArch } | Should -Throw
  }
}

Describe "Confirm-Config" {
  It "valid config passes + sets HOST_DATA_DIR" {
    # $env:HOME is empty on Windows (it uses USERPROFILE) — derive a profile dir
    # valid on both OSes, else GetFullPath in Confirm-Config throws "path is empty".
    $prof = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
    $env:USERPROFILE = $prof
    $CLUSTER_NAME = "tracebloc"; $SERVERS = "1"; $AGENTS = "1"; $HOST_DATA_DIR = Join-Path $prof ".tracebloc"
    { Confirm-Config } | Should -Not -Throw
  }
  It "invalid CLUSTER_NAME -> Err" {
    Mock Err { throw "err" }
    $prof = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
    $env:USERPROFILE = $prof
    $CLUSTER_NAME = "1bad"; $SERVERS = "1"; $AGENTS = "1"; $HOST_DATA_DIR = Join-Path $prof "x"
    { Confirm-Config } | Should -Throw
  }
}

Describe "Wait-ForClientReady" {
  BeforeEach { $script:TB_NAMESPACE = "ns"; $ReadyTimeout = "20" }
  It "all rollouts ready -> connected" {
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Mock Confirm-Cluster { }
    Wait-ForClientReady
    $script:ClientState | Should -Be "connected"
  }
  It "a rollout fails -> diagnosed (bad_creds)" {
    Mock kubectl {
      if ($args -match 'rollout') { $global:LASTEXITCODE = 1; return }
      $global:LASTEXITCODE = 0
      if ($args -match 'logs') { return "Authentication failed: Unable to log in" }
      return "x 0/1 CrashLoopBackOff"
    }
    Mock Confirm-Cluster { }
    Wait-ForClientReady
    $script:ClientState | Should -Be "bad_creds"
  }
}

Describe "Install-ClientHelm" {
  BeforeEach {
    $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false; $env:CLIENT_ENV = $null
    Mock helm { $global:LASTEXITCODE = 0 }
  }
  # Step-4 provisioning state must never leak between tests (#388): unset means
  # the legacy fallback path, which is what the pre-#388 tests below drive.
  AfterEach {
    $script:TB_PROV_MODE = $null; $script:TB_PROV_ID = $null
    $script:TB_PROV_NS = $null; $script:TB_PROV_PASSWORD = $null
    $env:TRACEBLOC_CLIENT_ID = $null; $env:TRACEBLOC_CLIENT_PASSWORD = $null
  }
  It "minted mode (#388): no prompts; values carry the minted credential; slug namespace used" {
    $HOST_DATA_DIR = "$TestDrive/d-mint"
    $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-11"
    $script:TB_PROV_PASSWORD = "mintedpw"; $script:TB_PROV_NS = "lukas-01"
    Mock Read-Host { throw "the minted path must never prompt" }
    Mock Test-Credentials { "valid" }   # even a fresh mint verifies (#397 r2)
    Install-ClientHelm
    Should -Invoke Test-Credentials -Times 1
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'clientId: "uuid-11"'
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match "clientPassword: 'mintedpw'"
    Should -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "lukas-01") }
  }
  It "adopted mode (#388): surgical --reuse-values reconcile heals a STALE (cli#125 numeric) clientId" {
    # The realistic heal: helm still reports the legacy numeric dashboard id
    # while Step 4 adopted the UUID. The guard must let adopted mode through
    # (the one sanctioned id mismatch, r1 High), and the upgrade must be
    # SURGICAL — --reuse-values on the LIVE release in ITS namespace, healing
    # only clientId, never regenerating values (#397 r2).
    $HOST_DATA_DIR = "$TestDrive/d-adopt"; New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    Set-Content "$HOST_DATA_DIR/values.yaml" "clientId: `"123`"`nclientPassword: 'prevpw'"
    $script:TB_PROV_MODE = "adopted"; $script:TB_PROV_ID = "uuid-9"; $script:TB_PROV_NS = "lukas-01"
    Mock Read-Host { throw "the adopted path must never prompt" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"legacy-ns","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"123"}' } else { 'clientId: 123' }   # STALE id
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "--reuse-values") -and ($args -contains "clientId=uuid-9") -and ($args -contains "oldrel") -and ($args -contains "legacy-ns") }
    Should -Not -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "--values") }
    # The local record is healed surgically — clientId only, password untouched.
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'clientId: "uuid-9"'
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match "clientPassword: 'prevpw'"
    # Wait-ForClientReady must watch the LIVE release's namespace.
    $script:TB_NAMESPACE | Should -Be "legacy-ns"
  }
  It "adopted mode with a live release needs NO password at all (#397 r2)" {
    $HOST_DATA_DIR = "$TestDrive/d-adopt-nopw"   # no values.yaml anywhere
    $script:TB_PROV_MODE = "adopted"; $script:TB_PROV_ID = "uuid-9"; $script:TB_PROV_NS = "lukas-01"
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"lukas-01","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"uuid-9"}' } else { 'clientId: uuid-9' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "--reuse-values") }
  }
  It "a DIFFERENT existing client still refuses outside adopted mode (guard intact)" {
    $HOST_DATA_DIR = "$TestDrive/d-guard-minted"
    $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-new"
    $script:TB_PROV_PASSWORD = "pw"; $script:TB_PROV_NS = "ws-new"
    Mock Err { throw "err: $args" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"other","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"someone-else"}' } else { 'clientId: someone-else' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "adopted mode on a REBUILT cluster (no release, no values file) -> honest terminal error (#388)" {
    $HOST_DATA_DIR = "$TestDrive/d-adopt-bare"
    $script:TB_PROV_MODE = "adopted"; $script:TB_PROV_ID = "uuid-9"; $script:TB_PROV_NS = "lukas-01"
    Mock Err { throw "err: $args" }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "preset mode (#388): env credentials verify once, no prompts" {
    $HOST_DATA_DIR = "$TestDrive/d-preset"
    $script:TB_PROV_MODE = "preset"
    $env:TRACEBLOC_CLIENT_ID = "envid"; $env:TRACEBLOC_CLIENT_PASSWORD = "envpw"
    Mock Read-Host { throw "the preset path must never prompt" }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'clientId: "envid"'
    Should -Invoke Test-Credentials -Times 1
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "preset mode: rejected env credentials fail closed (#388)" {
    $HOST_DATA_DIR = "$TestDrive/d-preset-bad"
    $script:TB_PROV_MODE = "preset"
    $env:TRACEBLOC_CLIENT_ID = "envid"; $env:TRACEBLOC_CLIENT_PASSWORD = "wrong"
    Mock Test-Credentials { "invalid" }
    Mock Err { throw "err: $args" }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "valid creds: writes values.yaml + runs helm" {
    $HOST_DATA_DIR = "$TestDrive/d1"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "mypw" -AsPlainText -Force) }
      if ($Prompt -match 'Workspace') { return "myws" }
      if ($Prompt -match 'Client ID') { return "myid" }
      return ""
    }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'clientId: "myid"'
    # NB: the SecureString->plaintext path runs, but PtrToStringAuto only decodes
    # correctly on Windows; assert the key is written, not the macOS-decoded value.
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match "clientPassword:"
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "CLIENT_ENV=dev is written into the values" {
    $HOST_DATA_DIR = "$TestDrive/d1b"; $CLIENT_ENV = "dev"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      if ($Prompt -match 'Workspace') { return "ws" }
      return "id"
    }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'CLIENT_ENV: dev'
  }
  It "re-prompts on invalid, then accepts valid" {
    $HOST_DATA_DIR = "$TestDrive/d2"; $script:vc = 0
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      if ($Prompt -match 'Workspace') { return "ws" }
      return "id"
    }
    Mock Test-Credentials { $script:vc++; if ($script:vc -ge 2) { "valid" } else { "invalid" } }
    Install-ClientHelm
    Should -Invoke Test-Credentials -Times 2
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "unverified backend -> proceeds with install" {
    $HOST_DATA_DIR = "$TestDrive/d3"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      if ($Prompt -match 'Workspace') { return "ws" }
      return "id"
    }
    Mock Test-Credentials { "unverified" }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "reuses previous clientId/password defaults" {
    $HOST_DATA_DIR = "$TestDrive/d4"; New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    Set-Content "$HOST_DATA_DIR/values.yaml" "clientId: `"previd`"`nclientPassword: 'prevpw'"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'previous') { return "y" }
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "newpw" -AsPlainText -Force) }
      if ($Prompt -match 'Workspace') { return "ws" }
      return ""   # Client ID -> Enter keeps the previous default (previd)
    }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    (Get-Content "$HOST_DATA_DIR/values.yaml" -Raw) | Should -Match 'clientId: "previd"'
  }
  # One-client guard mocks mirror real helm (#200): `helm get values` re-serializes
  # the stored values, so its YAML view typically emits clientId UNQUOTED — only
  # the `-o json` view is quoting-proof, and that is what the guard must read.
  # Each mock serves JSON when asked for it and the YAML view otherwise, so a
  # regression back to YAML-regex-scraping fails these tests.
  It "blocks a DIFFERENT client already installed" {
    $HOST_DATA_DIR = "$TestDrive/d5"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"otherclient"}' } else { 'clientId: otherclient' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "blocks a DIFFERENT client whose YAML view is <style> (#200)" -TestCases @(
    @{ style = 'unquoted';      yaml = 'clientId: otherclient' }
    @{ style = 'single-quoted'; yaml = "clientId: 'otherclient'" }
    @{ style = 'double-quoted'; yaml = 'clientId: "otherclient"' }
  ) {
    param($style, $yaml)
    $HOST_DATA_DIR = "$TestDrive/d5-$style"
    $script:yamlView = $yaml
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"otherclient"}' } else { $script:yamlView }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "scans past a release with no user values and still finds the client" {
    $HOST_DATA_DIR = "$TestDrive/d5-null"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"bare","namespace":"ns1","chart":"client-1.4.2"},{"name":"oldrel","namespace":"ns2","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        # `helm get values -o json` prints literal null when nothing was set.
        if ($args -contains "bare") { 'null' } else { '{"clientId":"otherclient"}' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "fails CLOSED when the only client release has unparsable values (no silent overwrite)" {
    # An unparsable `helm get values -o json` for the sole client release must NOT
    # be treated as "no client here" — that fails OPEN and overwrites an existing
    # client we simply couldn't identify. The guard must block instead.
    $HOST_DATA_DIR = "$TestDrive/d5-badjson"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") { '{ this is : not json'; $global:LASTEXITCODE = 0; return }  # fetch OK, unparsable
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "fails CLOSED when the only client release's values cannot be fetched" {
    $HOST_DATA_DIR = "$TestDrive/d5-fetchfail"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") { $global:LASTEXITCODE = 1; return }   # `helm get values` failed
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "fails CLOSED when 'helm list' itself errors (can't enumerate -> no silent overwrite)" {
    # A failed enumeration must not read as "no client here" — that fails OPEN.
    $HOST_DATA_DIR = "$TestDrive/d5-listfail"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { $global:LASTEXITCODE = 1; return }   # helm list failed
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "fails CLOSED when 'helm list' returns non-JSON garbage" {
    $HOST_DATA_DIR = "$TestDrive/d5-listgarbage"
    Mock Err { throw "err" }
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { 'this is not json'; $global:LASTEXITCODE = 0; return }  # rc 0 but garbage
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "values without a clientId key do not trip the guard" {
    $HOST_DATA_DIR = "$TestDrive/d5-nokey"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "newclient"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") { '{"env":{"CLIENT_ENV":"dev"}}'; $global:LASTEXITCODE = 0; return }
      $global:LASTEXITCODE = 0
    }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "same client re-run is allowed (upgrade in place)" {
    $HOST_DATA_DIR = "$TestDrive/d6"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "sameid"
    }
    Mock Test-Credentials { "valid" }
    Mock helm {
      if ($args -contains "list") { '[{"name":"tracebloc","namespace":"tracebloc","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"sameid"}' } else { 'clientId: sameid' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  # #385: the repo must be (re-)registered on EVERY run. The old presence guard
  # string-matched (helm repo list 2>&1), which Windows PowerShell 5.1 renders
  # with this script's own ...\tracebloc-installer-<n>\... temp path -- containing
  # "tracebloc" -- so the add was skipped on every fresh machine and the upgrade
  # died with "Error: repo tracebloc not found".
  It "registers the chart repo with --force-update before upgrading (#385)" {
    $HOST_DATA_DIR = "$TestDrive/d385a"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "id385"
    }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter {
      ($args -contains "repo") -and ($args -contains "add") -and
      ($args -contains "--force-update") -and ($args -contains "https://tracebloc.github.io/client")
    }
    Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
  It "aborts with helm's own output when the repo add fails (#385)" {
    $HOST_DATA_DIR = "$TestDrive/d385b"
    Mock Read-Host {
      param([string]$Prompt, [switch]$AsSecureString)
      if ($Prompt -match 'password') { return (ConvertTo-SecureString "pw" -AsPlainText -Force) }
      return "id385b"
    }
    Mock Test-Credentials { "valid" }
    # #423: helm's real output now flows through Err's $Detail param (surfaced on
    # screen via Get-ErrDetailLines), not embedded in the message — capture both.
    Mock Err { param($m, $Detail) $script:lastErr = "$m`n$Detail"; throw "err" }
    Mock helm {
      if (($args -contains "repo") -and ($args -contains "add")) {
        $global:LASTEXITCODE = 1
        return "Error: looks like this is not a valid chart repository"
      }
      $global:LASTEXITCODE = 0
    }
    { Install-ClientHelm } | Should -Throw
    $script:lastErr | Should -Match 'not a valid chart repository'
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
  }
}

Describe "Get-TrainingResources" {
  # backend#1236 (option A): machine-sized training default, mirroring the bash
  # twin's _training_resources. Precedence: env override > installed release's
  # choice > largest-node sizing > static fallback.
  BeforeEach { $script:TB_NAMESPACE = "tracebloc"; $env:TRACEBLOC_TRAINING_RESOURCES = $null }
  AfterEach  { $env:TRACEBLOC_TRAINING_RESOURCES = $null }
  It "explicit override wins" {
    $env:TRACEBLOC_TRAINING_RESOURCES = "cpu=4,memory=16Gi"
    Get-TrainingResources | Should -Be "cpu=4,memory=16Gi"
  }
  It "existing release choice carried (resources set survives re-install)" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }   # bounded namespace probe passes
    Mock helm { $global:LASTEXITCODE = 0; '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi"}}' }
    Get-TrainingResources | Should -Be "cpu=4,memory=12Gi"
  }
  It "the historic static default is NOT carried — re-install gets sized (Bugbot)" {
    Mock helm { $global:LASTEXITCODE = 0; '{"env":{"RESOURCE_LIMITS":"cpu=2,memory=8Gi"}}' }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0
        @("12 6924Mi")
      } else { $global:LASTEXITCODE = 0; "" }   # namespace probe passes
    }
    Get-TrainingResources | Should -Be "cpu=11,memory=3Gi"
  }
  It "fresh install sized to the largest node minus overhead (k3d nodes not summed)" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    # The mock only answers a BOUNDED call — dropping --request-timeout fails
    # this test (a wedged API must never hang values generation). Output is the
    # jsonpath "cpu memory" line contract (one line per node).
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0
        @("12 6924Mi", "12 6924Mi")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=11,memory=3Gi"
  }
  It "below-floor machine falls back to the static default" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 0; @("2 4Gi") }
    Get-TrainingResources | Should -Be "cpu=2,memory=8Gi"
  }
  It "unreadable cluster falls back to the static default" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Get-TrainingResources | Should -Be "cpu=2,memory=8Gi"
  }
}

Describe "Confirm-Cluster" {
  It "dumps cluster status without error" {
    $script:TB_NAMESPACE = "ns"; $script:LOG_FILE = "$TestDrive/log.txt"
    Mock kubectl { "info" }
    { Confirm-Cluster } | Should -Not -Throw
  }
}

# --- Corporate-proxy hardening (Windows parity with scripts/lib/cluster.sh) ---
Describe "Get-EffectiveNoProxy" {
  AfterEach { $env:NO_PROXY = $null; $env:no_proxy = $null }
  It "empty host NO_PROXY -> cluster-internal defaults" {
    $env:NO_PROXY = $null; $env:no_proxy = $null
    $r = Get-EffectiveNoProxy
    $r | Should -Match '169\.254\.169\.254'
    $r | Should -Match '127\.0\.0\.1'
    $r | Should -Match '10\.0\.0\.0/8'
    $r | Should -Match '\.svc'
    $r | Should -Match 'host\.k3d\.internal'
  }
  It "host entries kept first and de-duplicated" {
    $env:NO_PROXY = "foo.com,127.0.0.1"
    $r = Get-EffectiveNoProxy
    $r | Should -BeLike "foo.com,127.0.0.1,*"
    ([regex]::Matches($r, '127\.0\.0\.1')).Count | Should -Be 1
  }
  It "lowercase no_proxy is honoured" {
    $env:NO_PROXY = $null; $env:no_proxy = "bar.internal"
    Get-EffectiveNoProxy | Should -BeLike "bar.internal,*"
  }
}

Describe "Write-K3dProxyConfig" {
  AfterEach {
    $env:HTTP_PROXY = $null; $env:HTTPS_PROXY = $null
    $env:http_proxy = $null; $env:https_proxy = $null
    $env:NO_PROXY = $null;   $env:no_proxy = $null
  }
  It "no proxy set -> returns null" {
    Write-K3dProxyConfig | Should -BeNullOrEmpty
  }
  It "auth creds preserved (Gap A) + augmented NO_PROXY (Gap B), written without a BOM" {
    $env:HTTP_PROXY = "http://user:pass@proxy.example.com:8080"
    $env:NO_PROXY   = "corp.internal"
    $cfg = Write-K3dProxyConfig
    $cfg | Should -Not -BeNullOrEmpty
    Test-Path $cfg | Should -BeTrue
    $content = Get-Content $cfg -Raw
    $content | Should -Match 'apiVersion: k3d.io/v1alpha5'
    $content | Should -Match 'HTTP_PROXY=http://user:pass@proxy.example.com:8080'
    $content | Should -Match 'NO_PROXY=corp.internal,'
    $content | Should -Match 'NO_PROXY=[^"]*127\.0\.0\.1'
    # UTF-8 without BOM — Windows PowerShell 5.1 would otherwise prepend EF BB BF
    # and break the YAML parser.
    $bytes = [System.IO.File]::ReadAllBytes($cfg)
    ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    Remove-Item (Split-Path $cfg -Parent) -Recurse -Force
  }
  It "HTTP_PROXY only still emits augmented NO_PROXY" {
    $env:HTTP_PROXY = "http://proxy:8080"
    $cfg = Write-K3dProxyConfig
    (Get-Content $cfg -Raw) | Should -Match 'NO_PROXY=[^"]*127\.0\.0\.1'
    Remove-Item (Split-Path $cfg -Parent) -Recurse -Force
  }
}

# --- Preflight checks (mirrors scripts/lib/preflight.sh) ---------------------
Describe "Test-PfUrl" {
  It "HTTP 200 -> ok" {
    Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    Test-PfUrl "https://x" | Should -Be "ok"
  }
  It "HTTP error response (server reached) -> ok" {
    Mock Invoke-WebRequest {
      $ex = [System.Exception]::new("HTTP 401")
      Add-Member -InputObject $ex -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 401 }) -Force
      throw $ex
    }
    Test-PfUrl "https://x" | Should -Be "ok"
  }
  It "TLS / certificate error -> tls" {
    Mock Invoke-WebRequest { throw [System.Exception]::new("The SSL certificate could not be validated - trust failure") }
    Test-PfUrl "https://x" | Should -Be "tls"
  }
  It "connection failure -> blocked" {
    Mock Invoke-WebRequest { throw [System.Exception]::new("Unable to connect to the remote server") }
    Test-PfUrl "https://x" | Should -Be "blocked"
  }
  # -RequireSuccess: for targets whose CONTENT must exist (the Helm repo
  # index.yaml, #385) an HTTP error is a failure, not "reachable".
  It "-RequireSuccess: HTTP 404 -> 'http 404' (#385)" {
    Mock Invoke-WebRequest {
      $ex = [System.Exception]::new("HTTP 404")
      Add-Member -InputObject $ex -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 }) -Force
      throw $ex
    }
    Test-PfUrl "https://x" -RequireSuccess | Should -Be "http 404"
  }
  It "-RequireSuccess: HTTP 200 -> ok" {
    Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    Test-PfUrl "https://x" -RequireSuccess | Should -Be "ok"
  }
  It "-RequireSuccess: connection failure still classified (blocked)" {
    Mock Invoke-WebRequest { throw [System.Exception]::new("Unable to connect to the remote server") }
    Test-PfUrl "https://x" -RequireSuccess | Should -Be "blocked"
  }
}

# Get-CimInstance is a Windows-only cmdlet (CimCmdlets module) — it can't be
# mocked on Linux/macOS pwsh, so these run only on Windows (a Windows reviewer /
# Windows CI). Off-Windows the readers safely return $null (the catch), which
# Test-Preflight handles as "couldn't determine (skipping)".
Describe "Get-Pf* resource readers" -Skip:(-not $IsWindows) {
  It "Get-PfCpu reads logical processors" {
    Mock Get-CimInstance { [pscustomobject]@{ NumberOfLogicalProcessors = 4 } }
    Get-PfCpu | Should -Be 4
  }
  It "Get-PfMemGb reads total RAM in GB" {
    Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = 8GB } }
    Get-PfMemGb | Should -Be 8
  }
  It "Get-PfMemGb reports host RAM even when Docker reports a smaller budget (#417)" {
    # The flip-flop bug: same 16 GB host read as ~8 GB while Docker was up. Now the
    # host figure wins regardless of the Docker VM budget.
    Mock Get-CimInstance { [pscustomobject]@{ TotalPhysicalMemory = 16GB } }
    Mock docker { '8589934592' }          # Docker would report 8 GiB; must be IGNORED
    Get-PfMemGb | Should -Be 16
  }
  It "Get-PfFreeGb reads free disk in GB" {
    Mock Get-CimInstance { [pscustomobject]@{ FreeSpace = 50GB } }
    Get-PfFreeGb | Should -Be 50
  }
  It "Get-PfVirtualization: running hypervisor -> true, firmware not consulted (#387)" {
    Mock Get-CimInstance { [pscustomobject]@{ HypervisorPresent = $true } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
    Get-PfVirtualization | Should -Be $true
  }
  It "Get-PfVirtualization: no hypervisor + firmware disabled -> false (#387)" {
    Mock Get-CimInstance { [pscustomobject]@{ HypervisorPresent = $false } } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
    Mock Get-CimInstance { [pscustomobject]@{ VirtualizationFirmwareEnabled = $false } } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
    Get-PfVirtualization | Should -Be $false
  }
}

Describe "Test-Preflight" {
  BeforeEach {
    Mock Err { throw "preflight-failed" }      # Err exits; make it throwable to assert
    Mock Get-PfCpu { 4 }; Mock Get-PfMemGb { 8 }; Mock Get-PfFreeGb { 50 }
    Mock Get-WindowsArch { "amd64" }
    Mock Get-PfFsType { "local" }
    Mock Get-PfVirtualization { $true }
  }
  AfterEach { $env:TRACEBLOC_SKIP_PREFLIGHT = $null; $env:TRACEBLOC_ALLOW_ARM64 = $null; $env:TRACEBLOC_ALLOW_NETWORK_FS = $null }

  It "healthy environment -> does not throw" {
    Mock Test-PfUrl { "ok" }
    { Test-Preflight } | Should -Not -Throw
  }
  It "a critical host blocked -> fails (Err throws)" {
    Mock Test-PfUrl { "blocked" }
    { Test-Preflight } | Should -Throw
  }
  It "TRACEBLOC_SKIP_PREFLIGHT -> skipped, no probing" {
    $env:TRACEBLOC_SKIP_PREFLIGHT = "1"
    Mock Test-PfUrl { "blocked" }
    { Test-Preflight } | Should -Not -Throw
    Should -Invoke Test-PfUrl -Exactly -Times 0
  }
  It "arm64 -> info, not a hard fail (Docker Desktop emulates)" {
    Mock Get-WindowsArch { "arm64" }
    Mock Test-PfUrl { "ok" }
    { Test-Preflight } | Should -Not -Throw
  }
  # #387: Docker Desktop's own "Virtualization support not detected" only
  # appears AFTER we've installed and launched it — preflight must fail fast
  # with the firmware fix instead.
  It "virtualization disabled in firmware -> fails (Err throws) (#387)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfVirtualization { $false }
    { Test-Preflight } | Should -Throw
  }
  It "virtualization undeterminable -> skipped, not a fail (#387)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfVirtualization { $null }
    { Test-Preflight } | Should -Not -Throw
  }
  It "memory below floor -> warn-only on Windows (does not throw)" {
    Mock Test-PfUrl { "ok" }; Mock Get-PfMemGb { 3 }
    { Test-Preflight } | Should -Not -Throw
  }
  It "a throttled Docker budget warns even on a large host (not a green Ok) (#417 reviewer)" {
    # The reviewer's key case: 32 GB host but Docker throttled to 2 GB. Grading the
    # EFFECTIVE figure must OOM-warn (budget < the 5 GB floor), not green-OK the host.
    Mock Test-PfUrl { "ok" }; Mock Get-PfMemGb { 32 }; Mock Get-PfRuntimeMemGb { 2 }
    $out = (Test-Preflight 6>&1 | Out-String)
    $out | Should -Match 'it will OOM'
    $out | Should -Match "Docker's current share: 2 GB"   # budget named
    $out | Should -Match '32 GB'                            # host RAM still the label
  }
  It "PF_MIN_MEM_GB override relaxes the floor" {
    Mock Test-PfUrl { "ok" }; Mock Get-PfMemGb { 3 }; $env:PF_MIN_MEM_GB = "2"
    { Test-Preflight } | Should -Not -Throw
    $env:PF_MIN_MEM_GB = $null
  }
  It "network filesystem (HOST_DATA_DIR on NFS/UNC) -> fails (Err throws)" {
    Mock Test-PfUrl { "ok" }; Mock Get-PfFsType { "network" }
    { Test-Preflight } | Should -Throw
  }
  It "network filesystem + TRACEBLOC_ALLOW_NETWORK_FS -> does not throw" {
    Mock Test-PfUrl { "ok" }; Mock Get-PfFsType { "network" }
    $env:TRACEBLOC_ALLOW_NETWORK_FS = "1"
    { Test-Preflight } | Should -Not -Throw
  }
  It "undetermined filesystem type -> does not throw (assume local)" {
    Mock Test-PfUrl { "ok" }; Mock Get-PfFsType { $null }
    { Test-Preflight } | Should -Not -Throw
  }
}

Describe "Get-PfFsType" -Skip:(-not $IsWindows) {
  It "UNC path -> network" {
    $HOST_DATA_DIR = "\\nas\share\tracebloc"
    Get-PfFsType | Should -Be "network"
  }
  It "mapped network drive (DriveType 4) -> network" {
    $HOST_DATA_DIR = "Z:\tracebloc"
    Mock Get-CimInstance { [pscustomobject]@{ DriveType = 4 } }
    Get-PfFsType | Should -Be "network"
  }
  It "local fixed disk (DriveType 3) -> local" {
    $HOST_DATA_DIR = "C:\tracebloc"
    Mock Get-CimInstance { [pscustomobject]@{ DriveType = 3 } }
    Get-PfFsType | Should -Be "local"
  }
}

Describe "Get-Pf* runtime (Docker VM) view preference" {
  It "Get-PfRuntimeMemGb follows the docker MemTotal (#417)" {
    Mock docker { '8589934592' }          # 8 GiB, in bytes
    Get-PfRuntimeMemGb | Should -Be 8
  }
  It "Get-PfMemGb never consults the Docker VM budget (#417 no flip-flop)" {
    # Host-independent + cross-platform: the flip-flop bug was Get-PfMemGb reading
    # the docker budget. Prove it's decoupled by asserting Get-PfMemGb never calls
    # docker at all. Avoids the flaky "Should -Not -Be 8" on a real 8 GB host; the
    # exact host figure is locked by the Windows-gated CIM-mocked sibling test.
    Mock docker { '8589934592' }
    $null = Get-PfMemGb
    Should -Invoke docker -Times 0
  }
  It "Get-PfCpu prefers docker NCPU over the host" {
    Mock docker { '2' }
    Get-PfCpu | Should -Be 2
  }
  It "Get-PfRuntimeMemGb: junk value -> null (forces host fallback)" {
    Mock docker { 'lots' }
    Get-PfRuntimeMemGb | Should -BeNullOrEmpty
  }
  It "Get-PfRuntimeMemGb: docker errors -> null" {
    Mock docker { throw "daemon down" }
    Get-PfRuntimeMemGb | Should -BeNullOrEmpty
  }
}

Describe "Get-PfMemRecommendation (#417 achievable memory advice)" {
  It "caps the recommendation at host RAM - 2 GB" {
    Get-PfMemRecommendation -DesiredGb 16 -HostGb 15 | Should -Be 13
  }
  It "16 GB target on a 15 GB host -> 13, never the impossible 16 (the reported bug)" {
    Get-PfMemRecommendation -DesiredGb 16 -HostGb 15 | Should -Not -Be 16
  }
  It "returns the desired value untouched when it fits" {
    Get-PfMemRecommendation -DesiredGb 8 -HostGb 32 | Should -Be 8
  }
  # Floors at the CLIENT MINIMUM, not 1: a sub-floor recommendation is advice the
  # user cannot act on ("at least 5 GB (up to 4 GB)", memory=4GB). Matches bash's
  # _pf_clamp_mem_gb so both installers advise the same on the same hardware.
  It "floors at the client minimum on a tiny host (never zero/negative/sub-floor)" {
    Get-PfMemRecommendation -DesiredGb 8 -HostGb 2 | Should -Be 5
  }
  It "a 6 GB host never yields a sub-floor number (was 4 -> below the 5 GB minimum)" {
    Get-PfMemRecommendation -DesiredGb 8 -HostGb 6 | Should -Be 5
  }
  It "respects a PF_MIN_MEM_GB override as the floor" {
    $env:PF_MIN_MEM_GB = "3"
    try { Get-PfMemRecommendation -DesiredGb 8 -HostGb 4 | Should -Be 3 }
    finally { $env:PF_MIN_MEM_GB = $null }
  }
  It "never advises below the minimum for any host size (invariant sweep)" {
    foreach ($h in 1..24) {
      Get-PfMemRecommendation -DesiredGb 16 -HostGb $h | Should -BeGreaterOrEqual 5
    }
  }
}

Describe "Show-MemoryStatus: a host too small to reach the floor (#417/#444)" {
  # A 6 GB host cannot give a 5 GB VM and still leave the 2 GB OS reserve, so no
  # Docker setting fixes it. Before this, the sub-floor branch printed
  # "Give Docker at least 5 GB (up to 4 GB)" with a concrete memory=4GB — an empty
  # range whose value was below the minimum the same sentence demanded.
  It "says 'use a larger machine' instead of an unachievable resize hint" {
    $out = (Show-MemoryStatus -HostGb 6 -BudgetGb 3 6>&1 | Out-String)
    $out | Should -Match 'larger machine'
    $out | Should -Not -Match 'at least 5 GB \(up to 4 GB\)'
    $out | Should -Not -Match 'memory=4GB'
  }
  It "still offers the resize hint when the host CAN reach the floor (8 GB host)" {
    $out = (Show-MemoryStatus -HostGb 8 -BudgetGb 4 6>&1 | Out-String)
    $out | Should -Match 'wslconfig'          # a genuine budget bottleneck
    $out | Should -Not -Match 'larger machine'
  }
  It "prints no sub-floor .wslconfig value on any small host (invariant)" {
    foreach ($h in 4..8) {
      $out = (Show-MemoryStatus -HostGb $h -BudgetGb 2 6>&1 | Out-String)
      $out | Should -Not -Match 'memory=[1-4]GB'
    }
  }
}

Describe "Show-MemoryStatus (#417 grade effective, label host)" {
  It "throttled budget on a big host -> OOM-gated, host labeled, budget named (reviewer 32/2)" {
    $out = (Show-MemoryStatus -HostGb 32 -BudgetGb 2 6>&1 | Out-String)
    $out | Should -Match '32 GB'                          # host RAM = the label
    $out | Should -Match "Docker's current share: 2 GB"   # budget shown
    $out | Should -Match 'it will OOM'                     # graded on the 2 GB budget
  }
  It "the #417 machine (15 GB host / 7 GB budget) warns with a capped 13 GB target" {
    $out = (Show-MemoryStatus -HostGb 15 -BudgetGb 7 6>&1 | Out-String)
    $out | Should -Match 'training .* may OOM'
    $out | Should -Match '13 GB recommended'              # min(recMemGb 16, host-2 13)
    $out | Should -Not -Match '16 GB recommended'         # never more than the host has
  }
  It "Docker down (budget null) -> grades + reports host RAM, no flip-flop" {
    $out = (Show-MemoryStatus -HostGb 15 -BudgetGb $null 6>&1 | Out-String)
    $out | Should -Match 'Memory: 15 GB'
    $out | Should -Not -Match "Docker's current share"
  }
  It "host unreadable (CIM blocked) but budget known -> reports the budget, still gated" {
    $out = (Show-MemoryStatus -HostGb $null -BudgetGb 4 6>&1 | Out-String)
    $out | Should -Match 'Memory: 4 GB'
    $out | Should -Match 'host RAM unreadable'
    $out | Should -Match 'it will OOM'                    # 4 < 5 floor still applies
  }
  It "host unknown -> advice isn't capped at the (throttled) budget (#483 Bugbot)" {
    # No host ceiling is known, so recommend the raw targets, never a backwards
    # "at least 5 GB (up to 2 GB)" derived from the current 4 GB budget.
    $out = (Show-MemoryStatus -HostGb $null -BudgetGb 4 6>&1 | Out-String)
    $out | Should -Match 'at least 5 GB \(up to 8 GB\)'
    $out | Should -Not -Match 'up to 2 GB'
  }
  It "both unreadable -> skips (couldn't determine)" {
    $out = (Show-MemoryStatus -HostGb $null -BudgetGb $null 6>&1 | Out-String)
    $out | Should -Match "couldn't determine total RAM"
  }
  It "healthy host + healthy budget -> green Ok" {
    (Show-MemoryStatus -HostGb 32 -BudgetGb 24 6>&1 | Out-String) | Should -Match 'Memory: 32 GB'
    (Show-MemoryStatus -HostGb 32 -BudgetGb 24 6>&1 | Out-String) | Should -Not -Match 'OOM'
  }
}

Describe "Test-PreflightRuntimeMem (post-Docker, warn-only)" {
  It "small Docker VM -> warns, does not throw" {
    Mock Get-PfRuntimeMemGb { 4 }; Mock Get-PfMemGb { 16 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "daemon not reporting (null) -> no-op, does not throw" {
    Mock Get-PfRuntimeMemGb { $null }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "grades the budget with both floors and caps the rec at host RAM (#417 reviewer)" {
    Mock Get-PfRuntimeMemGb { 7 }    # budget in the training-warn band
    Mock Get-PfMemGb { 15 }          # host -> cap the rec at 13 GB
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Match '13 GB recommended'
    $out | Should -Not -Match '16 GB recommended'
    $out | Should -Match "Docker's current share: 7 GB"
  }
  It "a below-floor budget OOM-warns (min floor applies to the budget, not just warn) (#417 reviewer)" {
    Mock Get-PfRuntimeMemGb { 2 }; Mock Get-PfMemGb { 32 }
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Match 'it will OOM'
  }
}

Describe "Test-WslCurrent (#414 skip-when-current, version floor)" {
  It "modern WSL at/above the floor -> current" {
    Test-WslCurrent -VersionOutput "WSL version: 2.3.26.0`nKernel version: 5.15.167.4-1" | Should -BeTrue
  }
  It "a STALE modern WSL below the floor -> not current, so it still updates (reviewer)" {
    Test-WslCurrent -VersionOutput "WSL version: 2.0.0.0`nKernel version: 5.15.90.1" | Should -BeFalse
  }
  It "below Docker Desktop's 2.1.5 minimum (e.g. 2.1.4) -> not current (Bugbot #414)" {
    Test-WslCurrent -VersionOutput "WSL version: 2.1.4.0`nKernel version: 5.15.150.1" | Should -BeFalse
  }
  It "empty output (WSL absent) -> not current" {
    Test-WslCurrent -VersionOutput "" | Should -BeFalse
  }
  It "legacy error text (no version block) -> not current" {
    Test-WslCurrent -VersionOutput "Windows Subsystem for Linux has no installed distributions." | Should -BeFalse
  }
  It "non-English (localized) label still graded via the version number (Bugbot #414)" {
    Test-WslCurrent -VersionOutput "WSL バージョン: 2.3.26.0`nカーネル バージョン: 5.15.167.4-1" | Should -BeTrue
  }
  It "honors a custom floor via TB_WSL_MIN_VERSION / -MinVersion" {
    Test-WslCurrent -VersionOutput "WSL version: 2.3.26.0" -MinVersion "3.0.0" | Should -BeFalse
  }
}

Describe "Update-Wsl branching (#414 reviewer — executed, not just grepped)" {
  BeforeEach { Mock Ok {}; Mock Warn {}; Mock Hint {}; Mock Info {}; Mock Log {}; Mock Get-WindowsArch { "amd64" } }
  It "already current -> skips the update entirely" {
    Mock Get-WslVersionOutput { "WSL version: 2.3.26.0" }; Mock Test-WslCurrent { $true }
    Mock Invoke-WslUpdate { throw "must not run when current" }
    { Update-Wsl } | Should -Not -Throw
    Should -Invoke Invoke-WslUpdate -Times 0
    Should -Invoke Ok -ParameterFilter { $m -match 'current' }
  }
  It "web-download succeeds -> no Store-path retry" {
    Mock Get-WslVersionOutput { "" }; Mock Test-WslCurrent { $false }
    Mock Invoke-WslUpdate { @{ State = 'ok'; ExitCode = 0 } }
    Update-Wsl
    Should -Invoke Invoke-WslUpdate -Times 1
    Should -Invoke Ok -ParameterFilter { $m -match 'updated' }
  }
  It "web-download exits non-zero -> retries the plain Store path (two-rung ladder)" {
    Mock Get-WslVersionOutput { "" }; Mock Test-WslCurrent { $false }
    Mock Invoke-WslUpdate { if ($ExtraArgs -contains '--web-download') { @{ State='failed'; ExitCode=1 } } else { @{ State='ok'; ExitCode=0 } } }
    Update-Wsl
    Should -Invoke Invoke-WslUpdate -Times 2
    Should -Invoke Ok -ParameterFilter { $m -match 'updated' }
  }
  It "timeout is NOT retried and is reported as a timeout, not 'Store blocked'" {
    Mock Get-WslVersionOutput { "" }; Mock Test-WslCurrent { $false }
    Mock Invoke-WslUpdate { @{ State = 'timeout'; ExitCode = $null } }
    Update-Wsl
    Should -Invoke Invoke-WslUpdate -Times 1
    Should -Invoke Warn -ParameterFilter { $m -match 'timed out' }
  }
  It "wsl.exe missing -> reports not-found, no retry" {
    Mock Get-WslVersionOutput { "" }; Mock Test-WslCurrent { $false }
    Mock Invoke-WslUpdate { @{ State = 'not-found'; ExitCode = $null } }
    Update-Wsl
    Should -Invoke Invoke-WslUpdate -Times 1
    Should -Invoke Warn -ParameterFilter { $m -match "wasn't found" }
  }
}

Describe "WSL update wiring (#414 source guards)" {
  BeforeAll { $script:WSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "prefers the Store-free web download (anchored on the invocation, reviewer)" {
    $script:WSRC | Should -Match 'Invoke-WslUpdate -ExtraArgs @\("--web-download"\)'
  }
  It "the wsl --version probe is BOUNDED (job + deadline), not a synchronous hang (reviewer)" {
    $script:WSRC | Should -Match 'Get-WslVersionOutput'
    $script:WSRC | Should -Match 'Wait-JobWithProgress -Job \$job -TimeoutSec 20'
  }
  It "Invoke-WslUpdate redirects output so failures leave real WSL evidence (reviewer)" {
    $script:WSRC | Should -Match '-RedirectStandardOutput \$outF -RedirectStandardError \$errF'
  }
  It "the OutputEncoding restore is wrapped so a throw can't kill the installer (reviewer)" {
    $script:WSRC | Should -Match 'finally \{ try \{ \[Console\]::OutputEncoding = \$prev \} catch \{\} \}'
  }
  It "no longer uses the bare Store-path 'wsl --update' 90s job" {
    $script:WSRC | Should -Not -Match 'cmd /c "wsl --update 2>&1"'
  }
  It "the manual MSI hint names the arch-matched package, not hardcoded x64 (Bugbot #414)" {
    $script:WSRC | Should -Match "Get-WindowsArch\) -eq 'arm64'"
    $script:WSRC | Should -Match 'wsl\.<version>\.\$msiArch\.msi'
  }
}

# --- reboot persistence (Set-ClusterAutostart) -------------------------------
Describe "Set-ClusterAutostart" {
  AfterEach { $env:TRACEBLOC_NO_AUTOSTART = $null }
  It "sets unless-stopped on each k3d node" {
    Mock docker {
      if (($args -join ' ') -match 'ps -a') { return @("k3d-tracebloc-server-0", "k3d-tracebloc-serverlb") }
    }
    Set-ClusterAutostart
    Should -Invoke docker -ParameterFilter { ($args -join ' ') -match 'update --restart unless-stopped' } -Times 2
  }
  It "TRACEBLOC_NO_AUTOSTART -> no docker calls" {
    $env:TRACEBLOC_NO_AUTOSTART = "1"
    Mock docker { }
    Set-ClusterAutostart
    Should -Invoke docker -Times 0 -Exactly
  }
}

# --- diagnose support bundle (mirrors scripts/lib/diagnose.sh) ---------------
Describe "Edit-Redaction" {
  It "redacts clientPassword / proxy creds / token; keeps clientId + NO_PROXY" {
    $f = Join-Path $TestDrive "v.txt"
    @"
clientId: "abc-123"
clientPassword: 'S3cr3tP@ss'
HTTP_PROXY=http://user:s3cr3t@proxy:8080
token: ghp_SECRET
NO_PROXY=localhost,127.0.0.1
"@ | Set-Content $f
    Edit-Redaction $f
    $c = Get-Content $f -Raw
    $c | Should -Not -Match 'S3cr3tP@ss'
    $c | Should -Not -Match 's3cr3t'
    $c | Should -Not -Match 'ghp_SECRET'
    $c | Should -Match 'abc-123'
    $c | Should -Match '127\.0\.0\.1'
  }
  It "redacts any *password key (dockerRegistry password, HTTP_PROXY_PASSWORD)" {
    $f = Join-Path $TestDrive "g.txt"
    @"
dockerRegistry:
  password: dckr_REGTOKEN
HTTP_PROXY_PASSWORD: PROXYPW123
"@ | Set-Content $f
    Edit-Redaction $f
    $c = Get-Content $f -Raw
    $c | Should -Not -Match 'dckr_REGTOKEN'
    $c | Should -Not -Match 'PROXYPW123'
  }
  It "missing file -> no throw" {
    { Edit-Redaction (Join-Path $TestDrive "nope.txt") } | Should -Not -Throw
  }
}

Describe "Invoke-DiagnoseBundle" {
  It "produces a bundle and a seeded secret does NOT survive in it" {
    $HOST_DATA_DIR = Join-Path $TestDrive "tb"
    New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    "clientPassword: 'LEAKME123'" | Set-Content (Join-Path $HOST_DATA_DIR "values.yaml")
    Mock kubectl { "" }; Mock docker { "" }; Mock helm { "" }; Mock k3d { "" }
    Mock Get-WindowsArch { "amd64" }   # avoid the PROCESSOR_ARCHITECTURE Err off-Windows
    { Invoke-DiagnoseBundle } | Should -Not -Throw
    $zip = Get-ChildItem $HOST_DATA_DIR -Filter 'tracebloc-diagnose-*.zip' | Select-Object -First 1
    $zip | Should -Not -BeNullOrEmpty
    $ex = Join-Path $TestDrive "ex"
    Expand-Archive -Path $zip.FullName -DestinationPath $ex -Force
    $all = (Get-ChildItem $ex -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $all | Should -Not -Match 'LEAKME123'
  }
}

# ── Provisioning (#388 — parity with scripts/lib/provision.sh) ───────────────

Describe "Read-TraceblocCredentialFile" {
  It "parses the mint keys, splitting on the FIRST '=' (a password may contain '=')" {
    $f = "$TestDrive/cred.env"
    Set-Content $f "TRACEBLOC_CLIENT_ID=uuid-1`nTRACEBLOC_CLIENT_PASSWORD=p=w=x`nTB_NAMESPACE=lukas-01"
    $c = Read-TraceblocCredentialFile -Path $f
    $c['TRACEBLOC_CLIENT_ID'] | Should -Be "uuid-1"
    $c['TRACEBLOC_CLIENT_PASSWORD'] | Should -Be "p=w=x"
    $c['TB_NAMESPACE'] | Should -Be "lukas-01"
  }
  It "parses the adopt variant (no password, ADOPTED=1)" {
    $f = "$TestDrive/cred2.env"
    Set-Content $f "TRACEBLOC_CLIENT_ID=uuid-2`nTB_NAMESPACE=ws-7`nTRACEBLOC_CLIENT_ADOPTED=1"
    $c = Read-TraceblocCredentialFile -Path $f
    $c['TRACEBLOC_CLIENT_ADOPTED'] | Should -Be "1"
    $c.ContainsKey('TRACEBLOC_CLIENT_PASSWORD') | Should -BeFalse
  }
}

Describe "ConvertTo-SanitizedInput" {
  It "strips CSI sequences (arrow keys) and bracketed-paste markers" {
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "$esc[200~my machine$esc[201~" | Should -Be "my machine"
    ConvertTo-SanitizedInput -Value "na$esc[Dme$esc[1;5C" | Should -Be "name"
  }
  It "self-heals literal paste markers left by an earlier stripper" {
    ConvertTo-SanitizedInput -Value "[200~box[201~" | Should -Be "box"
  }
  It "drops control characters but keeps international letters" {
    ConvertTo-SanitizedInput -Value "b`tox-müller" | Should -Be "box-müller"
  }
  It "empty in, empty out" {
    ConvertTo-SanitizedInput -Value "" | Should -Be ""
  }
}

Describe "Get-ProvisioningPreset" {
  AfterEach { $env:TRACEBLOC_CLIENT_ID = $null; $env:TRACEBLOC_CLIENT_PASSWORD = $null }
  It "true only when BOTH env credentials are set" {
    $env:TRACEBLOC_CLIENT_ID = "x"
    Get-ProvisioningPreset | Should -BeFalse
    $env:TRACEBLOC_CLIENT_PASSWORD = "y"
    Get-ProvisioningPreset | Should -BeTrue
  }
}

Describe "Test-CliProvisioningSupport" {
  It "true when both --help probes pass" {
    Mock Invoke-TraceblocProbe { $true }
    Test-CliProvisioningSupport | Should -BeTrue
  }
  It "false when `client create` is unknown (old CLI)" {
    Mock Invoke-TraceblocProbe { param([string[]]$Args_) -not ($Args_ -contains "create") }
    Test-CliProvisioningSupport | Should -BeFalse
  }
}

Describe "Test-AccountOwnsNamespace" {
  It "owned when the list shows namespace=<ns>" {
    Mock Get-TraceblocClientList { [pscustomobject]@{ Ok = $true; Text = "id=7  name=x  namespace=lukas-01   location=DE" } }
    Test-AccountOwnsNamespace -Ns "lukas-01" | Should -Be "owned"
  }
  It "absent on a prefix (lukas-0 must not match lukas-01)" {
    Mock Get-TraceblocClientList { [pscustomobject]@{ Ok = $true; Text = "namespace=lukas-01 " } }
    Test-AccountOwnsNamespace -Ns "lukas-0" | Should -Be "absent"
  }
  It "unknown when the list can't be read" {
    Mock Get-TraceblocClientList { [pscustomobject]@{ Ok = $false; Text = "" } }
    Test-AccountOwnsNamespace -Ns "x" | Should -Be "unknown"
  }
}

Describe "Print-CreateFailure" {
  It "surfaces the unrecognized-carbon-zone hint with the rejected value" {
    $f = "$TestDrive/create-out.log"
    Set-Content $f 'Error: location: "berlin" is not a valid choice.'
    Mock Warn {}
    Mock Hint {}
    Print-CreateFailure -OutFile $f -Location "berlin"
    Should -Invoke Warn -ParameterFilter { $m -match "carbon zone" }
    Should -Invoke Hint -ParameterFilter { $m -match "TRACEBLOC_CLIENT_LOCATION" }
  }
  It "surfaces backend error lines instead of a generic message" {
    $f = "$TestDrive/create-out2.log"
    Set-Content $f "booting`nError: HTTP 503 from api.tracebloc.io`nmore noise"
    Mock Warn {}
    Mock Hint {}
    Print-CreateFailure -OutFile $f -Location ""
    Should -Invoke Hint -ParameterFilter { $m -match "HTTP 503" }
  }
}

Describe "Invoke-ProvisionClient" {
  # Only the ROUTING is unit-tested here (which TB_PROV_MODE each entry state
  # lands in); the mint/adopt handoff is covered via Install-ClientHelm's
  # minted/adopted-mode tests above.
  BeforeEach { Mock RefreshPath {} }
  AfterEach {
    $script:TB_PROV_MODE = $null; $script:TB_PROV_ID = $null
    $script:TB_PROV_NS = $null; $script:TB_PROV_PASSWORD = $null
    $env:TRACEBLOC_CLIENT_ID = $null; $env:TRACEBLOC_CLIENT_PASSWORD = $null
  }
  It "env preset skips browser sign-in entirely -> mode=preset" {
    $env:TRACEBLOC_CLIENT_ID = "x"; $env:TRACEBLOC_CLIENT_PASSWORD = "y"
    Invoke-ProvisionClient
    $script:TB_PROV_MODE | Should -Be "preset"
  }
  It "missing CLI -> mode=fallback (legacy manual prompts take over)" {
    Mock Has { $false }
    Invoke-ProvisionClient
    $script:TB_PROV_MODE | Should -Be "fallback"
  }
  It "too-old CLI (no login/client create) -> mode=fallback" {
    Mock Has { $true }
    Mock Test-CliProvisioningSupport { $false }
    Invoke-ProvisionClient
    $script:TB_PROV_MODE | Should -Be "fallback"
  }
}

Describe "Get-LeftoverDataDirs (Windows leftover-data detection; Bugbot r3655218480)" {
  # Paths are built with Join-Path / [IO.Path]::Combine so the tests pass under
  # BOTH Windows and Linux pwsh (CI runs Pester on ubuntu too — a hardcoded '\'
  # is a literal char, not a separator, on Linux).
  It "nonexistent HOST_DATA_DIR -> nothing" {
    @(Get-LeftoverDataDirs -Base (Join-Path $TestDrive 'nope')).Count | Should -Be 0
  }
  It "empty dirs / values.yaml are not data" {
    $b = Join-Path $TestDrive 'clean'
    New-Item -ItemType Directory -Path (Join-Path $b 'mysql') -Force | Out-Null   # empty
    New-Item -ItemType Directory -Path (Join-Path $b 'logs')  -Force | Out-Null
    Set-Content (Join-Path $b 'values.yaml') 'x'
    @(Get-LeftoverDataDirs -Base $b).Count | Should -Be 0
  }
  It "flat mysql data detected" {
    $b = Join-Path $TestDrive 'flat'
    New-Item -ItemType Directory -Path (Join-Path $b 'mysql') -Force | Out-Null
    Set-Content ([IO.Path]::Combine($b,'mysql','ibdata1')) 'x'
    @(Get-LeftoverDataDirs -Base $b) | Should -Contain (Join-Path $b 'mysql')
  }
  It "per-release layout detected" {
    $b = Join-Path $TestDrive 'rel'
    New-Item -ItemType Directory -Path ([IO.Path]::Combine($b,'tracebloc','data','ds1')) -Force | Out-Null
    Set-Content ([IO.Path]::Combine($b,'tracebloc','data','ds1','rows.csv')) 'x'
    @(Get-LeftoverDataDirs -Base $b) | Should -Contain ([IO.Path]::Combine($b,'tracebloc','data'))
  }
}

Describe "Invoke-LeftoverDataGuard (Windows leftover-data guard; Bugbot r3655218480)" {
  BeforeEach {
    $script:__up = $env:USERPROFILE
    $env:USERPROFILE = "$TestDrive"                 # so HOST_DATA_DIR under TestDrive passes the wipe path guard
    $env:TB_LEFTOVER_ACTION = $null
    $env:TRACEBLOC_SKIP_LEFTOVER_GUARD = $null
    Mock Warn {}; Mock Hint {}; Mock Log {}; Mock Info {}; Mock Write-Host {}
  }
  AfterEach { $env:USERPROFILE = $script:__up; $env:TB_LEFTOVER_ACTION = $null; $env:TRACEBLOC_SKIP_LEFTOVER_GUARD = $null }

  It "clean slate -> no prompt, returns" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-clean'; New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    Mock Read-Host { throw "should not prompt" }
    { Invoke-LeftoverDataGuard } | Should -Not -Throw
  }
  It "TRACEBLOC_SKIP_LEFTOVER_GUARD bypasses even with data present" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-skip'; $ib = [IO.Path]::Combine($HOST_DATA_DIR,'mysql','ibdata1')
    New-Item -ItemType Directory -Path (Join-Path $HOST_DATA_DIR 'mysql') -Force | Out-Null; Set-Content $ib 'x'
    $env:TRACEBLOC_SKIP_LEFTOVER_GUARD = "1"
    Mock Read-Host { throw "should not prompt" }
    { Invoke-LeftoverDataGuard } | Should -Not -Throw
    $ib | Should -Exist
  }
  It "TB_LEFTOVER_ACTION=reuse keeps data and does not prompt" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-reuse'; $ib = [IO.Path]::Combine($HOST_DATA_DIR,'mysql','ibdata1')
    New-Item -ItemType Directory -Path (Join-Path $HOST_DATA_DIR 'mysql') -Force | Out-Null; Set-Content $ib 'x'
    $env:TB_LEFTOVER_ACTION = "reuse"
    Mock Read-Host { throw "should not prompt" }
    { Invoke-LeftoverDataGuard } | Should -Not -Throw
    $ib | Should -Exist
  }
  It "TB_LEFTOVER_ACTION=wipe removes the leftover data" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-wipe'; $mysql = Join-Path $HOST_DATA_DIR 'mysql'
    New-Item -ItemType Directory -Path $mysql -Force | Out-Null; Set-Content (Join-Path $mysql 'ibdata1') 'x'
    $env:TB_LEFTOVER_ACTION = "wipe"
    Invoke-LeftoverDataGuard
    $mysql | Should -Not -Exist
  }
  It "non-interactive with no action -> aborts (Err), data untouched" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-abort'; $ib = [IO.Path]::Combine($HOST_DATA_DIR,'mysql','ibdata1')
    New-Item -ItemType Directory -Path (Join-Path $HOST_DATA_DIR 'mysql') -Force | Out-Null; Set-Content $ib 'x'
    Mock Test-CanPrompt { $false }
    Mock Err { throw "abort" }
    { Invoke-LeftoverDataGuard } | Should -Throw
    $ib | Should -Exist
  }
  It "interactive 'w' wipes" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-iw'; $mysql = Join-Path $HOST_DATA_DIR 'mysql'
    New-Item -ItemType Directory -Path $mysql -Force | Out-Null; Set-Content (Join-Path $mysql 'ibdata1') 'x'
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "w" }
    Invoke-LeftoverDataGuard
    $mysql | Should -Not -Exist
  }
  It "interactive default (empty) aborts, data untouched" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-ia'; $ib = [IO.Path]::Combine($HOST_DATA_DIR,'mysql','ibdata1')
    New-Item -ItemType Directory -Path (Join-Path $HOST_DATA_DIR 'mysql') -Force | Out-Null; Set-Content $ib 'x'
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "" }
    Mock Err { throw "abort" }
    { Invoke-LeftoverDataGuard } | Should -Throw
    $ib | Should -Exist
  }
  It "wipe unlinks a NESTED reparse point without deleting its target outside HOST_DATA_DIR (Bugbot r3655703571)" {
    $HOST_DATA_DIR = Join-Path $TestDrive 'g-nested'; $mysql = Join-Path $HOST_DATA_DIR 'mysql'
    New-Item -ItemType Directory -Path $mysql -Force | Out-Null; Set-Content (Join-Path $mysql 'ibdata1') 'x'
    # A target OUTSIDE HOST_DATA_DIR whose contents must survive the wipe.
    $outside = Join-Path $TestDrive 'outside-precious'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Set-Content (Join-Path $outside 'precious.dat') 'keep'
    # Plant a nested reparse point inside the leftover mysql dir -> outside.
    $link = Join-Path $mysql 'link'
    try {
      if ($IsWindows) { New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop | Out-Null }
      else            { New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null }
    } catch { Set-ItResult -Skipped -Because "cannot create a reparse point here: $_"; return }
    $env:TB_LEFTOVER_ACTION = "wipe"
    Invoke-LeftoverDataGuard
    $mysql | Should -Not -Exist                                # leftover dir (+ the link entry) gone
    (Join-Path $outside 'precious.dat') | Should -Exist        # target OUTSIDE never followed/deleted
  }
}

Describe "Test-ApiReachable (bounded probe gates helm; Bugbot)" {
  It "API answers within the timeout -> reachable" {
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Test-ApiReachable | Should -BeTrue
  }
  It "API wedged/unreachable (non-zero exit) -> not reachable" {
    Mock kubectl { $global:LASTEXITCODE = 1 }
    Test-ApiReachable | Should -BeFalse
  }
}

Describe "Get-InstalledClientInfo API gating (Bugbot)" {
  It "unreachable API -> degrades to ListUnknown WITHOUT calling helm (no hang)" {
    Mock kubectl { $global:LASTEXITCODE = 1 }     # bounded probe fails
    Mock helm    { $global:LASTEXITCODE = 0 }
    $info = Get-InstalledClientInfo
    $info.ListUnknown | Should -BeTrue
    Should -Not -Invoke helm
  }
  It "reachable API -> enumerates via helm and finds the client" {
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Mock helm {
      if ($args -contains "list") { '[{"name":"rel","namespace":"tracebloc","chart":"client-1.4.4"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get")  { '{"clientId":"acme"}'; $global:LASTEXITCODE = 0; return }
      $global:LASTEXITCODE = 0
    }
    $info = Get-InstalledClientInfo
    $info.Id | Should -Be "acme"
    $info.ListUnknown | Should -BeFalse
    Should -Invoke helm -ParameterFilter { $args -contains "list" }
  }
}

Describe "UNC-safe background jobs (#409)" {
  # Jobs spawn their runspace in $HOME; on roaming-profile machines that is a
  # UNC share and every cmd.exe child prints "UNC paths are not supported" +
  # a RemoteException record. $JobInit pins jobs to a local cwd first.
  It "defines the JobInit initialization scriptblock" {
    $JobInit | Should -Not -BeNullOrEmpty
    $JobInit | Should -BeOfType [scriptblock]
  }

  It "every Start-Job call site passes -InitializationScript (AST gate)" {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      "$PSScriptRoot/../install-k8s.ps1", [ref]$null, [ref]$null)
    $jobCalls = $ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -and
      $node.GetCommandName() -eq 'Start-Job'
    }, $true)
    $jobCalls.Count | Should -BeGreaterThan 0
    foreach ($call in $jobCalls) {
      $call.CommandElements.Where({
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
        $_.ParameterName -eq 'InitializationScript'
      }).Count | Should -Be 1 -Because "Start-Job at line $($call.Extent.StartLineNumber) must pin a local cwd (#409)"
    }
  }

  It "JobInit moves the job to SystemRoot when set, and is a no-op when unset" {
    $prev = $env:SystemRoot
    try {
      $env:SystemRoot = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'sysroot')).FullName
      $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
        (Get-Location).Path -eq (Resolve-Path $env:SystemRoot).Path
      }
      Receive-Job -Job ($job | Wait-Job) | Should -BeTrue
      Remove-Job $job -Force

      $env:SystemRoot = $null
      $job2 = Start-Job -InitializationScript $JobInit -ScriptBlock { "ran" }
      Receive-Job -Job ($job2 | Wait-Job) | Should -Be "ran"
      Remove-Job $job2 -Force
    } finally {
      $env:SystemRoot = $prev
    }
  }
}

Describe "Pinned tool versions - no api.github.com (#382 / #410)" {
  It "pins k3d and helm by default (lockstep with scripts/lib/common.sh)" {
    $K3dVersion  | Should -Be "v5.9.0"
    $HelmVersion | Should -Be "v4.2.3"
  }

  It "the installer never fetches from the rate-limited GitHub API" {
    # Comments may *mention* the API (to say why we avoid it); a URL means a fetch.
    (Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw) | Should -Not -Match 'https://api\.github\.com'
  }

  Context "Test-ReleaseTagShape" {
    It "accepts release tags" {
      Test-ReleaseTagShape "v5.9.0"     | Should -BeTrue
      Test-ReleaseTagShape "v1.2.3-rc1" | Should -BeTrue
    }
    It "rejects traversal, branches, and empties" {
      Test-ReleaseTagShape "v1.2.3-../../heads/main" | Should -BeFalse
      Test-ReleaseTagShape "develop"                 | Should -BeFalse
      Test-ReleaseTagShape "latest"                  | Should -BeFalse
      Test-ReleaseTagShape ""                        | Should -BeFalse
    }
  }

  Context "Resolve-ToolVersion" {
    BeforeEach { Mock Err { throw "ERR: $($args -join ' ')" } }
    It "returns a pinned value without touching the network" {
      Resolve-ToolVersion -Name "k3d" -Value "v5.9.0" -LatestResolver { throw "resolver must not run for a pinned value" } |
        Should -Be "v5.9.0"
    }
    It "resolves the literal 'latest' via the provided API-free resolver" {
      Resolve-ToolVersion -Name "k3d" -Value "latest" -LatestResolver { "v9.9.9" } | Should -Be "v9.9.9"
    }
    It "fails closed when 'latest' cannot be resolved" {
      { Resolve-ToolVersion -Name "helm" -Value "latest" -LatestResolver { $null } } | Should -Throw "*ERR:*"
    }
    It "retries transient lookup failures before giving up (retry 3 5 parity; Bugbot)" {
      Mock Start-Sleep {}
      Mock Warn {}
      $global:TbTestAttempts = 0
      try {
        $resolver = { $global:TbTestAttempts++; if ($global:TbTestAttempts -lt 3) { throw "blip" }; "v7.7.7" }
        Resolve-ToolVersion -Name "k3d" -Value "latest" -LatestResolver $resolver | Should -Be "v7.7.7"
        $global:TbTestAttempts | Should -Be 3
      } finally {
        Remove-Variable -Name TbTestAttempts -Scope Global -ErrorAction SilentlyContinue
      }
    }
    It "fails closed after exhausting retries on a persistently failing lookup" {
      Mock Start-Sleep {}
      Mock Warn {}
      Mock Err { throw "ERR: $($args -join ' ')" }
      $global:TbTestAttempts = 0
      try {
        $resolver = { $global:TbTestAttempts++; throw "down" }
        { Resolve-ToolVersion -Name "helm" -Value "latest" -LatestResolver $resolver } | Should -Throw "*ERR:*"
        $global:TbTestAttempts | Should -Be 3
      } finally {
        Remove-Variable -Name TbTestAttempts -Scope Global -ErrorAction SilentlyContinue
      }
    }
    It "fails closed on a non-release-shaped value" {
      { Resolve-ToolVersion -Name "k3d" -Value "v1.2.3-../../heads/main" -LatestResolver { $null } } | Should -Throw "*ERR:*"
    }
  }

  It "latest lookups carry a request timeout (Bugbot: no-response hosts must not hang)" {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      "$PSScriptRoot/../install-k8s.ps1", [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LatestGitHubTag'
    }, $true) | Select-Object -First 1
    $iwr = $fn.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest'
    }, $true)
    $iwr.Count | Should -BeGreaterThan 0
    foreach ($call in $iwr) {
      $call.CommandElements.Where({
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'TimeoutSec'
      }).Count | Should -Be 1
    }
    # The inline helm resolver too.
    (Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw) |
      Should -Match 'helm-latest-version" -UseBasicParsing -TimeoutSec 30'
  }

  Context "Get-LatestGitHubTag" {
    It "reads the tag from the /releases/latest redirect Location header" {
      Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{ Location = "https://github.com/k3d-io/k3d/releases/tag/v5.9.1" } } }
      Get-LatestGitHubTag -Repo "k3d-io/k3d" | Should -Be "v5.9.1"
    }
    It "returns null when no Location is available" {
      Mock Invoke-WebRequest { [pscustomobject]@{ Headers = @{} } }
      Get-LatestGitHubTag -Repo "k3d-io/k3d" | Should -BeNullOrEmpty
    }
  }
}

Describe "Bounded cluster-create wait (#412 / #426)" {
  Context "Wait-ProcessWithDeadline" {
    It "returns true when the process exits on its own" {
      $proc = [pscustomobject]@{ HasExited = $true }
      Wait-ProcessWithDeadline -Process $proc -Deadline (Get-Date).AddMinutes(1) -Message "x" | Should -BeTrue
    }
    It "kills the process and returns false once the deadline passes" {
      $global:TbTestKilled = $false
      $proc = [pscustomobject]@{ HasExited = $false }
      $proc | Add-Member -MemberType ScriptMethod -Name Kill -Value { $global:TbTestKilled = $true }
      try {
        Wait-ProcessWithDeadline -Process $proc -Deadline (Get-Date).AddMinutes(-1) -Message "x" | Should -BeFalse
        $global:TbTestKilled | Should -BeTrue
      } finally {
        Remove-Variable -Name TbTestKilled -Scope Global -ErrorAction SilentlyContinue
      }
    }
  }

  It "the k3d create spawn fails fast instead of leaving a null process (#412)" {
    $raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $raw | Should -Match '(?s)try \{\s*\$k3dProc = Start-Process.*?-ErrorAction Stop'
  }

  It "the create wait is deadline-bounded — the unbounded HasExited loop is gone" {
    $raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $raw | Should -Match 'Wait-ProcessWithDeadline -Process \$k3dProc'
    $raw | Should -Not -Match 'while \(-not \$k3dProc\.HasExited\)'
  }

  It "the timeout path removes the partial cluster before failing (Bugbot #439)" {
    # Killing k3d mid --wait skips its rollback; without the delete, a re-run
    # adopts the half-created cluster as "already running".
    $raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $raw | Should -Match '(?s)Wait-ProcessWithDeadline -Process \$k3dProc.*?cluster delete \$CLUSTER_NAME.*?timed out after'
  }
}

Describe "Docker engine wait calibration (#413)" {
  BeforeAll { $script:raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "waits 10 minutes by default, overridable via TB_DOCKER_WAIT_MIN" {
    $raw | Should -Match '\$waitMin = 10'
    $raw | Should -Match 'TB_DOCKER_WAIT_MIN'
    $raw | Should -Not -Match '\$maxWait = 60\b'
  }
  It "shows elapsed progress during the wait and names the observed state on expiry" {
    $raw | Should -Match 'min elapsed; a first start can take up to'
    $raw | Should -Match 'Get-Process "Docker Desktop"'
  }
}

Describe "In-node CA trust for TLS-inspecting networks (#424)" {
  Context "Resolve-CaBundle" {
    BeforeEach {
      $env:TRACEBLOC_CA_BUNDLE = $null; $env:CURL_CA_BUNDLE = $null
      Mock Err { throw "ERR: $args" }
    }
    It "returns null when no CA var is set" {
      Resolve-CaBundle | Should -BeNullOrEmpty
    }
    It "returns the path when TRACEBLOC_CA_BUNDLE is set and readable" {
      $ca = Join-Path $TestDrive "ca.pem"; "x" | Set-Content $ca
      $env:TRACEBLOC_CA_BUNDLE = $ca
      Resolve-CaBundle | Should -Be (Resolve-Path $ca).Path
    }
    It "falls back to CURL_CA_BUNDLE" {
      $ca = Join-Path $TestDrive "curlca.pem"; "x" | Set-Content $ca
      $env:CURL_CA_BUNDLE = $ca
      Resolve-CaBundle | Should -Be (Resolve-Path $ca).Path
    }
    It "hard-errors when the CA var is set but the file is missing" {
      $env:TRACEBLOC_CA_BUNDLE = (Join-Path $TestDrive "missing.pem")
      { Resolve-CaBundle } | Should -Throw "*ERR:*"
    }
    It "hard-errors when the CA file exists but is unreadable (matches bash -r; Bugbot #424)" -Skip:($IsWindows) {
      $ca = Join-Path $TestDrive "unreadable.pem"; "x" | Set-Content $ca
      chmod 000 $ca
      $env:TRACEBLOC_CA_BUNDLE = $ca
      try { { Resolve-CaBundle } | Should -Throw "*ERR:*" } finally { chmod 644 $ca }
    }
  }

  Context "Write-K3dRegistriesConfig" {
    It "writes ca_file for every registry" {
      $p = Write-K3dRegistriesConfig -NodeCa "/etc/ssl/certs/tracebloc-mitm-ca.crt"
      try {
        $raw = Get-Content $p -Raw
        $raw | Should -Match 'registry-1\.docker\.io'
        $raw | Should -Match 'auth\.docker\.io'      # Docker Hub token host (Bugbot #424)
        $raw | Should -Match 'ghcr\.io'
        ([regex]::Matches($raw, [regex]::Escape('ca_file: "/etc/ssl/certs/tracebloc-mitm-ca.crt"'))).Count | Should -Be 4
      } finally { Remove-Item (Split-Path $p -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  Context "Get-NotReadyState (CA classification)" {
    It "an x509 pull event -> image_pull_ca" {
      Mock kubectl {
        if ($args -match 'logs')   { return "booting" }
        if ($args -match 'events') { return "Failed to pull image: x509: certificate signed by unknown authority" }
        return "x 0/1 ImagePullBackOff"
      }
      Get-NotReadyState -Namespace "ns" | Should -Be "image_pull_ca"
    }
    It "ImagePullBackOff without x509 stays image_pull" {
      Mock kubectl {
        if ($args -match 'logs')   { return "booting" }
        if ($args -match 'events') { return "Back-off pulling image (rate limited)" }
        return "x 0/1 ImagePullBackOff"
      }
      Get-NotReadyState -Namespace "ns" | Should -Be "image_pull"
    }
    It "x509 on an unrelated event (not the pull) stays image_pull (Bugbot #424)" {
      Mock kubectl {
        if ($args -match 'logs')   { return "booting" }
        if ($args -match 'events') {
          return @(
            'Warning  Failed       pod/x   Back-off pulling image "ghcr.io/x"',
            'Warning  FailedMount  pod/y   MountVolume failed: x509: certificate signed by unknown authority'
          ) -join "`n"
        }
        return "x 0/1 ImagePullBackOff"
      }
      Get-NotReadyState -Namespace "ns" | Should -Be "image_pull"
    }
    It "bounds the events lookup with --request-timeout (matches bash; Bugbot #424)" {
      (Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw) |
        Should -Match 'kubectl get events -n \$Namespace --request-timeout=5s'
    }
  }

  Context "Write-HostCaCreateHint (host daemon x509 at create, #474)" {
    It "no x509 in output -> silent" {
      $out = Write-HostCaCreateHint -Output "FATA Failed to create cluster: docker not running" 6>&1 | Out-String
      $out.Trim() | Should -BeNullOrEmpty
    }
    It "x509 in output -> names the host daemon + Windows trust store" {
      $out = Write-HostCaCreateHint -Output 'Failed to pull image "rancher/k3s": x509: certificate signed by unknown authority' 6>&1 | Out-String
      $out | Should -Match 'HOST Docker daemon'
      $out | Should -Match 'Trusted Root'
    }
    It "the create-timeout path captures full output and surfaces the hint (Bugbot #474 parity)" {
      # The timeout branch can't be exercised end-to-end here, so assert the wiring:
      # it captures the full logs before deleting them and calls the hint before Err
      # (bash runs _host_ca_create_hint on its timeout fall-through too).
      $src = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
      $src | Should -Match '\$timeoutOut\s*\+='                       # full output captured
      $src | Should -Match 'Write-HostCaCreateHint -Output \$timeoutOut'  # hint called on timeout
    }
  }

  Context "Print-Summary CA message" {
    It "names the CA problem + env var, not a generic pull error" {
      $script:ClientState = "image_pull_ca"
      $script:TB_NAMESPACE = "ns"
      $out = Print-Summary 6>&1 | Out-String
      $out | Should -Match 'TLS-inspection CA'
      $out | Should -Match 'TRACEBLOC_CA_BUNDLE'
      $out | Should -Not -Match "an image couldn't be pulled"
    }
  }
}

Describe "Assert-ToolRuns execute-gate (#411)" {
  BeforeEach {
    Mock Err             { throw "ERR: $args" }
    Mock Get-WindowsArch { "amd64" }
  }

  It "passes when the tool runs (exit 0), no throw" {
    Mock k3d { $global:LASTEXITCODE = 0; "k3d version v5.9.0" }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") } | Should -Not -Throw
  }

  It "a non-zero exit -> hard fail (Err)" {
    Mock k3d { $global:LASTEXITCODE = 1; "boom" }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") } | Should -Throw "*ERR:*"
  }

  It "an unrunnable binary (exception) -> hard fail (Err)" {
    Mock k3d { throw "is not a valid application for this OS platform" }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") } | Should -Throw "*ERR:*"
  }

  It "removes the dropped binary on failure when it's the one that ran" {
    Mock k3d { $global:LASTEXITCODE = 1 }
    $bin = Join-Path $TestDrive "k3d.exe"; "x" | Set-Content $bin
    Mock Get-Command { [pscustomobject]@{ Source = $bin } } -ParameterFilter { $Name -eq 'k3d' }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") -BinPath $bin } | Should -Throw
    Test-Path $bin | Should -BeFalse
  }

  It "does NOT remove BinPath when the failing binary resolved elsewhere (winget/present)" {
    Mock k3d { $global:LASTEXITCODE = 1 }
    $bin = Join-Path $TestDrive "k3d.exe"; "x" | Set-Content $bin
    Mock Get-Command { [pscustomobject]@{ Source = "C:\winget\k3d.exe" } } -ParameterFilter { $Name -eq 'k3d' }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") -BinPath $bin } | Should -Throw
    Test-Path $bin | Should -BeTrue      # left alone — it isn't the binary that ran
  }

  It "the arch-aware remedy names the machine architecture" {
    Mock k3d { $global:LASTEXITCODE = 1 }
    { Assert-ToolRuns -Name "k3d" -VersionArgs @("version") } | Should -Throw "*amd64*"
  }
}

Describe "System-tool installs are execute-gated (#411)" {
  BeforeAll { $script:raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "gates kubectl, k3d, and helm" {
    $script:raw | Should -Match 'Assert-ToolRuns -Name "kubectl"'
    $script:raw | Should -Match 'Assert-ToolRuns -Name "k3d"'
    $script:raw | Should -Match 'Assert-ToolRuns -Name "helm"'
  }
  It "no longer masks a broken tool with a non-terminating version Log interpolation" {
    $script:raw | Should -Not -Match 'Log "k3d: \$\('
    $script:raw | Should -Not -Match 'Log "helm: \$\('
  }
}

Describe "Preflight download-host probing (#416)" {
  # Isolate the connectivity section: everything else reports healthy so only the
  # host probes decide the outcome. Err throws so a hard fail is observable.
  BeforeEach {
    $env:TRACEBLOC_SKIP_PREFLIGHT   = $null
    $env:TRACEBLOC_ALLOW_NETWORK_FS = $null
    Mock Get-WindowsArch      { "amd64" }
    Mock Get-PfVirtualization { $true }
    Mock Get-PfCpu            { 8 }
    Mock Get-PfMemGb          { 16 }
    Mock Get-PfFreeGb         { 100 }
    Mock Get-PfFsType         { "local" }
    Mock Get-BackendUrl       { "https://api.tracebloc.io" }
    Mock Err                  { throw "ERR: $args" }
    Mock Test-Path            { $false }   # Docker Desktop absent -> desktop.docker.com probed
  }

  It "auth.docker.io (Docker Hub token host) blocked -> hard fail" {
    Mock Has        { $true }              # all tools present -> only always-critical hosts probed
    Mock Test-PfUrl { param($Url) if ($Url -match 'auth\.docker\.io') { "blocked" } else { "ok" } }
    { Test-Preflight } | Should -Throw "*ERR:*"
  }

  It "kubectl host (dl.k8s.io) blocked -> hard fail when kubectl is absent" {
    Mock Has        { param($cmd) $cmd -ne "kubectl" }
    Mock Test-PfUrl { param($Url) if ($Url -match 'dl\.k8s\.io') { "blocked" } else { "ok" } }
    { Test-Preflight } | Should -Throw "*ERR:*"
  }

  It "k3d asset host (objects.githubusercontent.com) blocked -> hard fail when k3d absent" {
    Mock Has        { param($cmd) $cmd -ne "k3d" }
    Mock Test-PfUrl { param($Url) if ($Url -match 'objects\.githubusercontent\.com') { "blocked" } else { "ok" } }
    { Test-Preflight } | Should -Throw "*ERR:*"
  }

  It "a present tool's host is not probed (no false hard-fail)" {
    Mock Has        { $true }              # kubectl present -> dl.k8s.io never probed
    Mock Test-Path  { $true }              # Docker Desktop present -> desktop.docker.com not probed
    Mock Test-PfUrl { param($Url) if ($Url -match 'dl\.k8s\.io') { "blocked" } else { "ok" } }
    { Test-Preflight } | Should -Not -Throw
  }

  It "all hosts reachable -> preflight passes" {
    Mock Has        { $true }
    Mock Test-PfUrl { "ok" }
    { Test-Preflight } | Should -Not -Throw
  }
}

Describe "Preflight host list — required download hosts present (#416)" {
  BeforeAll { $script:raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "probes every download host the installer fetches from" {
    foreach ($h in 'auth.docker.io','desktop.docker.com','dl.k8s.io','get.helm.sh','github.com','objects.githubusercontent.com') {
      $script:raw | Should -Match ([regex]::Escape($h))
    }
  }
  It "gates tool-download hosts on tool absence (a present tool is not re-probed)" {
    $script:raw | Should -Match 'if \(-not \(Has "kubectl"\)\)'
    $script:raw | Should -Match 'if \(-not \(Has "k3d"\)\)'
  }
}

Describe "GPU container toolkit — progress + honest remedies (#415)" {
  BeforeAll {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      "$PSScriptRoot/../install-k8s.ps1", [ref]$null, [ref]$null)
    $script:gpuFn = $ast.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $n.Name -eq 'Install-NvidiaContainerToolkit'
    }, $true) | Select-Object -First 1
  }

  Context "Wait-JobWithProgress" {
    It "returns true when the job has already completed" {
      $job = [pscustomobject]@{ State = "Completed" }
      Wait-JobWithProgress -Job $job -TimeoutSec 4 -PollSeconds 2 | Should -BeTrue
    }
    It "stops the job and returns false once the timeout elapses" {
      # A real job (Start-Sleep in its own runspace, unaffected by the mock below)
      # so the production Stop-Job path binds and runs for real.
      Mock Start-Sleep {}
      $job = Start-Job -InitializationScript $JobInit -ScriptBlock { Start-Sleep -Seconds 120 }
      try {
        Wait-JobWithProgress -Job $job -TimeoutSec 6 -PollSeconds 2 -Message "x" | Should -BeFalse
        $job.State | Should -BeIn @("Stopped", "Stopping", "Failed")
      } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
      }
    }
    It "polls at most TimeoutSec/PollSeconds times (bounded, never unbounded)" {
      $global:TbSleeps = 0
      Mock Start-Sleep { $global:TbSleeps++ }
      $job = Start-Job -InitializationScript $JobInit -ScriptBlock { Start-Sleep -Seconds 120 }
      try {
        Wait-JobWithProgress -Job $job -TimeoutSec 10 -PollSeconds 2 -Message "x" | Out-Null
        $global:TbSleeps | Should -Be 5
      } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name TbSleeps -Scope Global -ErrorAction SilentlyContinue
      }
    }
  }

  Context "Show-GpuManualRemedy" {
    It "prints copy-pastable remedy commands and a tracebloc doctor follow-up" {
      $out = Show-GpuManualRemedy -Distro "Ubuntu-22.04" 6>&1 | Out-String
      $out | Should -Match 'apt-get install -y nvidia-container-toolkit'
      $out | Should -Match 'nvidia-ctk runtime configure'
      $out | Should -Match 'tracebloc doctor'
      $out | Should -Match 'Ubuntu-22\.04'
    }
    It "is honest that the environment falls back to CPU mode" {
      $out = Show-GpuManualRemedy 6>&1 | Out-String
      $out | Should -Match 'CPU mode'
    }
  }

  Context "Install-NvidiaContainerToolkit" {
    It "no-ops without an NVIDIA GPU (never starts a background job)" {
      $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false
      Mock Start-Job { throw "must not start a job in CPU mode" }
      { Install-NvidiaContainerToolkit } | Should -Not -Throw
    }
    It "announces GPU setup on screen, not only in the log file" {
      # The old flow used Log (file-only) -> a blank console for minutes (#415).
      $script:gpuFn.Extent.Text | Should -Match 'Info "Setting up GPU acceleration'
    }
    It "every long job wait shows a heartbeat — no bare Wait-Job in the GPU flow" {
      ($script:gpuFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-Job'
      }, $true)).Count | Should -Be 0
      ($script:gpuFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-JobWithProgress'
      }, $true)).Count | Should -BeGreaterOrEqual 3
    }
    It "the Ubuntu install runs as a progress-tracked job, not a silent cmd /c" {
      $script:gpuFn.Extent.Text | Should -Not -Match 'cmd /c "wsl --install -d Ubuntu --no-launch 2>&1" \| Out-Null'
      $script:gpuFn.Extent.Text | Should -Match 'Downloading and installing Ubuntu'
    }
    It "every timeout/failure branch hands the user a runnable remedy" {
      ($script:gpuFn.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-GpuManualRemedy'
      }, $true)).Count | Should -BeGreaterOrEqual 3
    }
    It "drops the vague dead-end copy the ticket flagged" {
      $script:gpuFn.Extent.Text | Should -Not -Match 'set it up manually inside WSL later'
      $script:gpuFn.Extent.Text | Should -Not -Match 'GPU setup may need manual attention'
    }
  }
}

Describe "Download UX -- PS 5.1 progress throttle silenced, honest expectation lines (#468)" {
  It "Invoke-WithRetry silences the progress overlay for every fetch scriptblock it drives" {
    (Get-Command Invoke-WithRetry).Definition | Should -Match "ProgressPreference\s*=\s*'SilentlyContinue'"
  }
  It "the Docker Desktop fallback names its ~600 MB wait before the silent fetch" {
    (Get-Command Install-DockerDesktop).Definition | Should -Match 'Downloading Docker Desktop \(~600 MB\)'
  }
  It "the winget bootstrap names its ~200 MB wait" {
    (Get-Command Install-Winget).Definition | Should -Match 'Downloading winget \(~200 MB\)'
  }
  It "kubectl / k3d / helm downloads announce size before going quiet" {
    (Get-Command Install-Kubectl).Definition    | Should -Match 'Downloading kubectl \$kVer \(~60 MB\)'
    (Get-Command Install-K3dAndHelm).Definition | Should -Match 'Downloading k3d \$k3dVer \(~25 MB\)'
    (Get-Command Install-K3dAndHelm).Definition | Should -Match 'Downloading Helm \$helmVer \(~20 MB\)'
  }
}

Describe "Enable-OneVirtFeature -- translated DISM failures, honest reboot flag (#468)" {
  BeforeAll {
    # DISM cmdlets don't exist off-Windows; Pester can only Mock an existing
    # command, so define an advanced-function stub (it must accept -ErrorAction).
    function Enable-WindowsOptionalFeature {
      [CmdletBinding()]
      param([switch]$Online, [string]$FeatureName, [switch]$NoRestart)
    }
  }
  BeforeEach {
    Mock Log  {}
    Mock Warn {}
    Mock Hint {}
  }
  It "already-enabled feature: no DISM call, no reboot demanded" {
    Mock Enable-WindowsOptionalFeature {}
    Enable-OneVirtFeature -Key 'VirtualMachinePlatform' -Label 'VMP' -CurrentState 'Enabled' -Edition 'Pro' |
      Should -BeFalse
    Should -Invoke Enable-WindowsOptionalFeature -Times 0
  }
  It "newly enabled feature: reports reboot-pending" {
    Mock Enable-WindowsOptionalFeature {}
    Enable-OneVirtFeature -Key 'VirtualMachinePlatform' -Label 'VMP' -CurrentState 'Disabled' -Edition 'Pro' |
      Should -BeTrue
  }
  It "feature package ABSENT on this edition (Server SKU): translated skip, no raw COMException, no reboot" {
    Mock Enable-WindowsOptionalFeature { throw [System.Runtime.InteropServices.COMException]::new("0x800f080c") }
    { Enable-OneVirtFeature -Key 'Microsoft-Hyper-V-All' -Label 'Hyper-V' -CurrentState $null -Edition 'Server 2022' } |
      Should -Not -Throw
    Enable-OneVirtFeature -Key 'Microsoft-Hyper-V-All' -Label 'Hyper-V' -CurrentState $null -Edition 'Server 2022' |
      Should -BeFalse
    Should -Invoke Warn -ParameterFilter { $m -like '*not available on this Windows edition*' }
  }
  It "feature present but enable FAILS: translated warning + manual hint, no reboot loop" {
    Mock Enable-WindowsOptionalFeature { throw [System.Runtime.InteropServices.COMException]::new("0x80070005") }
    Enable-OneVirtFeature -Key 'Microsoft-Hyper-V-All' -Label 'Hyper-V' -CurrentState 'Disabled' -Edition 'Pro' |
      Should -BeFalse
    Should -Invoke Warn -ParameterFilter { $m -like 'Could not enable*' }
    Should -Invoke Hint -ParameterFilter { $m -like "*Enable 'Microsoft-Hyper-V-All' manually*" }
  }
}
