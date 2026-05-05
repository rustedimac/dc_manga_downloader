# ==========================================
# DC Manga Search-Scanner
# ==========================================
param (
    [switch]$RunBoardCrawler
)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ProgressPreference = 'SilentlyContinue'

$RootDir = Split-Path $PSScriptRoot -Parent
$Downloader = Join-Path $PSScriptRoot "Start-Downloader.ps1"

. (Join-Path $PSScriptRoot "Get-Config.ps1")

function Get-ScannerConfig {
    $cfgPath = Join-Path $RootDir "config.yaml"
    if (-not (Test-Path $cfgPath)) { throw "config.yaml not found" }
    $ConfigObj = @{}
    Get-Content $cfgPath -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $ConfigObj[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
    return $ConfigObj
}
$Config = Get-ScannerConfig

$RequirePrefix = if ($Config.RequireTranslationPrefix -eq "False") { $false } else { $true }

$CsvFile = if ($Config.CatalogCsvPath) { Join-Path $RootDir ($Config.CatalogCsvPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\series_catalog.csv" }
$CsvDir = Split-Path $CsvFile
if (-not (Test-Path $CsvDir)) { New-Item -ItemType Directory -Path $CsvDir -Force | Out-Null }
$DsCsvFile = Join-Path $CsvDir "ds_results.csv"

$ListFile = if ($Config.DownloadListPath) { Join-Path $RootDir ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_list.txt" }
$ListDir = Split-Path $ListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }
if (-not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @("# DC Manga Downloader List", "", "[manual_urls]", "", "[automatic_urls]") | Set-Content -Path $ListFile -Encoding $Enc
}

$ScannerQueueFile = Join-Path $ListDir "scanner_queue.txt"

function Get-CleanUrl([string]$u) {
    $u = $u.Trim() -replace "^#RETRY ", "" -replace "^#DELETED ", ""
    if ($u -match 'gall\.dcinside\.com/board/view/') {
        $id = if ($u -match '[?&]id=([^&]+)') { $Matches[1] } else { "" }
        $no = if ($u -match '[?&]no=(\d+)') { $Matches[1] } else { "" }
        if ($id -and $no) { return "https://gall.dcinside.com/board/view/?id=$id&no=$no" }
    }
    return $u
}

$LogRank = @{ Error=0; Warn=1; Info=2; Verbose=3; DEBUG=3 }

function Initialize-SessionLog($Mode) {
    $BaseLogDir = Join-Path $RootDir ($Config.CrawlerLogDir -replace '^\.[\\/]', '')
    if ($Mode -eq "DeepSearch") { $dir = Join-Path $BaseLogDir "deep_search"; $prefix = "ds_scanner" } 
    elseif ($Mode -eq "BoardSeries") { $dir = Join-Path $BaseLogDir "series_scanner"; $prefix = "series_scanner" } 
    else { $dir = Join-Path $BaseLogDir "csv_browse"; $prefix = "csv_browse" }

    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    
    $ActiveLog = Join-Path $dir ($prefix + "_logs.json")
    if (Test-Path $ActiveLog) {
        $MaxLogMB = if ($Config.CrawlerLogMaxMB) { [double]$Config.CrawlerLogMaxMB } else { 10 }
        if (((Get-Item $ActiveLog).Length / 1MB) -ge $MaxLogMB) {
            $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $RotatedLog = Join-Path $dir ($prefix + "_$Timestamp.json")
            Rename-Item -Path $ActiveLog -NewName (Split-Path $RotatedLog -Leaf)
            $MaxLogFiles = if ($Config.CrawlerLogMaxFiles) { [int]$Config.CrawlerLogMaxFiles } else { 5 }
            $Files = Get-ChildItem -Path $dir -Filter "*.json" | Sort-Object CreationTime
            while ($Files.Count -gt $MaxLogFiles) {
                Remove-Item -Path $Files[0].FullName -Force
                $Files = Get-ChildItem -Path $dir -Filter "*.json" | Sort-Object CreationTime
            }
        }
    }
    $script:SessionLogFile = $ActiveLog; $script:RunId = [guid]::NewGuid().ToString()
}

function Write-ScannerLog {
    param($Level,$Component,$Event,$Data=@{})
    if ($null -eq $Config.CrawlerLogLevel) { $Config.CrawlerLogLevel = "Verbose" }
    if ($LogRank[$Level] -gt $LogRank[$Config.CrawlerLogLevel]) { return }

    $entry = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString("o"); run_id = $script:RunId; level = $Level; component = $Component; event = $Event }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { $entry | ConvertTo-Json -Compress -Depth 5 -EscapeHandling EscapeHtml } else { $entry | ConvertTo-Json -Compress -Depth 5 }
    $CleanJson = $Json -replace '\\u0026', '&'
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $CleanJson | Add-Content -LiteralPath $script:SessionLogFile -Encoding $Enc
}

function Write-Log {
    param($Level,$Component,$Message,$Data=@{})
    $Color = switch($Level) { "Error" {"Red"} "Warn" {"Yellow"} "Info" {"White"} default {"Gray"} }
    Write-Host "[$Level][$Component] $Message" -ForegroundColor $Color
    Write-ScannerLog $Level $Component $Message $Data
}

function Clear-ScannerQueue {
    if (-not (Test-Path $ScannerQueueFile)) { return }
    Invoke-WithFileLock "DownloadList" {
        $lines = @( (Get-Content -LiteralPath $ScannerQueueFile -Encoding UTF8 -ErrorAction SilentlyContinue) ); $retries = @()
        foreach ($l in $lines) { if ($l.Trim() -match "^#RETRY") { $retries += ($l.Trim() -replace "^#RETRY ", "") } }
        if ($retries.Count -gt 0) {
            $mainLines = if (Test-Path $ListFile) { Get-Content $ListFile -Encoding UTF8 } else { @("[manual_urls]", "", "[automatic_urls]") }
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($m in $mainLines) { $out.Add($m) }
            $idx = $out.IndexOf('[manual_urls]')
            if ($idx -lt 0) { $out.Add(""); $out.Add("[manual_urls]"); $idx = $out.Count - 1 }
            $idx++
            foreach ($r in $retries) { if ($out -notcontains $r) { $out.Insert($idx++, $r) } }
            $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
            Write-FileAtomic -Path $ListFile -Content $out -Encoding $Enc
        }
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        Write-FileAtomic -Path $ScannerQueueFile -Content @() -Encoding $Enc
    }
}

function Check-ScannerQueue {
    if (-not (Test-Path $ScannerQueueFile)) { return }
    $lines = @( (Get-Content -LiteralPath $ScannerQueueFile -Encoding UTF8 -ErrorAction SilentlyContinue) ) | Where-Object { $_.Trim().Length -gt 0 }
    if ($null -eq $lines -or $lines.Count -eq 0) { return }

    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "     [!] Unfinished Downloads Detected    " -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "You have unfinished download jobs from a previous session."
    Write-Host "Would you like to resume downloading them before proceeding?"
    Write-Host "(If 'N', pending jobs are deleted, but failed jobs move to Manual queue.)`n" -ForegroundColor Gray
    $choice = Read-Host "Resume downloads? (Y/N)"
    
    if ($choice -match "^[Yy]") {
        & $Downloader -RunScannerQueue
        Clear-ScannerQueue
    } else {
        Write-Host "Cleaning up queue..." -ForegroundColor Gray
        Clear-ScannerQueue
        Invoke-WithFileLock "DownloadList" {
            $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
            Write-FileAtomic -Path $ScannerQueueFile -Content @() -Encoding $Enc
        }
    }
}

function Add-ToScannerDownloadList($Urls) {
    Clear-ScannerQueue
    Invoke-WithFileLock "DownloadList" {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $UniqueUrls = @($Urls | Sort-Object -Unique)
        Write-FileAtomic -Path $ScannerQueueFile -Content $UniqueUrls -Encoding $Enc
    }
}

# --- ALIAS REGISTRY ---
$AliasFile = Join-Path $RootDir "Data\series_aliases.csv"

function Get-AliasMap {
    $map = @{}
    if (Test-Path $AliasFile) { 
        $aliases = @(Import-Csv $AliasFile -Encoding UTF8)
        foreach ($a in $aliases) { $map[$a.OriginalName] = $a.OperatorName } 
    }
    return $map
}

function Register-Alias([string]$OrigName) {
    if ([string]::IsNullOrWhiteSpace($OrigName)) { return }
    $map = Get-AliasMap
    if (-not $map.ContainsKey($OrigName)) {
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
    Write-Log "Verbose" "Extractor" "Extracting [시리즈] block" @{ url=$Url }
    
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
                    $ExtraLinks += $exUrl 
                }
            }
        }
        $ExtraLinksStr = ($ExtraLinks | Sort-Object -Unique) -join " | "
        
        $Parsed = Parse-TitleToSeries $RawTitle

        if ($PostContent -notmatch '\[시리즈\]') { 
            if ($FinalTitle -eq "") { $FinalTitle = $Parsed.Series }
            $exists = $false
            foreach ($ext in $AllChapters) { if ($ext.Url -eq $CurrentUrl) { $exists = $true; break } }
            if (-not $exists) {
                # [NEW] OriginalTitle (원본 제목) 저장 컬럼 추가
                $AllChapters.Add([PSCustomObject]@{ Series = $FinalTitle; Chapter = $RawTitle; OriginalTitle = $RawTitle; Url = $CurrentUrl; Date = $Date; ExtraLinks = $ExtraLinksStr; Status = "" })
            }
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
                if ($title -notmatch '^[\.\s\-_]*$' -and $JunkList -notcontains $title) {
                    $LastValidTitle = $title
                }
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
            if ($LastValidTitle -ne "UNKNOWN") {
                $FinalTitle = $LastValidTitle
            } else {
                $FinalTitle = $Parsed.Series
            }
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
            $OldestUrl = $null
            $MinNum = [double]::MaxValue
            $FoundRealNum = $false
            
            foreach ($c in $AllChapters) {
                if ($c.Chapter -match '(\d*\.\d+|\d+)') {
                    $num = [double]$Matches[1]
                    if ($num -lt $MinNum) { $MinNum = $num; $OldestUrl = $c.Url; $FoundRealNum = $true }
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

# [NEW] CSV에 OriginalTitle 컬럼 추가
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
    Write-Log "Verbose" "CSV" "Merging series map into CSV"
    
    $existing = @()
    if (Test-Path $CsvFile) { 
        $existing = @(Import-Csv $CsvFile -Encoding UTF8 | ForEach-Object { Normalize-CsvRow $_ }) 
    }
    
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
                Write-Log "Verbose" "CSV" "New chapter added ($($c.Chapter))" @{ series=$c.Series; chapter=$c.Chapter }
            } else {
                $updated = $false
                if ($c.Date -and -not $match.Date) { $match.Date = $c.Date; $updated = $true }
                if ($c.ExtraLinks -and -not $match.ExtraLinks) { $match.ExtraLinks = $c.ExtraLinks; $updated = $true }
                if ($c.Status -and -not $match.Status) { $match.Status = $c.Status; $updated = $true }
                
                # [NEW] 구형 CSV 데이터 자동 마이그레이션 (원본 제목 분리)
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
        Invoke-WithFileLock "SeriesCsv" {
            Write-FileAtomic -Path $CsvFile -Content $out -Encoding $Enc -AsCsv
        }
    }
    return $added
}

function Read-SeriesCsv {
    if (-not (Test-Path $CsvFile)) { return @() }
    return @(Import-Csv $CsvFile -Encoding UTF8 | ForEach-Object { Normalize-CsvRow $_ })
}

function Invoke-AliasManager {
    $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== SERIES ALIAS MANAGER ===" -ForegroundColor Cyan
        
        $map = Get-AliasMap
        $keys = @($map.Keys | Sort-Object)
        
        if ($keys.Count -eq 0) {
            Write-Host " (Registry is currently empty.)" -ForegroundColor DarkGray
            Write-Host "`nPress Enter to return..." -ForegroundColor Gray
            $null = Read-Host
            return
        }

        $slice = $keys | Select-Object -Skip ($page*15) -First 15
        
        for ($i=0; $i -lt $slice.Count; $i++) {
            $orig = $slice[$i]
            $oper = $map[$orig]
            $color = if ($orig -ne $oper) { "Green" } else { "Gray" }
            Write-Host "[$i] $orig -> $oper" -ForegroundColor $color
        }

        Write-Host "`n(n)ext | (p)rev | (#) edit alias | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        
        if ($k -eq 'b') { return }
        if ($k -eq 'n' -and ($page*15+15) -lt $keys.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^\d+$' -and [int]$k -lt $slice.Count) {
            $orig = $slice[[int]$k]
            Write-Host "`nOriginal Series Name: $orig" -ForegroundColor Cyan
            Write-Host "Current Folder Name: $($map[$orig])" -ForegroundColor Cyan
            $new = Read-Host "Enter New Folder Name (Alias)"
            if (-not [string]::IsNullOrWhiteSpace($new)) {
                $map[$orig] = $new
                $out = $map.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ OriginalName=$_; OperatorName=$map[$_] } }
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                Invoke-WithFileLock "Aliases" { 
                    Write-FileAtomic -Path $AliasFile -Content $out -Encoding $Enc -AsCsv 
                }
            }
        }
    }
}

