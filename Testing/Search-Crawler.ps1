# Search-Crawler.ps1

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config   = Get-Config
$CsvFile  = Join-Path $PSScriptRoot "series_catalog.csv"

$MaxPages = [int]$Config.MaxPages
$Headers = @{
    "User-Agent" = "Mozilla/5.0"
    "Referer"    = "https://gall.dcinside.com/"
}

# =========================
# JSON LOGGING
# =========================
$LogDir = $Config.CrawlerLogDir
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir "crawler_$(Get-Date -Format yyyyMMdd_HHmmss).json"

$Log = [ordered]@{ events = @() }

function Log($cat,$msg,$data=@{}) {
    $Log.events += @{
        time = (Get-Date).ToString("o")
        category = $cat
        message = $msg
        data = $data
    }
}

function Save-Log {
    $Log | ConvertTo-Json -Depth 6 | Set-Content $LogFile -Encoding UTF8
}

# =========================
# HELPERS
# =========================
function Get-PageHtml($Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $Headers -TimeoutSec 15
        Log "Fetch" "OK" @{ url=$Url; length=$r.Content.Length }
        return $r.Content
    } catch {
        Log "Fetch" "FAIL" @{ url=$Url; error=$_.Exception.Message }
        return $null
    }
}

function Clean-DcUrl($u) {
    if ($u -notmatch '^http') { "https://gall.dcinside.com$u" } else { $u }
}

# =========================
# SERIES PARSER (FIXED)
# =========================
function Get-SeriesFromHtml($Html) {
    $Result = @{}

    $Blocks = [regex]::Matches(
        $Html,
        '(?s)<div\s+class="dc_series"[^>]*>(.+?)</div>\s*(?=<div|$)'
    )

    Log "SeriesScan" "dc_series blocks" @{ count=$Blocks.Count }

    foreach ($B in $Blocks) {
        $BlockHtml = $B.Groups[1].Value

        if ($BlockHtml -notmatch '<div[^>]*font-weight\s*:\s*bold[^>]*>\s*\[시리즈\]\s*(.*?)\s*</div>') {
            continue
        }

        $Title = $Matches[1].Trim()

        $Links = [regex]::Matches(
            $BlockHtml,
            '<a\s+class="lnk"[^>]*href="([^"]+)"[^>]*>\s*·\s*(.*?)\s*</a>'
        )

        if ($Links.Count -eq 0) { continue }

        $Chapters = @()
        foreach ($L in $Links) {
            $Chapters += [PSCustomObject]@{
                Series  = $Title
                Chapter = $L.Groups[2].Value.Trim()
                URL     = Clean-DcUrl $L.Groups[1].Value
            }
        }

        $Result[$Title] = $Chapters
    }

    return $Result
}

# =========================
# MAIN SCAN
# =========================
$All = @()

for ($p=1; $p -le $MaxPages; $p++) {
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
    Write-Host "`nSaved to $CsvFile" -ForegroundColor Cyan
} else {
    Write-Host "`nNo series found." -ForegroundColor Red
}

Save-Log
Write-Host "Log saved to $LogFile"
``
