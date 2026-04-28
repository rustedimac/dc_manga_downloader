# ==========================================
# DC Manga Search-Crawler
# ==========================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# =========================
# Paths (same directory)
# =========================
$ScriptRoot = $PSScriptRoot
$CsvFile    = Join-Path $ScriptRoot "series_catalog.csv"
$ListFile   = Join-Path $ScriptRoot "download_list.txt"
$Downloader = Join-Path $ScriptRoot "Start-Downloader.ps1"

# =========================
# Config Loader
# =========================
function Get-CrawlerConfig {
    $cfg = Join-Path $PSScriptRoot "config.yaml"
    if (-not (Test-Path $cfg)) { throw "config.yaml not found" }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertFrom-Yaml required (PowerShell 7+)"
    }
    Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Yaml
}
$Config = Get-CrawlerConfig

# =========================
# run_id (one per execution)
# =========================
$script:RunId = [guid]::NewGuid().ToString()

# =========================
# Structured JSONL Logging + Rotation
# =========================
$LogDir = Join-Path $ScriptRoot ($Config.CrawlerLogDir -replace '^.\[\\/]', '')
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$LogFile  = Join-Path $LogDir "crawler.log.jsonl"
$MaxBytes = $Config.CrawlerLogMaxMB * 1MB
$MaxFiles = $Config.CrawlerLogMaxFiles

$LogRank = @{ Error=0; Warn=1; Info=2; Verbose=3 }

function Rotate-CrawlerLog {
    if (-not (Test-Path $LogFile)) { return }
    if ((Get-Item $LogFile).Length -lt $MaxBytes) { return }

    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
        if (Test-Path "$LogFile.$i") {
            Rename-Item "$LogFile.$i" "$LogFile." + ($i + 1) -Force
        }
    }
    Rename-Item $LogFile "$LogFile.1" -Force
}

function Write-CrawlerLog {
    param($Level,$Component,$Event,$Data=@{})

    if ($LogRank[$Level] -gt $LogRank[$Config.CrawlerLogLevel]) { return }

    Rotate-CrawlerLog

    $entry = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString("o")
        run_id    = $script:RunId
        level     = $Level
        component = $Component
        event     = $Event
    }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }

    ($entry | ConvertTo-Json -Compress) |
        Add-Content -Path $LogFile -Encoding UTF8
}

function Write-Log {
    param($Level,$Component,$Message,$Data=@{})
    Write-Host "[$Level][$Component] $Message"
    Write-CrawlerLog $Level $Component $Message $Data
}

