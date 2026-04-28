# Start-Downloader.ps1
param ( [switch]$RunAuto )

# Ensure UTF8 for Korean character support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Shared Config Loader ---
. (Join-Path $PSScriptRoot "Get-Config.ps1")
$Config   = Get-Config
$ListFile = Join-Path $PSScriptRoot "download_list.txt"

# --- Proxy Settings ---
if ($Config.UseProxy -eq "False") {
    $NullProxy = New-Object System.Net.WebProxy
    [System.Net.HttpWebRequest]::DefaultWebProxy = $NullProxy
    [System.Net.WebRequest]::DefaultWebProxy     = $NullProxy
} else {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebProxy]::new()
}

# --- Session Metrics ---
$script:SessionSuccessCount = 0
$script:SessionFailureCount = 0
$script:SessionSkipCount    = 0
$script:SessionTotalBytes   = 0

# --- Settings ---
$DownloadLocation = if ($Config.DownloadDir -and [System.IO.Path]::IsPathRooted($Config.DownloadDir)) {
    $Config.DownloadDir
} else {
    Join-Path $PSScriptRoot ($Config.DownloadDir -replace '^\.\\', '')
}
$LogFile          = Join-Path $PSScriptRoot $Config.LogPath
$LogLevel         = $Config.LogLevel
$DoDNSRepair      = $Config.DNSAutoRepair -eq "True"
$SleepTime        = if ($Config.RateLimitSeconds) { [double]$Config.RateLimitSeconds } else { 2.5 }
$RenameSequential = $Config.RenameFilesSequential -eq "True"
$MaxThreads       = if ($Config.MaxConcurrentDownloads) { [int]$Config.MaxConcurrentDownloads } else { 3 }

if ($MaxThreads -lt 1) { $MaxThreads = 1 }

if ($Config.ShowProgressBar -eq "False") { $ProgressPreference = 'SilentlyContinue' }

# --- Constants (formerly magic numbers) ---
$PostTimeoutSec    = 20   # Timeout for fetching a post's HTML page
$ImageTimeoutSec   = 30   # Timeout for downloading a single image
$MaxPostRetries    = 3    # How many times to retry loading a post page
$MaxImageRetries   = 3    # How many times to retry a failed image download
$ImageRetryWaitSec = 2    # Seconds to wait between image retry attempts
$PostRetryWaitSec  = 3    # Seconds to wait between post page retry attempts
$DNSWaitSec        = 5    # Seconds to wait after a DNS flush
$JobPollMs         = 100  # Milliseconds to wait when polling running jobs
$LogPipeTimeoutMs  = 150  # Milliseconds to wait for the logger named pipe
$JobNamePrefix     = "DCM_DL_"  # Unique prefix for all background jobs (used for orphan cleanup)

# --- Sanitization ---
function Get-SafeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Unknown" }
    $Safe        = ($Name -replace '<[^>]+>', '').Replace('?','？').Replace(':','：').Replace('*','＊').Replace('|','｜').Replace('"','＂')
    $IllegalChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $Extra       = if ($Config.CustomStripChars) { $Config.CustomStripChars } else { "" }
    $Regex       = "[" + [regex]::Escape($IllegalChars + $Extra) + "\x00-\x1F]"
    $Final       = (($Safe -replace $Regex, '_') -replace '\s+', ' ').Trim().Trim(".")
    if ([string]::IsNullOrWhiteSpace($Final)) { return "Unknown_Title" }
    return $Final
}

# --- Logging ---
function Write-Log([string]$Status, [string]$Message, [string]$Url = "N/A", [string]$Manga = "N/A", [string]$Chapter = "N/A", [string]$ImgNum = "N/A", [string]$Total = "N/A", [string]$Size = "N/A") {
    if ($LogLevel -eq "Error" -and $Status -notin @("ERROR","SESSION","REPAIR","FLAGGED")) { return }

    $LogEntry = [ordered]@{
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Status      = $Status
        Manga       = $Manga
        Chapter     = $Chapter
        ImageNum    = $ImgNum
        TotalImages = $Total
        Size        = $Size
        Message     = $Message
        Url         = $Url
    }

    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) {
        $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml
    } else {
        $LogEntry | ConvertTo-Json -Compress
    }
    $Json = $Json.Replace('\u0026','&').Replace('\u003c','<').Replace('\u003e','>')

    try {
        $Client = New-Object System.IO.Pipes.NamedPipeClientStream(".", "DCMangaLogger", 'Out')
        $Client.Connect($LogPipeTimeoutMs)
        $Writer = New-Object System.IO.StreamWriter($Client, [System.Text.Encoding]::UTF8)
        $Writer.WriteLine($Json); $Writer.Flush(); $Client.Dispose()
    } catch {
        $Json | Add-Content -LiteralPath $LogFile -Encoding UTF8
    }
}

