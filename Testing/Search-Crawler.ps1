# Search-Crawler.ps1
# Three modes: Native DCinside Search, Google CSE Search, Series Browser
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Shared Config ---
. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config   = Get-Config
$ListFile = Join-Path $PSScriptRoot "download_list.txt"
$CsvFile  = Join-Path $PSScriptRoot "series_catalog.csv"

# --- Settings from Config ---
$BaseId = "comic_new6"
$MaxPages = if ($Config.MaxPages) { [int]$Config.MaxPages } else { 10 }
$DoDNSRepair = $Config.DNSAutoRepair -eq "True"
$CseApiKey = $Config.GoogleCseApiKey
$CseCxId   = $Config.GoogleCseCxId

# --- Constants ---
$PageTimeoutSec  = 15
$MaxPageRetries  = 2
$DNSWaitSec      = 10
$SearchRetryWait = 3
$MaxSearchBlocks = 300
$MaxPagesPerBlock = 10

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer"    = "https://gall.dcinside.com/"
}

# ===========================================================================
# JSON LOGGING  (NEW)
# ===========================================================================
$CrawlerLogDir   = if ($Config.CrawlerLogDir)   { $Config.CrawlerLogDir }   else { ".\logs" }
$CrawlerLogLevel = if ($Config.CrawlerLogLevel) { $Config.CrawlerLogLevel } else { "Verbose" }

if (-not (Test-Path $CrawlerLogDir)) {
    New-Item -ItemType Directory -Path $CrawlerLogDir -Force | Out-Null
}

$LogTimestamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
$CrawlerLogFile = Join-Path $CrawlerLogDir "crawler_$LogTimestamp.json"

$script:CrawlerLog = [ordered]@{
    run_start = (Get-Date).ToString("o")
    log_level = $CrawlerLogLevel
    mode      = ""
    events    = [System.Collections.Generic.List[object]]::new()
}

function Write-CrawlerLog {
    param(
        [string]$Level,
        [string]$Category,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    if ($CrawlerLogLevel -eq "Error" -and $Level -notin @("ERROR","WARN")) { return }
    $Entry = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        level     = $Level
        category  = $Category
        message   = $Message
    }
    if ($Data.Count -gt 0) { $Entry["data"] = $Data }
    $script:CrawlerLog.events.Add($Entry)
}

function Close-CrawlerLog {
    $script:CrawlerLog["run_end"] = (Get-Date).ToString("o")
    $script:CrawlerLog | ConvertTo-Json -Depth 5 |
        Set-Content $CrawlerLogFile -Encoding UTF8
}

# ===========================================================================
# SHARED HELPERS
# ===========================================================================

function Get-PageHtml([string]$Url) {
    $Retries = 0
    while ($Retries -le $MaxPageRetries) {
        try {
            $Resp = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec $PageTimeoutSec
            Write-CrawlerLog "INFO" "PageFetch" "Fetched page" @{ url = $Url; length = $Resp.Content.Length }
            return $Resp.Content
        } catch {
            Write-CrawlerLog "ERROR" "PageFetch" "Fetch failed" @{ url = $Url; error = $_.Exception.Message; retry = $Retries }
            if ($DoDNSRepair -and ($_.Exception.Message -match "resolved|host")) {
                Write-Host "  ! DNS Error. Flushing..." -ForegroundColor Yellow
                ipconfig /flushdns | Out-Null
                Start-Sleep -Seconds $DNSWaitSec
            } else {
                Start-Sleep -Seconds $SearchRetryWait
            }
            $Retries++
        }
    }
    return $null
}

# Clean a DCinside URL — strip search/pagination params, normalize view path
function Clean-DcUrl([string]$Raw) {
    $Url = $Raw -replace '&amp;', '&'
    if ($Url -match '^http') { $Full = $Url } else { $Full = "https://gall.dcinside.com" + $Url }
    $Full = $Full -replace '&page=[^&]*', '' `
                  -replace '&s_type=[^&]*', '' `
                  -replace '&s_keyword=[^&]*', '' `
                  -replace '&search_pos=[^&]*', '' `
                  -replace '&exception_mode=[^&]*', ''
    # Normalize /view? -> /view/?
    $Full = $Full -replace '/view\?id=', '/view/?id='
    return $Full
}

