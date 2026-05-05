param (
    [switch]$RunAuto,
    [switch]$RunManualQueue,
    [switch]$RunScannerQueue
)

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

# ==========================================
# [NEW] 화이트리스트 & 블랙리스트 파싱 (스마트 정규식 변환)
# ==========================================
$Global:ExtWhitelistPattern = "telegra\.ph|kone\.gg" # 기본값
if (-not [string]::IsNullOrWhiteSpace($Config.ExternalWhitelist)) {
    $wList = ($Config.ExternalWhitelist -split '\|' | Where-Object { $_.Trim() -ne "" } | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|'
    if ($wList) { $Global:ExtWhitelistPattern = $wList }
}

$Global:ExtBlacklistPattern = ""
if (-not [string]::IsNullOrWhiteSpace($Config.ExternalBlacklist)) {
    $Global:ExtBlacklistPattern = ($Config.ExternalBlacklist -split '\|' | Where-Object { $_.Trim() -ne "" } | ForEach-Object { [regex]::Escape($_.Trim()) }) -join '|'
}
# ==========================================

$script:ForceRedownload = $Config.ForceRedownload -eq "True"

$MainListFile = if ($Config.DownloadListPath) { Join-Path $RootDir ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_list.txt" }
$ListDir = Split-Path $MainListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }

$ListFile = $MainListFile
if ($RunScannerQueue) { $ListFile = Join-Path $ListDir "scanner_queue.txt" }

if ($ListFile -eq $MainListFile -and -not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @("# DC Manga Downloader List", "", "[manual_urls]", "", "[automatic_urls]") | Set-Content -Path $ListFile -Encoding $Enc
} elseif ($ListFile -ne $MainListFile -and -not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @() | Set-Content -Path $ListFile -Encoding $Enc
}

# --- ALIAS REGISTRY ---
$AliasFile = Join-Path $RootDir "Data\series_aliases.csv"
$Global:AliasMap = @{}
if (Test-Path $AliasFile) {
    $aliases = @(Import-Csv $AliasFile -Encoding UTF8)
    foreach ($a in $aliases) { $Global:AliasMap[$a.OriginalName] = $a.OperatorName }
}

function Register-Alias([string]$OrigName) {
    if ([string]::IsNullOrWhiteSpace($OrigName)) { return }
    if (-not $Global:AliasMap.ContainsKey($OrigName)) {
        $Global:AliasMap[$OrigName] = $OrigName
        Invoke-WithFileLock "Aliases" {
            $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
            $NewRow = [PSCustomObject]@{ OriginalName=$OrigName; OperatorName=$OrigName }
            if (Test-Path $AliasFile) {
                $All = @(Import-Csv $AliasFile -Encoding UTF8)
                $All += $NewRow
                Write-FileAtomic -Path $AliasFile -Content ($All | Sort-Object OriginalName) -AsCsv -Encoding $Enc
            } else {
                Write-FileAtomic -Path $AliasFile -Content @($NewRow) -AsCsv -Encoding $Enc
            }
        }
    }
}

function Get-OperatorName([string]$detectedName) {
    Register-Alias $detectedName
    if ($Global:AliasMap.ContainsKey($detectedName)) { return $Global:AliasMap[$detectedName] }
    return $detectedName
}

# --- HISTORY & CATALOG ---
$HistoryFile = if ($Config.DownloadHistoryPath) { Join-Path $RootDir ($Config.DownloadHistoryPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_history.csv" }
$Global:DownloadHistory = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $HistoryFile) {
    $histData = @(Import-Csv $HistoryFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Url) })
    foreach ($h in $histData) { $Global:DownloadHistory.Add($h.Url.Trim()) | Out-Null }
}

$CsvFile = if ($Config.CatalogCsvPath) { Join-Path $RootDir ($Config.CatalogCsvPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\series_catalog.csv" }
$Global:CatalogLookup = @{}
if (Test-Path $CsvFile) {
    try {
        $catData = @(Import-Csv $CsvFile -Encoding UTF8)
        foreach ($c in $catData) {
            if (-not [string]::IsNullOrWhiteSpace($c.Url)) { $Global:CatalogLookup[$c.Url.Trim()] = $c }
        }
    } catch {}
}

if ($Config.UseProxy -eq "False") {
    $NullProxy = New-Object System.Net.WebProxy
    [System.Net.HttpWebRequest]::DefaultWebProxy = $NullProxy
    [System.Net.WebRequest]::DefaultWebProxy = $NullProxy
} else {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebProxy]::new()
}

$script:SessionSuccessCount = 0; $script:SessionFailureCount = 0; $script:SessionSkipCount = 0; $script:SessionTotalBytes = 0; $script:SessionExtraLinks = @()

$DownloadLocation = if ($Config.DownloadDir -and [System.IO.Path]::IsPathRooted($Config.DownloadDir)) { $Config.DownloadDir } else { Join-Path $RootDir ($Config.DownloadDir -replace '^\.\\', '') }
$LogFile = if ($Config.LogPath -and [System.IO.Path]::IsPathRooted($Config.LogPath)) { $Config.LogPath } else { Join-Path $RootDir ($Config.LogPath -replace '^\.\\', '') }

if (Test-Path $LogFile) {
    $MaxLogMB = if ($Config.CrawlerLogMaxMB) { [double]$Config.CrawlerLogMaxMB } else { 10 }
    if (((Get-Item $LogFile).Length / 1MB) -ge $MaxLogMB) {
        $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $RotatedLog = ($LogFile -replace '\.json$', "_$Timestamp.json")
        Rename-Item -Path $LogFile -NewName (Split-Path $RotatedLog -Leaf)
        $Files = Get-ChildItem -Path (Split-Path $LogFile) -Filter "*.json" | Sort-Object CreationTime
        $MaxLogFiles = if ($Config.CrawlerLogMaxFiles) { [int]$Config.CrawlerLogMaxFiles } else { 5 }
        while ($Files.Count -gt $MaxLogFiles) { Remove-Item -Path $Files[0].FullName -Force; $Files = Get-ChildItem -Path (Split-Path $LogFile) -Filter "*.json" | Sort-Object CreationTime }
    }
}

$LogLevel = $Config.LogLevel; $DoDNSRepair = $Config.DNSAutoRepair -eq "True"; $SleepTime = if ($Config.RateLimitSeconds) { [double]$Config.RateLimitSeconds } else { 2.5 }
$RenameSequential = $Config.RenameFilesSequential -eq "True"; $MaxThreads = if ($Config.MaxConcurrentDownloads) { [int]$Config.MaxConcurrentDownloads } else { 15 }
if ($MaxThreads -lt 1) { $MaxThreads = 1 }

$script:ShowVisualBar = if ($Config.ShowProgressBar -eq "False") { $false } else { $true }
if ($script:ShowVisualBar) { $ProgressPreference = 'SilentlyContinue' }

function Get-SafeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Unknown" }
    $Safe = ($Name -replace '<[^>]+>', '').Replace('?', '？').Replace(':', '：').Replace('*', '＊').Replace('|', '｜').Replace('"', '＂')
    $IllegalChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $ExtraChars = if ($Config.CustomStripChars) { $Config.CustomStripChars } else { "" }
    $Regex = "[" + [regex]::Escape($IllegalChars + $ExtraChars) + "\x00-\x1F]"
    $Final = (($Safe -replace $Regex, '_') -replace '\s+', ' ').Trim().Trim(".")
    
    if ([string]::IsNullOrWhiteSpace($Final)) { return "Unknown_Title" }
    return $Final
}

