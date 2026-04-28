# ==========================================
# DC Manga Search-Crawler (Definitive Edition)
# ==========================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# =========================
# Paths & Setup
# =========================
$ScriptRoot = $PSScriptRoot
$CsvFile    = Join-Path $ScriptRoot "series_catalog.csv"
$ListFile   = Join-Path $ScriptRoot "download_list.txt"
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
# Excel-Safe Session Logging
# =========================
$LogDir = Join-Path $ScriptRoot ($Config.CrawlerLogDir -replace '^.\[\\/]', '')
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Scheme: crawler_2026-04-28_000854.json
$script:SessionLogFile = Join-Path $LogDir ("crawler_" + (Get-Date -Format "yyyy-MM-dd_HHmmss") + ".json")
$script:LogEntries = New-Object System.Collections.Generic.List[PSObject]
$script:RunId = [guid]::NewGuid().ToString()
$LogRank = @{ Error=0; Warn=1; Info=2; Verbose=3; DEBUG=3 }

function Save-SessionLogs {
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { 
        $script:LogEntries | ConvertTo-Json -Depth 5 -EscapeHandling EscapeHtml
    } else { 
        $script:LogEntries | ConvertTo-Json -Depth 5
    }
    
    $CleanJson = $Json -replace '\\u0026', '&'
    
    # Excel compatibility: Use utf8BOM for v7 or UTF8 for v5
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
    
    if ($Html -notmatch '\[시리즈\]') { 
        Write-Log "Verbose" "Extractor" "No series block found"
        return @{} 
    }
    
    $parts = $Html -split '\[시리즈\]', 2
    $after = $parts[1]

    if ($after -match '(?s)^\s*(.*?)(?:<a|<br|·)') {
        $title = ($Matches[1] -replace '<[^>]+>', '').Trim()
    } else { $title = "UNKNOWN" }

    $chapterMatches = [regex]::Matches($after, '<a[^>]+href="([^"]+)"[^>]*>\s*·\s*([^<]+)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($chapterMatches.Count -eq 0) { return @{} }

    $chapters = @()
    foreach ($m in $chapterMatches) {
        $chapters += [PSCustomObject]@{ Series = ""; Chapter = $m.Groups[2].Value.Trim(); Url = $m.Groups[1].Value.Trim() }
    }

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
                $out += $c; $added++; 
                Write-Log "Verbose" "CSV" "New chapter added" @{ series=$c.Series; chapter=$c.Chapter }
            }
        }
    }
    if ($added -gt 0) { Write-SeriesCsv $out }
    return $added
}

function Add-ToManualDownloadList($Urls) {
    Write-Log "Verbose" "Queue" "Updating manual_urls in download_list.txt" @{ urlCount=$Urls.Count }
    $lines = Get-Content $ListFile -Encoding UTF8; $out = New-Object System.Collections.Generic.List[string]
    $inManual=$false; $existing=@()
    foreach ($l in $lines) {
        if ($l -match '^\[manual_urls\]') { $inManual=$true }
        elseif ($l -match '^\[') { $inManual=$false }
        elseif ($inManual -and $l -match '^https?://') { $existing+=$l.Trim() }
        $out.Add($l)
    }
    $idx = $out.IndexOf('[manual_urls]') + 1
    foreach ($u in $Urls | Sort-Object -Unique) {
        if ($u -notin $existing) { $out.Insert($idx++,$u); Write-Log "Verbose" "Queue" "Added URL to queue" @{ url=$u } }
    }
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $out | Set-Content $ListFile -Encoding $Enc
}

function Invoke-ManualDownloader {
    Write-Log "Info" "Handoff" "Invoking Start-Downloader.ps1"
    & $Downloader
}

