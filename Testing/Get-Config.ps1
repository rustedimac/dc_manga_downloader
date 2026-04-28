# Get-Config.ps1
# Shared config loader for the DC Manga Downloader Suite.
# Dot-source this file in any script: . (Join-Path $PSScriptRoot "Get-Config.ps1")
# Then call: $Config = Get-Config

function Get-Config {
    param (
        [string]$ConfigPath = (Join-Path $PSScriptRoot "config.yaml")
    )

    $Config = @{}

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "config.yaml not found at: $ConfigPath"
        return $Config
    }

    Get-Content $ConfigPath | Where-Object { $_ -match '^\s*([^:#][^:]*)\s*:\s*(.*)$' } | ForEach-Object {
        $Key   = $Matches[1].Trim()
        $Value = ($Matches[2] -split '#')[0].Trim(" `"'")
        $Config[$Key] = $Value
    }

    return $Config
}