function Write-Log {
    param($Status, $Message, $Url="N/A", $Manga="N/A", $Chapter="N/A", $ImageNum="N/A", $TotalImages="N/A", $Size="N/A")
    if ($LogLevel -eq "Error" -and $Status -notin @("ERROR", "SESSION", "REPAIR", "FLAGGED")) { return }
    $LogEntry = [ordered]@{ Timestamp=(Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status=$Status; Manga=$Manga; Chapter=$Chapter; ImageNum=$ImageNum; TotalImages=$TotalImages; Size=$Size; Message=$Message; Url=$Url }
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml } else { $LogEntry | ConvertTo-Json -Compress }
    $Json = $Json.Replace('\u0026', '&').Replace('\u003c', '<').Replace('\u003e', '>')
    try {
        $Client = New-Object System.IO.Pipes.NamedPipeClientStream(".", "DCMangaLogger", [System.IO.Pipes.PipeDirection]::Out); $Client.Connect(150)
        $Writer = New-Object System.IO.StreamWriter($Client, [System.Text.Encoding]::UTF8); $Writer.WriteLine($Json); $Writer.Flush(); $Client.Dispose()
    } catch { 
        $LogDirNode = Split-Path $LogFile
        if (-not (Test-Path $LogDirNode)) { New-Item -ItemType Directory -Path $LogDirNode -Force | Out-Null }
        $Json | Add-Content -LiteralPath $LogFile -Encoding UTF8 
    }
}

function Show-VisualProgress([int]$Current, [int]$Total) {
    if (-not $script:ShowVisualBar) { return }
    $Percent = [Math]::Floor(($Current / $Total) * 100); $Width = 30; $Done = [Math]::Floor(($Current / $Total) * $Width); $Left = $Width - $Done
    $Bar = "[" + ("#" * $Done) + ("-" * $Left) + "]"
    Write-Host -NoNewline "`r    Progress: $Bar $Percent% ($Current/$Total images)    "
}

function Parse-TitleToSeries([string]$RawTitle) {
    $T = $RawTitle -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
    
    $IsDanpyeon = ($T -match '단편')
    $FallbackChapter = if ($IsDanpyeon) { "단편" } else { "General" }

    $T = $T -replace '^(?:\[?번역\]?\s*\)?|재업\)?|딸깍\)?|\[?단편\]?\s*\)?|<단편>\s*|\(단편\)\s*)\s*', ''
    $T = $T -replace '\(.*?(?:完|완결|끝).*?\)$', '' 

    $ChapterPattern = '(?i)((?:\d+권\s*)?(?:#\d+|\(\s*\d+_\d+\s*\)|(?:Part|LIFE|Season|Session)\s*\d+(?:\s*,\s*\d+)*|[<\[\(][^>\]\)]*[화편권]\s*\d+[>\]\)]|\d[\d\.\-~_]*(?:\s*[화편권])?(?:(?:\s*[,&＆\+]\s*|\s+)\d[\d\.\-~_]*(?:\s*[화편권])?)*\s*[화편권](?:\s*[\-\+]\s*\d+)?|\d+\s*~\s*\d+(?:\s*[화편권])?|\d+(?:\s*,\s*\d+)*(?:\s*(?:完|완결|끝))?(?=\s*(?:[\[\(<][^\]\)>]*[\]\)>]\s*)*$)|(?:최종|마지막)\s*[화편])(?:\s*(?:오마케|보너스|외전|특별|특별편|번외|번외편|단편|총집편))?)'

    while ($T -match '(?s)\s*([\[\(<][^\]\)>]*[\]\)>])\s*$') {
        $ParenText = $Matches[1].Trim()
        $InsideText = $ParenText.Substring(1, $ParenText.Length - 2).Trim()
        
        if ($ParenText -match "^${ChapterPattern}$" -or $InsideText -match "^${ChapterPattern}$") {
            break 
        } else {
            $T = $T.Substring(0, $T.Length - $Matches[0].Length)
        }
    }
    
    $Manga = $T
    $Chapter = $FallbackChapter
    
    $matchesList = [regex]::Matches($T, $ChapterPattern)
    if ($matchesList.Count -gt 0) {
        $lastMatch = $matchesList[$matchesList.Count - 1]
        
        $PossibleManga = $T.Substring(0, $lastMatch.Index).Trim()
        
        $PossibleManga = [regex]::Replace($PossibleManga, '[\(\[<][^)>\]]*[가-힣a-zA-Z]+[^)>\]]*[\)\]>]', '')
        $PossibleManga = $PossibleManga -replace '[-\s:\[\(<]+$', '' 
        $PossibleManga = $PossibleManga -replace '\s+\d+$', ''
        $PossibleManga = $PossibleManga.Trim()
        
        if (-not [string]::IsNullOrWhiteSpace($PossibleManga)) { $Manga = $PossibleManga }
        
        $RawChapter = $lastMatch.Value.Trim()
        $RawChapter = $RawChapter -replace '^[<\[\(]', '' -replace '[>\]\)]$', '' 
        $Chapter = $RawChapter
    } else {
        $Manga = [regex]::Replace($Manga, '[\(\[<][^)>\]]*[가-힣a-zA-Z]+[^)>\]]*[\)\]>]', '')
        $Manga = $Manga -replace '\s+\d+$', ''
        $Manga = $Manga.Trim()
    }
    
    return @{ Series = $Manga; Chapter = $Chapter }
}