# Add URLs to the [manual_urls] section of download_list.txt (deduped)
function Add-ToManualList([string[]]$Urls) {
    if ($Urls.Count -eq 0) { return }
    $Existing = @()
    if (Test-Path $ListFile) {
        $Existing = Get-Content $ListFile -Encoding UTF8 | Where-Object { $_.Trim() -ne "" }
    }
    $New = $Urls | Where-Object { $_ -notin $Existing }
    if ($New.Count -gt 0) {
        Add-Content $ListFile ($New -join "`n") -Encoding UTF8
        Write-Host "  Added $($New.Count) new URL(s) to download_list.txt" -ForegroundColor Green
    } else {
        Write-Host "  All URLs already in download_list.txt" -ForegroundColor Yellow
    }
}

# ===========================================================================
# CSV HELPERS (series_catalog.csv)
# Columns: SeriesTitle, ChapterTitle, URL, Status
# ===========================================================================

function Read-SeriesCsv {
    $Rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not (Test-Path $CsvFile)) { return $Rows }
    $Lines = Get-Content $CsvFile -Encoding UTF8
    foreach ($Line in $Lines | Select-Object -Skip 1) { # skip header
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        # Simple CSV split — handles quoted fields with commas inside
        $Parts = [regex]::Matches($Line, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
        if ($Parts.Count -eq 4) {
            $Rows.Add([PSCustomObject]@{
                SeriesTitle  = $Parts[0]
                ChapterTitle = $Parts[1]
                URL          = $Parts[2]
                Status       = $Parts[3]
            })
        }
    }
    return $Rows
}

function Write-SeriesCsv([System.Collections.Generic.List[PSCustomObject]]$Rows) {
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('"SeriesTitle","ChapterTitle","URL","Status"')
    foreach ($R in $Rows) {
        $Lines.Add("""$($R.SeriesTitle)"",""$($R.ChapterTitle)"",""$($R.URL)"",""$($R.Status)""")
    }
    $Lines | Set-Content $CsvFile -Encoding UTF8
}

# Merge newly found series into the CSV — never overwrites existing rows
function Merge-SeriesIntoCsv([hashtable]$SeriesMap) {
    $Existing = Read-SeriesCsv
    $ExistingUrls = @($Existing | ForEach-Object { $_.URL })
    $Added = 0
    foreach ($Title in $SeriesMap.Keys) {
        foreach ($Ch in $SeriesMap[$Title]) {
            if ($Ch.URL -notin $ExistingUrls) {
                $Existing.Add([PSCustomObject]@{
                    SeriesTitle  = $Title
                    ChapterTitle = $Ch.Title
                    URL          = $Ch.URL
                    Status       = "Pending"
                })
                $Added++
            }
        }
    }
    if ($Added -gt 0) { Write-SeriesCsv $Existing }
    return $Added
}

# Update Status for a URL in the CSV (called by downloader integration)
function Update-SeriesCsvStatus([string]$Url, [string]$NewStatus) {
    if (-not (Test-Path $CsvFile)) { return }
    $Rows = Read-SeriesCsv
    $Changed = $false
    foreach ($R in $Rows) {
        if ($R.URL -eq $Url) { $R.Status = $NewStatus; $Changed = $true }
    }
    if ($Changed) { Write-SeriesCsv $Rows }
}

# ===========================================================================
# SERIES EXTRACTION  (FIXED)
# ===========================================================================