# =========================
# Crawler Engines
# =========================
function Start-KeywordSearch {
    Clear-Host
    Write-Host "=== Keyword Deep-Search Crawler ===" -ForegroundColor Cyan
    $Keyword = Read-Host "Enter Manga Title/Keyword to search"
    if ([string]::IsNullOrWhiteSpace($Keyword)) { return }
    
    Write-Log "Verbose" "Crawler" "Keyword search initiated" @{ keyword=$Keyword }
    $EncodedKeyword = [uri]::EscapeDataString($Keyword)
    $BaseId = "comic_new6"; if ($Config.BoardUrl -match 'id=([^&]+)') { $BaseId = $Matches[1] }
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    $FoundResults = @(); $CurrentSearchPos = ""

    for ($Block = 1; $Block -le 300; $Block++) {
        Write-Log "Verbose" "Crawler" "Scanning Time Block $Block"
        $NextSearchPos = ""; $BlockHasNext = $false
        for ($Page = 1; $Page -le 10; $Page++) {
            $TargetUrl = "https://gall.dcinside.com/board/lists/?id=$BaseId&page=$Page&s_type=search_subject&s_keyword=$EncodedKeyword"
            if ($CurrentSearchPos) { $TargetUrl += "&search_pos=$CurrentSearchPos" }
            
            Write-Log "Verbose" "Network" "Requesting list page" @{ url=$TargetUrl }
            try { $Html = (Invoke-WebRequest -Uri $TargetUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content } catch { continue }
            if (-not $Html) { continue }

            [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
                $T = ($_.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if ($T -match '번역\)|\[번역\]' -and $T -notmatch '모음|추천|번역추|요청|질문|념글') {
                    $U = ($_.Groups[1].Value -replace '&amp;', '&' -replace '^/board', 'https://gall.dcinside.com/board')
                    if ($U -notmatch '^http') { $U = "https://gall.dcinside.com" + $U }
                    $CleanU = $U -replace '&page=[^&]*', '' -replace '&s_type=[^&]*', '' -replace '&s_keyword=[^&]*', '' -replace '&search_pos=[^&]*', ''
                    if ($null -eq ($FoundResults | Where-Object { $_.Url -eq $CleanU })) {
                        $Parsed = Parse-TitleToSeries $T
                        $FoundResults += [PSCustomObject]@{ Series = $Parsed.Series; Chapter = $Parsed.Chapter; Url = $CleanU }
                    }
                }
            }
            if ($Html -match 'search_pos=(-\d+)[^>]*>(?:<[^>]+>)*다음 검색') { $NextSearchPos = $Matches[1]; $BlockHasNext = $true }
            if ($Html -notmatch "page=$($Page+1)") { break }
        }
        if ($BlockHasNext -and $NextSearchPos -ne $CurrentSearchPos) { $CurrentSearchPos = $NextSearchPos } else { break }
    }

    if ($FoundResults.Count) {
        $SeriesMap = @{}; foreach($r in $FoundResults){ if(-not $SeriesMap.ContainsKey($r.Series)){$SeriesMap[$r.Series]=@()}; $SeriesMap[$r.Series]+=$r }
        $Added = Merge-SeriesCsv $SeriesMap
        Write-Log "Info" "KeywordSearch" "Merged $Added entries into CSV" @{ keyword=$Keyword; found=$FoundResults.Count }
    }
    Write-Host "`nPress Enter to return..." -ForegroundColor Gray; $null = Read-Host
}

function Start-SingleUrlExtraction {
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
    Clear-Host
    Write-Host "=== Board Series Crawler ===" -ForegroundColor Cyan
    $BaseUrl = $Config.BoardUrl; $MaxPages = [int]$Config.MaxPages
    Write-Log "Verbose" "Crawler" "Board crawler started" @{ board=$BaseUrl; pages=$MaxPages }
    $FoundPosts = @()
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    for ($p=1; $p -le $MaxPages; $p++) {
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
        Write-Host "[$idx/$($FoundPosts.Count)] checking..." -ForegroundColor Gray
        try { $h = (Invoke-WebRequest $u -Headers $Headers -UseBasicParsing -TimeoutSec 10).Content; $s = Extract-SeriesFromHtml $h $u; if($s.Count){ $Total += Merge-SeriesCsv $s } } catch {}
        $idx++
    }
    Write-Log "Info" "BoardCrawler" "Finished. Merged $Total entries."
    Write-Host "Press Enter..."; $null = Read-Host
}

# =========================
# Browser & UI
# =========================
function Start-CsvSeriesBrowser {
    Write-Log "Verbose" "UI" "CSV Browser opened"
    $rows = Read-SeriesCsv; if (-not $rows) { Write-Host "Catalog is empty." -ForegroundColor Red; Start-Sleep -Seconds 2; return }
    $groups = $rows | Group-Object Series | Sort-Object Name; $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== CSV SERIES BROWSER ===" -ForegroundColor Cyan
        $slice = $groups | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) { Write-Host "[$i] $($slice[$i].Name)" }
        Write-Host "`nn/p page | b back" -ForegroundColor Gray
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
        Write-Host "`nn/p page | d queue all | b back" -ForegroundColor Gray
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
    Write-Host " 0. Exit"
    Write-Host "==========================================" -ForegroundColor Cyan
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Start-KeywordSearch }
        "2" { Start-SingleUrlExtraction }
        "3" { Start-BoardSeriesCrawler }
        "4" { Start-CsvSeriesBrowser }
        "0" { break }
    }
} while ($true)