function Extract-SeriesFromHtml {
    param([string]$Html, [string]$Url)
    
    $AllChapters = New-Object System.Collections.Generic.List[PSObject]
    $VisitedHtmlUrls = @{}
    $CurrentUrl = Get-CleanUrl $Url
    $CurrentHtml = $Html
    $FinalTitle = ""

    while ($true) {
        $VisitedHtmlUrls[$CurrentUrl] = $true
        
        $RawTitle = "Unknown"
        if ($CurrentHtml -match '(?i)<meta\s+property="og:title"\s+content="([^"]+)"') {
            $RawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
        } elseif ($CurrentHtml -match '(?i)<title>([^<]+)</title>') {
            $RawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
        } elseif ($CurrentHtml -match '(?s)<span[^>]*class="title_subject"[^>]*>(.*?)</span>') {
            $RawTitle = $Matches[1].Trim()
        }
        $RawTitle = ($RawTitle -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>')

        $Date = if ($CurrentHtml -match '<span class="gall_date" title="([^"]+)">') { $Matches[1] } else { "" }
        
        $PostContent = ""
        $bStart = $CurrentHtml.IndexOf('class="writing_view_box"')
        if ($bStart -ge 0) {
            $bEnd = $CurrentHtml.IndexOf('class="updown_area"', $bStart)
            if ($bEnd -lt 0) { $bEnd = $CurrentHtml.IndexOf('class="appending_file_box"', $bStart) }
            if ($bEnd -lt 0) { $bEnd = $CurrentHtml.Length }
            $bLen = $bEnd - $bStart
            if ($bLen -gt 0) { $PostContent = $CurrentHtml.Substring($bStart, $bLen) }
        }

        $ExtraLinks = @()
        if ($PostContent) {
            [regex]::Matches($PostContent, '(?i)href="(https?://[^"]+)"') | ForEach-Object { 
                $exUrl = $_.Groups[1].Value
                if ($exUrl -notmatch 'dcinside\.(com|co\.kr)|\$\{link\}|pickmaker\.com|rankify\.best|naver\.com/adbiz') {
                    # [블랙리스트 체크 적용]
                    if ([string]::IsNullOrWhiteSpace($Global:ExtBlacklistPattern) -or ($exUrl -notmatch $Global:ExtBlacklistPattern)) {
                        $ExtraLinks += $exUrl 
                    }
                }
            }
        }
        $ExtraLinksStr = ($ExtraLinks | Sort-Object -Unique) -join " | "
        
        $Parsed = Parse-TitleToSeries $RawTitle

        if ($PostContent -notmatch '\[시리즈\]') { 
            if ($FinalTitle -eq "") { $FinalTitle = $Parsed.Series }
            $exists = $false
            foreach ($ext in $AllChapters) { if ($ext.Url -eq $CurrentUrl) { $exists = $true; break } }
            if (-not $exists) { $AllChapters.Add([PSCustomObject]@{ Series = $FinalTitle; Chapter = $RawTitle; OriginalTitle = $RawTitle; Url = $CurrentUrl; Date = $Date; ExtraLinks = $ExtraLinksStr; Status = "" }) }
            break 
        }
        
        $parts = $PostContent -split '\[시리즈\]'
        if ($parts.Count -lt 2) { break }

        $batch = @()
        $batch += [PSCustomObject]@{ Series = ""; Chapter = $RawTitle; OriginalTitle = $RawTitle; Url = $CurrentUrl; Date = $Date; ExtraLinks = $ExtraLinksStr; Status = "" }
        $LastValidTitle = "UNKNOWN"

        for ($i = 1; $i -lt $parts.Count; $i++) {
            $after = $parts[$i]
            if ($after -match '(?s)^\s*(.*?)(?:<a|<br|·)') { 
                $title = ($Matches[1] -replace '<[^>]+>', '').Trim() 
                $JunkList = if ($Config.JunkSeriesTitles) { $Config.JunkSeriesTitles -split '\|' | ForEach-Object { $_.Trim() } } else { @("ㅇㅇ", "1", "UNKNOWN") }
                if ($title -notmatch '^[\.\s\-_]*$' -and $JunkList -notcontains $title) { $LastValidTitle = $title }
            }

            $chapterMatches = [regex]::Matches($after, '<a[^>]+href="([^"]+)"[^>]*>\s*·\s*([^<]+)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($m in $chapterMatches) { 
                $u = Get-CleanUrl $m.Groups[1].Value.Trim()
                $LinkText = $m.Groups[2].Value.Trim()
                if ($u -ne $CurrentUrl) {
                    $batch += [PSCustomObject]@{ Series = ""; Chapter = $LinkText; OriginalTitle = $LinkText; Url = $u; Date = ""; ExtraLinks = ""; Status = "" } 
                } else {
                    $batch[0].Chapter = $LinkText
                    $batch[0].OriginalTitle = $LinkText
                }
            }
        }

        if ($FinalTitle -eq "") {
            if ($LastValidTitle -ne "UNKNOWN") { $FinalTitle = $LastValidTitle } else { $FinalTitle = $Parsed.Series }
        }
        Register-Alias $FinalTitle

        foreach ($c in $batch) {
            $c.Series = $FinalTitle
            $exists = $false
            foreach ($ext in $AllChapters) { 
                if ($ext.Url -eq $c.Url) { 
                    $exists = $true
                    if (-not $ext.Date -and $c.Date) { $ext.Date = $c.Date }
                    if (-not $ext.ExtraLinks -and $c.ExtraLinks) { $ext.ExtraLinks = $c.ExtraLinks }
                    break 
                } 
            }
            if (-not $exists) { $AllChapters.Add($c) }
        }

        if ($Config.DaisyChainSeries -eq "True") {
            $OldestUrl = $null; $MinNum = [double]::MaxValue; $FoundRealNum = $false
            foreach ($c in $AllChapters) {
                if ($c.Chapter -match '(\d*\.\d+|\d+)') {
                    $num = [double]$Matches[1]; if ($num -lt $MinNum) { $MinNum = $num; $OldestUrl = $c.Url; $FoundRealNum = $true }
                }
            }
            if ($null -eq $OldestUrl -and $AllChapters.Count -gt 0) { $OldestUrl = $AllChapters[0].Url }

            if ($OldestUrl -and -not $VisitedHtmlUrls.ContainsKey($OldestUrl)) {
                $HoppingTxt = if ($FoundRealNum) { "$($MinNum)화" } else { "Older Posts" }
                Write-Host "    -> [Daisy Chain] Hopping to bridge series gaps: $HoppingTxt" -ForegroundColor Magenta
                try {
                    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }
                    $CurrentUrl = $OldestUrl
                    $CurrentHtml = (Invoke-WebRequest $CurrentUrl -Headers $Headers -UseBasicParsing -TimeoutSec 10).Content
                    Start-Sleep -Milliseconds 400
                    continue
                } catch { break }
            } else { break }
        } else { break }
    }

    if ($AllChapters.Count -gt 0) {
        Write-Host "    -> Database Linked: $FinalTitle ($($AllChapters.Count) chapters)" -ForegroundColor Green
        return @{ $FinalTitle = $AllChapters.ToArray() }
    } else { return @{} }
}

function Normalize-CsvRow($row) {
    return [PSCustomObject]@{
        Series = if ($row.Series) { $row.Series } else { "Unknown" }
        Chapter = if ($row.Chapter) { $row.Chapter } else { "General" }
        OriginalTitle = if ($row.OriginalTitle) { $row.OriginalTitle } else { "" }
        Url = if ($row.Url) { Get-CleanUrl $row.Url } else { "" }
        Date = if ($row.Date) { $row.Date } else { "" }
        ExtraLinks = if ($row.ExtraLinks) { $row.ExtraLinks } else { "" }
        Status = if ($row.Status) { $row.Status } else { "" }
    }
}

function Merge-SeriesCsv($SeriesMap) {
    $existing = @()
    if (Test-Path $CsvFile) { $existing = @(Import-Csv $CsvFile -Encoding UTF8 | ForEach-Object { Normalize-CsvRow $_ }) }
    
    $out = @($existing); $added = 0
    foreach ($t in $SeriesMap.Keys) {
        foreach ($c in $SeriesMap[$t]) {
            $match = $out | Where-Object Url -eq $c.Url
            if (-not $match) { 
                
                $ParsedOriginal = Parse-TitleToSeries $c.Chapter
                $FinalChap = $ParsedOriginal.Chapter
                $ParsedSeries = $ParsedOriginal.Series

                $IsCollectionOneShot = ($FinalChap -eq "단편" -and $ParsedSeries -ne $c.Series)

                if ($FinalChap -eq "General" -or $IsCollectionOneShot) {
                    $cleaned = $ParsedSeries
                    $FinalChap = if ($cleaned.Length -gt 60) { $cleaned.Substring(0, 30) + "..." + $cleaned.Substring($cleaned.Length - 27) } else { $cleaned }
                }
                
                $c.OriginalTitle = $c.Chapter
                $c.Chapter = $FinalChap
                $out += Normalize-CsvRow $c; $added++
            } else {
                $updated = $false
                if ($c.Date -and -not $match.Date) { $match.Date = $c.Date; $updated = $true }
                if ($c.ExtraLinks -and -not $match.ExtraLinks) { $match.ExtraLinks = $c.ExtraLinks; $updated = $true }
                if ($c.Status -and -not $match.Status) { $match.Status = $c.Status; $updated = $true }
                
                if (-not $match.OriginalTitle) { 
                    $match.OriginalTitle = $match.Chapter
                    $ParsedOld = Parse-TitleToSeries $match.Chapter
                    $FinalOldChap = $ParsedOld.Chapter
                    $OldSeries = $ParsedOld.Series
                    $IsCol = ($FinalOldChap -eq "단편" -and $OldSeries -ne $match.Series)
                    if ($FinalOldChap -eq "General" -or $IsCol) {
                        $FinalOldChap = if ($OldSeries.Length -gt 60) { $OldSeries.Substring(0, 30) + "..." + $OldSeries.Substring($OldSeries.Length - 27) } else { $OldSeries }
                    }
                    $match.Chapter = $FinalOldChap
                    $updated = $true 
                }

                if ($updated) { $added++ }
            }
        }
    }
    if ($added -gt 0) { 
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        Invoke-WithFileLock "SeriesCsv" { Write-FileAtomic -Path $CsvFile -Content $out -Encoding $Enc -AsCsv }
    }
    return $added
}