# ===========================================================================
# PROCESS-POST HELPERS
# Each function below handles one clearly named responsibility.
# ===========================================================================

# --- Helper 1: Fetch the HTML for a post, with retry and DNS repair ---
function Get-PostHtml([string]$Url, [hashtable]$Headers) {
    $RetryCount = 0
    while ($RetryCount -le $MaxPostRetries) {
        try {
            $Resp = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec $PostTimeoutSec
            return $Resp.Content
        } catch {
            $RetryCount++
            if ($DoDNSRepair -and ($_.Exception.Message -match "resolved|host")) {
                Write-Host "  ! DNS Error. Flushing..." -ForegroundColor Yellow
                ipconfig /flushdns | Out-Null
                Start-Sleep -Seconds $DNSWaitSec
            } else {
                Start-Sleep -Seconds $PostRetryWaitSec
            }
        }
    }
    return $null
}

# --- Helper 2: Parse the manga title and chapter number from the post HTML ---
function Get-PostTitleParts([string]$Html) {
    $RawTitle   = if ($Html -match '<span[^>]*class="title_subject"[^>]*>(.*?)</span>') { $Matches[1].Trim() } else { "Unknown" }
    $CleanTitle = $RawTitle -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&'
    $CleanTitle = $CleanTitle -replace '^번역\)\s*','' -replace '^\s*\[?번역\]?\s*','' -replace '\s*\([^)]*\)$',''
    $CleanTitle = $CleanTitle.Trim().Trim(".")

    $Manga   = $CleanTitle
    $Chapter = "General"

    if ($CleanTitle -match '^(.*?)\s+([\(<\[]?[\d\.\-~,&＆\s]+화?[\)>\]]?)$') {
        $Manga   = $Matches[1].Trim()
        $Chapter = $Matches[2].Trim()
    } elseif ($CleanTitle -match '^(.*?)([\d\.\-~,&＆]+화)$') {
        $Manga   = $Matches[1].Trim()
        $Chapter = $Matches[2].Trim()
    }

    return @{ Manga = $Manga; Chapter = $Chapter }
}

# --- Helper 3: Build the high-quality attachment URL dictionary from the attachment box ---
function Get-AttachmentDictionary([string]$Html) {
    $Dict     = @{}
    $AppIndex = $Html.IndexOf('class="appending_file"')
    if ($AppIndex -lt 0) { return $Dict }

    $AppEnd  = $Html.IndexOf('</ul>', $AppIndex)
    if ($AppEnd -lt 0) { $AppEnd = $Html.Length }
    $AppHtml = $Html.Substring($AppIndex, $AppEnd - $AppIndex)

    $AttachLinks = [regex]::Matches($AppHtml, '(?i)href="([^"]*(?:download\.php|/download/\?)[^"]*)"')
    foreach ($L in $AttachLinks) {
        $AttUrl = $L.Groups[1].Value -replace '&amp;','&'
        if     ($AttUrl -match '^//')   { $AttUrl = "https:" + $AttUrl }
        elseif ($AttUrl -notmatch '^http') { $AttUrl = "https://gall.dcinside.com" + $AttUrl }

        if ($AttUrl -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') {
            $Dict[$Matches[1]] = $AttUrl
        }
    }
    return $Dict
}

