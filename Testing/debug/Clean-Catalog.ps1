# ==========================================
# DC Manga Standalone Catalog Cleaner
# ==========================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent
$CsvFile = Join-Path $RootDir "Data\series_catalog.csv"

# [NEW] Load shared config and Mutex locks
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# [NEW] Updated URL Sanitizer (Now scrubs #DELETED flags as well)
function Get-CleanUrl([string]$u) {
    $u = $u.Trim() -replace "^#RETRY ", "" -replace "^#DELETED ", ""
    if ($u -match 'gall\.dcinside\.com/board/view/') {
        $id = if ($u -match '[?&]id=([^&]+)') { $Matches[1] } else { "" }
        $no = if ($u -match '[?&]no=(\d+)') { $Matches[1] } else { "" }
        if ($id -and $no) {
            return "https://gall.dcinside.com/board/view/?id=$id&no=$no"
        }
    }
    return $u
}

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Catalog URL Canonicalizer / Cleaner    " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

if (-not (Test-Path $CsvFile)) {
    Write-Host "[ERROR] Could not find series_catalog.csv at: $CsvFile" -ForegroundColor Red
    Pause
    exit
}

$RawRows = @(Import-Csv $CsvFile -Encoding UTF8)
$CleanRows = New-Object System.Collections.Generic.List[PSObject]
$SeenUrls = @{}

$CleanedCount = 0
$RemovedDups = 0

foreach ($row in $RawRows) {
    if ([string]::IsNullOrWhiteSpace($row.Url)) { continue }

    $CleanUrl = Get-CleanUrl $row.Url
    if ($CleanUrl -ne $row.Url.Trim()) {
        $CleanedCount++
    }

    if (-not $SeenUrls.ContainsKey($CleanUrl)) {
        $SeenUrls[$CleanUrl] = $true
        
        $oldDate = if ($row.Date) { $row.Date } else { "" }
        $oldExtra = if ($row.ExtraLinks) { $row.ExtraLinks } else { "" }
        $oldStatus = if ($row.Status) { $row.Status } else { "" }
        
        # [CRITICAL FIX] Safely preserve the new OriginalTitle column
        $oldOriginalTitle = if ($row.OriginalTitle) { $row.OriginalTitle } else { $row.Chapter }
        
        # Scrub known junk ad links from existing ExtraLinks data
        $CleanExtraLinks = @()
        if (-not [string]::IsNullOrWhiteSpace($oldExtra)) {
            foreach ($l in ($oldExtra -split '\|')) {
                $l = $l.Trim()
                if ($l -and $l -notmatch 'dcinside\.(com|co\.kr)|\$\{link\}|pickmaker\.com|rankify\.best|naver\.com/adbiz') {
                    $CleanExtraLinks += $l
                }
            }
        }
        $finalExtraLinks = ($CleanExtraLinks | Sort-Object -Unique) -join " | "
        
        # Build a fresh object. This guarantees all new columns exist!
        $CleanRows.Add([PSCustomObject]@{
            Series = $row.Series
            Chapter = $row.Chapter
            OriginalTitle = $oldOriginalTitle
            Url = $CleanUrl
            Date = $oldDate
            ExtraLinks = $finalExtraLinks
            Status = $oldStatus
        })
    } else {
        $RemovedDups++
    }
}

$Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }

# [NEW] Safely write using Cross-Process Mutex Locks and Atomic Write
Invoke-WithFileLock "SeriesCsv" {
    Write-FileAtomic -Path $CsvFile -Content $CleanRows -Encoding $Enc -AsCsv
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Done!" -ForegroundColor Green
Write-Host "URLs Sanitized: $CleanedCount" -ForegroundColor White
Write-Host "Duplicates Removed: $RemovedDups" -ForegroundColor White
Write-Host "Total Unique Chapters: $($CleanRows.Count)" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan
Pause