function Process-Post($RawUrl, $BaseDir) {
    $PostStartTime = Get-Date; $CleanUrl = Get-CleanUrl $RawUrl

    # [FIX] 함수 외부에서 이미 설정된 $script:ForceRedownload 변수를 직접 사용하여 스코프 오류 해결
    $IsForceMode = ($script:ForceRedownload -eq $true)
    
    if (-not $IsForceMode -and $Global:DownloadHistory.Contains($CleanUrl)) {
        Write-Host "  [SKIP] URL exists in Download History: $CleanUrl" -ForegroundColor DarkGray
        $script:SessionSkipCount++
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $UpdatedLines = @((Get-Content $ListFile -Encoding UTF8) | Where-Object { $_.Trim() -ne $RawUrl -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" -and $_.Trim() -ne "#DELETED $CleanUrl" })
                Write-FileAtomic -Path $ListFile -Content $UpdatedLines -Encoding $Enc
            }
        }
        return
    } elseif ($IsForceMode -and $Global:DownloadHistory.Contains($CleanUrl)) {
        Write-Host "  [FORCE] Bypassing history check for: $CleanUrl" -ForegroundColor Cyan
    }
    $PostSuccess = 0; $PostFail = 0; $PostSkip = 0; $PostBytes = 0
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }
    $MaxRetries = 3; $RetryCount = 0; $Html = $null
    $IsDeleted = $false
    
    # [NEW] 접속 세션을 유지하기 위한 쿠키 저장소 생성
    $DCWebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    
    while ($RetryCount -le $MaxRetries -and $null -eq $Html) {
        try {
            # WebSession을 함께 넘겨서 쿠키를 받아옵니다
            $Response = Invoke-WebRequest -Uri $CleanUrl -Headers $Headers -WebSession $DCWebSession -UseBasicParsing -TimeoutSec 20
            $FinalUrl = $Response.BaseResponse.ResponseUri.AbsoluteUri
            if ($FinalUrl -match "error/deleted" -or $FinalUrl -match "derror") {
                $IsDeleted = $true; break
            }
            $Html = $Response.Content
        } catch {
            if ($_.Exception.Response) {
                $StatusCode = $_.Exception.Response.StatusCode
                $ErrorUri = $_.Exception.Response.ResponseUri.AbsoluteUri
                if ($StatusCode -eq "NotFound" -or $StatusCode -eq 404 -or $ErrorUri -match "error/deleted" -or $ErrorUri -match "derror") {
                    $IsDeleted = $true; break
                }
            }
            $RetryCount++
            if ($DoDNSRepair -and ($_.Exception.Message -match "could not be resolved|No such host")) {
                Write-Host "  ! DNS Error detected. Flushing DNS and waiting..." -ForegroundColor Yellow
                ipconfig /flushdns | Out-Null; Start-Sleep -Seconds 10
            } else { Start-Sleep -Seconds 3 }
        }
    }

    if ($IsDeleted -or $null -eq $Html) { 
        $Prefix = if ($IsDeleted) { "#DELETED" } else { "#RETRY" }
        $Color  = if ($IsDeleted) { "Red" } else { "Magenta" }
        $Msg    = if ($IsDeleted) { "Post permanently deleted. Added #DELETED flag." } else { "Failed to load HTML. Added #RETRY flag." }

        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Lines = (Get-Content $ListFile -Encoding UTF8)
                if ($Lines -notcontains "$Prefix $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $UpdatedLines = @($Lines | Where-Object { $_.Trim() -ne $RawUrl -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" -and $_.Trim() -ne "#DELETED $CleanUrl" })
                    $UpdatedLines += "$Prefix $CleanUrl"
                    Write-FileAtomic -Path $ListFile -Content $UpdatedLines -Encoding $Enc
                }
            }
        }
        Write-Host "  [FLAGGED] $Msg" -ForegroundColor $Color
        
        if ($IsDeleted) {
            $CatMatch = $Global:CatalogLookup[$CleanUrl]
            if ($CatMatch) {
                $CatMatch.Status = "DELETED"
                Merge-SeriesCsv @{ ($CatMatch.Series) = @($CatMatch) } | Out-Null
            }
            Invoke-WithFileLock "DownloadHistory" {
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $NewEntry = [PSCustomObject]@{ Url = $CleanUrl; Series = "DELETED"; Chapter = "DELETED"; DownloadedDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
                $existingHist = @()
                if (Test-Path $HistoryFile) { $existingHist = @(Import-Csv $HistoryFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Url) }) }
                if (-not ($existingHist | Where-Object { $_.Url -eq $CleanUrl })) {
                    $existingHist += $NewEntry
                    Write-FileAtomic -Path $HistoryFile -Content $existingHist -Encoding $Enc -AsCsv
                    $Global:DownloadHistory.Add($CleanUrl) | Out-Null
                }
            }
        }
        return 
    }

    $Manga = "Unknown"
    $Chapter = "General"
    $CatalogMatch = $Global:CatalogLookup[$CleanUrl]
    $FinalExtraLinks = ""

    if ($null -ne $CatalogMatch) {
        $Manga = $CatalogMatch.Series
        $RawTarget = if ($CatalogMatch.OriginalTitle) { $CatalogMatch.OriginalTitle } else { $CatalogMatch.Chapter }
        $Chapter = $RawTarget
        
        Write-Host "  [CATALOG MATCH] Mapped to database: $Manga ($($CatalogMatch.Chapter))" -ForegroundColor DarkGray
        
        $CurrentDate = if ($Html -match '<span class="gall_date" title="([^"]+)">') { $Matches[1] } else { "" }
        $PostContent = ""
        $bStart = $Html.IndexOf('class="writing_view_box"')
        if ($bStart -ge 0) {
            $bEnd = $Html.IndexOf('class="updown_area"', $bStart)
            if ($bEnd -lt 0) { $bEnd = $Html.IndexOf('class="appending_file_box"', $bStart) }
            if ($bEnd -lt 0) { $bEnd = $Html.Length }
            $bLen = $bEnd - $bStart
            if ($bLen -gt 0) { $PostContent = $Html.Substring($bStart, $bLen) }
        }

        $ExtraLinks = @()
        if ($PostContent) {
            [regex]::Matches($PostContent, '(?i)href="(https?://[^"]+)"') | ForEach-Object { 
                $exUrl = $_.Groups[1].Value
                if ($exUrl -notmatch 'dcinside\.(com|co\.kr)|\$\{link\}|pickmaker\.com|rankify\.best|naver\.com/adbiz') {
                    if ([string]::IsNullOrWhiteSpace($Global:ExtBlacklistPattern) -or ($exUrl -notmatch $Global:ExtBlacklistPattern)) {
                        $ExtraLinks += $exUrl 
                    }
                }
            }
        }
        $ExtraLinksStr = ($ExtraLinks | Sort-Object -Unique) -join " | "
        $FinalExtraLinks = if ($ExtraLinksStr) { $ExtraLinksStr } else { $CatalogMatch.ExtraLinks }

        if ($ExtraLinksStr) {
            $script:SessionExtraLinks += [PSCustomObject]@{ Manga = $Manga; Chapter = $CatalogMatch.Chapter; Links = $ExtraLinksStr }
            Write-Host "  [INFO] Found Extra External Links in Body: $ExtraLinksStr" -ForegroundColor Cyan
        }

        if (($CurrentDate -and -not $CatalogMatch.Date) -or ($ExtraLinksStr -and -not $CatalogMatch.ExtraLinks)) {
            $CatalogMatch.Date = if ($CurrentDate) { $CurrentDate } else { $CatalogMatch.Date }
            $CatalogMatch.ExtraLinks = if ($ExtraLinksStr) { $ExtraLinksStr } else { $CatalogMatch.ExtraLinks }
            Merge-SeriesCsv @{ ($Manga) = @($CatalogMatch) } | Out-Null
        }
    } else {
        Write-Host "  [CATALOG] Analyzing post data for Database..." -ForegroundColor Gray
        $Extracted = Extract-SeriesFromHtml $Html $CleanUrl
        if ($Extracted.Keys.Count -gt 0) {
            $Manga = $Extracted.Keys[0]; $ChapObj = $Extracted[$Manga] | Where-Object Url -eq $CleanUrl
            
            $RawTarget = if ($ChapObj) { $ChapObj.OriginalTitle } else { "General" }
            $Chapter = $RawTarget
            $FinalExtraLinks = if ($ChapObj) { $ChapObj.ExtraLinks } else { "" }
            
            if ($ChapObj -and $ChapObj.ExtraLinks) {
                $script:SessionExtraLinks += [PSCustomObject]@{ Manga = $Manga; Chapter = $ChapObj.Chapter; Links = $ChapObj.ExtraLinks }
                Write-Host "  [INFO] Found Extra External Links in Body: $($ChapObj.ExtraLinks)" -ForegroundColor Cyan
            }
            Merge-SeriesCsv $Extracted | Out-Null
            foreach ($c in $Extracted[$Manga]) { $Global:CatalogLookup[$c.Url] = $c }
        } else {
            $HtmlRawTitle = ""
            if ($Html -match '(?i)<meta\s+property="og:title"\s+content="([^"]+)"') {
                $HtmlRawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
            } elseif ($Html -match '(?i)<title>([^<]+)</title>') {
                $HtmlRawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
            } elseif ($Html -match '(?s)<span[^>]*class="title_subject"[^>]*>(.*?)</span>') {
                $HtmlRawTitle = $Matches[1].Trim()
            }
            $HtmlRawTitle = ($HtmlRawTitle -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>')
            
            $Parsed = Parse-TitleToSeries $HtmlRawTitle
            $Manga = $Parsed.Series; $Chapter = $HtmlRawTitle

            $PostContent = ""
            $bStart = $Html.IndexOf('class="writing_view_box"')
            if ($bStart -ge 0) {
                $bEnd = $Html.IndexOf('class="updown_area"', $bStart)
                if ($bEnd -lt 0) { $bEnd = $Html.IndexOf('class="appending_file_box"', $bStart) }
                if ($bEnd -lt 0) { $bEnd = $Html.Length }
                $bLen = $bEnd - $bStart
                if ($bLen -gt 0) { $PostContent = $Html.Substring($bStart, $bLen) }
            }
            $ExtraLinks = @()
            if ($PostContent) {
                [regex]::Matches($PostContent, '(?i)href="(https?://[^"]+)"') | ForEach-Object { 
                    $exUrl = $_.Groups[1].Value
                    if ($exUrl -notmatch 'dcinside\.(com|co\.kr)|\$\{link\}|pickmaker\.com|rankify\.best|naver\.com/adbiz') {
                        if ([string]::IsNullOrWhiteSpace($Global:ExtBlacklistPattern) -or ($exUrl -notmatch $Global:ExtBlacklistPattern)) {
                            $ExtraLinks += $exUrl 
                        }
                    }
                }
            }
            $FinalExtraLinks = ($ExtraLinks | Sort-Object -Unique) -join " | "
            
            if ($FinalExtraLinks) {
                $script:SessionExtraLinks += [PSCustomObject]@{ Manga = $Manga; Chapter = $Chapter; Links = $FinalExtraLinks }
                Write-Host "  [INFO] Found Extra External Links in Body: $FinalExtraLinks" -ForegroundColor Cyan
            }
        }
    }

    $OperatorManga = Get-OperatorName $Manga
    if ($OperatorManga -ne $Manga) { Write-Host "  [ALIAS] Override active: $OperatorManga" -ForegroundColor Cyan }

    $ParsedChapObj = Parse-TitleToSeries $Chapter
    $FolderChapter = $ParsedChapObj.Chapter
    $ParsedChapSeries = $ParsedChapObj.Series
    
    $IsCollectionOneShot = ($FolderChapter -eq "단편" -and $ParsedChapSeries -ne $OperatorManga -and $ParsedChapSeries -ne $Manga)

    if ($FolderChapter -eq "General" -or $IsCollectionOneShot) {
        $HtmlRawTitle = ""
        if ($Html -match '(?i)<meta\s+property="og:title"\s+content="([^"]+)"') {
            $HtmlRawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
        } elseif ($Html -match '(?i)<title>([^<]+)</title>') {
            $HtmlRawTitle = $Matches[1] -replace '\s*-\s*.*?갤러리\s*$', ''
        } elseif ($Html -match '(?s)<span[^>]*class="title_subject"[^>]*>(.*?)</span>') {
            $HtmlRawTitle = $Matches[1].Trim()
        }
        $HtmlRawTitle = ($HtmlRawTitle -replace '<[^>]+>', '').Replace('&amp;', '&').Replace('&lt;', '<').Replace('&gt;', '>')
        
        if ($HtmlRawTitle) { 
            $FallbackParsed = Parse-TitleToSeries $HtmlRawTitle
            $FolderChapter = $FallbackParsed.Chapter 
            
            $StillCollectionOneShot = ($FolderChapter -eq "단편" -and $FallbackParsed.Series -ne $OperatorManga -and $FallbackParsed.Series -ne $Manga)
            
            if ($FolderChapter -eq "General" -or $StillCollectionOneShot) {
                $CleanedTitle = $FallbackParsed.Series
                if ($CleanedTitle.Length -gt 60) {
                    $FolderChapter = $CleanedTitle.Substring(0, 30) + "..." + $CleanedTitle.Substring($CleanedTitle.Length - 27)
                } else {
                    $FolderChapter = $CleanedTitle
                }
            }
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($FolderChapter)) { $FolderChapter = "General" }

    $SafeManga   = Get-SafeName $OperatorManga
    $SafeChapter = Get-SafeName $FolderChapter
    
    $BaseTargetDir = Join-Path (Join-Path $BaseDir $SafeManga) $SafeChapter
    $TargetDir = $BaseTargetDir
    $DupeCounter = 1
    
    while ([System.IO.Directory]::Exists($TargetDir)) {
        $SourceFile = Join-Path $TargetDir "source.txt"
        if (Test-Path $SourceFile) {
            $ExistingUrls = Get-Content -LiteralPath $SourceFile -ErrorAction SilentlyContinue
            if ($ExistingUrls -contains $CleanUrl) { break }
        }
        $TargetDir = Join-Path (Join-Path $BaseDir $SafeManga) "$SafeChapter (중복 $DupeCounter)"
        $DupeCounter++
    }

    if (-not [System.IO.Directory]::Exists($TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }

    $SourceFile = Join-Path $TargetDir "source.txt"
    try {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $WriteUrl = $true
        if (Test-Path $SourceFile) {
            $ExistingUrls = Get-Content -LiteralPath $SourceFile -ErrorAction SilentlyContinue
            if ($ExistingUrls -contains $CleanUrl) { $WriteUrl = $false }
        }
        if ($WriteUrl) { Add-Content -LiteralPath $SourceFile -Value $CleanUrl -Encoding $Enc -ErrorAction Stop }
    } catch {}

    if (-not [string]::IsNullOrWhiteSpace($FinalExtraLinks)) {
        $ExtLinksFile = Join-Path $TargetDir "external_links.txt"
        try {
            $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
            $LinksArray = $FinalExtraLinks -split ' \| '
            $LinksArray | Set-Content -LiteralPath $ExtLinksFile -Encoding $Enc -Force
        } catch {}
    }

    Get-ChildItem -LiteralPath $TargetDir -File | Where-Object { $_.Extension -eq '.tmp' -or $_.Extension -eq '' } | Remove-Item -Force -ErrorAction SilentlyContinue 2>$null

    $FinalLinks = New-Object System.Collections.Generic.List[PSObject]; $HQ_Lookup = @{}; $AttachmentList = New-Object System.Collections.Generic.List[string]
    $AppIndex = $Html.IndexOf('class="appending_file"')
    if ($AppIndex -ge 0) {
        $AppEnd = $Html.IndexOf('</ul>', $AppIndex)
        if ($AppEnd -lt 0) { $AppEnd = $Html.Length }
        $AppLength = $AppEnd - $AppIndex
        if ($AppLength -gt 0) {
            [regex]::Matches($Html.Substring($AppIndex, $AppLength), '(?i)href="([^"]*(?:download\.php|/download/\?)[^"]*)"') | ForEach-Object {
                $u = $_.Groups[1].Value -replace '&amp;', '&'
                if ($u -match '^//') { $u = "https:" + $u } elseif ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
                $AttachmentList.Add($u); if ($u -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $HQ_Lookup[$Matches[1]] = $u }
            }
        }
    }

    $StartIndex = $Html.IndexOf('class="writing_view_box"')
    if ($StartIndex -lt 0) { $StartIndex = 0 }
    $EndIndex = $Html.IndexOf('class="updown_area"', $StartIndex)
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="appending_file_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="view_comment"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="reply_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.Length }
    
    $BodyLength = $EndIndex - $StartIndex
    if ($BodyLength -lt 0) { $BodyLength = 0 }
    
    $Body = $Html.Substring($StartIndex, $BodyLength)
    $BodyItems = New-Object System.Collections.Generic.List[PSObject]
    
    [regex]::Matches($Body, '(?i)<img[^>]+>') | ForEach-Object {
        $ImgStr = $_.Value
        if ($ImgStr -match '(?i)data-original="([^"]+)"' -or $ImgStr -match '(?i)src="([^"]+)"') {
            $BodyUrl = $Matches[1] -replace '&amp;', '&'
            if ($BodyUrl -match '^//') { $BodyUrl = "https:" + $BodyUrl } elseif ($BodyUrl -notmatch '^http') { $BodyUrl = "https://gall.dcinside.com" + $BodyUrl }
            if ($BodyUrl -match 'dccon\.php|blank\.gif|clear\.gif|spacer\.gif') { return }
            if ($BodyUrl -match 'dcinside\.(com|co\.kr)' -and $BodyUrl -notmatch 'viewimage\.php|dcimg\d+\.dcinside\.(com|co\.kr)|image\.dcinside\.(com|co\.kr)|download\.php') { return }
            $Hash = if ($BodyUrl -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $Matches[1] } else { $null }
            $FileNo = if ($ImgStr -match '(?i)data-(?:fileno|tempno)\s*=\s*["'']?([^"''\s>]+)') { $Matches[1] } else { $null }
            $BodyItems.Add((New-Object PSObject -Property @{ BodyUrl = $BodyUrl; Hash = $Hash; FileNo = $FileNo; ImgStr = $ImgStr }))
        }
    }

    $AttCount = $AttachmentList.Count; $BodyCount = $BodyItems.Count
    if ($AttCount -gt 0 -and $BodyCount -ge $AttCount -and $BodyCount -le ($AttCount + 2)) {
        for ($i=0; $i -lt $BodyCount; $i++) {
            if ($i -lt $AttCount) { $FinalLinks.Add((New-Object PSObject -Property @{ Url = $AttachmentList[$i]; Fallback = $BodyItems[$i].BodyUrl })) }
            else { $FinalLinks.Add((New-Object PSObject -Property @{ Url = $BodyItems[$i].BodyUrl; Fallback = $null })) }
        }
    } else {
        foreach ($item in $BodyItems) {
            $UpgradeUrl = $null
            if ($item.Hash -and $HQ_Lookup[$item.Hash]) { $UpgradeUrl = $HQ_Lookup[$item.Hash] }
            elseif ($item.FileNo -and $HQ_Lookup[$item.FileNo]) { $UpgradeUrl = $HQ_Lookup[$item.FileNo] }
            else {
                foreach ($key in $HQ_Lookup.Keys) {
                    if (($item.Hash -and $key -and ($item.Hash.StartsWith($key) -or $key.StartsWith($item.Hash))) -or ($item.FileNo -and $key -and ($item.FileNo.StartsWith($key) -or $key.StartsWith($item.FileNo)))) {
                        $UpgradeUrl = $HQ_Lookup[$key]; break
                    }
                }
            }
            $FinalLinks.Add((New-Object PSObject -Property @{ Url = if ($UpgradeUrl) { $UpgradeUrl } else { $item.BodyUrl }; Fallback = if ($UpgradeUrl) { $item.BodyUrl } else { $null } }))
        }
    }

    $TotalCount = $FinalLinks.Count
    if ($TotalCount -eq 0) { Write-Host "  ! No images found." -ForegroundColor Yellow }
    else {
        $FinalFolderName = Split-Path $TargetDir -Leaf
        Write-Host ">>> Processing: $OperatorManga ($FinalFolderName) | Images: $TotalCount" -ForegroundColor Cyan
        Write-Log "SESSION" "Starting Post Download" $CleanUrl $SafeManga $FinalFolderName "N/A" $TotalCount

        $RunningJobs = @()
        for ($i=0; $i -lt $TotalCount; $i++) {
            $Item = $FinalLinks[$i]; $BaseName = if ($RenameSequential) { (($i+1).ToString('000')) } else { "img_$($i+1)" }
            $ExistingFile = Get-ChildItem -LiteralPath $TargetDir -Filter "$BaseName.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

            if ($null -eq $ExistingFile) {
                while (($RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                    $Completed = $RunningJobs | Where-Object { $_.State -ne 'Running' }
                    if ($Completed) {
                        $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                        if ($null -ne $Results) {
                            foreach ($R in $Results) {
                                if ($null -ne $R -and $R.Success) { 
                                    $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $R.Size; $script:SessionTotalBytes += $R.Size
                                } elseif ($null -ne $R -and $null -ne $R.Success) { 
                                    $PostFail++; $script:SessionFailureCount++; 
                                }
                                Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
                            }
                        }
                        Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                        $RunningJobs = @($RunningJobs | Where-Object { $_.State -eq 'Running' })
                    }
                    Start-Sleep -Milliseconds 50 
                }
                
                $RunningJobs += Start-Job -Name "DCM_DL_$i" -ScriptBlock {
                    param($Target, $Dest, $Idx, $BaseName, $Headers, $Proxy)
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    if ($Proxy -eq "False") { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy }
                    $UrlsToTry = @($Target.Url); if ($Target.Fallback) { $UrlsToTry += $Target.Fallback }
                    foreach ($Url in $UrlsToTry) {
                        $H = $Headers.Clone(); if ($Url -notmatch "dcinside\.") { $H.Remove("Referer") }
                        for ($r=0; $r -lt 2; $r++) {
                            try {
                                $wc = New-Object System.Net.WebClient
                                foreach ($k in $H.Keys) { $wc.Headers.Add($k, $H[$k]) }
                                $wc.DownloadFile($Url, $Dest); $wc.Dispose()
                                $Stream = [System.IO.File]::OpenRead($Dest); $Bytes = New-Object byte[] 12; $Stream.Read($Bytes, 0, 12) | Out-Null; $Stream.Close()
                                $Hex = [System.BitConverter]::ToString($Bytes); $Ext = ".jpg" 
                                if ($Hex -match "^89-50-4E-47") { $Ext = ".png" } elseif ($Hex -match "^47-49-46-38") { $Ext = ".gif" } elseif ($Hex -match "^52-49-46-46") { $Ext = ".webp" }
                                $Final = "$BaseName$Ext"; Rename-Item -LiteralPath $Dest -NewName $Final -Force
                                return @{ Success=$true; Size=(Get-Item (Join-Path (Split-Path $Dest) $Final)).Length; Index=$Idx; FileName=$Final }
                            } catch { if (Test-Path $Dest) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue }; Start-Sleep -Seconds 1 }
                        }
                    }
                    return @{ Success=$false; Index=$Idx; ErrorMsg="Connection Dropped by Server" }
                } -ArgumentList $Item, (Join-Path $TargetDir "$BaseName.tmp"), ($i+1), $BaseName, $Headers, $Config.UseProxy
            } else { 
                $PostSkip++; $script:SessionSkipCount++
                Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
            }
        }

        while ($RunningJobs.Count -gt 0) {
            $Completed = $RunningJobs | Where-Object { $_.State -ne 'Running' }
            if ($Completed) {
                $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                if ($null -ne $Results) {
                    foreach ($R in $Results) {
                        if ($null -ne $R -and $R.Success) { 
                            $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $R.Size; $script:SessionTotalBytes += $R.Size 
                        } elseif ($null -ne $R -and $null -ne $R.Success) { 
                            $PostFail++; $script:SessionFailureCount++; 
                        }
                        Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
                    }
                }
                Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                $RunningJobs = @($RunningJobs | Where-Object { $_.State -eq 'Running' })
            } else { Start-Sleep -Milliseconds 50 }
        }
        if ($script:ShowVisualBar) { Write-Host "" }
    }

# ==========================================
    # [NEW] EXTERNAL LINK PIPELINE (Body + Mobile Comment Bypass)
    # ==========================================
    $UrlPattern = '(?i)((?:https?://|https?:\\/\\/)?(?:' + $Global:ExtWhitelistPattern + ')[a-zA-Z0-9\-\./\\\?=&_%]+)'
    $AllExternalLinks = @()

    # 1. 본문(Body) 스캔
    if (-not [string]::IsNullOrWhiteSpace($FinalExtraLinks)) {
        $rawLinks = $FinalExtraLinks -split '\|'
        foreach ($rl in $rawLinks) {
            $cleanLink = $rl.Trim()
            if ($cleanLink -match $Global:ExtWhitelistPattern) {
                if ($cleanLink -notmatch '^http') { $cleanLink = "https://" + $cleanLink }
                $AllExternalLinks += $cleanLink
            }
        }
    }

    # 2. 댓글(Comment) 스캔 - 사용자님의 [모바일 우회 로직] 적용
    $BoardId = if ($CleanUrl -match '[?&]id=([^&]+)') { $Matches[1] } else { $null }
    $PostNo = if ($CleanUrl -match '[?&]no=(\d+)') { $Matches[1] } else { $null }

    if ($BoardId -and $PostNo) {
        try {
            # 모바일 전용 엔드포인트 및 헤더 설정
            $MobCommentUrl = "https://m.dcinside.com/ajax/response-comment"
            $MobHeaders = @{
                "User-Agent"       = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
                "Referer"          = "https://m.dcinside.com/board/$BoardId/$PostNo"
                "X-Requested-With" = "XMLHttpRequest"
                "Content-Type"     = "application/x-www-form-urlencoded"
            }
            $MobBody = @{
                "id"           = $BoardId
                "no"           = $PostNo
                "comment_page" = "1"
            }

            # 모바일 API 호출 (토큰 없이 호출 가능)
            $CommentResponse = Invoke-RestMethod -Uri $MobCommentUrl -Method Post -Headers $MobHeaders -Body $MobBody -TimeoutSec 10
            
            # 응답 텍스트(HTML/JSON)에서 화이트리스트 링크 추출
            [regex]::Matches($CommentResponse, $UrlPattern) | ForEach-Object {
                $cLink = $_.Groups[1].Value -replace '\\/', '/'
                if ($cLink -notmatch '^http') { $cLink = "https://" + $cLink }
                $AllExternalLinks += $cLink
            }
        } catch {
            Write-Host "  [WARN] Failed to scan comments using Mobile Bypass." -ForegroundColor DarkGray
        }
    }

    $AllExternalLinks = $AllExternalLinks | Select-Object -Unique
	
    # 3. 외부 모듈 호출
    if ($AllExternalLinks.Count -gt 0) {
        Write-Host "  [DEBUG] Found $($AllExternalLinks.Count) Whitelisted link(s) in Body/Comments. Launching Module..." -ForegroundColor Magenta
        
        $ExtScript = Join-Path $PSScriptRoot "Invoke-ExternalDownloader.ps1"
        if (Test-Path $ExtScript) {
            $ExtResult = & $ExtScript -TelegraphLinks $AllExternalLinks -TargetDir $TargetDir -MaxThreads $MaxThreads -Headers $Headers -UseProxy $Config.UseProxy -RenameSequential $RenameSequential
            
            if ($null -ne $ExtResult) {
                $PostSuccess += $ExtResult.Success
                $PostFail += $ExtResult.Fail
                $PostBytes += $ExtResult.Bytes
                $script:SessionSuccessCount += $ExtResult.Success
                $script:SessionFailureCount += $ExtResult.Fail
                $script:SessionTotalBytes += $ExtResult.Bytes
                
                # 댓글에서 찾은 링크도 리포트에 표시
                foreach ($exLink in $AllExternalLinks) {
                    $script:SessionExtraLinks += [PSCustomObject]@{ Manga = $OperatorManga; Chapter = $FolderChapter; Links = $exLink }
                }
            }
        }
    else {
            Write-Host "  [WARN] Invoke-ExternalDownloader.ps1 not found at: $ExtScript" -ForegroundColor Red
        }
    }
    # ==========================================

    if ($PostFail -eq 0 -and ($PostSuccess -gt 0 -or $PostSkip -gt 0)) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $Lines = Get-Content $ListFile -Encoding UTF8
                $UpdatedLines = @($Lines | Where-Object { $_.Trim() -ne $RawUrl -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" -and $_.Trim() -ne "#DELETED $CleanUrl" })
                Write-FileAtomic -Path $ListFile -Content $UpdatedLines -Encoding $Enc
            }
        }
        Invoke-WithFileLock "DownloadHistory" {
            $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
            $NewEntry = [PSCustomObject]@{ Url = $CleanUrl; Series = $SafeManga; Chapter = $FinalFolderName; DownloadedDate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
            $existingHist = @()
            if (Test-Path $HistoryFile) { $existingHist = @(Import-Csv $HistoryFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Url) }) }
            if (-not ($existingHist | Where-Object { $_.Url -eq $CleanUrl })) {
                $existingHist += $NewEntry
                Write-FileAtomic -Path $HistoryFile -Content $existingHist -Encoding $Enc -AsCsv
                $Global:DownloadHistory.Add($CleanUrl) | Out-Null
            }
        }
        Write-Host "  [CLEANUP] Post finished. Added to History & Link removed." -ForegroundColor Gray
    } elseif ($PostFail -gt 0) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Lines = Get-Content $ListFile -Encoding UTF8
                if ($Lines -notcontains "#RETRY $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $UpdatedLines = @($Lines -replace [regex]::Escape($RawUrl), "#RETRY $CleanUrl")
                    Write-FileAtomic -Path $ListFile -Content $UpdatedLines -Encoding $Enc
                }
            }
        }
        Write-Host "  [FLAGGED] Post has missing images." -ForegroundColor Magenta
    }
    
    $PostEndTime = Get-Date; $PostElapsed = "{0:hh\:mm\:ss}" -f ($PostEndTime - $PostStartTime)
    $Summary = "Post Done: Saved: $PostSuccess | Failed: $PostFail | Skipped: $PostSkip | Size: $([Math]::Round($PostBytes/1MB, 2)) MB | Time: $PostElapsed"
    Write-Host "  $Summary`n" -ForegroundColor Gray
}

