$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

function Invoke-InDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Push-Location $Path
    try {
        & $Action
    }
    finally {
        Pop-Location
    }
}

Write-Host "==> Verifying Dart CLI"
Invoke-InDirectory (Join-Path $RepoRoot "app_updater_cli") {
    Invoke-Checked "dart" @("pub", "get")
    Invoke-Checked "dart" @("format", "--output=none", "--set-exit-if-changed", "bin", "lib", "test")
    Invoke-Checked "dart" @("analyze")
    Invoke-Checked "dart" @("test")
}

Write-Host "==> Verifying Flutter plugin"
Invoke-InDirectory (Join-Path $RepoRoot "app_updater") {
    Invoke-Checked "flutter" @("pub", "get")
    Invoke-Checked "flutter" @("analyze")
    Invoke-Checked "flutter" @("test")
}

Write-Host "==> Verifying sample application"
Invoke-InDirectory (Join-Path $RepoRoot "sample_app") {
    Invoke-Checked "flutter" @("pub", "get")
    Invoke-Checked "flutter" @("analyze")
    Invoke-Checked "flutter" @("test")
}

Write-Host "==> Verifying Android runtime"
Invoke-InDirectory (Join-Path $RepoRoot "ota_runtime_android") {
    Invoke-Checked ".\gradlew.bat" @("test")
}

Write-Host "Windows verification completed successfully."
