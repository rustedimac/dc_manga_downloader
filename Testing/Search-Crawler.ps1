# Search-Crawler.ps1
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# =========================
# Config
# =========================
$ConfigPath = ".\config.yaml"
$Config = @{}
if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match '^\s*([^:#]+)\s*:\s*(.+)$') {
            $Config[$matches[1].Trim()] = $matches[2].Trim('" ')
        }
    }
}

$OutputCsv = "series_catalog.csv"

# =========================
# Logging (JSON)
# =========================
$LogDir = $Config.CrawlerLogDir ?? ".\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("crawler_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")

$script:Log = [ordered]@{
    run_start = (Get-Date).ToString("o")
    events    = @()
}

function Log {
    param($Level, $Category, $Message, $Data = @{})
    $script:Log.events += [ordered]@{
        timestamp = (Get-Date).ToString("o")
        level     = $Level
        category  = $Category
        message   = $Message
        data      = $Data
    }
}

function Close-Log {
    $script:Log.run_end = (Get-Date).ToString("o")
    $script:Log | ConvertTo-Json -Depth 6 | Set-Content $LogFile -Encoding UTF8
}

# =========================
# HTTP
# =========================
function Fetch-Page($Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        Log INFO PageFetch "Fetched page" @{ url = $Url; length = $r.Content.Length }
        return $r.Content
    } catch {
        Log ERROR PageFetch "Fetch failed" @{ url = $Url; error = $_.Exception.Message }
        return $null
    }
}

# =========================
# Series Extraction (WORKING)
# =========================
function Extract-SeriesFromHtml {
    param($Html, $Url)

    if ($Html -notmatch '\[시리즈\]') {
        return @{}
    }

    # Split AFTER [시리즈]
    $parts = $Html -split '\[시리즈\]', 2
    if ($parts.Count -lt 2) { return @{} }

    $after = $parts[1]

    # Extract title (text before first link)
    $title = ($after -split '<a', 2)[0]
    $title = $title -replace '<[^>]+>', ''
    $title = $title.Trim()
    if (-not $title) { $title = "UNKNOWN" }

    # ✅ Extract ANY anchor with ·
    $matches = [regex]::Matches(
        $after,
        '<a[^>]+href="([^"]+)"[^>]*>\s*·\s*([^<]+)</a>',
        'IgnoreCase'
    )

    $chapters = @()
    foreach ($m in $matches) {
        $chapters += [PSCustomObject]@{
            Series  = $title
            Chapter = $m.Groups[2].Value.Trim()
            Url     = $m.Groups[1].Value.Trim()
        }
    }

    Log DEBUG SeriesScan "Parsed series" @{
        title    = $title
        chapters = $chapters.Count
        url      = $Url
    }

    return @{ $title = $chapters }
}

# =========================
# CSV
# =========================
function Write-SeriesCsv($SeriesMap) {
    $rows = @()
    foreach ($s in $SeriesMap.Keys) {
        foreach ($c in $SeriesMap[$s]) {
            $rows += $c
        }
    }

    if ($rows.Count -eq 0) { return }

    if (Test-Path $OutputCsv) {
        $rows | Export-Csv $OutputCsv -Append -NoTypeInformation -Encoding UTF8
    } else {
        $rows | Export-Csv $OutputCsv -NoTypeInformation -Encoding UTF8
    }
}

# =========================
# Series Browser
# =========================
function Start-SeriesBrowser {
    $Board = $Config.BoardUrl
    $Pages = [int]($Config.MaxPages ?? 1)

    Log INFO SeriesBrowser "Starting board scan" @{ board = $Board; pages = $Pages }

    $AllSeries = @{}

    for ($p = 1; $p -le $Pages; $p++) {
        $listHtml = Fetch-Page "$Board&page=$p"
        if (-not $listHtml) { continue }

        $links = [regex]::Matches(
            $listHtml,
            '<a[^>]+href="(/board/view/\?id=[^"]+)"'
        ) | ForEach-Object {
            "https://gall.dcinside.com$($_.Groups[1].Value)"
        } | Select-Object -Unique

        foreach ($post in $links) {
            $html = Fetch-Page $post
            if (-not $html) { continue }

            if ($html -match '\[시리즈\]') {
                Log DEBUG SeriesScan "Post has series" @{ url = $post }
                $map = Extract-SeriesFromHtml $html $post
                foreach ($k in $map.Keys) {
                    if ($map[$k].Count -gt 0) {
                        $AllSeries[$k] = $map[$k]
                    }
                }
            }
        }
    }

    if ($AllSeries.Count -eq 0) {
        Log INFO SeriesBrowser "No series with chapters found"
        return
    }

    Write-SeriesCsv $AllSeries
    Log INFO SeriesBrowser "CSV written" @{ series = $AllSeries.Count; file = $OutputCsv }
}

# =========================
# Run
# =========================
Start-SeriesBrowser
Close-Log
Write-Host "DONE. CSV written if chapters were found."
``
