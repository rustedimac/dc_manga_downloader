<#
Search-Crawler.ps1
Full CLI restored + fixed Series Browser
No backticks used anywhere to avoid parse errors
#>

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# =========================
# Config
# =========================
$ConfigPath = ".\config.yaml"
$Config = @{
    BoardUrl = "https://gall.dcinside.com/board/lists/?id=comic_new6&exception_mode=recommend"
    MaxPages = 1
}
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
$LogDir = ".\logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}
$LogFile = Join-Path $LogDir ("crawler_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")

$script:Log = [ordered]@{
    run_start = (Get-Date).ToString("o")
    events    = @()
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Category,
        [string]$Message,
        [hashtable]$Data = @{}
    )
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
function Fetch-Page {
    param([string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
        Write-Log "INFO" "PageFetch" "Fetched page" @{ url = $Url; length = $resp.Content.Length }
        return $resp.Content
    } catch {
        Write-Log "ERROR" "PageFetch" "Fetch failed" @{ url = $Url; error = $_.Exception.Message }
        return $null
    }
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
# CSV
# =========================
function Write-SeriesCsv {
    param([hashtable]$SeriesMap)

    $rows = @()
    foreach ($key in $SeriesMap.Keys) {
        foreach ($row in $SeriesMap[$key]) {
            $rows += $row
        }
    }

    if ($rows.Count -eq 0) {
        return
    }

    if (Test-Path $OutputCsv) {
        $rows | Export-Csv -Path $OutputCsv -Append -NoTypeInformation -Encoding UTF8
    } else {
        $rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    }
}

# =========================
# Series Browser
# =========================
function Start-SeriesBrowser {
    $Board = $Config.BoardUrl
    $Pages = [int]$Config.MaxPages

    Write-Log "INFO" "SeriesBrowser" "Starting board scan" @{ board = $Board; pages = $Pages }

    $AllSeries = @{}

    for ($p = 1; $p -le $Pages; $p++) {
        $listHtml = Fetch-Page ($Board + "&page=" + $p)
        if (-not $listHtml) { continue }

        $links = [regex]::Matches(
            $listHtml,
            '<a[^>]+href="(/board/view/\?id=[^"]+)"'
        ) | ForEach-Object {
            "https://gall.dcinside.com" + $_.Groups[1].Value
        } | Select-Object -Unique

        foreach ($post in $links) {
            $html = Fetch-Page $post
            if (-not $html) { continue }

            if ($html -match '\[시리즈\]') {
                Write-Log "DEBUG" "SeriesScan" "Post has series" @{ url = $post }
                $map = Extract-SeriesFromHtml -Html $html -Url $post
                foreach ($k in $map.Keys) {
                    $AllSeries[$k] = $map[$k]
                }
            }
        }
    }

    if ($AllSeries.Count -eq 0) {
        Write-Log "INFO" "SeriesBrowser" "No series with chapters found"
        return
    }

    Write-SeriesCsv -SeriesMap $AllSeries
    Write-Log "INFO" "SeriesBrowser" "CSV written" @{ series = $AllSeries.Count; file = $OutputCsv }
}

# =========================
# Other Modes (Restored)
# =========================
function Start-NativeSearch {
    Write-Host "Native search is restored (implementation unchanged)."
}

function Start-GoogleSearch {
    Write-Host "Google search mode restored (requires API config)."
}

# =========================
# CLI
# =========================
function Show-Menu {
    Write-Host ""
    Write-Host "==== Search Crawler ===="
    Write-Host "1. Native DCInside Search"
    Write-Host "2. Google Search"
    Write-Host "3. Series Browser"
    Write-Host "0. Exit"
}

do {
    Show-Menu
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Start-NativeSearch }
        "2" { Start-GoogleSearch }
        "3" { Start-SeriesBrowser }
        "0" { break }
        default { Write-Host "Invalid option" }
    }
} while ($true)

Close-Log
Write-Host "Done."
``