function Invoke-CatalogHealthCheck {
    Initialize-SessionLog "Misc"
    Clear-Host
    Write-Host "=== Catalog Health Check & Metadata Fetcher ===" -ForegroundColor Cyan
    
    $rows = Read-SeriesCsv
    if (-not $rows) { Write-Host "Catalog is empty." -ForegroundColor Red; Start-Sleep -Seconds 2; return }
    
    $Pending = $rows | Where-Object { ([string]::IsNullOrWhiteSpace($_.Date)) -and ($_.Status -ne "DELETED") }
    
    if ($Pending.Count -eq 0) {
        Write-Host "Catalog is fully up to date! No missing metadata found." -ForegroundColor Green
        Start-Sleep -Seconds 2; return
    }
    
    Write-Host "Found $($Pending.Count) entries needing metadata check." -ForegroundColor Yellow
    Write-Host ">>> Press 'Q' at any time to safely stop and save progress. <<<`n" -ForegroundColor Magenta
    
    $Headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"; "Referer" = "https://gall.dcinside.com/" }
    $UpdatedCount = 0
    
    for ($i = 0; $i -lt $Pending.Count; $i++) {
        if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Health Check interrupted by user. Saving..." -ForegroundColor Yellow; break } }
        
        $target = $Pending[$i]
        Write-Host "[$($i+1)/$($Pending.Count)] Checking: $($target.Series) - $($target.Chapter)..." -NoNewline
        
        try {
            $Response = Invoke-WebRequest -Uri $target.Url -Headers $Headers -UseBasicParsing -TimeoutSec 15
            $FinalUrl = $Response.BaseResponse.ResponseUri.AbsoluteUri
            
            if ($FinalUrl -match "error/deleted" -or $FinalUrl -match "derror") {
                $target.Status = "DELETED"; Write-Host " DELETED" -ForegroundColor Red; $UpdatedCount++
            } else {
                $Html = $Response.Content
                $Date = if ($Html -match '<span class="gall_date" title="([^"]+)">') { $Matches[1] } else { "" }
                
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
                        if ($exUrl -notmatch 'dcinside\.(com|co\.kr)|\$\{link\}|pickmaker\.com|rankify\.best|naver\.com/adbiz') { $ExtraLinks += $exUrl }
                    }
                }
                $ExtraLinksStr = ($ExtraLinks | Sort-Object -Unique) -join " | "
                
                if ($Date) { $target.Date = $Date; $UpdatedCount++ }
                if ($ExtraLinksStr) { $target.ExtraLinks = $ExtraLinksStr; $UpdatedCount++ }
                Write-Host " OK" -ForegroundColor Green
            }
        } catch {
            $ErrorUri = if ($_.Exception.Response) { $_.Exception.Response.ResponseUri.AbsoluteUri } else { "" }
            $StatusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode } else { "" }
            if ($StatusCode -eq "NotFound" -or $StatusCode -eq 404 -or $ErrorUri -match "error/deleted" -or $ErrorUri -match "derror") {
                $target.Status = "DELETED"; Write-Host " DELETED" -ForegroundColor Red; $UpdatedCount++
            } else { Write-Host " ERROR ($($_.Exception.Message))" -ForegroundColor DarkGray }
        }
        Start-Sleep -Seconds 2
    }
    
    if ($UpdatedCount -gt 0) {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        Invoke-WithFileLock "SeriesCsv" { Write-FileAtomic -Path $CsvFile -Content $rows -Encoding $Enc -AsCsv }
        Write-Host "`nHealth Check finished. Saved updates to catalog." -ForegroundColor Green
    } else { Write-Host "`nHealth Check finished. No updates were made." -ForegroundColor Gray }
    Write-Host "Press Enter to return..." -ForegroundColor Gray; $null = Read-Host
}