# Extract all dc_series blocks from a post's HTML
function Get-SeriesFromHtml([string]$Html) {
    $SeriesMap = @{}

    # FIXED: old regex stopped at the first inner </div>, cutting off <a> links
    # New regex captures the entire dc_series block including nested divs
    $Blocks = [regex]::Matches($Html, '(?s)<div\s+class="dc_series"[^>]*>(.+?)</div>\s*(?=<div|$)')

    Write-CrawlerLog "INFO" "SeriesScan" "Regex scan complete" @{ blocks_found = $Blocks.Count }

    foreach ($Block in $Blocks) {
        $BlockHtml = $Block.Groups[1].Value

        # Extract series title from the bold div
        $SeriesTitle = "Unknown Series"
        if ($BlockHtml -match '<div[^>]*font-weight\s*:\s*bold[^>]*>\s*\[시리즈\]\s*(.*?)\s*</div>') {
            $SeriesTitle = $Matches[1].Trim()
        }

        # Extract all chapter links
        $ChapterLinks = [regex]::Matches($BlockHtml, '<a\s+class="lnk"[^>]*href="([^"]+)"[^>]*>\s*·\s*(.*?)\s*</a>')
        $Chapters = @()
        foreach ($L in $ChapterLinks) {
            $ChUrl   = Clean-DcUrl ($L.Groups[1].Value)
            $ChTitle = ($L.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Trim()
            $Chapters += [PSCustomObject]@{ Title = $ChTitle; URL = $ChUrl }
        }

        Write-CrawlerLog "DEBUG" "SeriesScan" "Block parsed" @{
            title    = $SeriesTitle
            chapters = $Chapters.Count
        }

        if ($Chapters.Count -gt 0 -and $SeriesTitle -ne "Unknown Series") {
            $SeriesMap[$SeriesTitle] = $Chapters
        }
    }
    return $SeriesMap
}

# ===========================================================================
# MODE 1: NATIVE DCINSIDE SEARCH
# ===========================================================================

function Start-NativeSearch([string]$Keyword) {
    $Encoded = [uri]::EscapeDataString($Keyword)
    $Found = @()
    $SearchPos = ""

    for ($Block = 0; $Block -lt $MaxSearchBlocks; $Block++) {
        $SearchUrl = "https://search.dcinside.com/post/p/1/sort/accuracy/q/$Encoded"
        if ($SearchPos) { $SearchUrl += "&search_pos=$SearchPos" }

        Write-Host "  Searching block $($Block+1)..." -ForegroundColor Yellow
        $Html = Get-PageHtml $SearchUrl
        if ($null -eq $Html) { break }

        $Links = [regex]::Matches($Html, 'href="(https://gall\.dcinside\.com/board/view/[^"]+)"') |
                 ForEach-Object { Clean-DcUrl $_.Groups[1].Value } |
                 Where-Object { $_ -match "id=$BaseId" } |
                 Select-Object -Unique

        $Found += $Links

        if ($Html -match 'search_pos=(-?\d+)') {
            $SearchPos = $Matches[1]
        } else {
            break
        }

        if ($Links.Count -eq 0) { break }
        Start-Sleep -Seconds $SearchRetryWait
    }

    return ($Found | Select-Object -Unique)
}

# ===========================================================================
# MODE 2: GOOGLE CSE SEARCH
# ===========================================================================

function Start-GoogleSearch([string]$Keyword) {
    if (-not $CseApiKey -or -not $CseCxId) {
        Write-Host "  [WARN] No Google CSE credentials in config. Falling back to native search." -ForegroundColor Yellow
        return Start-NativeSearch $Keyword
    }

    $Found = @()
    $Start = 1

    for ($Block = 0; $Block -lt 10; $Block++) {
        $Encoded = [uri]::EscapeDataString($Keyword)
        $ApiUrl = "https://www.googleapis.com/customsearch/v1?key=$CseApiKey&cx=$CseCxId&q=$Encoded&start=$Start"

        Write-Host "  Google CSE block $($Block+1)..." -ForegroundColor Yellow

        try {
            $Resp = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 15
        } catch {
            Write-Host "  [ERROR] Google API: $($_.Exception.Message)" -ForegroundColor Red
            break
        }

        if (-not $Resp.items) { break }

        foreach ($Item in $Resp.items) {
            $Link = Clean-DcUrl $Item.link
            if ($Link -match "id=$BaseId") {
                $Found += $Link
            }
        }

        $Start += 10
        if ($Resp.queries.nextPage -eq $null) { break }
        Start-Sleep -Seconds $SearchRetryWait
    }

    return ($Found | Select-Object -Unique)
}

# ===========================================================================
# MODE 3: SERIES BROWSER
# ===========================================================================

function Start-SeriesBrowser {
    Write-Host "`nScanning $MaxPages page(s) of the board for series blocks..." -ForegroundColor Cyan
    $script:CrawlerLog.mode = "SeriesBrowser"
    Write-CrawlerLog "INFO" "SeriesBrowser" "Starting board scan" @{ pages = $MaxPages; board = $Config.BoardUrl }

    $BoardUrl  = $Config.BoardUrl
    $AllSeries = @{}   # SeriesTitle -> [chapters]

    for ($Page = 1; $Page -le $MaxPages; $Page++) {
        Write-Host "  Scanning page $Page/$MaxPages..." -ForegroundColor Yellow
        $Html = Get-PageHtml "$BoardUrl&page=$Page"
        if ($null -eq $Html) { Write-Host "  ! Page $Page failed. Skipping." -ForegroundColor Red; continue }

        Write-CrawlerLog "DEBUG" "SeriesBrowser" "Board page fetched" @{ page = $Page }

        # Collect post links from the listing page
        $PostLinks = [regex]::Matches($Html, '/board/view/?\?id=[^"&]+&no=\d+') |
                     ForEach-Object { "https://gall.dcinside.com" + ($_.Value -replace '&amp;','&') } |
                     Select-Object -Unique

        Write-CrawlerLog "DEBUG" "SeriesBrowser" "Post links found" @{ page = $Page; count = @($PostLinks).Count }

        foreach ($PostUrl in $PostLinks) {
            $PostHtml = Get-PageHtml $PostUrl
            if ($null -eq $PostHtml) { continue }
            if ($PostHtml -notmatch 'class="dc_series"') {
                Write-CrawlerLog "DEBUG" "SeriesScan" "No dc_series" @{ url = $PostUrl }
                continue
            }

            Write-CrawlerLog "DEBUG" "SeriesScan" "Post has dc_series" @{ url = $PostUrl }

            $SeriesMap = Get-SeriesFromHtml $PostHtml

            Write-CrawlerLog "INFO" "SeriesScan" "Extraction result" @{ url = $PostUrl; series_count = $SeriesMap.Count }

            foreach ($Key in $SeriesMap.Keys) {
                if (-not $AllSeries.ContainsKey($Key)) {
                    $AllSeries[$Key] = $SeriesMap[$Key]
                    Write-Host "    [SERIES] Found: $Key ($($SeriesMap[$Key].Count) chapters)" -ForegroundColor Green
                }
            }
        }
    }

    if ($AllSeries.Count -eq 0) {
        Write-Host "`nNo series blocks found in the scanned pages." -ForegroundColor Red
        Close-CrawlerLog
        return
    }

    # Display the nested tree
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "  SERIES FOUND ($($AllSeries.Count) total)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $SeriesList = @($AllSeries.Keys | Sort-Object)
    for ($i = 0; $i -lt $SeriesList.Count; $i++) {
        $Title    = $SeriesList[$i]
        $Chapters = $AllSeries[$Title]
        Write-Host ""
        Write-Host "  [$($i+1)] $Title ($($Chapters.Count) chapters)" -ForegroundColor White
        foreach ($Ch in $Chapters) {
            Write-Host "        $([char]0x00B7) $($Ch.Title)" -ForegroundColor Gray
        }
    }

    # Save everything to CSV
    Write-Host ""
    $Added = Merge-SeriesIntoCsv $AllSeries
    Write-Host "  Catalog saved to: series_catalog.csv ($Added new entries)" -ForegroundColor Cyan

    # Let user pick series to queue
    Write-Host ""
    Write-Host "Enter series number(s) to add to download list (e.g. 1,3,5 or 'all' or ENTER to skip):" -ForegroundColor Yellow
    $UserInput = Read-Host "Selection"

    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        Close-CrawlerLog
        return
    }

    $ToQueue = @()
    if ($UserInput.Trim().ToLower() -eq "all") {
        foreach ($Title in $SeriesList) { $ToQueue += $AllSeries[$Title] | ForEach-Object { $_.URL } }
    } else {
        $Picks = $UserInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($Pick in $Picks) {
            $Idx = [int]$Pick - 1
            if ($Idx -ge 0 -and $Idx -lt $SeriesList.Count) {
                $Title    = $SeriesList[$Idx]
                $ToQueue += $AllSeries[$Title] | ForEach-Object { $_.URL }
                Write-Host "  Queued: $Title" -ForegroundColor Green
            }
        }
    }

    if ($ToQueue.Count -gt 0) {
        Add-ToManualList $ToQueue
    }

    Close-CrawlerLog
}

