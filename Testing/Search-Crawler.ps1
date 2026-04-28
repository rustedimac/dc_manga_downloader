# Search-Crawler.ps1
# Native Search / Google CSE / Series Browser

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Shared Config ---
. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config   = Get-Config
$ListFile = Join-Path $PSScriptRoot "download_list.txt"
$CsvFile  = Join-Path $PSScriptRoot "series_catalog.csv"

$BaseId = "comic_new6"
$MaxPages = [int]$Config.MaxPages
$DoDNSRepair = $Config.DNSAutoRepair -eq "True"

# --- Constants ---
$PageTimeoutSec = 15
$MaxPageRetries = 2
$DNSWaitSec = 10
$SearchRetryWait = 3

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    "Referer"    = "https://gall.dcinside.com/"
}

# ===========================================================================
# JSON LOGGING
# ===========================================================================

$CrawlerLogDir   = $Config.CrawlerLogDir
$CrawlerLogLevel = $Config.CrawlerLogLevel

if (-not (Test-Path $CrawlerLogDir)) {
    New-Item -ItemType Directory -Path $CrawlerLogDir -Force | Out-Null
}

$LogTimestamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$CrawlerLogFile = Join-Path $CrawlerLogDir "crawler_$LogTimestamp.json"

$script:CrawlerLog = [ordered]@{
    run_start = (Get-Date).ToString("o")
    log_level = $CrawlerLogLevel
    events    = @()
}

function Write-CrawlerLog {
    param($Level,$Category,$Message,$Data=@{})
    if ($CrawlerLogLevel -eq "Error" -and $Level -notin @("ERROR","WARN")) { return }
    $Entry = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        level     = $Level
        category  = $Category
        message   = $Message
        data      = $Data
    }
    $script:CrawlerLog.events += $Entry
}

function Close-CrawlerLog {
    $script:CrawlerLog["run_end"] = (Get-Date).ToString("o")
    $script:CrawlerLog | ConvertTo-Json -Depth 6 |
        Set-Content $CrawlerLogFile -Encoding UTF8
}

# ===========================================================================
# HELPERS
# ===========================================================================

function Get-PageHtml([string]$Url) {
    $Retries = 0
    while ($Retries -le $MaxPageRetries) {
        try {
            $Resp = Invoke-WebRequest -Uri $Url -Headers $Headers -TimeoutSec $PageTimeoutSec
            Write-CrawlerLog "INFO" "PageFetch" "Fetched page" @{
                url = $Url; length = $Resp.Content.Length
            }
            return $Resp.Content
        } catch {
            Write-CrawlerLog "ERROR" "PageFetch" "Fetch failed" @{
                url = $Url; error = $_.Exception.Message; retry = $Retries
            }
            if ($DoDNSRepair -and ($_.Exception.Message -match "resolved|host")) {
                ipconfig /flushdns | Out-Null
                Start-Sleep $DNSWaitSec
            } else {
                Start-Sleep $SearchRetryWait
            }
            $Retries++
        }
    }
    return $null
}

function Clean-DcUrl([string]$Raw) {
    $Url = $Raw -replace '&amp;', '&'
    if ($Url -notmatch '^http') {
        $Url = "https://gall.dcinside.com$Url"
    }
    $Url -replace '/view\?id=', '/view/?id='
}

# ===========================================================================
# SERIES EXTRACTION
# ===========================================================================

function Get-SeriesFromHtml([string]$Html) {
    $SeriesMap = @{}
    $Blocks = [regex]::Matches(
        $Html,
        '(?s)<div class="dc_series"[^>]*>(.*?)</div>\s*</div>'
    )

    Write-CrawlerLog "INFO" "SeriesScan" "Regex scan complete" @{
        blocks_found = $Blocks.Count
    }

    foreach ($B in $Blocks) {
        $BlockHtml = $B.Groups[1].Value
        if ($BlockHtml -match '\[시리즈\]\s*(.*?)</div>') {
            $Title = $Matches[1].Trim()
            $Links = [regex]::Matches(
                $BlockHtml,
                '<a class="lnk"[^>]*href="([^"]+)"[^>]*>.*?(.*?)</a>'
            )
            $Chapters = @()
            foreach ($L in $Links) {
                $Chapters += [PSCustomObject]@{
                    Title = $L.Groups[2].Value.Trim()
                    URL   = Clean-DcUrl $L.Groups[1].Value
                }
            }
            if ($Chapters.Count -gt 0) {
                $SeriesMap[$Title] = $Chapters
            }
        }
    }
    return $SeriesMap
}

# ===========================================================================
# SERIES BROWSER
# ===========================================================================

function Start-SeriesBrowser {
    Write-Host "`nScanning $MaxPages pages..." -ForegroundColor Cyan
    Write-CrawlerLog "INFO" "SeriesBrowser" "Start scan" @{
        pages = $MaxPages; board = $Config.BoardUrl
    }

    $AllSeries = @{}

    for ($Page=1; $Page -le $MaxPages; $Page++) {
        $Html = Get-PageHtml "$($Config.BoardUrl)&page=$Page"
        if (-not $Html) { continue }

        $PostLinks = [regex]::Matches(
            $Html,
            '/board/view/\?id=[^"&]+&no=\d+'
        ) | ForEach-Object {
            "https://gall.dcinside.com$($_.Value)"
        } | Select-Object -Unique

        Write-CrawlerLog "DEBUG" "SeriesBrowser" "Posts found" @{
            page=$Page; count=$PostLinks.Count
        }

        foreach ($PostUrl in $PostLinks) {
            $PostHtml = Get-PageHtml $PostUrl
            if (-not $PostHtml) { continue }

            $HasSeries = $PostHtml -match 'dc_series'
            Write-CrawlerLog "DEBUG" "SeriesScan" "Post inspected" @{
                url=$PostUrl; has_series=$HasSeries
            }

            if (-not $HasSeries) { continue }

            $Series = Get-SeriesFromHtml $PostHtml
            foreach ($K in $Series.Keys) {
                if (-not $AllSeries.ContainsKey($K)) {
                    $AllSeries[$K] = $Series[$K]
                    Write-Host "  [SERIES] $K" -ForegroundColor Green
                }
            }
        }
    }

    if ($AllSeries.Count -eq 0) {
        Write-Host "`nNo series found." -ForegroundColor Red
    }

    Close-CrawlerLog
    Write-Host "`nLog saved to $CrawlerLogFile" -ForegroundColor Cyan
}

# ===========================================================================
# MAIN
# ===========================================================================

Clear-Host
Write-Host "DC Manga Series Crawler" -ForegroundColor Cyan
Write-Host "1. Series Browser"
Write-Host "2. Exit"

switch (Read-Host "Select") {
    "1" { Start-SeriesBrowser }
    default { }
}

Write-Host "`nPress any key to exit..."
[Console]::ReadKey($true)
``