function Start-KeywordSearch {
    Initialize-SessionLog "DeepSearch"
    Clear-Host
    Write-Host "=== Keyword Deep-Search Scanner ===" -ForegroundColor Cyan
    $Keyword = Read-Host "Enter Manga Title/Keyword to search"
    if ([string]::IsNullOrWhiteSpace($Keyword)) { return }
    
    $EncodedKeyword = [uri]::EscapeDataString($Keyword)
    $BaseUrl = $Config.BoardUrl
    $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    $FoundResults = @(); $CurrentSearchPos = ""
    Write-Host ">>> Press 'Q' at any time to stop searching and view results. <<<" -ForegroundColor Magenta

    $StopSearch = $false
    $MaxBlocks = if ($Config.KeywordSearchMaxBlocks) { [int]$Config.KeywordSearchMaxBlocks } else { 300 }
    
    for ($Block = 1; $Block -le $MaxBlocks; $Block++) {
        if ($StopSearch) { break }
        $NextSearchPos = ""; $BlockHasNext = $false
        for ($Page = 1; $Page -le 10; $Page++) {
            if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Search interrupted by user." -ForegroundColor Yellow; $StopSearch = $true; break } }
            
            Write-Host -NoNewline "`r    -> Searching Block $Block/$MaxBlocks | Page $Page/10 | Found: $($FoundResults.Count) chapters...   "
            
            $TargetUrl = "$BaseUrl&page=$Page&s_type=search_subject_memo&s_keyword=$EncodedKeyword"
            if ($CurrentSearchPos) { $TargetUrl += "&search_pos=$CurrentSearchPos" }
            try { $Html = (Invoke-WebRequest -Uri $TargetUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content } catch { continue }
            if (-not $Html) { continue }
            [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
                $T = ($_.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if (-not $RequirePrefix -or $T -match '번역\)|\[번역\]') {
                    if ($T -notmatch '모음|추천|번역추|요청|질문|념글') {
                        $U = ($_.Groups[1].Value -replace '&amp;', '&' -replace '^/board', 'https://gall.dcinside.com/board')
                        if ($U -notmatch '^http') { $U = "https://gall.dcinside.com" + $U }
                        $CleanU = Get-CleanUrl $U
                        if ($null -eq ($FoundResults | Where-Object { $_.Url -eq $CleanU })) { $FoundResults += [PSCustomObject]@{ Title = $T; Url = $CleanU; Downloaded = $false } }
                    }
                }
            }
            if ($Html -match 'search_pos=(-\d+)[^>]*>(?:<[^>]+>)*다음 검색') { $NextSearchPos = $Matches[1]; $BlockHasNext = $true }
            if ($Html -notmatch "page=$($Page+1)") { break }
        }
        if ($BlockHasNext -and $NextSearchPos -ne $CurrentSearchPos) { $CurrentSearchPos = $NextSearchPos } else { break }
    }
    
    Write-Host "" # Newline after the progress finishes
    
    if ($FoundResults.Count) {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        Invoke-WithFileLock "DsResults" { Write-FileAtomic -Path $DsCsvFile -Content $FoundResults -Encoding $Enc -AsCsv }
        Write-Host "`nSearch finished. Opening Checklist..." -ForegroundColor Green
        Start-Sleep -Seconds 1; Browse-DsResults
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
    Write-Host "=== Board Series Scanner ===" -ForegroundColor Cyan
    $BaseUrl = $Config.BoardUrl
    $MaxPages = if ($Config.SeriesBrowserMaxPages) { [int]$Config.SeriesBrowserMaxPages } else { 10 }
    $FoundPosts = @(); $Headers = @{ "User-Agent" = "Mozilla/5.0"; "Referer" = "https://gall.dcinside.com/" }

    Write-Host ">>> Press 'Q' at any time to stop and save results. <<<" -ForegroundColor Magenta
    for ($p=1; $p -le $MaxPages; $p++) {
        if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Scanning interrupted. Moving to extraction..." -ForegroundColor Yellow; break } }
        Write-Host "Scanning Board Page $p/$MaxPages..." -ForegroundColor Gray
        try { $Html = (Invoke-WebRequest "$BaseUrl&page=$p" -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content } catch { continue }
        [regex]::Matches($Html, '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
            $T = $_.Groups[2].Value
            if (-not $RequirePrefix -or $T -match '번역\)|\[번역\]') {
                $u = $_.Groups[1].Value -replace '&amp;', '&' -replace '&page=[^&]*', ''
                if ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
                $cleanU = Get-CleanUrl $u
                if ($FoundPosts -notcontains $cleanU) { $FoundPosts += $cleanU }
            }
        }
    }
    Write-Host "`nProcessing $($FoundPosts.Count) series candidates..." -ForegroundColor Yellow
    $Total = 0; $idx = 1
    foreach ($u in $FoundPosts) {
        if ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Q') { Write-Host "`n[!] Scan interrupted. Saving progress..." -ForegroundColor Yellow; break } }
        Write-Host "[$idx/$($FoundPosts.Count)] checking series block..." -ForegroundColor Gray
        try { $h = (Invoke-WebRequest $u -Headers $Headers -UseBasicParsing -TimeoutSec 10).Content; $s = Extract-SeriesFromHtml $h $u; if($s.Count){ $Total += Merge-SeriesCsv $s } } catch {}
        $idx++
    }
    Write-Host "`nBoard Scanner finished. Merged $Total new series links into the CSV Catalog." -ForegroundColor Green
    if (-not $AutoRun) { Write-Host "Press Enter to return..." -ForegroundColor Gray; $null = Read-Host }
}

function Start-CsvSeriesBrowser {
    Initialize-SessionLog "Misc"
    $rows = Read-SeriesCsv; if (-not $rows) { Write-Host "Catalog is empty." -ForegroundColor Red; Start-Sleep -Seconds 2; return }
    $map = Get-AliasMap
    $groups = $rows | Group-Object Series | Sort-Object Name; $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== CSV SERIES BROWSER ===" -ForegroundColor Cyan
        $slice = $groups | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) { 
            $origName = $slice[$i].Name
            $dispName = if ($map.ContainsKey($origName)) { "$($map[$origName]) [$origName]" } else { $origName }
            Write-Host "[$i] $dispName" 
        }
        Write-Host "`n(n)ext page | (p)revious page | (#) to select series | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'n' -and ($page*10+10) -lt $groups.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^\d+$' -and [int]$k -lt $slice.Count) { Browse-CsvSeriesChapters $slice[[int]$k] $map }
    }
}

function Browse-CsvSeriesChapters($Group, $map) {
    $origName = $Group.Name
    $dispName = if ($map.ContainsKey($origName)) { $map[$origName] } else { $origName }
    $chs = $Group.Group; $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== $dispName ===" -ForegroundColor Cyan
        $slice = $chs | Select-Object -Skip ($page*10) -First 10
        for ($i=0;$i -lt $slice.Count;$i++) { Write-Host "[$i] $($slice[$i].Chapter)" }
        Write-Host "`n(n)ext page | (p)revious page | (d)ownload all | (#) to download | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'd') { 
            Add-ToScannerDownloadList $chs.Url; & $Downloader -RunScannerQueue; Clear-ScannerQueue; continue 
        }
        if ($k -eq 'n' -and ($page*10+10) -lt $chs.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^\d+$' -and [int]$k -lt $slice.Count) { 
            Add-ToScannerDownloadList @($slice[[int]$k].Url); & $Downloader -RunScannerQueue; Clear-ScannerQueue; continue 
        }
    }
}