# ===========================================================================
# SHARED RESULT HANDLER (for search modes)
# ===========================================================================

function Show-SearchResults([array]$Results, [string]$Keyword) {
    if ($Results.Count -eq 0) {
        Write-Host "`nNo results found for: $Keyword" -ForegroundColor Red
        return
    }

    Write-Host "`nFound $($Results.Count) post(s) for: $Keyword" -ForegroundColor Green
    for ($i = 0; $i -lt $Results.Count; $i++) {
        Write-Host "  [$($i+1)] $($Results[$i])"
    }

    Write-Host ""
    Write-Host "Enter number(s) to add to download list (e.g. 1,3,5 or 'all' or ENTER to skip):" -ForegroundColor Yellow
    $UserInput = Read-Host "Selection"

    if ([string]::IsNullOrWhiteSpace($UserInput)) { return }

    $ToQueue = @()
    if ($UserInput.Trim().ToLower() -eq "all") {
        $ToQueue = $Results
    } else {
        $Picks = $UserInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($Pick in $Picks) {
            $Idx = [int]$Pick - 1
            if ($Idx -ge 0 -and $Idx -lt $Results.Count) {
                $ToQueue += $Results[$Idx]
            }
        }
    }

    if ($ToQueue.Count -gt 0) {
        Add-ToManualList $ToQueue
    }
}

