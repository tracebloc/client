# Pester tests for scripts/install-k8s.ps1 (Windows installer).
# Dot-sources the script with $env:TB_PESTER set so the admin gate + main() are
# skipped and only the functions load. Run: Invoke-Pester scripts/tests/

BeforeAll {
  $env:TB_PESTER = "1"
  . "$PSScriptRoot/../install-k8s.ps1"
  # Stubs so Pester can mock external commands that the functions invoke.
  function kubectl { }
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
}

Describe "ConvertTo-WorkspaceName" {
  It "lowercases + dashes spaces/underscores" { ConvertTo-WorkspaceName -Input_ "My Team_1" | Should -Be "my-team-1" }
  It "all-invalid -> default" { ConvertTo-WorkspaceName -Input_ "@@@" | Should -Be "default" }
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
    $env:USERPROFILE = $env:HOME
    $CLUSTER_NAME = "tracebloc"; $SERVERS = "1"; $AGENTS = "1"; $HOST_DATA_DIR = "$env:HOME/.tracebloc"
    { Confirm-Config } | Should -Not -Throw
  }
  It "invalid CLUSTER_NAME -> Err" {
    Mock Err { throw "err" }
    $env:USERPROFILE = $env:HOME
    $CLUSTER_NAME = "1bad"; $SERVERS = "1"; $AGENTS = "1"; $HOST_DATA_DIR = "$env:HOME/x"
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
}

Describe "Confirm-Cluster" {
  It "dumps cluster status without error" {
    $script:TB_NAMESPACE = "ns"; $script:LOG_FILE = "$TestDrive/log.txt"
    Mock kubectl { "info" }
    { Confirm-Cluster } | Should -Not -Throw
  }
}