function Browse-DsResults {
    if (-not (Test-Path $DsCsvFile)) { return }
    $rows = @(Import-Csv $DsCsvFile -Encoding UTF8); $page = 0
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
        if ($k -eq 'd') {
            $undownloaded = $rows | Where-Object { $_.Downloaded -ne 'True' }
            if ($undownloaded) {
                $urls = @($undownloaded | Select-Object -ExpandProperty Url)
                Add-ToScannerDownloadList $urls; & $Downloader -RunScannerQueue; Clear-ScannerQueue
                foreach ($item in $undownloaded) { $item.Downloaded = $true }
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                Invoke-WithFileLock "DsResults" { Write-FileAtomic -Path $DsCsvFile -Content $rows -Encoding $Enc -AsCsv }
            } else { Write-Host "All items are already downloaded!" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            continue
        }
        if ($k -match '^\d+$' -and [int]$k -lt $slice.Count) { 
            $idx = ($page * 10) + [int]$k; $target = $rows[$idx]
            if ($target.Downloaded -ne 'True') {
                Add-ToScannerDownloadList @($target.Url); & $Downloader -RunScannerQueue; Clear-ScannerQueue
                $target.Downloaded = $true; $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                Invoke-WithFileLock "DsResults" { Write-FileAtomic -Path $DsCsvFile -Content $rows -Encoding $Enc -AsCsv }
            } else { Write-Host "Already downloaded!" -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            continue 
        }
    }
}

function Start-ExternalLinkBrowser {
    Initialize-SessionLog "Misc"
    Clear-Host
    Write-Host "=== EXTERNAL LINK BROWSER ===" -ForegroundColor Cyan
    $rows = Read-SeriesCsv | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ExtraLinks) }
    
    if ($rows.Count -eq 0) {
        Write-Host "No external links found in the catalog." -ForegroundColor Yellow
        Start-Sleep -Seconds 2; return
    }

    $page = 0
    while ($true) {
        Clear-Host
        Write-Host "=== CHAPTERS WITH EXTERNAL LINKS ===" -ForegroundColor Cyan
        $slice = $rows | Select-Object -Skip ($page*15) -First 15
        for ($i=0; $i -lt $slice.Count; $i++) {
            Write-Host "[$i] $($slice[$i].Series) - $($slice[$i].Chapter)"
            Write-Host "    -> $($slice[$i].ExtraLinks)" -ForegroundColor Cyan
        }
        Write-Host "`n(n)ext | (p)rev | (#) open link in browser | (b)ack" -ForegroundColor Gray
        $k = Read-Host "Input"
        if ($k -eq 'b') { return }
        if ($k -eq 'n' -and ($page*15+15) -lt $rows.Count) { $page++; continue }
        if ($k -eq 'p' -and $page -gt 0) { $page--; continue }
        if ($k -match '^\d+$' -and [int]$k -lt $slice.Count) {
            $links = $slice[[int]$k].ExtraLinks -split ' \| '
            foreach ($l in $links) { Start-Process $l.Trim() }
        }
    }
}

# =========================
# Startup Check
# =========================
Check-ScannerQueue

if ($RunBoardCrawler) { Start-BoardSeriesCrawler -AutoRun; exit }

do {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "     DC Manga Search / Series Scanner     " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1. Keyword Deep-Search"
    Write-Host " 2. Extract Series from Single URL"
    Write-Host " 3. Series Scanner"
    Write-Host " 4. Series CSV Browser"
    Write-Host " 5. Verify Catalog Health & Fetch Metadata"
    Write-Host " 6. Manage Series Aliases (Operator Names)"
    Write-Host " 7. Browse External Links"
    Write-Host " 0. Return to Main Menu"
    Write-Host "==========================================" -ForegroundColor Cyan
    $choice = Read-Host "Select option"
    switch ($choice) {
        "1" { Start-KeywordSearch }
        "2" { Start-SingleUrlExtraction }
        "3" { Start-BoardSeriesCrawler }
        "4" { Start-CsvSeriesBrowser }
        "5" { Invoke-CatalogHealthCheck }
        "6" { Invoke-AliasManager }
        "7" { Start-ExternalLinkBrowser }
        "0" { exit }
    }
} while ($true)