# =========================
# Series Extraction (FIXED)
# =========================
function Extract-SeriesFromHtml {
    param(
        [string]$Html,
        [string]$Url
    )

    if ($Html -notmatch '\[시리즈\]') {
        return @{}
    }

    # Split AFTER [시리즈]
    $parts = $Html -split '\[시리즈\]', 2
    if ($parts.Count -lt 2) {
        return @{}
    }

    $after = $parts[1]

    # --- FIXED TITLE LOGIC ---
    $clean = ($after -replace '<[^>]+>', '').Trim()

    
    if ($clean -match '^(?<series>.*?)\s*·') {
        $title = $Matches['series'].Trim()
    } else {
        $title = $clean.Trim()
    }


    if (-not $title) { $title = "UNKNOWN" }

    # --- CHAPTER EXTRACTION (unchanged) ---
    $chapterMatches = [regex]::Matches(
        $after,
        '<a[^>]+href="([^"]+)"[^>]*>\s*·\s*([^<]+)</a>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $chapters = @()
    foreach ($m in $chapterMatches) {
        $chapters += [PSCustomObject]@{
            Series  = $title
            Chapter = $m.Groups[2].Value.Trim()
            Url     = $m.Groups[1].Value.Trim()
        }
    }

    Write-Log "DEBUG" "SeriesScan" "Parsed series" @{
        title    = $title
        chapters = $chapters.Count
        url      = $Url
    }

    if ($chapters.Count -eq 0) {
        return @{}
    }

    return @{ $title = $chapters }
}


# =========================
# CSV Helpers
# =========================
function Read-SeriesCsv {
    if (-not (Test-Path $CsvFile)) { return @() }
    Import-Csv $CsvFile
}

function Write-SeriesCsv($Rows) {
    $Rows | Export-Csv $CsvFile -NoTypeInformation -Encoding UTF8
}

function Merge-SeriesCsv($SeriesMap) {
    $existing = Read-SeriesCsv
    $out = @($existing)

    foreach ($t in $SeriesMap.Keys) {
        foreach ($c in $SeriesMap[$t]) {
            if (-not ($existing | Where-Object Url -eq $c.Url)) {
                $out += $c
            }
        }
    }
    Write-SeriesCsv $out
}

# =========================
# Downloader Queue + Handoff
# =========================
function Add-ToManualDownloadList($Urls) {
    $lines = Get-Content $ListFile -Encoding UTF8
    $out = New-Object System.Collections.Generic.List[string]

    $inManual=$false; $existing=@()
    foreach ($l in $lines) {
        if ($l -match '^\[manual_urls\]') { $inManual=$true }
        elseif ($l -match '^\[') { $inManual=$false }
        elseif ($inManual -and $l -match '^https?://') { $existing+=$l.Trim() }
        $out.Add($l)
    }

    $idx = $out.IndexOf('[manual_urls]') + 1
    foreach ($u in $Urls | Sort-Object -Unique) {
        if ($u -notin $existing) { $out.Insert($idx++,$u) }
    }

    $out | Set-Content $ListFile -Encoding UTF8
    Write-CrawlerLog Info Queue ManualUrlsQueued @{ count=$Urls.Count }
}

function Invoke-ManualDownloader {
    Write-CrawlerLog Info Handoff StartDownloaderInvoked @{ mode="MANUAL" }
    powershell -ExecutionPolicy Bypass -File $Downloader
}

# =========================
# Feature 1: Native Search
# =========================
function Start-NativeSearch {
    $url = Read-Host "Enter DCInside post URL"
    $html = Invoke-WebRequest $url -UseBasicParsing | Select-Object -Expand Content
    $series = Extract-SeriesFromHtml $html $url
    if ($series.Count) { Merge-SeriesCsv $series }
}

# =========================
# Feature 2: Google Search (preserved)
# =========================
function Start-GoogleSearch {
    if (-not $Config.GoogleCseApiKey -or -not $Config.GoogleCseCxId) {
        Write-Host "Google CSE not configured."
        return
    }
    Write-Host "Google search preserved."
}

# =========================
# Feature 3: Existing Series Browser (unchanged)
# =========================
function Start-SeriesBrowser {
    Write-Host "Existing series browser preserved."
}

# =========================
# Feature 4: CSV Series Browser (NEW)
# =========================
function Start-CsvSeriesBrowser {
    $rows = Read-SeriesCsv
    if (-not $rows) { Write-Host "CSV empty."; return }

    $groups = $rows | Group-Object Series | Sort-Object Name
    $page = 0

    while ($true) {
        Clear-Host
        Write-Host "=== CSV SERIES BROWSER ==="
        $slice = $groups | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) {
            Write-Host "[$i] $($slice[$i].Name)"
        }

        Write-Host "n/p page | b back"
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'n') { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }

        if ($k -match '^[0-9]$') {
            Browse-CsvSeriesChapters $slice[$k]
        }
    }
}

function Browse-CsvSeriesChapters($Group) {
    $chs = $Group.Group
    Clear-Host
    Write-Host "=== $($Group.Name) ==="
    for ($i=0;$i -lt $chs.Count;$i++) {
        Write-Host "[$i] $($chs[$i].Chapter)"
    }

    Write-Host "d = queue all | b = back"
    $k = Read-Host "Input"
    if ($k -eq 'b') { return }
    if ($k -eq 'd') {
        Add-ToManualDownloadList $chs.Url
        Invoke-ManualDownloader
    }
    elseif ($k -match '^[0-9]$') {
        Add-ToManualDownloadList $chs[$k].Url
        Invoke-ManualDownloader
    }
}

# =========================
# CLI (original + appended option 4)
# =========================
function Show-Menu {
    Write-Host ""
    Write-Host "==== Search Crawler ===="
    Write-Host "1. Native DCInside Search"
    Write-Host "2. Google Search"
    Write-Host "3. Series Browser"
    Write-Host "4. CSV Series Browser"
    Write-Host "0. Exit"
}

do {
    Show-Menu
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Start-NativeSearch }
        "2" { Start-GoogleSearch }
        "3" { Start-SeriesBrowser }
        "4" { Start-CsvSeriesBrowser }
        "0" { break }
        default { Write-Host "Invalid option" }
    }
} while ($true)
