param ( [switch]$RunAuto, [switch]$RunManualQueue )

# Ensure UTF8 for Korean character support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ConfigFile = Join-Path $PSScriptRoot "config.yaml"

# --- 1. CONFIG PARSER ---
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

# --- 2. PATH RESOLUTION ---
$ListFile = if ($Config.DownloadListPath) { Join-Path $PSScriptRoot ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $PSScriptRoot "download_list.txt" }
$ListDir = Split-Path $ListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }

# Load File Lock Utility
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# Proxy Fixes
if ($Config.UseProxy -eq "False") {
    $NullProxy = New-Object System.Net.WebProxy
    [System.Net.HttpWebRequest]::DefaultWebProxy = $NullProxy
    [System.Net.WebRequest]::DefaultWebProxy = $NullProxy
} else { [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebProxy]::new() }

# Metrics & Settings
$script:SessionSuccessCount = 0; $script:SessionFailureCount = 0
$script:SessionSkipCount    = 0; $script:SessionTotalBytes   = 0

$DownloadLocation = if ($Config.DownloadDir -and [System.IO.Path]::IsPathRooted($Config.DownloadDir)) { $Config.DownloadDir } else { Join-Path $PSScriptRoot ($Config.DownloadDir -replace '^\.\\', '') }
$LogFile          = Join-Path $PSScriptRoot $Config.LogPath
$LogLevel         = $Config.LogLevel
$DoDNSRepair      = $Config.DNSAutoRepair -eq "True"
$SleepTime        = if ($Config.RateLimitSeconds) { [double]$Config.RateLimitSeconds } else { 2.5 }
$RenameSequential = $Config.RenameFilesSequential -eq "True"
$MaxThreads       = if ($Config.MaxConcurrentDownloads) { [int]$Config.MaxConcurrentDownloads } else { 3 }

if ($MaxThreads -lt 1) { $MaxThreads = 1 }

# --- 3. SANITIZATION & LOGGING ---
function Get-SafeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Unknown" }
    $Safe = ($Name -replace '<[^>]+>', '').Replace('?', '？').Replace(':', '：').Replace('*', '＊').Replace('|', '｜').Replace('"', '＂')
    $IllegalChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $Extra = if ($Config.CustomStripChars) { $Config.CustomStripChars } else { "" }
    $Regex = "[" + [regex]::Escape($IllegalChars + $Extra) + "\x00-\x1F]"
    
    $Final = (($Safe -replace $Regex, '_') -replace '\s+', ' ').Trim().Trim(".")
    if ([string]::IsNullOrWhiteSpace($Final)) { return "Unknown_Title" }
    return $Final
}

if ($Config.ShowProgressBar -eq "False") { $ProgressPreference = 'SilentlyContinue' }

function Write-Log([string]$Status, [string]$Message, [string]$Url = "N/A", [string]$Manga = "N/A", [string]$Chapter = "N/A", [string]$ImgNum = "N/A", [string]$Total = "N/A", [string]$Size = "N/A") {
    if ($LogLevel -eq "Error" -and $Status -notin @("ERROR", "SESSION", "REPAIR", "FLAGGED")) { return }
    $LogEntry = [ordered]@{ Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = $Status; Manga = $Manga; Chapter = $Chapter; ImageNum = $ImgNum; TotalImages = $Total; Size = $Size; Message = $Message; Url = $Url }
    
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { 
        $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml 
    } else { 
        $LogEntry | ConvertTo-Json -Compress 
    }
    
    $Json = $Json.Replace('\u0026', '&').Replace('\u003c', '<').Replace('\u003e', '>')

    try {
        $Client = New-Object System.IO.Pipes.NamedPipeClientStream(".", "DCMangaLogger", 'Out')
        $Client.Connect(150)
        $Writer = New-Object System.IO.StreamWriter($Client, [System.Text.Encoding]::UTF8)
        $Writer.WriteLine($Json); $Writer.Flush(); $Client.Dispose()
    } catch { 
        $LogDir = Split-Path $LogFile
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $Json | Add-Content -LiteralPath $LogFile -Encoding UTF8 
    }
}

