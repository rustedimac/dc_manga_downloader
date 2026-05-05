# ==========================================
# DC Manga - Auto-Populate Alias Registry
# ==========================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent

# [NEW] Load settings safely via Get-Config
. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config = Get-Config

$DownloadDir = if ($Config.DownloadDir -and [System.IO.Path]::IsPathRooted($Config.DownloadDir)) {
    $Config.DownloadDir
} else {
    Join-Path $RootDir ($Config.DownloadDir -replace '^\.\\', '')
}

$AliasFile = Join-Path $RootDir "Data\series_aliases.csv"
$DataDir = Split-Path $AliasFile
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "    Alias Registry Population Tool        " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$Existing = @{}
if (Test-Path $AliasFile) {
    $aliases = @(Import-Csv $AliasFile -Encoding UTF8)
    foreach ($a in $aliases) { $Existing[$a.OriginalName] = $a.OperatorName }
}

if (-not (Test-Path $DownloadDir)) {
    Write-Host "[ERROR] Download directory not found at: $DownloadDir" -ForegroundColor Red
    Pause; exit
}

$Folders = Get-ChildItem -Path $DownloadDir -Directory
$AddedCount = 0

foreach ($f in $Folders) {
    $Name = $f.Name
    if (-not $Existing.ContainsKey($Name)) {
        $Existing[$Name] = $Name
        $AddedCount++
    }
}

if ($AddedCount -gt 0) {
    $out = $Existing.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ OriginalName=$_; OperatorName=$Existing[$_] } }
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    
    # [NEW] Safely write using Cross-Process Mutex Locks and Atomic Write
    Invoke-WithFileLock "Aliases" {
        Write-FileAtomic -Path $AliasFile -Content $out -Encoding $Enc -AsCsv
    }
    
    Write-Host "`nSUCCESS: Successfully added $AddedCount existing folders to the Alias Registry." -ForegroundColor Green
    Write-Host "You can now edit them using the Scanner's Alias Manager." -ForegroundColor Gray
} else {
    Write-Host "`nNo new folders to add. Alias registry is up to date." -ForegroundColor Yellow
}

Write-Host "`nPress Enter to exit..." -ForegroundColor Gray
$null = Read-Host