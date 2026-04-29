# ==========================================
# DC Manga Search-Crawler
# ==========================================
param (
    [switch]$RunBoardCrawler
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptRoot = $PSScriptRoot
$Downloader = Join-Path $ScriptRoot "Start-Downloader.ps1"

# =========================
# Config Loader
# =========================
function Get-CrawlerConfig {
    $cfgPath = Join-Path $PSScriptRoot "config.yaml"
    if (-not (Test-Path $cfgPath)) { throw "config.yaml not found" }
    
    $ConfigObj = @{}
    Get-Content $cfgPath -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $ConfigObj[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
    return $ConfigObj
}
$Config = Get-CrawlerConfig

# =========================
# Path Resolution
# =========================
$CsvFile = if ($Config.CatalogCsvPath) { Join-Path $ScriptRoot ($Config.CatalogCsvPath -replace '^\.\\', '') } else { Join-Path $ScriptRoot "series_catalog.csv" }
$CsvDir = Split-Path $CsvFile
if (-not (Test-Path $CsvDir)) { New-Item -ItemType Directory -Path $CsvDir -Force | Out-Null }

$DsCsvFile = Join-Path $CsvDir "ds_results.csv"

$ListFile = if ($Config.DownloadListPath) { Join-Path $ScriptRoot ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $ScriptRoot "download_list.txt" }
$ListDir = Split-Path $ListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }

# Load File Lock Utility
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# =========================
# Dynamic Session Logging
# =========================
$LogRank = @{ Error=0; Warn=1; Info=2; Verbose=3; DEBUG=3 }

function Initialize-SessionLog($Mode) {
    $BaseLogDir = Join-Path $ScriptRoot ($Config.CrawlerLogDir -replace '^.\[\\/]', '')
    
    if ($Mode -eq "DeepSearch") {
        $dir = Join-Path $BaseLogDir "deep_search"
        $prefix = "ds_crawler_"
    } elseif ($Mode -eq "BoardSeries") {
        $dir = Join-Path $BaseLogDir "series_search"
        $prefix = "series_crawler_"
    } else {
        $dir = Join-Path $BaseLogDir "misc_search"
        $prefix = "misc_crawler_"
    }

    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    
    $script:SessionLogFile = Join-Path $dir ($prefix + (Get-Date -Format "yyyy-MM-dd_HHmmss") + ".json")
    $script:LogEntries = New-Object System.Collections.Generic.List[PSObject]
    $script:RunId = [guid]::NewGuid().ToString()
}

function Save-SessionLogs {
    if (-not $script:LogEntries) { return }
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { 
        $script:LogEntries | ConvertTo-Json -Depth 5 -EscapeHandling EscapeHtml
    } else { 
        $script:LogEntries | ConvertTo-Json -Depth 5
    }
    $CleanJson = $Json -replace '\\u0026', '&'
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $CleanJson | Set-Content -Path $script:SessionLogFile -Encoding $Enc
}

function Write-CrawlerLog {
    param($Level,$Component,$Event,$Data=@{})
    if ($null -eq $Config.CrawlerLogLevel) { $Config.CrawlerLogLevel = "Verbose" }
    if ($LogRank[$Level] -gt $LogRank[$Config.CrawlerLogLevel]) { return }

    $entry = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString("o")
        run_id    = $script:RunId
        level     = $Level
        component = $Component
        event     = $Event
    }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $script:LogEntries.Add($entry)
    Save-SessionLogs
}

function Write-Log {
    param($Level,$Component,$Message,$Data=@{})
    $Color = switch($Level) { "Error" {"Red"} "Warn" {"Yellow"} "Info" {"White"} default {"Gray"} }
    Write-Host "[$Level][$Component] $Message" -ForegroundColor $Color
    Write-CrawlerLog $Level $Component $Message $Data
}

