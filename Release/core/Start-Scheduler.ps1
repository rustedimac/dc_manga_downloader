# ==========================================
# DC Manga Background Scheduler
# ==========================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "Get-Config.ps1")

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   DC Manga Background Scheduler Active   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Leave this window open. The suite will silently monitor the board." -ForegroundColor Gray
Write-Host "You can edit config.yaml while this is running to change intervals dynamically.`n" -ForegroundColor DarkGray

$NextAutoRun = Get-Date
$NextBoardRun = Get-Date

while ($true) {

    $Config = Get-Config -ConfigPath (Join-Path $RootDir "config.yaml")
    
    $AutoInterval = if ($null -ne $Config.AutoCrawlerIntervalHours) { [double]$Config.AutoCrawlerIntervalHours } else { 1 }
    $BoardInterval = if ($null -ne $Config.BoardCrawlerIntervalHours) { [double]$Config.BoardCrawlerIntervalHours } else { 12 }

    $CurrentTime = Get-Date

    # ---------------------------------------------------------
    # 1. Auto-Crawler
    # ---------------------------------------------------------
    if ($AutoInterval -le 0) {
        $NextAutoRun = $CurrentTime.AddHours(1)
    } elseif ($CurrentTime -ge $NextAutoRun) {
        Write-Host "[$($CurrentTime.ToString('HH:mm:ss'))] Starting Auto-Crawler..." -ForegroundColor Yellow
        
        $CrawlerScript = Join-Path $PSScriptRoot "Run-Crawler.ps1"
        if (Test-Path $CrawlerScript) { & $CrawlerScript }
        
        $NextAutoRun = (Get-Date).AddHours($AutoInterval)
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] Auto-Crawler finished. Next run at $($NextAutoRun.ToString('HH:mm:ss'))" -ForegroundColor Green
    }

    # ---------------------------------------------------------
    # 2. Board Series Scanner
    # ---------------------------------------------------------
    if ($BoardInterval -le 0) {

        $NextBoardRun = $CurrentTime.AddHours(1)
    } elseif ($CurrentTime -ge $NextBoardRun) {
        Write-Host "[$($CurrentTime.ToString('HH:mm:ss'))] Starting Board Series Scanner..." -ForegroundColor Yellow
        
        $ScannerScript = Join-Path $PSScriptRoot "Search-Scanner.ps1"
        if (Test-Path $ScannerScript) { & $ScannerScript -RunBoardCrawler }
        
        $NextBoardRun = (Get-Date).AddHours($BoardInterval)
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] Board Scanner finished. Next run at $($NextBoardRun.ToString('HH:mm:ss'))" -ForegroundColor Green
    }
    Start-Sleep -Seconds 60
}