# --- Helper 4: Extract ordered image URLs from the post body ---
function Get-ImageLinks([string]$Html, [hashtable]$HQ_Dictionary) {
    $FinalLinks = [ordered]@{}

    $StartIndex = $Html.IndexOf('class="writing_view_box"')
    if ($StartIndex -lt 0) { $StartIndex = 0 }

    $EndIndex = $Html.IndexOf('class="updown_area"', $StartIndex)
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="appending_file_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="reply_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.Length }

    $PostBodyHtml = $Html.Substring($StartIndex, $EndIndex - $StartIndex)
    $ImgNodes     = [regex]::Matches($PostBodyHtml, '(?i)<img[^>]+>')

    foreach ($Node in $ImgNodes) {
        $ImgStr = $Node.Value
        $ImgUrl = ""

        if     ($ImgStr -match '(?i)data-original="([^"]+)"') { $ImgUrl = $Matches[1] }
        elseif ($ImgStr -match '(?i)src="([^"]+)"')           { $ImgUrl = $Matches[1] }

        if (-not $ImgUrl) { continue }

        $ImgUrl = $ImgUrl -replace '&amp;','&'
        if     ($ImgUrl -match '^//')         { $ImgUrl = "https:" + $ImgUrl }
        elseif ($ImgUrl -notmatch '^http')    { $ImgUrl = "https://gall.dcinside.com" + $ImgUrl }

        # Skip known junk images (icons, spacers, UI chrome)
        $IsJunk = $ImgUrl -match 'dccon\.php|blank\.gif|clear\.gif|spacer\.gif'
        if (-not $IsJunk -and $ImgUrl -match 'dcinside\.(com|co\.kr)') {
            $IsJunk = $ImgUrl -notmatch 'viewimage\.php|dcimg\d+\.dcinside\.(com|co\.kr)|image\.dcinside\.(com|co\.kr)|download\.php'
        }
        if ($IsJunk) { continue }

        $BodyHash = if ($ImgUrl  -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $Matches[1] } else { "" }
        $FileNo   = if ($ImgStr  -match '(?i)data-fileno\s*=\s*["'']?([^"''\s>]+)') { $Matches[1] } else { "" }

        $FinalUrl = $ImgUrl
        $Matched  = $false

        # Exact match against attachment dictionary
        if     ($BodyHash -and $HQ_Dictionary.ContainsKey($BodyHash)) { $FinalUrl = $HQ_Dictionary[$BodyHash]; $Matched = $true }
        elseif ($FileNo   -and $HQ_Dictionary.ContainsKey($FileNo))   { $FinalUrl = $HQ_Dictionary[$FileNo];   $Matched = $true }

        # Partial match fallback (handles thumbnail hash mutations)
        if (-not $Matched) {
            foreach ($Key in $HQ_Dictionary.Keys) {
                if ($BodyHash -and $Key -and ($BodyHash.StartsWith($Key) -or $Key.StartsWith($BodyHash))) { $FinalUrl = $HQ_Dictionary[$Key]; break }
                if ($FileNo   -and $Key -and ($FileNo.StartsWith($Key)   -or $Key.StartsWith($FileNo)))   { $FinalUrl = $HQ_Dictionary[$Key]; break }
            }
        }

        if (-not $FinalLinks.Contains($FinalUrl)) { $FinalLinks[$FinalUrl] = $FinalUrl }
    }

    return @($FinalLinks.Values)
}

# --- Helper 5: Drain completed jobs and update session counters ---
function Receive-CompletedJobs([ref]$Jobs, [ref]$PostSuccess, [ref]$PostFail, [ref]$PostBytes, [string]$CleanUrl, [string]$SafeManga, [string]$SafeChapter, [int]$TotalCount) {
    $Completed = $Jobs.Value | Where-Object { $_.State -ne 'Running' }
    if (-not $Completed) { return }

    foreach ($R in ($Completed | Receive-Job)) {
        if ($R.Success) {
            $PostSuccess.Value++; $script:SessionSuccessCount++
            $PostBytes.Value   += $R.Size; $script:SessionTotalBytes += $R.Size
            Write-Log "SUCCESS" "Saved: $($R.FileName)" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount "$($R.Size) B"
        } else {
            $PostFail.Value++; $script:SessionFailureCount++
            $ActualError = if ($R.ErrorMsg) { $R.ErrorMsg } else { "Unknown Network Error" }
            Write-Log "ERROR" "Failed: $ActualError" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount
        }
    }
    $Completed | Remove-Job
    $Jobs.Value = @($Jobs.Value | Where-Object { $_.State -eq 'Running' })
}