# =========================
# Core Logic Functions
# =========================
function Parse-TitleToSeries([string]$RawTitle) {
    Write-Log "Verbose" "Parser" "Starting Title Parse" @{ input=$RawTitle }
    $CleanTitle = $RawTitle -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
    $CleanTitle = $CleanTitle -replace '^번역\)\s*', '' -replace '^\s*\[?번역\]?\s*', '' -replace '\s*\([^)]*\)$', ''
    $CleanTitle = $CleanTitle.Trim().Trim(".")
    
    $Manga = $CleanTitle; $Chapter = "General"
    if ($CleanTitle -match '^(.*?)\s+([\(<\[]?[\d\.\-~,&＆\s]+화?[\)>\]]?)$') {
        $Manga = $Matches[1].Trim(); $Chapter = $Matches[2].Trim()
    } elseif ($CleanTitle -match '^(.*?)([\d\.\-~,&＆]+화)$') {
        $Manga = $Matches[1].Trim(); $Chapter = $Matches[2].Trim()
    }
    Write-Log "Verbose" "Parser" "Parse Complete" @{ series=$Manga; chapter=$Chapter }
    return @{ Series = $Manga; Chapter = $Chapter }
}

function Extract-SeriesFromHtml {
    param([string]$Html, [string]$Url)
    Write-Log "Verbose" "Extractor" "Extracting [시리즈] block" @{ url=$Url }
    if ($Html -notmatch '\[시리즈\]') { return @{} }
    
    $parts = $Html -split '\[시리즈\]', 2
    if ($parts.Count -lt 2) { return @{} }
    $after = $parts[1]

    if ($after -match '(?s)^\s*(.*?)(?:<a|<br|·)') { $title = ($Matches[1] -replace '<[^>]+>', '').Trim() } else { $title = "UNKNOWN" }

    $chapterMatches = [regex]::Matches($after, '<a[^>]+href="([^"]+)"[^>]*>\s*·\s*([^<]+)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($chapterMatches.Count -eq 0) { return @{} }

    $chapters = @()
    foreach ($m in $chapterMatches) { $chapters += [PSCustomObject]@{ Series = ""; Chapter = $m.Groups[2].Value.Trim(); Url = $m.Groups[1].Value.Trim() } }

    if ($title -match '^[\.\s\-_]*$' -or $title -eq "UNKNOWN") {
        Write-Log "Verbose" "Extractor" "Junk title detected, attempting recovery"
        $repaired = Parse-TitleToSeries $chapters[0].Chapter
        $title = $repaired.Series
        Write-Log "Warn" "Extractor" "Repaired junk title [.] to [$title]" @{ url=$Url }
    }

    foreach ($c in $chapters) { $c.Series = $title }
    Write-Log "Verbose" "Extractor" "Extraction finished" @{ title=$title; count=$chapters.Count }
    return @{ $title = $chapters }
}
function Read-SeriesCsv {
    Write-Log "Verbose" "CSV" "Reading data from catalog"
    if (-not (Test-Path $CsvFile)) { return @() }
    Import-Csv $CsvFile
}

function Write-SeriesCsv($Rows) {
    Write-Log "Verbose" "CSV" "Writing data to catalog" @{ rowCount=$Rows.Count }
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $Rows | Export-Csv $CsvFile -NoTypeInformation -Encoding $Enc
}

function Write-SeriesCsv($Rows) {
    Write-Log "Verbose" "CSV" "Writing data to catalog" @{ rowCount=$Rows.Count }
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $Rows | Export-Csv $CsvFile -NoTypeInformation -Encoding $Enc
}

function Merge-SeriesCsv($SeriesMap) {
    Write-Log "Verbose" "CSV" "Merging series map into CSV"
    $existing = if (Test-Path $CsvFile) { Import-Csv $CsvFile } else { @() }
    $out = @($existing); $added = 0
    foreach ($t in $SeriesMap.Keys) {
        foreach ($c in $SeriesMap[$t]) {
            if (-not ($existing | Where-Object Url -eq $c.Url)) { 
                $out += $c; $added++
                Write-Log "Verbose" "CSV" "New chapter added" @{ series=$c.Series; chapter=$c.Chapter }
            }
        }
    }
    if ($added -gt 0) { Write-SeriesCsv $out }
    return $added
}

function Add-ToManualDownloadList($Urls) {
    Write-Log "Verbose" "Queue" "Updating manual_urls" @{ urlCount=$Urls.Count }
    
    Invoke-WithFileLock "DownloadList" {
        $lines = if (Test-Path $ListFile) { Get-Content $ListFile -Encoding UTF8 } else { @("[automatic_urls]", "", "[manual_urls]") }
        $out = New-Object System.Collections.Generic.List[string]
        $inManual=$false; $existing=@()
        
        foreach ($l in $lines) {
            if ($l -match '^\[manual_urls\]') { $inManual=$true }
            elseif ($l -match '^\[') { $inManual=$false }
            elseif ($inManual -and $l -match '^https?://') { $existing+=$l.Trim() }
            $out.Add($l)
        }
        
        $idx = $out.IndexOf('[manual_urls]')
        if ($idx -lt 0) { $out.Add("[manual_urls]"); $idx = $out.Count - 1 }
        $idx += 1
        
        foreach ($u in $Urls | Sort-Object -Unique) {
            if ($u -notin $existing) { $out.Insert($idx++,$u); Write-Log "Verbose" "Queue" "Added URL to queue" @{ url=$u } }
        }
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $out | Set-Content $ListFile -Encoding $Enc
    }
}

function Invoke-ManualDownloader {
    Write-Log "Info" "Handoff" "Invoking Start-Downloader.ps1"
    & $Downloader -RunManualQueue
}

# =========================
# Crawler Engines
# =========================
function Start-KeywordSearch {
    Initialize-SessionLog "DeepSearch"
    Clear-Host
    Write-Host "=== Keyword Deep-Search Crawler ===" -ForegroundColor Cyan
    $Keyword = Read-Host "Enter Manga Title/Keyword to search"
    if ([string]::IsNullOrWhiteSpace($Keyword)) { return }
    
    Write-Log "Verbose" "Crawler" "Keyword search initiated" @{ keyword=$Keyword }
    $EncodedKeyword = [uri]::EscapeDataString($Keyword)
    $BaseUrl = $Config.BoardUrl
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    $FoundResults = @(); $CurrentSearchPos = ""
    Write-Host ">>> Press 'Q' at any time to stop searching and view results. <<<" -ForegroundColor Magenta

    $StopSearch = $false
    $MaxBlocks = if ($Config.KeywordSearchMaxBlocks) { [int]$Config.KeywordSearchMaxBlocks } else { 300 }
    for ($Block = 1; $Block -le $MaxBlocks; $Block++) {
        if ($StopSearch) { break }
        Write-Log "Verbose" "Crawler" "Scanning Time Block $Block"
        $NextSearchPos = ""; $BlockHasNext = $false
        
        for ($Page = 1; $Page -le 10; $Page++) {
            # --- KEYBOARD INTERRUPT LISTENER ---
            if ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).Key -eq 'Q') {
                    Write-Host "`n[!] Search interrupted by user." -ForegroundColor Yellow
                    $StopSearch = $true; break
                }
            }

            $TargetUrl = "$BaseUrl&page=$Page&s_type=search_subject_memo&s_keyword=$EncodedKeyword"
            if ($CurrentSearchPos) { $TargetUrl += "&search_pos=$CurrentSearchPos" }
            
            Write-Log "Verbose" "Network" "Requesting list page" @{ url=$TargetUrl }
            try { $Html = (Invoke-WebRequest -Uri $TargetUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content } catch { continue }
            if (-not $Html) { continue }

            [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
                $T = ($_.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if ($T -match '번역\)|\[번역\]' -and $T -notmatch '모음|추천|번역추|요청|질문|념글') {
                    $U = ($_.Groups[1].Value -replace '&amp;', '&' -replace '^/board', 'https://gall.dcinside.com/board')
                    if ($U -notmatch '^http') { $U = "https://gall.dcinside.com" + $U }
                    
                    $CleanU = $U -replace '&page=[^&]*', '' -replace '&s_type=[^&]*', '' -replace '&s_keyword=[^&]*', '' -replace '&search_pos=[^&]*', '' -replace '&exception_mode=[^&]*', ''
                    
                    if ($null -eq ($FoundResults | Where-Object { $_.Url -eq $CleanU })) {
                        # Add to session array with a Downloaded boolean instead of parsing series
                        $FoundResults += [PSCustomObject]@{ Title = $T; Url = $CleanU; Downloaded = $false }
                    }
                }
            }
            if ($Html -match 'search_pos=(-\d+)[^>]*>(?:<[^>]+>)*다음 검색') { $NextSearchPos = $Matches[1]; $BlockHasNext = $true }
            if ($Html -notmatch "page=$($Page+1)") { break }
        }
        if ($BlockHasNext -and $NextSearchPos -ne $CurrentSearchPos) { $CurrentSearchPos = $NextSearchPos } else { break }
    }

    if ($FoundResults.Count) {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $FoundResults | Export-Csv $DsCsvFile -NoTypeInformation -Encoding $Enc
        Write-Log "Info" "KeywordSearch" "Saved entries to ds_results.csv" @{ keyword=$Keyword; found=$FoundResults.Count }
        
        Write-Host "`nSearch finished. Opening Checklist..." -ForegroundColor Green
        Start-Sleep -Seconds 1
        Browse-DsResults
    } else {
        Write-Host "`nNo valid chapters found." -ForegroundColor Red
        Write-Host "Press Enter to return..." -ForegroundColor Gray; $null = Read-Host
    }
}

