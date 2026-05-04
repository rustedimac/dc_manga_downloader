# ==========================================
# DC Manga Background Scheduler
# ==========================================
param (
    [string]$AutoInterval = "",
    [string]$BoardInterval = ""
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent
$ConfigFile = Join-Path $RootDir "config.yaml"

. (Join-Path $PSScriptRoot "Get-Config.ps1")

$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

$AutoH = if ($AutoInterval) { [double]$AutoInterval } elseif ($Config.AutoCrawlerIntervalHours) { [double]$Config.AutoCrawlerIntervalHours } else { 1 }
$BoardH = if ($BoardInterval) { [double]$BoardInterval } elseif ($Config.BoardCrawlerIntervalHours) { [double]$Config.BoardCrawlerIntervalHours } else { 12 }

$NextAuto = (Get-Date)
$NextBoard = (Get-Date).AddHours($BoardH)

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      DC Manga Background Scheduler       " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Auto-Crawler Interval : $AutoH hours" -ForegroundColor Gray
Write-Host "Board Scanner Interval: $BoardH hours" -ForegroundColor Gray
Write-Host "Leave this window open to run in the background." -ForegroundColor Yellow
Write-Host "==========================================`n" -ForegroundColor Cyan

while ($true) {
    $Now = Get-Date

    if ($Now -ge $NextAuto) {
        Write-Host "[$($Now.ToString('MM/dd/yyyy HH:mm:ss'))] Triggering Auto-Crawler..." -ForegroundColor Green
        
        # 1. Run the Crawler to find links
        & (Join-Path $PSScriptRoot "Run-Crawler.ps1")
        
        # 2. INSTANTLY trigger the Downloader to grab what was found
        Write-Host "[$((Get-Date).ToString('MM/dd/yyyy HH:mm:ss'))] Triggering Auto-Downloader..." -ForegroundColor Green
        & (Join-Path $PSScriptRoot "Start-Downloader.ps1") -RunAuto
        
        $NextAuto = (Get-Date).AddHours($AutoH)
        Write-Host "`nNext Auto-Crawler run at: $($NextAuto.ToString('MM/dd/yyyy HH:mm:ss'))`n" -ForegroundColor DarkGray
    }

    if ($Now -ge $NextBoard) {
        Write-Host "[$($Now.ToString('MM/dd/yyyy HH:mm:ss'))] Triggering Board Series Scanner..." -ForegroundColor Green
        & (Join-Path $PSScriptRoot "Search-Scanner.ps1") -RunBoardCrawler
        $NextBoard = (Get-Date).AddHours($BoardH)
        Write-Host "`nNext Board Scanner run at: $($NextBoard.ToString('MM/dd/yyyy HH:mm:ss'))`n" -ForegroundColor DarkGray
    }

    Start-Sleep -Seconds 10
}