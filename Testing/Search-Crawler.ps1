# Search-Crawler.ps1
# Three modes: Native DCinside Search, Google CSE Search, Series Browser
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Shared Config ---
. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config   = Get-Config
$ListFile = Join-Path $PSScriptRoot "download_list.txt"
$CsvFile  = Join-Path $PSScriptRoot "series_catalog.csv"

# --- Settings from Config ---
$BaseId      = "comic_new6"
$MaxPages    = if ($Config.MaxPages) { [int]$Config.MaxPages } else { 10 }
$DoDNSRepair = $Config.DNSAutoRepair -eq "True"
$CseApiKey   = $Config.GoogleCseApiKey
$CseCxId     = $Config.GoogleCseCxId

# --- Constants ---
$PageTimeoutSec   = 15
$MaxPageRetries   = 2
$DNSWaitSec       = 10
$SearchRetryWait  = 3
$MaxSearchBlocks  = 300
$MaxPagesPerBlock = 10

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer"    = "https://gall.dcinside.com/"
}

# ===========================================================================
# JSON LOGGING
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
        $Existing = Get-Content $ListFile -Encoding UTF8
    } else {
        $Existing = @("# Last crawled: never", "", "[manual_urls]", "", "[automatic_urls]")
    }

    # Collect all URLs already in the file
    $KnownUrls = @($Existing | Where-Object { $_ -match '^http' } | ForEach-Object { $_.Trim() })

    $NewUrls = $Urls | Where-Object { $_ -notin $KnownUrls }
    if ($NewUrls.Count -eq 0) {
        Write-Host "  All URLs already in list — nothing added." -ForegroundColor Gray
        return
    }

    # Insert new URLs after [manual_urls] header
    $Out = [System.Collections.Generic.List[string]]::new()
    $Inserted = $false
    foreach ($Line in $Existing) {
        $Out.Add($Line)
        if (-not $Inserted -and $Line -match "^\[manual_urls\]") {
            foreach ($U in $NewUrls) { $Out.Add($U) }
            $Inserted = $true
        }
    }
    if (-not $Inserted) {
        $Out.Add("[manual_urls]")
        foreach ($U in $NewUrls) { $Out.Add($U) }
    }

    $Out | Set-Content $ListFile -Encoding UTF8
    Write-Host "  Added $($NewUrls.Count) URL(s) to [manual_urls]." -ForegroundColor Green
}

# ===========================================================================
# CSV HELPERS  (series_catalog.csv)
# Columns: SeriesTitle, ChapterTitle, URL, Status
# ===========================================================================