function Start-SingleUrlExtraction {
    Initialize-SessionLog "Misc"
    Clear-Host
    Write-Host "=== Extract Series from URL ===" -ForegroundColor Cyan
    $url = Read-Host "Enter DCInside post URL"
    Write-Log "Verbose" "Crawler" "Manual URL extraction started" @{ url=$url }
    try {
        $html = (Invoke-WebRequest $url -UseBasicParsing).Content
        $series = Extract-SeriesFromHtml $html $url
        if ($series.Count) { 
            $Added = Merge-SeriesCsv $series
            Write-Host "Successfully added $Added new chapters." -ForegroundColor Green
        } else { Write-Host "No series data found." -ForegroundColor Yellow }
    } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    Start-Sleep -Seconds 2
}

function Start-BoardSeriesCrawler {
    param([switch]$AutoRun)
    Initialize-SessionLog "BoardSeries"
    Clear-Host
    Write-Host "=== Board Series Crawler ===" -ForegroundColor Cyan
    $BaseUrl = $Config.BoardUrl; $MaxPages = [int]$Config.SeriesBrowserMaxPages
    Write-Log "Verbose" "Crawler" "Board crawler started" @{ board=$BaseUrl; pages=$MaxPages }
    $FoundPosts = @()
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    Write-Host ">>> Press 'Q' at any time to stop and save results. <<<" -ForegroundColor Magenta

    for ($p=1; $p -le $MaxPages; $p++) {
        if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Scanning interrupted. Moving to extraction..." -ForegroundColor Yellow; break } }
        
        Write-Host "Scanning Board Page $p/$MaxPages..." -ForegroundColor Gray
        try { $Html = (Invoke-WebRequest "$BaseUrl&page=$p" -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content } catch { continue }
        [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
            if ($_.Groups[2].Value -match '번역\)|\[번역\]') {
                $u = $_.Groups[1].Value -replace '&amp;', '&' -replace '&page=[^&]*', ''
                if ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
                if ($FoundPosts -notcontains $u) { $FoundPosts += $u }
            }
        }
    }

    Write-Host "`nCrawling $($FoundPosts.Count) posts for series blocks..." -ForegroundColor Yellow
    $Total = 0; $idx = 1
    foreach ($u in $FoundPosts) {
        if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Extraction interrupted. Saving progress..." -ForegroundColor Yellow; break } }
        
        Write-Host "[$idx/$($FoundPosts.Count)] checking..." -ForegroundColor Gray
        try { $h = (Invoke-WebRequest $u -Headers $Headers -UseBasicParsing -TimeoutSec 10).Content; $s = Extract-SeriesFromHtml $h $u; if($s.Count){ $Total += Merge-SeriesCsv $s } } catch {}
        $idx++
    }
    Write-Log "Info" "BoardCrawler" "Finished. Merged $Total entries."
    Write-Host "`nBoard Crawler finished. Merged $Total new series links into the CSV Catalog." -ForegroundColor Green
    
    # Only pause if NOT running automatically
    if (-not $AutoRun) { Write-Host "Press Enter to return..." -ForegroundColor Gray; $null = Read-Host }
}

# =========================
# Browser & UI
# =========================
function Start-CsvSeriesBrowser {
    Initialize-SessionLog "Misc"
    Write-Log "Verbose" "UI" "CSV Browser opened"
    $rows = Read-SeriesCsv; if (-not $rows) { Write-Host "Catalog is empty." -ForegroundColor Red; Start-Sleep -Seconds 2; return }
    $groups = $rows | Group-Object Series | Sort-Object Name; $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== CSV SERIES BROWSER ===" -ForegroundColor Cyan
        $slice = $groups | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) { Write-Host "[$i] $($slice[$i].Name)" }
        Write-Host "`n(n)ext page | (p)revious page | (#) to select series | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'n' -and ($page*10+10) -lt $groups.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^[0-9]$' -and [int]$k -lt $slice.Count) { Browse-CsvSeriesChapters $slice[[int]$k] }
    }
}

