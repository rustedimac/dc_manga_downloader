param (
    [double]$AutoInterval = 0,
    [double]$BoardInterval = 0
)

# Lock the window title so launch.bat can always find and kill it
$Host.UI.RawUI.WindowTitle = "DC Manga Scheduler"

# ==========================================
# DC Manga Background Scheduler
# ==========================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent
$ConfigFile = Join-Path $RootDir "config.yaml"

# --- CONFIG PARSER ---
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

# --- INTERVAL LOGIC & CONFIG UPDATER ---
$Lines = Get-Content $ConfigFile -Encoding UTF8
$ConfigUpdated = $false

if ($AutoInterval -gt 0) {
    $AutoCrawlerIntervalHours = $AutoInterval
    # Regex replace the line in memory
    $Lines = $Lines -replace '(?i)^\s*AutoCrawlerIntervalHours\s*:.*', "AutoCrawlerIntervalHours: $AutoInterval"
    $ConfigUpdated = $true
} else {
    $AutoCrawlerIntervalHours = if ($Config.AutoCrawlerIntervalHours) { [double]$Config.AutoCrawlerIntervalHours } else { 1 }
}

if ($BoardInterval -gt 0) {
    $BoardCrawlerIntervalHours = $BoardInterval
    $Lines = $Lines -replace '(?i)^\s*BoardCrawlerIntervalHours\s*:.*', "BoardCrawlerIntervalHours: $BoardInterval"
    $ConfigUpdated = $true
} else {
    $BoardCrawlerIntervalHours = if ($Config.BoardCrawlerIntervalHours) { [double]$Config.BoardCrawlerIntervalHours } else { 12 }
}

# Save updated config back to disk ONLY if we passed in custom arguments
if ($ConfigUpdated) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $Lines | Set-Content $ConfigFile -Encoding $Enc
    Write-Host "Updated config.yaml with new scheduler intervals." -ForegroundColor Green
}

$AutoIntervalSec  = $AutoCrawlerIntervalHours * 3600
$BoardIntervalSec = $BoardCrawlerIntervalHours * 3600

# Set initial run times (Trigger immediately on launch)
$NextAuto  = (Get-Date)
$NextBoard = (Get-Date)

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   DC Manga Background Scheduler Active   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Auto-Crawler runs every: $AutoCrawlerIntervalHours hour(s)"
Write-Host "Board Scanner runs every: $BoardCrawlerIntervalHours hour(s)"
Write-Host "Leave this window open. You can toggle it off from the main menu.`n" -ForegroundColor Gray

while ($true) {
    $Now = Get-Date

    if ($Now -ge $NextAuto) {
        Write-Host "[$Now] Triggering Auto-Crawler..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "Run-Crawler.ps1")
        $NextAuto = $Now.AddSeconds($AutoIntervalSec)
        Write-Host "Next Auto-Crawler run at: $NextAuto`n" -ForegroundColor DarkGray
    }

    if ($Now -ge $NextBoard) {
        Write-Host "[$Now] Triggering Board Series Scanner..." -ForegroundColor Green
        # UPDATED: Now calls Search-Scanner.ps1 instead of Search-Crawler.ps1
        & (Join-Path $PSScriptRoot "Search-Scanner.ps1") -RunBoardCrawler
        $NextBoard = $Now.AddSeconds($BoardIntervalSec)
        Write-Host "Next Board Scanner run at: $NextBoard`n" -ForegroundColor DarkGray
    }

    Start-Sleep -Seconds 10
}