# ===========================================================================
# MAIN MENU
# ===========================================================================

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  DC Manga Search & Series Crawler" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$GoogleAvailable = ($CseApiKey -and $CseCxId)
Write-Host " 1. Native DCInside keyword search"
if ($GoogleAvailable) {
    Write-Host " 2. Google CSE keyword search [API key configured]" -ForegroundColor Green
} else {
    Write-Host " 2. Google CSE keyword search [no API key - will fallback to native]" -ForegroundColor DarkGray
}
Write-Host " 3. Series browser (scan board for series blocks)"
Write-Host " 4. Exit"
Write-Host "==========================================" -ForegroundColor Cyan

$Choice = Read-Host "Select option (1-4)"

switch ($Choice) {
    "1" {
        $Keyword = Read-Host "Enter manga title / keyword"
        if ([string]::IsNullOrWhiteSpace($Keyword)) { break }
        $Results = Start-NativeSearch $Keyword
        Show-SearchResults $Results $Keyword
    }
    "2" {
        $Keyword = Read-Host "Enter manga title / keyword"
        if ([string]::IsNullOrWhiteSpace($Keyword)) { break }
        $Results = Start-GoogleSearch $Keyword
        Show-SearchResults $Results $Keyword
    }
    "3" { Start-SeriesBrowser }
    default { exit }
}

Write-Host "`nPress any key to exit..."
$null = [Console]::ReadKey($true)