function Browse-CsvSeriesChapters($Group) {
    Write-Log "Verbose" "UI" "Chapter Browser opened" @{ series=$Group.Name }
    $chs = $Group.Group; $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== $($Group.Name) ===" -ForegroundColor Cyan
        $slice = $chs | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) { Write-Host "[$i] $($slice[$i].Chapter)" }
        Write-Host "`n(n)ext page | (p)revious page | (d)ownload all | (#) to download | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'd') { 
            Write-Log "Verbose" "UI" "Queue All selected"
            Add-ToManualDownloadList $chs.Url; Invoke-ManualDownloader; return 
        }
        if ($k -eq 'n' -and ($page*10+10) -lt $chs.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^[0-9]$' -and [int]$k -lt $slice.Count) { 
            Write-Log "Verbose" "UI" "Single chapter selected" @{ url=$slice[[int]$k].Url }
            Add-ToManualDownloadList $slice[[int]$k].Url; Invoke-ManualDownloader; return 
        }
    }
}

function Browse-DsResults {
    Write-Log "Verbose" "UI" "Deep Search Checklist opened"
    if (-not (Test-Path $DsCsvFile)) { return }
    
    # Force the imported CSV into an array in case there's only 1 result
    $rows = @(Import-Csv $DsCsvFile)
    $page = 0
    
    while ($true) {
        Clear-Host
        Write-Host "=== DEEP-SEARCH CHECKLIST ===" -ForegroundColor Cyan
        $slice = $rows | Select-Object -Skip ($page*10) -First 10
        
        for ($i=0; $i -lt $slice.Count; $i++) { 
            $mark = if ($slice[$i].Downloaded -eq 'True') { "[X]" } else { "[ ]" }
            $color = if ($slice[$i].Downloaded -eq 'True') { "DarkGray" } else { "White" }
            Write-Host "[$i] $mark $($slice[$i].Title)" -ForegroundColor $color
        }
        
        Write-Host "`n(n)ext page | (p)revious page | (d)ownload all | (#) to download | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        
        if ($k -eq 'b') { return }
        if ($k -eq 'n' -and ($page*10+10) -lt $rows.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        
        # Download ALL un-downloaded items in the entire CSV
        if ($k -eq 'd') {
            $undownloaded = $rows | Where-Object { $_.Downloaded -ne 'True' }
            if ($undownloaded) {
                $urls = @($undownloaded | Select-Object -ExpandProperty Url)
                Write-Log "Verbose" "UI" "Deep Search: Download ALL selected" @{ count=$urls.Count }
                
                Add-ToManualDownloadList $urls
                Invoke-ManualDownloader
                
                foreach ($item in $undownloaded) { $item.Downloaded = $true }
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $rows | Export-Csv $DsCsvFile -NoTypeInformation -Encoding $Enc
            } else {
                Write-Host "All items are already downloaded!" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            continue
        }
        
        # Download specific item
        if ($k -match '^[0-9]$' -and [int]$k -lt $slice.Count) { 
            $idx = ($page * 10) + [int]$k
            $target = $rows[$idx]
            
            if ($target.Downloaded -ne 'True') {
                Write-Log "Verbose" "UI" "Deep Search: Single item selected" @{ url=$target.Url }
                Add-ToManualDownloadList @($target.Url)
                Invoke-ManualDownloader
                
                $target.Downloaded = $true
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $rows | Export-Csv $DsCsvFile -NoTypeInformation -Encoding $Enc
            } else {
                Write-Host "Already downloaded!" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            continue 
        }
    }
}

# =========================
# Headless Execution
# =========================
if ($RunBoardCrawler) {
    Start-BoardSeriesCrawler -AutoRun
    exit
}

# =========================
# Main Menu
# =========================
do {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "          DC Manga Search-Crawler         " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1. Keyword Deep-Search Crawler"
    Write-Host " 2. Extract Series from Single URL"
    Write-Host " 3. Board Series Crawler"
    Write-Host " 4. CSV Series Browser"
    Write-Host " 0. Return to Main Menu"
    Write-Host "==========================================" -ForegroundColor Cyan
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Start-KeywordSearch }
        "2" { Start-SingleUrlExtraction }
        "3" { Start-BoardSeriesCrawler }
        "4" { Start-CsvSeriesBrowser }
        "0" { exit } # Completely exits the PS script, returning control to launch.bat
    }
} while ($true)