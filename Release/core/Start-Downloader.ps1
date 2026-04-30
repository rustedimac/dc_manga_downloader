param (
    [switch]$RunAuto,
    [switch]$RunManualQueue,
    [switch]$RunScannerQueue
)

# Ensure UTF8 for Korean character support
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- NEW ANCHOR LOGIC ---
$RootDir = Split-Path $PSScriptRoot -Parent
$ConfigFile = Join-Path $RootDir "config.yaml"

# --- 1. CONFIG PARSER ---
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

# --- 2. PATH RESOLUTION & LIST GENERATOR ---
$MainListFile = if ($Config.DownloadListPath) { Join-Path $RootDir ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_list.txt" }
$ListDir = Split-Path $MainListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }

$ListFile = $MainListFile
if ($RunScannerQueue) {
    $ListFile = Join-Path $ListDir "scanner_queue.txt"
}

if ($ListFile -eq $MainListFile -and -not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @("# DC Manga Downloader List", "", "[manual_urls]", "", "[automatic_urls]") | Set-Content -Path $ListFile -Encoding $Enc
} elseif ($ListFile -ne $MainListFile -and -not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @() | Set-Content -Path $ListFile -Encoding $Enc
}

# Load File Lock Utility
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# Force Disable System Proxy (prevents issues with some network environments)
if ($Config.UseProxy -eq "False") {
    $NullProxy = New-Object System.Net.WebProxy
    [System.Net.HttpWebRequest]::DefaultWebProxy = $NullProxy
    [System.Net.WebRequest]::DefaultWebProxy = $NullProxy
} else {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebProxy]::new()
}

# Metrics
$script:SessionSuccessCount = 0
$script:SessionFailureCount = 0
$script:SessionSkipCount    = 0
$script:SessionTotalBytes   = 0

# Configuration
$DownloadLocation = if ($Config.DownloadDir -and [System.IO.Path]::IsPathRooted($Config.DownloadDir)) {
    $Config.DownloadDir
} else {
    Join-Path $RootDir ($Config.DownloadDir -replace '^\.\\', '')
}

$LogFile = if ($Config.LogPath -and [System.IO.Path]::IsPathRooted($Config.LogPath)) {
    $Config.LogPath
} else {
    Join-Path $RootDir ($Config.LogPath -replace '^\.\\', '')
}

# --- LOG ROTATION ---
if (Test-Path $LogFile) {
    $MaxLogMB = if ($Config.CrawlerLogMaxMB) { [double]$Config.CrawlerLogMaxMB } else { 10 }
    if (((Get-Item $LogFile).Length / 1MB) -ge $MaxLogMB) {
        $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $RotatedLog = ($LogFile -replace '\.json$', "_$Timestamp.json")
        Rename-Item -Path $LogFile -NewName (Split-Path $RotatedLog -Leaf)
        
        $LogDirObj = Split-Path $LogFile
        $MaxLogFiles = if ($Config.CrawlerLogMaxFiles) { [int]$Config.CrawlerLogMaxFiles } else { 5 }
        $Files = Get-ChildItem -Path $LogDirObj -Filter "*.json" | Sort-Object CreationTime
        while ($Files.Count -gt $MaxLogFiles) {
            Remove-Item -Path $Files[0].FullName -Force
            $Files = Get-ChildItem -Path $LogDirObj -Filter "*.json" | Sort-Object CreationTime
        }
    }
}

$LogLevel         = $Config.LogLevel
$DoDNSRepair      = $Config.DNSAutoRepair -eq "True"
$SleepTime        = if ($Config.RateLimitSeconds) { [double]$Config.RateLimitSeconds } else { 2.5 }
$RenameSequential = $Config.RenameFilesSequential -eq "True"
$MaxThreads       = if ($Config.MaxConcurrentDownloads) { [int]$Config.MaxConcurrentDownloads } else { 15 }
$ShowVisualBar    = $Config.ShowProgressBar -eq "True"

if ($MaxThreads -lt 1) { $MaxThreads = 1 }

# Native PowerShell Progress Setting
if ($ShowVisualBar) {
    $ProgressPreference = 'SilentlyContinue'
}

