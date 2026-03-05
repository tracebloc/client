# =============================================================================
#  Bootstrap installer (Windows) — downloads install-k8s.ps1 from GitHub
#  and runs it.  Equivalent of install.sh for macOS/Linux.
#
#  Usage (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
#    $env:BRANCH = "develop"; irm ... | iex
#
#  macOS / Linux:
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
# =============================================================================

$ErrorActionPreference = "Stop"

# ── Platform gate ────────────────────────────────────────────────────────────
if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
  Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline
  Write-Host " This script is for Windows. On macOS / Linux use:" -ForegroundColor Red
  Write-Host "  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash" -ForegroundColor Cyan
  exit 1
}

$Branch  = if ($env:BRANCH) { $env:BRANCH } else { "main" }
$RepoRaw = "https://raw.githubusercontent.com/tracebloc/client/$Branch"
$TmpDir  = Join-Path $env:TEMP "tracebloc-installer-$(Get-Random)"

Write-Host "  " -NoNewline; Write-Host "Downloading tracebloc installer..." -ForegroundColor DarkGray

New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

$ScriptUrl  = "$RepoRaw/scripts/install-k8s.ps1"
$ScriptDest = Join-Path $TmpDir "install-k8s.ps1"

$maxAttempts = 3
for ($i = 1; $i -le $maxAttempts; $i++) {
  try {
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $ScriptDest -UseBasicParsing
    break
  } catch {
    if ($i -eq $maxAttempts) {
      Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline
      Write-Host " Failed to download installer after $maxAttempts attempts: $_" -ForegroundColor Red
      Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
      exit 1
    }
    Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow -NoNewline
    Write-Host "  Download failed (attempt $i/$maxAttempts). Retrying in 5s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
  }
}

try {
  & $ScriptDest @args
} finally {
  Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