function Read-SeriesCsv {
    $Rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not (Test-Path $CsvFile)) { return $Rows }
    $Lines = Get-Content $CsvFile -Encoding UTF8
    foreach ($Line in $Lines | Select-Object -Skip 1) {   # skip header
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

    $AddedSeries = 0; $AddedChapters = 0
    foreach ($Title in $SeriesMap.Keys) {
        foreach ($Chapter in $SeriesMap[$Title]) {
            if ($Chapter.URL -notin $ExistingUrls) {
                $Existing.Add([PSCustomObject]@{
                    SeriesTitle  = $Title
                    ChapterTitle = $Chapter.Title
                    URL          = $Chapter.URL
                    Status       = "Pending"
                })
                $AddedChapters++
            }
        }
        $AddedSeries++
    }

    if ($AddedChapters -gt 0) {
        Write-SeriesCsv $Existing
        Write-Host "  CSV updated: $AddedChapters new chapter(s) across $AddedSeries series." -ForegroundColor Green
    } else {
        Write-Host "  No new entries — CSV already up to date." -ForegroundColor Gray
    }
    return $AddedChapters
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

# Extract all dc_series blocks from a post's HTML
function Get-SeriesFromHtml([string]$Html) {
    $SeriesMap = @{}
    $Blocks = [regex]::Matches($Html, '(?s)<div\s+class="dc_series"[^>]*>(.+?)</div>\s*(?=<div|$)')
    Write-CrawlerLog "INFO" "SeriesScan" "Regex scan complete" @{ blocks_found = $Blocks.Count }
    foreach ($Block in $Blocks) {
        $BlockHtml = $Block.Groups[1].Value

        # Extract series title from the bold div
        $SeriesTitle = "Unknown Series"
        if ($BlockHtml -match '<div[^>]*font-weight:bold[^>]*>\s*\[시리즈\]\s*(.*?)\s*</div>') {
            $SeriesTitle = $Matches[1].Trim()
        }

        # Extract all chapter links
        $ChapterLinks = [regex]::Matches($BlockHtml, '<a class="lnk"[^>]*href="([^"]+)"[^>]*>\s*·\s*(.*?)\s*</a>')
        $Chapters = @()
        foreach ($L in $ChapterLinks) {
            $ChUrl   = Clean-DcUrl ($L.Groups[1].Value)
            $ChTitle = ($L.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Trim()
            $Chapters += [PSCustomObject]@{ Title = $ChTitle; URL = $ChUrl }
        }

        Write-CrawlerLog "DEBUG" "SeriesScan" "Block parsed" @{ title = $SeriesTitle; chapters = $Chapters.Count }
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
    $Encoded  = [uri]::EscapeDataString($Keyword)
    $Found    = @()
    $SearchPos = ""

    Write-Host "`nSearching DCInside natively for: $Keyword" -ForegroundColor Cyan

    for ($Block = 1; $Block -le $MaxSearchBlocks; $Block++) {
        Write-Host "  Block $Block/$MaxSearchBlocks..." -ForegroundColor Yellow
        $BlockHasNext = $false
        $NextPos      = ""

        for ($Page = 1; $Page -le $MaxPagesPerBlock; $Page++) {
            $Url = "https://gall.dcinside.com/board/lists/?id=$BaseId&page=$Page&s_type=search_subject&s_keyword=$Encoded"
            if ($SearchPos) { $Url += "&search_pos=$SearchPos" }

            $Html = Get-PageHtml $Url
            if ($null -eq $Html) { continue }

            $Pattern     = '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>'
            $MatchesList = [regex]::Matches($Html, $Pattern)

            foreach ($M in $MatchesList) {
                $Title = ($M.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if (($Title -match '번역\)|\[번역\]') -and ($Title -notmatch '모음|추천|번역추|요청|질문|념글')) {
                    $CleanUrl = Clean-DcUrl $M.Groups[1].Value
                    if ($null -eq ($Found | Where-Object { $_.Url -eq $CleanUrl })) {
                        $Found += [PSCustomObject]@{ Title = $Title; Url = $CleanUrl }
                    }
                }
            }

            if ($Html -match 'search_pos=(-\d+)[^>]*>(?:<[^>]+>)*다음 검색') {
                $NextPos = $Matches[1]; $BlockHasNext = $true
            }

            $NextPage = $Page + 1
            if ($Html -notmatch "page=$NextPage") { break }
        }

        if ($BlockHasNext -and $NextPos -ne $SearchPos) { $SearchPos = $NextPos }
        else { Write-Host "  Reached end of DCInside search history." -ForegroundColor Cyan; break }
    }
    return $Found
}

# ===========================================================================
# MODE 2: GOOGLE CSE SEARCH
# ===========================================================================

function Start-GoogleSearch([string]$Keyword) {
    if (-not $CseApiKey -or -not $CseCxId) {
        Write-Host "  [WARN] No Google CSE credentials in config. Falling back to native search." -ForegroundColor Yellow
        return Start-NativeSearch $Keyword
    }

    $Encoded = [uri]::EscapeDataString("번역 $Keyword site:gall.dcinside.com/board/view")
    $Found   = @()
    $Start   = 1

    Write-Host "`nSearching via Google CSE for: $Keyword" -ForegroundColor Cyan

    # Google CSE returns max 10 results per call, up to index 91 (10 pages)
    while ($Start -le 91) {
        $ApiUrl = "https://www.googleapis.com/customsearch/v1?key=$CseApiKey&cx=$CseCxId&q=$Encoded&start=$Start&num=10"
        try {
            $Resp = Invoke-WebRequest -Uri $ApiUrl -UseBasicParsing -TimeoutSec 15
            $Json = $Resp.Content | ConvertFrom-Json
        } catch {
            Write-Host "  ! Google CSE request failed: $($_.Exception.Message)" -ForegroundColor Red
            break
        }

        if (-not $Json.items -or $Json.items.Count -eq 0) { break }

        foreach ($Item in $Json.items) {
            $Title = $Item.title -replace ' - 만화 갤러리.*$', '' -replace ' \| DC.*$', ''
            $Url   = Clean-DcUrl $Item.link
            if ($Url -match '/board/view' -and $null -eq ($Found | Where-Object { $_.Url -eq $Url })) {
                $Found += [PSCustomObject]@{ Title = $Title; Url = $Url }
            }
        }

        Write-Host "  Retrieved results $Start – $($Start + $Json.items.Count - 1) (Total reported: $($Json.searchInformation.totalResults))" -ForegroundColor Gray
        $Start += 10

        # Stop if Google reports fewer results than we asked for (last page)
        if ($Json.items.Count -lt 10) { break }
    }

    Write-Host "  Google CSE returned $($Found.Count) unique post(s)." -ForegroundColor Cyan
    return $Found
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
            if ($PostHtml -notmatch 'class="dc_series"') { continue }
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
        return
        Close-CrawlerLog
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
            Write-Host "        · $($Ch.Title)" -ForegroundColor Gray
        }
    }

    # Save everything to CSV
    Write-Host ""
    $Added = Merge-SeriesIntoCsv $AllSeries
    Write-Host "  Catalog saved to: series_catalog.csv" -ForegroundColor Cyan

    # Let user pick series to queue
    Write-Host ""
    Write-Host "Enter series number(s) to add to download list (e.g. 1,3,5 or 'all' or ENTER to skip):" -ForegroundColor Yellow
    $Input = Read-Host "Selection"

    if ([string]::IsNullOrWhiteSpace($Input)) { return }

    $ToQueue = @()
    if ($Input.Trim().ToLower() -eq "all") {
        foreach ($Title in $SeriesList) { $ToQueue += $AllSeries[$Title] | ForEach-Object { $_.URL } }
    } else {
        $Picks = $Input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
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
}

# ===========================================================================
# SHARED RESULT HANDLER (for search modes)
# ===========================================================================

function Show-SearchResults([array]$Results, [string]$Keyword) {
    if ($Results.Count -eq 0) {
        Write-Host "`nNo results found for: $Keyword" -ForegroundColor Red
        return
    }

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "  RESULTS FOR: $Keyword ($($Results.Count) found)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Results.Count; $i++) {
        Write-Host "  [$($i+1)] $($Results[$i].Title)" -ForegroundColor White
        Write-Host "        $($Results[$i].Url)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "Enter number(s) to queue (e.g. 1,3,5), 'all', or ENTER to skip:" -ForegroundColor Yellow
    $Input = Read-Host "Selection"
    if ([string]::IsNullOrWhiteSpace($Input)) { return }

    $ToQueue = @()
    if ($Input.Trim().ToLower() -eq "all") {
        $ToQueue = $Results | ForEach-Object { $_.Url }
    } else {
        $Picks = $Input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($Pick in $Picks) {
            $Idx = [int]$Pick - 1
            if ($Idx -ge 0 -and $Idx -lt $Results.Count) {
                $ToQueue += $Results[$Idx].Url
                Write-Host "  Queued: $($Results[$Idx].Title)" -ForegroundColor Green
            }
        }
    }

    if ($ToQueue.Count -gt 0) { Add-ToManualList $ToQueue }
}

# ===========================================================================
# MAIN MENU
# ===========================================================================

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   DC Manga Search & Series Crawler" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$GoogleAvailable = ($CseApiKey -and $CseCxId)
Write-Host "  1. Native DCInside keyword search"
if ($GoogleAvailable) {
    Write-Host "  2. Google CSE keyword search  [API key configured]" -ForegroundColor Green
} else {
    Write-Host "  2. Google CSE keyword search  [no API key — will fallback to native]" -ForegroundColor DarkGray
}
Write-Host "  3. Series browser (scan board for [시리즈] blocks)"
Write-Host "  4. Exit"
Write-Host "==========================================" -ForegroundColor Cyan

$Choice = Read-Host "Select option (1-4)"

switch ($Choice) {
    "1" {
        $Keyword = Read-Host "Enter manga title / keyword"
        if ([string]::IsNullOrWhiteSpace($Keyword)) { exit }
        $Results = Start-NativeSearch $Keyword
        Show-SearchResults $Results $Keyword
    }
    "2" {
        $Keyword = Read-Host "Enter manga title / keyword"
        if ([string]::IsNullOrWhiteSpace($Keyword)) { exit }
        $Results = Start-GoogleSearch $Keyword
        Show-SearchResults $Results $Keyword
    }
    "3" {
        Start-SeriesBrowser
    }
    default { exit }
}

Close-CrawlerLog
Write-Host "`nPress any key to exit..."
$null = [Console]::ReadKey($true)