# --- Helper 6a: Harvest dc_series blocks from a post and merge into series_catalog.csv ---
$CsvFile = Join-Path $PSScriptRoot "series_catalog.csv"

function Read-SeriesCsv {
    $Rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not (Test-Path $CsvFile)) { return $Rows }
    foreach ($Line in (Get-Content $CsvFile -Encoding UTF8 | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Parts = [regex]::Matches($Line, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
        if ($Parts.Count -eq 4) {
            $Rows.Add([PSCustomObject]@{ SeriesTitle=$Parts[0]; ChapterTitle=$Parts[1]; URL=$Parts[2]; Status=$Parts[3] })
        }
    }
    return $Rows
}

function Write-SeriesCsv([System.Collections.Generic.List[PSCustomObject]]$Rows) {
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add('"SeriesTitle","ChapterTitle","URL","Status"')
    foreach ($R in $Rows) {
        $Lines.Add("""$($R.SeriesTitle)"",""$($R.ChapterTitle)"",""$($R.URL)"",""$($R.Status)""")
    }
    $Lines | Set-Content $CsvFile -Encoding UTF8
}

function Invoke-PassiveSeriesHarvest([string]$Html, [string]$PostUrl) {
    if ($Html -notmatch 'class="dc_series"') { return }

    $Blocks = [regex]::Matches($Html, '(?s)<div class="dc_series"[^>]*>(.*?)</div>\s*</div>')
    if ($Blocks.Count -eq 0) { return }

    $Existing    = Read-SeriesCsv
    $ExistingUrls = @($Existing | ForEach-Object { $_.URL })
    $Added       = 0

    foreach ($Block in $Blocks) {
        $BlockHtml   = $Block.Groups[1].Value
        $SeriesTitle = "Unknown Series"
        if ($BlockHtml -match '<div[^>]*font-weight:bold[^>]*>\s*\[시리즈\]\s*(.*?)\s*</div>') {
            $SeriesTitle = $Matches[1].Trim()
        }
        if ($SeriesTitle -eq "Unknown Series") { continue }

        $ChapterLinks = [regex]::Matches($BlockHtml, '<a class="lnk"[^>]*href="([^"]+)"[^>]*>\s*·\s*(.*?)\s*</a>')
        foreach ($L in $ChapterLinks) {
            $Raw      = $L.Groups[1].Value -replace '&amp;', '&'
            $ChUrl    = if ($Raw -match '^http') { $Raw } else { "https://gall.dcinside.com" + $Raw }
            $ChUrl    = $ChUrl -replace '&exception_mode=[^&]*', '' -replace '&page=[^&]*', '' -replace '/view\?id=', '/view/?id='
            $ChTitle  = ($L.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()

            if ($ChUrl -notin $ExistingUrls) {
                $Existing.Add([PSCustomObject]@{ SeriesTitle=$SeriesTitle; ChapterTitle=$ChTitle; URL=$ChUrl; Status="Pending" })
                $ExistingUrls += $ChUrl
                $Added++
            }
        }
    }

    if ($Added -gt 0) {
        Write-SeriesCsv $Existing
        Write-Host "  [SERIES] Discovered $Added new chapter(s) in series_catalog.csv" -ForegroundColor DarkCyan
    }
}

# Update a URL's status in series_catalog.csv after download
function Update-SeriesCsvStatus([string]$Url, [string]$NewStatus) {
    if (-not (Test-Path $CsvFile)) { return }
    $Rows    = Read-SeriesCsv
    $Changed = $false
    foreach ($R in $Rows) { if ($R.URL -eq $Url) { $R.Status = $NewStatus; $Changed = $true } }
    if ($Changed) { Write-SeriesCsv $Rows }
}

# --- Helper 7: Flag or remove a URL from the download list ---
function Update-DownloadList([string]$OriginalUrl, [string]$CleanUrl, [string]$Action) {
    if (-not (Test-Path $ListFile)) { return }
    $Lines = Get-Content $ListFile -Encoding UTF8

    if ($Action -eq "Remove") {
        $Lines = $Lines | Where-Object { $_.Trim() -ne $OriginalUrl -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" }
        $Lines | Set-Content $ListFile -Encoding UTF8
        Write-Host "  [CLEANUP] Post finished/verified. Link removed." -ForegroundColor Gray
    } elseif ($Action -eq "Flag" -and $Lines -notcontains "#RETRY $CleanUrl") {
        $Lines = $Lines -replace [regex]::Escape($OriginalUrl), "#RETRY $CleanUrl"
        $Lines | Set-Content $ListFile -Encoding UTF8
        Write-Host "  [FLAGGED] Post has missing images. Marked for retry." -ForegroundColor Magenta
    }
}

# ===========================================================================
# MAIN ORCHESTRATOR: Process-Post
# Now a slim coordinator that calls the helpers above.
# ===========================================================================
function Process-Post($Url, $BaseDir) {
    $PostStartTime = Get-Date
    $OriginalUrl   = $Url
    $CleanUrl      = $Url.Trim() -replace "^#RETRY ", ""
    if ($CleanUrl -match "/view\?id=") { $CleanUrl = $CleanUrl -replace "/view\?id=", "/view/?id=" }

    $PostSuccess = 0; $PostFail = 0; $PostSkip = 0; $PostBytes = 0

    $Headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Referer"    = "https://gall.dcinside.com/"
        "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    }

    # Step 1: Fetch post HTML
    $Html = Get-PostHtml $CleanUrl $Headers
    if ($null -eq $Html) {
        Update-DownloadList $OriginalUrl $CleanUrl "Flag"
        Write-Log "ERROR" "Failed to load HTML" $CleanUrl
        return
    }

    # Step 2: Parse title
    $Parts      = Get-PostTitleParts $Html
    $Manga      = $Parts.Manga
    $Chapter    = $Parts.Chapter
    $SafeManga  = Get-SafeName $Manga
    $SafeChapter = Get-SafeName $Chapter

    # Step 3: Set up folder
    $TargetDir = Join-Path (Join-Path $BaseDir $SafeManga) $SafeChapter
    if (-not [System.IO.Directory]::Exists($TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }

    $SourceFile = Join-Path $TargetDir "source.txt"
    if (-not (Test-Path -LiteralPath $SourceFile)) { $CleanUrl | Set-Content -LiteralPath $SourceFile -Encoding UTF8 }

    # Step 4a: Passively harvest any [시리즈] blocks found in this post → series_catalog.csv
    Invoke-PassiveSeriesHarvest $Html $CleanUrl

    # Step 4b: Clean up any lingering temp/unnamed files from a previous crashed run
    Get-ChildItem -LiteralPath $TargetDir -File |
        Where-Object { $_.Extension -eq '.tmp' -or $_.Extension -eq '' } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Step 5: Build image URL list
    $HQ_Dict     = Get-AttachmentDictionary $Html
    $UniqueLinks = Get-ImageLinks $Html $HQ_Dict
    $TotalCount  = $UniqueLinks.Count

    if ($TotalCount -eq 0) {
        Write-Host "  ! No images found. Might be deleted." -ForegroundColor Yellow
        return
    }

    Write-Host ">>> Processing: $Manga ($Chapter)" -ForegroundColor Cyan
    Write-Host "    Found $TotalCount images to download." -ForegroundColor Yellow
    Write-Log "SESSION" "Starting Post Download" $CleanUrl $SafeManga $SafeChapter "N/A" $TotalCount

    # Step 6: Dispatch download jobs
    $RunningJobs = @()
    $ValidExts   = @('.jpg','.jpeg','.png','.gif','.webp')

    for ($i = 0; $i -lt $TotalCount; $i++) {
        $Item         = $UniqueLinks[$i]
        $BaseFileName = if ($RenameSequential) { (($i+1).ToString('000')) } else { "img_$($i+1)" }

        $ExistingFile = Get-ChildItem -LiteralPath $TargetDir -Filter "$BaseFileName.*" -File |
                        Where-Object { $ValidExts -contains $_.Extension.ToLower() } |
                        Select-Object -First 1

        if ($null -ne $ExistingFile) {
            $PostSkip++; $script:SessionSkipCount++
            continue
        }

        $TmpPath = Join-Path $TargetDir "$BaseFileName.tmp"

        # Wait for a job slot to free up
        while (($RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) {
            Receive-CompletedJobs ([ref]$RunningJobs) ([ref]$PostSuccess) ([ref]$PostFail) ([ref]$PostBytes) $CleanUrl $SafeManga $SafeChapter $TotalCount
            Start-Sleep -Milliseconds $JobPollMs
        }

        # Start a uniquely-named job so orphan cleanup only catches our jobs
        $JobName     = "$JobNamePrefix$($i+1)_$(Get-Date -Format 'HHmmss')"
        $RunningJobs += Start-Job -Name $JobName -ScriptBlock {
            param($DownloadUrl, $DestPath, $Idx, $BaseName, $JobHeaders, $UseProxy,
                  $ImageTimeoutSec, $MaxImageRetries, $ImageRetryWaitSec)

            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if ($UseProxy -eq "False") { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy }

            if ($DownloadUrl -notmatch "dcinside\.(com|co\.kr)") {
                $JobHeaders.Remove("Referer")
            }

            $ErrorMsg = ""
            for ($retry = 0; $retry -lt $MaxImageRetries; $retry++) {
                try {
                    Invoke-WebRequest -Uri $DownloadUrl -Headers $JobHeaders -OutFile $DestPath -UseBasicParsing -TimeoutSec $ImageTimeoutSec

                    $Stream = [System.IO.File]::OpenRead($DestPath)
                    $Bytes  = New-Object byte[] 12
                    $Stream.Read($Bytes, 0, 12) | Out-Null
                    $Stream.Close()

                    $Hex = [System.BitConverter]::ToString($Bytes)
                    $Ext = ".jpg"
                    if    ($Hex -match "^89-50-4E-47")                                     { $Ext = ".png"  }
                    elseif ($Hex -match "^47-49-46-38")                                    { $Ext = ".gif"  }
                    elseif ($Hex -match "^52-49-46-46" -and $Hex -match "57-45-42-50")    { $Ext = ".webp" }
                    elseif ($Hex -match "^FF-D8-FF")                                       { $Ext = ".jpg"  }

                    $FinalPath = $DestPath -replace '\.tmp$', $Ext
                    Rename-Item -LiteralPath $DestPath -NewName "$BaseName$Ext" -Force

                    $Size = (Get-Item -LiteralPath $FinalPath).Length
                    return @{ Success=$true; Size=$Size; Index=$Idx; FileName=("$BaseName$Ext") }
                } catch {
                    $ErrorMsg = $_.Exception.Message
                    if (Test-Path $DestPath) { Remove-Item $DestPath -Force -ErrorAction SilentlyContinue }
                    Start-Sleep -Seconds $ImageRetryWaitSec
                }
            }
            return @{ Success=$false; Index=$Idx; ErrorMsg=$ErrorMsg }
        } -ArgumentList $Item, $TmpPath, ($i+1), $BaseFileName, $Headers, $Config.UseProxy,
                        $ImageTimeoutSec, $MaxImageRetries, $ImageRetryWaitSec
    }

    # Step 7: Drain remaining jobs
    if ($RunningJobs.Count -gt 0) {
        $FinishedData = $RunningJobs | Wait-Job | Receive-Job
        foreach ($Res in $FinishedData) {
            if ($Res.Success) {
                $PostSuccess++; $script:SessionSuccessCount++
                $PostBytes += $Res.Size; $script:SessionTotalBytes += $Res.Size
                Write-Log "SUCCESS" "Saved: $($Res.FileName)" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount "$($Res.Size) B"
            } else {
                $PostFail++; $script:SessionFailureCount++
                $ActualError = if ($Res.ErrorMsg) { $Res.ErrorMsg } else { "Unknown Network Error" }
                Write-Log "ERROR" "Failed: $ActualError" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount
            }
        }
        $RunningJobs | Remove-Job
    }

    # Step 8: Update the download list and series catalog based on success/failure
    if ($PostFail -eq 0 -and ($PostSuccess -gt 0 -or $PostSkip -gt 0)) {
        Update-DownloadList $OriginalUrl $CleanUrl "Remove"
        Update-SeriesCsvStatus $CleanUrl "Downloaded"
    } elseif ($PostFail -gt 0) {
        Update-DownloadList $OriginalUrl $CleanUrl "Flag"
        Update-SeriesCsvStatus $CleanUrl "Failed"
    }

    # Step 9: Print summary
    $PostElapsed = "{0:hh\:mm\:ss}" -f ((Get-Date) - $PostStartTime)
    $Summary     = "Post Done: Saved: $PostSuccess | Failed: $PostFail | Skipped: $PostSkip | Size: $([Math]::Round($PostBytes/1MB,2)) MB | Time: $PostElapsed"
    Write-Host "  $Summary`n" -ForegroundColor Gray
    Write-Log "SESSION" "Finished Post Download | $Summary" $CleanUrl $SafeManga $SafeChapter "N/A" $TotalCount
}

# ===========================================================================
# SELECTION UI & EXECUTION
# ===========================================================================
Clear-Host
$Urls = @()
$Mode = ""

if ($RunAuto) {
    $Mode = "AUTO"
} else {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   DC Manga Downloader (Definitive Ver.)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1: Auto-grab URLs from [manual_urls]"
    Write-Host " 2: Download from single URL manually"
    $Choice = Read-Host "Select Option"
    $Mode   = if ($Choice -eq '1') { "AUTO" } else { "MANUAL" }
}

if ($Mode -eq "AUTO") {
    if (Test-Path $ListFile) {
        $cap          = $false
        $TargetHeader = if ($RunAuto) { "\[automatic_urls\]" } else { "\[manual_urls\]" }
        foreach ($l in Get-Content $ListFile -Encoding UTF8) {
            if    ($l -match $TargetHeader)          { $cap = $true }
            elseif($l -match "\[")                   { $cap = $false }
            elseif($cap -and $l.Trim() -match "^http|^#RETRY") { $Urls += $l.Trim() }
        }
    } else {
        Write-Host "Error: download_list.txt missing." -ForegroundColor Red
        Pause; exit
    }
} else {
    $pasted = Read-Host "Enter URL"
    if ($pasted -match "http") { $Urls += $pasted.Trim() }
}

# --- Main Loop ---
$script:SessionInterrupted = $true
try {
    $SessionStartTime = Get-Date
    Write-Log "SESSION" "--- DOWNLOADER START ($Mode MODE) ---"
    $idx = 1
    foreach ($Target in $Urls) {
        if ([string]::IsNullOrWhiteSpace($Target)) { continue }
        Write-Host "[$idx/$($Urls.Count)] Processing: $Target" -ForegroundColor Yellow
        Process-Post $Target $DownloadLocation
        if ($idx -lt $Urls.Count) { Start-Sleep -Seconds $SleepTime }
        $idx++
    }
    $script:SessionInterrupted = $false
} finally {
    $SessionEndTime = Get-Date
    $Elapsed        = "{0:hh\:mm\:ss}" -f ($SessionEndTime - $SessionStartTime)

    # CTRL+C orphan catcher — only targets our own jobs using the unique prefix
    if ($script:SessionInterrupted) {
        $OrphanJobs = Get-Job | Where-Object { $_.Name -like "$JobNamePrefix*" }
        if ($OrphanJobs) {
            $OrphanJobs | Stop-Job -ErrorAction SilentlyContinue
            $Results = $OrphanJobs | Receive-Job -ErrorAction SilentlyContinue
            foreach ($R in $Results) {
                if     ($R -and $R.Success)                               { $script:SessionSuccessCount++; $script:SessionTotalBytes += $R.Size }
                elseif ($R -and $null -ne $R.Success -and -not $R.Success) { $script:SessionFailureCount++ }
            }
            $OrphanJobs | Remove-Job -ErrorAction SilentlyContinue
        }
    }

    $B  = $script:SessionTotalBytes
    $Sz = if     ($B -ge 1GB) { "$([Math]::Round($B/1GB,2)) GB" }
          elseif ($B -ge 1MB) { "$([Math]::Round($B/1MB,2)) MB" }
          else                 { "$([Math]::Round($B/1KB,2)) KB" }

    $Stats     = "Success: $($script:SessionSuccessCount) | Failed: $($script:SessionFailureCount) | Skipped: $($script:SessionSkipCount) | Size: $Sz | Time: $Elapsed"
    $EndStatus = if ($script:SessionInterrupted) { "INTERRUPTED" } else { "FINISHED" }

    Write-Log "SESSION" "--- DOWNLOADER $EndStatus | $Stats ---"
    Write-Host "========================================`nDOWNLOADER $EndStatus`n$Stats`n========================================" -ForegroundColor White
    if (-not $RunAuto) { Pause }
}