Clear-Host
$Urls = @()

if ($RunAuto -or $RunManualQueue -or $RunScannerQueue) {
    $Mode = "AUTO"
} else {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   DC Manga Downloader (Definitive Ver.)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1. Auto-grab from [manual_urls]"
    Write-Host " 2. Manual URL"
    Write-Host " 0. Return to Main Menu"
    $Choice = Read-Host "Select Option"
    
    if ($Choice -eq '0') { exit } elseif ($Choice -eq '1') { $Mode = "AUTO" } else { $Mode = "MANUAL" }
}

if ($Mode -eq "AUTO") {
    if (Test-Path $ListFile) {
        $cap = ($RunScannerQueue -eq $true)
        $TargetHeader = if ($RunAuto) { "\[automatic_urls\]" } else { "\[manual_urls\]" }
        
        if (Test-Path $ListFile) {
            $Lines = Get-Content $ListFile -Encoding UTF8
            if ($null -ne $Lines) {
                if ($Lines.Count -eq $null) { $Lines = @($Lines) }
                foreach($l in $Lines) {
                    if (-not $RunScannerQueue) {
                        if($l -match $TargetHeader) { $cap = $true } elseif($l -match "\[") { $cap = $false }
                    }
                    if($cap -and $l.Trim() -match "^http|^#RETRY") { $Urls += $l.Trim() } 
                }
            }
        }
    } else { Write-Host "Error: target list missing at $ListFile" -ForegroundColor Red; Pause; exit }
} else {
    Write-Host "Enter DCInside Post URL (or leave blank to cancel):" -ForegroundColor Gray
    $pasted = Read-Host "URL"
    if ($pasted -match "http") { $Urls += $pasted.Trim() } else { exit }
}

