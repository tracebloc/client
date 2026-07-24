# Pester tests for scripts/install-k8s.ps1 (Windows installer).
# Dot-sources the script with $env:TB_PESTER set so the admin gate + main() are
# skipped and only the functions load. Run: Invoke-Pester scripts/tests/

BeforeAll {
  $env:TB_PESTER = "1"
  . "$PSScriptRoot/../install-k8s.ps1"
  # Stubs so Pester can mock external commands that the functions invoke.
  function kubectl { }
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
    Mock helm { $global:LASTEXITCODE = 0; '{"env":{"RESOURCE_LIMITS":"cpu=4,memory=12Gi"}}' }
    Get-TrainingResources | Should -Be "cpu=4,memory=12Gi"
  }
  It "fresh install sized to the largest node minus overhead (k3d nodes not summed)" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    # The mock only answers a BOUNDED call — dropping --request-timeout fails
    # this test (a wedged API must never hang values generation).
    Mock kubectl {
      if ($args -contains "--request-timeout=10s") {
        $global:LASTEXITCODE = 0
        '{"items":[{"status":{"allocatable":{"cpu":"12","memory":"6924Mi"}}},{"status":{"allocatable":{"cpu":"12","memory":"6924Mi"}}}]}'
      } else { $global:LASTEXITCODE = 1; "" }
    }
    Get-TrainingResources | Should -Be "cpu=11,memory=3Gi"
  }
  It "below-floor machine falls back to the static default" {
    Mock helm { $global:LASTEXITCODE = 1; "" }
    Mock kubectl { $global:LASTEXITCODE = 0; '{"items":[{"status":{"allocatable":{"cpu":"2","memory":"4Gi"}}}]}' }
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
}

Describe "Test-Preflight" {
  BeforeEach {
    Mock Err { throw "preflight-failed" }      # Err exits; make it throwable to assert
    Mock Get-PfCpu { 4 }; Mock Get-PfMemGb { 8 }; Mock Get-PfFreeGb { 50 }
    Mock Get-WindowsArch { "amd64" }
    Mock Get-PfFsType { "local" }
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