# --- 4. CORE PROCESSING FUNCTION ---
function Process-Post($Url, $BaseDir) {
    $PostStartTime = Get-Date

    $CleanUrl = $Url.Trim() -replace "^#RETRY ", ""
    if ($CleanUrl -match "/view\?id=") { $CleanUrl = $CleanUrl -replace "/view\?id=", "/view/?id=" }

    $PostSuccess = 0; $PostFail = 0; $PostSkip = 0; $PostBytes = 0
    $Headers = @{ 
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
        "Referer" = "https://gall.dcinside.com/";
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    }
    
    $MaxRetries = 3; $RetryCount = 0; $Html = $null
    while ($RetryCount -le $MaxRetries -and $null -eq $Html) {
        try {
            $Resp = Invoke-WebRequest -Uri $CleanUrl -Headers $Headers -UseBasicParsing -TimeoutSec 20
            $Html = $Resp.Content
        } catch {
            $RetryCount++
            if ($DoDNSRepair -and ($_.Exception.Message -match "resolved|host")) {
                Write-Host "  ! DNS Error. Flushing..." -ForegroundColor Yellow
                ipconfig /flushdns | Out-Null; Start-Sleep -Seconds 5
            } else { Start-Sleep -Seconds 3 }
        }
    }

    if ($null -eq $Html) { 
        if (Test-Path $ListFile) {
            Invoke-WithFileLock "DownloadList" {
                $Lines = (Get-Content $ListFile -Encoding UTF8)
                if ($Lines -notcontains "#RETRY $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl" | Set-Content $ListFile -Encoding $Enc
                    Write-Host "  [FLAGGED] Post failed to load." -ForegroundColor Magenta
                }
            }
        }
        Write-Log "ERROR" "Failed to load HTML" $CleanUrl
        return 
    }

    $RawTitle = if ($Html -match '<span[^>]*class="title_subject"[^>]*>(.*?)</span>') { $Matches[1].Trim() } else { "Unknown" }
    $CleanTitle = $RawTitle -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
    $CleanTitle = $CleanTitle -replace '^번역\)\s*', '' -replace '^\s*\[?번역\]?\s*', '' -replace '\s*\([^)]*\)$', ''
    $CleanTitle = $CleanTitle.Trim().Trim(".")
    
    $Manga = $CleanTitle; $Chapter = "General"
    
    if ($CleanTitle -match '^(.*?)\s+([\(<\[]?[\d\.\-~,&＆\s]+화?[\)>\]]?)$') {
        $Manga = $Matches[1].Trim(); $Chapter = $Matches[2].Trim()
    }

    $SafeManga   = Get-SafeName $Manga; $SafeChapter = Get-SafeName $Chapter
    $TargetDir   = Join-Path (Join-Path $BaseDir $SafeManga) $SafeChapter
    if (-not [System.IO.Directory]::Exists($TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }

    # --- SAVE SOURCE URL ---
    $SourceFile = Join-Path $TargetDir "source.txt"
    if (-not (Test-Path $SourceFile)) {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        Set-Content -Path $SourceFile -Value $CleanUrl -Encoding $Enc
    }

    # --- CLEANUP ---
    Get-ChildItem -LiteralPath $TargetDir -File | Where-Object { $_.Extension -eq '.tmp' -or $_.Extension -eq '' } | Remove-Item -Force -ErrorAction SilentlyContinue

    # --- EXTRACTION (STRICT BOUNDS AND FALLBACK) ---
    $FinalLinks = New-Object System.Collections.Generic.List[PSObject]
    $HQ_Lookup = @{}
    
    # 1. Map Attachments
    $AppIndex = $Html.IndexOf('class="appending_file"')
    if ($AppIndex -ge 0) {
        $AppEnd = $Html.IndexOf('</ul>', $AppIndex); if ($AppEnd -lt 0) { $AppEnd = $Html.Length }
        [regex]::Matches($Html.Substring($AppIndex, $AppEnd-$AppIndex), '(?i)href="([^"]*(?:download\.php|/download/\?)[^"]*)"') | ForEach-Object {
            $u = $_.Groups[1].Value -replace '&amp;', '&'
            if ($u -match '^//') { $u = "https:" + $u } elseif ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
            if ($u -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $HQ_Lookup[$Matches[1]] = $u }
        }
    }

    # 2. Extract Body and build Job Metadata
    $StartIndex = $Html.IndexOf('class="writing_view_box"')
    if ($StartIndex -lt 0) { $StartIndex = 0 }

    # STRICT BOUNDS: Stop exactly before the upvotes, attachments, or comments.
    $EndIndex = $Html.IndexOf('class="updown_area"', $StartIndex)
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="appending_file_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="view_comment"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.IndexOf('class="reply_box"', $StartIndex) }
    if ($EndIndex -lt 0) { $EndIndex = $Html.Length }
    
    $Body = $Html.Substring($StartIndex, $EndIndex - $StartIndex)
    
    [regex]::Matches($Body, '(?i)<img[^>]+>') | ForEach-Object {
        $ImgStr = $_.Value
        if ($ImgStr -match '(?i)data-original="([^"]+)"' -or $ImgStr -match '(?i)src="([^"]+)"') {
            $BodyUrl = $Matches[1] -replace '&amp;', '&'
            if ($BodyUrl -match '^//') { $BodyUrl = "https:" + $BodyUrl } elseif ($BodyUrl -notmatch '^http') { $BodyUrl = "https://gall.dcinside.com" + $BodyUrl }
            
            # STRICT JUNK FILTER
            $IsJunk = $false
            if ($BodyUrl -match 'dccon\.php|blank\.gif|clear\.gif|spacer\.gif') { $IsJunk = $true }
            if ($BodyUrl -match 'dcinside\.(com|co\.kr)' -and $BodyUrl -notmatch 'viewimage\.php|dcimg\d+\.dcinside\.(com|co\.kr)|image\.dcinside\.(com|co\.kr)|download\.php') {
                $IsJunk = $true
            }
            if ($IsJunk) { return }

            $Hash = if ($BodyUrl -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $Matches[1] } else { $null }
            $FileNo = if ($ImgStr -match '(?i)data-fileno\s*=\s*["'']?([^"''\s>]+)') { $Matches[1] } else { $null }
            
            $UpgradeUrl = $null
            if ($Hash -and $HQ_Lookup.ContainsKey($Hash)) { $UpgradeUrl = $HQ_Lookup[$Hash] }
            elseif ($FileNo -and $HQ_Lookup.ContainsKey($FileNo)) { $UpgradeUrl = $HQ_Lookup[$FileNo] }
            else {
                foreach ($key in $HQ_Lookup.Keys) {
                    if (($Hash -and ($Hash.StartsWith($key) -or $key.StartsWith($Hash))) -or ($FileNo -and ($FileNo.StartsWith($key) -or $key.StartsWith($FileNo)))) {
                        $UpgradeUrl = $HQ_Lookup[$key]; break
                    }
                }
            }

            $FinalLinks.Add((New-Object PSObject -Property @{
                Url = if ($UpgradeUrl) { $UpgradeUrl } else { $BodyUrl }
                Fallback = if ($UpgradeUrl) { $BodyUrl } else { $null }
            }))
        }
    }

    $TotalCount = $FinalLinks.Count
    if ($TotalCount -eq 0) { Write-Host "  ! No images found." -ForegroundColor Yellow; return }

    Write-Host ">>> Processing: $Manga ($Chapter) | Images: $TotalCount" -ForegroundColor Cyan
    Write-Log "SESSION" "Starting Post Download" $CleanUrl $SafeManga $SafeChapter "N/A" $TotalCount

    $RunningJobs = @()
    for ($i=0; $i -lt $TotalCount; $i++) {
        $Item = $FinalLinks[$i]
        $Base = if ($RenameSequential) { (($i+1).ToString('000')) } else { "img_$($i+1)" }
        
        $ExistingFile = Get-ChildItem -LiteralPath $TargetDir -Filter "$Base.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

        if ($null -eq $ExistingFile) {
            while (($RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                $Completed = $RunningJobs | Where-Object { $_.State -ne 'Running' }
                if ($Completed) {
                    foreach ($R in ($Completed | Receive-Job)) {
                        if ($R.Success) { $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $R.Size; $script:SessionTotalBytes += $R.Size
                            Write-Log "SUCCESS" "Saved: $($R.FileName)" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount "$($R.Size) B" 
                        } else { $PostFail++; $script:SessionFailureCount++; Write-Log "ERROR" "Failed: $($R.ErrorMsg)" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount }
                    }
                    $Completed | Remove-Job; $RunningJobs = @($RunningJobs | Where-Object { $_.State -eq 'Running' })
                }
                Start-Sleep -Milliseconds 100 
            }
            
            $RunningJobs += Start-Job -ScriptBlock {
                param($Target, $Dest, $Idx, $Base, $Headers, $Proxy)
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                if ($Proxy -eq "False") { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy }
                
                $UrlsToTry = @($Target.Url)
                if ($Target.Fallback) { $UrlsToTry += $Target.Fallback }

                foreach ($Url in $UrlsToTry) {
                    $H = $Headers.Clone()
                    if ($Url -notmatch "dcinside\.") { $H.Remove("Referer") }
                    
                    for ($r=0; $r -lt 2; $r++) {
                        try {
                            $wc = New-Object System.Net.WebClient
                            foreach ($k in $H.Keys) { $wc.Headers.Add($k, $H[$k]) }
                            $wc.DownloadFile($Url, $Dest)
                            $wc.Dispose()

                            $Stream = [System.IO.File]::OpenRead($Dest); $Bytes = New-Object byte[] 12; $Stream.Read($Bytes, 0, 12) | Out-Null; $Stream.Close()
                            $Hex = [System.BitConverter]::ToString($Bytes); $Ext = ".jpg" 
                            if ($Hex -match "^89-50-4E-47") { $Ext = ".png" } elseif ($Hex -match "^47-49-46-38") { $Ext = ".gif" } elseif ($Hex -match "^52-49-46-46") { $Ext = ".webp" }
                            $Final = "$Base$Ext"; Rename-Item -LiteralPath $Dest -NewName $Final -Force
                            return @{ Success=$true; Size=(Get-Item (Join-Path (Split-Path $Dest) $Final)).Length; Index=$Idx; FileName=$Final }
                        } catch { if (Test-Path $Dest) { Remove-Item $Dest -Force }; Start-Sleep -Seconds 1 }
                    }
                }
                return @{ Success=$false; Index=$Idx; ErrorMsg="Connection Dropped by Server" }
            } -ArgumentList $Item, (Join-Path $TargetDir "$Base.tmp"), ($i+1), $Base, $Headers, $Config.UseProxy
        } else { $PostSkip++; $script:SessionSkipCount++ }
    }

    if ($RunningJobs) {
        $FinishedData = $RunningJobs | Wait-Job | Receive-Job
        foreach ($Res in $FinishedData) {
            if ($Res.Success) { $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $Res.Size; $script:SessionTotalBytes += $Res.Size 
                Write-Log "SUCCESS" "Saved: $($Res.FileName)" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount "$($Res.Size) B"
            } else { $PostFail++; $script:SessionFailureCount++; Write-Log "ERROR" "Failed: $($Res.ErrorMsg)" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount }
        }
        $RunningJobs | Remove-Job
    }

    # --- SYNCHRONIZED CLEANUP ---
    if ($PostFail -eq 0 -and ($PostSuccess -gt 0 -or $PostSkip -gt 0)) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                (Get-Content $ListFile -Encoding UTF8) | Where-Object { $_.Trim() -ne $Url -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" } | Set-Content $ListFile -Encoding $Enc
            }
        }
        Write-Host "  [CLEANUP] Post finished. Link removed." -ForegroundColor Gray
    } elseif ($PostFail -gt 0) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Lines = (Get-Content $ListFile -Encoding UTF8)
                if ($Lines -notcontains "#RETRY $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl" | Set-Content $ListFile -Encoding $Enc
                }
            }
        }
        Write-Host "  [FLAGGED] Post has missing images." -ForegroundColor Magenta
    }
    
    $PostEndTime = Get-Date; $PostElapsed = "{0:hh\:mm\:ss}" -f ($PostEndTime - $PostStartTime)
    $Summary = "Post Done: Saved: $PostSuccess | Failed: $PostFail | Skipped: $PostSkip | Size: $([Math]::Round($PostBytes/1MB, 2)) MB | Time: $PostElapsed"
    Write-Host "  $Summary`n" -ForegroundColor Gray
    Write-Log "SESSION" "Finished Post Download | $Summary" $CleanUrl $SafeManga $SafeChapter "N/A" $TotalCount
}