$script:SessionInterrupted = $true

try {
    $SessionStartTime = Get-Date; $idx = 1
    
    if ($Urls.Count -gt 0) {
        foreach ($Target in $Urls) {
            if ([string]::IsNullOrWhiteSpace($Target)) { continue }
            Write-Host "[$idx/$($Urls.Count)] Processing: $Target" -ForegroundColor Yellow
            Process-Post $Target $DownloadLocation
            if ($idx -lt $Urls.Count) { Start-Sleep -Seconds $SleepTime }
            $idx++
        }
    } else { Write-Host "No valid URLs found in queue." -ForegroundColor Yellow }
    
    $script:SessionInterrupted = $false
} finally {
    $SessionEndTime = Get-Date; $Elapsed = "{0:hh\:mm\:ss}" -f ($SessionEndTime - $SessionStartTime)

    if ($script:SessionInterrupted) {
        $OrphanJobs = Get-Job | Where-Object { $_.Name -like "DCM_DL_*" }
        if ($OrphanJobs) {
            $OrphanJobs | Stop-Job -ErrorAction SilentlyContinue 2>$null
            $Results = $OrphanJobs | Receive-Job -ErrorAction SilentlyContinue 2>$null
            if ($null -ne $Results) {
                foreach ($R in $Results) {
                    if ($null -ne $R -and $R.Success) { $script:SessionSuccessCount++; $script:SessionTotalBytes += $R.Size } elseif ($null -ne $R -and -not $R.Success) { $script:SessionFailureCount++ }
                }
            }
            $OrphanJobs | Remove-Job -Force -ErrorAction SilentlyContinue 2>$null
        }
    }

    $B = $script:SessionTotalBytes
    $Sz = if ($B -ge 1GB) { "$([Math]::Round($B/1GB, 2)) GB" } elseif ($B -ge 1MB) { "$([Math]::Round($B/1MB, 2)) MB" } else { "$([Math]::Round($B/1KB, 2)) KB" }
    
    $Stats = "Success: $($script:SessionSuccessCount) | Failed: $($script:SessionFailureCount) | Skipped: $($script:SessionSkipCount) | Size: $Sz | Time: $Elapsed"
    $EndStatus = if ($script:SessionInterrupted) { "INTERRUPTED" } else { "FINISHED" }
    
    if ($script:SessionExtraLinks -and $script:SessionExtraLinks.Count -gt 0) {
        Write-Host "`n========================================" -ForegroundColor Magenta
        Write-Host "   EXTRA EXTERNAL LINKS DETECTED" -ForegroundColor Magenta
        Write-Host "========================================" -ForegroundColor Magenta
        foreach ($ex in $script:SessionExtraLinks) {
            Write-Host " -> $($ex.Manga) ($($ex.Chapter)): $($ex.Links)" -ForegroundColor Cyan
        }
    }

    Write-Host "========================================" -ForegroundColor White
    Write-Host "DOWNLOADER $EndStatus" -ForegroundColor White
    Write-Host $Stats -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    
    if (-not $RunAuto -and -not $RunScannerQueue) { Pause }
}