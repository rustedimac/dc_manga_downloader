# Search-Crawler.ps1

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config  = Get-Config
$CsvFile = Join-Path $PSScriptRoot "series_catalog.csv"

$MaxPages = [int]$Config.MaxPages
$Headers = @{
    "User-Agent" = "Mozilla/5.0"
    "Referer"    = "https://gall.dcinside.com/"
}

# =========================
# HELPERS
# =========================
function Get-PageHtml($Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $Headers -TimeoutSec 15
        return $r.Content
    } catch {
        return $null
    }
}

function Clean-DcUrl($u) {
    if ($u -notmatch '^http') { "https://gall.dcinside.com$u" } else { $u }
}

# =========================
# SERIES PARSER (FIXED)
# =========================
# Extract all dc_series blocks from a post's HTML
function Get-SeriesFromHtml([string]$Html) {
    $SeriesMap = @{}

    # FIXED: capture entire dc_series block, not just up to first inner </div>
    $Blocks = [regex]::Matches(
        $Html,
        '(?s)<div\s+class="dc_series"[^>]*>(.+?)</div>\s*(?=<div|$)'
    )

    foreach ($Block in $Blocks) {
        $BlockHtml = $Block.Groups[1].Value

        # Title extraction
        $SeriesTitle = "Unknown Series"
        if ($BlockHtml -match '<div[^>]*font-weight\s*:\s*bold[^>]*>\s*\[시리즈\]\s*(.*?)\s*</div>') {
            $SeriesTitle = $Matches[1].Trim()
        }

        # Chapter link extraction
        $ChapterLinks = [regex]::Matches(
            $BlockHtml,
            '<a\s+class="lnk"[^>]*href="([^"]+)"[^>]*>\s*·\s*(.*?)\s*</a>'
        )

        $Chapters = @()
        foreach ($L in $ChapterLinks) {
            $ChUrl   = Clean-DcUrl ($L.Groups[1].Value)
            $ChTitle = ($L.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>').Trim()
            $Chapters += [PSCustomObject]@{ Title = $ChTitle; URL = $ChUrl }
        }

        if ($Chapters.Count -gt 0 -and $SeriesTitle -ne "Unknown Series") {
            $SeriesMap[$SeriesTitle] = $Chapters
        }
    }

    return $SeriesMap
}

# =========================
# SERIES BROWSER MODE
# =========================
function Start-SeriesBrowser {
    Write-Host ""
    Write-Host "Scanning $MaxPages page(s)..." -ForegroundColor Cyan

    $All = @()

    for ($p = 1; $p -le $MaxPages; $p++) {
        $ListHtml = Get-PageHtml "$($Config.BoardUrl)&page=$p"
        if (-not $ListHtml) { continue }

        $Posts = [regex]::Matches(
            $ListHtml,
            '/board/view/\?id=[^"&]+&no=\d+'
        ) | ForEach-Object {
            "https://gall.dcinside.com$($_.Value)"
        } | Select-Object -Unique

        foreach ($Post in $Posts) {
            $PostHtml = Get-PageHtml $Post
            if (-not $PostHtml) { continue }
            if ($PostHtml -notmatch 'dc_series') { continue }

            $Series = Get-SeriesFromHtml $PostHtml
            foreach ($S in $Series.Values) {
                $All += $S
                Write-Host "[SERIES] $($S[0].Series)" -ForegroundColor Green
            }
        }
    }

    if ($All.Count -gt 0) {
        $All | Export-Csv $CsvFile -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "Saved to $CsvFile" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "No series found." -ForegroundColor Red
    }
}

# =========================
# CLI MENU (RESTORED)
# =========================
Clear-Host
Write-Host "DCinside Series Crawler" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Series Browser"
Write-Host "2. Exit"

switch (Read-Host "Select") {
    "1" { Start-SeriesBrowser }
    default { }
}

Write-Host ""
Write-Host "Press any key to exit..."
[Console]::ReadKey($true)
