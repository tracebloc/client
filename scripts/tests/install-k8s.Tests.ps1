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
    $script:PSRC | Should -Match 'if \(-not \(Test-InstallSucceeded\)\) \{ exit 1 \}'
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
  BeforeEach { $script:TB_NAMESPACE = "tracebloc"; $env:TRACEBLOC_TRAINING_RESOURCES = $null }
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
  }

  It "every single-node golden vector replays" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    $failures = @()
    foreach ($v in $script:Contract.vectors.single_node) {
      # A machine below the contract floor, or with unparseable allocatable,
      # makes the installer emit nothing and fall through to the literal.
      $want = if ($null -eq $v.expected -or -not $v.expected.viable) {
        "cpu=2,memory=8Gi"
      } else {
        "cpu=$($v.expected.render_gi.cpu),memory=$($v.expected.render_gi.memory)"
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
    $script:PSRC577 | Should -Match 'if \(-not \$env:TB_PESTER\)[\s\S]{0,600}?try \{'
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
    $script:PSRC577b | Should -Match 'trap \{ Show-FatalError \$_; exit 1 \}'
    $script:PSRC577b | Should -Match '\} finally \{'
    $script:PSRC577b | Should -Match 'if \(-not \$script:OutcomeReported\) \{ Show-Interrupted \}'
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
    $script:CEC | Should -Match 'function Wait-ProcessWithDeadline[\s\S]{0,1600}\$Process\.WaitForExit\(\)[\s\S]{0,80}return \$true'
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

Describe "Bounded process quotes whitespace arguments (#616 Bugbot)" {
  BeforeAll { $script:QSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }
  It "the joiner quotes-on-whitespace and skips already-quoted values (source guard)" {
    # The args are joined into ONE command line, so an unquoted value with a space -- a registry
    # username, or a temp path under a profile like C:\Users\First Last\... -- would silently
    # become two arguments and corrupt the command.
    $fn = (($script:QSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'ForEach-Object'
    $fn | Should -Match 'notmatch'                 # the already-quoted escape hatch
    $fn | Should -Match 'Quote any argument containing whitespace'
  }
  It "behavioural: a username with a space survives as ONE argument" {
    # exercises the same expression the function uses
    $parts = @("login", "ghcr.io", "-u", "First Last", "--password-stdin")
    $joined = (($parts | ForEach-Object {
      if ($_ -eq "") { '""' } elseif ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
    $joined | Should -Be 'login ghcr.io -u "First Last" --password-stdin'
  }
  It "behavioural: an already-quoted path is not double-quoted, and empty survives" {
    $parts = @('"C:\Temp\a b\p.json"', "", "plain")
    $joined = (($parts | ForEach-Object {
      if ($_ -eq "") { '""' } elseif ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
    $joined | Should -Be '"C:\Temp\a b\p.json" "" plain'
  }
}

Describe "Bounded process survives a child that closes stdin first (broken pipe)" {
  BeforeAll {
    $script:BPSRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw
    # Load the REAL function rather than a copy of it, so this cannot pass while the
    # shipped one throws -- the whole failure mode being tested is an unguarded call.
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
    $fn = (($script:BPSRC -split 'function Invoke-BoundedProcess')[1] -split '\nfunction ')[0]
    $fn | Should -Match 'try \{ \$proc\.StandardInput\.Write\(\$Stdin\); \$proc\.StandardInput\.Close\(\) \} catch'
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
