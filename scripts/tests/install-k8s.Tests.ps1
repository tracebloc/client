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

  # THE ALIASES (backend#1745). values.schema.json documents
  # development|staging|production as accepted, and the switch knew only
  # dev|stg -- so every alias hit the `default` (prod) branch. Since
  # Get-BackendUrl feeds Test-Credentials, a Windows install with
  # CLIENT_ENV=staging validated STAGING credentials against PRODUCTION and
  # told the customer their correct credentials were wrong.
  #
  # The suite covered dev, stg, unset and "whatever" -- never the spellings
  # the docs tell people to use, which is why the alias branch went untested
  # on both installers.
  It "staging alias -> stg backend, NOT prod" {
    $env:CLIENT_ENV = "staging"; Get-BackendUrl | Should -Be "https://stg-api.tracebloc.io/"
  }
  It "development alias -> dev backend" {
    $env:CLIENT_ENV = "development"; Get-BackendUrl | Should -Be "https://dev-api.tracebloc.io/"
  }
  It "production alias -> prod backend" {
    $env:CLIENT_ENV = "production"; Get-BackendUrl | Should -Be "https://api.tracebloc.io/"
  }
}

Describe "Get-TraceblocClientEnv" {
  AfterEach { $env:CLIENT_ENV = $null }
  It "reduces the documented aliases" {
    Get-TraceblocClientEnv "staging"     | Should -Be "stg"
    Get-TraceblocClientEnv "development" | Should -Be "dev"
    Get-TraceblocClientEnv "production"  | Should -Be "prod"
  }
  It "passes canonical and unknown values through unchanged" {
    # It normalises spellings; it does not validate. Callers keep their own
    # fallback for genuine garbage.
    Get-TraceblocClientEnv "stg"      | Should -Be "stg"
    Get-TraceblocClientEnv "whatever" | Should -Be "whatever"
  }
}

Describe "Daily-user provisioning (#418)" {
  # Get-WslConfigMemoryGb WRITES real config, so it must never emit a budget the
  # client can't run in. It used to do its own arithmetic with a private 4 GB reserve
  # (vs the shared 2) and floor at 1 GB, so an 8 GB host -- perfectly viable -- got
  # memory=4GB, below the client's own floor and a guaranteed OOM crashloop, while
  # the same run advised "give Docker up to 6 GB". It now delegates to
  # Get-PfMemRecommendation, so written budget == advised budget, always.
  It "Get-WslConfigMemoryGb gives an 8 GB host 6 GB, not the OOM-guaranteed 4 (the reported bug)" {
    Get-WslConfigMemoryGb -HostGb 8 | Should -Be 6
    Get-WslConfigMemoryGb -HostGb 8 | Should -Not -Be 4
  }
  It "Get-WslConfigMemoryGb never writes below the client's memory floor" {
    $floor = Get-PfMinMemGb
    foreach ($h in 7,8,9,12,16,32,64) {
      Get-WslConfigMemoryGb -HostGb $h |
        Should -BeGreaterOrEqual $floor -Because "a ${h} GB host can support the floor, so the written budget must clear it"
    }
  }
  It "Get-WslConfigMemoryGb returns 0 (= don't write) when the host can't reach the floor" {
    # physical - reserve < floor: no budget is worth writing. 6 - 2 = 4 < 5.
    Get-WslConfigMemoryGb -HostGb 6 | Should -Be 0
    Get-WslConfigMemoryGb -HostGb 4 | Should -Be 0
    Get-WslConfigMemoryGb -HostGb 2 | Should -Be 0
    Get-WslConfigMemoryGb -HostGb 0 | Should -Be 0
  }
  It "Get-WslConfigMemoryGb never over-commits the host (the OS keeps its reserve)" {
    # The old private 4 GB reserve also erred the OTHER way past the cap: a 32 GB
    # host was handed 28 GB, leaving Windows 4.
    foreach ($h in 7,8,16,32,64) {
      $m = Get-WslConfigMemoryGb -HostGb $h
      $m | Should -BeLessOrEqual ($h - (Get-PfOsReserveGb)) -Because "a ${h} GB host must keep its OS reserve"
    }
    Get-WslConfigMemoryGb -HostGb 32 | Should -Not -Be 28
  }
  It "Get-WslConfigMemoryGb writes exactly what the preflight advises (one reserve, no drift)" {
    foreach ($h in 7,8,12,16,32,64) {
      Get-WslConfigMemoryGb -HostGb $h |
        Should -Be (Get-PfMemRecommendation -DesiredGb (Get-PfRecMemGb) -HostGb $h) `
        -Because "a ${h} GB host must be WRITTEN the same budget it is ADVISED"
    }
  }
  It "Get-WslConfigMemoryGb caps at the recommended training budget on a big host" {
    # No point handing WSL2 more than the client can use to train.
    Get-WslConfigMemoryGb -HostGb 64  | Should -Be (Get-PfRecMemGb)
    Get-WslConfigMemoryGb -HostGb 256 | Should -Be (Get-PfRecMemGb)
  }
  It "Get-WslConfigMemoryGb honours the PF_MIN_MEM_GB floor override" {
    try {
      $env:PF_MIN_MEM_GB = "8"
      Get-WslConfigMemoryGb -HostGb 9  | Should -Be 0   # 9 - 2 = 7 < 8 -> too small
      Get-WslConfigMemoryGb -HostGb 10 | Should -Be 8
    } finally { $env:PF_MIN_MEM_GB = $null }
  }
  It "Get-PfOsReserveGb is the single reserve and fails closed (never 0)" {
    # A 0 reserve would hand WSL2 the entire host; and no caller may pass its own
    # reserve -- the parameter is gone on purpose, so the 4-vs-2 drift can't return.
    Get-PfOsReserveGb | Should -Be 2
    Get-PfOsReserveGb | Should -BeGreaterThan 0
    (Get-Command Get-WslConfigMemoryGb).Parameters.Keys | Should -Not -Contain 'ReserveGb'
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
  It "sizes the budget from the shared recommendation, not its own arithmetic" {
    # The private reserve is what let the written budget drift below the advised one.
    $script:PSRC | Should -Match 'Get-WslConfigMemoryGb[\s\S]{0,600}?Get-PfMemRecommendation'
    $script:PSRC | Should -Not -Match '\$ReserveGb\s*=\s*4'
  }
  It "skips the memory setting entirely on a host too small for the floor (never writes a known-OOM budget)" {
    # The 0 return must gate the write, not be passed through to Add-WslMemorySetting.
    $script:PSRC | Should -Match 'if \(\$memGb -le 0\)'
    $script:PSRC | Should -Match '\.wslconfig memory left unset'
  }
  It "says the machine is too small honestly, with the practical minimum" {
    $script:PSRC | Should -Match 'too little for tracebloc'
    $script:PSRC | Should -Match 'practical minimum'
    $script:PSRC | Should -Match 'Use a larger machine'
  }
  It "notes .wslconfig as a manual step when the write itself throws (no silent catch)" {
    $script:PSRC | Should -Match "couldn't write .wslconfig"
  }
  It "autostarts Docker Desktop for a provisioned DIFFERENT user via a Startup-folder shortcut (#558)" {
    # A different user's hive isn't loaded, so the per-user Run key can't be written
    # for them; a .lnk in THEIR Startup folder is the hive-free equivalent.
    $script:PSRC | Should -Match 'CreateShortcut'
    $script:PSRC | Should -Match 'Start Menu\\Programs\\Startup'
    $script:PSRC | Should -Match 'autostart enabled \(Startup shortcut'
  }
  It "notes autostart as a manual step when the Startup-shortcut path throws (no silent catch) (#558)" {
    # COM/dir/permission failures in the cross-user autostart path must append a
    # manual-step note to $did, mirroring the .wslconfig catch -- otherwise
    # docker-users succeeding prints a green "Configured for" with no autostart note
    # and IT leaves thinking the daily user is ready while Docker Desktop won't launch.
    $script:PSRC | Should -Match "couldn't set Docker Desktop autostart"
    $script:PSRC | Should -Match "Start Docker Desktop when you sign in"
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

# #557 Bugbot (High, CID 3728714531): "absent cluster misclassified as unknown".
# The classifier keys off a FULL `k3d cluster list` (no name filter), so an absent
# cluster is a definite 'down' (a foreign 6550 listener still hard-fails), and only
# a timed-out / failed list is 'unknown' (warn-and-proceed).
Describe "Get-ClusterRunState tri-state (#557 Bugbot 3728714531: absent != unknown)" {
  Context "Get-ClusterRunStateFromList (pure, full 'k3d cluster list' output)" {
    It "named cluster present with >=1 server -> 'running'" {
      Get-ClusterRunStateFromList -Json '[{"name":"tracebloc","serversRunning":1}]' -Name 'tracebloc' | Should -Be 'running'
    }
    It "named cluster present but STOPPED (serversRunning=0) -> 'down'" {
      Get-ClusterRunStateFromList -Json '[{"name":"tracebloc","serversRunning":0}]' -Name 'tracebloc' | Should -Be 'down'
    }
    It "cluster ABSENT from a successful list -> 'down', NOT 'unknown' (the bug)" {
      Get-ClusterRunStateFromList -Json '[{"name":"other","serversRunning":1}]' -Name 'tracebloc' | Should -Be 'down'
    }
    It "empty list [] (no clusters at all) -> 'down'" {
      Get-ClusterRunStateFromList -Json '[]' -Name 'tracebloc' | Should -Be 'down'
    }
    It "empty / unparseable output (k3d itself failed) -> 'unknown'" {
      Get-ClusterRunStateFromList -Json ''          -Name 'tracebloc' | Should -Be 'unknown'
      Get-ClusterRunStateFromList -Json '{not json' -Name 'tracebloc' | Should -Be 'unknown'
    }
  }
  # NOTE: the bounded Get-ClusterRunState wrapper (timeout -> 'unknown',
  # completed -> classify) is intentionally NOT unit-tested here. Mocking the
  # Start-Job / Wait-JobWithProgress / Receive-Job machinery is fragile and
  # environment-dependent (it fails under CI's Pester). Coverage is provided
  # instead by two stable sources: the pure classifier is exercised directly
  # above via Get-ClusterRunStateFromList, and the bounded-job wrapping itself
  # is asserted by the source-of-truth regex guard on Test-ClusterRunning
  # (Start-Job + Wait-JobWithProgress + deadline). See #557 Bugbot 3728714531.
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
    # — and since backend#2268 the same line records that status for the telemetry
    # emitter, because PowerShell gives `finally` no access to an exit's code. Both
    # halves asserted: dropping the assignment would leave the outcome event
    # reporting 0 for a failed install, which is the one wrong answer that looks fine.
    $script:PSRC | Should -Match 'if \(-not \(Test-InstallSucceeded\)\) \{ \$script:TbExitCode = 1; exit 1 \}'
  }
  It "does not leave dead per-step stage checkpoints behind (reviewer: stages dropped)" {
    $script:PSRC | Should -Not -Match "Set-StageComplete"
    $script:PSRC | Should -Not -Match "function Add-CompletedStage"
  }
  It "gates the fast nothing-to-do path on tools + a CURRENT CLI + running cluster + HEALTHY client" {
    # Test-TraceblocCliCurrent is load-bearing here (client#707): Test-ToolsPresent
    # covers docker/kubectl/k3d/helm only, so without it the fast path shortcuts
    # past Install-TraceblocCli and the CLI is never updated — nor even retried on
    # a machine where its (non-fatal) install had failed.
    $script:PSRC | Should -Match '\$script:InstallState\.completed -and \(Test-ToolsPresent\) -and \(Test-TraceblocCliCurrent\) -and \(Test-ClusterRunning\) -and \(Test-ClientHealthy\)'
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
  It "every winget/installer install goes through the capturing wrapper" {
    # k3d-winget was removed in #607: k3d has no winget manifest, so that branch
    # only ever logged "No package found" before the (now resilient) direct
    # download ran. The remaining installs must still go through the wrapper.
    foreach ($tag in 'docker-winget','docker-direct','helm-winget') {
      $script:ISRC | Should -Match "Invoke-TrackedInstall[\s\S]{0,300}-Tag `"$tag`""
    }
  }
  It "no longer runs a k3d winget install (#607: k3d has no winget manifest)" {
    # The comment in install-k8s.ps1 still names Rancher.k3d to explain the removal,
    # so assert on the tracked-install TAG (unique to the actual invocation), not
    # on any mention of the id.
    $script:ISRC | Should -Not -Match '-Tag "k3d-winget"'
    $script:ISRC | Should -Not -Match 'install","-e","--id","Rancher\.k3d"'
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
  It "counts a caller-declared reboot-required code as SUCCESS, preserving the real code (backend#2849)" {
    # Docker Desktop's installer returns 3010 (ERROR_SUCCESS_REBOOT_REQUIRED) when the
    # WSL2 backend adds Windows features -- a COMPLETED install, not a failure. A caller
    # that declares 3010 succeeds must get State 'ok' AND the real code back (not 0), so
    # the reboot-pending outcome stays visible in the log.
    Mock Start-Process { [pscustomobject]@{ ExitCode = 3010; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t" -SuccessExitCodes @(0, 3010)
    $r.State | Should -Be 'ok'; $r.ExitCode | Should -Be 3010
  }
  It "a NULL ExitCode is NOT success -- `-contains` does not invert the null case (backend#2849 / Bugbot)" {
    # PowerShell: `0 -eq $null` is $false and `@(0,3010,...) -contains $null` is $false,
    # so a null code falls through to 'failed' exactly as the old `$p.ExitCode -eq 0`
    # did -- the `-contains` swap does NOT make a missing code read as ok. (#913 makes a
    # real null unlikely by caching .Handle; this pins the guard regardless.)
    Mock Start-Process { [pscustomobject]@{ ExitCode = $null; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t" `
      -SuccessExitCodes (@(0) + $script:INSTALLER_REBOOT_OK_CODES)
    $r.State | Should -Be 'failed'
  }
  It "still FAILS a reboot code the caller did NOT declare (default success set is @(0))" {
    # The broadening is opt-in per caller: without -SuccessExitCodes, 3010 is a failure,
    # so no non-installer caller (k3d, cluster start) silently starts tolerating it.
    Mock Start-Process { [pscustomobject]@{ ExitCode = 3010; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t"
    $r.State | Should -Be 'failed'; $r.ExitCode | Should -Be 3010
  }
  It "the reboot-OK code set is exactly the SUCCESS codes -- and excludes winget's FAILURE reboot code" {
    # Guards against a future 'helpful' addition: 0x8A15010A (-1978334966,
    # REBOOT_REQUIRED_FOR_INSTALL) means the install did NOT complete -- a real failure,
    # not a success -- so it must never be in the accepted set.
    $script:INSTALLER_REBOOT_OK_CODES | Should -Be @(3010, 1641, -1978334967, -1978334965)
    $script:INSTALLER_REBOOT_OK_CODES | Should -Not -Contain -1978334966
  }
  It "the reboot-INITIATED subset is exactly the 'already restarting' codes, and a subset of the OK codes (backend#2849 review)" {
    # 1641 / winget 0x8A15010B mean the installer ALREADY started a reboot; the handler
    # branches on this. 3010 / 0x8A150109 (reboot merely REQUIRED, box still up) must NOT
    # be in this set.
    $script:INSTALLER_REBOOT_INITIATED_CODES | Should -Be @(1641, -1978334965)
    foreach ($c in $script:INSTALLER_REBOOT_INITIATED_CODES) { $script:INSTALLER_REBOOT_OK_CODES | Should -Contain $c }
    $script:INSTALLER_REBOOT_INITIATED_CODES | Should -Not -Contain 3010
    $script:INSTALLER_REBOOT_INITIATED_CODES | Should -Not -Contain -1978334967
  }
  It "an INITIATED reboot arms a FRESH resume and stops via declared exit 2 -- no false handoff claim (backend#2849 / Bugbot)" {
    # Step 1's RunOnce is spent by Step 2, so an installer that already started a reboot
    # must re-arm the resume before the box goes down, else the install can't come back.
    # exit 2 would terminate Pester, so the exit/arm path is asserted on source; the
    # REQUIRED/no-op branches are exercised behaviorally below.
    $fn = [regex]::Match($script:ISRC, 'function Invoke-PostInstallReboot[\s\S]*?\n\}').Value
    $fn | Should -Match 'INSTALLER_REBOOT_INITIATED_CODES -contains \$Result\.ExitCode'
    $fn | Should -Match 'Register-ResumeAfterReboot'   # arm a FRESH resume before the box goes down
    $fn | Should -Match 'Set-TbRerunHandoff'           # declared handoff, not an interruption
    $fn | Should -Match 'exit 2'                       # stop, don't race the reboot into the engine wait
    # the resume promise carries Step 1's split-account caveat (RunOnce is per-hive)
    $fn | Should -Match '\$DailyUser -and \(\$DailyUser -ne \$env:USERNAME\)'
    # BOTH Docker install paths (winget-first and direct) route their result through it,
    # so the handling can't depend on which path ran (the Bugbot gap).
    ([regex]::Matches($script:ISRC, 'Invoke-PostInstallReboot -Result \$r -Label "Docker Desktop"')).Count | Should -BeGreaterOrEqual 2
  }
  It "EVERY installer that accepts the reboot codes routes its result through the handler -- no permissive-without-handler gap (backend#2849 review)" {
    # shujaat's catch: helm-winget opted into the reboot codes but skipped the handler, so
    # a 1641 there would count as success and continue into the direct-download fallback
    # while the box restarts underneath, with no resume armed. The invariant that forecloses
    # this whole class: each -SuccessExitCodes reboot-code site is paired with a handler call.
    $accepts = ([regex]::Matches($script:ISRC, '-SuccessExitCodes \(@\(0\) \+ \$script:INSTALLER_REBOOT_OK_CODES\)')).Count
    $routes  = ([regex]::Matches($script:ISRC, 'Invoke-PostInstallReboot -Result \$r ')).Count
    $accepts | Should -BeGreaterOrEqual 3     # docker-winget, docker-direct, helm-winget
    $routes  | Should -Be $accepts            # one handler call per accepting site
  }
  It "Invoke-PostInstallReboot is a no-op on clean/non-ok and just logs+continues on a REQUIRED reboot (never arms/exits)" {
    # The REQUIRED reboot (box still up) and the 0 / non-ok cases must NOT arm a resume or
    # exit -- only the INITIATED set does. If any of these armed a resume, an ordinary
    # install would strand itself behind a reboot handoff.
    Mock Log { }
    Mock Register-ResumeAfterReboot { $true }
    { Invoke-PostInstallReboot -Result @{ State = 'ok';     ExitCode = 0 }    -Label "X" } | Should -Not -Throw
    { Invoke-PostInstallReboot -Result @{ State = 'failed'; ExitCode = 1 }    -Label "X" } | Should -Not -Throw
    { Invoke-PostInstallReboot -Result @{ State = 'ok';     ExitCode = 3010 } -Label "X" } | Should -Not -Throw
    Should -Invoke Register-ResumeAfterReboot -Times 0
  }
  It "accepts EVERY reboot-OK code end-to-end (not just 3010), including the negative winget HRESULTs" {
    # 3010 above is the headline; this drives all four documented codes -- incl. the
    # Int32-negative winget HRESULTs -1978334967 / -1978334965 -- through the real
    # `-contains` path so a mistyped code or a negative-Int32 comparison regression is
    # caught behaviorally, not just as constant membership.
    Mock Wait-ProcessWithDeadline { $true }
    foreach ($code in $script:INSTALLER_REBOOT_OK_CODES) {
      # Build the mock with the literal interpolated in, so the returned ExitCode is not
      # captured by reference (Pester runs the mock body in a later scope).
      Mock Start-Process ([scriptblock]::Create("[pscustomobject]@{ ExitCode = $code; HasExited = 1 -eq 1 }"))
      $r = Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t" `
        -SuccessExitCodes (@(0) + $script:INSTALLER_REBOOT_OK_CODES)
      $r.State | Should -Be 'ok' -Because "code $code is a documented reboot-pending success"
      $r.ExitCode | Should -Be $code
    }
    # winget REBOOT_REQUIRED_FOR_INSTALL (-1978334966) means the install did NOT complete:
    # it must stay 'failed' even when the installer reboot-OK set is passed.
    Mock Start-Process ([scriptblock]::Create("[pscustomobject]@{ ExitCode = -1978334966; HasExited = 1 -eq 1 }"))
    (Invoke-TrackedInstall -FilePath "x" -ArgumentList @() -Label "t" -Tag "t" `
      -SuccessExitCodes (@(0) + $script:INSTALLER_REBOOT_OK_CODES)).State | Should -Be 'failed'
  }
  It "both Docker install paths opt into the reboot-OK codes so a completed install isn't aborted (backend#2849 finding 1)" {
    # The fatal direct path (docker-direct) and the best-effort winget path both pass the
    # reboot-OK codes. Without this, a 3010 success is misfiled 'failed' and the direct
    # path Errs out on a Docker Desktop that actually installed -- the reopened finding 1.
    $script:ISRC | Should -Match 'Invoke-TrackedInstall -FilePath \$installer[\s\S]{0,400}-SuccessExitCodes \(@\(0\) \+ \$script:INSTALLER_REBOOT_OK_CODES\)'
    $script:ISRC | Should -Match 'Invoke-TrackedInstall -FilePath "winget" -ArgumentList \$wingetArgs[\s\S]{0,400}-SuccessExitCodes \(@\(0\) \+ \$script:INSTALLER_REBOOT_OK_CODES\)'
  }
}

Describe "Format-ExitCode (backend#2849 the exit-code slot is never empty)" {
  # backend#2849: the Windows journey printed "Docker Desktop installation failed
  # (installer exited )" and "wsl exited " -- the ONE number that names the cause,
  # dropped. Format-ExitCode is the guarantee that a failure line can never render a
  # blank code, whatever the captured value.
  It "renders a real code verbatim" {
    Format-ExitCode 0   | Should -Be '0'
    Format-ExitCode 1   | Should -Be '1'
    Format-ExitCode 3   | Should -Be '3'
    Format-ExitCode 137 | Should -Be '137'
    Format-ExitCode -1  | Should -Be '-1'
  }
  It "never returns blank for an absent code ($null / empty / whitespace)" {
    foreach ($code in @($null, '', '   ', "`t")) {
      $out = Format-ExitCode $code
      $out               | Should -Not -Match '^\s*$'     # not empty, not whitespace
      $out               | Should -Be 'with no code reported'
    }
  }
  It "no exit-code value can produce an empty slot in the failure message" {
    # The load-bearing assertion for the acceptance criterion: build the SAME
    # message the installer emits and prove the slot after 'exited ' is never blank,
    # across every value ExitCode can carry (including the $null that shipped).
    foreach ($code in @($null, '', '   ', "`t", 0, 1, 3, 137, -1)) {
      $docker = "Docker Desktop installation failed (installer exited $(Format-ExitCode $code)). Install it manually and re-run."
      $wsl    = "Couldn't update WSL automatically (wsl exited $(Format-ExitCode $code))."
      $docker | Should -Match 'installer exited \S'       # a non-space char follows 'exited '
      $docker | Should -Not -Match 'installer exited \)'  # never the empty "exited )"
      $wsl    | Should -Match 'wsl exited \S'
      $wsl    | Should -Not -Match 'wsl exited \)'
    }
  }
}

Describe "Wait-ProcessWithDeadline exit-code reliability (backend#2849 root cause)" {
  BeforeAll { $script:WSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "caches \$Process.Handle before the wait loop (keeps .ExitCode readable after reap)" {
    # A Start-Process -PassThru process, once reaped, reports a $null ExitCode unless
    # its handle was retained while it was alive. The cache MUST precede the wait loop.
    $script:WSRC | Should -Match 'function Wait-ProcessWithDeadline[\s\S]*\$null = \$Process\.Handle[\s\S]*while \(-not \$Process\.HasExited\)'
  }
  It "actually touches .Handle at runtime" {
    # Behavioral proof, not just a source grep: a fake process that records access.
    $script:handleTouched = $false
    $fake = [pscustomobject]@{ HasExited = $true }
    $fake | Add-Member ScriptProperty Handle { $script:handleTouched = $true; [IntPtr]::Zero }
    $fake | Add-Member ScriptMethod WaitForExit { }
    $fake | Add-Member ScriptMethod Kill { }
    Wait-ProcessWithDeadline -Process $fake -Deadline (Get-Date).AddMinutes(1) -Message "t" 6>$null | Out-Null
    $script:handleTouched | Should -BeTrue
  }
}

Describe "Failure lines route exit codes through Format-ExitCode (backend#2849 no drift)" {
  BeforeAll { $script:FSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the Docker install failure renders via Format-ExitCode" {
    $script:FSRC | Should -Match 'installer exited \$\(Format-ExitCode \$r\.ExitCode\)'
  }
  It "the WSL update failure renders via Format-ExitCode" {
    $script:FSRC | Should -Match 'wsl exited \$\(Format-ExitCode \$r\.ExitCode\)'
  }
  It "no user-facing 'exited' line renders a bare \$r.ExitCode" {
    # If a new call site reintroduces the raw form, this fails and points at it.
    $script:FSRC | Should -Not -Match 'exited \$\(\$r\.ExitCode\)'
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
  # NO REAL PROCESSES (Bugbot, on this PR). Print-Summary reaches Get-ChartVersion,
  # whose `helm list` is bounded now -- and Invoke-BoundedProcess calls
  # [Process]::Start directly, so it does NOT see the suite's `function helm` stub
  # at the top of this file. Two "connected" cases here were therefore spawning the
  # REAL helm against whatever kubeconfig the machine has. Measured against develop:
  # exactly 3 tests in this file gained a real spawn from this PR, and two are here.
  # A Describe-level default covers every case; the ones needing a specific answer
  # override it with their own Mock.
  BeforeEach {
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 0; Output = "" } }
    $script:TB_NAMESPACE = "ns"; $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false
  }
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
    # SEAM MOVED OUT ONE LAYER: Get-ChartVersion's `helm list` is bounded now
    # (backend#2849 / Bugbot), so the mock sits on Invoke-BoundedProcess. Same
    # assertions.
    $script:ClientState = "connected"
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 0; Output = "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4" } }
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "Version"
    $out | Should -Match "1\.4\.4"
    # The mock must actually have INTERCEPTED. If the seam moves again this fails
    # loudly instead of silently shelling out to the real helm (Bugbot).
    Should -Invoke Invoke-BoundedProcess -Times 1 -Exactly
  }
  It "connected: a timed-out helm leaves the version 'unknown' instead of hanging the summary" {
    # Previously unreachable: the bare `helm list` blocked instead of returning, so
    # a wedged API server froze the summary at the very end of a good install.
    $script:ClientState = "connected"
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 124; Output = "" } }
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "unknown"
  }
  It "GPU detected but not enabled: summary says CPU + the reason, not 'NVIDIA GPU' (#616)" {
    $script:ClientState = "connected"
    $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $K3D_GPU_FLAG = ""
    $GPU_SKIP_REASON = "WSL2 Ubuntu needs first-run setup (open Ubuntu once, set a username/password, then re-run)"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "GPU detected but not enabled"
    $out | Should -Match "first-run setup"
  }
  It "GPU wired into the cluster: summary shows NVIDIA GPU (#616)" {
    $script:ClientState = "connected"
    $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $K3D_GPU_FLAG = "--gpus=all"
    $out = Print-Summary 6>&1 | Out-String
    $out | Should -Match "NVIDIA GPU"
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

Describe "Test-TraceblocCliCurrent" {
  # client#707. The fast path gates on Test-ToolsPresent, which covers
  # docker/kubectl/k3d/helm and NOT the CLI — so a stale CLI was invisible and a
  # machine whose CLI install failed (it is non-fatal) was marked completed and
  # never retried. This predicate is what puts the CLI back in that gate, both
  # for presence and for version.

  It "a CLI below the floor is not current -> fast path must fall through" {
    Mock Has { $true }
    Mock tracebloc { "tracebloc 0.5.1 (windows/amd64)" }   # the field version
    Test-TraceblocCliCurrent | Should -BeFalse
  }

  It "a CLI at the floor is current" {
    Mock Has { $true }
    Mock tracebloc { "tracebloc 0.10.0 (windows/amd64)" }
    Test-TraceblocCliCurrent | Should -BeTrue
  }

  It "a CLI above the floor is current" {
    Mock Has { $true }
    Mock tracebloc { "tracebloc 0.10.6 (windows/amd64)" }
    Test-TraceblocCliCurrent | Should -BeTrue
  }

  # 9 vs 10: a string comparison would call 0.9.9 newer than 0.10.0.
  It "orders 0.9.9 below 0.10.0 numerically, not lexically" {
    Mock Has { $true }
    Mock tracebloc { "tracebloc 0.9.9 (windows/amd64)" }
    Test-TraceblocCliCurrent | Should -BeFalse
  }

  # The Windows-only hole: absent entirely, yet `completed` can still be true.
  It "a MISSING CLI is not current -> no longer fast-paths past the install" {
    Mock Has { $false }
    Test-TraceblocCliCurrent | Should -BeFalse
  }

  # Fail OPEN — an unreadable version is not evidence of staleness, and churning
  # a reinstall on every run would be worse than the staleness.
  It "an unreadable version is treated as current (no reinstall churn)" {
    Mock Has { $true }
    Mock tracebloc { "tracebloc (unknown build)" }
    Test-TraceblocCliCurrent | Should -BeTrue
  }

  It "a CLI that errors on 'version' is treated as current" {
    Mock Has { $true }
    Mock tracebloc { throw "boom" }
    Test-TraceblocCliCurrent | Should -BeTrue
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
    # AN OPERATOR IS AT THE TERMINAL for every test in this block -- the
    # fallback-mode ones supply their answers with `Mock Read-Host`, which is
    # only a faithful model of an install that CAN prompt. Under Pester the real
    # Test-CanPrompt is $false (stdin is redirected), so without this the
    # no-terminal refusal added in backend#2675 fires before any of them reach
    # the path they are about. The refusal has its own Describe below, where the
    # non-interactive case is the subject rather than the setup.
    Mock Test-CanPrompt { $true }
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
  It "adopted mode prefers --reset-then-reuse-values when Helm >= 3.14 exposes it (bash parity: new chart defaults reach adopted edges)" {
    # When `helm upgrade --help` advertises --reset-then-reuse-values (Helm >= 3.14),
    # the reconcile must use it so NEW chart defaults land on adopted Windows edges on
    # auto-upgrade — not stay pinned to stored values as plain --reuse-values would.
    $HOST_DATA_DIR = "$TestDrive/d-adopt-reset"
    $script:TB_PROV_MODE = "adopted"; $script:TB_PROV_ID = "uuid-9"; $script:TB_PROV_NS = "lukas-01"
    Mock helm {
      if (($args -contains "upgrade") -and ($args -contains "--help")) { "      --reset-then-reuse-values   reset then reuse"; $global:LASTEXITCODE = 0; return }
      if ($args -contains "list") { '[{"name":"oldrel","namespace":"lukas-01","chart":"client-1.4.3"}]'; $global:LASTEXITCODE = 0; return }
      if ($args -contains "get") {
        if ($args -contains "json") { '{"clientId":"uuid-9"}' } else { 'clientId: uuid-9' }
        $global:LASTEXITCODE = 0; return
      }
      $global:LASTEXITCODE = 0
    }
    Install-ClientHelm
    Should -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "--reset-then-reuse-values") }
    Should -Not -Invoke helm -ParameterFilter { ($args -contains "upgrade") -and ($args -contains "--reuse-values") }
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
  # THE CONTRACT HERE INVERTED, DELIBERATELY (backend#2571, Bugbot #859), and
  # this test used to assert the old one. It read: "values without a clientId
  # key do not trip the guard" -- a readable client release carrying no
  # `clientId` was NOT a client, so the installer proceeded to upgrade over it.
  #
  # That was true only while `clientId` was `required`, which made a clientId-free
  # client release impossible. This chart drops that requirement and tells
  # operators to remove clientId from release values once the Secret holds it, so
  # a live client legitimately has none in values -- and reading it as "not a
  # client" fails OPEN: the one-client guard waves through an install that
  # re-points a machine already running someone else's client.
  #
  # So a client-chart release naming an id in NEITHER values NOR the Secret is
  # now a client that cannot be NAMED, and the guard refuses. `kubectl` is absent
  # (or has no cluster) under Pester, so Get-ClientIdFromSecret returns "" and
  # this exercises the both-places-empty path specifically.
  It "fails CLOSED on a readable client release with no clientId in values or Secret" {
    $HOST_DATA_DIR = "$TestDrive/d5-nokey"
    Mock Err { throw "err" }
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
    { Install-ClientHelm } | Should -Throw
    # NAME THE REFUSAL, don't just count one (CLAUDE.md rule 10). Every other
    # fail-closed path in this Describe also throws, so a bare `Should -Throw`
    # would pass on the WRONG refusal -- an unreadable-values or garbage-list
    # abort would look identical to the one this test is named for.
    Should -Invoke Err -ParameterFilter { $m -match 'unidentifiable existing client' }
    Should -Not -Invoke helm -ParameterFilter { $args -contains "upgrade" }
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
  It "GPU detected but NOT wired into the cluster: jobs request no GPU (#616 CPU fallback)" {
    # The core #616 fix: requesting nvidia.com/gpu while the node advertises 0 GPUs strands every
    # job Pending until the SINGLE_NODE fallback rescues it. So when the GPU wasn't enabled
    # ($K3D_GPU_FLAG empty) the values must carry NO gpu request — training runs on CPU cleanly.
    $HOST_DATA_DIR = "$TestDrive/d-gpu-skip"
    $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-g1"
    $script:TB_PROV_PASSWORD = "pw"; $script:TB_PROV_NS = "ws-g1"
    $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $K3D_GPU_FLAG = ""
    Mock Read-Host { throw "must not prompt" }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    $vals = Get-Content "$HOST_DATA_DIR/values.yaml" -Raw
    $vals | Should -Match 'GPU_REQUESTS: ""'
    $vals | Should -Match 'GPU_LIMITS: ""'
    $vals | Should -Not -Match 'nvidia\.com/gpu'
    $vals | Should -Match 'RUNTIME_CLASS_NAME: ""'
  }
  It "GPU wired into the cluster: jobs request nvidia.com/gpu (#616)" {
    $HOST_DATA_DIR = "$TestDrive/d-gpu-on"
    $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-g2"
    $script:TB_PROV_PASSWORD = "pw"; $script:TB_PROV_NS = "ws-g2"
    $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $K3D_GPU_FLAG = "--gpus=all"
    Mock Read-Host { throw "must not prompt" }
    Mock Test-Credentials { "valid" }
    Install-ClientHelm
    $vals = Get-Content "$HOST_DATA_DIR/values.yaml" -Raw
    $vals | Should -Match 'GPU_REQUESTS: "nvidia\.com/gpu=1"'
    $vals | Should -Match 'GPU_LIMITS: "nvidia\.com/gpu=1"'
    $vals | Should -Match 'RUNTIME_CLASS_NAME: "nvidia"'
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
  # CHANGED BEHAVIOR (backend#2220). This asserted that a 2c/4Gi machine gets
  # "cpu=2,memory=8Gi" -- an envelope LARGER than the machine, on which no
  # training pod can ever schedule. That was the bug, pinned as if it were the
  # contract. It now gets the honest remainder, which fits.
  #
  # The old expectation is not lost: "unreadable cluster falls back to the static
  # default" just below still covers the case where the literal IS right, because
  # we genuinely cannot see the machine. Cannot-see vs too-small is the whole
  # distinction this change introduces; they used to be the same answer.
  It "below-floor machine gets the honest remainder, not an unschedulable literal" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 0; @("2 4Gi") }
    Get-TrainingResources | Should -Be "cpu=1,memory=1Gi"
  }
  It "unreadable cluster falls back to the contract floor" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
  }
}

Describe "Envelope contract golden vectors (backend#2220)" {
  # The PowerShell side of the ticket's definition of done, mirroring the bats
  # suite's replay. The arithmetic has ONE definition — client-runtime's
  # node_sizing.envelope_from_allocatable — and this file cannot call it, so it
  # proves it still AGREES with it by replaying the contract's golden vectors
  # through the real Get-TrainingResources.
  #
  # Unlike bats, PowerShell HAS a JSON parser, so this reads the vendored
  # contract directly rather than the flattened bash table. Same source, two
  # readers: if the two disagree, one of them has drifted.

  BeforeAll {
    $script:ContractPath = Join-Path $PSScriptRoot "fixtures/envelope_contract.json"
    $script:Contract = Get-Content $script:ContractPath -Raw | ConvertFrom-Json
  }
  BeforeEach {
    $script:TB_NAMESPACE = "tracebloc"
    $env:TRACEBLOC_TRAINING_RESOURCES = $null
    # backend#2220: Get-TrainingResources SETS these, so they must be cleared
    # between tests or a previous undersized case would leak a $true into the
    # next assertion. Folded into this Describe's ONE BeforeEach -- Pester 6
    # allows only one per block.
    $script:TbTrainingUndersized    = $false
    $script:TbTrainingUnschedulable = $false
  }
  AfterEach  { $env:TRACEBLOC_TRAINING_RESOURCES = $null }

  It "the vendored contract is readable and carries vectors" {
    $script:Contract.contract_version | Should -BeGreaterOrEqual 1
    @($script:Contract.vectors.single_node).Count | Should -BeGreaterThan 0
  }

  It "the embedded constants match the vendored contract" {
    # The one that catches a hand-edit to the generated block above
    # Get-TrainingResources. scripts/gen-envelope-embed.sh is the authority;
    # this is the in-suite mirror so a PowerShell-only reviewer sees it too.
    $script:TbEnvelopeContractVersion  | Should -Be $script:Contract.contract_version
    $script:TbEnvelopeOverheadCpuMilli | Should -Be $script:Contract.overhead.cpu_millicores
    $script:TbEnvelopeOverheadMemBytes | Should -Be $script:Contract.overhead.memory_bytes
    $script:TbEnvelopeFloorCpuMilli    | Should -Be $script:Contract.floor.cpu_millicores
    $script:TbEnvelopeFloorMemBytes    | Should -Be $script:Contract.floor.memory_bytes
    # backend#2221 -- the VM beneath the node containers.
    $script:TbEnvelopeVmReserveMemBytes | Should -Be $script:Contract.vm_reserve.memory_bytes
    $script:TbEnvelopeNodeMinCpuMilli   | Should -Be $script:Contract.topology.per_node_minimum.cpu_millicores
    $script:TbEnvelopeNodeMinMemBytes   | Should -Be $script:Contract.topology.per_node_minimum.memory_bytes
  }

  It "every single-node golden vector replays" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    $failures = @()
    foreach ($v in $script:Contract.vectors.single_node) {
      # What the installer must PRINT for this vector (backend#2220):
      #
      #   unparseable        -> the literal. We cannot read the machine, so the
      #                         historical default is the best available answer.
      #   viable             -> the contract's rendering.
      #   below the floor    -> the contract's rendering ANYWAY, as long as it is
      #                         a requestable shape (>= 1 core and >= 1 GiB).
      #                         It fits; the literal would not.
      #   below even that    -> the literal, because cpu=0 is not a request.
      #
      # This used to collapse every non-viable vector onto the literal, which is
      # what let the sub-8GiB bug live inside a passing replay. Now the
      # non-viable vectors are checked against the contract's own numbers, so
      # the installer and the accessor agree on the small machines too.
      $rendered = if ($null -ne $v.expected) {
        "cpu=$($v.expected.render_gi.cpu),memory=$($v.expected.render_gi.memory)"
      } else { $null }
      # The fallback for an unreadable/sub-requestable vector is the contract
      # FLOOR since backend#2254 (was cpu=2,memory=8Gi). Derived from the vendored
      # contract, not hardcoded, so it cannot drift from the floor the installer
      # actually writes.
      $floor = "cpu=$([math]::Floor($script:Contract.floor.cpu_millicores / 1000)),memory=$([math]::Floor($script:Contract.floor.memory_bytes / 1GB))Gi"
      $want = if ($null -eq $v.expected) {
        $floor
      } elseif ($v.expected.viable) {
        $rendered
      } elseif ([int]$v.expected.render_gi.cpu -ge 1 -and
                [int]($v.expected.render_gi.memory -replace 'Gi$','') -ge 1) {
        $rendered
      } else {
        $floor
      }
      $line = "$($v.allocatable_cpu) $($v.allocatable_memory)"
      Mock kubectl {
        if ($args -contains "--request-timeout=10s") {
          $global:LASTEXITCODE = 0; @($line)
        } else { $global:LASTEXITCODE = 1; "" }
      }.GetNewClosure()
      $got = Get-TrainingResources
      if ($got -ne $want) {
        $failures += "$($v.label) ($line): want '$want' got '$got'"
      }
    }
    $failures -join "`n" | Should -BeNullOrEmpty
  }

  It "every MULTI-NODE golden vector replays (incl. the cordoned one)" {
    # backend#2237. Until this existed the ps1 replayed only vectors.single_node,
    # so the contract's multi_node block -- the ANCHOR_LARGEST selection rule,
    # and one-cordoned-out with it -- was asserted on the bash side ONLY. The
    # bats twin has replayed these all along; PowerShell simply never read them,
    # which is how the ps1 could ignore spec.unschedulable while its suite was
    # entirely green.
    #
    # Node lines are built from the contract's OWN node list, cordoned entries
    # included, because the skip is the code's job to apply. The generator used
    # to pre-filter them for the bash table and that is exactly what made the
    # cordoned vector inert; rebuilding the filter here would reproduce the bug
    # in the other language.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    @($script:Contract.vectors.multi_node).Count | Should -BeGreaterThan 0

    $failures = @()
    foreach ($v in $script:Contract.vectors.multi_node) {
      # The three fields kubectl's jsonpath emits. Unschedulable is omitempty,
      # so a live node contributes an empty third field.
      $nodeLines = @(
        foreach ($n in $v.nodes) {
          $flag = if ($n.unschedulable) { "true" } else { "" }
          "$($n.cpu) $($n.memory) $flag"
        }
      )
      $exp  = $v.anchored.largest.expected
      $want = "cpu=$($exp.render_gi.cpu),memory=$($exp.render_gi.memory)"

      $script:TbTrainingUndersized    = $false
      $script:TbTrainingUnschedulable = $false
      Mock kubectl {
        if ($args -contains "--request-timeout=10s") {
          $global:LASTEXITCODE = 0; $nodeLines
        } else { $global:LASTEXITCODE = 1; "" }
      }.GetNewClosure()

      $got = Get-TrainingResources
      if ($got -ne $want) {
        $failures += "$($v.label) [$($nodeLines -join ' | ')]: want '$want' got '$got'"
      }
    }
    $failures -join "`n" | Should -BeNullOrEmpty
  }

  It "a cordoned node never takes the anchor, whichever node it is" {
    # The named regression for backend#2237, kept separate from the replay above
    # so the failure says WHAT broke rather than which golden row moved.
    #
    # Both directions on purpose: a filter that simply dropped the largest node
    # would satisfy the first assertion and be completely wrong. The second
    # pins that a cordoned SMALL node changes nothing.
    Mock helm { $global:LASTEXITCODE = 1; "" }

    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("16 64Gi true", "4 16Gi ")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=3,memory=13Gi"

    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("16 64Gi ", "4 16Gi true")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=15,memory=61Gi"
  }

  It "every node cordoned reads as UNMEASURED, not as too small" {
    # The fail-safe direction. A fully-cordoned cluster must take the same
    # branch as an unreadable one -- keep the literal, set no warning flags.
    # Reporting `undersized` here would tell an operator their hardware is too
    # small when the real cause is a cordon they can undo in one command.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("16 64Gi true", "8 32Gi true")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    [bool]$script:TbTrainingUndersized    | Should -BeFalse
    [bool]$script:TbTrainingUnschedulable | Should -BeFalse
  }

  It "an explicit 'false' third field is schedulable, not cordoned" {
    # Value-domain check (backend#1729 rule 6): Unschedulable is omitempty so the
    # field is normally absent or 'true', but keying on non-emptiness instead of
    # on 'true' would make an API server that serialises `false` drop every node
    # from sizing -- silent and total.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("8 32Gi false")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=29Gi"
  }

  It "ANCHOR_LARGEST ties break on cpu, not memory — and the bash twin agrees" {
    # The divergence backend#2220 closes: this function ranked nodes
    # (memory, cpu) and would have anchored on 4c/32Gi here, while cli's
    # nodeLarger ranked (cpu, memory) and anchored on 8c/16Gi. Same cluster,
    # two answers, neither chosen. One order now, matching bash and cli.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("8 16Gi", "4 32Gi")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=13Gi"
  }

  It "the answer does not depend on the order the API listed nodes in" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("4 32Gi", "8 16Gi")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=13Gi"
  }

  # Bugbot #766, second pass. The contract's skipped_nodes says allocatable that
  # will not parse is SKIPPED; the bash twin does that with an explicit
  # `|| continue`. This function used to coerce an unparseable quantity to 0 and
  # then RANK the node, which the old memory-first order hid — a memB of 0 could
  # never win. Ranking on cpu first exposes it: a node with a good CPU count and
  # a memory unit we do not speak wins the anchor, fails the memory floor, and
  # drops the whole machine to the literal even though a sibling node was
  # perfectly sizeable. BYO/heterogeneous clusters only; k3d never hits it.
  # ── provenance (backend#2220) ──────────────────────────────────────────────
  # Get-TrainingProvenance mirrors Get-TrainingResources' precedence rather than
  # calling it, so these pin that the mirror stays honest on EVERY branch. A
  # wrong verdict here either strands an edge forever or silently overrules a
  # human, which is the defect scope bullet 4 is about.

  # The fail-unsafe case Bugbot found and @saadqbal confirmed on #768: the two
  # resolvers each did their own `helm get values` behind their own bare
  # `catch {}`, so a size read that succeeded and carried a live RESOURCE_LIMITS
  # while the provenance read then threw pinned that carried envelope as
  # `installer` -- inviting a future ladder to overrule a human choice. One
  # shared lookup makes it structurally impossible; these pin that.
  It "provenance: a failing values read can never report 'installer' for a CARRIED size" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    # helm succeeds for the size probe but returns junk the parse chokes on.
    Mock helm { $global:LASTEXITCODE = 0; "{ this is : not json" }
    # Both must agree on NOT having carried anything: the read failed, so the
    # size is machine-derived (or the literal) and `installer` is then correct.
    $carried = Get-CarriedTrainingValues
    $carried | Should -BeNullOrEmpty
    Get-TrainingProvenance | Should -Be "installer"
  }

  It "provenance: size and provenance come from ONE lookup and cannot disagree" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi","RESOURCE_PROVENANCE":"user"}}'
    }
    $carried = Get-CarriedTrainingValues
    $carried.Size       | Should -Be "cpu=4,memory=12Gi"
    $carried.Provenance | Should -Be "user"
    # Handed the SAME lookup, as the values generation does.
    Get-TrainingResources  -Carried $carried -CarriedResolved | Should -Be "cpu=4,memory=12Gi"
    Get-TrainingProvenance -Carried $carried -CarriedResolved | Should -Be "user"
  }

  It "provenance: the shared lookup ignores the historic literal as a non-choice" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=2,memory=8Gi","RESOURCE_PROVENANCE":"user"}}'
    }
    # The literal was the ABSENCE of a choice, so there is nothing to carry --
    # even with a marker sitting next to it.
    Get-CarriedTrainingValues | Should -BeNullOrEmpty
  }

  It "provenance: an unreadable namespace carries nothing (and does not throw)" {
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Get-CarriedTrainingValues | Should -BeNullOrEmpty
    Get-TrainingProvenance | Should -Be "installer"
  }

  It "provenance: a fresh machine-sized install is the installer's choice" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") { $global:LASTEXITCODE = 0; @("8 32Gi") }
      else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources  | Should -Be "cpu=7,memory=29Gi"
    Get-TrainingProvenance | Should -Be "installer"
  }

  It "provenance: an install-time override is a human choice" {
    $env:TRACEBLOC_TRAINING_RESOURCES = "cpu=4,memory=16Gi"
    try {
      Get-TrainingResources  | Should -Be "cpu=4,memory=16Gi"
      Get-TrainingProvenance | Should -Be "user"
    } finally { $env:TRACEBLOC_TRAINING_RESOURCES = $null }
  }

  It "provenance: a carried-forward value with no marker is 'unknown'" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi"}}'
    }
    Get-TrainingResources  | Should -Be "cpu=4,memory=12Gi"
    Get-TrainingProvenance | Should -Be "unknown"
  }

  It "provenance: an existing 'user' marker SURVIVES re-install" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi","RESOURCE_PROVENANCE":"user"}}'
    }
    Get-TrainingProvenance | Should -Be "user"
  }

  It "provenance: an existing 'installer' marker survives re-install" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi","RESOURCE_PROVENANCE":"installer"}}'
    }
    Get-TrainingProvenance | Should -Be "installer"
  }

  It "provenance: a junk marker degrades to 'unknown', never to a guess" {
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi","RESOURCE_PROVENANCE":"banana"}}'
    }
    Get-TrainingProvenance | Should -Be "unknown"
  }

  It "provenance: the static-default fallback is still the installer's choice" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Get-TrainingResources  | Should -Be "cpu=1,memory=2Gi"
    Get-TrainingProvenance | Should -Be "installer"
  }

  # ── undersized machines (backend#2220) ─────────────────────────────────────
  # This used to return cpu=2,memory=8Gi for a machine with ~4 GiB allocatable —
  # an envelope larger than the machine, on which no pod can ever schedule. The
  # Windows memory preflight only WARNS (Linux hard-fails), so this installer
  # reaches exactly those machines.

  It "undersized: a below-floor machine gets the honest remainder, not the literal" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") { $global:LASTEXITCODE = 0; @("2 4Gi") }
      else { $global:LASTEXITCODE = 1; "" }
    }
    # 4 GiB - 3 GiB = 1 GiB, below the 2 GiB floor but still a requestable shape.
    Get-TrainingResources | Should -Be "cpu=1,memory=1Gi"
    $script:TbTrainingUndersized | Should -BeTrue
    $script:TbTrainingUnschedulable | Should -BeFalse
  }

  It "undersized: a machine too small for even 1c/1Gi keeps the literal and flags it" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") { $global:LASTEXITCODE = 0; @("500m 512Mi") }
      else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    $script:TbTrainingUnschedulable | Should -BeTrue
    $script:TbTrainingUndersized | Should -BeFalse
  }

  It "undersized: an UNREADABLE cluster keeps the literal and flags NOTHING" {
    # The distinction that makes this change safe: cannot-see is not too-small.
    # With no readable node the literal is still the best available answer, and
    # warning about machine size would be a fabrication.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    $script:TbTrainingUndersized | Should -BeFalse
    $script:TbTrainingUnschedulable | Should -BeFalse
  }

  It "undersized: a viable machine flags nothing" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") { $global:LASTEXITCODE = 0; @("8 32Gi") }
      else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=29Gi"
    $script:TbTrainingUndersized | Should -BeFalse
    $script:TbTrainingUnschedulable | Should -BeFalse
  }

  It "a node with unparseable memory does not beat a valid one" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        # 16 cores but a memory unit neither installer parses, alongside a
        # perfectly good 8c/32Gi node. The valid node must win.
        $global:LASTEXITCODE = 0; @("16 64GB", "8 32Gi")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=29Gi"
  }

  It "a node with unparseable cpu does not beat a valid one" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("sixteen 64Gi", "8 32Gi")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=29Gi"
  }

  It "every node unparseable falls through to the literal" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("sixteen 64GB", "eight lots")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
  }
}

Describe "Sizing-probe failures reach the install log (client#771)" {
  # The bare `catch {}` on the sizing path swallowed two real defects into a
  # plausible-looking default -- the Int32 [math]::Max overload throw
  # (client#766: EVERY machine over ~2 GiB of headroom silently got the
  # literal) and a provenance read landing a wrong verdict (client#768). The
  # bounded degradation is deliberate and stays; these pin that it can no
  # longer be SILENT. Expected absence -- no namespace, no release, an
  # unreadable cluster -- must stay quiet, because it happens on every fresh
  # install and a warning there would be noise that trains people to ignore
  # the real one.
  BeforeEach {
    $script:TB_NAMESPACE = "tracebloc"
    $env:TRACEBLOC_TRAINING_RESOURCES = $null
    Mock Log { }
  }
  AfterEach  { $env:TRACEBLOC_TRAINING_RESOURCES = $null }

  It "a sizing probe that throws logs the exception AND still returns the bounded default" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") { throw "kubectl exploded mid-probe" }
      $global:LASTEXITCODE = 1; ""
    }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    Should -Invoke Log -Times 1 -Exactly -ParameterFilter {
      $m -match 'Get-TrainingResources' -and $m -match 'kubectl exploded mid-probe'
    }
  }

  It "a carried-values read that throws logs the exception AND still carries nothing" {
    # The client#768 shape: helm answers, the parse chokes. The $null return is
    # asserted elsewhere ("a failing values read can never report 'installer'");
    # this pins that the choke is no longer invisible.
    Mock kubectl { $global:LASTEXITCODE = 0; "" }
    Mock helm { $global:LASTEXITCODE = 0; "{ this is : not json" }
    Get-CarriedTrainingValues | Should -BeNullOrEmpty
    Should -Invoke Log -Times 1 -Exactly -ParameterFilter {
      $m -match 'Get-CarriedTrainingValues'
    }
  }

  It "EXPECTED absence stays quiet: an unreadable namespace logs nothing" {
    Mock kubectl { $global:LASTEXITCODE = 1; "" }
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Get-CarriedTrainingValues | Should -BeNullOrEmpty
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    Should -Not -Invoke Log
  }

  It "EXPECTED absence stays quiet: unparseable node quantities log nothing" {
    # Unparseable allocatable is contract-SKIPPED (`continue`), not an
    # exception -- the fall-through to the literal here is the code working as
    # specified, so it must not cry wolf in the install log.
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0; @("sixteen 64GB")
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=1,memory=2Gi"
    Should -Not -Invoke Log
  }

  It "the logged degradation still returns the size the values generation needs" {
    # The whole-path guarantee client#766's replay relies on: even with BOTH
    # probes throwing, values generation gets a usable size string -- logged
    # loudly, degraded boundedly, never $null and never a hang.
    Mock kubectl { throw "everything is on fire" }
    Mock helm { throw "helm too" }
    $carried = Get-CarriedTrainingValues
    $carried | Should -BeNullOrEmpty
    Get-TrainingResources -Carried $carried -CarriedResolved | Should -Be "cpu=1,memory=2Gi"
    Get-TrainingProvenance -Carried $carried -CarriedResolved | Should -Be "installer"
    Should -Invoke Log -ParameterFilter { $m -match 'WARN' }
  }
}

Describe "Topology contract golden vectors (backend#2221)" {
  # The PowerShell half of the topology parity. scripts/tests/
  # install-client-helm.bats replays the SAME contract rows through the bash
  # twin _honest_topology, so a row added upstream forces both languages to
  # answer it -- and both return a STRING, so the two are compared
  # byte-for-byte rather than through two different shapes.
  #
  # Get-HonestTopology is pure arithmetic over two numbers: no docker, no
  # kubectl, no branching on cluster state. So the contract vectors are the
  # right parity mechanism for it. (installer_parity.json exists for CONTROL
  # FLOW -- every backend#2220 divergence lived in a state that was not a clean
  # measurement. The eventual CALLER of this function belongs there, because it
  # will shell out to docker and branch; the arithmetic itself does neither.)

  BeforeAll {
    $script:TopologyContract =
      Get-Content (Join-Path $PSScriptRoot "fixtures/envelope_contract.json") -Raw |
      ConvertFrom-Json
  }

  It "the vendored contract carries topology vectors" {
    @($script:TopologyContract.vectors.topology).Count | Should -BeGreaterThan 0
  }

  It "per_node_minimum is overhead + floor, not a fourth constant" {
    # Recorded in the contract so this file and its bash twin can embed it
    # without doing arithmetic on JSON -- but DERIVED. A recorded derivation
    # nobody checks is just a fourth constant waiting to rot, which is the
    # duplication backend#2220 spent seven PRs deleting. The generator refuses a
    # stale one; this is the in-suite mirror.
    $c = $script:TopologyContract
    $c.topology.per_node_minimum.cpu_millicores |
      Should -Be ($c.overhead.cpu_millicores + $c.floor.cpu_millicores)
    $c.topology.per_node_minimum.memory_bytes |
      Should -Be ($c.overhead.memory_bytes + $c.floor.memory_bytes)
  }

  It "every topology golden vector replays" {
    $failures = @()
    foreach ($v in $script:TopologyContract.vectors.topology) {
      # $null expected means the VM was unreadable -- "I cannot answer", which a
      # caller must never read as one node.
      $want = if ($null -eq $v.expected) {
        $null
      } else {
        "nodes=$($v.expected.nodes),cap=$($v.expected.node_memory_cap_bytes)," +
        "cpu_honest=$([int][bool]$v.expected.cpu_honest),viable=$([int][bool]$v.expected.viable)"
      }
      $got = Get-HonestTopology -VmCpu $v.vm_cpu -VmMemory $v.vm_memory `
                                -RequestedNodes ([int]$v.requested_nodes)
      if ($got -ne $want) {
        $failures += "$($v.label): want '$want' got '$got'"
      }
    }
    $failures -join "`n" | Should -BeNullOrEmpty
  }

  It "an unreadable VM returns null, not a default topology" {
    Get-HonestTopology -VmCpu "eight" -VmMemory "lots" -RequestedNodes 2 |
      Should -BeNullOrEmpty
  }

  It "fewer than one requested node is refused" {
    # A caller bug, not a machine state. The bash twin exits non-zero with no
    # output for the same input.
    Get-HonestTopology -VmCpu "8" -VmMemory "17179869184" -RequestedNodes 0 |
      Should -BeNullOrEmpty
  }

  It "nodes x cap never exceeds the usable VM" {
    # The invariant the whole ticket exists to establish, as a property across
    # VM sizes rather than on the hand-picked rows above. Uncapped k3d violates
    # sum(node capacity) <= VM by exactly the node count; nothing this function
    # recommends may.
    $failures = @()
    foreach ($gib in 4, 5, 6, 7, 8, 11, 12, 16, 24, 32, 48, 64) {
      $bytes  = [long]$gib * 1GB
      $usable = [long][math]::Max([long]0, $bytes - $script:TbEnvelopeVmReserveMemBytes)
      foreach ($req in 1, 2, 3, 4, 8) {
        $got = Get-HonestTopology -VmCpu "16" -VmMemory "$bytes" -RequestedNodes $req
        if ($null -eq $got) { $failures += "${gib}GiB/${req}: unexpected null"; continue }
        $nodes = [long]($got -replace '^nodes=(\d+),.*$', '$1')
        $cap   = [long]($got -replace '^.*,cap=(\d+),.*$', '$1')
        if (($nodes * $cap) -gt $usable) {
          $failures += "${gib}GiB/${req}: $nodes x $cap > $usable usable"
        }
        if ($nodes -lt 1 -or $nodes -gt $req) {
          $failures += "${gib}GiB/${req}: $nodes nodes out of range"
        }
      }
    }
    $failures -join "`n" | Should -BeNullOrEmpty
  }

  It "a stock macOS Docker VM cannot host the shipped two-node default" {
    # The measured case, and the reason this is not a future multi-node
    # concern: the client defaults to SERVERS=1 AGENTS=1, so every CPU-only
    # edge asks for exactly this and cannot have it.
    Get-HonestTopology -VmCpu "10" -VmMemory "8321712128" -RequestedNodes 2 |
      Should -Be "nodes=1,cap=7247970304,cpu_honest=1,viable=1"
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

# Invoke-BoundedProcess hands back stdout+stderr concatenated, so the anchor check has to
# pick the context out of it. A whole-blob compare hard-stops a correctly switched install
# the moment kubectl warns on stderr (Bugbot) — bash gets this for free with `2>/dev/null`.
Describe "Get-CurrentContextFromOutput (client#732 Bugbot: stderr must not fail a good install)" {
  It "returns the context when kubectl is quiet" {
    Get-CurrentContextFromOutput -Output "k3d-tracebloc`n" | Should -Be "k3d-tracebloc"
  }
  It "ignores stderr noise that FOLLOWS the context (the concatenation order)" {
    $out = "k3d-tracebloc`nW0817 10:00:00 warning: plugin ... is deprecated`n"
    Get-CurrentContextFromOutput -Output $out | Should -Be "k3d-tracebloc"
  }
  It "survives CRLF and leading blank lines" {
    Get-CurrentContextFromOutput -Output "`r`n  k3d-tracebloc  `r`nnoise`r`n" | Should -Be "k3d-tracebloc"
  }
  It "returns empty for empty/whitespace-only output -- 'couldn't tell' is not a pass" {
    Get-CurrentContextFromOutput -Output ""        | Should -Be ""
    Get-CurrentContextFromOutput -Output "  `r`n "  | Should -Be ""
  }
  It "does NOT invent a match from a warning that merely mentions the context" {
    # stderr-only output (kubectl printed nothing on stdout) must not read as anchored
    $out = "error: no current context; run 'kubectl config use-context k3d-tracebloc'"
    Get-CurrentContextFromOutput -Output $out | Should -Not -Be "k3d-tracebloc"
  }
}

# --- Releasing the dashboard record before deleting the cluster (backend#2077) ---
#
# This machine's backend record is anchored to the CLUSTER's identity (the
# kube-system namespace UID), which dies with the k3d cluster. So a bare
# `k3d cluster delete` strands the secure environment on the dashboard for good --
# and the installer used to print exactly that at every recreate remedy.
Describe "Write-RecreateClusterHint (backend#2077)" {
  BeforeEach { $script:CLUSTER_NAME = "tracebloc"; $script:LOG_FILE = $null }
  It "names 'tracebloc delete' BEFORE the k3d delete (the order is the fix)" {
    $out = (Write-RecreateClusterHint 6>&1 | Out-String)
    $out | Should -Match 'tracebloc delete --keep-data'
    $out | Should -Match 'k3d cluster delete tracebloc'
    ($out -split 'k3d cluster delete')[0] | Should -Match 'tracebloc delete --keep-data'
  }
  It "never recommends a BARE 'tracebloc delete' -- the plain form wipes the data these sites keep" {
    $out = (Write-RecreateClusterHint 6>&1 | Out-String)
    ([regex]::Matches($out, 'tracebloc delete')).Count |
      Should -Be ([regex]::Matches($out, 'tracebloc delete --keep-data')).Count
  }
  It "tells a machine with nothing installed that it can skip the release" {
    $out = (Write-RecreateClusterHint 6>&1 | Out-String)
    $out | Should -Match 'nothing installed on this machine yet'
  }
  It "puts the re-run prefix on the k3d line, not a line of its own" {
    $out = (Write-RecreateClusterHint -RerunPrefix "TB_STORAGE_MODE=node-local  " 6>&1 | Out-String)
    $out | Should -Match 'k3d cluster delete tracebloc  \(then TB_STORAGE_MODE=node-local  re-run this installer\)\.'
  }
}

# Derived from the source, not from a hand-kept list: a recreate hint added later
# with its own `Hint "  k3d cluster delete ..."` line strands a record exactly like
# the ones this replaced. Scoped to the recreate sites this PR owns -- the peers of
# cluster.sh's seven -- so it names offenders rather than counting them.
Describe "Recreate hints route through Write-RecreateClusterHint (backend#2077 source guards)" {
  BeforeAll { $script:PSRC2 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the k3s-version drift remedy releases the record first" {
    $script:PSRC2 | Should -Match "not the validated pin[\s\S]{0,600}?Write-RecreateClusterHint"
  }
  It "the 0.0.0.0-bind rebuild remedy releases the record first" {
    $script:PSRC2 | Should -Match "binds its API to 0\.0\.0\.0[\s\S]{0,900}?Write-RecreateClusterHint"
  }
  It "the CA-drift remedy releases the record first" {
    $script:PSRC2 | Should -Match "was created without it[\s\S]{0,600}?Write-RecreateClusterHint"
  }
  It "the dataset-mount remedy releases the record first" {
    $script:PSRC2 | Should -Match "no /tracebloc-data bind mount[\s\S]{0,600}?Write-RecreateClusterHint"
  }
  It "the GPU-capability remedies release the record first" {
    $script:PSRC2 | Should -Match "is CPU-only[\s\S]{0,600}?Write-RecreateClusterHint"
    $script:PSRC2 | Should -Match "GPU experiments will stay Pending[\s\S]{0,600}?Write-RecreateClusterHint"
  }
  It "the helper's own line is the ONLY recreate command hint left, and it follows CLUSTER_NAME" {
    # Derived: any site that grows its own `Hint "  k3d cluster delete ... (then ...`
    # is named here rather than counted. The helper's line is the one carrying
    # $RerunPrefix, which is how it excludes itself without an allowlist of names.
    $offenders = @(Select-String -Path "$PSScriptRoot/../install-k8s.ps1" `
                     -Pattern 'Hint\s+"\s+k3d cluster delete \$CLUSTER_NAME\s+\(then' |
                   Where-Object { $_.Line -notmatch 'RerunPrefix' } |
                   ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" })
    $offenders -join "`n" | Should -BeNullOrEmpty
  }
}

# --- The kubeconfig merge is load-bearing, not cosmetic (client#732) ---
#
# The installer passes no --kubeconfig/--context to `tracebloc client create`, so
# the secure environment is registered against kubectl's CURRENT context. The merge
# used to be piped to Out-Null with $LASTEXITCODE never read, so a failure left the
# previous context selected and the install anchored this machine to it.
Describe "Kubeconfig merge is checked, and the anchor verified (client#732 source guards)" {
  BeforeAll { $script:PSRC3 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "no longer discards the merge result into Out-Null" {
    $script:PSRC3 | Should -Not -Match 'k3d kubeconfig merge \$CLUSTER_NAME[^\r\n]*\| Out-Null'
  }
  It "merges into the DEFAULT kubeconfig -- without it the gate below proves nothing (Bugbot)" {
    # k3d writes a standalone ~/.k3d/kubeconfig-<cluster>.yaml unless told otherwise,
    # so a merge lacking this flag never touches the file kubectl reads.
    $fn = (($script:PSRC3 -split 'function New-K3dCluster')[1] -split '\nfunction ')[0]
    $fn | Should -Match '"kubeconfig",\s*"merge",\s*\$CLUSTER_NAME,\s*"--kubeconfig-merge-default",\s*"--kubeconfig-switch-context"'
    # ...and the remedy it prints has to be the same command, or it can't repair it
    $fn | Should -Match '\$mergeCmd\s*=\s*"k3d kubeconfig merge \$CLUSTER_NAME --kubeconfig-merge-default --kubeconfig-switch-context"'
  }
  It "reads the merge's exit code and stops the install on failure" {
    $script:PSRC3 | Should -Match '\$merge\s*=\s*Invoke-BoundedProcess[\s\S]{0,400}?\$merge\.Code -ne 0'
    $script:PSRC3 | Should -Match 'refusing to continue against an unknown cluster'
  }
  It "bounds BOTH external calls, like the bash peer (installer rule)" {
    $fn = (($script:PSRC3 -split 'function New-K3dCluster')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'Invoke-BoundedProcess -FileName "k3d" -TimeoutSec 60'
    $fn | Should -Match 'Invoke-BoundedProcess -FileName "kubectl" -Arguments @\("config", "current-context"\) -TimeoutSec 10'
    $fn | Should -Not -Match '\n\s*kubectl config current-context'   # never the unbounded native call
  }
  It "verifies the current context IS this cluster, and says how to select it" {
    $script:PSRC3 | Should -Match '\$wantCtx\s*=\s*"k3d-\$CLUSTER_NAME"'
    $script:PSRC3 | Should -Match 'kubectl config use-context \$wantCtx'
  }
  It "treats an unreadable current-context as a failure, not as agreement" {
    $script:PSRC3 | Should -Match "can't tell us which context is current"
  }
  It "reads the context through the stderr-tolerant parser, never the raw merged blob (Bugbot)" {
    $fn = (($script:PSRC3 -split 'function New-K3dCluster')[1] -split '\nfunction ')[0]
    $fn | Should -Match '\$haveCtx = Get-CurrentContextFromOutput -Output "\$\(\$ctx\.Output\)"'
  }
  It "normalizes the kubeconfig k3d actually wrote, not a hardcoded profile path" {
    # --kubeconfig-merge-default honours $KUBECONFIG; the rewrite has to follow it or
    # it silently edits a file k3d never touched (peer of bash's ${KUBECONFIG%%:*}).
    $script:PSRC3 | Should -Match '\$kubeConfigPath = if \(\$env:KUBECONFIG\) \{ \(\$env:KUBECONFIG -split .;.\)\[0\] \}'
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
  # #557: port-6550 conflict detection.
  It "Get-PfPortListening: a bound listener -> true" {
    Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort = 6550; State = 'Listen' } }
    Get-PfPortListening 6550 | Should -Be $true
  }
  It "Get-PfPortListening: no listener (empty result) -> false" {
    Mock Get-NetTCPConnection { }
    Get-PfPortListening 6550 | Should -Be $false
  }
  It "Get-PfPortListening: no listener (ObjectNotFound throw) -> false (#557)" {
    # Real Get-NetTCPConnection THROWS an ObjectNotFound error when nothing matches
    # the filter; -ErrorAction Stop routes it to the catch, which reads it as free.
    Mock Get-NetTCPConnection { throw "CmdletizationQuery_NotFound_LocalPort" }
    Get-PfPortListening 6550 | Should -Be $false
  }
  It "Get-PfPortListening: a genuine probe error -> null, never fails open (#557 Bugbot)" {
    # A real CIM/access failure must NOT be conflated with a free port -- the old
    # -ErrorAction SilentlyContinue swallowed it into an empty (= free) result.
    Mock Get-NetTCPConnection { throw "CIM server is unavailable" }
    Get-PfPortListening 6550 | Should -Be $null
  }
}

Describe "Test-Preflight" {
  BeforeEach {
    Mock Err { throw "preflight-failed" }      # Err exits; make it throwable to assert
    Mock Get-PfCpu { 4 }; Mock Get-PfMemGb { 8 }; Mock Get-PfFreeGb { 50 }
    Mock Get-WindowsArch { "amd64" }
    Mock Get-PfFsType { "local" }
    Mock Get-PfVirtualization { $true }
    Mock Get-PfPortListening { $false }   # #557: default to port 6550 free
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
  # #557: port 6550 bound by something that is NOT our cluster -> hard fail with
  # an actionable message, instead of k3d's raw stderr at cluster-create.
  It "port 6550 in use by a foreign process (no k3d) -> fails (Err throws) (#557)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfPortListening { $true }
    Mock Has { $false }   # no k3d (nor any tool) -> the listener can't be our cluster
    { Test-Preflight } | Should -Throw
  }
  # #557 Bugbot (Med): a STOPPED leftover cluster named $CLUSTER_NAME plus a
  # foreign listener on 6550 must still hard-fail -- ownership is gated on the
  # cluster actually RUNNING ('running'), not mere presence. Get-ClusterRunState
  # returns 'down' for a present-but-stopped (or absent) cluster.
  It "port 6550 busy + our cluster present but STOPPED -> fails (Err throws) (#557)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfPortListening { $true }
    Mock Has { $true }                     # k3d present, so run-state is consulted
    Mock Get-ClusterRunState { 'down' }    # enumerated: ours is stopped/absent -> foreign listener
    { Test-Preflight } | Should -Throw
  }
  # #557: port 6550 held by OUR own running cluster -> reused, not a conflict.
  # Ownership passes here, so Test-Preflight continues into the
  # network-reachability block (which also calls Has for kubectl/helm/k3d); a
  # plain default Has mock (all tools present -> only always-critical hosts
  # probed) covers every call and keeps that block from throwing.
  It "port 6550 in use by our running cluster -> ok, does not throw (#557)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfPortListening { $true }
    Mock Has { $true }
    Mock Get-ClusterRunState { 'running' }
    { Test-Preflight } | Should -Not -Throw
  }
  # #557 Bugbot (Med, CID 3728340365): a slow/wedged Docker can make
  # `k3d cluster list` time out (Get-ClusterRunState -> 'unknown'). That is
  # "can't determine", NOT "confidently foreign" -- a normal re-run of an
  # existing install must NOT be hard-blocked with stop/delete hints. Downgrade
  # to a warning and proceed; New-K3dCluster's start/repair path settles it.
  It "port 6550 busy + cluster run-state indeterminate (list timed out) -> warns, does NOT hard-fail (#557 Bugbot)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfPortListening { $true }
    Mock Has { $true }                       # k3d present, but...
    Mock Get-ClusterRunState { 'unknown' }   # ...the bounded list timed out / was unreadable
    { Test-Preflight } | Should -Not -Throw
    $out = (Test-Preflight 6>&1 | Out-String)
    $out | Should -Match "run-state couldn't be determined"   # warned, not hard-failed
    $out | Should -Not -Match 'will be reused'                # and not misreported as ours
  }
  It "port 6550 listener state undeterminable -> skipped, not a fail (#557)" {
    Mock Test-PfUrl { "ok" }
    Mock Get-PfPortListening { $null }
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
  # THE SEAM MOVED, THE ASSERTIONS DID NOT (backend#2849). These readers used to
  # invoke `docker` natively; they now go through Invoke-DockerCli so the call
  # carries a deadline (a bare `docker info` against a wedged daemon blocks rather
  # than failing, and these run at the top of Step 3). Every case below still
  # asserts the same behaviour -- prefer the runtime view, fall back to null on
  # junk or on a dead daemon -- just mocked one layer out.
  It "Get-PfRuntimeMemGb follows the docker MemTotal (#417)" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = '8589934592' } }   # 8 GiB, in bytes
    Get-PfRuntimeMemGb | Should -Be 8
  }
  It "Get-PfMemGb never consults the Docker VM budget (#417 no flip-flop)" {
    # Host-independent + cross-platform: the flip-flop bug was Get-PfMemGb reading
    # the docker budget. Prove it's decoupled by asserting Get-PfMemGb never asks
    # docker at all. Avoids the flaky "Should -Not -Be 8" on a real 8 GB host; the
    # exact host figure is locked by the Windows-gated CIM-mocked sibling test.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = '8589934592' } }
    $null = Get-PfMemGb
    Should -Invoke Invoke-DockerCli -Times 0
  }
  It "Get-PfCpu prefers docker NCPU over the host" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = '2' } }
    Get-PfCpu | Should -Be 2
  }
  It "Get-PfRuntimeMemGb: junk value -> null (forces host fallback)" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = 'lots' } }
    Get-PfRuntimeMemGb | Should -BeNullOrEmpty
  }
  It "Get-PfRuntimeMemGb: docker errors -> null" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 1; Output = 'daemon down' } }
    Get-PfRuntimeMemGb | Should -BeNullOrEmpty
  }
  It "Get-PfRuntimeMemGb: a TIMED-OUT probe -> null, not a hang (backend#2849)" {
    # The case that did not exist before: the reader used to have no way to time
    # out, so this state was unreachable and untested. 124 is the timeout code
    # Invoke-BoundedProcess returns.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = 'docker info timed out after 20s' } }
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

Describe "Memory thresholds are single-sourced (#417/#418 no-drift guard)" {
  BeforeAll { $script:PSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  # The 4-vs-2 reserve drift that wrote a sub-floor .wslconfig (#418) and the
  # sub-floor advice (#417) both came from paths re-deriving these numbers locally.
  # Each threshold must now have exactly ONE read site: its accessor.
  It "each PF_* threshold is read on exactly one line -- its accessor" {
    # Count LINES, not occurrences: an accessor names its var twice on one line
    # (the truthiness test and the [int] cast). Two read SITES would be two lines.
    $lines = Get-Content "$PSScriptRoot/../install-k8s.ps1"
    foreach ($v in 'PF_MIN_MEM_GB','PF_WARN_MEM_GB','PF_REC_MEM_GB','PF_VM_MEM_GRACE_MIB') {
      @($lines | Where-Object { $_ -match [regex]::Escape("env:$v") }).Count |
        Should -Be 1 -Because "$v must be read only by its Get-Pf* accessor"
    }
  }
  It "the OS reserve is read only by its accessor (plus its own definition)" {
    # 3 = the `$script:PfOsReserveGb = 2` assignment + the two reads in Get-PfOsReserveGb.
    ([regex]::Matches($script:PSRC, [regex]::Escape('$script:PfOsReserveGb'))).Count |
      Should -Be 3 -Because 'callers must use Get-PfOsReserveGb, not the raw variable'
  }
  It "the accessors agree with the documented defaults" {
    Get-PfMinMemGb | Should -Be 5
    Get-PfWarnMemGb | Should -Be 8
    Get-PfRecMemGb | Should -Be 16
    Get-PfOsReserveGb | Should -Be 2
  }
  It "the advice path and the .wslconfig write path cannot disagree" {
    # The whole point of the accessors: one machine, one number. A host that can
    # reach the floor is WRITTEN exactly what it is ADVISED; one that cannot is
    # written nothing at all.
    foreach ($h in 7,8,12,16,32,64) {
      Get-WslConfigMemoryGb -HostGb $h |
        Should -Be (Get-PfMemRecommendation -DesiredGb (Get-PfRecMemGb) -HostGb $h) -Because "host=$h GB"
    }
    foreach ($h in 2,4,6) { Get-WslConfigMemoryGb -HostGb $h | Should -Be 0 -Because "host=$h GB can't reach the floor" }
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
  # Without naming the OS reserve, a 6 GB host reads "you have 6, you need 5, get a
  # bigger machine" — self-contradictory (Bugbot). State the reserve and the
  # resulting practical minimum, as bash's _pf_recheck_runtime_mem does.
  It "names the OS reserve and the practical minimum, so the shortfall adds up" {
    $out = (Show-MemoryStatus -HostGb 6 -BudgetGb 3 6>&1 | Out-String)
    $out | Should -Match 'the OS needs ~2 GB'
    $out | Should -Match '7 GB physical is the practical minimum'
  }
  It "the arithmetic is reserve-aware for every too-small host (5 and 6 GB both explained)" {
    foreach ($h in 4..6) {
      $out = (Show-MemoryStatus -HostGb $h -BudgetGb 2 6>&1 | Out-String)
      $out | Should -Match 'too little for tracebloc'
      $out | Should -Match 'practical minimum'
    }
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

  # Bugbot: hostTooSmall was only consulted in the below-floor branch, so a 5-6 GB
  # host with Docker DOWN graded as "enough to run" and the TRAINING hint printed
  # memory=5GB — leaving the OS 1 GB, a budget this same function calls
  # unachievable two branches up.
  It "a too-small host with Docker down gets no training resize number" {
    $out = (Show-MemoryStatus -HostGb 6 -BudgetGb $null 6>&1 | Out-String)
    $out | Should -Match 'too little to train locally'
    $out | Should -Match 'train on a larger machine'
    $out | Should -Not -Match 'memory=5GB'
    $out | Should -Not -Match 'give Docker up to'
  }
  It "a host that CAN reach the floor still gets the training recommendation" {
    # 16 GB host, 6 GB budget: between floor and warn, and 16 - 2 >= 5 so the
    # machine is genuinely tunable -> keep the actionable number.
    $out = (Show-MemoryStatus -HostGb 16 -BudgetGb 6 6>&1 | Out-String)
    $out | Should -Match 'give Docker up to 14 GB'
    $out | Should -Match 'memory=14GB'
    $out | Should -Not -Match 'larger machine'
  }
  # The invariant that closes this class of bug for good: across EVERY branch and
  # every budget shape, a host that cannot reach the floor while keeping the OS
  # reserve must never be handed a concrete memory= value to write.
  It "no branch emits a concrete memory= value for a host that cannot reach the floor" {
    foreach ($h in 1..6) {                     # 6 - 2 reserve = 4 < 5 floor
      foreach ($b in @($null, 1, 2, 3, 4, 5, 6)) {
        $out = (Show-MemoryStatus -HostGb $h -BudgetGb $b 6>&1 | Out-String)
        $out | Should -Not -Match 'memory=\d+GB' -Because "host=$h budget=$b must not print a writable budget"
      }
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

Describe "Test-PreflightRuntimeMem (post-Docker: enforces the floor)" {
  # Windows used to only WARN here while bash HARD-FAILS on every OS
  # (_pf_recheck_runtime_mem -> error -> exit 1, #513) -- so the platform this whole
  # memory story is about was the one still shipping the OOM-crashloop. Budgets are
  # mocked in MiB: the gate needs sub-GB precision (see Get-PfRuntimeMemMib).
  BeforeEach { Mock Err { throw "runtime-mem-failed" } }   # Err exits; make it assertable
  AfterEach  { $env:TRACEBLOC_SKIP_PREFLIGHT = $null }

  It "a genuinely sub-floor VM (4 GB) HARD-FAILS instead of proceeding to crashloop" {
    Mock Get-PfRuntimeMemMib { 4096 }; Mock Get-PfMemGb { 16 }
    { Test-PreflightRuntimeMem } | Should -Throw
  }
  It "a VM at the documented floor still passes despite the guest shortfall (grace band)" {
    # 5 GB configured reports ~4.8 GB (guest kernel + reserved). Failing that would
    # make the effective floor a GB higher than we document (#513 reviewer).
    Mock Get-PfRuntimeMemMib { 4800 }; Mock Get-PfMemGb { 16 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "and is NOT told it will OOM — the grade and the gate agree (Bugbot)" {
    # floor(4800/1024) = 4 would have printed hard-floor "it will OOM" copy for a
    # machine the gate accepts: told a correctly configured box it would crash, then
    # carried on. The grade folds in the same grace, so it reports the configured 5 GB.
    Mock Err { }
    Mock Get-PfRuntimeMemMib { 4800 }; Mock Get-PfMemGb { 16 }
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Not -Match 'it will OOM'
    $out | Should -Not -Match 'OOM-crashloop'
    $out | Should -Match "Docker's current share: 5 GB"   # the configured size
    $out | Should -Match 'training'                       # the honest warn band
  }
  It "the grade boundary and the gate boundary are the SAME boundary" {
    # The property that makes the contradiction impossible rather than merely absent:
    # at every MiB either BOTH say sub-floor (fail + OOM copy) or NEITHER does.
    Mock Err { }
    Mock Get-PfMemGb { 16 }
    foreach ($m in 4096, 4607, 4608, 4800, 5120) {
      Mock Get-PfRuntimeMemMib -MockWith { $m }.GetNewClosure()
      $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
      $saysSubFloor = $out -match 'it will OOM|OOM-crashloop'
      $gateFails    = $m -lt ((Get-PfMinMemGb) * 1024 - (Get-PfVmMemGraceMib))
      $saysSubFloor | Should -Be $gateFails -Because "at $m MiB the copy and the gate must agree"
    }
  }
  It "the grace band is bounded — just under it still fails" {
    Mock Get-PfMemGb { 16 }
    Mock Get-PfRuntimeMemMib { 4607 }        # floor 5*1024 - 512 grace = 4608
    { Test-PreflightRuntimeMem } | Should -Throw
    Mock Get-PfRuntimeMemMib { 4608 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "daemon not reporting (null) -> no-op, does not throw" {
    Mock Get-PfRuntimeMemMib { $null }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "a between-floor-and-warn budget still only warns (it can run, just tightly)" {
    Mock Get-PfRuntimeMemMib { 7168 }; Mock Get-PfMemGb { 15 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "grades the budget with both floors and caps the rec at host RAM (#417 reviewer)" {
    Mock Get-PfRuntimeMemMib { 7168 }   # 7 GB — in the training-warn band
    Mock Get-PfMemGb { 15 }             # host -> cap the rec at 13 GB
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Match '13 GB recommended'
    $out | Should -Not -Match '16 GB recommended'
    $out | Should -Match "Docker's current share: 7 GB"
  }
  # Message-content tests let Err return instead of throwing, so the function runs to
  # completion and every line it prints is capturable. The exit itself is asserted by
  # the hard-fail tests above.
  It "sub-floor on a BIG host -> an achievable resize target, clamped to the host" {
    Mock Err { }
    Mock Get-PfRuntimeMemMib { 2048 }; Mock Get-PfMemGb { 15 }
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Match 'OOM-crashloop'
    $out | Should -Match 'wslconfig'
    # min(warn target 8, host ceiling 15-2=13) = 8 — same as bash's clamped warn
    # target. The point is that it FITS the host, not that it equals the ceiling.
    $out | Should -Match 'memory=8GB'
    $out | Should -Not -Match 'larger machine'   # this host CAN be fixed
  }
  It "sub-floor because the HOST is too small -> 'larger machine', no resize number" {
    # 6 - 2 reserve = 4 < 5: no Docker setting fixes it, so don't repeat an
    # unachievable size (mirrors the #428 bash branch + Show-MemoryStatus's copy).
    Mock Err { }
    Mock Get-PfRuntimeMemMib { 3072 }; Mock Get-PfMemGb { 6 }
    $out = (Test-PreflightRuntimeMem 6>&1 | Out-String)
    $out | Should -Match 'practical minimum'
    $out | Should -Match 'larger machine'
    $out | Should -Not -Match 'memory=\d+GB'
  }
  It "host RAM unreadable + sub-floor -> still fails, with a raw (uncapped) target" {
    Mock Get-PfRuntimeMemMib { 2048 }; Mock Get-PfMemGb { $null }
    { Test-PreflightRuntimeMem } | Should -Throw
  }
  It "TRACEBLOC_SKIP_PREFLIGHT overrides the hard fail (documented escape hatch)" {
    $env:TRACEBLOC_SKIP_PREFLIGHT = "1"
    Mock Get-PfRuntimeMemMib { 1024 }; Mock Get-PfMemGb { 16 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "reads the budget ONCE so the printed and enforced numbers can't disagree" {
    Mock Get-PfRuntimeMemMib { 7168 }; Mock Get-PfMemGb { 16 }
    Test-PreflightRuntimeMem 6>&1 | Out-Null
    Should -Invoke Get-PfRuntimeMemMib -Exactly -Times 1
  }
}

Describe "Windows/bash memory-floor enforcement parity (#513)" {
  BeforeAll {
    $script:PSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $script:BSRC = Get-Content "$PSScriptRoot/../lib/preflight.sh" -Raw
  }
  It "bash hard-fails a sub-floor VM in its runtime recheck" {
    # The behaviour Windows is matching. If bash ever softens this, the two
    # installers have diverged again and this guard should be revisited.
    $bashRecheck = [regex]::Match($script:BSRC, '(?s)_pf_recheck_runtime_mem\(\)\s*\{.*?\n\}').Value
    $bashRecheck | Should -Match 'error '
  }
  It "the Windows recheck hard-fails too, not warn-only" {
    $psRecheck = [regex]::Match($script:PSRC, '(?s)function Test-PreflightRuntimeMem\s*\{.*?\n\}').Value
    $psRecheck | Should -Match 'Write-PfFail'
    $psRecheck | Should -Match 'Err '
    $psRecheck | Should -Not -Match 'WARN-only'
  }
  It "both tolerate the guest-vs-configured shortfall by the same grace constant" {
    $script:BSRC | Should -Match 'PF_VM_MEM_GRACE_MIB'
    $script:PSRC | Should -Match 'PF_VM_MEM_GRACE_MIB'
    Get-PfVmMemGraceMib | Should -Be 512
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
  # SEAM MOVED OUT ONE LAYER (backend#2849 review): both docker calls here are now
  # bounded, so the mock is on Invoke-DockerCli, not the native `docker`. Same
  # assertions -- one `update --restart` per node -- plus the timeout cases, which
  # were unreachable while the calls were bare.
  AfterEach { $env:TRACEBLOC_NO_AUTOSTART = $null }
  It "sets unless-stopped on each k3d node" {
    Mock Invoke-DockerCli {
      if (($DockerArgs -join ' ') -match 'ps -a') {
        return [pscustomobject]@{ Code = 0; Output = "k3d-tracebloc-server-0`nk3d-tracebloc-serverlb" }
      }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Set-ClusterAutostart
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -join ' ') -match 'update --restart unless-stopped' } -Times 2
  }
  It "TRACEBLOC_NO_AUTOSTART -> no docker calls" {
    $env:TRACEBLOC_NO_AUTOSTART = "1"
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "" } }
    Set-ClusterAutostart
    Should -Invoke Invoke-DockerCli -Times 0 -Exactly
  }
  It "every docker call carries a timeout -- no bare probe left on the main install path" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "k3d-tracebloc-server-0" } }
    Set-ClusterAutostart
    Should -Invoke Invoke-DockerCli -ParameterFilter { $TimeoutSec -gt 0 } -Times 2
  }
  It "a timed-out 'ps' SKIPS the pass instead of blocking, and never runs an update" {
    # This is defensive housekeeping (k3d already sets unless-stopped), so a wedged
    # daemon must cost a log line -- not the install. Previously the bare `ps`
    # blocked here and Step 3 never printed anything.
    Mock Log { }
    Mock Invoke-DockerCli {
      if (($DockerArgs -join ' ') -match 'ps -a') { return [pscustomobject]@{ Code = 124; Output = "" } }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    { Set-ClusterAutostart } | Should -Not -Throw
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -join ' ') -match 'update --restart' } -Times 0 -Exactly
  }
  It "a timed-out 'update' on one node does not abort the others" {
    Mock Log { }
    Mock Invoke-DockerCli {
      if (($DockerArgs -join ' ') -match 'ps -a') { return [pscustomobject]@{ Code = 0; Output = "n1`nn2" } }
      return [pscustomobject]@{ Code = 124; Output = "" }
    }
    { Set-ClusterAutostart } | Should -Not -Throw
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -join ' ') -match 'update --restart' } -Times 2
  }
  It "blank lines in the node list are not treated as nodes" {
    # The native call returned an ARRAY; the wrapper returns a STRING, so the split
    # is new code and a trailing newline would otherwise become a `docker update ""`.
    Mock Invoke-DockerCli {
      if (($DockerArgs -join ' ') -match 'ps -a') { return [pscustomobject]@{ Code = 0; Output = "n1`n`n  `nn2`n" } }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Set-ClusterAutostart
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -join ' ') -match 'update --restart' } -Times 2
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
    # MOCK THE SEAM THAT IS ACTUALLY USED (Bugbot). The bundle's reads now go through
    # Invoke-BoundedProcess, which calls [Process]::Start directly and so bypasses
    # both the `function kubectl/docker/helm/k3d` stubs at the top of this file and
    # any `Mock kubectl`. Left as-is, this test spawned the REAL kubectl, docker,
    # helm and k3d -- against the machine's live kubeconfig -- while claiming to
    # test redaction of a seeded secret.
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 0; Output = "" } }
    Mock Get-WindowsArch { "amd64" }   # avoid the PROCESSOR_ARCHITECTURE Err off-Windows
    { Invoke-DiagnoseBundle } | Should -Not -Throw
    # and prove the collectors went through it, so a future seam move is loud
    Should -Invoke Invoke-BoundedProcess -Times 1
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

  # ── SS3 (ESC O <final>) and the floor ───────────────────────────────────
  # These shipped in #736 with NO committed PowerShell test: the four cases
  # above are all CSI, so the whole SS3 half and the entire floor were
  # unverified here while the bash and Go copies had cases. That asymmetry is
  # how SS3 came to be missing from all three implementations at once
  # (tracebloc/cli#516) — the rule is hand-copied into three languages and only
  # one shape was ever tested.
  #
  # The cases mirror the bats corpus in install-client-helm.bats one-for-one, on
  # purpose: until backend#2084 lands a shared fixture, matching case lists are
  # the only thing making the three implementations comparable by reading.

  It "strips SS3 escapes around real content" {
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "na${esc}ODme" | Should -Be "name"
  }

  It "SS3-only input yields empty, so the caller re-prompts" {
    $esc = [char]27
    # Arrow keys pressed at the prompt. Empty is the contract: callers treat it
    # as "no answer" and re-prompt or auto-name, rather than naming a machine
    # after escape residue.
    ConvertTo-SanitizedInput -Value "${esc}OD${esc}OD${esc}OA" | Should -Be ""
    ConvertTo-SanitizedInput -Value "${esc}OH${esc}OF"         | Should -Be ""   # Home/End
    ConvertTo-SanitizedInput -Value "${esc}OP${esc}OQ"         | Should -Be ""   # F1/F2
  }

  It "handles SS3 and CSI mixed in one value" {
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "a${esc}ODb${esc}[Dc" | Should -Be "abc"
  }

  It "a bare O is not an escape" {
    # The regression guard for the obvious wrong fix: matching "O<letter>"
    # without requiring the ESC would eat two characters out of any name
    # starting with O.
    ConvertTo-SanitizedInput -Value "OPTIMUS-01" | Should -Be "OPTIMUS-01"
  }

  It "truncated SS3 (ESC with no final byte) yields empty" {
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "${esc}O" | Should -Be ""
  }

  It "an unknown escape family with nothing else is refused" {
    # ESC N is SS2 — deliberately NOT in the strip list. This is the floor
    # doing its job on the family nobody has reported yet, which is the only
    # part of this that generalises past the escapes we happen to know.
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "${esc}NB${esc}NC" | Should -Be ""
  }

  It "an unknown escape family beside real content keeps the content" {
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "box${esc}NC" | Should -Be "boxNC"
  }

  It "the floor counts non-Latin letters as real content" {
    # \p{L} not [A-Za-z]: keep-vs-reject must not depend on the script a name
    # is written in. An ASCII name and a Japanese one behave the same here
    # (Bugbot, #736) — the pair is the assertion, either alone proves nothing.
    $esc = [char]27
    ConvertTo-SanitizedInput -Value "${esc}NC日本"  | Should -Be "NC日本"
    ConvertTo-SanitizedInput -Value "${esc}NChello" | Should -Be "NChello"
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

Describe "Read-RebootChoice (the reboot prompt cannot hang an unattended install; backend#2675)" {
  # WHAT THIS DEFENDS. The "Reboot now?" question sits on the path EVERY fresh
  # Windows install takes -- a fresh host always has WSL2 / Virtual Machine
  # Platform / Hyper-V still to enable -- and it used to call Read-Host
  # unconditionally. With nobody at the console that call never returns, so the
  # `exit 2` handoff below it never happens and the caller watches a live process
  # do nothing. That is how the e2e Windows journey burned 22 minutes and
  # reported a timeout with no cause.
  #
  # The prompt itself is unreachable from Pester (its caller ends in `exit 2`),
  # which is exactly why the decision was lifted into this function.
  It "does not prompt at all when there is no terminal" {
    Mock Test-CanPrompt { $false }
    Mock Read-Host { throw "must not prompt with no terminal -- this is the hang" }
    Read-RebootChoice | Should -Be ""
    Should -Invoke Read-Host -Times 0
  }
  It "an empty answer is 'no reboot', not a retry" {
    # A terminal IS there and the user just presses Enter: Read-Host returns ""
    # and the caller's ^[Yy]$ match falls through to Set-TbRerunHandoff +
    # exit 2 -- the same handoff -NoReboot takes. (Bugbot: the first version
    # mocked Test-CanPrompt false, so it re-covered the no-terminal early
    # return and never drove Read-Host at all.)
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "" }
    Read-RebootChoice | Should -Not -Match "^[Yy]$"
    Should -Invoke Read-Host -Times 1
  }
  It "still asks when a terminal is there" {
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "y" }
    Read-RebootChoice | Should -Be "y"
    Should -Invoke Read-Host -Times 1
  }
  It "a Read-Host that throws is 'no reboot', not a crash" {
    # Same shape as the leftover guard's prompt: a console that dies mid-question
    # must not take the install with it.
    Mock Test-CanPrompt { $true }
    Mock Read-Host { throw "console gone" }
    Read-RebootChoice | Should -Be ""
  }
}

Describe "Unattended install with no credentials refuses instead of spinning (backend#2675)" {
  # THE SPIN. Install-ClientHelm's `fallback` branch reads the credential with
  # Read-Host and does `continue` on an empty answer WITHOUT charging an attempt
  # against $credMax. With nothing on stdin that is an infinite loop printing
  # "Client ID cannot be empty." -- an install that neither finishes nor fails,
  # which reads to any caller exactly like the reboot-prompt hang above.
  #
  # Only the GUARD is exercised here: everything past it needs a live cluster.
  # Err is mocked to throw, the way the leftover-guard tests do it.
  BeforeEach {
    $script:TB_PROV_MODE = "fallback"
    $env:TRACEBLOC_CLIENT_ID = $null
    $env:TRACEBLOC_CLIENT_PASSWORD = $null
  }
  It "no terminal + no credentials -> refuses, and never reaches a prompt" {
    Mock Test-CanPrompt { $false }
    Mock Read-Host { throw "must not prompt with no terminal -- this is the spin" }
    Mock Err { throw "refused" }
    Mock Step { }
    { Install-ClientHelm } | Should -Throw
    Should -Invoke Read-Host -Times 0
  }
  It "the refusal names the two variables that make the path unnecessary" {
    # Whoever hits this is automating; the message has to be actionable, and the
    # pair it names is the same one Get-ProvisioningPreset reads. Read straight
    # off the pure function the branch passes to Err -- capturing it THROUGH a
    # throwing mock bound differently on every Pester/PowerShell pairing in the
    # CI matrix (three strategies, three version-specific failures), which is
    # exactly why the message was lifted out, mirroring Read-RebootChoice.
    $refusal = Get-UnattendedCredentialRefusal
    $refusal | Should -Match 'TRACEBLOC_CLIENT_ID'
    $refusal | Should -Match 'TRACEBLOC_CLIENT_PASSWORD'
  }
}

Describe "TRACEBLOC_SKIP_REBOOT_PROMPT is the env twin of -NoReboot (backend#2675)" {
  # The documented Windows entry point is `irm https://tracebloc.io/i.ps1 | iex`,
  # and `iex` has nowhere to put a switch: install.ps1 forwards $args, and an
  # `irm | iex` launch has none. So without this variable there was NO unattended
  # way to opt out of the reboot prompt on Windows, while the bash twin has had
  # one for as long as the GPU path has existed.
  #
  # Dot-sourced into a CHILD SCOPE (`& { . $ps1; ... }`) so the binding is read
  # from the script itself rather than asserted against its wording -- and so the
  # $NoReboot this sets cannot leak into the rest of the suite.
  BeforeAll { $script:Ps1 = Join-Path $PSScriptRoot "../install-k8s.ps1" }
  AfterEach { $env:TRACEBLOC_SKIP_REBOOT_PROMPT = $null }

  It "set -> -NoReboot is on without the switch" {
    $env:TRACEBLOC_SKIP_REBOOT_PROMPT = "1"
    (& { . $script:Ps1; [bool]$NoReboot }) | Should -BeTrue
  }
  It "unset -> -NoReboot stays off (the customer default still asks)" {
    $env:TRACEBLOC_SKIP_REBOOT_PROMPT = $null
    (& { . $script:Ps1; [bool]$NoReboot }) | Should -BeFalse
  }
}

Describe "Every Docker/child wait on the install path is bounded (backend#2849)" {
  # WHAT THIS DEFENDS, and why it is the shape that keeps costing this journey
  # runs: an unbounded external call against a SICK dependency does not fail, it
  # BLOCKS. The caller then spends its whole budget and reports a timeout that
  # names nothing -- which is exactly how the reboot prompt (backend#2675) and the
  # empty exit code (backend#2849) each burned four Windows runs before anyone
  # could say what was wrong. This file already has the rule (Invoke-BoundedProcess,
  # "installer external-call timeout rule"); these are the sites that predated it.
  BeforeAll { $script:Src = Get-Content (Join-Path $PSScriptRoot "../install-k8s.ps1") -Raw }

  It "no bare 'docker info' survives anywhere -- every engine read is bounded" {
    # SOURCE-LEVEL and deliberately so: the sites are inside functions whose
    # callers exit, and the property is "this text does not appear", which is
    # only expressible against the text. Matches the NATIVE-call form
    # `(docker info ...)`, not the string inside an Invoke-DockerCli arg list.
    $script:Src | Should -Not -Match '\(docker info'
  }

  # THE CLASS, not one verb (backend#2849 review, @LukasWodka).
  #
  # The assertion above defends `docker info`. Its input domain is one needle, so
  # a NEW unbounded call -- `docker ps -a`, `docker inspect`, `docker version` --
  # walks straight past it while this Describe's name claims "every Docker/child
  # wait". Lukas proved that by injecting one and watching 38 tests stay green.
  #
  # So assert the real property: no native `docker` invocation anywhere in this
  # file is unbounded. Two bounding mechanisms are legitimate and both are
  # recognised -- Invoke-DockerCli (which is not a native call at all, so it
  # cannot match) and a `Start-Job` scriptblock reaped by Wait-JobWithProgress.
  # Anything else is a hang against a wedged daemon.
  #
  # AST, NOT REGEX, and that is the load-bearing choice. Every text-level version
  # of this either drowns in false positives -- this file has ~10 Log/return
  # strings containing "docker run", "docker build", "docker exec" -- or gets
  # narrowed until it is an instance guard again, which is exactly the failure
  # being fixed. The PowerShell parser knows a command from a string, so the
  # property can be stated once and stay true.
  It "EVERY native docker call is bounded -- the class, not just 'docker info' (backend#2849 review)" {
    $tokens = $null; $errors = $null
    $file = (Resolve-Path (Join-Path $PSScriptRoot "../install-k8s.ps1")).Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    # Fail CLOSED: an unparseable file must not read as "no unbounded calls".
    $errors.Count | Should -Be 0 -Because "the installer must parse before this property means anything"
    $ast | Should -Not -BeNullOrEmpty -Because "cannot read the installer AST"

    $native = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
      Where-Object { $_.GetCommandName() -eq 'docker' }

    # Sanity: this guard must be looking at something. If a refactor moves every
    # docker call behind the wrapper, delete this line -- do not let it pass vacuously.
    $native.Count | Should -BeGreaterThan 0 -Because "the AST query must still find native calls to judge"

    $unbounded = @()
    foreach ($c in $native) {
      $p = $c.Parent; $inJob = $false
      while ($p) {
        if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Start-Job') { $inJob = $true; break }
        $p = $p.Parent
      }
      if (-not $inJob) { $unbounded += "line $($c.Extent.StartLineNumber): $($c.Extent.Text)" }
    }
    $unbounded -join "`n" | Should -BeNullOrEmpty -Because "every native docker call must go through Invoke-DockerCli or a Wait-JobWithProgress-reaped Start-Job"
  }

  It "the -Diagnose bundle has NO unbounded external read -- it must work when the box does not" {
    # Bugbot (High) on the first pass of this PR, and it caught a real hole in the
    # fix: `docker ps` was bounded but `k3d cluster list` in the SAME expression
    # was not, and `Out-File` cannot run until both sides finish -- so the bundle
    # still never appeared on a wedged engine. Bounding one tool is not the
    # property; the property is that the bundle a user collects BECAUSE the
    # machine is broken always gets written.
    #
    # Same AST reasoning as the docker guard: k3d/kubectl/helm all reach the
    # engine or the API server behind it, and every one of them blocks.
    $tokens = $null; $errors = $null
    $file = (Resolve-Path (Join-Path $PSScriptRoot "../install-k8s.ps1")).Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0

    # INTERPROCEDURAL (Bugbot, second High). The first version of this looked only
    # at native commands written INSIDE Invoke-DiagnoseBundle, so a bare call in a
    # HELPER the bundle calls was invisible -- which is exactly how `Get-ChartVersion`
    # (`helm list`, no deadline) survived it. And it is the worst possible place for
    # one: the bundle calls it BEFORE writing any file, so an unreachable cluster
    # meant no zip at all.
    #
    # So walk the whole call graph the bundle can reach, not just its own body.
    $allFns = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
      $allFns[$f.Name] = $f
    }
    $allFns.ContainsKey('Invoke-DiagnoseBundle') | Should -BeTrue -Because "cannot locate Invoke-DiagnoseBundle"

    # transitive closure of in-file functions reachable from the bundle
    $reach = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    [void]$reach.Add('Invoke-DiagnoseBundle'); $queue.Enqueue('Invoke-DiagnoseBundle')
    while ($queue.Count -gt 0) {
      $cur = $queue.Dequeue()
      foreach ($call in $allFns[$cur].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if ($name -and $allFns.ContainsKey($name) -and -not $reach.Contains($name)) {
          [void]$reach.Add($name); $queue.Enqueue($name)
        }
      }
    }
    # must actually have followed calls, or the closure proves nothing
    $reach.Count | Should -BeGreaterThan 1 -Because "the closure must follow the bundle's helper calls"

    # Every external tool anything in that closure shells out to must be bounded.
    # A native invocation is unbounded unless it sits in a Start-Job (reaped on a
    # deadline -- the docker guard above enforces that reap per job).
    $unbounded = @()
    foreach ($name in $reach) {
      foreach ($c in $allFns[$name].FindAll({ param($n)
          $n -is [System.Management.Automation.Language.CommandAst] -and
          $n.GetCommandName() -in @('docker','k3d','kubectl','helm') }, $true)) {
        $p = $c.Parent; $inJob = $false
        while ($p) {
          if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Start-Job') { $inJob = $true; break }
          $p = $p.Parent
        }
        if (-not $inJob) { $unbounded += "$name line $($c.Extent.StartLineNumber): $($c.Extent.Text)" }
      }
    }

    $unbounded -join "`n" | Should -BeNullOrEmpty -Because "the support bundle must never block on the dependency it exists to describe"
  }

  # NOTE: these use a REAL present tool (pwsh, which is running this suite) and a
  # real absent one, deliberately. Mocking Get-Command hangs the run -- both the
  # installer and Pester itself call it constantly -- so the presence check is
  # exercised against the live command table instead.
  # THE TYPE CHANGE, not just the timeout (Bugbot, High). Bounding a native call
  # swaps line OBJECTS for one multi-line STRING, and any consumer that parsed
  # per-line silently changes meaning. That is what happened to namespace
  # discovery: `$blob | Select-String` matches the whole blob as a single line, so
  # the first token became the table header "NAMESPACE" and a SUCCESSFUL -Diagnose
  # collected logs, helm values and the chart version from a namespace that does
  # not exist. Extracted as a pure function precisely so this is pinned.
  It "namespace discovery reads the POD's namespace, never the table header" {
    $pods = @(
      "NAMESPACE     NAME                          READY   STATUS",
      "kube-system   coredns-5d78c9869d-abcde      1/1     Running",
      "tb-rel-a1     tb-rel-a1-jobs-manager-xyz    1/1     Running",
      "tb-rel-a1     tb-rel-a1-requests-proxy-q    1/1     Running"
    ) -join "`n"
    Get-JobsManagerNamespace $pods | Should -Be "tb-rel-a1"
  }
  It "namespace discovery survives CRLF, the shape a Windows kubectl actually emits" {
    $pods = "NAMESPACE  NAME  READY`r`nns-b2  ns-b2-jobs-manager-abc  1/1"
    Get-JobsManagerNamespace $pods | Should -Be "ns-b2"
  }
  It "namespace discovery returns EMPTY when no jobs-manager is present, so the caller falls back" {
    # Empty, not the header and not a wrong namespace: the caller then uses
    # "default", which is the documented behaviour.
    Get-JobsManagerNamespace "NAMESPACE  NAME  READY`nkube-system  coredns-1  1/1" | Should -Be ""
    Get-JobsManagerNamespace ""    | Should -Be ""
    Get-JobsManagerNamespace $null | Should -Be ""
  }
  It "namespace discovery never yields 'NAMESPACE' even if the split is broken again" {
    # The belt-and-braces guard: the header is rejected explicitly, so a future
    # refactor that re-breaks the line split still cannot leak it as a namespace.
    #
    # THE FIXTURE MUST MATCH (@LukasWodka). The first version used
    # "NAMESPACE NAME jobs-manager" -- no hyphen before jobs-manager, so
    # `Select-String '\-jobs-manager'` found nothing, the function returned early at
    # `-not $line`, and the header guard this test is named for never ran. It passed
    # identically with the guard present and removed: a vacuous test, in a test
    # written to catch exactly that. Measured after the fix, guard vs no guard:
    # "" / "NAMESPACE".
    #
    # One line whose first token IS the header and which DOES contain a
    # jobs-manager pod is precisely the broken-split shape.
    Get-JobsManagerNamespace "NAMESPACE NAME tb-jobs-manager" | Should -Be ""
  }
  It "a timed-out capture becomes DATA in the bundle, not a missing file" {
    # The distinction that makes the bundle useful: "k3d cluster list timed out"
    # is itself the finding support needs. Swallowing it to $null would hand them
    # an empty section and no explanation.
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 124; Output = "" } }
    $out = Invoke-DiagnoseCapture -FileName "pwsh" -Arguments @("-x") -TimeoutSec 5
    $out | Should -Match 'FAILED or TIMED OUT'
    $out | Should -Match 'exit 124'
  }
  It "a capture passes its deadline through and returns healthy output unchanged" {
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 0; Output = "NAME  SERVERS`ntracebloc  1/1" } }
    Invoke-DiagnoseCapture -FileName "pwsh" -Arguments @("-v") | Should -Match 'tracebloc  1/1'
    Should -Invoke Invoke-BoundedProcess -ParameterFilter { $TimeoutSec -gt 0 } -Times 1
  }
  It "a missing tool is reported, not shelled out to" {
    Mock Invoke-BoundedProcess { [pscustomobject]@{ Code = 0; Output = "x" } }
    Invoke-DiagnoseCapture -FileName "tb-definitely-not-installed-xyz" -Arguments @("x") | Should -Match 'not installed'
    Should -Invoke Invoke-BoundedProcess -Times 0 -Exactly
  }

  It "the Start-Job docker sites are actually reaped on a deadline, not merely in a job" {
    # "inside Start-Job" only bounds the call if something reaps the job. Without
    # this, the guard above could be satisfied by wrapping a hang in a job and
    # then waiting on it forever -- a bounded-looking unbounded wait.
    $tokens = $null; $errors = $null
    $file = (Resolve-Path (Join-Path $PSScriptRoot "../install-k8s.ps1")).Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0

    $native = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
      Where-Object { $_.GetCommandName() -eq 'docker' }
    $native.Count | Should -BeGreaterThan 0

    # PER-JOB, not per-function (@LukasWodka's follow-up). The first version of this
    # matched `Wait-JobWithProgress -Job $x -TimeoutSec N` anywhere in the enclosing
    # FUNCTION, so one compliant job vouched for its neighbours -- he proved it by
    # adding a second, unreaped docker job to a function that already had a good one
    # and watching all 41 tests stay green. Bind the reap to the SPECIFIC variable
    # this job was assigned to, so every job answers for itself.
    foreach ($c in $native) {
      $fn = $c.Parent
      while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
      $fn | Should -Not -BeNullOrEmpty -Because "the docker call at line $($c.Extent.StartLineNumber) is not inside a function, so nothing owns its deadline"

      # the Start-Job this call lives in ...
      $job = $c.Parent
      while ($job -and -not ($job -is [System.Management.Automation.Language.CommandAst] -and $job.GetCommandName() -eq 'Start-Job')) { $job = $job.Parent }
      $job | Should -Not -BeNullOrEmpty -Because "line $($c.Extent.StartLineNumber) is a native docker call outside Start-Job"

      # ... and the variable it is assigned to. No assignment => nothing can reap it.
      $assign = $job.Parent
      while ($assign -and -not ($assign -is [System.Management.Automation.Language.AssignmentStatementAst])) { $assign = $assign.Parent }
      $assign | Should -Not -BeNullOrEmpty -Because "the Start-Job at line $($job.Extent.StartLineNumber) is not assigned to a variable, so no reap can name it"

      $varAst = $assign.Left.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
      $varAst | Should -Not -BeNullOrEmpty -Because "cannot determine the job variable at line $($job.Extent.StartLineNumber)"
      $var = $varAst.VariablePath.UserPath

      $reap = "Wait-JobWithProgress -Job \$" + [regex]::Escape($var) + " -TimeoutSec \d+"
      $fn.Extent.Text | Should -Match $reap -Because "$($fn.Name) starts docker job '$var' but never reaps THAT job on a deadline"
    }
  }

  It "the engine probe goes through the bounded wrapper, with a timeout" {
    $script:Src | Should -Match 'function Test-DockerEngineUp'
    $script:Src | Should -Match 'Invoke-DockerCli -DockerArgs @\("info", "--format", "\{\{\.ID\}\}"\) -TimeoutSec \d+'
  }

  It "a timed-out probe reads as 'not up', never as up" {
    # The distinction that matters: a wedged daemon must not be mistaken for a
    # healthy one, or the install proceeds into Step 3 on an engine that is not
    # there. Non-zero Code -> false, regardless of what Output happens to hold.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = "abc123" } }
    Test-DockerEngineUp | Should -BeFalse
  }
  It "an empty ID reads as 'not up' even on a zero exit" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "   " } }
    Test-DockerEngineUp | Should -BeFalse
  }
  It "a real ID on a zero exit is 'up'" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "SOMEID" } }
    Test-DockerEngineUp | Should -BeTrue
  }

  It "the engine wait's deadline is wall-clock, not an iteration count" {
    # `$waitMin * 20` assumed every pass costs exactly its 3s sleep, which stops
    # being true the moment a probe blocks -- so the cap the code believed it had
    # was not a time bound at all.
    $script:Src | Should -Match '\$dockerStart\s+= Get-Date'
    $script:Src | Should -Match '\$dockerDeadline = \$dockerStart\.AddMinutes\(\$waitMin\)'
    $script:Src | Should -Match '\(Get-Date\) -lt \$dockerDeadline'
    # the iteration counter is GONE, not merely unused -- `$waitMin * 20` was the
    # thing that made a cap look like a time bound.
    $script:Src | Should -Not -Match '\$maxWait'
  }

  It "the ELAPSED the user reads comes from the same clock as the deadline" {
    # Bugbot + review: the deadline became wall-clock but the label still divided
    # the iteration counter by 20, i.e. assumed a 3s pass. With the probe capped
    # at 15s a wedged-daemon pass costs ~18s, so the loop exited at ~10 REAL
    # minutes still printing "1 min elapsed", immediately before "didn't come up
    # within 10 minutes". The status line exists to be honest on exactly that
    # pathology, so it must not be derived from a counter.
    $script:Src | Should -Match '\$elapsedMin = \[math\]::Floor\(\(\(Get-Date\) - \$dockerStart\)\.TotalMinutes\)'
    $script:Src | Should -Match '\$elapsedMin -ge 1'
    $script:Src | Should -Not -Match 'Floor\(\$i / 20\)'
  }

  It "the runtime preflight readers fall back to null on a timeout, not hang" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = "" } }
    Get-PfRuntimeMemGb  | Should -BeNullOrEmpty
    Get-PfRuntimeMemMib | Should -BeNullOrEmpty
    Get-PfRuntimeCpu    | Should -BeNullOrEmpty
  }
  It "the runtime preflight readers still parse a healthy answer" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "8589934592" } }
    Get-PfRuntimeMemGb | Should -Be 8
  }

  It "the CLI installer child is waited on WITH a deadline, and killed on timeout" {
    # This was the only wait in ~7400 lines with no bound. The child is
    # `irm <url> | iex` -- a network fetch we then execute.
    $script:Src | Should -Match '\$p\.WaitForExit\(\$cliWaitMs\)'
    $script:Src | Should -Match '\$p\.Kill\(\)'
    # The GATING wait must be the bounded one: a bare parameterless call as its own
    # statement is the unbounded wait this ticket removed.
    $script:Src | Should -Not -Match '(?m)^\s*\$p\.WaitForExit\(\)\s*$'
  }

  It "and its streams are FLUSHED after the bounded wait, or a success reads as failure" {
    # Bugbot on acefcae, against my own change. WaitForExit(ms) waits for the
    # PROCESS only; the PARAMETERLESS overload is what also waits for redirected
    # stdout/stderr to drain, and until they do .ExitCode can read back $null. So
    # `$p.ExitCode -eq 0` goes false after a SUCCESSFUL CLI install and Step 4
    # silently falls back to the legacy credential path -- the #611 shape, and the
    # empty-ExitCode class backend#2849 exists to remove. Swapping the parameterless
    # call for the timeout overload dropped the flush; the assertion above forbade
    # only the BARE form, so nothing caught it.
    $fn = [regex]::Match($script:Src, 'function Install-TraceblocCli[\s\S]*?\n\}').Value
    $fn | Should -Not -BeNullOrEmpty -Because "cannot locate Install-TraceblocCli"
    $fn | Should -Match '\$null = \$p\.Handle'                     # code survives the reap
    $fn | Should -Match 'try \{ \$p\.WaitForExit\(\) \} catch \{\}'   # streams drain before ExitCode is read
    # ORDER: the flush must come after the bounded wait and BEFORE ExitCode is read.
    # Anchored on CODE shapes, not bare substrings -- the surrounding comments quote
    # `$p.ExitCode -eq 0` in prose, and matching that text found the comment first.
    $gate  = [regex]::Match($fn, '(?m)^\s*if \(\$p\.WaitForExit\(\$cliWaitMs\)\)')
    $flush = [regex]::Match($fn, '(?m)^\s*try \{ \$p\.WaitForExit\(\) \} catch \{\}')
    $read  = [regex]::Match($fn, '(?m)^\s*if \(\$p\.ExitCode -eq 0\)')
    $gate.Success  | Should -BeTrue -Because "the bounded wait must gate the branch"
    $flush.Success | Should -BeTrue -Because "the stream flush must be a real statement"
    $read.Success  | Should -BeTrue -Because "cannot locate the ExitCode test"
    $flush.Index | Should -BeGreaterThan $gate.Index -Because "flushing before the bounded wait proves nothing"
    $read.Index  | Should -BeGreaterThan $flush.Index -Because "ExitCode must not be read before the streams have drained"
  }
}

Describe "Read-ClientName (the client-name prompt cannot hang an unattended install; backend#2836)" {
  # THE SECOND PROMPT. Right after the reboot question backend#2675 fixed, the
  # PRIMARY provisioning path asks for a client name with Read-Host. With no
  # console that call BLOCKS -- and the 3-try "empty Enter" loop is no defence,
  # because a blocked Read-Host never returns to be retried. Gated on
  # Test-CanPrompt, an unattended run gets "" and the caller fails closed naming
  # TRACEBLOC_CLIENT_NAME. Extracted (like Read-RebootChoice) because the call
  # site ends in Err, which no Pester mock can intercept.
  It "does not prompt at all when there is no terminal" {
    Mock Test-CanPrompt { $false }
    Mock Read-Host { throw "must not prompt with no terminal -- this is the hang" }
    Read-ClientName | Should -Be ""
    Should -Invoke Read-Host -Times 0 -Exactly
  }
  It "returns the name a present operator types" {
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "acme-lab" }
    Read-ClientName | Should -Be "acme-lab"
    Should -Invoke Read-Host -Times 1 -Exactly
  }
  It "retries an empty answer up to three times, then gives up (never an infinite loop)" {
    Mock Test-CanPrompt { $true }
    Mock Read-Host { "" }
    Read-ClientName | Should -Be ""
    Should -Invoke Read-Host -Times 3 -Exactly
  }
  It "a Read-Host that throws is 'no name', not a crash" {
    Mock Test-CanPrompt { $true }
    Mock Read-Host { throw "console gone" }
    Read-ClientName | Should -Be ""
  }
}

Describe "No Read-Host is reachable without a Test-CanPrompt gate (the hang class stays closed; backend#2836)" {
  # THE CLASS, NOT THE INSTANCE. A Read-Host with nobody at the console does not
  # fail, it HANGS -- backend#2675 fixed one such site, backend#2836's audit found
  # six more. The durable fix is a RULE: every Read-Host in this installer must
  # sit behind Test-CanPrompt, so an unattended run refuses or hands off instead
  # of blocking. This asserts the rule against the parsed script, so a future
  # unguarded Read-Host fails HERE, in CI, rather than in a customer's
  # console-less install.
  #
  # "Guarded" = a Test-CanPrompt CALL appears, lexically before the Read-Host, in
  # the Read-Host's own enclosing function -- or, for the load-time admin gate
  # that has no enclosing function, earlier at script scope. Every real guard in
  # this file has that shape: `if (Test-CanPrompt) { ...Read-Host... }`, an
  # `if (-not (Test-CanPrompt)) { return/Err }` at the top of the function or
  # branch, or `$canPrompt = Test-CanPrompt` before the gate. (Comments and
  # strings that mention Read-Host are invisible to the AST, so they can't
  # confuse this the way a grep would.)
  #
  # LIMITS, on purpose. This is lexical precedence, not true dominance -- a real
  # dominance/data-flow check would have to follow the admin gate's
  # `$canPrompt = Test-CanPrompt; if ($canPrompt)` indirection, which is more
  # machinery than a guard test should carry. So it will MISS a future Read-Host
  # dropped into the same function (or script scope) as an unrelated earlier
  # Test-CanPrompt call, and it REQUIRES each prompt to carry its own gate rather
  # than lean on a caller's. Both are acceptable here: it covers all 11 current
  # sites and fails the moment any of their gates is removed (that is the
  # regression this defends against); "self-guarded prompt" is a fine house rule.
  BeforeAll {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      "$PSScriptRoot/../install-k8s.ps1", [ref]$null, [ref]$null)
    $script:ReadHosts = @($ast.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-Host'
    }, $true))
    $script:CanPromptCalls = @($ast.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-CanPrompt'
    }, $true))
  }

  It "the AST query actually found Read-Host sites (a zero-site guard is green and worthless)" {
    $script:ReadHosts.Count | Should -BeGreaterThan 0
  }

  It "every Read-Host has a Test-CanPrompt gate before it in the same scope" {
    $unguarded = @()
    foreach ($rh in $script:ReadHosts) {
      # Nearest enclosing function; $null => the Read-Host sits at script scope
      # (the load-time admin gate), where the whole script is the search scope.
      $fn = $rh.Parent
      while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
      $scopeStart = if ($fn) { $fn.Extent.StartOffset } else { 0 }
      $scopeEnd   = if ($fn) { $fn.Extent.EndOffset }   else { [int]::MaxValue }
      $gate = $script:CanPromptCalls | Where-Object {
        $_.Extent.StartOffset -ge $scopeStart -and
        $_.Extent.EndOffset   -le $scopeEnd   -and
        $_.Extent.StartOffset -lt $rh.Extent.StartOffset
      }
      if (-not $gate) {
        $where = if ($fn) { $fn.Name } else { "<script scope>" }
        $unguarded += "line $($rh.Extent.StartLineNumber) (in $where)"
      }
    }
    $unguarded.Count | Should -Be 0 -Because "these Read-Host sites can hang an unattended install: $($unguarded -join '; ')"
  }
}

Describe "The dashboard link follows CLIENT_ENV (backend#2849)" {
  # WAS HARDCODED TO PRODUCTION at all thirteen sites, while Get-BackendUrl
  # right beside it was correctly env-aware. So a `CLIENT_ENV=dev` install sent
  # the operator to ai.tracebloc.io for credentials that dev-api then rejects.
  # Reported from a real dev install on Windows.
  #
  # The hosts are the BACKEND'S OWN settings, not a guess: DEVICE_VERIFICATION_URI
  # / RESET_PASSWORD_URL in xraybackend/settings/{dev,stg,prod}.py.
  AfterEach { $env:CLIENT_ENV = $null }

  It "dev -> dev.tracebloc.io" {
    $env:CLIENT_ENV = "dev"; Get-TraceblocDashboardUrl | Should -Be "https://dev.tracebloc.io/clients"
  }
  It "staging -> stg.tracebloc.io" {
    $env:CLIENT_ENV = "staging"; Get-TraceblocDashboardUrl | Should -Be "https://stg.tracebloc.io/clients"
  }
  It "prod -> ai.tracebloc.io" {
    $env:CLIENT_ENV = "production"; Get-TraceblocDashboardUrl | Should -Be "https://ai.tracebloc.io/clients"
  }
  It "unset or unknown -> prod, the same fallback Get-BackendUrl takes" {
    $env:CLIENT_ENV = $null;      Get-TraceblocDashboardUrl | Should -Be "https://ai.tracebloc.io/clients"
    $env:CLIENT_ENV = "whatever"; Get-TraceblocDashboardUrl | Should -Be "https://ai.tracebloc.io/clients"
  }
  It "honours the alias spellings the docs tell people to write" {
    # The exact class backend#1745 cost us on Get-BackendUrl: `staging` fell
    # through to prod. Same vocabulary, so it cannot drift apart here.
    $env:CLIENT_ENV = "development"; Get-TraceblocDashboardUrl | Should -Match 'dev\.tracebloc\.io'
    $env:CLIENT_ENV = "stg";         Get-TraceblocDashboardUrl | Should -Match 'stg\.tracebloc\.io'
  }
  It "takes a path, and an empty path gives the bare host" {
    $env:CLIENT_ENV = "dev"
    Get-TraceblocDashboardUrl 'my-use-cases' | Should -Be "https://dev.tracebloc.io/my-use-cases"
    Get-TraceblocDashboardUrl ''             | Should -Be "https://dev.tracebloc.io"
  }
  It "and it AGREES with Get-BackendUrl about which environment this is" {
    # The defect was precisely these two disagreeing. Pair them per environment
    # rather than asserting each alone, so a future edit cannot split them.
    foreach ($pair in @(@('dev','dev-api','dev.'), @('staging','stg-api','stg.'), @('production','//api','ai.'))) {
      $env:CLIENT_ENV = $pair[0]
      (Get-BackendUrl)             | Should -Match ([regex]::Escape($pair[1]))
      (Get-TraceblocDashboardUrl)  | Should -Match ([regex]::Escape($pair[2]))
    }
  }
  It "every dashboard host lives ONLY in the mapping" {
    # The three hosts must appear exactly once each -- as the switch arms of
    # Get-TraceblocDashboardUrl. A second occurrence is a site that went back to
    # hardcoding, which is the whole defect.
    $src = Get-Content (Join-Path $PSScriptRoot "../install-k8s.ps1") -Raw
    foreach ($h in @('https://dev.tracebloc.io', 'https://stg.tracebloc.io', 'https://ai.tracebloc.io')) {
      ([regex]::Matches($src, '"' + [regex]::Escape($h) + '"')).Count |
        Should -Be 1 -Because "$h should be written once, in the mapping"
    }
  }
  It "no LIVE dashboard link is hardcoded to production" {
    # The sharp one: a hardcoded link always carries a PATH (/clients,
    # /my-use-cases). The bare host with no path is only ever the mapping arm.
    $src = Get-Content (Join-Path $PSScriptRoot "../install-k8s.ps1") -Raw
    ([regex]::Matches($src, 'https://ai\.tracebloc\.io/[a-z-]')).Count |
      Should -Be 0 -Because 'every live dashboard link must go through Get-TraceblocDashboardUrl'
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

  It "JobInit silences the progress overlay in the job runspace (Bugbot #515)" {
    # A fresh runspace resets $ProgressPreference to 'Continue' -- the parent's
    # silence is not inherited -- and on PS 5.1 that overlay throttles
    # Invoke-WebRequest badly (#468/#471). It must be set by the init script so
    # every runspace gets it, not by each caller remembering to.
    $job = Start-Job -InitializationScript $JobInit -ScriptBlock { "$ProgressPreference" }
    Receive-Job -Job ($job | Wait-Job) | Should -Be 'SilentlyContinue'
    Remove-Job $job -Force
  }

  It "a caller that forgets ProgressPreference still runs silenced (Bugbot #515)" {
    # The whole point of moving it into JobInit: Invoke-WithHeartbeat is how every
    # in-job download runs, and its scriptblock must not have to opt in.
    (Invoke-WithHeartbeat -Message "progress" -PollSeconds 1 -Script { "$ProgressPreference" }) |
      Should -Be 'SilentlyContinue'
  }

  It "the silence lives in JobInit itself, not only at the call sites" {
    # Source-level gate: the assignment must be inside the $script:JobInit block,
    # so a new Start-Job call site inherits it without an edit. Slice the block
    # out first (non-greedy to the first closing brace at column 0) — matching
    # against the whole file would be satisfied by any caller-local assignment.
    $src   = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $block = [regex]::Match($src, '(?s)\$script:JobInit = \{.*?\r?\n\}')
    $block.Success | Should -BeTrue
    $block.Value | Should -Match '\$ProgressPreference = ''SilentlyContinue'''
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

Describe "k3s version pin: create + reuse drift (#547 source guards)" {
  BeforeAll { $script:PSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "passes --image rancher/k3s:<pin> on create" {
    $script:PSRC | Should -Match '"--image", "rancher/k3s:\$K8S_VERSION"'
  }
  It "warns loudly (not silently floats) when K8S_VERSION=latest" {
    $script:PSRC | Should -Match 'K8S_VERSION=latest runs an UNVALIDATED k3s'
    $script:PSRC | Should -Match 'if \(\$K8S_VERSION -eq "latest"\)'
  }
  It "defines Test-K3sVersionDrift which inspects the node image and compares the tag to the pin" {
    $script:PSRC | Should -Match 'function Test-K3sVersionDrift'
    $script:PSRC | Should -Match "docker inspect ""k3d-\`$n-server-0"" --format '{{\.Config\.Image}}'"
    $script:PSRC | Should -Match 'rancher/k3s:\(\[\^@'      # the tag-extract regex
    $script:PSRC | Should -Match '\$runningK3s -ne \$K8S_VERSION'
  }
  It "bounds the docker inspect probe with a deadline (no hang on a wedged engine, Bugbot #565)" {
    # Start-Job + Wait-JobWithProgress -TimeoutSec, same bounded pattern as Test-ClusterRunning;
    # the distinctive -Message ties the deadline to THIS probe.
    $script:PSRC | Should -Match 'Wait-JobWithProgress -Job \$job -TimeoutSec 15 -Message "Checking k3s version"'
  }
  It "warns with the recreate remedy on drift" {
    $script:PSRC | Should -Match 'not the validated pin'
    $script:PSRC | Should -Match 'k3d cluster delete \$CLUSTER_NAME'
  }
  It "runs the drift check on BOTH the reuse path and the healthy fast-path (Bugbot #565)" {
    # 1 definition + 2 call sites = at least 3 mentions
    ([regex]::Matches($script:PSRC, 'Test-K3sVersionDrift')).Count | Should -BeGreaterOrEqual 3
    # the completed+healthy fast-path calls it (right after the "nothing to do" line)
    $script:PSRC | Should -Match 'client is healthy -- nothing to do[\s\S]{0,320}?Test-K3sVersionDrift'
  }
  It "header docs no longer advertise 'default: latest'" {
    $script:PSRC | Should -Not -Match 'default: latest'
    $script:PSRC | Should -Match 'pinned \+ validated'
  }
}

Describe "Log hygiene: no Start-Transcript, helpers feed the curated log (#576)" {
  BeforeAll { $script:PSRC576 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "does not use Start-Transcript / Stop-Transcript (the transcript header is the PII leak)" {
    $script:PSRC576 | Should -Not -Match 'Start-Transcript -Path'
    $script:PSRC576 | Should -Not -Match 'Stop-Transcript'
  }

  It "routes the message helpers through Log() so the log stays useful without a transcript" {
    $log = Join-Path $TestDrive "install-576.log"
    $script:LOG_FILE = $log
    try {
      Ok   "route-check-ok"
      Warn "route-check-warn"
      Info "route-check-info"
      Step 1 6 "route-check-step"
      Hint "route-check-hint"
      $content = Get-Content $log -Raw
      $content | Should -Match 'route-check-ok'
      $content | Should -Match 'route-check-warn'
      $content | Should -Match 'route-check-info'
      $content | Should -Match 'route-check-step'
      $content | Should -Match 'route-check-hint'
      # curated by construction: the PowerShell transcript identity header (the PII)
      # can never appear, because Log() only ever writes what we pass it.
      $content | Should -Not -Match 'Username:'
      $content | Should -Not -Match 'Machine:'
      $content | Should -Not -Match 'PowerShell transcript'
    } finally { $script:LOG_FILE = $null }
  }
}

Describe "Preflight + summary failures reach the curated log (#576 Bugbot)" {
  It "Write-PfFail routes preflight hard-fail lines to the log (not screen-only)" {
    $log = Join-Path $TestDrive "install-pf.log"
    $script:LOG_FILE = $log
    try {
      Write-PfFail "Disk: only 5 GB free (need 40)"
      (Get-Content $log -Raw) | Should -Match 'PREFLIGHT FAIL: Disk: only 5 GB free'
    } finally { $script:LOG_FILE = $null }
  }
}

Describe "Print-Summary logs the classified outcome for every state (#576 Bugbot)" {
  BeforeEach { $script:TB_NAMESPACE = "ns"; $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false }
  It "records the final client state in the log (covers the default/image_pull/crash branch)" {
    $log = Join-Path $TestDrive "install-sum.log"
    $script:LOG_FILE = $log
    $script:ClientState = "image_pull"
    try {
      Print-Summary 6>&1 | Out-Null
      (Get-Content $log -Raw) | Should -Match 'Final client state: image_pull'
    } finally { $script:LOG_FILE = $null }
  }
}

Describe "Network profile: plain-language proxy / TLS-inspection read (#582)" {
  BeforeEach {
    $env:HTTP_PROXY = $null; $env:HTTPS_PROXY = $null
    $env:http_proxy = $null; $env:https_proxy = $null
    $env:TRACEBLOC_CA_BUNDLE = $null; $env:CURL_CA_BUNDLE = $null
  }
  AfterAll {
    $env:HTTP_PROXY = $null; $env:HTTPS_PROXY = $null
    $env:http_proxy = $null; $env:https_proxy = $null
    $env:TRACEBLOC_CA_BUNDLE = $null; $env:CURL_CA_BUNDLE = $null
  }

  It "Get-EnvProxyHostPort strips scheme + user:pass credentials (PII)" {
    Get-EnvProxyHostPort "http://user:pass@proxy.corp:8080/x" | Should -Be "proxy.corp:8080"
  }

  It "Get-EnvProxy: HTTPS wins and credentials are stripped" {
    $env:HTTP_PROXY = "http://h:1"; $env:HTTPS_PROXY = "http://user:secret@sproxy.corp:3128"
    $p = Get-EnvProxy
    $p | Should -Be "sproxy.corp:3128"
    $p | Should -Not -Match "secret"
  }

  It "Test-IssuerIsPublic: public CA true, corporate re-signer false" {
    Test-IssuerIsPublic "CN=DigiCert Global G2, O=DigiCert Inc" | Should -BeTrue
    Test-IssuerIsPublic "CN=Acme Corp Proxy CA, O=Acme Corp"    | Should -BeFalse
  }

  It "Get-EnvCaBundle: readable CA file returned, null when unset" {
    $ca = Join-Path $TestDrive "ca.pem"; "x" | Set-Content -LiteralPath $ca
    $env:TRACEBLOC_CA_BUNDLE = $ca
    Get-EnvCaBundle | Should -Be $ca
    $env:TRACEBLOC_CA_BUNDLE = $null
    Get-EnvCaBundle | Should -BeNullOrEmpty
  }

  It "Show-NetworkProfile: direct connection is silent" {
    Mock Get-TlsInspectionState { "no" }
    $out = Show-NetworkProfile 6>&1 | Out-String
    $out.Trim() | Should -BeNullOrEmpty
  }

  It "Show-NetworkProfile: proxy + inspection -> one PII-free line" {
    $env:HTTPS_PROXY = "http://u:p@proxy.corp:8080"
    Mock Get-TlsInspectionState { "yes" }
    $out = Show-NetworkProfile 6>&1 | Out-String
    $out | Should -Match "corporate proxy detected \(proxy\.corp:8080\)"
    $out | Should -Match "TLS inspection detected"
    $out | Should -Not -Match "u:p"
  }

  It "Show-NetworkProfile: a configured CA bundle is announced" {
    $ca = Join-Path $TestDrive "ca2.pem"; "x" | Set-Content -LiteralPath $ca
    $env:HTTPS_PROXY = "http://proxy.corp:8080"; $env:TRACEBLOC_CA_BUNDLE = $ca
    Mock Get-TlsInspectionState { "yes" }
    $out = Show-NetworkProfile 6>&1 | Out-String
    $out | Should -Match "your company's certificate is configured"
  }

  It "Get-EnvProxyRaw: preserves credentials (probe connection only, never displayed)" {
    $env:HTTPS_PROXY = "http://user:secret@px.corp:3128"
    Get-EnvProxyRaw | Should -Be "http://user:secret@px.corp:3128"
    Get-EnvProxy    | Should -Be "px.corp:3128"   # display path still strips
  }

  It "the TLS probe connects with proxy credentials, but display strips them (Bugbot)" {
    $src = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $probeFn = (($src -split "function Get-TlsInspectionState")[1] -split "`nfunction ")[0]
    $probeFn | Should -Match 'Get-EnvProxyRaw'      # connect uses the raw (credentialed) proxy
    $probeFn | Should -Match 'NetworkCredential'
    $showFn = (($src -split "function Show-NetworkProfile")[1] -split "`nfunction ")[0]
    $showFn | Should -Match 'Get-EnvProxy\b'        # display uses the stripped proxy
    $showFn | Should -Not -Match 'Get-EnvProxyRaw'
  }
}

Describe "Top-level error boundary: crashes become a clean message, never a stack (#577)" {
  BeforeAll { $script:PSRC577 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "the main run is wrapped in a top-level try/catch that calls Show-FatalError" {
    $script:PSRC577 | Should -Match 'Show-FatalError \$_'
    # Anchor on the trap->try pair that opens the top-level boundary, NOT on a
    # char-window from the TB_PESTER guard. That window (600 chars) only ever
    # passed by coincidentally matching the admin gate's own inline `try`, ~1200
    # chars nearer than the real boundary; removing that inline copy in
    # backend#2836 (one Test-CanPrompt predicate, no inline duplicate) exposed
    # the miscalibration. The main run's trap routes crashes to Show-FatalError
    # and sits immediately above the top-level try.
    $script:PSRC577 | Should -Match 'trap \{ Show-FatalError \$_[\s\S]{0,120}?\}\s*try \{'
  }

  It "Show-FatalError renders a clean 'stopped' message with reason + re-run hint, no stack" {
    $er = $null; try { throw "widget exploded" } catch { $er = $_ }
    $out = Show-FatalError $er 6>&1 | Out-String
    $out | Should -Match 'Installation stopped'
    $out | Should -Match 'widget exploded'
    $out | Should -Match 're-run'
    $out | Should -Not -Match 'char:\d'
    $out | Should -Not -Match 'ScriptStackTrace'
  }

  It "Show-FatalError logs the reason but never the stack" {
    $log = Join-Path $TestDrive "fatal-577.log"; $script:LOG_FILE = $log
    try {
      $er = $null; try { throw "disk on fire" } catch { $er = $_ }
      Show-FatalError $er 6>&1 | Out-Null
      $c = Get-Content $log -Raw
      $c | Should -Match 'FATAL: disk on fire'
      $c | Should -Not -Match 'ScriptStackTrace'
    } finally { $script:LOG_FILE = $null }
  }
}

Describe "Graceful failure: guaranteed finally + trap, guarded closer (#577)" {
  BeforeAll { $script:PSRC577b = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "wraps the main run in try/catch/finally with a last-resort trap" {
    # The trap also records the exit status for the telemetry emitter since
    # backend#2268 — without it a terminating error OUTSIDE the try reported
    # `install.run.succeeded`. Asserted as the full line so neither half can be
    # dropped: Show-FatalError, the status, and the exit 1.
    $script:PSRC577b | Should -Match 'trap \{ Show-FatalError \$_; \$script:TbExitCode = 1; exit 1 \}'
    $script:PSRC577b | Should -Match '\} finally \{'
    # The interrupted closer grew a body under backend#2268 (it now also derives the
    # telemetry status from the same signal), so this matches the CONDITION and the
    # call rather than a one-line spelling of both. `[\s\S]*?` is bounded by
    # Show-Interrupted on the next line, so it cannot drift across the whole file.
    $script:PSRC577b | Should -Match 'if \(-not \$script:OutcomeReported\) \{[\s\S]*?Show-Interrupted'
    # The telemetry status is DERIVED from OutcomeReported rather than detected
    # again: two Ctrl-C mechanisms could disagree, and the installer already has one.
    $script:PSRC577b | Should -Match '\$script:TbExitCode = 130'
    # And the outcome event is emitted from this finally — the Windows analogue of
    # install_cleanup. Without this line the emitter exists and is never called,
    # which is exactly how install-k8s.ps1 came to have no telemetry at all.
    $script:PSRC577b | Should -Match 'Send-TelemetryOutcome -Code \$script:TbExitCode'
  }

  It "marks the outcome reported on every terminal path (guards against a spurious interrupted line)" {
    ([regex]::Matches($script:PSRC577b, '\$script:OutcomeReported = \$true')).Count | Should -BeGreaterOrEqual 5
  }

  It "the -Diagnose path marks the outcome reported only after the bundle completes (Bugbot)" {
    # Setting the flag before the long collection would skip Show-Interrupted on an
    # interrupt mid-diagnose - the silent death this boundary exists to prevent.
    $script:PSRC577b | Should -Match 'Invoke-DiagnoseBundle; \$script:OutcomeReported = \$true'
  }

  It "the reboot-pending stop marks the outcome reported before exiting (Bugbot)" {
    # A reboot-pending exit is an intentional, reported stop (guidance is printed),
    # not an interruption; without the flag the finally appends a contradictory
    # Show-Interrupted line. The flag must be set before the block's exit 2.
    $script:PSRC577b | Should -Match '(?s)if \(\$rebootNeeded\) \{.*?\$script:OutcomeReported = \$true.*?exit 2'
  }

  It "Show-Interrupted renders a clean interrupted line (log + re-run, no stack)" {
    $log = Join-Path $TestDrive "int-577.log"; $script:LOG_FILE = $log
    try {
      $out = Show-Interrupted 6>&1 | Out-String
      $out | Should -Match 'interrupted'
      $out | Should -Match 're-run'
      $out | Should -Not -Match 'ScriptStackTrace'
      (Get-Content $log -Raw) | Should -Match 'interrupted'
    } finally { $script:LOG_FILE = $null }
  }
}

Describe "GPU device-plugin failure is recoverable, not fatal (#577)" {
  BeforeAll { $script:PSRCGPU = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "warns + continues in CPU mode instead of a fatal Err on a plugin failure" {
    $script:PSRCGPU | Should -Not -Match 'Err "Failed to enable GPU acceleration'
    $script:PSRCGPU | Should -Match 'continuing in CPU mode'
    $script:PSRCGPU | Should -Match 'GPU device-plugin setup error'
  }
  It "gates the success message on the kubectl exit code — never a false 'enabled' (Bugbot)" {
    # Native kubectl doesn't throw on a non-zero exit, so the GPU apply/rollout must be
    # $LASTEXITCODE-checked; otherwise a failed apply prints "GPU acceleration enabled."
    $gpuFn = ($script:PSRCGPU -split "function Install-GpuDevicePlugin")[1]
    # No fire-and-forget discard of the apply into $null (the false-success pattern).
    $gpuFn | Should -Not -Match '\$null = \(kubectl apply'
    # The success message is guarded, and the apply output is written to the log.
    $gpuFn | Should -Match '\$LASTEXITCODE'
    $gpuFn | Should -Match 'Log "GPU plugin apply'
  }
  It "bounds the GPU apply with --request-timeout so a wedged API can't hang it (Bugbot)" {
    # Parity with bash gpu-plugins.sh: the apply output is captured to the log, so
    # without a request timeout a wedged API server would hang instead of falling
    # through to the CPU-mode warn.
    $gpuFn = ($script:PSRCGPU -split "function Install-GpuDevicePlugin")[1]
    $gpuFn | Should -Match 'kubectl apply -f \$dpTmp --request-timeout='
  }
  It "verify runs only when the plugin deployed - CPU-mode skips Confirm-GpuNode (Bugbot)" {
    # A failed/CPU-mode deploy returns $false; the caller must gate Confirm-GpuNode
    # on it so the user doesn't wait ~90s for a plugin that was never applied.
    $script:PSRCGPU | Should -Match 'if \(Install-GpuDevicePlugin\) \{\s*Confirm-GpuNode'
    $gpuFn = ($script:PSRCGPU -split "function Install-GpuDevicePlugin")[1]
    $gpuFn | Should -Match 'return \$true'
    $gpuFn | Should -Match 'return \$false'
  }
  It "the PS GPU kubectl probes are bounded with --request-timeout (reviewer parity)" {
    # The existence check and Confirm-GpuNode's node probe must carry a request
    # timeout so a wedged API can't hang before/around the bounded apply (bash parity).
    $script:PSRCGPU | Should -Match 'kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset --request-timeout='
    $script:PSRCGPU | Should -Match 'kubectl get nodes? -o jsonpath.*--request-timeout='
  }
}

Describe "Set-ToolTrust: wire the corporate CA into cosign/helm/git (#583)" {
  BeforeEach { $env:TRACEBLOC_CA_BUNDLE=$null; $env:CURL_CA_BUNDLE=$null; $env:SSL_CERT_FILE=$null; $env:GIT_SSL_CAINFO=$null }
  AfterAll  { $env:TRACEBLOC_CA_BUNDLE=$null; $env:CURL_CA_BUNDLE=$null; $env:SSL_CERT_FILE=$null; $env:GIT_SSL_CAINFO=$null }

  It "exports GIT_SSL_CAINFO but NOT SSL_CERT_FILE (Go ignores it on Windows), points cosign/helm at the store (Bugbot)" {
    $ca = Join-Path $TestDrive "ca.pem"; "pem" | Set-Content -LiteralPath $ca
    $env:TRACEBLOC_CA_BUNDLE = $ca
    $out = Set-ToolTrust 6>&1 | Out-String
    $env:GIT_SSL_CAINFO | Should -Be (Resolve-Path -LiteralPath $ca).Path
    $env:SSL_CERT_FILE  | Should -BeNullOrEmpty      # inert on Windows; deliberately not set
    $out | Should -Match 'certificate for git'       # success names only what's wired
    $out | Should -Match 'downloads read the certificate store'  # downloads/cosign/helm -> store
  }

  It "no-op when no CA is configured" {
    Set-ToolTrust *> $null
    $env:GIT_SSL_CAINFO | Should -BeNullOrEmpty
  }

  It "does NOT clobber a user's pre-set GIT_SSL_CAINFO (replace-not-augment, Bugbot)" {
    $ca = Join-Path $TestDrive "corp.pem"; "pem" | Set-Content -LiteralPath $ca
    $uf = Join-Path $TestDrive "user-full.pem"; "pem" | Set-Content -LiteralPath $uf
    $env:TRACEBLOC_CA_BUNDLE = $ca
    $env:GIT_SSL_CAINFO = $uf
    Set-ToolTrust *> $null
    $env:GIT_SSL_CAINFO | Should -Be $uf     # user's fuller bundle left intact
  }

  It "a skipped export is not claimed as success (Bugbot)" {
    # With GIT_SSL_CAINFO pre-set the export is skipped — a green "Trusting..."
    # would report wiring that did not happen and mask a pre-set bundle that
    # still lacks the corporate CA. Say what was kept, claim nothing.
    $ca = Join-Path $TestDrive "corp.pem"; "pem" | Set-Content -LiteralPath $ca
    $uf = Join-Path $TestDrive "user-full.pem"; "pem" | Set-Content -LiteralPath $uf
    $env:TRACEBLOC_CA_BUNDLE = $ca
    $env:GIT_SSL_CAINFO = $uf
    $out = Set-ToolTrust 6>&1 | Out-String
    $out | Should -Not -Match 'Trusting'
    $out | Should -Match 'Keeping your pre-set GIT_SSL_CAINFO'
  }
}

Describe "Registry-block detection + guidance (#585)" {
  It "Test-Preflight flags a blocked container registry and points to the mirror/offline docs" {
    $src = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $fn  = (($src -split "function Test-Preflight")[1] -split "`nfunction ")[0]
    $fn | Should -Match '\$regBlocked'                 # detection flag
    $fn | Should -Match 'ghcr\.io'                     # registry match in the detection
    $fn | Should -Match 'container registries'         # the guidance line
    $fn | Should -Match 'docs/INSTALL\.md'             # points at the mirror/offline docs
  }
}

Describe "Get-ImageMirrorYaml (private registry mirror / air-gap, #585)" {
  # Bash parity: lib/install-client-helm.sh::_image_mirror_yaml + its bats tests.
  AfterEach {
    $env:TRACEBLOC_IMAGE_REGISTRY     = $null
    $env:TRACEBLOC_REGISTRY_USERNAME  = $null
    $env:TRACEBLOC_REGISTRY_PASSWORD  = $null
    $env:TRACEBLOC_REGISTRY_SERVER    = $null
    $env:TRACEBLOC_REGISTRY_EMAIL     = $null
  }

  It "returns empty when no mirror/creds are set (default install unchanged)" {
    Get-ImageMirrorYaml | Should -BeExactly ""
  }

  It "emits global.imageRegistry for a mirror-only install and no dockerRegistry" {
    $env:TRACEBLOC_IMAGE_REGISTRY = "mirror.corp.example"
    $out = Get-ImageMirrorYaml
    $out | Should -Match "(?m)^global:"
    $out | Should -Match "imageRegistry: 'mirror.corp.example'"
    $out | Should -Not -Match "dockerRegistry:"
  }

  It "strips a pasted scheme from the mirror host" {
    $env:TRACEBLOC_IMAGE_REGISTRY = "https://mirror.corp.example"
    $out = Get-ImageMirrorYaml
    $out | Should -Match "imageRegistry: 'mirror.corp.example'"
    $out | Should -Not -Match "imageRegistry: 'https://"
  }

  It "mints a dockerRegistry with a derived https:// server when creds are given" {
    $env:TRACEBLOC_IMAGE_REGISTRY    = "mirror.corp.example"
    $env:TRACEBLOC_REGISTRY_USERNAME = "svc"
    $env:TRACEBLOC_REGISTRY_PASSWORD = "secret"
    $out = Get-ImageMirrorYaml
    $out | Should -Match "(?m)^dockerRegistry:"
    $out | Should -Match "create: true"
    $out | Should -Match "server: 'https://mirror.corp.example'"
    $out | Should -Match "username: 'svc'"
    $out | Should -Match "password: 'secret'"
  }

  It "lets an explicit TRACEBLOC_REGISTRY_SERVER win over the derived URI" {
    $env:TRACEBLOC_IMAGE_REGISTRY    = "mirror.corp.example"
    $env:TRACEBLOC_REGISTRY_USERNAME = "svc"
    $env:TRACEBLOC_REGISTRY_PASSWORD = "secret"
    $env:TRACEBLOC_REGISTRY_SERVER   = "https://auth.corp.example/v2/"
    (Get-ImageMirrorYaml) | Should -Match "server: 'https://auth.corp.example/v2/'"
  }

  It "doubles single quotes in the password (YAML-safe)" {
    $env:TRACEBLOC_IMAGE_REGISTRY    = "mirror.corp.example"
    $env:TRACEBLOC_REGISTRY_USERNAME = "svc"
    $env:TRACEBLOC_REGISTRY_PASSWORD = "s3cr3t'q"
    (Get-ImageMirrorYaml) | Should -Match "password: 's3cr3t''q'"
  }

  It "emits dockerRegistry but no global when creds are given without a mirror" {
    $env:TRACEBLOC_REGISTRY_USERNAME = "svc"
    $env:TRACEBLOC_REGISTRY_PASSWORD = "secret"
    $out = Get-ImageMirrorYaml
    $out | Should -Not -Match "(?m)^global:"
    $out | Should -Match "(?m)^dockerRegistry:"
  }

  It "creds without a mirror still emit server (Docker Hub) - schema requires it (Bugbot)" {
    # The chart schema requires dockerRegistry.server whenever create is true.
    $env:TRACEBLOC_REGISTRY_USERNAME = "svc"
    $env:TRACEBLOC_REGISTRY_PASSWORD = "secret"
    (Get-ImageMirrorYaml) | Should -Match "server: 'https://index.docker.io/v1/'"
  }
}

Describe "Test-DownloadComplete (resilient tool download, #607)" {
  BeforeAll {
    $script:dl = Join-Path ([System.IO.Path]::GetTempPath()) ("tbdl-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:dl | Out-Null
    $script:exe = Join-Path $script:dl "k3d.exe"
    [System.IO.File]::WriteAllBytes($script:exe, ([byte[]](0x4D,0x5A) + (New-Object byte[] 2000000)))   # MZ + 2MB
    $script:zip = Join-Path $script:dl "helm.zip"
    [System.IO.File]::WriteAllBytes($script:zip, ([byte[]](0x50,0x4B,0x03,0x04) + (New-Object byte[] 2000000))) # PK + 2MB
    $script:err = Join-Path $script:dl "err.html"
    [System.IO.File]::WriteAllText($script:err, "<html>blocked by proxy</html>")
  }
  AfterAll { Remove-Item $script:dl -Recurse -Force -ErrorAction SilentlyContinue }

  It "passes a complete .exe (MZ) above the size floor" {
    Test-DownloadComplete -Path $script:exe -MinBytes 1MB -Magic 'MZ' | Should -BeNullOrEmpty
  }
  It "passes a complete .zip (PK) above the size floor" {
    Test-DownloadComplete -Path $script:zip -MinBytes 1MB -Magic 'PK' | Should -BeNullOrEmpty
  }
  It "flags a truncated/blocked transfer (below the size floor) as a transfer failure" {
    Test-DownloadComplete -Path $script:err -MinBytes 1MB -Magic 'MZ' | Should -Match 'truncated or blocked'
  }
  It "flags a complete-but-too-small file (size floor not met)" {
    Test-DownloadComplete -Path $script:exe -MinBytes 5MB -Magic 'MZ' | Should -Match 'expected at least'
  }
  It "flags a wrong magic (an error page or altered binary), not a checksum problem" {
    Test-DownloadComplete -Path $script:exe -MinBytes 1MB -Magic 'PK' | Should -Match "not a valid 'PK'"
  }
  It "flags a missing file" {
    Test-DownloadComplete -Path (Join-Path $script:dl "nope.bin") -MinBytes 1MB -Magic 'MZ' | Should -Match 'no file was written'
  }
  It "skips the magic check when no magic is given (size floor only)" {
    Test-DownloadComplete -Path $script:err -MinBytes 10 | Should -BeNullOrEmpty
  }
}

Describe "Get-VerifiedDownload resilience guards (#607, Bugbot)" {
  BeforeAll { $script:GVD = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "the curl.exe fallback names the TLS 1.2 floor (parity with curl_secure)" {
    # Bugbot: the fallback must not be able to negotiate below TLS 1.2 on the very
    # proxy networks this targets.
    $script:GVD | Should -Match 'curl\.exe --tlsv1\.2'
  }

  It "wraps the post-download validation so an I/O error tries the next transport, not aborts" {
    # Bugbot: Get-Item/OpenRead can throw if AV locks the just-written file; that
    # must fall through to curl.exe/BITS, not escape Get-VerifiedDownload.
    # Distance-independent: the try wraps the validation, and a catch turns an I/O
    # error into a recorded problem (so the loop tries the next transport).
    $script:GVD | Should -Match 'try \{\s*\$bad = Test-DownloadComplete'
    $script:GVD | Should -Match 'catch \{\s*\$bad = "could not read the downloaded file'
  }
}

Describe "Checksum-driven tool download (#609)" {
  BeforeAll { $script:CDD = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "Get-VerifiedDownload exposes -Sha256 and -MatchPattern, and no fail-open substring gate" {
    $script:CDD | Should -Match '\[string\]\$Sha256'
    $script:CDD | Should -Match '\[string\]\$MatchPattern'
    # -MustContain removed (Bugbot #611): a substring gate is fail-open because the
    # asset name also appears in the request URL that a proxy error page can echo.
    $script:CDD | Should -Not -Match 'MustContain'
  }

  It "the kubectl .sha256 gate is START-anchored so a proxy page retries transports (Bugbot #611)" {
    # kubectl's .sha256 is a bare hash; the gate must be anchored ('^...64hex') so an
    # HTML error page (which starts with '<') fails it and falls through to curl.exe/
    # BITS. An unanchored [0-9a-fA-F]{64} would pass on any page with a 64-hex run.
    $script:CDD | Should -Match "kubectl\.exe\.sha256[\s\S]{0,140}-MatchPattern '\^"
  }

  It "a checksum mismatch is treated as a bad transport (retries the next one), not a dead end" {
    # The whole point: -Sha256 makes the checksum the completeness test, so a
    # truncated/altered copy triggers curl.exe/BITS instead of failing the install.
    $script:CDD | Should -Match "if \(-not \`$bad -and \`$Sha256\)[\s\S]{0,200}checksum mismatch"
  }

  It "k3d gates the binary on the checksum fetched first, via a hash-anchored gate" {
    # The checksum-list gate requires a 64-hex hash adjacent to the asset, not a bare
    # asset-name substring (which also appears in the URL and would fail open) (Bugbot).
    $script:CDD | Should -Match 'checksums\.txt[\s\S]{0,160}-MatchPattern "\[0-9a-fA-F\]\{64\}'
    $script:CDD | Should -Match '\$k3dUrl[\s\S]{0,160}-Sha256'
  }

  It "kubectl gates the binary download on the .sha256 fetched first" {
    $script:CDD | Should -Match 'Get-VerifiedDownload[\s\S]{0,80}kubectl\.exe\.sha256'
    $script:CDD | Should -Match '\$kUrl[\s\S]{0,160}-Sha256'
  }

  It "helm gates the zip on its sha256sum with a hash-anchored gate (PS parity with bash)" {
    $script:CDD | Should -Match '\$helmUrl[\s\S]{0,160}-Sha256'
    $script:CDD | Should -Match 'sha256sum[\s\S]{0,160}-MatchPattern "\[0-9a-fA-F\]\{64\}'
  }

  It "each extracted checksum is validated as 64 hex before it gates a download" {
    ([regex]::Matches($script:CDD, "notmatch '\^\[0-9a-fA-F\]\{64\}\`$'")).Count | Should -BeGreaterOrEqual 2
  }
}

Describe "Cluster-create exit-code reliability (#611)" {
  BeforeAll { $script:CEC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "Wait-ProcessWithDeadline calls WaitForExit before returning success" {
    # HasExited can flip true before redirected stdout/stderr drain, leaving
    # $proc.ExitCode null; WaitForExit flushes them so every caller reads a real code.
    # Reliability is now co-guaranteed by the .Handle cache at the function's entry
    # (backend#2849) -- asserted in "Wait-ProcessWithDeadline exit-code reliability
    # (backend#2849 root cause)" -- so the header->WaitForExit window is wider than it was.
    $script:CEC | Should -Match 'function Wait-ProcessWithDeadline[\s\S]{0,2600}\$Process\.WaitForExit\(\)[\s\S]{0,80}return \$true'
  }

  It "the null-exit fallback checks BOTH k3d streams (logrus success goes to stderr) (Bugbot)" {
    # k3d's 'Cluster created successfully!' is a logrus line on STDERR, so the null-
    # exit fallback must inspect $k3dStderr too, not only $k3dStdout.
    $script:CEC | Should -Match 'if \(\$null -eq \$k3dExitCode\)[\s\S]{0,120}k3dStdout[\s\S]{0,20}k3dStderr[\s\S]{0,40}created successfully'
  }
}

Describe "Local chart path support (#611 — Windows/bash parity)" {
  BeforeAll { $script:LCP = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "uses TRACEBLOC_CHART_PATH as the chart ref when set (test an unreleased chart)" {
    $script:LCP | Should -Match 'if \(\$env:TRACEBLOC_CHART_PATH\)'
    $script:LCP | Should -Match '\$chartRef = \$env:TRACEBLOC_CHART_PATH'
  }
  It "installs from `$chartRef, not a hardcoded repo path" {
    $script:LCP | Should -Match 'helm upgrade --install \$TB_NAMESPACE \$chartRef'
    $script:LCP | Should -Match 'helm upgrade \$existingName \$chartRef'
  }
  It "skips 'helm repo add' when a local chart path is given (it's in the else branch)" {
    $script:LCP | Should -Match '\$chartRef = "\$TRACEBLOC_HELM_REPO_NAME/\$TRACEBLOC_CHART_NAME"[\s\S]{0,140}helm repo add'
  }
  It "errors if TRACEBLOC_CHART_PATH is set but is not a directory" {
    $script:LCP | Should -Match 'TRACEBLOC_CHART_PATH is set but is not a directory'
  }
}

Describe "Confirm-DockerGpu (#616 authoritative GPU gate)" {
  BeforeEach { $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $CUDA_BASE_TAG = "12.4.1-base-ubuntu22.04"; $script:GPU_SKIP_REASON = "" }
  It "returns true when the bounded docker-run probe succeeds" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "NVIDIA-SMI 550.x   Driver Version: 550.x   CUDA Version: 12.4" } }
    Confirm-DockerGpu | Should -BeTrue
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "run") -and ($DockerArgs -contains "--gpus") }
  }
  It "the probe disables the CUDA requirement gate so an older driver isn't a false negative (#616)" {
    # NVIDIA_REQUIRE_CUDA in the base image would reject the container on a driver older than the
    # base's CUDA (e.g. 532.x = CUDA 12.1 vs a 12.4 base) -- reading a working GPU as unavailable.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "NVIDIA-SMI 532.10   Driver Version: 532.10   CUDA Version: 12.1" } }
    Confirm-DockerGpu | Should -BeTrue
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "-e") -and ($DockerArgs -contains "NVIDIA_DISABLE_REQUIRE=1") }
  }
  It "probe exits non-zero: false + a GPU-unavailable reason (not a timeout one)" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 125; Output = "could not select device driver with capabilities: [[gpu]]" } }
    Confirm-DockerGpu | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "can't expose the GPU"
  }
  It "returns false when output lacks the nvidia-smi banner even on exit 0" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "some unrelated output" } }
    Confirm-DockerGpu | Should -BeFalse
  }
  It "probe TIMEOUT (Code 124): false + a reason that says timed out, not GPU-unavailable (#616 Bugbot)" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = "docker run timed out after 180s" } }
    Confirm-DockerGpu | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "timed out"
    $script:GPU_SKIP_REASON | Should -Not -Match "can't expose the GPU"
  }
  It "short-circuits to false without probing when there is no NVIDIA GPU" {
    $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false
    Mock Invoke-DockerCli { throw "must not probe without a GPU" }
    Confirm-DockerGpu | Should -BeFalse
    Should -Not -Invoke Invoke-DockerCli
  }
}

Describe "Test-NodeImageGpuCapable (#616 Bugbot: only the CUDA node can schedule GPU pods)" {
  It "the custom k3s-CUDA image is GPU-capable" {
    Test-NodeImageGpuCapable "ghcr.io/tracebloc/k3s-cuda:v1.29.4-k3s1-cuda-12.4.1-base-ubuntu22.04" | Should -BeTrue
  }
  It "a mirror-hosted CUDA image is still recognized" {
    Test-NodeImageGpuCapable "registry.internal/tracebloc/k3s-cuda:v1.29.4-k3s1-cuda-12.4.1-base-ubuntu22.04" | Should -BeTrue
  }
  It "a stock rancher/k3s image is NOT GPU-capable (the reused CPU cluster)" {
    Test-NodeImageGpuCapable "rancher/k3s:v1.29.4-k3s1" | Should -BeFalse
  }
  It "an unreadable/empty image fails safe to NOT GPU-capable" {
    Test-NodeImageGpuCapable "" | Should -BeFalse
  }
  It "a renamed/digest-only override that equals the configured image IS recognized (#616 Bugbot)" {
    # An operator override (TRACEBLOC_K3S_CUDA_IMAGE) may not contain 'k3s-cuda:' -- accept an
    # exact match against the image this run is configured to use.
    Test-NodeImageGpuCapable -Image "mirror.corp/gpu-node@sha256:abc123" -Configured "mirror.corp/gpu-node@sha256:abc123" | Should -BeTrue
  }
  It "a stock node is NOT recognized even when a custom GPU image is configured" {
    Test-NodeImageGpuCapable -Image "rancher/k3s:v1.29.4-k3s1" -Configured "mirror.corp/gpu-node:v1" | Should -BeFalse
  }
}

Describe "Confirm-ReusedClusterGpuCapable (#616 Bugbot: reused stock cluster can't adopt GPU)" {
  It "GPU not requested: no-op that never inspects the node" {
    $script:K3D_GPU_FLAG = ""
    Mock Start-Job { throw "must not inspect the node when GPU was not requested" }
    { Confirm-ReusedClusterGpuCapable } | Should -Not -Throw
    $script:K3D_GPU_FLAG | Should -Be ""
    Should -Not -Invoke Start-Job
  }
}

Describe "GPU capability is reconciled on cluster REUSE (#616 Bugbot source guards)" {
  BeforeAll { $script:RSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the reuse path calls Confirm-ReusedClusterGpuCapable so a stock node can't get GPU values" {
    # It must run inside the reuse branch, after the drift check, before the fresh-create else.
    $script:RSRC | Should -Match 'Test-K3sVersionDrift[\s\S]{0,500}?Confirm-ReusedClusterGpuCapable[\s\S]{0,400}?\} else \{'
  }
  It "the reconciler is bounded (job + deadline) like the other reuse-time docker probes" {
    $fn = ($script:RSRC -split 'function Confirm-ReusedClusterGpuCapable')[1]
    $fn | Should -Match 'Start-Job'
    $fn | Should -Match 'Wait-JobWithProgress -Job \$job -TimeoutSec 15'
    $fn | Should -Match "Config.Image"
    $fn | Should -Match 'Test-NodeImageGpuCapable -Image \$img -Configured \$K3S_CUDA_IMAGE'
  }
  It "when the reused node isn't CUDA it clears the flag (CPU fallback) with a recreate reason" {
    $fn = ($script:RSRC -split 'function Confirm-ReusedClusterGpuCapable')[1]
    $fn | Should -Match '\$script:K3D_GPU_FLAG = ""'
    $fn | Should -Match '\$script:GPU_SKIP_REASON = "the existing'
    $fn | Should -Match 'k3d cluster delete \$CLUSTER_NAME'
  }
}

Describe "GPU cluster wiring (#616 source guards)" {
  BeforeAll { $script:GSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "a GPU cluster uses the custom k3s-CUDA image, a normal one uses stock k3s" {
    $script:GSRC | Should -Match '\$k3dArgs \+= @\("--image", \$K3S_CUDA_IMAGE\)'
    $script:GSRC | Should -Match '\$k3dArgs \+= @\("--image", "rancher/k3s:\$K8S_VERSION"\)'
  }
  It "the custom image ref defaults to GHCR, is env-overridable, and re-homes onto a mirror" {
    $script:GSRC | Should -Match 'TRACEBLOC_K3S_CUDA_IMAGE'
    $script:GSRC | Should -Match '\$cudaRepo = "tracebloc/k3s-cuda:\$K8S_VERSION-cuda-\$CUDA_BASE_TAG"'
    $script:GSRC | Should -Match '"ghcr\.io/\$cudaRepo"'
    # air-gap: the one installer command re-homes the GPU image onto the mirror (#585)
    $script:GSRC | Should -Match 'TRACEBLOC_IMAGE_REGISTRY'
    $script:GSRC | Should -Match '"\$mirrorHost/\$cudaRepo"'
  }
  It "the docker-run probe is the authoritative gate: it sets/clears K3D_GPU_FLAG" {
    $script:GSRC | Should -Match 'Confirm-DockerGpu'
    $script:GSRC | Should -Match '\$K3D_GPU_FLAG = "--gpus=all"'
  }
  It "k3s drift detection also recognizes the GPU node image, not just rancher/k3s (#616 Bugbot)" {
    $script:GSRC | Should -Match "k3sImage -match 'k3s-cuda:"
    $script:GSRC | Should -Match '\^\(\.\+\?\)-cuda-'
  }
  It "GPU-enabled installs request the nvidia RuntimeClass for spawned pods" {
    $script:GSRC | Should -Match '\$runtimeClass = "nvidia"'
    $script:GSRC | Should -Match 'RUNTIME_CLASS_NAME: "\$runtimeClass"'
  }
  It "enabling the GPU collapses the cluster to a single node so one card isn't double-counted (#616 Bugbot)" {
    # --gpus=all exposes the SAME host GPU to every k3d node + the device-plugin registers
    # it per node, so a server+agent cluster advertises 2 GPUs for 1 card. When GPU is on,
    # AGENTS must be forced to 0 (the block sits under the K3D_GPU_FLAG="--gpus=all" branch).
    $gate = ($script:GSRC -split '\$K3D_GPU_FLAG = "--gpus=all"')[1]
    $gate | Should -Match '\$AGENTS = "0"'
    # an explicit user AGENTS is overridden LOUDLY, not silently
    $gate | Should -Match 'if \(\$env:AGENTS\)'
    $gate | Should -Match 'double-count'
  }
}

Describe 'k3s component disablement (New-K3dCluster $k3dArgs)' {
  # Three properties, none of them covered before this block. `traefik` and
  # `servicelb` appeared nowhere in scripts/tests/ at all -- neither suite, either
  # installer -- and losing one is silent: the install still succeeds, the cluster
  # just runs an inbound component the chart never uses (it renders no Ingress and
  # no LoadBalancer Service). Nothing goes red.
  #
  # The third runs the other way and is load-bearing: metrics-server must NEVER be
  # disabled. client/templates/resource-monitor-daemonset.yaml looks up the
  # v1beta1.metrics.k8s.io APIService and `fail`s the release when it is absent, so
  # adding `--disable=metrics-server` as a footprint optimisation -- a plausible
  # edit, sitting right next to the three legitimate ones -- would abort the
  # install and every later auto-upgrade tick, each of which re-renders that
  # template.
  #
  # DERIVED from the real assignment via the AST, not restated: the list is read
  # out of `$k3dArgs` itself, so this file keeps no second copy to drift from it.
  # The assertion is on the EXACT set rather than "contains", which is what makes
  # the metrics-server property hold for components nobody has proposed yet -- a
  # `contains` test can only catch a REMOVED flag, never an added one.
  #
  # Note on gating: `Pester (windows-latest)` is NOT a required status check on
  # develop, so on its own this Describe advises rather than blocks. The blocking
  # copy of the same two properties lives in scripts/tests/k3s-components-agreement.sh,
  # which runs in the required `Source-of-truth drift` job and compares this
  # installer's set against the bash one. These tests are the local-feedback and
  # per-argument-position half; that script is the gate.
  BeforeAll {
    $script:KRaw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      "$PSScriptRoot/../install-k8s.ps1", [ref]$null, [ref]$null)

    # The `$k3dArgs = @(…)` literal, found by AST rather than regex so the
    # arguments come from the declaration the installer actually runs.
    $script:KAssign = @($ast.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$k3dArgs' -and
      $node.Operator -eq 'Equals'
    }, $true))

    $script:KArgs = @()
    if ($script:KAssign.Count -eq 1) {
      $script:KArgs = @($script:KAssign[0].Right.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
      }, $true) | ForEach-Object { $_.Value })
    }

    # Components disabled by that literal: node filter (`@server:*`) stripped.
    $script:KDisables = @($script:KArgs |
      Where-Object { $_ -like '--disable=*' } |
      ForEach-Object { ($_ -replace '^--disable=', '') -replace '@.*$', '' } |
      Sort-Object -Unique)

    # The installer with comment lines removed. Every whole-file scan below reads
    # this rather than $script:KRaw, because this file documents both the flag it
    # must never pass and the variable the tripwire watches for -- a scan over
    # prose fires on its own explanation, which says nothing about the code.
    $script:KCode = ($script:KRaw -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    # Every `--disable=` in the whole file. The AST read above sees only the initial
    # literal; a later `$k3dArgs += @("--k3s-arg", …)` in the same function, or a
    # disable added in some other function, would be invisible to it. This is the
    # backstop that is not.
    $script:KAllDisables = @([regex]::Matches($script:KCode, '--disable=([A-Za-z0-9_-]+)') |
      ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  }

  It 'finds exactly one $k3dArgs literal to derive from (else every assertion below is vacuous)' {
    # Fail closed. Zero parsed arguments would satisfy "does not contain
    # metrics-server" perfectly, and a renamed variable or a split assignment must
    # surface as a finding here rather than as silent green below.
    $script:KAssign.Count | Should -Be 1 -Because 'the tests below read the k3d argv out of this one assignment'
    $script:KDisables.Count | Should -BeGreaterThan 0 -Because 'a stale parser reports an empty set, which passes every negative assertion'
  }

  It "disables EXACTLY traefik, servicelb and local-storage" {
    ($script:KDisables -join ' ') | Should -Be 'local-storage servicelb traefik'
  }

  It 'NEVER disables metrics-server -- not in $k3dArgs, not anywhere in the installer' {
    $script:KDisables    | Should -Not -Contain 'metrics-server'
    $script:KAllDisables | Should -Not -Contain 'metrics-server'
  }

  It "passes each disablement as a --k3s-arg value, not as a bare k3d flag" {
    # k3d has no --disable of its own; the flag belongs to k3s and only reaches it
    # through --k3s-arg. A disable passed bare makes `k3d cluster create` fail with
    # "unknown flag", so this pins the pairing the flags depend on.
    for ($i = 0; $i -lt $script:KArgs.Count; $i++) {
      if ($script:KArgs[$i] -like '--disable=*') {
        $i | Should -BeGreaterThan 0 -Because "a --disable cannot be the first argument"
        $script:KArgs[$i - 1] | Should -Be '--k3s-arg' -Because "$($script:KArgs[$i]) must be the value of a --k3s-arg"
      }
    }
  }

  It "is hostpath-only, which is the sole reason local-storage may be unconditional here" {
    # cluster.sh gates the local-storage disable on TB_STORAGE_MODE; this installer
    # does not, and that is correct only while node-local (RFC-0003 Option C) has
    # no Windows path -- the reason the leftover-data guard gives for being
    # hostpath-only. A divergence held in place by an absence, previously watched
    # by nothing.
    #
    # A tripwire, not a defect report: the day this installer learns
    # TB_STORAGE_MODE, it reddens, and the fix is to make the local-storage disable
    # conditional the way cluster.sh does. k3s-components-agreement.sh carries the
    # blocking copy of this check.
    $script:KCode | Should -Not -Match 'TB_STORAGE_MODE' -Because 'adding Windows node-local support means the local-storage disable must become conditional first'
    $script:KArgs | Should -Contain '--disable=local-storage@server:*'
  }
}

Describe "Confirm-GpuImagePullable (#616 private GPU image, no public package)" {
  BeforeAll { $script:GSRC2 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  BeforeEach {
    $K3S_CUDA_IMAGE = "ghcr.io/tracebloc/k3s-cuda:v1.29.4-k3s1-cuda-12.4.1-base-ubuntu22.04"
    $script:GPU_SKIP_REASON = ""
    $env:TRACEBLOC_REGISTRY_USERNAME = $null; $env:TRACEBLOC_REGISTRY_PASSWORD = $null
  }
  AfterEach { $env:TRACEBLOC_REGISTRY_USERNAME = $null; $env:TRACEBLOC_REGISTRY_PASSWORD = $null }

  It "logs Docker in with the registry creds, pulls, and sanity-checks -> true" {
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "run") { return [pscustomobject]@{ Code = 0; Output = "k3s version v1.29.4+k3s1" } }  # sanity OK
      return [pscustomobject]@{ Code = 0; Output = "" }   # login + pull OK
    }
    Confirm-GpuImagePullable | Should -BeTrue
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "login") -and ($DockerArgs -contains "ghcr.io") }
    Should -Invoke Invoke-DockerCli -ParameterFilter { $DockerArgs -contains "pull" }
    Should -Invoke Invoke-DockerCli -ParameterFilter { $DockerArgs -contains "run" }   # sanity check ran
  }
  It "a pulled but BROKEN image (fails the k3s sanity check) -> CPU fallback, not cluster-create abort (#616 Bugbot)" {
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "run") { return [pscustomobject]@{ Code = 127; Output = "exec /bin/k3s: no such file" } }  # broken
      return [pscustomobject]@{ Code = 0; Output = "" }   # login + pull succeed
    }
    Confirm-GpuImagePullable | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "doesn't run k3s"
  }
  It "returns false with a credentials hint when the pull fails despite creds" {
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli { if ($DockerArgs -contains "login") { [pscustomobject]@{ Code = 0; Output = "" } } else { [pscustomobject]@{ Code = 1; Output = "denied" } } }
    Confirm-GpuImagePullable | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "credentials"
  }
  It "without creds: no docker login, and the reason names the env vars to set" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 1; Output = "denied" } }
    Confirm-GpuImagePullable | Should -BeFalse
    Should -Not -Invoke Invoke-DockerCli -ParameterFilter { $DockerArgs -contains "login" }
    $script:GPU_SKIP_REASON | Should -Match "TRACEBLOC_REGISTRY_USERNAME"
  }
  It "a pull TIMEOUT (Code 124) falls back to CPU with a timeout reason, not an auth error (#616 Bugbot)" {
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli { if ($DockerArgs -contains "login") { [pscustomobject]@{ Code = 0; Output = "" } } else { [pscustomobject]@{ Code = 124; Output = "docker pull timed out after 900s" } } }
    Confirm-GpuImagePullable | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "timed out"
    $script:GPU_SKIP_REASON | Should -Not -Match "credentials"
  }
  It "GPU gate + BOUNDED docker calls (source guard: installer timeout rule)" {
    # Default = local BUILD (no login); explicit prebuilt image / mirror = PULL. Both gated
    # behind the docker-run probe, which short-circuits before any build/pull.
    $script:GSRC2 | Should -Match '\(Confirm-DockerGpu\) -and \(& \$gpuImageReady\)'
    $script:GSRC2 | Should -Match 'if \(\$env:TRACEBLOC_K3S_CUDA_IMAGE -or \$env:TRACEBLOC_IMAGE_REGISTRY\) \{ Confirm-GpuImagePullable \} else \{ Build-GpuNodeImage \}'
    # every GPU docker call goes through the bounded helper with an explicit timeout
    $script:GSRC2 | Should -Match 'Invoke-DockerCli -DockerArgs @\("run"'
    $script:GSRC2 | Should -Match 'Invoke-DockerCli -DockerArgs @\("login"'
    $script:GSRC2 | Should -Match 'Invoke-DockerCli -DockerArgs @\("pull", \$K3S_CUDA_IMAGE\) -TimeoutSec'
    # the helper itself is bounded AND kills docker.exe on timeout (no orphaned native process)
    $script:GSRC2 | Should -Match 'function Invoke-DockerCli'
    $script:GSRC2 | Should -Match '\$proc.WaitForExit\(\$TimeoutSec \* 1000\)'
    $script:GSRC2 | Should -Match '\$proc.Kill\(\)'
  }
}

Describe "Get-RegistryHost (#616 Bugbot: docker login targets the right host)" {
  It "a qualified registry host is used as-is" {
    Get-RegistryHost "ghcr.io/tracebloc/k3s-cuda:tag" | Should -Be "ghcr.io"
  }
  It "a custom mirror host is used as-is" {
    Get-RegistryHost "mirror.corp/tracebloc/k3s-cuda:tag" | Should -Be "mirror.corp"
  }
  It "a host:port is recognized" {
    Get-RegistryHost "localhost:5000/gpu-node:tag" | Should -Be "localhost:5000"
  }
  It "a bare Docker Hub repo (owner/name) logs into docker.io, NOT the owner (#616 Bugbot)" {
    Get-RegistryHost "owner/private-image:tag" | Should -Be "docker.io"
  }
}

Describe "GPU registry login happens BEFORE the probe (#616 Bugbot: authenticated mirror)" {
  BeforeAll { $script:LSRC2 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the gate calls Connect-GpuRegistry before the Confirm-DockerGpu probe for a mirror/custom image" {
    # Otherwise the mirror-homed CUDA probe pull is unauthenticated -> CPU fallback despite creds.
    $script:LSRC2 | Should -Match 'if \(\$env:TRACEBLOC_K3S_CUDA_IMAGE -or \$env:TRACEBLOC_IMAGE_REGISTRY\) \{ Connect-GpuRegistry \}[\s\S]{0,1600}?\(Confirm-DockerGpu\) -and'
  }
  It "Connect-GpuRegistry logs into the host from Get-RegistryHost and no-ops without creds" {
    $fn = ($script:LSRC2 -split 'function Connect-GpuRegistry')[1]
    $fn | Should -Match 'if \(-not \(\$regUser -and \$regPass\)\) \{ return \}'
    $fn | Should -Match 'Get-RegistryHost \$K3S_CUDA_IMAGE'
    $fn | Should -Match 'Invoke-DockerCli -DockerArgs @\("login", \$regHost'
  }
  It "with a bare Docker Hub override, login uses docker.io (behavioural)" {
    $K3S_CUDA_IMAGE = "owner/private-image:tag"
    $CUDA_PROBE_IMAGE = "nvidia/cuda:tag"
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "" } }
    Connect-GpuRegistry
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "login") -and ($DockerArgs -contains "docker.io") }
    $env:TRACEBLOC_REGISTRY_USERNAME = $null; $env:TRACEBLOC_REGISTRY_PASSWORD = $null
  }
  It "logs into BOTH the node-image host and the probe-image host when they differ (#616 Bugbot)" {
    $K3S_CUDA_IMAGE  = "nodehost.corp/tracebloc/k3s-cuda:tag"
    $CUDA_PROBE_IMAGE = "mirrorhost.corp/nvidia/cuda:tag"
    $env:TRACEBLOC_REGISTRY_USERNAME = "bot"; $env:TRACEBLOC_REGISTRY_PASSWORD = "tok"
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "" } }
    Connect-GpuRegistry
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "login") -and ($DockerArgs -contains "nodehost.corp") }
    Should -Invoke Invoke-DockerCli -ParameterFilter { ($DockerArgs -contains "login") -and ($DockerArgs -contains "mirrorhost.corp") }
    $env:TRACEBLOC_REGISTRY_USERNAME = $null; $env:TRACEBLOC_REGISTRY_PASSWORD = $null
  }
}

Describe "Confirm-GpuNode disables GPU when the node never advertises one (#616 Bugbot: air-gap plugin)" {
  BeforeAll { $script:GNSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the 0-GPU branch clears K3D_GPU_FLAG (CPU fallback) with a reason, not just a warning" {
    $fn = ($script:GNSRC -split 'function Confirm-GpuNode')[1]
    # it waits on allocatable nvidia.com/gpu ...
    $fn | Should -Match "nvidia\\\.com/gpu"
    # ... and if the count stays 0, it makes the node authoritative: disable GPU for this run.
    $else = ($fn -split '\$gpuCount -gt 0')[1]
    $else | Should -Match '\$script:K3D_GPU_FLAG = ""'
    $else | Should -Match '\$script:GPU_SKIP_REASON ='
  }
  It "runs before the chart values are written, so the CPU fallback reaches Install-ClientHelm" {
    # main flow: New-K3dCluster (Step 3) -> Confirm-GpuNode -> ... -> Install-ClientHelm (Step 5)
    $script:GNSRC | Should -Match 'if \(Install-GpuDevicePlugin\) \{\s*Confirm-GpuNode[\s\S]*Install-TraceblocCli'
  }
}

Describe "Adopted-reuse reconciles the GPU request (#616 Bugbot: no stale GPU under --reuse-values)" {
  BeforeAll { $script:ESRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the GPU value decision is made BEFORE the adopted/fresh split so both paths use it" {
    $script:ESRC | Should -Match 'BEFORE the adopted/fresh split[\s\S]{0,2200}?if \(-not \$adoptedReuse\)'
  }
  It "the adopted helm upgrade forces the GPU env keys to this run's decision via --set-string" {
    # else a prior release's GPU_REQUESTS/GPU_LIMITS survives --reuse-values after a CPU fallback.
    $adopted = ($script:ESRC -split 'if \(\$adoptedReuse\) \{')[1]
    $adopted | Should -Match '--set-string "env.GPU_REQUESTS=\$gpuVal"'
    $adopted | Should -Match '--set-string "env.GPU_LIMITS=\$gpuVal"'
    $adopted | Should -Match '--set-string "env.RUNTIME_CLASS_NAME=\$runtimeClass"'
  }
  It "the fresh (non-adopted) values.yaml still carries the same gpuVal/runtimeClass" {
    $script:ESRC | Should -Match 'GPU_LIMITS: "\$gpuVal"'
    $script:ESRC | Should -Match 'RUNTIME_CLASS_NAME: "\$runtimeClass"'
  }
}

Describe "Build-GpuNodeImage (#616: local build from public bases, no registry login)" {
  BeforeEach {
    $K3S_CUDA_IMAGE = "ghcr.io/tracebloc/k3s-cuda:v1.29.4-k3s1-cuda-12.4.1-base-ubuntu22.04"
    $K8S_VERSION = "v1.29.4-k3s1"; $CUDA_BASE_TAG = "12.4.1-base-ubuntu22.04"
    $script:GPU_SKIP_REASON = ""
    # The installer builds its temp paths from $env:TEMP (always set on Windows, where it
    # runs and where the Pester CI job runs). Seed it for a non-Windows local test host.
    if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }
    # NB: leave $script:K3S_CUDA_DOCKERFILE_B64 as the real embedded value; Start-Process is
    # mocked so the decoded content is never actually built here.
  }
  It "idempotent: a cached image with the CURRENT content hash that passes sanity is reused, nothing is built" {
    Mock Get-GpuBuildContentHash { "abc123def456" }
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 0; Output = "map[tracebloc.k3s-cuda-content:abc123def456]" } }  # present + current
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 0; Output = "k3s version v1.29.4+k3s1" } }  # runs k3s
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { throw "must not build when a healthy, current image already exists" }
    Build-GpuNodeImage | Should -BeTrue
    Should -Not -Invoke Start-Process
  }
  It "a STALE cached image (content hash mismatch) is rebuilt, not reused (#616 Bugbot: e.g. pre-NVIDIA_DISABLE_REQUIRE)" {
    Mock Get-GpuBuildContentHash { "newhash999999" }
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 0; Output = "map[tracebloc.k3s-cuda-content:oldhash000000]" } }  # present but OLD content
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 0; Output = "k3s version v1.29.4+k3s1" } }  # even if it "runs k3s"
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Out-Null
    Should -Invoke Start-Process -ParameterFilter { $ArgumentList -match 'build' }   # rebuilt despite the cached image running k3s
  }
  It "an existing image with the current hash but BROKEN (fails sanity) is NOT reused -- it rebuilds (#616 Bugbot)" {
    Mock Get-GpuBuildContentHash { "abc123def456" }
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 0; Output = "map[tracebloc.k3s-cuda-content:abc123def456]" } }  # present + current
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 127; Output = "exec /bin/k3s: no such file" } }  # broken
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Out-Null
    Should -Invoke Start-Process -ParameterFilter { $ArgumentList -match 'build' }
  }
  It "the build stamps the content-hash label so the reuse check can detect stale images (#616 Bugbot)" {
    $psrc = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $fn = ($psrc -split 'function Build-GpuNodeImage')[1]
    $fn | Should -Match '"--label", "tracebloc.k3s-cuda-content=\$contentHash"'
    $fn | Should -Match 'tracebloc\\\.k3s-cuda-content:\$contentHash'
  }
  It "builds locally with NO docker login and verifies k3s runs -> true" {
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 1; Output = "" } }              # not present yet
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 0; Output = "k3s version v1.29.4+k3s1" } }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Should -BeTrue
    Should -Invoke Start-Process -ParameterFilter { $ArgumentList -match 'build' }
    # the whole point: a GPU install never logs into a registry
    Should -Not -Invoke Invoke-DockerCli -ParameterFilter { $DockerArgs -contains "login" }
    $script:GPU_SKIP_REASON | Should -Be ""
  }
  It "build FAILS (non-zero exit) -> CPU fallback with a reason, returns false" {
    Mock Invoke-DockerCli { if ($DockerArgs -contains "inspect") { [pscustomobject]@{ Code = 1 } } else { [pscustomobject]@{ Code = 0; Output = "k3s version" } } }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 1; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "build failed"
  }
  It "a NULL build exit code is not a failure -- the k3s sanity check is authoritative (#616 Bugbot)" {
    # With redirected stdout/stderr, $proc.ExitCode can stay null after exit; a successful build
    # must not be misclassified as failed and silently lose GPU.
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 1 } }                             # not present -> build
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 0; Output = "k3s version v1.29.4+k3s1" } }  # image works
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = $null; HasExited = $true } }   # exit code unreadable
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Should -BeTrue
    $script:GPU_SKIP_REASON | Should -Be ""
  }
  It "a NULL build exit code with a BROKEN image still falls back to CPU (sanity check catches it)" {
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 1 } }
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 127; Output = "exec /bin/k3s: no such file" } }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = $null; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "didn't run k3s"
  }
  It "build TIMES OUT -> CPU fallback with a timeout reason, returns false" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 1 } }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $false } }
    Mock Wait-ProcessWithDeadline { $false }
    Build-GpuNodeImage | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "timed out"
  }
  It "built image can't run k3s (broken rootfs) -> CPU fallback, returns false" {
    Mock Invoke-DockerCli {
      if ($DockerArgs -contains "inspect") { return [pscustomobject]@{ Code = 1 } }
      if ($DockerArgs -contains "run")     { return [pscustomobject]@{ Code = 127; Output = "exec /bin/k3s: no such file" } }
      return [pscustomobject]@{ Code = 0; Output = "" }
    }
    Mock Start-Process { [pscustomobject]@{ ExitCode = 0; HasExited = $true } }
    Mock Wait-ProcessWithDeadline { $true }
    Build-GpuNodeImage | Should -BeFalse
    $script:GPU_SKIP_REASON | Should -Match "didn't run k3s"
  }
  It "a build-context error (temp-dir permission/AV/disk) degrades to CPU, never aborts (#616 Bugbot)" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 1 } }   # image not present -> proceeds to build
    Mock New-Item { throw "Access to the path is denied" }     # context dir creation fails
    Mock Start-Process { throw "must not reach docker build after a context error" }
    Build-GpuNodeImage | Should -BeFalse                        # returns, does NOT rethrow (no abort)
    $script:GPU_SKIP_REASON | Should -Match "couldn't be built"
  }
}

Describe "Embedded GPU build inputs stay in sync with docker/k3s-cuda (#616 drift guard)" {
  # The embed is base64 (ASCII, no bare-curl token) so the host-side style/ASCII guards don't
  # trip on the container Dockerfile; decode it and compare to the source file (LF-normalized).
  # $norm is defined INSIDE each It (Describe-body code runs at discovery, not run time).
  It "the embedded Dockerfile decodes to docker/k3s-cuda/Dockerfile" {
    $norm = { param([byte[]]$b) (([System.Text.Encoding]::UTF8.GetString($b)) -replace "`r`n","`n").TrimEnd() }
    $decoded = & $norm ([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $file = & $norm ([System.IO.File]::ReadAllBytes((Resolve-Path "$PSScriptRoot/../../docker/k3s-cuda/Dockerfile").Path))
    $decoded | Should -Be $file
  }
  It "the embedded RuntimeClass manifest decodes to docker/k3s-cuda/nvidia-runtimeclass.yaml" {
    $norm = { param([byte[]]$b) (([System.Text.Encoding]::UTF8.GetString($b)) -replace "`r`n","`n").TrimEnd() }
    $decoded = & $norm ([System.Convert]::FromBase64String($script:K3S_CUDA_RUNTIMECLASS_B64))
    $file = & $norm ([System.IO.File]::ReadAllBytes((Resolve-Path "$PSScriptRoot/../../docker/k3s-cuda/nvidia-runtimeclass.yaml").Path))
    $decoded | Should -Be $file
  }
  It "the embedded CDI drop-in decodes to docker/k3s-cuda/k3d-entrypoint-tracebloc-cdi.sh" {
    $norm = { param([byte[]]$b) (([System.Text.Encoding]::UTF8.GetString($b)) -replace "`r`n","`n").TrimEnd() }
    $decoded = & $norm ([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $file = & $norm ([System.IO.File]::ReadAllBytes((Resolve-Path "$PSScriptRoot/../../docker/k3s-cuda/k3d-entrypoint-tracebloc-cdi.sh").Path))
    $decoded | Should -Be $file
  }
  It "the node image disables the CUDA requirement gate so it boots on an older-but-valid driver (#616)" {
    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $decoded | Should -Match 'ENV NVIDIA_DISABLE_REQUIRE=1'
  }
  It "the node image ships ONLY the RuntimeClass, never the NVML device-plugin DaemonSet (#616 WSL2)" {
    # the NVML plugin can't init on WSL2; shipping it would register 0 GPUs and overwrite the
    # installer's node-capacity patch, stranding jobs.
    $df = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $df | Should -Match 'COPY nvidia-runtimeclass\.yaml /var/lib/rancher/k3s/server/manifests/'
    $df | Should -Not -Match 'COPY nvidia-device-plugin-daemonset\.yaml'
    $rc = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_RUNTIMECLASS_B64))
    $rc | Should -Match 'kind: RuntimeClass'
    $rc | Should -Match 'handler: nvidia'
    $rc | Should -Not -Match 'kind: DaemonSet'
  }
  It "the CDI setup ships as a k3d ENTRYPOINT DROP-IN, not the image ENTRYPOINT (#616 regression)" {
    # This shipped broken once: k3d REPLACES the image entrypoint with its own
    # /bin/k3d-entrypoint.sh (verified on a live node), so an ENTRYPOINT wrapper never ran and
    # the CDI spec was never generated. k3d runs /bin/k3d-entrypoint-*.sh drop-ins instead.
    $df = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $df | Should -Match 'COPY k3d-entrypoint-tracebloc-cdi\.sh /bin/k3d-entrypoint-tracebloc-cdi\.sh'
    $df | Should -Match 'chmod \+x /bin/k3d-entrypoint-tracebloc-cdi\.sh'
    # the image entrypoint must stay the stock k3s one -- never our script
    $df | Should -Match 'ENTRYPOINT \["/bin/k3s"\]'
    $df | Should -Not -Match 'ENTRYPOINT \["/usr/local/bin/tracebloc'
  }
  It "the drop-in RETURNS (never execs k3s) and always exits 0 so it can't abort the node (#616)" {
    # k3d runs drop-ins with `|| exit 1` and execs k3s itself afterwards.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Not -Match 'exec /bin/k3s'
    $boot.TrimEnd() | Should -Match 'exit 0$'
  }
  It "the CDI setup is a strict no-op without /dev/dxg (Linux/CPU nodes unaffected) (#616)" {
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match 'if \[ -e /dev/dxg \]'
  }
  It "the node re-asserts nvidia.com/gpu capacity across restarts (#616 Bugbot HIGH: kubelet zeroes it)" {
    # A manually patched extended resource is not durable -- the kubelet re-reports node
    # status on start, so a Docker Desktop / Windows restart would drop the GPU and strand
    # jobs. The node reconciles it itself, in the background, on every start.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match 'capacity/nvidia\.com~1gpu'
    $boot | Should -Match '--subresource=status'
    $boot | Should -Match 'TRACEBLOC_GPU_RECONCILE_SECS'
    # backgrounded so it can never delay/block k3s, and it re-patches only when missing/0
    $boot | Should -Match "case \`"\`$current\`" in"
    $boot | Should -Match '\) </dev/null >/dev/null 2>&1 &'
  }
  It "the libdxcore injection MIRRORS the generator's indentation, never hardcodes it (#616 regression)" {
    # nvidia-ctk (yaml.v3) indents with 4 spaces, so the original `^  mounts:$` anchor never
    # matched and libdxcore was silently never injected -> pods died with a misleading
    # "CUDA driver version is insufficient" error. Verified on a live box.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match '\[\[:space:\]\]\*mounts:'      # indent-agnostic anchor
    $boot | Should -Not -Match "\^  mounts:\\\$"           # never the fixed 2-space anchor
    $boot | Should -Match 'item = substr\(\$0, 1, RLENGTH - 2\)'   # mirror the item's indent
    # and the edit is only adopted if the spec still parses
    $boot | Should -Match 'nvidia-ctk cdi list'
  }
  It "the toolkit version is PINNED with a fallback -- reproducible across machines (#616)" {
    # unpinned, two machines built weeks apart get different toolkit builds, and a release that
    # changes the CDI YAML shape breaks GPU on new installs while old ones keep working.
    $df = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $df | Should -Match 'ARG NCT_VERSION='
    $df | Should -Match 'nvidia-container-toolkit=\$\{NCT_VERSION\}'
    # a pin that has aged out of the repo must NOT fail the build (that would cost GPU entirely)
    $df | Should -Match 'falling back to latest'
    $df | Should -Match 'nvidia-ctk --version'          # record what actually got installed
  }
  It "EVERY `cdi list` use is availability-gated -- incl. the revert (#616 Bugbot)" {
    # The revert originally called `cdi list` unconditionally, so a toolkit without that
    # subcommand reverted a PERFECTLY GOOD libdxcore injection -- and the installer then reported
    # "spec is missing libdxcore", which is false and unactionable. Verified with a dash harness:
    # with `cdi list` absent the injection survives and the GPU is advertised.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    # exactly two availability probes: one per call site (revert + cdi_ok)
    ([regex]::Matches($boot, 'nvidia-ctk cdi list --help')).Count | Should -Be 2
    # and every EXECUTABLE bare use (comments excluded) sits inside such a guard
    $bare = @($boot -split "`n" | Where-Object { $_ -match 'nvidia-ctk cdi list' -and $_ -notmatch '--help' -and $_.TrimStart() -notmatch '^#' })
    $bare.Count | Should -Be 2
    # the revert shape: guard, then the vetoing call
    $boot | Should -Match 'cdi list --help >/dev/null 2>&1; then\s*\n\s*if ! nvidia-ctk cdi list'
    # the cdi_ok shape: guard, then veto by clearing the flag
    $boot | Should -Match 'cdi list --help >/dev/null 2>&1; then\s*\n\s*nvidia-ctk cdi list >/dev/null 2>&1 \|\| cdi_ok=0'
  }
  It "the CDI gate does NOT require `nvidia-ctk cdi list` to exist (#616: no false negative)" {
    # `cdi list` is version-dependent; keying the decision on it would disable a working GPU on a
    # toolkit build that lacks the subcommand. Structural, format-stable checks decide instead.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match "grep -q 'nvidia\\.com/gpu'"
    $boot | Should -Match "grep -q '/dev/dxg'"
    $boot | Should -Match "grep -q 'libdxcore"
    # cdi list is only an EXTRA veto, and only when available
    $boot | Should -Match 'nvidia-ctk cdi list --help'
  }
  It "the reconciler only advertises GPU when CDI is USABLE (#616 Bugbot HIGH)" {
    # re-asserting capacity onto a node whose CDI spec is broken is worse than not advertising:
    # pods schedule then fail CUDA with no cluster-level signal.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match 'cdi_ok=0'
    $boot | Should -Match "grep -q 'libdxcore"
    $boot | Should -Match 'nvidia-ctk cdi list'
    $boot | Should -Match 'if \[ "\$cdi_ok" = "1" \]'
  }
  It "libdxcore is DISCOVERED across known locations, not hardcoded to one path (#616 Bugbot)" {
    # it lives in different places across Docker Desktop / WSL2 versions; a miss silently
    # skipped the injection while the spec still looked fine.
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match '/usr/lib/wsl/lib/libdxcore\.so'
    $boot | Should -Match '/usr/lib/wsl/drivers/\*/libdxcore\.so'
    $boot | Should -Match 'ldconfig -p'                       # last-resort discovery
    $boot | Should -Match 'awk -v dx="\$DXCORE"'              # mounted at the path found
  }
  It "the drop-in wires CDI on WSL2 (mode=cdi baked, generate spec, inject libdxcore) (#616)" {
    $boot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))
    $boot | Should -Match 'nvidia-ctk cdi generate --mode=wsl'
    $boot | Should -Match 'libdxcore\.so'
    $boot | Should -Not -Match 'exec /bin/k3s'
    $df = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    $df | Should -Match 'nvidia-container-runtime\.mode=cdi'
    $df | Should -Match 'k3d-entrypoint-tracebloc-cdi\.sh'
  }
}

Describe "Get-GpuBuildFailureReason (#616: every GPU failure names an actionable cause)" {
  BeforeEach { $CUDA_BASE_TAG = "12.4.1-base-ubuntu22.04" }
  It "old Docker Desktop / missing BuildKit labs frontend -> says update Docker Desktop" {
    $r = Get-GpuBuildFailureReason -BuildOutput 'failed to solve with frontend dockerfile.v0' -ExitCode 1
    $r | Should -Match 'Docker Desktop is too old'
    $r | Should -Match 'TRACEBLOC_K3S_CUDA_IMAGE'      # the escape hatch
  }
  It "unknown --exclude flag (older frontend) is also recognised" {
    (Get-GpuBuildFailureReason -BuildOutput 'unknown flag: --exclude' -ExitCode 1) | Should -Match 'too old'
  }
  It "full disk -> says free up space" {
    (Get-GpuBuildFailureReason -BuildOutput 'write /tmp/x: no space left on device' -ExitCode 1) | Should -Match 'ran out of disk'
  }
  It "retired CUDA tag -> names the tag and the override" {
    $r = Get-GpuBuildFailureReason -BuildOutput 'nvcr.io/nvidia/cuda:12.4.1: manifest unknown' -ExitCode 1
    $r | Should -Match 'no longer exists upstream'
    $r | Should -Match 'TRACEBLOC_CUDA_BASE_TAG'
  }
  It "TLS-inspecting proxy -> points at the CA bundle" {
    $r = Get-GpuBuildFailureReason -BuildOutput 'x509: certificate signed by unknown authority' -ExitCode 1
    $r | Should -Match 'TRACEBLOC_CA_BUNDLE'
  }
  It "blocked/offline registry -> points at the mirror override" {
    $r = Get-GpuBuildFailureReason -BuildOutput 'dial tcp 1.2.3.4:443: i/o timeout' -ExitCode 1
    $r | Should -Match "couldn't download its base images"
    $r | Should -Match 'TRACEBLOC_IMAGE_REGISTRY'
  }
  It "registry rate limit is called out separately" {
    (Get-GpuBuildFailureReason -BuildOutput 'toomanyrequests: rate limit exceeded' -ExitCode 1) | Should -Match 'rate-limited'
  }
  It "an unrecognised failure still names the exit code AND the log" {
    $r = Get-GpuBuildFailureReason -BuildOutput 'something odd happened' -ExitCode 7
    $r | Should -Match 'exit 7'
    $r | Should -Match 'install log'
  }
  It "every branch ends by stating the outcome (running CPU-only)" {
    foreach ($o in @('failed to solve with frontend', 'no space left on device', 'manifest unknown',
                     'x509: bad cert', 'i/o timeout', 'toomanyrequests', 'mystery')) {
      (Get-GpuBuildFailureReason -BuildOutput $o -ExitCode 1) | Should -Match 'running CPU-only'
    }
  }
}

Describe "Bounded process argument quoting round-trips through CommandLineToArgvW (backend#2455)" {
  # #616 quoted whitespace-bearing args but left INNER QUOTES unescaped, so any arg carrying both a
  # space and a `"` (and even a quote with no space, which took the pass-through branch) reached the
  # child with its quotes silently consumed by CommandLineToArgvW -- the #817 false-refusal. The fix
  # escapes per the real CommandLineToArgvW/MSVCRT rules in ConvertTo-Win32Arg. These tests pin the
  # encoding and prove the round-trip: encode(argv) then re-split == argv, as SINGLE tokens.
  BeforeAll {
    $script:QSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw

    # A from-spec reimplementation of how CommandLineToArgvW (and the CRT every well-behaved Windows
    # program links) re-splits a command line, MINUS the special argv[0] rules -- $psi.Arguments is
    # argv[1..] only ($psi.FileName is passed separately). Pure PowerShell so the round-trip runs on
    # this suite's Linux/macOS CI, where shell32!CommandLineToArgvW does not exist; the Windows-only
    # test below cross-checks the SAME encoder against the real API.
    function script:Split-LikeArgvW {
      param([string]$CommandLine)
      $out = [System.Collections.Generic.List[string]]::new()
      $cur = [System.Text.StringBuilder]::new()
      $inQuotes = $false; $has = $false; $i = 0; $n = $CommandLine.Length
      while ($i -lt $n) {
        $c = $CommandLine[$i]
        if ($c -eq '\') {
          $nb = 0
          while ($i -lt $n -and $CommandLine[$i] -eq '\') { $nb++; $i++ }
          if ($i -lt $n -and $CommandLine[$i] -eq '"') {
            [void]$cur.Append('\' * [int][math]::Floor($nb / 2))
            if ($nb % 2 -eq 0) { $inQuotes = -not $inQuotes } else { [void]$cur.Append('"') }
            $has = $true; $i++
          } else {
            [void]$cur.Append('\' * $nb); $has = $true
          }
        } elseif ($c -eq '"') {
          if ($inQuotes -and ($i + 1) -lt $n -and $CommandLine[$i + 1] -eq '"') {
            [void]$cur.Append('"'); $i += 2                 # "" inside a quoted range -> literal " (CRT 2008+)
          } else {
            $inQuotes = -not $inQuotes; $has = $true; $i++
          }
        } elseif (($c -eq ' ' -or $c -eq "`t") -and -not $inQuotes) {
          if ($has) { $out.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
          $i++
        } else {
          [void]$cur.Append($c); $has = $true; $i++
        }
      }
      if ($has) { $out.Add($cur.ToString()) }
      return $out.ToArray()
    }

    # Build the line EXACTLY as Invoke-BoundedProcess does (ConvertTo-Win32Arg is the single source
    # of truth; the join is the one line the helper wraps around it), then recover it. A throwaway
    # program token absorbs the argv[0] rules, mirroring how the OS prepends $psi.FileName.
    function script:Roundtrip { param([string[]]$Argv)
      $line = (($Argv | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
      $recovered = @(script:Split-LikeArgvW ("prog.exe " + $line))
      [pscustomobject]@{ Line = $line; Argv = @($recovered | Select-Object -Skip 1) }
    }
  }

  It "Invoke-BoundedProcess delegates to ConvertTo-Win32Arg and drops the unescaped escape hatch (source guard)" {
    $fn = (($script:QSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    # Match the actual CALL, not just the name: a comment in the body also mentions
    # ConvertTo-Win32Arg, so a bare-name match would still pass if the call were
    # deleted -- a guard that can't detect its own removal (Bugbot #845).
    $fn | Should -Match 'ForEach-Object \{ ConvertTo-Win32Arg \$_'
    $fn | Should -Not -Match 'notmatch'          # the old `^".*"$` already-quoted escape hatch is gone
  }

  It "callers pass RAW args -- Set-NodeGpuCapacity no longer pre-quotes the patch file (source guard)" {
    $sn = [regex]::Match($script:QSRC, 'function Set-NodeGpuCapacity \{.*?\n\}', 'Singleline').Value
    $sn | Should -Match '"--patch-file", \$patchFile,'
    $sn | Should -Not -Match 'patchFile`"'       # the old `"$patchFile`" wrapping
  }

  It "ConvertTo-Win32Arg emits the exact CommandLineToArgvW encoding (golden)" {
    ConvertTo-Win32Arg ''             | Should -BeExactly '""'          # empty survives as a present arg
    ConvertTo-Win32Arg 'plain'        | Should -BeExactly 'plain'       # nothing to escape -> untouched
    ConvertTo-Win32Arg '--format=csv' | Should -BeExactly '--format=csv'
    ConvertTo-Win32Arg 'a b'          | Should -BeExactly '"a b"'       # whitespace
    ConvertTo-Win32Arg 'a"b'          | Should -BeExactly '"a\"b"'      # quote, no space -> still must quote
    ConvertTo-Win32Arg 'a b"c'        | Should -BeExactly '"a b\"c"'    # whitespace + quote (the #817 bug)
    ConvertTo-Win32Arg 'a\b'          | Should -BeExactly 'a\b'         # lone backslash is literal
    ConvertTo-Win32Arg 'C:\a b\'      | Should -BeExactly '"C:\a b\\"'  # trailing \ doubled before close quote
    ConvertTo-Win32Arg 'a\"b'         | Should -BeExactly '"a\\\"b"'    # backslashes before a quote
  }

  It "round-trips representative args back to the ORIGINAL single tokens" {
    $cases = @(
      ,@('plain')
      ,@('a b')                                  # whitespace
      ,@('has"quote')                            # embedded quote
      ,@('a b"c')                                # whitespace + quote
      ,@('')                                     # empty string
      ,@('a\"b')                                 # backslashes before a quote
      ,@('C:\Users\First Last\tb.json')          # spaced temp path (Set-NodeGpuCapacity's --patch-file)
      ,@('ends\with\backslash\')                 # trailing backslash, unquoted fast path
      ,@('login','ghcr.io','-u','First "Q" Last','--password-stdin')  # registry user w/ space+quote
      ,@('--format','{{.Names}} {{.Label "k3d.role"}}')              # the #817 shape, now safe
    )
    foreach ($argv in $cases) {
      $rt = script:Roundtrip -Argv $argv
      $rt.Argv.Count | Should -Be $argv.Count -Because "the line was: $($rt.Line)"
      for ($k = 0; $k -lt $argv.Count; $k++) {
        $rt.Argv[$k] | Should -BeExactly $argv[$k] -Because "token $k of the line: $($rt.Line)"
      }
    }
  }

  It "the encoder agrees with the real shell32!CommandLineToArgvW (Windows only)" -Skip:(-not $IsWindows) {
    $sig = @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@
    Add-Type -Namespace TbWin32 -Name Argv -MemberDefinition $sig
    function realArgv([string]$cl) {
      $n = 0; $p = [TbWin32.Argv]::CommandLineToArgvW($cl, [ref]$n)
      try {
        # Collect into a typed List and return via the ,$arr idiom: the array then
        # survives assignment at 0/1 elements AND keeps empty-string elements. The
        # old `,@($r) | Select-Object -Skip 1` dropped a trailing "" (backend#2455).
        $out = [System.Collections.Generic.List[string]]::new()
        for ($j = 0; $j -lt $n; $j++) {
          $out.Add([System.Runtime.InteropServices.Marshal]::PtrToStringUni(
            [System.Runtime.InteropServices.Marshal]::ReadIntPtr($p, $j * [System.IntPtr]::Size)))
        }
        return ,$out.ToArray()
      } finally { [void][TbWin32.Argv]::LocalFree($p) }   # documented: the caller frees with LocalFree
    }
    # Newline-separated ,@(...) so each $argv iterates as a FLAT [string[]] — the
    # comma-separated @((,@(...)), ...) form nests each case one level deeper, so
    # ConvertTo-Win32Arg was handed an Object[] and threw before a single comparison
    # ran, leaving this real-API cross-check inert on Windows while macOS skipped it
    # (Bugbot / LukasWodka on #845). Mirrors the round-trip test's $cases shape.
    $cases = @(
      ,@('a b"c')
      ,@('a\"b')
      ,@('C:\a b\')
      ,@('')
      ,@('x')
    )
    foreach ($argv in $cases) {
      $line = (($argv | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
      # Assign (don't pipe) and slice off the prog.exe argv[0] by index — piping
      # through Select-Object -Skip 1 lost a trailing empty arg (backend#2455).
      $full = realArgv ("prog.exe " + $line)
      # Drop the prog.exe argv[0] with an explicit index loop, NOT a range slice:
      # $full[1..($full.Count-1)] collapses to a SCALAR string under Windows
      # PowerShell when it selects one element, so $got[$k] then indexed into the
      # string's characters ("got a" for "a b\"c") even though shell32 returned the
      # arg intact. The loop keeps $got a real array on every host (backend#2455).
      $got = @()
      for ($m = 1; $m -lt $full.Count; $m++) { $got += $full[$m] }
      $because = "arg=[$($argv -join '|')] encoded=[$line] shell32=[$($full -join '|')]"
      $got.Count | Should -Be $argv.Count -Because $because
      for ($k = 0; $k -lt $argv.Count; $k++) { $got[$k] | Should -BeExactly $argv[$k] -Because $because }
    }
  }
}

Describe "docker-buildx and k3d-create command lines escape inner quotes via ConvertTo-Win32Arg (backend#2545)" {
  # backend#2455 (#845) fixed the SHARED Invoke-BoundedProcess joiner, but two Start-Process command
  # lines built inline elsewhere kept the naive `wrap-only-if-it-has-a-space` quoting with the inner
  # `"` UNescaped: `docker buildx build` (Build-GpuNodeImage) and `k3d cluster create` (New-K3dCluster).
  # -ArgumentList <one string> is handed to the child verbatim, exactly like $psi.Arguments, so an arg
  # carrying BOTH a space and a `"` had its quotes silently consumed by CommandLineToArgvW's re-split --
  # the #817 corruption, in two more places. These tests exercise the EXACT shipped builder expressions
  # (pulled from source, never transcribed) and prove such an arg survives the round-trip as ONE token.
  BeforeAll {
    $script:B2545SRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw

    # A from-spec CommandLineToArgvW re-splitter, MINUS the argv[0] special-casing (a throwaway program
    # token below absorbs those). Mirrors the parser the backend#2455 block uses -- whose Windows-only
    # test cross-checks it against the real shell32!CommandLineToArgvW -- duplicated here so this block
    # stands alone and does not depend on another Describe's BeforeAll having run first.
    function script:Split-Cmdline2545 {
      param([string]$CommandLine)
      $out = [System.Collections.Generic.List[string]]::new()
      $cur = [System.Text.StringBuilder]::new()
      $inQuotes = $false; $has = $false; $i = 0; $n = $CommandLine.Length
      while ($i -lt $n) {
        $c = $CommandLine[$i]
        if ($c -eq '\') {
          $nb = 0
          while ($i -lt $n -and $CommandLine[$i] -eq '\') { $nb++; $i++ }
          if ($i -lt $n -and $CommandLine[$i] -eq '"') {
            [void]$cur.Append('\' * [int][math]::Floor($nb / 2))
            if ($nb % 2 -eq 0) { $inQuotes = -not $inQuotes } else { [void]$cur.Append('"') }
            $has = $true; $i++
          } else {
            [void]$cur.Append('\' * $nb); $has = $true
          }
        } elseif ($c -eq '"') {
          if ($inQuotes -and ($i + 1) -lt $n -and $CommandLine[$i + 1] -eq '"') {
            [void]$cur.Append('"'); $i += 2
          } else {
            $inQuotes = -not $inQuotes; $has = $true; $i++
          }
        } elseif (($c -eq ' ' -or $c -eq "`t") -and -not $inQuotes) {
          if ($has) { $out.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
          $i++
        } else {
          [void]$cur.Append($c); $has = $true; $i++
        }
      }
      if ($has) { $out.Add($cur.ToString()) }
      return $out.ToArray()
    }

    # Pull the RHS of a builder's `$x = (...) -join " "` assignment straight out of the shipped source,
    # so these tests can never pass against a transcription that has drifted from the line the installer
    # actually runs. Non-greedy to the FIRST `-join <sep>`; the separator char class tolerates either
    # quote style (`-join " "` or `-join ' '`) so a benign requote does not turn into a false failure.
    function script:Get-BuilderRhs {
      param([Parameter(Mandatory)][string]$Lhs)
      $sep = '["' + "'" + ']'   # a character class matching a single or double quote
      $m = [regex]::Match($script:B2545SRC, [regex]::Escape($Lhs) + '\s*=\s*([\s\S]*?-join\s+' + $sep + ' ' + $sep + ')')
      if (-not $m.Success) { throw "could not find the builder assignment for $Lhs in install-k8s.ps1" }
      return $m.Groups[1].Value
    }

    # Encode $BuilderArgs through the shipped RHS, re-split, and drop the throwaway argv[0] by INDEX
    # (a range slice collapses to a scalar string at one element under Windows PowerShell 5.1; the loop
    # keeps $got a real array on every host, the lesson from backend#2455).
    function script:ThroughBuilder {
      param([Parameter(Mandatory)][string]$Lhs, [Parameter(Mandatory)][string[]]$BuilderArgs)
      # The shipped RHS names either $buildArgs (buildx) or $k3dArgs (k3d); bind both so whichever the
      # extracted expression references evaluates against the crafted list.
      $buildArgs = $BuilderArgs
      $k3dArgs   = $BuilderArgs
      $line = Invoke-Expression (script:Get-BuilderRhs $Lhs)
      $full = @(script:Split-Cmdline2545 ("prog.exe " + $line))
      $got = @(); for ($m = 1; $m -lt $full.Count; $m++) { $got += $full[$m] }
      [pscustomobject]@{ Line = $line; Argv = $got }
    }
  }

  It "the docker-buildx builder delegates to ConvertTo-Win32Arg, not the naive space-only quoting (source guard)" {
    $rhs = script:Get-BuilderRhs '$argStr'
    $rhs | Should -Match 'ConvertTo-Win32Arg \$_'
    $rhs | Should -Not -Match '-match'          # the old `if ($_ -match '[\s]') { ... }` quote branch is gone
  }

  It "the k3d-create builder delegates to ConvertTo-Win32Arg, not the naive space/@ quoting (source guard)" {
    $rhs = script:Get-BuilderRhs '$k3dArgString'
    $rhs | Should -Match 'ConvertTo-Win32Arg \$_'
    $rhs | Should -Not -Match '-match'          # the old `if ($_ -match '[\s@]') { ... }` quote branch is gone
  }

  It "an arg with whitespace AND a quote survives the docker-buildx builder as ONE token" {
    # A --label value carrying both a space and a `"` -- the exact class the old builder mangled: its
    # inner quotes were consumed by the re-split and it merged with the adjacent token.
    $buildArgs = @('build', '--label', 'tracebloc.title=k3s "cuda" node', '-t', 'img:tag', 'C:\Users\First Last\ctx')
    $rt = script:ThroughBuilder -Lhs '$argStr' -BuilderArgs $buildArgs
    $rt.Argv.Count | Should -Be $buildArgs.Count -Because "line: $($rt.Line)"
    for ($k = 0; $k -lt $buildArgs.Count; $k++) {
      $rt.Argv[$k] | Should -BeExactly $buildArgs[$k] -Because "token $k of: $($rt.Line)"
    }
  }

  It "an arg with whitespace AND a quote survives the k3d-create builder as ONE token; a bare @ arg still round-trips unquoted" {
    # `note=...` carries both a space and a `"` (the fix); `/host:/node@all` carries an `@` but no space
    # or quote, so the old `@` branch used to wrap it. `@` is not special to CommandLineToArgvW, so
    # dropping that branch is a no-op: the bare token re-splits to the identical single token.
    $k3dArgs = @('cluster', 'create', 'tb', '-v', '/host:/node@all', '--k3s-node-label', 'note=a "b" c@server:*')
    $rt = script:ThroughBuilder -Lhs '$k3dArgString' -BuilderArgs $k3dArgs
    $rt.Argv.Count | Should -Be $k3dArgs.Count -Because "line: $($rt.Line)"
    for ($k = 0; $k -lt $k3dArgs.Count; $k++) {
      $rt.Argv[$k] | Should -BeExactly $k3dArgs[$k] -Because "token $k of: $($rt.Line)"
    }
    # The intentional behaviour change: the bare `@` arg is now emitted WITHOUT wrapping quotes, and
    # still recovers as one token above -- proving dropping the `@` quote branch changed nothing.
    $rt.Line.Contains(' /host:/node@all ') | Should -BeTrue  -Because "bare @ arg is a standalone unquoted token: $($rt.Line)"
    $rt.Line.Contains('"/host:/node@all"') | Should -BeFalse -Because "the old builder wrapped it in quotes: $($rt.Line)"
  }

  It "Split-Cmdline2545 (this block's decoder/oracle) agrees with the real shell32!CommandLineToArgvW (Windows only)" -Skip:(-not $IsWindows) {
    # LukasWodka on #858: this block's re-splitter is the ORACLE the builder tests above trust, and --
    # unlike the backend#2455 one -- it was only asserted (in a comment) to "mirror" the real API, not
    # checked against it. If the two from-spec decoders ever drift, every encoder test here would be
    # validating ConvertTo-Win32Arg against a decoder that no longer matches Windows, and the
    # cross-check on the OTHER copy would say nothing about this one. So pin THIS decoder to shell32
    # directly, with the same Windows-gated P/Invoke #845 uses (a distinct namespace so both blocks'
    # Add-Type calls can coexist in one session). shell32 is why the check is Windows-only -- it does
    # not exist off-Windows, exactly as #845's is gated.
    $sig = @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@
    Add-Type -Namespace TbWin32b -Name Argv -MemberDefinition $sig
    function realArgv2545([string]$cl) {
      $n = 0; $p = [TbWin32b.Argv]::CommandLineToArgvW($cl, [ref]$n)
      try {
        # Typed List + the ,$arr return idiom: survives 0/1 elements and keeps a trailing "" (the
        # `| Select-Object -Skip 1` form dropped it -- backend#2455). Caller frees with LocalFree.
        $out = [System.Collections.Generic.List[string]]::new()
        for ($j = 0; $j -lt $n; $j++) {
          $out.Add([System.Runtime.InteropServices.Marshal]::PtrToStringUni(
            [System.Runtime.InteropServices.Marshal]::ReadIntPtr($p, $j * [System.IntPtr]::Size)))
        }
        return ,$out.ToArray()
      } finally { [void][TbWin32b.Argv]::LocalFree($p) }
    }
    # Flat [string[]] per case (the ,@(...) idiom), exercising each branch of the re-splitter:
    # whitespace+quote, backslashes-before-quote, trailing backslash, empty, the two @-bearing k3d
    # shapes, and a plain token. Mirrors the #2455 cross-check's $cases shape.
    $cases = @(
      ,@('a b"c')
      ,@('a\"b')
      ,@('C:\a b\')
      ,@('')
      ,@('/host:/node@all')
      ,@('note=a "b" c@server:*')
      ,@('x')
    )
    foreach ($argv in $cases) {
      $line = "prog.exe " + (($argv | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
      # Drop the prog.exe argv[0] with an INDEX loop, not a range slice: $full[1..($full.Count-1)]
      # collapses to a scalar string at one element under Windows PowerShell 5.1 (backend#2455).
      $realFull = realArgv2545 $line
      $real = @(); for ($m = 1; $m -lt $realFull.Count; $m++) { $real += $realFull[$m] }
      $mineFull = @(script:Split-Cmdline2545 $line)
      $mine = @(); for ($m = 1; $m -lt $mineFull.Count; $m++) { $mine += $mineFull[$m] }
      $because = "arg=[$($argv -join '|')] line=[$line] shell32=[$($realFull -join '|')] mine=[$($mineFull -join '|')]"
      # This block's decoder must match the real API token-for-token...
      $mine.Count | Should -Be $real.Count -Because $because
      for ($k = 0; $k -lt $real.Count; $k++) { $mine[$k] | Should -BeExactly $real[$k] -Because $because }
      # ...and the real API must recover the ORIGINAL args (round-trip completeness of the encoder).
      $real.Count | Should -Be $argv.Count -Because $because
      for ($k = 0; $k -lt $argv.Count; $k++) { $real[$k] | Should -BeExactly $argv[$k] -Because $because }
    }
  }
}

Describe "Bounded process survives a child that closes stdin first (broken pipe)" {
  BeforeAll {
    $script:BPSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    # Load the REAL function rather than a copy of it, so this cannot pass while the
    # shipped one throws -- the whole failure mode being tested is an unguarded call.
    # Pull in its arg-quoting dependency too (backend#2455), so the redefined copy
    # doesn't fall back to a missing ConvertTo-Win32Arg.
    $cw = (($script:BPSRC -split 'function ConvertTo-Win32Arg')[1] -split '\nfunction ')[0]
    Invoke-Expression "function ConvertTo-Win32Arg $cw"
    $fn = (($script:BPSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    Invoke-Expression "function Invoke-BoundedProcess $fn"
  }

  It "returns the child's verdict instead of throwing when the pipe is already closed" {
    # THE RACE, REPRODUCED. `true` ignores stdin and exits immediately, so the write
    # below lands on a closed pipe -- the exact SocketException/IOException that took
    # down Pester (ubuntu-latest) on client's main tip after the 2026-08-16 prod hop.
    #
    # Big enough to outlive the child: a short string fits the OS pipe buffer and is
    # accepted even after exit, so a small payload would pass with the bug present.
    $payload = "x" * 200000
    # `Arguments` is a mandatory [string[]], so an EMPTY array binds as null and the
    # call fails before the race is reached -- a test that never tested. `true`
    # ignores whatever it is given and exits 0 regardless.
    $exe = if ($IsWindows) { "cmd.exe" } else { "/usr/bin/true" }
    $argv = if ($IsWindows) { @("/c", "exit", "0") } else { @("ignored") }

    # `$script:` because a plain assignment inside the Should -Not -Throw scriptblock
    # stays in that block's scope and reads back as $null out here -- which asserts
    # nothing while looking like it asserts something.
    $script:bpResult = $null
    { $script:bpResult = Invoke-BoundedProcess -FileName $exe -Arguments $argv -Stdin $payload -TimeoutSec 30 } |
      Should -Not -Throw
    # And it still reports the CHILD, not our plumbing: the guard swallows the pipe
    # error, it does not invent a result.
    $script:bpResult.Code | Should -Be 0
  }

  It "the stdin write is guarded, like Start and Kill already were (source guard)" {
    # Belt and braces to the behavioural case above: if someone unwraps the try/catch,
    # this fails even on a machine where the race happens not to fire.
    #
    # Matches the WRITE GUARD ONLY. It deliberately does not pin the statement that
    # follows Write() inside the try: the previous version of this assertion was one
    # literal blob covering `Write(...); Close()` together, so it spoke for two
    # independent properties at once and had to be rewritten to change either. The
    # Close() placement is asserted on its own, below.
    $fn = (($script:BPSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    $fn | Should -Match '\$proc\.StandardInput\.Write\(\$Stdin\)'
    $fn | Should -Match 'try \{ \$proc\.StandardInput\.Write\(\$Stdin\) \} catch'
  }

  It "stdin is closed even when the write throws -- Close() is in a finally (backend#2246)" {
    # Chained as `try { Write(...); Close() } catch { }`, a throw from Write() skipped
    # Close() entirely: the child never received EOF and our write handle stayed open.
    # Because the one exception actually seen here (broken pipe) is swallowed by design,
    # the skip was silent. Asserting the `finally` is what makes it non-silent.
    $fn = (($script:BPSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'finally \{ try \{ \$proc\.StandardInput\.Close\(\) \} catch \{ \} \}'
    # ...and NOT back inside the same try as the write, which is the shape that regressed.
    $fn | Should -Not -Match 'Write\(\$Stdin\); \$proc\.StandardInput\.Close\(\)'
  }

  It "stdout is drained BEFORE the stdin write, so a chatty child cannot deadlock (backend#2246)" {
    # ORDERING GUARD, derived by position from the real function body rather than from a
    # transcription of it: the ReadToEndAsync() that drains stdout must appear ahead of
    # the stdin write. Reversed -- which is how this shipped -- a child that both reads
    # stdin and writes output wedges: it fills its stdout pipe, stops reading stdin, our
    # Write() blocks, and WaitForExit() is never reached, so -TimeoutSec never fires at
    # all. The behavioural proof is the case below; this catches a reorder on any
    # platform, including one where the deadlock case is skipped.
    $fn = (($script:BPSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    $drain = $fn.IndexOf('$proc.StandardOutput.ReadToEndAsync()')
    $write = $fn.IndexOf('$proc.StandardInput.Write($Stdin)')
    # Fail closed: if either anchor is gone this function has been restructured, and an
    # index of -1 must read as "cannot tell", never as agreement (a bare -lt would let
    # two missing anchors compare equal and pass).
    $drain | Should -BeGreaterThan -1 -Because 'the stdout drain anchor must exist to be ordered'
    $write | Should -BeGreaterThan -1 -Because 'the stdin write anchor must exist to be ordered'
    $drain | Should -BeLessThan $write -Because 'draining stdout after the stdin write is the deadlock'
  }

  # Skip condition is the ACTUAL precondition -- "is there a /bin/cat to run" -- not a
  # platform guess. `-Skip:$IsWindows` would have been wrong twice: $IsWindows does not
  # exist under Windows PowerShell 5.1 (the version install.ps1 pins), so it evaluates
  # $null there, the test would run, /bin/cat would not exist, and a missing binary would
  # be reported as this deadlock regressing.
  It "a chatty child that reads stdin returns its real verdict, not a hang (backend#2246)" -Skip:(-not (Test-Path '/bin/cat')) {
    # THE DEADLOCK, REPRODUCED. `cat` reads stdin AND echoes every byte to stdout, and
    # stdout is redirected -- the exact shape of the caller Bugbot named, `docker exec -i
    # <node> sh`, where the shell consumes a script on stdin and the script prints.
    #
    # 200 KB deliberately exceeds the ~64 KiB OS pipe buffer. A payload that FITS the
    # buffer cannot deadlock and would pass with the bug present, which is why the
    # existing broken-pipe case above does not cover this one despite also being 200 KB:
    # `/usr/bin/true` produces no output, so there is no stdout backpressure.
    #
    # Run in a JOB with an OUTER watchdog because the failure is an unbounded HANG, not a
    # 124 -- a direct call would hang the whole Pester run rather than fail this test.
    # Measured before the fix: past 60s with -TimeoutSec 20. After: ~0.2s.
    $job = Start-Job -ScriptBlock {
      param($src)
      # This runspace is isolated, so Invoke-BoundedProcess's dependency must come along too:
      # it now delegates arg-quoting to ConvertTo-Win32Arg (backend#2455).
      $cw = (($src -split 'function ConvertTo-Win32Arg')[1] -split '\nfunction ')[0]
      Invoke-Expression "function ConvertTo-Win32Arg $cw"
      $fn = (($src -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
      Invoke-Expression "function Invoke-BoundedProcess $fn"
      $r = Invoke-BoundedProcess -FileName "/bin/cat" -Arguments @("-") -Stdin ("x" * 200000) -TimeoutSec 20
      [pscustomobject]@{ Code = $r.Code; OutLen = "$($r.Output)".Length }
    } -ArgumentList $script:BPSRC
    $finished = Wait-Job $job -Timeout 60
    $res = if ($finished) { Receive-Job $job } else { $null }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    # Name the specific failure. "It hung" and "it returned 124" are different defects and
    # this must not report one as the other.
    $finished | Should -Not -BeNullOrEmpty -Because 'the call deadlocked: it outlived a 60s watchdog despite -TimeoutSec 20'
    $res.Code | Should -Not -Be 124 -Because 'a bounded write should not have to be killed by the timeout'
    $res.Code | Should -Be 0 -Because "cat should exit 0; got $($res.Code)"
    # And the payload really round-tripped -- proof the child was drained, not merely that
    # something returned quickly.
    $res.OutLen | Should -Be 200000 -Because "the full payload must come back; got $($res.OutLen) bytes"
  }
}

Describe "GPU setup fails fast when preflight already found the hosts unreachable (#616 Bugbot)" {
  BeforeAll { $script:FFSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "preflight records the unreachable GPU host" {
    $script:FFSRC | Should -Match '\$script:GPU_HOSTS_UNREACHABLE = "\$\(\$c\.label\) is unreachable'
  }
  It "nvcr.io is NON-blocking on the mirror/prebuilt path -- air-gap keeps its GPU (#616 Bugbot HIGH)" {
    # Regression I introduced: treating EVERY soft GPU probe as blocking disabled GPU on
    # air-gapped mirror installs, where nvcr.io is blocked BY DESIGN and images come from the
    # mirror -- and the remedy told them to configure the mirror they had configured.
    $script:FFSRC | Should -Match '\$nvcrBlocking = -not \(\$env:TRACEBLOC_K3S_CUDA_IMAGE -or \$env:TRACEBLOC_IMAGE_REGISTRY\)'
    $script:FFSRC | Should -Match 'url = "https://nvcr\.io/"; gpuSoft = \$true; gpuBlocking = \$nvcrBlocking'
    # the hosts the path DOES need are blocking
    $script:FFSRC | Should -Match 'nvidia\.github\.io/"; gpuSoft = \$true; gpuBlocking = \$true'
    $script:FFSRC | Should -Match 'GPU image registry \(\$gpuHost\)"; url = "https://\$gpuHost/"; gpuSoft = \$true; gpuBlocking = \$true'
    # and only a blocking probe arms the short-circuit
    $script:FFSRC | Should -Match 'if \(\$c\.gpuBlocking\) \{ \$script:GPU_HOSTS_UNREACHABLE'
  }
  It "the skip remedy matches the path -- no 'set a mirror' to someone who set one (#616 Bugbot)" {
    $script:FFSRC | Should -Match "can't be pulled -- check that your configured GPU image registry is reachable"
    $script:FFSRC | Should -Match "can't be built -- on a restricted network set TRACEBLOC_IMAGE_REGISTRY"
  }
  It "the gate short-circuits BEFORE the probe, with an actionable reason" {
    # otherwise a re-run (which our own CPU-fallback advice recommends) burns 3-15 minutes of
    # timeouts on hosts already known to be blocked, and looks hung.
    $script:FFSRC | Should -Match 'if \(\$GPU_HOSTS_UNREACHABLE\) \{[\s\S]{0,2000}?\}\s*\n\s*elseif \(\(Confirm-DockerGpu\)'
    $script:FFSRC | Should -Match 'Skipping GPU setup --'
  }
  It "the global defaults empty so a reachable machine is unaffected" {
    $script:FFSRC | Should -Match '(?m)^\$GPU_HOSTS_UNREACHABLE = ""'
  }
}

Describe "No green line may claim GPU is enabled before verification (#616 Bugbot, x3 instances)" {
  BeforeAll { $script:PSRC_OK = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "only two Ok-level GPU lines exist, and both state a VERIFIED fact" {
    # This defect recurred three times (WSL2/CDI branch, the top-level gate, the device-plugin
    # branch): a green "GPU enabled" printed while cluster-create / CDI wiring / Confirm-GpuNode
    # could still clear K3D_GPU_FLAG, so the operator saw success then a CPU-only summary.
    # Ok is reserved for facts already established; intent uses Info.
    $oks = [regex]::Matches($script:PSRC_OK, 'Ok "GPU[^"]*"') | ForEach-Object { $_.Value }
    $oks.Count | Should -Be 2
    # the image really was built AND passed the k3s sanity check before this line
    ($oks -join ' | ') | Should -Match 'GPU node image built locally'
    # the node really was observed advertising a GPU before this line
    ($oks -join ' | ') | Should -Match 'GPU verified and available'
  }
  It "no Ok line claims 'acceleration enabled' or 'GPU enabled' anywhere" {
    $script:PSRC_OK | Should -Not -Match 'Ok "GPU acceleration enabled'
    $script:PSRC_OK | Should -Not -Match 'Ok "GPU enabled'
  }
  It "the pre-verification lines are Info and say verification is still pending" {
    $script:PSRC_OK | Should -Match 'Info "GPU support prepared'
    $script:PSRC_OK | Should -Match 'Info "GPU wired up \(WSL2/CDI\)'
    $script:PSRC_OK | Should -Match 'Info "NVIDIA device plugin deployed -- verifying'
    $script:PSRC_OK | Should -Match 'Info "NVIDIA device plugin already present -- verifying'
  }
}

Describe "GPU-not-enabled is surfaced prominently with a fix (#616)" {
  BeforeAll { $script:SUMSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the summary gives it its own block, not a cramped Mode line" {
    $script:SUMSRC | Should -Match 'GPU found but not enabled -- training will run on CPU'
    $script:SUMSRC | Should -Match 'Why: \$GPU_SKIP_REASON'
    $script:SUMSRC | Should -Match 're-run this installer to enable GPU'
    $script:SUMSRC | Should -Match 'Full detail: \$script:LOG_FILE'
    # and the Mode line no longer carries the whole reason
    $script:SUMSRC | Should -Not -Match 'CPU \(GPU detected but not enabled: \$GPU_SKIP_REASON\)'
  }
  It "the block is gated on GPU present but not enabled" {
    $script:SUMSRC | Should -Match 'if \(\$GPU_VENDOR -eq "nvidia" -and \$NVIDIA_DRIVER_OK -and \$K3D_GPU_FLAG -eq ""\) \{'
  }
  It "the probe reason quotes the detected driver and a concrete minimum" {
    $script:SUMSRC | Should -Match 'NVIDIA_DRIVER_VERSION'
    $script:SUMSRC | Should -Match 'update the NVIDIA Windows driver to 525 or newer'
  }
}

Describe "WSL2 GPU: node-advertised capacity replaces the NVML device plugin (#616)" {
  BeforeAll { $script:CDISRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  BeforeEach {
    $script:CLUSTER_NAME = "tracebloc"
    $GPU_VENDOR = "nvidia"; $NVIDIA_DRIVER_OK = $true; $K3D_GPU_FLAG = "--gpus=all"
  }
  It "Set-NodeGpuCapacity patches nvidia.com/gpu=1 onto the node status (bounded)" {
    $fn = (($script:CDISRC -split 'function Set-NodeGpuCapacity')[1] -split '\nfunction ')[0]
    $fn | Should -Match '/status/capacity/nvidia\.com~1gpu'
    $fn | Should -Match '--subresource=status'
    $fn | Should -Match '--request-timeout=15s'
    # single GPU per node -- GPU mode already forces one node, so 1 never double-counts
    $fn | Should -Match '"value":"1"'
  }
  It "the JSON patch goes via --patch-file, never an inline -p (PS 5.1 eats the quotes) (#616 regression)" {
    # Windows PowerShell 5.1 does not preserve embedded double quotes when building a native
    # command line, so `-p '[{"op":...}]'` reached kubectl as `[{op:...}]` and the patch ALWAYS
    # failed on a real box. A file sidesteps the shell entirely.
    $fn = (($script:CDISRC -split 'function Set-NodeGpuCapacity')[1] -split '\nfunction ')[0]
    $fn | Should -Match '"--patch-file"'
    $fn | Should -Not -Match '-p \$patch'
    # written without a BOM (a BOM breaks kubectl's JSON parse)
    $fn | Should -Match 'UTF8Encoding\(\$false\)'
    # and retried, since the node object can still be settling right after cluster-create
    $fn | Should -Match 'for \(\$i = 1; \$i -le 6; \$i\+\+\)'
  }
  It "Set-NodeGpuCapacity no-ops when GPU isn't enabled" {
    $K3D_GPU_FLAG = ""
    Mock kubectl { throw "must not patch the node when GPU is not enabled" }
    Set-NodeGpuCapacity | Should -BeFalse
    Should -Not -Invoke kubectl
  }
  It "Install-GpuDevicePlugin takes the CDI path when the node has /dev/dxg (WSL2)" {
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'Invoke-DockerCli -DockerArgs @\("exec", "k3d-\$CLUSTER_NAME-server-0", "test", "-e", "/dev/dxg"\)'
    $fn | Should -Match 'if \(Set-NodeGpuCapacity\) \{[\s\S]{0,700}?Info "GPU wired up \(WSL2/CDI\)[\s\S]{0,120}?return \$true'
  }
  It "the WSL2/CDI path sets the chart's GPU device selector for training pods (#616)" {
    # without GPU_VISIBLE_DEVICES a pod schedules but CUDA fails (client-runtime#291)
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $fn | Should -Match '\$script:GPU_DEVICE_SELECTOR = "nvidia\.com/gpu=all"'
    # values carry it, gated on the same condition as gpuVal (empty when GPU is off)
    $script:CDISRC | Should -Match '\$gpuSelector = if \(\$gpuVal\) \{ \$GPU_DEVICE_SELECTOR \} else \{ "" \}'
    $script:CDISRC | Should -Match 'GPU_VISIBLE_DEVICES: "\$gpuSelector"'
    # and the adopted-reuse reconcile forces it too, so a stale value can't survive
    $script:CDISRC | Should -Match '--set-string "env\.GPU_VISIBLE_DEVICES=\$gpuSelector"'
  }
  It "the 0-GPU reason names the RIGHT cause per path -- no dead-end advice (#616 Bugbot)" {
    # on WSL2/CDI there is no device plugin, so blaming a blocked nvcr.io plugin image would
    # send operators down a dead end.
    $fn = (($script:CDISRC -split 'function Confirm-GpuNode')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'if \(\$GPU_DEVICE_SELECTOR\) \{'
    $wsl = ($fn -split 'if \(\$GPU_DEVICE_SELECTOR\) \{')[1]
    ($wsl -split '\} else \{')[0] | Should -Match 'WSL2/CDI path'
    ($wsl -split '\} else \{')[0] | Should -Not -Match 'k8s-device-plugin'
    # the non-CDI branch keeps the device-plugin guidance
    ($wsl -split '\} else \{')[1] | Should -Match 'k8s-device-plugin'
  }
  It "the WSL2/CDI smoke-test --overrides payload is VALID JSON (#616 Bugbot: claimed stray brace)" {
    # A scanner reported an "extra closing brace before the containers array close". It was a
    # false positive -- the `}}}` closes limits, resources and the container in turn -- but the
    # only durable answer is to PARSE it, so a genuine brace slip can never ship a command that
    # errors on a healthy cluster.
    $cmd = Get-GpuSmokeTestCommand -Selector "nvidia.com/gpu=all"
    if ($cmd -notmatch "--overrides='(.*)'$") { throw "no --overrides payload in: $cmd" }
    $json = $Matches[1] -replace '\\"', '"'          # undo the PowerShell-paste escaping
    $obj = $json | ConvertFrom-Json                    # throws on malformed JSON
    $obj.spec.runtimeClassName | Should -Be "nvidia"
    $obj.spec.containers[0].resources.limits."nvidia.com/gpu" | Should -Be "1"
    $obj.spec.containers[0].env[0].name | Should -Be "NVIDIA_VISIBLE_DEVICES"
    $obj.spec.containers[0].env[0].value | Should -Be "nvidia.com/gpu=all"
    $obj.spec.containers[0].image | Should -Match 'vectoradd'   # CUDA workload, not nvidia-smi
  }
  It "the device-plugin smoke-test --overrides payload is VALID JSON too (#616)" {
    $cmd = Get-GpuSmokeTestCommand -Selector ""
    if ($cmd -notmatch "--overrides='([^']*)'") { throw "no --overrides payload in: $cmd" }
    $obj = ($Matches[1] -replace '\\"', '"') | ConvertFrom-Json
    $obj.spec.runtimeClassName | Should -Be "nvidia"
    $cmd | Should -Match 'nvidia-smi'                  # NVML works on a device-plugin node
  }
  It "the doctor's GPU smoke test matches how the cluster delivers the GPU (#616 Bugbot)" {
    # pods only get the GPU under the nvidia RuntimeClass, and on WSL2 nvidia-smi FAILS in a pod
    # even when CUDA works -- so the suggested command must not make a working cluster look broken.
    $wsl = Get-GpuSmokeTestCommand -Selector "nvidia.com/gpu=all"
    $wsl | Should -Match 'runtimeClassName'
    $wsl | Should -Match 'vectoradd'                  # CUDA workload, not nvidia-smi
    $wsl | Should -Match 'NVIDIA_VISIBLE_DEVICES'
    # every quote in the payload is ESCAPED, else PowerShell strips them and the pasted
    # command dies with "error: Invalid JSON Patch" (seen on a live box).
    $wsl | Should -Match ([regex]::Escape('\"spec\"'))
    # and the device-plugin variant also carries the RuntimeClass + keeps nvidia-smi
    $plugin = Get-GpuSmokeTestCommand -Selector ""
    $plugin | Should -Match 'runtimeClassName'
    $plugin | Should -Match 'nvidia-smi'
    # the diagnostics bundle prints it through the builder (one source of truth)
    $script:CDISRC | Should -Match 'Get-GpuSmokeTestCommand -Selector \$GPU_DEVICE_SELECTOR'
  }
  It "the selector is EMPTY on a normal device-plugin (Linux) node -- the plugin owns that var (#616)" {
    # $GPU_DEVICE_SELECTOR is only ever assigned inside the WSL2/CDI branch; the global default
    # is empty, so a Linux/device-plugin install writes GPU_VISIBLE_DEVICES: "".
    $script:CDISRC | Should -Match '(?m)^\$GPU_DEVICE_SELECTOR = ""'
    ([regex]::Matches($script:CDISRC, '\$script:GPU_DEVICE_SELECTOR = "')).Count | Should -Be 1
  }
  It "the installer verifies libdxcore is IN the spec, not just that a spec exists (#616 regression)" {
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $fn | Should -Match '"grep", "-q", "libdxcore"'
    $fn | Should -Match 'missing libdxcore'
  }
  It "K3D_GPU_FLAG is set in exactly ONE place -- the authoritative gate (#616 Bugbot)" {
    # Install-NvidiaContainerToolkit used to set it (and clear GPU_SKIP_REASON) after the
    # in-WSL toolkit check, before the Docker GPU probe that actually decides. That made a
    # later CPU fallback look enabled and dropped the real skip reason.
    ([regex]::Matches($script:CDISRC, '\$(script:)?K3D_GPU_FLAG = "--gpus=all"')).Count | Should -Be 1
    $tk = (($script:CDISRC -split 'function Install-NvidiaContainerToolkit')[1] -split '\nfunction ')[0]
    $tk | Should -Not -Match 'K3D_GPU_FLAG = "--gpus=all"'
    $tk | Should -Not -Match 'GPU_SKIP_REASON = ""'
    # it reports only what it established, and says GPU is still gated
    $tk | Should -Match 'NVIDIA Container Toolkit present in'
    $tk | Should -Match 'still gated on the Docker GPU probe'
  }
  It "no green GPU-success line before Confirm-GpuNode verifies the node (#616 Bugbot)" {
    # claiming success at the capacity patch produced a green "enabled" immediately followed
    # by a CPU fallback when verification cleared the flag.
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $cdiBranch = ($fn -split 'if \(\$dxg\.Code -eq 0\) \{')[1]
    ($cdiBranch -split '\n  \}')[0] | Should -Not -Match 'Ok "GPU acceleration enabled \(WSL2/CDI\)'
    ($cdiBranch -split '\n  \}')[0] | Should -Match 'Info "GPU wired up \(WSL2/CDI\)'
  }
  It "the soft GPU preflight warning names the path actually in use (#616 Bugbot)" {
    # "can't be built" was wrong on the pull/mirror path, where nothing is built locally.
    $script:CDISRC | Should -Match "can't be pulled here"
    $script:CDISRC | Should -Match "can't be built here"
  }
  It "the CDI spec is VERIFIED before claiming GPU is ready (#616 Bugbot)" {
    # the boot script guards every step with `|| true`; without this check a failed
    # `cdi generate` would leave us advertising a GPU pods can't actually use.
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $fn | Should -Match '"test", "-s", "/etc/cdi/nvidia\.yaml"'
    # and the spec check must come BEFORE the success path
    $fn | Should -Match '/etc/cdi/nvidia\.yaml"\)[\s\S]{0,1800}?Set-NodeGpuCapacity'
    $fn | Should -Match '\$script:GPU_SKIP_REASON = "the node couldn''t generate its WSL GPU \(CDI\) spec'
  }
  It "a leftover NVML device plugin is REMOVED before advertising capacity (#616 Bugbot HIGH)" {
    # A device plugin owns the nvidia.com/gpu extended resource and re-reports 0 on WSL2 every
    # sync, so one left behind by an older install would permanently defeat the capacity patch.
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'delete", "daemonset", "-n", "kube-system", "nvidia-device-plugin-daemonset"'
    $fn | Should -Match '--ignore-not-found'          # idempotent: clean no-op when absent
    # and it must happen BEFORE we patch capacity
    $fn | Should -Match 'nvidia-device-plugin-daemonset"[\s\S]{0,900}?Set-NodeGpuCapacity'
  }
  It "a failed capacity patch names the CDI cause, not a device-plugin failure (#616 Bugbot)" {
    # this path never uses the plugin, so the caller's generic fallback reason would mislead
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $tail = ($fn -split 'if \(Set-NodeGpuCapacity\) \{')[1]
    $tail | Should -Match '\$script:GPU_SKIP_REASON = "the installer couldn''t advertise nvidia\.com/gpu'
    $tail | Should -Match 'WSL2/CDI path'
  }
  It "GPU mode collapses SERVERS to 1 as well as AGENTS to 0 (#616 Bugbot: one card, one advertiser)" {
    # every server node runs the boot reconciler and advertises nvidia.com/gpu=1 for the SAME
    # physical card, so SERVERS>1 would offer N GPUs for one device.
    $gate = ($script:CDISRC -split '\$K3D_GPU_FLAG = "--gpus=all"')[1]
    $gate | Should -Match '\$AGENTS = "0"'
    $gate | Should -Match '\$SERVERS = "1"'
    $gate | Should -Match 'if \(\$env:SERVERS\)'      # an explicit user value is overridden LOUDLY
  }
  It "a failed capacity advertisement returns false so the caller falls back to CPU" {
    $fn = (($script:CDISRC -split 'function Install-GpuDevicePlugin')[1] -split '\nfunction ')[0]
    $dxgBranch = ($fn -split 'if \(\$dxg\.Code -eq 0\) \{')[1]
    ($dxgBranch -split '\n  \}')[0] | Should -Match 'return \$false'
  }
}

Describe "GPU + K8S_VERSION=latest is refused (#616 Bugbot: latest bypasses the CUDA image)" {
  BeforeAll { $script:LSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the GPU gate has a latest/empty branch that never enables GPU and gives a reason" {
    # latest adds no --image, so k3d makes a stock node; enabling GPU there strands jobs.
    $script:LSRC | Should -Match 'if \(\$GPU_VENDOR -eq "nvidia" -and \$NVIDIA_DRIVER_OK -and \(\$K8S_VERSION -eq "latest" -or \$K8S_VERSION -eq ""\)\)'
    $gate = ($script:LSRC -split 'if \(\$GPU_VENDOR -eq "nvidia" -and \$NVIDIA_DRIVER_OK -and \(\$K8S_VERSION')[1]
    # this branch must NOT set the --gpus flag; it only records a skip reason (CPU fallback)
    ($gate -split '\} elseif')[0] | Should -Not -Match '\$K3D_GPU_FLAG = "--gpus=all"'
    ($gate -split '\} elseif')[0] | Should -Match '\$GPU_SKIP_REASON ='
  }
  It "the latest branch CLEARS any flag Install-NvidiaContainerToolkit already set (#616 Bugbot)" {
    # Install-NvidiaContainerToolkit runs first and may set K3D_GPU_FLAG=--gpus=all; the latest
    # branch must clear it or a stock 'latest' cluster gets --gpus=all without the CUDA image.
    $gate = ($script:LSRC -split 'if \(\$GPU_VENDOR -eq "nvidia" -and \$NVIDIA_DRIVER_OK -and \(\$K8S_VERSION')[1]
    ($gate -split '\} elseif')[0] | Should -Match '\$K3D_GPU_FLAG = ""'
  }
}

Describe "Device-plugin setup failure falls back to CPU (#616 Bugbot: don't leave GPU requests)" {
  BeforeAll { $script:MSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "a failed Install-GpuDevicePlugin (flag still set) clears K3D_GPU_FLAG before values are written" {
    # if (Install-GpuDevicePlugin) { Confirm-GpuNode } elseif ($K3D_GPU_FLAG -ne "") { clear + reason }
    $script:MSRC | Should -Match 'if \(Install-GpuDevicePlugin\) \{[\s\S]{0,80}?Confirm-GpuNode[\s\S]{0,80}?\} elseif \(\$K3D_GPU_FLAG -ne ""\) \{'
    $branch = ($script:MSRC -split '\} elseif \(\$K3D_GPU_FLAG -ne ""\) \{')[1]
    ($branch -split '\n\}')[0] | Should -Match '\$K3D_GPU_FLAG = ""'
    ($branch -split '\n\}')[0] | Should -Match 'GPU_SKIP_REASON'
  }
}

Describe "GPU download hosts are in the connectivity preflight (#616 Bugbot: nvcr.io coverage)" {
  BeforeAll { $script:PSRC4 = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "GPU is detected BEFORE preflight (and before the fast path) so both can use it" {
    # Find-Gpu now runs before the fast path (so it can decide GPU retry) -- still before Test-Preflight.
    $script:PSRC4 | Should -Match '(?m)^Find-Gpu\s*$[\s\S]*?^Test-Preflight\s*$'
    # ordering: the single Find-Gpu call precedes the fast-path health check
    $script:PSRC4 | Should -Match '(?m)^Find-Gpu\s*$[\s\S]{0,400}?InstallState\.completed'
  }
  It "nvcr.io (device plugin) is probed on BOTH paths whenever GPU is enabled (#616 Bugbot)" {
    # nvcr.io/nvidia/k8s-device-plugin is baked in + pulled at runtime regardless of build/pull.
    $script:PSRC4 | Should -Match 'url = "https://nvcr\.io/"; gpuSoft = \$true'
  }
  It "the BUILD path also probes the toolkit apt repo (nvidia.github.io)" {
    $script:PSRC4 | Should -Match 'if \(-not \(\$env:TRACEBLOC_K3S_CUDA_IMAGE -or \$env:TRACEBLOC_IMAGE_REGISTRY\)\)'
    $script:PSRC4 | Should -Match 'url = "https://nvidia\.github\.io/"; gpuSoft = \$true'
  }
  It "the PULL path probes EVERY distinct host across the node + probe images (#616 Bugbot)" {
    # node image and probe image can be on different hosts when both overrides are set.
    $script:PSRC4 | Should -Match '\$gpuHosts = @\(\(Get-RegistryHost \$K3S_CUDA_IMAGE\), \(Get-RegistryHost \$CUDA_PROBE_IMAGE\)\) \| Select-Object -Unique'
    $script:PSRC4 | Should -Match 'label = "GPU image registry \(\$gpuHost\)"; url = "https://\$gpuHost/"; gpuSoft = \$true'
    # bare docker.io + already-added nvcr.io are skipped
    $script:PSRC4 | Should -Match "\`$gpuHost -match '\[.:\]' -and \`$gpuHost -ne 'docker.io' -and \`$gpuHost -ne 'nvcr.io'"
  }
  It "a blocked GPU host WARNS (CPU fallback), it does not hard-fail a CPU-capable install" {
    # gpuSoft branch must not increment the fail counters
    $script:PSRC4 | Should -Match 'elseif \(\$c\.gpuSoft\) \{'
    $block = ($script:PSRC4 -split 'elseif \(\$c\.gpuSoft\) \{')[1]
    ($block -split '\}')[0] | Should -Not -Match '\$hardFail\+\+'
  }
  It "the GPU passthrough probe uses the mirror-homed CUDA image (#616 Bugbot: mirror path)" {
    # $CUDA_PROBE_IMAGE re-homes nvidia/cuda onto the mirror when TRACEBLOC_IMAGE_REGISTRY is set,
    # so a mirrored/air-gapped GPU install doesn't fall back to CPU on a blocked Docker Hub.
    $script:PSRC4 | Should -Match '\$CUDA_PROBE_IMAGE = if \(\$env:TRACEBLOC_IMAGE_REGISTRY\)'
    $script:PSRC4 | Should -Match '"\$mp/nvidia/cuda:\$CUDA_BASE_TAG"'
    $script:PSRC4 | Should -Match '\$probeImg = \$CUDA_PROBE_IMAGE'
  }
}

Describe "Test-HealthyClusterGpuConsistent (#616 Bugbot: healthy reinstall flags a stale GPU request)" {
  BeforeAll { $script:HCSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "reads the GPU request from the LIVE Helm release, not the (stale-on-adopt) local values.yaml (#616 Bugbot)" {
    # the helm query now lives in the shared Test-LiveReleaseRequestsGpu helper
    $lr = (($script:HCSRC -split 'function Test-LiveReleaseRequestsGpu')[1] -split '\nfunction ')[0]
    $lr | Should -Match 'helm list -A -o json'
    $lr | Should -Match 'helm get values \$r\.name -n \$r\.namespace'
    $lr | Should -Match '\$v\.env\.GPU_REQUESTS'
    $lr | Should -Match 'Wait-JobWithProgress -Job \$vjob -TimeoutSec 20'
    # the consistency check must NOT read the local values.yaml file anymore
    $fn = (($script:HCSRC -split 'function Test-HealthyClusterGpuConsistent')[1] -split '\nfunction ')[0]
    $fn | Should -Not -Match 'Join-Path \$HOST_DATA_DIR "values\.yaml"'
    $fn | Should -Not -Match 'Get-Content .*values\.yaml'
  }
  It "returns early when no live release requests GPU (via the shared helper)" {
    $fn = (($script:HCSRC -split 'function Test-HealthyClusterGpuConsistent')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'if \(-not \(Test-LiveReleaseRequestsGpu\)\) \{ return \}'
  }
  It "warns with the recreate remedy when the live release wants GPU but the node is CPU-only" {
    $fn = (($script:HCSRC -split 'function Test-HealthyClusterGpuConsistent')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'Test-NodeImageGpuCapable -Image \$img -Configured \$K3S_CUDA_IMAGE'
    # The remedy now comes from the one helper that prints it (backend#2077) — the
    # `k3d cluster delete` line moved there, together with the `tracebloc delete`
    # that has to precede it. Its wording is asserted in the helper's own Describe.
    $fn | Should -Match 'Write-RecreateClusterHint'
  }
  It "the fast path calls it so a healthy-but-inconsistent cluster is flagged (source guard)" {
    $script:HCSRC | Should -Match 'client is healthy -- nothing to do[\s\S]{0,800}?Test-HealthyClusterGpuConsistent'
  }
}

Describe "Fast path retries GPU on a CPU-only cluster (#616 Bugbot: re-run can enable GPU)" {
  BeforeAll { $script:FPSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the fast path shortcuts ONLY when GPU is fully consistent -- else it falls through to reconcile" {
    # GPU 'fully enabled' = node advertises a GPU AND the live release requests one; any other combo
    # on a GPU machine (node not advertising, OR release still CPU after a delayed recovery) must
    # NOT shortcut (Bugbot -- both directions).
    $script:FPSRC | Should -Match '\$gpuFullyEnabled = \(\(Test-RunningClusterGpuCapable\) -and \(Test-LiveReleaseRequestsGpu\)\)'
    $script:FPSRC | Should -Match 'if \(\$gpuPresent -and -not \$gpuFullyEnabled\) \{'
    # within the fast-path block, the 'nothing to do' exit lives in the else branch (no reconcile).
    $fastpath = (($script:FPSRC -split 'Fast path \(#420\)')[1] -split 'Trust an explicit corporate CA')[0]
    $fastpath | Should -Match '\} else \{[\s\S]*?nothing to do[\s\S]*?exit 0'
  }
  It "Test-RunningClusterGpuCapable checks LIVE allocatable GPU (not the image name) and is bounded (#616 Bugbot)" {
    # a CUDA image with 0 allocatable GPUs (device-plugin failure) must read as NOT live, so the
    # fast path retries -- the image name alone is not proof of a working GPU.
    $fn = (($script:FPSRC -split 'function Test-RunningClusterGpuCapable')[1] -split '\nfunction ')[0]
    $fn | Should -Match "allocatable\.nvidia\\\.com/gpu"
    $fn | Should -Match '--request-timeout=5s'
    $fn | Should -Match "-match '\[1-9\]"
    $fn | Should -Not -Match 'Config\.Image'   # no longer keyed on the image name
  }
  It "Find-Gpu's nvidia-smi probes are bounded so a wedged driver can't hang a re-run (#616 Bugbot)" {
    $drv = (($script:FPSRC -split 'function Confirm-NvidiaDriver')[1] -split '\nfunction ')[0]
    $drv | Should -Match 'Invoke-BoundedProcess -FileName \$nvSmi'
    $drv | Should -Not -Match '& \$nvSmi'   # no unbounded native invocation
  }
  It "the image sanity check runs WITH --gpus so it catches a stale image on an older driver (#616 Bugbot)" {
    # Test-GpuImageRunsK3s must exercise the same requirement gate cluster-create hits (no -e bypass).
    $fn = (($script:FPSRC -split 'function Test-GpuImageRunsK3s')[1] -split '\nfunction ')[0]
    $fn | Should -Match '"run", "--rm", "--gpus", "all", \$K3S_CUDA_IMAGE, "--version"'
    # the actual docker call must NOT bypass the requirement gate (comment may mention it)
    $fn | Should -Not -Match 'Invoke-DockerCli[^\n]*NVIDIA_DISABLE_REQUIRE'
  }
}

Describe "hostPath PV dirs are made writable before Helm (#616 follow-up: first-ingest Permission denied)" {
  BeforeAll { $script:HPSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  # The bug: the chart's hostPath PVs bind /tracebloc/<release>/{data,logs}. kubelet's
  # DirectoryOrCreate makes a missing path root:root 0755 and ignores fsGroup on hostPath
  # (kubernetes#138411), so uid 1000 can't write and the FIRST `data ingest` dies with
  # "mkdir: can't create directory '/data/shared/.tracebloc-staging/': Permission denied".
  # The bash installer has always pre-created these (lib/cluster.sh _ensure_release_dirs);
  # this script didn't, which is exactly why the failure was Windows-only.

  It "prepares both PV dirs for the release the PV paths are keyed on" {
    $cmd = Get-ReleaseDirsPrepCommand -Release "windows-demo"
    $cmd | Should -Match '/tracebloc/windows-demo/data'
    $cmd | Should -Match '/tracebloc/windows-demo/logs'
  }

  It "pre-creates the dirs -- the mkdir is the part that beats kubelet to them" {
    # Without mkdir -p, kubelet wins the race and creates them root:root 0755; a chmod
    # afterwards would be repairing damage instead of preventing it.
    Get-ReleaseDirsPrepCommand -Release "r" | Should -Match 'mkdir -p'
  }

  It "matches the chart's init-writable-data semantics, INCLUDING its per-dir sticky split" {
    # Same end state as a current chart's init container, so a cluster on an older published
    # chart is not a second, differently-broken configuration. The modes deliberately differ
    # per dir (#667): /data/shared must NOT be sticky or `data delete` -- which runs as a
    # different uid than the ingest -- cannot remove the tree, and on the currently-published
    # chart (no init-writable-data) or the fast path that returns before Helm, nothing runs
    # afterwards to correct a sticky bit the installer set.
    $cmd = Get-ReleaseDirsPrepCommand -Release "r"
    $cmd | Should -Match 'chown 1000:1000'
    $cmd | Should -Match '/tracebloc/r/data:2777'
    $cmd | Should -Match '/tracebloc/r/logs:3777'
    $cmd | Should -Not -Match '/data:3777'      # never sticky on the shared/data dir
    $cmd | Should -Match 'chmod "\$want"'       # per-dir mode, not one mode for both
  }

  It "the desired mode does not collide with the observed mode in the shell" {
    # Both were briefly called $m, so the ls-derived value overwrote the wanted one. Harmless
    # only because chmod ran first -- exactly the kind of ordering dependency that breaks on
    # the next edit.
    $cmd = Get-ReleaseDirsPrepCommand -Release "r"
    $cmd | Should -Match 'want=\$\{e#\*:\}'
    $cmd | Should -Match 'm=\$1'
  }

  It "leaves the mysql PV alone" {
    # mysql gets its own init container in the chart and its datadir permissions are the
    # database's business; installs that reach a healthy cluster prove it's already fine.
    Get-ReleaseDirsPrepCommand -Release "r" | Should -Not -Match '/mysql'
  }

  It "reads the mode with POSIX ls -ldn, never GNU-only stat -c" {
    # Regression guard on a bug this actually had: `stat -c` is a GNU/coreutils flag that
    # BSD stat REJECTS, and it fails SILENTLY -- empty mode string, so a correctly-chmodded
    # dir gets reported FAIL and the installer emits a scary warning on a healthy install.
    # Same class as the sha256sum --check trap (#429). ls -ldn behaves identically on
    # busybox, coreutils and BSD.
    $cmd = Get-ReleaseDirsPrepCommand -Release "r"
    $cmd | Should -Match 'ls -ldn'
    $cmd | Should -Not -Match 'stat -c'
  }

  It "keeps the shell's own \$d/\$1/\$3 out of PowerShell's hands" {
    # If the here-string interpolated these, the node would run `mkdir -p ""` and silently
    # prepare nothing -- the exact silent-no-op this whole fix exists to remove.
    $cmd = Get-ReleaseDirsPrepCommand -Release "r"
    $cmd | Should -Match '\$d'
    $cmd | Should -Match 'm=\$1'
    $cmd | Should -Match 'o=\$3'
  }

  It "reports FAIL for a root-owned 0755 dir and OK for a 3777 one (the decision logic)" {
    # Exercises the glob that decides writability, without needing a node: character 9 of
    # the mode is the other-write bit.
    $cmd = Get-ReleaseDirsPrepCommand -Release "r"
    $cmd | Should -Match '\?{8}w\*\)'      # ????????w*) -> other-writable
    # Ownership must NOT be a pass condition: the writers are 65534 / 65532, and an
    # owner-is-1000 shortcut reported OK on a 0755 dir whose chmod had failed (Bugbot).
    $cmd | Should -Not -Match '= 1000 \]' 
  }

  Context "Initialize-ReleaseDataDirs" {
    It "warns with a runnable command when the dirs still aren't writable" {
      Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "FAIL /tracebloc/rel/data 0 drwxr-xr-x" } }
      Mock Warn {}; Mock Hint {}; Mock Log {}
      { Initialize-ReleaseDataDirs -Release "rel" } | Should -Not -Throw
      Should -Invoke Warn -Times 1
      # The hint must be copy-pasteable, not advice to go read something.
      Should -Invoke Hint -ParameterFilter { $m -match 'docker exec' } -Times 1
    }

    It "a docker exec timeout degrades to a warning, never a failed install" {
      # 124 is Invoke-BoundedProcess's timeout code. A cluster that isn't k3d-shaped lands
      # here too. Neither is a reason to abort an install that is otherwise fine -- and on a
      # current chart init-writable-data fixes the same dirs at pod start.
      Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = "docker exec timed out after 60s" } }
      Mock Warn {}; Mock Hint {}; Mock Log {}
      { Initialize-ReleaseDataDirs -Release "rel" } | Should -Not -Throw
      Should -Invoke Warn -Times 1
    }

    It "stays quiet when every dir came back OK" {
      Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "OK /tracebloc/rel/data 1000 drwxrwsrwt`nOK /tracebloc/rel/logs 1000 drwxrwsrwt" } }
      Mock Warn {}; Mock Hint {}; Mock Log {}
      Initialize-ReleaseDataDirs -Release "rel"
      Should -Invoke Warn -Times 0
    }
  }

  It "runs BEFORE helm, for whichever release helm is about to touch" {
    # Order matters: after Helm, the pod may already have failed to mount. And the release
    # name must follow the adopt/fresh branch, since the PV path embeds it -- preparing
    # dirs for the wrong release would look successful and fix nothing.
    # The release name follows the adopt/fresh branch.
    $script:HPSRC | Should -Match '\$pvRelease = \$TB_NAMESPACE'
    $script:HPSRC | Should -Match 'if \(\$adoptedReuse -and \$existingName\) \{ \$pvRelease = \$existingName \}'
    # ...and the prep runs before the helm adopted/fresh split.
    $idxPrep = $script:HPSRC.IndexOf('Initialize-ReleaseDataDirs -Release $pvRelease')
    $idxHelm = $script:HPSRC.IndexOf('if ($adoptedReuse) {', $idxPrep)
    $idxPrep | Should -BeGreaterThan 0
    $idxHelm | Should -BeGreaterThan $idxPrep
    # Guard the anchor collision that broke an existing test once: the inline form
    # must not reappear before the helm block.
    $script:HPSRC.IndexOf('-Release $(if ($adoptedReuse)') | Should -Be -1
  }
}

Describe "hostPath prep also runs on the nothing-to-do fast path (#653)" {
  BeforeAll { $script:FPHSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "repairs an already-installed cluster instead of shortcutting past the fix" {
    # The fast path exits before Helm. A cluster installed before this fix is HEALTHY, so
    # every re-run takes that shortcut -- without this, "re-run the installer" would be
    # advice that quietly does nothing while the first ingest keeps failing.
    $fast = ($script:FPHSRC -split 'already installed and the client is healthy')[1]
    $fast = ($fast -split 'exit 0')[0]
    $fast | Should -Match 'Initialize-ReleaseDataDirs -Release \$fpRelease'
    # Keyed on the release NAME, since that is what the PV paths embed -- not the namespace.
    $fast | Should -Match '\(Get-InstalledClientInfo\)\.Name'
  }
  It "skips silently when no release name could be resolved" {
    # Never prepare /tracebloc//data: an unresolvable release must be a no-op, not a
    # directory named after nothing.
    $fast = (($script:FPHSRC -split 'already installed and the client is healthy')[1] -split 'exit 0')[0]
    $fast | Should -Match 'if \(\$fpRelease\) \{ Initialize-ReleaseDataDirs'
  }
}

Describe "hostPath prep survives Windows argv and follows the dataset mount (#654 Bugbot)" {

  It "sends the script on STDIN, with every argv token space-free" {
    # Invoke-BoundedProcess joins args into ONE command line and quotes any arg containing
    # whitespace WITHOUT escaping inner quotes -- its documented contract is "callers pass
    # space-free tokens". Passed as `sh -c <script>`, Windows' parser would end the quoted
    # arg at the script's first inner " and hand sh a TRUNCATED program: prep silently does
    # nothing and the Permission denied survives, with the install still reporting success.
    # Same failure family as the kubectl patch that had to move to --patch-file.
    $script:capArgs = $null; $script:capStdin = $null
    Mock Invoke-DockerCli {
      $script:capArgs = $DockerArgs; $script:capStdin = $Stdin
      [pscustomobject]@{ Code = 0; Output = "OK /tracebloc/rel/data 1000 drwxrwsrwt" }
    }
    Mock Log {}; Mock Warn {}; Mock Hint {}
    Initialize-ReleaseDataDirs -Release "rel"

    @($script:capArgs | Where-Object { $_ -match '\s' }).Count | Should -Be 0
    $script:capArgs | Should -Contain "-i"      # stdin must be attached
    $script:capArgs | Should -Contain "sh"
    $script:capArgs | Should -Not -Contain "-c" # not an argv-borne script
    $script:capStdin | Should -Match 'mkdir -p'
    $script:capStdin | Should -Match "`n$"      # trailing newline so the last line runs
  }

  It "prepares data on the dataset mount when HOST_DATASET_DIR is set" {
    # tracebloc.clientDataHostPath resolves data to <hostPath.datasetPath>/<release>/data, and
    # the installer writes datasetPath: /tracebloc-data whenever HOST_DATASET_DIR is set. Prep
    # under /tracebloc there would touch a path nothing mounts while kubelet still created the
    # real one root:root 0755 -- fixed-looking, still broken.
    $cmd = Get-ReleaseDirsPrepCommand -Release "rel" -DataBase "/tracebloc-data"
    $cmd | Should -Match '/tracebloc-data/rel/data'
    $cmd | Should -Not -Match '/tracebloc/rel/data'
  }

  It "keeps logs on the local tree even when data moves to the dataset mount" {
    # logs-pvc.yaml hardcodes /tracebloc/<release>/logs — only data follows datasetPath.
    $cmd = Get-ReleaseDirsPrepCommand -Release "rel" -DataBase "/tracebloc-data"
    $cmd | Should -Match '/tracebloc/rel/logs'
  }

  It "defaults to the local tree when no dataset mount is configured" {
    $cmd = Get-ReleaseDirsPrepCommand -Release "rel"
    $cmd | Should -Match '/tracebloc/rel/data'
    $cmd | Should -Match '/tracebloc/rel/logs'
  }

  It "the repair hint names the same paths AND the same modes that were prepared" {
    # This test used to assert paths only, which is exactly how a hint saying
    # `chmod -R 3777` on BOTH dirs survived the switch to per-dir modes: following the
    # installer's own copy-paste would put the sticky bit back on /data/shared and break
    # `data delete`, while ingest looked fixed (Bugbot). Assert the modes too, per dir.
    $hint = Get-ReleaseDirsRepairHint -Release "rel" -Node "k3d-x-server-0" -DataBase "/tracebloc-data"
    $hint | Should -Match 'chmod 2777 /tracebloc-data/rel/data'
    $hint | Should -Match 'chmod 3777 /tracebloc/rel/logs'
    $hint | Should -Not -Match '3777 [^ ]*/data'   # never sticky on the shared/data dir
    $hint | Should -Not -Match '-R'                # dir mode governs unlink; no setgid on files
  }

  It "the hint and the prep are generated from ONE spec, so they cannot drift" {
    # The drift is invisible until someone runs the hint, so remove the possibility rather
    # than test for its absence in two places.
    $spec = Get-ReleaseDirsSpec -Release "rel" -DataBase "/tracebloc-data"
    $cmd  = Get-ReleaseDirsPrepCommand -Release "rel" -DataBase "/tracebloc-data"
    $hint = Get-ReleaseDirsRepairHint -Release "rel" -Node "n" -DataBase "/tracebloc-data"
    foreach ($e in $spec) {
      $cmd  | Should -Match ([regex]::Escape("$($e.Path):$($e.Mode)"))
      $hint | Should -Match ([regex]::Escape("chmod $($e.Mode) $($e.Path)"))
    }
    $spec.Count | Should -Be 2
  }
}

Describe "hostPath prep: no false OK, and the data base comes from the live cluster (#654 Bugbot r2)" {

  It "a chowned-but-not-chmodded dir reports FAIL, not OK" {
    # chown succeeding while chmod fails leaves 0755 owned by 1000. None of the writers is
    # 1000 (ingestion Job 65534/HOST_UID, CLI staging pod 65532) and they share no group, so
    # that dir is unusable -- and an owner-based pass would have called it OK, skipped the
    # warning, and left the first ingest to die on Permission denied.
    $cmd = Get-ReleaseDirsPrepCommand -Release "rel"
    $cmd | Should -Not -Match '= 1000 \]'
    $cmd | Should -Match 'w=0'
  }

  It "asks the node's mount table for the data base, not the env var" {
    # HOST_DATASET_DIR is not persisted in install state, so a re-run without it would prepare
    # /tracebloc/<rel>/data while the live release still mounts /tracebloc-data/<rel>/data.
    # k3d bakes bind mounts at cluster-create and can't change them on a running cluster, so
    # the node is ground truth.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "/tracebloc`n/tracebloc-data`n/var/lib/rancher" } }
    Mock Log {}
    Get-NodeDataBase -Node "k3d-x-server-0" | Should -Be "/tracebloc-data"
  }

  It "uses the local tree when the node has no dataset mount" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "/tracebloc`n/var/lib/rancher" } }
    Mock Log {}
    Get-NodeDataBase -Node "k3d-x-server-0" | Should -Be "/tracebloc"
  }

  It "does not read an unreachable docker as 'no dataset mount'" {
    # Exit 124 is the bounded-process timeout. Failing to ASK tells us nothing about the
    # layout, so it must fall back to the env var rather than silently assuming the local tree
    # and preparing the wrong path.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 124; Output = "timed out" } }
    Mock Log {}
    Get-NodeDataBase -Node "k3d-x-server-0" -DatasetDirHint "D:\datasets" | Should -Be "/tracebloc-data"
    Get-NodeDataBase -Node "k3d-x-server-0" -DatasetDirHint "" | Should -Be "/tracebloc"
  }

  It "a mount named like the dataset path but different does not match" {
    # Anchored match: /tracebloc-data-old must not be read as the dataset mount.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "/tracebloc`n/tracebloc-data-old" } }
    Mock Log {}
    Get-NodeDataBase -Node "k3d-x-server-0" | Should -Be "/tracebloc"
  }
}

Describe "hostPath prep call site asks the node, not the env var (#654 Bugbot r2)" {
  BeforeAll { $script:CSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "Initialize-ReleaseDataDirs resolves the data base via Get-NodeDataBase" {
    # A correct Get-NodeDataBase is worthless if the caller still decides from
    # $HOST_DATASET_DIR: that var is not persisted in install state, so a re-run without it
    # prepares /tracebloc/<rel>/data while the live release mounts /tracebloc-data/<rel>/data.
    # Guarding the FUNCTION alone left this reachable, so guard the call site too.
    $fn = (($script:CSRC -split 'function Initialize-ReleaseDataDirs')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'Get-NodeDataBase -Node \$node'
    $fn | Should -Not -Match 'if \(\$HOST_DATASET_DIR\) \{ "/tracebloc-data" \}'
  }
}

Describe "hostPath prep needs positive proof, not just absence of failure (#654 Bugbot r3)" {
  BeforeEach { Mock Log {}; Mock Warn {}; Mock Hint {} }

  It "empty output with exit 0 warns instead of reporting success" {
    # If the program never reaches `sh` -- stdin not attached, empty here-doc, an exec that
    # starts and ends -- sh exits 0 having printed nothing. Reading that as success skips the
    # warning and leaves the first ingest on Permission denied while the install looks fine.
    # Same fail-open shape as the argv-quoting bug this PR already fixed.
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "" } }
    Initialize-ReleaseDataDirs -Release "rel"
    Should -Invoke Warn -Times 1
  }

  It "a partial result (one dir confirmed, one missing) still warns" {
    Mock Invoke-DockerCli { [pscustomobject]@{ Code = 0; Output = "OK /tracebloc/rel/data 65534 drwxrwsrwx" } }
    Initialize-ReleaseDataDirs -Release "rel"
    Should -Invoke Warn -Times 1
  }

  It "output about some OTHER release does not count as proof for this one" {
    # A stale or misrouted exec must not satisfy the check.
    Mock Invoke-DockerCli {
      [pscustomobject]@{ Code = 0; Output = "OK /tracebloc/other/data 65534 drwxrwsrwx`nOK /tracebloc/other/logs 65534 drwxrwsrwt" }
    }
    Initialize-ReleaseDataDirs -Release "rel"
    Should -Invoke Warn -Times 1
  }

  It "stays quiet only when EVERY expected dir reports OK" {
    Mock Invoke-DockerCli {
      [pscustomobject]@{ Code = 0; Output = "OK /tracebloc/rel/data 65534 drwxrwsrwx`nOK /tracebloc/rel/logs 65534 drwxrwsrwt" }
    }
    Initialize-ReleaseDataDirs -Release "rel"
    Should -Invoke Warn -Times 0
  }

  It "the dir list is shared, so what we prepare and what we verify cannot drift" {
    $list = Get-ReleaseDirsList -Release "rel" -DataBase "/tracebloc-data"
    $cmd  = Get-ReleaseDirsPrepCommand -Release "rel" -DataBase "/tracebloc-data"
    foreach ($d in $list) { $cmd | Should -Match ([regex]::Escape($d)) }
    $list.Count | Should -Be 2
  }
}

Describe "Wait-MetricsApiService (client#553 -- the Windows installer had no wait)" {
  # k3s applies its bundled metrics-server AFTER the API server is ready, and
  # `k3d cluster create --wait` does not gate on it. The resource-monitor template
  # `fail`s at RENDER time when v1beta1.metrics.k8s.io is missing, which aborts the
  # whole release -- so helm must not render inside that window. bash has waited
  # since #553; this file's installer went straight from create to helm install,
  # on the slowest host we support.
  BeforeEach { Mock Log {} }
  AfterEach  { $env:TB_METRICS_WAIT_S = $null }

  Context "Get-MetricsWaitSeconds -- the whole input domain, not a sample" {
    # Rule 6: derive the domain from what an env var can actually hold. The
    # interesting values are the ones a human types by mistake, and every one of
    # them must land on the default rather than on 0 (which would silently
    # disable the wait) or on an exception.
    #
    # Rule 1: the expected default is PARSED from scripts/spec/facts.env, never
    # restated here. Both installers advertise the same TB_METRICS_WAIT_S knob, so
    # the budget is one cross-OS fact; a test carrying its own copy of 120 would
    # agree with itself while the two installers waited different lengths.
    BeforeAll {
      $spec = Get-Content "$PSScriptRoot/../spec/facts.env" -Raw
      # \r?$ for the same CRLF reason as below -- facts.env is checked out CRLF on Windows.
      $m = [regex]::Match($spec, '(?m)^METRICS_WAIT_TIMEOUT=(?<v>\d+)\r?$')
      $m.Success | Should -BeTrue -Because "facts.env must declare the shared wait budget"
      $script:SpecWait = [int]$m.Groups['v'].Value
    }
    It "the stamped PowerShell default IS the facts.env fact" {
      $script:MetricsWaitTimeout | Should -Be $script:SpecWait
    }
    It "an unset/empty knob is the declared default" {
      Get-MetricsWaitSeconds -Value ""    | Should -Be $script:SpecWait
      Get-MetricsWaitSeconds -Value $null | Should -Be $script:SpecWait
    }
    It "a plain integer is honoured, including 0 (= disable) and a leading-zero form" {
      Get-MetricsWaitSeconds -Value "45"  | Should -Be 45
      Get-MetricsWaitSeconds -Value "0"   | Should -Be 0
      Get-MetricsWaitSeconds -Value "007" | Should -Be 7
    }
    It "garbage falls back to the default instead of becoming 0" {
      foreach ($v in "abc", "-5", "12.5", "12s", " 30", "30 ", "1e3", "0x10") {
        Get-MetricsWaitSeconds -Value $v |
          Should -Be $script:SpecWait -Because "'$v' is not a wait budget, and reading it as 0 would silently switch the wait off"
      }
    }
    It "an absurdly long digit string falls back instead of throwing on the [int] cast" {
      # `[int]"99999999999999999999"` is an OverflowException. A typo'd knob must
      # not be able to take the install down before helm even runs.
      { Get-MetricsWaitSeconds -Value ("9" * 20) } | Should -Not -Throw
      Get-MetricsWaitSeconds -Value ("9" * 20)     | Should -Be $script:SpecWait
    }
    It "reads TB_METRICS_WAIT_S -- the same knob name the bash installer reads" {
      $env:TB_METRICS_WAIT_S = "77"
      Get-MetricsWaitSeconds | Should -Be 77
    }
  }

  Context "the poll loop" {
    It "returns as soon as the APIService is registered, and asks for the right one" {
      Mock kubectl { $global:LASTEXITCODE = 0 }
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeTrue
      Should -Invoke kubectl -ParameterFilter {
        ($args -contains "apiservice") -and ($args -contains "v1beta1.metrics.k8s.io")
      }
    }

    It "keeps polling across the registration window instead of giving up on the first miss" {
      # THE BUG THIS PORTS AWAY: one probe at t=0 is exactly what `--wait` already
      # gave us, and it is what loses the race on a slow WSL2 box.
      $script:probes = 0
      Mock kubectl {
        if ($args -contains "apiservice") {
          $script:probes++
          $global:LASTEXITCODE = $(if ($script:probes -ge 3) { 0 } else { 1 })
          return
        }
        $global:LASTEXITCODE = 0
      }
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeTrue
      $script:probes | Should -Be 3
    }

    It "the post-registration Available wait is best-effort -- failing it changes nothing" {
      # The template needs the APIService to EXIST at render time; Available is a
      # nicety. A non-zero `kubectl wait` must not turn a won race into a lost one.
      Mock kubectl {
        if ($args -contains "wait") { $global:LASTEXITCODE = 1; return }
        $global:LASTEXITCODE = 0
      }
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeTrue
      Should -Invoke kubectl -ParameterFilter { $args -contains "wait" }
    }

    It "says nothing on the fast path -- an already-registered API must not add a line" {
      Mock kubectl { $global:LASTEXITCODE = 0 }
      Mock Info {}
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeTrue
      Should -Invoke Info -Times 0
    }

    It "announces the wait ONCE when it actually has to wait (RFC-0002 §2, not once per poll)" {
      # bash runs the equivalent loop behind spin_cmd_bounded. Silence here would
      # be a two-minute frozen terminal on exactly the host this exists for; a
      # line per poll would be 40 of them.
      $script:n = 0
      Mock kubectl {
        if ($args -contains "apiservice") {
          $script:n++
          $global:LASTEXITCODE = $(if ($script:n -ge 4) { 0 } else { 1 })
          return
        }
        $global:LASTEXITCODE = 0
      }
      Mock Info {}
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeTrue
      $script:n | Should -BeGreaterThan 1 -Because "the announcement only means anything if we really polled"
      Should -Invoke Info -Times 1 -Exactly
    }

    It "falls through NON-FATALLY when it never registers, so the chart's guard still speaks" {
      # The issue's preferred option (a): a genuinely absent metrics-server must
      # reach `{{ fail }}` and get its actionable message, not die here.
      Mock kubectl { $global:LASTEXITCODE = 1 }
      Mock Err { throw "the metrics wait must never abort the install" }
      $result = $null
      { $result = Wait-MetricsApiService -TimeoutSec 1 -IntervalSec 1 } | Should -Not -Throw
      $result | Should -BeFalse
      Should -Invoke Err -Times 0
    }

    It "is actually bounded -- a never-registering APIService returns near the deadline" {
      # Guards the bound itself: an unbounded loop passes every assertion above.
      Mock kubectl { $global:LASTEXITCODE = 1 }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      Wait-MetricsApiService -TimeoutSec 2 -IntervalSec 1 | Should -BeFalse
      $sw.Stop()
      $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It "a 0 budget disables the wait outright -- no probe, no stall" {
      Mock kubectl { $global:LASTEXITCODE = 0 }
      $env:TB_METRICS_WAIT_S = "0"
      Wait-MetricsApiService | Should -BeFalse
      Should -Invoke kubectl -Times 0
    }

    It "no kubectl on PATH -> says so and returns, rather than polling an exception to the deadline" {
      # A missing native command THROWS; it does not set $LASTEXITCODE.
      Mock Has { $false } -ParameterFilter { $cmd -eq "kubectl" }
      Mock kubectl { throw "must not be called when kubectl is absent" }
      Wait-MetricsApiService -TimeoutSec 30 -IntervalSec 0 | Should -BeFalse
      Should -Invoke kubectl -Times 0
    }
  }

  Context "wired into Install-ClientHelm, on both helm paths" {
    BeforeEach {
      $GPU_VENDOR = "none"; $NVIDIA_DRIVER_OK = $false; $env:CLIENT_ENV = $null
      Mock helm { $global:LASTEXITCODE = 0 }
      Mock Test-Credentials { "valid" }
      Mock Read-Host { throw "no prompts on the minted path" }
      # Ensure-ReleaseDirs reads $script:HOST_DATA_DIR explicitly, so set the
      # script-scoped one rather than inheriting whatever an earlier Describe
      # happened to leave behind -- these tests must pass when run alone too.
      $script:PrevHostDataDir = $script:HOST_DATA_DIR
    }
    AfterEach {
      $script:TB_PROV_MODE = $null; $script:TB_PROV_ID = $null
      $script:TB_PROV_NS = $null; $script:TB_PROV_PASSWORD = $null
      $script:HOST_DATA_DIR = $script:PrevHostDataDir
    }

    It "waits BEFORE helm renders the chart, not after" {
      $script:seq = @()
      Mock Wait-MetricsApiService { $script:seq += "wait"; $true }
      Mock helm {
        if ($args -contains "upgrade") { $script:seq += "helm-upgrade" }
        $global:LASTEXITCODE = 0
      }
      $HOST_DATA_DIR = "$TestDrive/d-metrics-order"; $script:HOST_DATA_DIR = $HOST_DATA_DIR
      $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-m1"
      $script:TB_PROV_PASSWORD = "pw"; $script:TB_PROV_NS = "ns-m1"
      Install-ClientHelm
      $script:seq | Should -Contain "helm-upgrade"
      $script:seq.IndexOf("wait") | Should -BeGreaterOrEqual 0
      $script:seq.IndexOf("wait") |
        Should -BeLessThan $script:seq.IndexOf("helm-upgrade") -Because "rendering first is the whole failure mode (#553)"
    }

    It "waits on the adopted-reuse path too -- that reconcile re-renders the chart" {
      Mock Wait-MetricsApiService { $true }
      Mock Get-InstalledClientInfo {
        [pscustomobject]@{ Id = "uuid-a1"; Ns = "ns-a1"; Name = "rel-a1"; UnreadableNs = ""; ListUnknown = $false }
      }
      $HOST_DATA_DIR = "$TestDrive/d-metrics-adopt"; $script:HOST_DATA_DIR = $HOST_DATA_DIR
      $script:TB_PROV_MODE = "adopted"; $script:TB_PROV_ID = "uuid-a1"
      $script:TB_PROV_NS = "ns-a1"
      Install-ClientHelm
      Should -Invoke Wait-MetricsApiService -Times 1
      Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
    }

    It "a wait that runs out does NOT abort the install -- helm still runs" {
      Mock Wait-MetricsApiService { $false }
      $HOST_DATA_DIR = "$TestDrive/d-metrics-timeout"; $script:HOST_DATA_DIR = $HOST_DATA_DIR
      $script:TB_PROV_MODE = "minted"; $script:TB_PROV_ID = "uuid-m2"
      $script:TB_PROV_PASSWORD = "pw"; $script:TB_PROV_NS = "ns-m2"
      { Install-ClientHelm } | Should -Not -Throw
      Should -Invoke helm -ParameterFilter { $args -contains "upgrade" }
    }
  }

  Context "the APIService name is derived from the chart, not restated here" {
    # Rule 1: the template is the authority for what has to be registered. If the
    # chart ever looks up a different APIService, an installer still waiting on the
    # old name is a wait that cannot succeed -- and it would look identical to a
    # slow cluster. Parse the real `lookup`, compare against both installers.
    BeforeAll {
      $script:TplPath  = "$PSScriptRoot/../../client/templates/resource-monitor-daemonset.yaml"
      $script:PsSrc    = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
      $script:BashSrc  = Get-Content "$PSScriptRoot/../lib/install-client-helm.sh" -Raw
    }
    It "the template really does lookup + fail on an APIService (else this whole wait is pointless)" {
      # Fail closed: an unreadable/renamed template is a finding, not a pass.
      Test-Path $script:TplPath | Should -BeTrue
      $tpl = Get-Content $script:TplPath -Raw
      $m = [regex]::Match($tpl, 'lookup\s+"apiregistration\.k8s\.io/v1"\s+"APIService"\s+""\s+"(?<n>[^"]+)"')
      $m.Success | Should -BeTrue -Because "the render-time guard is the reason the installers wait at all"
      $tpl | Should -Match '\{\{-?\s*fail '
      $script:ApiSvc = $m.Groups['n'].Value
      $script:ApiSvc | Should -Not -BeNullOrEmpty
    }
    It "the Windows installer waits on exactly that name" {
      $tpl = Get-Content $script:TplPath -Raw
      $name = [regex]::Match($tpl, 'lookup\s+"apiregistration\.k8s\.io/v1"\s+"APIService"\s+""\s+"(?<n>[^"]+)"').Groups['n'].Value
      $script:MetricsApiServiceName | Should -Be $name
      $script:PsSrc | Should -Match ([regex]::Escape($name))
    }
    It "bash still waits too, and still best-effort -- if it stops, revisit this port" {
      $fn = [regex]::Match($script:BashSrc, '(?s)_wait_for_metrics_apiservice\(\)\s*\{.*?\n\}').Value
      $fn | Should -Not -BeNullOrEmpty
      $fn | Should -Match 'v1beta1\.metrics\.k8s\.io'
      $fn | Should -Match 'TB_METRICS_WAIT_S'
      $fn | Should -Not -Match '(?m)^\s*error '
    }
    It "both installers read the same knob name, so one support instruction fits both" {
      $script:BashSrc | Should -Match 'TB_METRICS_WAIT_S'
      $script:PsSrc   | Should -Match 'TB_METRICS_WAIT_S'
    }
    It "and neither installer keeps its own copy of the default -- both take the facts.env fact" {
      # Bugbot on #757: one advertised knob whose default could differ per OS. The
      # budget now lives in scripts/spec/facts.env and is stamped by check-facts.sh,
      # so this asserts the INDIRECTION, not the number.
      # \r?$ , not a bare $ : the Windows runner checks these files out CRLF, and
      # .NET's multiline $ matches before \n but NOT before \r\n -- so a bare anchor
      # fails on a line that is plainly there. Cost one red Pester (windows-latest)
      # while Pester (ubuntu-latest) stayed green, which is exactly the shape of bug
      # that job exists to catch.
      $script:BashSrc | Should -Match '(?m)^METRICS_WAIT_TIMEOUT=\d+\r?$'
      $script:PsSrc   | Should -Match '\$script:MetricsWaitTimeout = \d+'
      # No literal fallback left in either poll path.
      $fn = [regex]::Match($script:BashSrc, '(?s)_wait_for_metrics_apiservice\(\)\s*\{.*?\n\}').Value
      $fn | Should -Match '\$METRICS_WAIT_TIMEOUT'
      $psFn = [regex]::Match($script:PsSrc, '(?s)function Get-MetricsWaitSeconds\s*\{.*?\n\}').Value
      $psFn | Should -Match '\$script:MetricsWaitTimeout'
      $psFn | Should -Not -Match '\$Default = \d'
    }
  }
}

Describe "Assert-NodesSeeHostData (backend#2422)" {
  # /tracebloc is the k3d bind mount of HOST_DATA_DIR. If it is not in effect,
  # DirectoryOrCreate fabricates the dirs inside the node and the install looks
  # healthy while storing nothing on this machine. The chart-side fix is
  # unavailable (spec.persistentvolumesource is immutable, so `type: Directory`
  # fails the helm upgrade of any existing release), so this probe is the guard —
  # and it has to fail closed. Keep in step with bash _verify_nodes_see_host_data.
  #
  # Mocks Invoke-DockerCli, not `docker`: the probe routes through the bounded
  # wrapper so a WEDGED daemon cannot hang a headless install (#817 Bugbot).
  BeforeEach {
    $script:HOST_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "tb2422-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $script:HOST_DATA_DIR | Out-Null
    $script:CLUSTER_NAME = "tracebloc"
  }
  AfterEach {
    Remove-Item -Recurse -Force -Path $script:HOST_DATA_DIR -ErrorAction SilentlyContinue
  }

  # The {Code,Output} shape Invoke-DockerCli returns is written out inline in each
  # Mock: a helper function defined here is NOT visible inside a Mock scriptblock
  # (different scope), which fails every test with "term not recognized".
  #
  # Output is ONE STRING with embedded newlines, never an array -- that is what
  # Invoke-BoundedProcess actually builds ($outTask.Result + $errTask.Result). A
  # mock returning an array would pass while production parsed a different shape,
  # which is testing a copy of the code instead of the code.
  It "passes when every node sees the host tree, and leaves no probe file behind" {
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "k3d-tracebloc-agent-0`n" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
    Test-Path (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") | Should -BeFalse
  }

  It "REFUSES when a node cannot see the host tree, and names Docker Desktop file sharing" {
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = "" })
    }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*cannot see your data directory*"
    $err = $null
    try { Assert-NodesSeeHostData } catch { $err = $_.Exception.Message }
    $err | Should -BeLike "*File sharing*"
  }

  It "compares the token, not just the file's presence" {
    # A mount pointed at the WRONG host directory still shows a file of this name
    # from an earlier run. Presence alone would pass; content must not.
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = "a-token-from-some-other-run" })
    }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*cannot see your data directory*"
  }

  It "fails closed when no nodes can be listed" {
    Mock Invoke-DockerCli { return ([pscustomobject]@{ Code = 0; Output = "" }) }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*Couldn't list the nodes*"
  }

  It "fails closed when docker ps itself fails or times out" {
    # Code 124 is Invoke-BoundedProcess's timeout. A wedged daemon must refuse,
    # not be read as "no nodes, carry on" — and certainly not hang (#817 Bugbot).
    Mock Invoke-DockerCli { return ([pscustomobject]@{ Code = 124; Output = "docker ps timed out after 10s" }) }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*Couldn't list the nodes*"
  }

  It "fails closed when a node's docker exec fails" {
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 1; Output = "Error response from daemon" })
    }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*cannot see your data directory*"
  }

  It "fails closed when ONE role's query errors (#817)" {
    # One query per role means a per-role FAILURE is its own fail-closed decision.
    # `server` answers, `agent` errors: we cannot tell whether there are agents to
    # probe, so refusing is the only safe answer. An EMPTY agent list is different
    # and legitimate (AGENTS=0), which is why the branch keys on .Code and not on
    # emptiness — a distinction the empty-list test cannot see, since both reach the
    # same final error (measured: a fail-open mutation stayed green without this).
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") {
        if ($DockerArgs -contains "label=k3d.role=agent") { return ([pscustomobject]@{ Code = 1; Output = "Cannot connect to the Docker daemon" }) }
        return ([pscustomobject]@{ Code = 0; Output = "k3d-tracebloc-server-0`n" })
      }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*Couldn't list the nodes*"
  }

  It "accepts an EMPTY agent list, since AGENTS=0 is legitimate (#817)" {
    # The opposite direction: a single-node cluster genuinely has no agent and must
    # not be refused.
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") {
        if ($DockerArgs -contains "label=k3d.role=agent") { return ([pscustomobject]@{ Code = 0; Output = "" }) }
        return ([pscustomobject]@{ Code = 0; Output = "k3d-tracebloc-server-0`n" })
      }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
  }

  It "checks EVERY node, not just the server" {
    # AGENTS defaults to 1 and agents run kubelets, so a training pod can land on
    # an agent — the same @all-vs-@server trap as the cgroup v1 flag (#806).
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "k3d-tracebloc-agent-0`n" }) }) }
      if ($DockerArgs[1] -like "*server-0") { return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) }) }
      return ([pscustomobject]@{ Code = 0; Output = "" })   # the AGENT is blind
    }
    { Assert-NodesSeeHostData } | Should -Throw -ExpectedMessage "*agent-0*"
  }

  It "ignores the load balancer by ROLE, not by name suffix" {
    # k3d's own k3d.role label says what each container IS. The lb is excluded
    # because it is a `loadbalancer`, not because its name ends in -serverlb.
    Mock Invoke-DockerCli {
      # docker HONOURS the role filters, so a `loadbalancer` is never returned for
      # role=server or role=agent -- excluded by construction, not by a name suffix.
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
  }

  It "selects nodes by the EXACT k3d.cluster label, never a name substring (#817 review)" {
    # `name=k3d-<cluster>-` is an unanchored SUBSTRING match, so a same-prefixed
    # sibling (k3d-tracebloc-dev-*) would be probed too; created against a
    # different HOST_DATA_DIR it cannot see this token and the probe would refuse
    # THIS install while naming a node that is not ours — a false refusal
    # (@saqlainsyed007).
    $script:capturedArgs = $null
    Mock Invoke-DockerCli {
      if ($DockerArgs[0] -eq "ps") {
        $script:capturedArgs = ($DockerArgs -join " ")
        return ([pscustomobject]@{ Code = 0; Output = "k3d-tracebloc-server-0 server`n" })
      }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
    $script:capturedArgs | Should -BeLike "*label=k3d.cluster=tracebloc*"
    $script:capturedArgs | Should -Not -BeLike "*name=k3d-*"
    $script:capturedArgs | Should -BeLike "*k3d.role*"
  }

  It "bounds every docker call with a positive timeout (#817 Bugbot)" {
    # A wedged daemon never returns from a bare `docker`, freezing a headless
    # install with no output. Every call must carry a deadline.
    $script:timeouts = @()
    Mock Invoke-DockerCli {
      $script:timeouts += $TimeoutSec
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
    $script:timeouts.Count | Should -BeGreaterOrEqual 2      # ps + one exec
    ($script:timeouts | Where-Object { $_ -le 0 }).Count | Should -Be 0
  }

  It "isolates stdout so docker stderr cannot forge a miss (#817 @saadqbal / Bugbot)" {
    # THE REAL BUG: Invoke-BoundedProcess returns Output = stdout + stderr concatenated
    # (a plain string join), and the marker is written -NoNewline. So `cat` emits the
    # token with no trailing newline and a docker warning glues onto it INSIDE THE SAME
    # LINE -- "<token>WARNING: ..." -- which is why "take the first non-empty line" does
    # not fix it either. The result is a FALSE REFUSAL after the cluster is already up.
    #
    # Tested against a REAL process, not a mock of Invoke-DockerCli: mocking the very
    # call whose output shape is the bug would assert nothing about the fix. This runs
    # a child that writes to BOTH streams and checks the switch actually separates them.
    $sh = (Get-Command sh -ErrorAction SilentlyContinue)
    if (-not $sh) { Set-ItResult -Skipped -Because "needs a POSIX sh to write both streams"; return }
    # No spaces or quotes inside the stderr payload: Invoke-BoundedProcess quotes any
    # argument containing whitespace, and a nested quoted string inside this -c script
    # gets mangled by that (which is what made the first version of this test fail with
    # a truncated payload rather than a real verdict).
    $script = 'printf tok; printf WARNING:chatter >&2'

    $merged = Invoke-BoundedProcess -FileName $sh.Source -Arguments @("-c", $script) -TimeoutSec 20
    $merged.Code | Should -Be 0
    $merged.Output | Should -BeLike "*WARNING*" -Because "the default must keep merging, or callers that classify stderr break"
    # and it glues on with NO separator -- the precise mechanism of the bug, and the
    # reason a first-non-empty-line fix cannot work
    $merged.Output | Should -Be "tokWARNING:chatter"

    $isolated = Invoke-BoundedProcess -FileName $sh.Source -Arguments @("-c", $script) -TimeoutSec 20 -StdoutOnly
    $isolated.Code | Should -Be 0
    $isolated.Output | Should -Be "tok"
    $isolated.Output | Should -Not -BeLike "*WARNING*"
  }

  It "keeps merged stderr on a NON-ZERO exit even under -StdoutOnly (client#828)" {
    # THE CONTRACT: -StdoutOnly isolates stdout ONLY on the success path (exit 0).
    # A non-zero exit is a failure path and must return the merged stdout+stderr so
    # the caller still has the child's diagnostics -- gating isolation on the switch
    # alone silently discarded stderr, making a failed child look like it produced
    # nothing rather than like the helper threw its stderr away (client#828).
    #
    # Real child, not a mock: the return-shape on failure IS the fix, so a mock of
    # Invoke-DockerCli would assert nothing. The child exits 3 after writing to BOTH
    # streams; the stderr payload has no space/quote for the same quoting reason as
    # the success-path test above.
    $sh = (Get-Command sh -ErrorAction SilentlyContinue)
    if (-not $sh) { Set-ItResult -Skipped -Because "needs a POSIX sh to write both streams"; return }
    $script = 'printf tok; printf WARNING:boom >&2; exit 3'

    $failed = Invoke-BoundedProcess -FileName $sh.Source -Arguments @("-c", $script) -TimeoutSec 20 -StdoutOnly
    $failed.Code | Should -Be 3
    # stderr SURVIVES the failure despite -StdoutOnly -- the whole point of #828
    $failed.Output | Should -BeLike "*WARNING*" -Because "a failing -StdoutOnly caller still needs the child's stderr diagnostics (client#828)"
    # and it is the same merged string a non-isolated failing call would return
    $failed.Output | Should -Be "tokWARNING:boom"
  }

  It "passes -StdoutOnly on BOTH docker calls, so the isolation cannot regress (#817)" {
    # The switch above only helps if this function actually asks for it. Capture what
    # the probe requests rather than trusting the wiring.
    $script:sawStdoutOnly = @()
    Mock Invoke-DockerCli {
      $script:sawStdoutOnly += [bool]$StdoutOnly
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw
    $script:sawStdoutOnly.Count | Should -BeGreaterOrEqual 2          # ps + one exec
    ($script:sawStdoutOnly | Where-Object { -not $_ }).Count | Should -Be 0
  }

  It "passes no argument carrying a space or a quote (#817 Bugbot, High)" {
    # DEFENSE IN DEPTH. Invoke-BoundedProcess now escapes inner quotes correctly
    # (ConvertTo-Win32Arg, backend#2455), so this shape is no longer corrupted at the
    # helper -- but the probe still keeps its args space/quote-free so it never depends
    # on that. Historically the joiner quoted any whitespace-bearing value as
    # '"' + $_ + '"' with NO escaping of inner quotes, so the obvious single query --
    #   --format "{{.Names}} {{.Label `"k3d.role`"}}"
    # -- has both a space and quotes, so it went out with its own quotes intact and
    # CommandLineToArgvW toggled in and out of quoting to hand docker ONE token with
    # the inner quotes CONSUMED: `{{.Names}} {{.Label k3d.role}}`. text/template then
    # cannot parse k3d.role as an identifier, docker exits non-zero, and the probe
    # threw "Couldn't list the nodes" -- a FALSE REFUSAL on every Windows hostpath
    # install, after the cluster is already up.
    #
    # Why no earlier test caught it: every case here mocks Invoke-DockerCli, so the
    # quoting lives BELOW the mock and is unreachable from Pester. The property is
    # therefore asserted at the mock boundary instead -- on the ARGUMENTS, which is
    # the layer this suite can actually see.
    $script:allArgs = @()
    Mock Invoke-DockerCli {
      $script:allArgs += ,@($DockerArgs)
      if ($DockerArgs[0] -eq "ps") { return ([pscustomobject]@{ Code = 0; Output = $(if ($DockerArgs -contains "label=k3d.role=server") { "k3d-tracebloc-server-0`n" } else { "" }) }) }
      return ([pscustomobject]@{ Code = 0; Output = (Get-Content (Join-Path $script:HOST_DATA_DIR ".tracebloc-mount-probe") -Raw) })
    }
    { Assert-NodesSeeHostData } | Should -Not -Throw

    $flat = @($script:allArgs | ForEach-Object { $_ })
    $flat.Count | Should -BeGreaterThan 0
    # A quote in ANY argument is unsafe here, whether or not it also has a space:
    # the quoting branch only triggers on whitespace, so a quoted value silently
    # passes through un-escaped either way.
    @($flat | Where-Object { $_ -like '*"*' }).Count | Should -Be 0 -Because "an inner quote is passed through unescaped"
    @($flat | Where-Object { $_ -match '\s' }).Count  | Should -Be 0 -Because "a whitespace-bearing arg hits the unescaped quoting branch"
    # and the scoping must still be real: both roles queried, exact cluster label
    ($flat -contains "label=k3d.role=server") | Should -BeTrue
    ($flat -contains "label=k3d.role=agent")  | Should -BeTrue
    ($flat -contains "label=k3d.cluster=tracebloc") | Should -BeTrue
  }

  It "mints the token without culture-sensitive parsing (#817 Bugbot, High)" {
    # THE FUNCTIONAL TEST CANNOT PROVE THIS HERE, and pretending otherwise was the
    # first version of this test: on PowerShell 7 `Get-Date -UFormat %s` emits a
    # bare integer ("1787575411"), which [double]::Parse accepts in every culture
    # -- measured across en-US / de-DE / fr-FR, all three fine. So a de-DE
    # round-trip passes with the bug still in place (confirmed by mutation).
    #
    # The bug is real on the platform this installer actually targets. It declares
    # `#Requires -Version 5.1` and is invoked via powershell.exe (see the note at
    # install-k8s.ps1:1896), and Windows PowerShell 5.1 emits %s WITH a fractional
    # part. In de-DE "." is the GROUP separator, so that string either throws
    # FormatException or -- worse -- parses to a wildly wrong number. Either way
    # the operator gets a cryptic .NET error on an already-created cluster instead
    # of a mount check.
    #
    # So this is a source guard: assert the mint does no culture-sensitive parsing
    # at all. That is the property, it is checkable here, and it reddens under the
    # mutation that a de-DE round-trip cannot see.
    $src = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    $fn  = [regex]::Match($src, 'function Assert-NodesSeeHostData \{.*?\n\}', 'Singleline').Value
    $fn | Should -Not -BeNullOrEmpty
    # COMMENT LINES STRIPPED, or the guard trips on the comment that EXPLAINS the
    # ban -- it names both banned constructs, so the first version of this test
    # failed on its own documentation. Same reason scripts/tests/
    # k3s-components-agreement.sh reads the installer with comments removed.
    $code = ($fn -split "`r?`n" | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
    $code | Should -Not -Match '\[double\]::Parse'
    $code | Should -Not -Match 'UFormat'
    # and it must still mint SOMETHING unique per run
    $code | Should -Match 'Get-Random'
  }
}


# ── Get-TrainingLimits (backend#2418, Utilization Ladder L0.2) ───────────────
#
# CPU is time-shared: `requests` with NO `limits` is a cgroup share weight,
# whereas requests == limits is a cpu.max QUOTA that throttles at its ceiling on
# a completely idle box. Memory is not time-shared -- over the limit is an OOM
# kill -- so requests == limits stays there and only cpu is dropped.
#
# The bash twin is `_training_limits` in scripts/lib/install-client-helm.sh; the
# two are pinned to agree by scripts/tests/fixtures/installer_parity.json. The
# whitespace case below is a real divergence the bash side had and this side did
# not: `case " cpu=7 " in cpu=*)` does not match, so an untrimmed pair kept the
# cpu limit on Linux/macOS while `.Trim()` dropped it on Windows.
Describe "Get-TrainingLimits" {
  It "drops cpu and keeps memory" {
    Get-TrainingLimits "cpu=7,memory=29Gi" | Should -Be "memory=29Gi"
  }
  It "keeps every non-cpu dimension, not just memory" {
    # backend#2223 added ephemeral-storage; a "memory only" filter would silently
    # drop a disk limit and let a pod fill the node's disk.
    Get-TrainingLimits "cpu=7,memory=29Gi,ephemeral-storage=26Gi" |
      Should -Be "memory=29Gi,ephemeral-storage=26Gi"
  }
  It "leaves a size with no cpu unchanged" {
    Get-TrainingLimits "memory=16Gi" | Should -Be "memory=16Gi"
  }
  It "returns the input for a cpu-ONLY size, never empty" {
    # An empty RESOURCE_LIMITS reads to jobs-manager as UNSET, which since
    # client-runtime#388 mirrors the requests side back -- resurrecting the very
    # cpu limit this function exists to drop.
    Get-TrainingLimits "cpu=4" | Should -Be "cpu=4"
  }
  It "matches cpu= case-insensitively, and the bash twin now agrees" {
    # Divergence caught in review on client#820: this side's `-like` was
    # already case-insensitive while bash's `case cpu=*)` was not, so
    # `CPU=7,...` kept the cpu limit on Linux/macOS and dropped it here. Bash
    # now uses [Cc][Pp][Uu] character classes (macOS ships bash 3.2, which has
    # no `${var,,}`).
    Get-TrainingLimits "CPU=7,memory=29Gi" | Should -Be "memory=29Gi"
    Get-TrainingLimits "Cpu=7,memory=29Gi" | Should -Be "memory=29Gi"
    Get-TrainingLimits "CPU=7,CPUSET=0-3,memory=29Gi" |
      Should -Be "CPUSET=0-3,memory=29Gi"
  }
  It "trims each pair before matching cpu=" {
    Get-TrainingLimits " cpu=7 , memory=29Gi " | Should -Be "memory=29Gi"
  }
  It "skips empty pairs" {
    Get-TrainingLimits "cpu=7,,memory=29Gi" | Should -Be "memory=29Gi"
  }
  It "does not eat a dimension that merely starts with cpu" {
    Get-TrainingLimits "cpu=7,cpuset=0-3,memory=29Gi" |
      Should -Be "cpuset=0-3,memory=29Gi"
  }
}


# ── the carry path after L0.2 (backend#2418, Bugbot High on client#820) ──────
#
# `RESOURCE_LIMITS` stopped being the whole envelope, so a reader taking the
# carried size from it broke REINSTALL two ways: the size came back as
# `memory=29Gi` and was written into RESOURCE_REQUESTS (dropping the cpu
# request), and the historic-literal gate stopped matching so the post-filter
# default was mistaken for a deliberate choice. The reader now prefers
# RESOURCE_REQUESTS and falls back to LIMITS. Bash twin:
# `_existing_training_values`.
Describe "Get-TrainingResources carry path (backend#2418)" {
  BeforeEach { $env:TRACEBLOC_TRAINING_RESOURCES = $null; $script:TB_NAMESPACE = "tracebloc" }
  AfterEach { $script:TB_NAMESPACE = $null }

  It "carries RESOURCE_REQUESTS, not the memory-only RESOURCE_LIMITS" {
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"memory=29Gi","RESOURCE_REQUESTS":"cpu=7,memory=29Gi","RESOURCE_PROVENANCE":"user"}}'
    }
    Get-TrainingResources | Should -Be "cpu=7,memory=29Gi"
  }

  It "falls back to RESOURCE_LIMITS when REQUESTS is absent" {
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi"}}'
    }
    Get-TrainingResources | Should -Be "cpu=4,memory=12Gi"
  }

  It "still refuses to carry the historic literal" {
    # The gate that keeps an unschedulable 8Gi off the machines this sizing
    # exists to fix. It compares the FULL envelope, which only works because
    # the reader takes RESOURCE_REQUESTS.
    Mock kubectl { $global:LASTEXITCODE = 0 }
    Mock helm {
      $global:LASTEXITCODE = 0
      '{"env":{"RESOURCE_LIMITS":"memory=8Gi","RESOURCE_REQUESTS":"cpu=2,memory=8Gi"}}'
    }
    # Not carried: the answer is machine-derived, so it still names a cpu
    # dimension. Asserting only "not the literal" would pass vacuously under
    # the mutation this test exists to catch.
    Get-TrainingResources | Should -Not -Be "memory=8Gi"
    Get-TrainingResources | Should -Match '^cpu='
  }
}

Describe 'kubelet image-GC bound on an EXISTING cluster (backend#2634)' {
  # Bugbot Medium on client#912: the bash twin warned when a reused cluster had no
  # kubelet config mount and this twin did not, so every Windows/WSL2 edge created
  # before that change stayed on the stock 85/80 thresholds with no signal. The two
  # twins agreed on every VALUE while disagreeing on this BEHAVIOUR, which is why
  # value agreement did not catch it.
  #
  # Source-level, like the k3s-component block above and for the same reason:
  # New-K3dCluster's reuse branch needs a live k3d + docker to execute. The gate is
  # scripts/tests/kubelet-config-agreement.sh, which runs in the required
  # `Source-of-truth drift` job and asserts BOTH twins carry the check. This is the
  # local-feedback half.
  BeforeAll {
    $script:Raw = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    # Comment lines dropped: the block documents itself, and a check satisfied by
    # its own documentation is not checking code.
    $script:Code = ($script:Raw -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  }

  It 'inspects the node mounts on the reuse path' {
    $script:Code | Should -Match 'kubeletMounts'
    $script:Code | Should -Match 'docker inspect'
  }

  It 'keys the comparison on the SHARED node-path variable, not a literal' {
    # A literal would silently stop matching the moment the mount path moves, and
    # the agreement guard could not tie the two twins together.
    $script:Code | Should -Match 'TB_KUBELET_CONFIG_NODE_PATH'
  }

  It 'WARNS and offers the recreate hint, and does NOT Err' {
    # Err here would turn every ordinary re-run against an existing cluster into a
    # hard failure, because an unbounded image store is today's status quo on every
    # edge. The dataset-mount sibling Errs; this one deliberately must not.
    $script:Code | Should -Match 'no kubelet config mount'
    $idx = $script:Code.IndexOf('no kubelet config mount')
    $window = $script:Code.Substring($idx, [Math]::Min(900, $script:Code.Length - $idx))
    $window | Should -Match 'Write-RecreateClusterHint'
    $window | Should -Not -Match '\bErr\b'
  }

  It 'stays silent when the mounts could not be read' {
    # 'cannot tell' must not read as 'missing', or the warning trains people to
    # ignore it. The guard is the `-and` on a non-empty $kubeletMounts.
    $script:Code | Should -Match '\$kubeletMounts -and'
  }

  It 'is a FUNCTION, so a path that does not build a cluster can call it' {
    # Inline in New-K3dCluster it was unreachable by the population it exists for:
    # main()'s completed+healthy fast path never enters New-K3dCluster, so every
    # already-working pre-#2634 edge got silence. The only mention of the name over
    # here was a comment (reviewer, client#912). Same lesson as Read-RebootChoice
    # and Test-K3sVersionDrift: a guard the fast path cannot call does not exist.
    $script:Code | Should -Match 'function Test-ExistingClusterKubeletConfig'
  }

  It 'runs on the completed+healthy fast path, after the k3s and GPU advisories' {
    # THE ASSERTION THAT WOULD HAVE CAUGHT THIS. Defining the function is not
    # wiring it; the previous version of this Describe asserted the block existed
    # and said nothing about who reaches it, which is exactly how it shipped
    # unreachable. Anchored on the fast path's own success line, the way the
    # Test-K3sVersionDrift assertion at ~4393 already is.
    $script:Code | Should -Match 'client is healthy -- nothing to do[\s\S]{0,700}?Test-ExistingClusterKubeletConfig'
  }

  It 'bounds the docker inspect, so a wedged engine cannot hang a healthy re-run' {
    # It now runs AFTER the success line on a machine that is already working, so an
    # unbounded probe would hang a healthy host to deliver an advisory (installer
    # rule; the reviewer asked for this explicitly). Same Start-Job + deadline
    # pattern as its siblings.
    $idx = $script:Code.IndexOf('function Test-ExistingClusterKubeletConfig')
    $window = $script:Code.Substring($idx, [Math]::Min(1400, $script:Code.Length - $idx))
    $window | Should -Match 'Start-Job'
    $window | Should -Match 'Wait-JobWithProgress'
  }

  It 'TRIMS the received inspect output, so an unreadable cluster stays silent' {
    # Bugbot Medium on client#912. Two Out-String hops (the job body stringifies,
    # then Receive-Job stringifies again) turn an empty or failed `docker inspect`
    # into a lone newline -- TRUTHY in PowerShell -- so the `-and` empty-guard
    # passed and the recreate warning fired on a cluster nobody could read. The
    # bash twin returns early on the same input, so it was a twin divergence too.
    #
    # Asserted inside the FUNCTION's own text: the k3s sibling has always had the
    # .Trim(), so a whole-file match is satisfied by it while this one has none.
    # That is exactly how the first version of the drift assertion went vacuous.
    $fn = [regex]::Match($script:Code,
      '(?s)function Test-ExistingClusterKubeletConfig \{.*?\n\}').Value
    $fn | Should -Not -BeNullOrEmpty
    $fn | Should -Match 'Out-String\)\.Trim\(\)'
  }

  It 'agrees with the bash twin on the operator-visible message' {
    # The agreement guard keys on this exact phrase in both files. If either side
    # rewords it, the guard stops tying them together and this catches it here.
    $bash = Get-Content "$PSScriptRoot/../lib/cluster.sh" -Raw
    $bash | Should -Match 'no kubelet config mount'
  }
}