# --- 3. HELPER FUNCTIONS ---

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
    param(
        [string]$Status,
        [string]$Message,
        [string]$Url = "N/A",
        [string]$Manga = "N/A",
        [string]$Chapter = "N/A",
        [string]$ImageNum = "N/A",
        [string]$TotalImages = "N/A",
        [string]$Size = "N/A"
    )
    
    if ($LogLevel -eq "Error" -and $Status -notin @("ERROR", "SESSION", "REPAIR", "FLAGGED")) { return }

    $LogEntry = [ordered]@{
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Status      = $Status
        Manga       = $Manga
        Chapter     = $Chapter
        ImageNum    = $ImageNum
        TotalImages = $TotalImages
        Size        = $Size
        Message     = $Message
        Url         = $Url
    }
    
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { 
        $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml 
    } else { 
        $LogEntry | ConvertTo-Json -Compress 
    }
    
    $Json = $Json.Replace('\u0026', '&').Replace('\u003c', '<').Replace('\u003e', '>')

    try {
        $Client = New-Object System.IO.Pipes.NamedPipeClientStream(".", "DCMangaLogger", [System.IO.Pipes.PipeDirection]::Out)
        $Client.Connect(150)
        $Writer = New-Object System.IO.StreamWriter($Client, [System.Text.Encoding]::UTF8)
        $Writer.WriteLine($Json)
        $Writer.Flush()
        $Client.Dispose()
    } catch { 
        $LogDirNode = Split-Path $LogFile
        if (-not (Test-Path $LogDirNode)) { New-Item -ItemType Directory -Path $LogDirNode -Force | Out-Null }
        $Json | Add-Content -LiteralPath $LogFile -Encoding UTF8 
    }
}

function Show-VisualProgress([int]$Current, [int]$Total) {
    if (-not $ShowVisualBar) { return }
    $Percent = [Math]::Floor(($Current / $Total) * 100)
    $Width = 30
    $Done = [Math]::Floor(($Current / $Total) * $Width)
    $Left = $Width - $Done
    $Bar = "[" + ("#" * $Done) + ("-" * $Left) + "]"
    Write-Host -NoNewline "`r    Progress: $Bar $Percent% ($Current/$Total images)    "
}

# --- 4. CORE PROCESSING FUNCTION ---