# --- 5. UI ---
Clear-Host
$Urls = @()
if ($RunAuto -or $RunManualQueue) { $Mode = "AUTO" } else {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   DC Manga Downloader (Definitive Ver.)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1. Auto-grab from [manual_urls]"
    Write-Host " 2. Manual URL"
    $Choice = Read-Host "Select Option"
    $Mode = if ($Choice -eq '1') { "AUTO" } else { "MANUAL" }
}

if ($Mode -eq "AUTO") {
    if (Test-Path $ListFile) {
        $cap = $false; $TargetHeader = if ($RunAuto) { "\[automatic_urls\]" } else { "\[manual_urls\]" }
        foreach($l in Get-Content $ListFile -Encoding UTF8) {
            if($l -match $TargetHeader) { $cap = $true } elseif($l -match "\[") { $cap = $false }
            elseif($cap -and $l.Trim() -match "^http|^#RETRY") { $Urls += $l.Trim() } 
        }
    } else { Write-Host "Error: download_list.txt missing at $ListFile" -ForegroundColor Red; Pause; exit }
} else {
    $pasted = Read-Host "Enter URL"; if ($pasted -match "http") { $Urls += $pasted.Trim() }
}

$script:SessionInterrupted = $true
try {
    $SessionStartTime = Get-Date; $idx = 1
    Write-Log "SESSION" "--- DOWNLOADER START ($Mode MODE) ---"
    foreach ($Target in $Urls) {
        if ([string]::IsNullOrWhiteSpace($Target)) { continue }
        Write-Host "[$idx/$($Urls.Count)] Processing: $Target" -ForegroundColor Yellow
        Process-Post $Target $DownloadLocation
        if ($idx -lt $Urls.Count) { Start-Sleep -Seconds $SleepTime }; $idx++
    }
    $script:SessionInterrupted = $false
} finally {
    $SessionEndTime = Get-Date; $Elapsed = "{0:hh\:mm\:ss}" -f ($SessionEndTime - $SessionStartTime)
    if ($script:SessionInterrupted) {
        $OrphanJobs = Get-Job | Where-Object { $_.Name -like "Job*" }
        if ($OrphanJobs) {
            $OrphanJobs | Stop-Job -ErrorAction SilentlyContinue
            $Results = $OrphanJobs | Receive-Job -ErrorAction SilentlyContinue
            foreach ($R in $Results) {
                if ($R -and $R.Success) { $script:SessionSuccessCount++; $script:SessionTotalBytes += $R.Size }
                elseif ($R -and $null -ne $R.Success -and -not $R.Success) { $script:SessionFailureCount++ }
            }
            $OrphanJobs | Remove-Job -ErrorAction SilentlyContinue
        }
    }
    $B = $script:SessionTotalBytes; $Sz = if ($B -ge 1GB) { "$([Math]::Round($B/1GB, 2)) GB" } elseif ($B -ge 1MB) { "$([Math]::Round($B/1MB, 2)) MB" } else { "$([Math]::Round($B/1KB, 2)) KB" }
    $Stats = "Success: $($script:SessionSuccessCount) | Failed: $($script:SessionFailureCount) | Skipped: $($script:SessionSkipCount) | Size: $Sz | Time: $Elapsed"
    $EndStatus = if ($script:SessionInterrupted) { "INTERRUPTED" } else { "FINISHED" }
    Write-Log "SESSION" "--- DOWNLOADER $EndStatus | $Stats ---"
    Write-Host "========================================`nDOWNLOADER $EndStatus`n$Stats`n========================================" -ForegroundColor White
    if (-not $RunAuto) { Pause }
}