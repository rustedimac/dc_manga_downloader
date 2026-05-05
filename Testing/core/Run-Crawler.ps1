# ==========================================
# DC Manga Auto-Crawler
# ==========================================
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$RootDir = Split-Path $PSScriptRoot -Parent
$ConfigFile = Join-Path $RootDir "config.yaml"

. (Join-Path $PSScriptRoot "Get-Config.ps1")

function Get-CleanUrl([string]$u) {
    $u = $u.Trim() -replace "^#RETRY ", "" -replace "^#DELETED ", ""
    if ($u -match 'gall\.dcinside\.com/board/view/') {
        $id = if ($u -match '[?&]id=([^&]+)') { $Matches[1] } else { "" }
        $no = if ($u -match '[?&]no=(\d+)') { $Matches[1] } else { "" }
        if ($id -and $no) { return "https://gall.dcinside.com/board/view/?id=$id&no=$no" }
    }
    return $u
}

$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

# --- FILTERS & OVERRIDES ---
$RequirePrefix = if ($Config.RequireTranslationPrefix -eq "False") { $false } else { $true }
$ForceRedownload = $Config.ForceRedownload -eq "True"

$ListFile = if ($Config.DownloadListPath) { Join-Path $RootDir ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_list.txt" }
$HistoryFile = if ($Config.DownloadHistoryPath) { Join-Path $RootDir ($Config.DownloadHistoryPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_history.csv" }

$Global:DownloadHistory = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $HistoryFile) {
    $histData = @(Import-Csv $HistoryFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Url) })
    foreach ($h in $histData) { $Global:DownloadHistory.Add($h.Url.Trim()) | Out-Null }
}

$BaseUrl = $Config.BoardUrl
$MaxPages = if ($Config.AutoCrawlerMaxPages) { [int]$Config.AutoCrawlerMaxPages } else { 3 }
$CrawlOrder = if ($null -ne $Config.CrawlOrder) { [int]$Config.CrawlOrder } else { 0 }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "       DC Manga Auto-Crawler Started      " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

if ($ForceRedownload) {
    Write-Host "[!] ForceRedownload is ON. Bypassing History filter." -ForegroundColor Magenta
}

$Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }
$FoundPosts = New-Object System.Collections.Generic.List[string]

$PagesToScan = if ($CrawlOrder -eq 0) { $MaxPages..1 } else { 1..$MaxPages }

foreach ($p in $PagesToScan) {
    Write-Host "Scanning Board Page $p..." -ForegroundColor Gray
    try { 
        $Html = (Invoke-WebRequest "$BaseUrl&page=$p" -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content 
    } catch { 
        Write-Host "  Failed to load page $p" -ForegroundColor Red
        continue 
    }
    
    $PageMatches = [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>')
    
    # Reverse array if crawling oldest first
    if ($CrawlOrder -eq 0) {
        $MatchArray = @()
        foreach ($m in $PageMatches) { $MatchArray += $m }
        [array]::Reverse($MatchArray)
        $PageMatches = $MatchArray
    }

    foreach ($m in $PageMatches) {
        $T = $m.Groups[2].Value
        
        # Apply Title Prefix Filter (e.g., "번역)")
        if (-not $RequirePrefix -or $T -match '번역\)|\[번역\]') {
            $u = $m.Groups[1].Value -replace '&amp;', '&' -replace '&page=[^&]*', ''
            if ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
            $cleanU = Get-CleanUrl $u
            
            # --- THE MAGIC OVERRIDE ---
            # If ForceRedownload is False AND history contains it, skip.
            # If ForceRedownload is True, it ignores history and adds it to the queue anyway!
            if (-not $ForceRedownload -and $Global:DownloadHistory.Contains($cleanU)) {
                continue
            }

            if (-not $FoundPosts.Contains($cleanU)) { 
                $FoundPosts.Add($cleanU) 
            }
        }
    }
}

Write-Host "`nFound $($FoundPosts.Count) target posts." -ForegroundColor Yellow

Invoke-WithFileLock "DownloadList" {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $ExistingLines = if (Test-Path $ListFile) { Get-Content $ListFile -Encoding UTF8 } else { @("# DC Manga Downloader List", "", "[manual_urls]", "", "[automatic_urls]") }
    
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $ExistingLines) { $out.Add($line) }
    
    $idx = $out.IndexOf('[automatic_urls]')
    if ($idx -lt 0) { 
        $out.Add(""); $out.Add("[automatic_urls]"); $idx = $out.Count - 1 
    }
    
    if ($Config.KeepUnfinishedLinks -ne "True") {
        $idx++
        while ($out.Count -gt $idx) { $out.RemoveAt($idx) }
    } else {
        $idx = $out.Count
    }

    $AddedCount = 0
    foreach ($u in $FoundPosts) {
        if (-not $out.Contains($u)) {
            $out.Insert($idx, $u)
            $idx++
            $AddedCount++
        }
    }
    
    Write-FileAtomic -Path $ListFile -Content $out -Encoding $Enc
    Write-Host "Added $AddedCount new links to the queue." -ForegroundColor Green
}