function Process-Post($Url, $BaseDir) {
    $PostStartTime = Get-Date
    $CleanUrl = $Url.Trim() -replace "^#RETRY ", ""
    
    if ($CleanUrl -match "/view\?id=") {
        $CleanUrl = $CleanUrl -replace "/view\?id=", "/view/?id="
    }

    $PostSuccess = 0
    $PostFail    = 0
    $PostSkip    = 0
    $PostBytes   = 0

    $Headers = @{ 
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
        "Referer" = "https://gall.dcinside.com/";
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    }
    
    $MaxRetries = 3
    $RetryCount = 0
    $Html = $null
    
    while ($RetryCount -le $MaxRetries -and $null -eq $Html) {
        try {
            $Response = Invoke-WebRequest -Uri $CleanUrl -Headers $Headers -UseBasicParsing -TimeoutSec 20
            $Html = $Response.Content
        } catch {
            $RetryCount++
            if ($DoDNSRepair -and ($_.Exception.Message -match "could not be resolved|No such host")) {
                Write-Host "  ! DNS Error detected. Flushing DNS and waiting..." -ForegroundColor Yellow
                Write-Log "REPAIR" "DNS Flush triggered" $CleanUrl
                ipconfig /flushdns | Out-Null
                Start-Sleep -Seconds 10
            } else {
                Start-Sleep -Seconds 3
            }
        }
    }

    if ($null -eq $Html) { 
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Lines = (Get-Content $ListFile -Encoding UTF8)
                if ($Lines -notcontains "#RETRY $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl" | Set-Content $ListFile -Encoding $Enc
                    Write-Host "  [FLAGGED] Post failed to load HTML. Added #RETRY flag." -ForegroundColor Magenta
                }
            }
        }
        Write-Log "ERROR" "Failed to load HTML after retries" $CleanUrl
        return 
    }

    $RawTitle = if ($Html -match '<span[^>]*class="title_subject"[^>]*>(.*?)</span>') {
        $Matches[1].Trim()
    } else {
        "Unknown"
    }

    $CleanTitle = $RawTitle -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&'
    $CleanTitle = $CleanTitle -replace '^번역\)\s*', '' -replace '^\s*\[?번역\]?\s*', '' -replace '\s*\([^)]*\)$', ''
    $CleanTitle = $CleanTitle.Trim().Trim(".")
    
    $Manga = $CleanTitle
    $Chapter = "General"
    
    if ($CleanTitle -match '^(.*?)\s+([\(<\[]?[\d\.\-~,&＆\s]+화?[\)>\]]?)$') {
        $Manga = $Matches[1].Trim()
        $Chapter = $Matches[2].Trim()
    }

    $SafeManga   = Get-SafeName $Manga
    $SafeChapter = Get-SafeName $Chapter
    $TargetDir   = Join-Path (Join-Path $BaseDir $SafeManga) $SafeChapter
    
    if (-not [System.IO.Directory]::Exists($TargetDir)) {
        [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null
    }

    $SourceFile = Join-Path $TargetDir "source.txt"
    try {
        $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
        $WriteUrl = $true
        if (Test-Path $SourceFile) {
            $ExistingUrls = Get-Content -LiteralPath $SourceFile -ErrorAction SilentlyContinue
            if ($ExistingUrls -contains $CleanUrl) { $WriteUrl = $false }
        }
        if ($WriteUrl) {
            Add-Content -LiteralPath $SourceFile -Value $CleanUrl -Encoding $Enc -ErrorAction Stop
        }
    } catch {
        Write-Host "  ! Minor Issue: Could not save source.txt" -ForegroundColor DarkYellow
    }

    Get-ChildItem -LiteralPath $TargetDir -File | Where-Object { $_.Extension -eq '.tmp' -or $_.Extension -eq '' } | Remove-Item -Force -ErrorAction SilentlyContinue

    $FinalLinks = New-Object System.Collections.Generic.List[PSObject]
    $HQ_Lookup = @{}
    $AttachmentList = New-Object System.Collections.Generic.List[string]
    
    $AppIndex = $Html.IndexOf('class="appending_file"')
    if ($AppIndex -ge 0) {
        $AppEnd = $Html.IndexOf('</ul>', $AppIndex)
        if ($AppEnd -lt 0) { $AppEnd = $Html.Length }
        $AppLength = $AppEnd - $AppIndex
        if ($AppLength -gt 0) {
            [regex]::Matches($Html.Substring($AppIndex, $AppLength), '(?i)href="([^"]*(?:download\.php|/download/\?)[^"]*)"') | ForEach-Object {
                $u = $_.Groups[1].Value -replace '&amp;', '&'
                if ($u -match '^//') { $u = "https:" + $u } elseif ($u -notmatch '^http') { $u = "https://gall.dcinside.com" + $u }
                $AttachmentList.Add($u)
                if ($u -match '(?i)[?&](?:no|attach_no|f_no)=([^&]+)') { $HQ_Lookup[$Matches[1]] = $u }
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

    $AttCount = $AttachmentList.Count
    $BodyCount = $BodyItems.Count
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
    if ($TotalCount -eq 0) { Write-Host "  ! No images found." -ForegroundColor Yellow; return }

    Write-Host ">>> Processing: $Manga ($Chapter) | Images: $TotalCount" -ForegroundColor Cyan
    Write-Log "SESSION" "Starting Post Download" $CleanUrl $SafeManga $SafeChapter "N/A" $TotalCount

    $RunningJobs = @()
    for ($i=0; $i -lt $TotalCount; $i++) {
        $Item = $FinalLinks[$i]
        $BaseName = if ($RenameSequential) { (($i+1).ToString('000')) } else { "img_$($i+1)" }
        $ExistingFile = Get-ChildItem -LiteralPath $TargetDir -Filter "$BaseName.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

        if ($null -eq $ExistingFile) {
            while (($RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                $Completed = $RunningJobs | Where-Object { $_.State -ne 'Running' }
                if ($Completed) {
                    foreach ($R in ($Completed | Receive-Job)) {
                        if ($R.Success) { 
                            $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $R.Size; $script:SessionTotalBytes += $R.Size
                            Write-Log "SUCCESS" "Saved image" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount "$($R.Size) B" 
                        } else { 
                            $PostFail++; $script:SessionFailureCount++; 
                            Write-Log "ERROR" "Failed image: $($R.ErrorMsg)" $CleanUrl $SafeManga $SafeChapter $R.Index $TotalCount 
                        }
                        Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
                    }
                    $Completed | Remove-Job
                    $RunningJobs = @($RunningJobs | Where-Object { $_.State -eq 'Running' })
                }
                Start-Sleep -Milliseconds 50 
            }
            
            $RunningJobs += Start-Job -ScriptBlock {
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
                        } catch { if (Test-Path $Dest) { Remove-Item $Dest -Force }; Start-Sleep -Seconds 1 }
                    }
                }
                return @{ Success=$false; Index=$Idx; ErrorMsg="Connection Dropped by Server" }
            } -ArgumentList $Item, (Join-Path $TargetDir "$BaseName.tmp"), ($i+1), $BaseName, $Headers, $Config.UseProxy
        } else { 
            $PostSkip++; $script:SessionSkipCount++
            Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
        }
    }

    if ($RunningJobs) {
        $FinishedData = $RunningJobs | Wait-Job | Receive-Job
        foreach ($Res in $FinishedData) {
            if ($Res.Success) { 
                $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $Res.Size; $script:SessionTotalBytes += $Res.Size 
                Write-Log "SUCCESS" "Saved image" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount "$($Res.Size) B"
            } else { 
                $PostFail++; $script:SessionFailureCount++; 
                Write-Log "ERROR" "Failed image: $($Res.ErrorMsg)" $CleanUrl $SafeManga $SafeChapter $Res.Index $TotalCount 
            }
            Show-VisualProgress ($PostSuccess + $PostSkip + $PostFail) $TotalCount
        }
        $RunningJobs | Remove-Job
    }

    if ($ShowVisualBar) { Write-Host "" } # Add line break after bar finishes

    if ($PostFail -eq 0 -and ($PostSuccess -gt 0 -or $PostSkip -gt 0)) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                $Lines = Get-Content $ListFile -Encoding UTF8
                $UpdatedLines = @($Lines | Where-Object { $_.Trim() -ne $Url -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" })
                Set-Content -Path $ListFile -Value $UpdatedLines -Encoding $Enc
            }
        }
        Write-Host "  [CLEANUP] Post finished. Link removed." -ForegroundColor Gray
    } elseif ($PostFail -gt 0) {
        Invoke-WithFileLock "DownloadList" {
            if (Test-Path $ListFile) {
                $Lines = Get-Content $ListFile -Encoding UTF8
                if ($Lines -notcontains "#RETRY $CleanUrl") {
                    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
                    $UpdatedLines = @($Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl")
                    Set-Content -Path $ListFile -Value $UpdatedLines -Encoding $Enc
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
    
    if ($Choice -eq '0') {
        exit # Returns control to launch.bat
    } elseif ($Choice -eq '1') {
        $Mode = "AUTO"
    } else {
        $Mode = "MANUAL"
    }
}

if ($Mode -eq "AUTO") {
    if (Test-Path $ListFile) {
        $cap = ($RunScannerQueue -eq $true)
        $TargetHeader = if ($RunAuto) { "\[automatic_urls\]" } else { "\[manual_urls\]" }
        
        foreach($l in Get-Content $ListFile -Encoding UTF8) {
            if (-not $RunScannerQueue) {
                if($l -match $TargetHeader) { $cap = $true } 
                elseif($l -match "\[") { $cap = $false }
            }
            
            if($cap -and $l.Trim() -match "^http|^#RETRY") { 
                $Urls += $l.Trim() 
            } 
        }
    } else {
        Write-Host "Error: target list missing at $ListFile" -ForegroundColor Red
        Pause
        exit
    }
} else {
    Write-Host "Enter DCInside Post URL (or leave blank to cancel):" -ForegroundColor Gray
    $pasted = Read-Host "URL"
    if ($pasted -match "http") {
        $Urls += $pasted.Trim()
    } else {
        exit # Return to main menu if blank
    }
}

$script:SessionInterrupted = $true

try {
    $SessionStartTime = Get-Date
    $idx = 1
    
    Write-Log "SESSION" "--- DOWNLOADER START ($Mode MODE) ---"
    
    foreach ($Target in $Urls) {
        if ([string]::IsNullOrWhiteSpace($Target)) { continue }
        
        Write-Host "[$idx/$($Urls.Count)] Processing: $Target" -ForegroundColor Yellow
        Process-Post $Target $DownloadLocation
        
        if ($idx -lt $Urls.Count) {
            Start-Sleep -Seconds $SleepTime
        }
        $idx++
    }
    
    $script:SessionInterrupted = $false

} finally {
    $SessionEndTime = Get-Date
    $Elapsed = "{0:hh\:mm\:ss}" -f ($SessionEndTime - $SessionStartTime)

    if ($script:SessionInterrupted) {
        $OrphanJobs = Get-Job | Where-Object { $_.Name -like "Job*" }
        if ($OrphanJobs) {
            $OrphanJobs | Stop-Job -ErrorAction SilentlyContinue
            $Results = $OrphanJobs | Receive-Job -ErrorAction SilentlyContinue
            foreach ($R in $Results) {
                if ($R -and $R.Success) {
                    $script:SessionSuccessCount++
                    $script:SessionTotalBytes += $R.Size
                } elseif ($R -and $null -ne $R.Success -and -not $R.Success) {
                    $script:SessionFailureCount++
                }
            }
            $OrphanJobs | Remove-Job -ErrorAction SilentlyContinue
        }
    }

    $B = $script:SessionTotalBytes
    $Sz = if ($B -ge 1GB) { "$([Math]::Round($B/1GB, 2)) GB" } elseif ($B -ge 1MB) { "$([Math]::Round($B/1MB, 2)) MB" } else { "$([Math]::Round($B/1KB, 2)) KB" }
    
    $Stats = "Success: $($script:SessionSuccessCount) | Failed: $($script:SessionFailureCount) | Skipped: $($script:SessionSkipCount) | Size: $Sz | Time: $Elapsed"
    
    $EndStatus = if ($script:SessionInterrupted) { "INTERRUPTED" } else { "FINISHED" }
    Write-Log "SESSION" "--- DOWNLOADER $EndStatus | $Stats ---"
    
    Write-Host "========================================" -ForegroundColor White
    Write-Host "DOWNLOADER $EndStatus" -ForegroundColor White
    Write-Host $Stats -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    
    if (-not $RunAuto -and -not $RunScannerQueue) {
        Pause
    }
}