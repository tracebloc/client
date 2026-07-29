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
    Mock Err { param($m) $script:lastErr = $m; throw "err" }
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
  It "Get-PfMemGb prefers docker MemTotal over the host" {
    Mock docker { '8589934592' }          # 8 GiB, in bytes
    Get-PfMemGb | Should -Be 8
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

Describe "Test-PreflightRuntimeMem (post-Docker, warn-only)" {
  It "small Docker VM -> warns, does not throw" {
    Mock Get-PfRuntimeMemGb { 4 }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
  }
  It "daemon not reporting (null) -> no-op, does not throw" {
    Mock Get-PfRuntimeMemGb { $null }
    { Test-PreflightRuntimeMem } | Should -Not -Throw
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
