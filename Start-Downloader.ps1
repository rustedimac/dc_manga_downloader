param ( [switch]$RunAuto )

# Ensure UTF8 for Korean character support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ConfigFile = Join-Path $PSScriptRoot "config.yaml"
$ListFile   = Join-Path $PSScriptRoot "download_list.txt"

# --- 1. CONFIG PARSER ---
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

# Proxy Fixes
if ($Config.UseProxy -eq "False") {
    $NullProxy = New-Object System.Net.WebProxy
    [System.Net.HttpWebRequest]::DefaultWebProxy = $NullProxy
    [System.Net.WebRequest]::DefaultWebProxy = $NullProxy
}

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

# --- Concurrent Setting ---
if ($MaxThreads -lt 1) { $MaxThreads = 1 }
# Thread cap removed

# --- 2. SANITIZATION & LOGGING ---
function Get-SafeName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Unknown" }
    $Clean = ($Name -replace '<[^>]+>', '').Replace('?', '？').Replace(':', '：').Replace('*', '＊').Replace('|', '｜').Replace('"', '＂')
    $IllegalChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $Extra = if ($Config.CustomStripChars) { $Config.CustomStripChars } else { "" }
    $Regex = "[" + [regex]::Escape($IllegalChars + $Extra) + "\x00-\x1F]"
    $Final = (($Clean -replace $Regex, '_') -replace '\s+', ' ').Trim(" .")
    if ([string]::IsNullOrWhiteSpace($Final)) { return "Unknown_Title" }
    return $Final
}

function Write-Log([string]$Status, [string]$Message, [string]$Url = "N/A", [string]$Manga = "N/A", [string]$Chapter = "N/A", [string]$ImgNum = "N/A", [string]$Size = "N/A") {
    if ($LogLevel -eq "Error" -and $Status -notin @("ERROR", "SESSION", "REPAIR", "FLAGGED")) { return }
    $LogEntry = [ordered]@{ Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Status = $Status; Manga = $Manga; Chapter = $Chapter; ImageNum = $ImgNum; Size = $Size; Message = $Message; Url = $Url }
    $Json = if ($PSVersionTable.PSVersion.Major -ge 6) { $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml } 
            else { ($LogEntry | ConvertTo-Json -Compress) -replace '\\u0026', '&' }
    $Json | Add-Content -LiteralPath $LogFile
}

# --- 3. CORE PROCESSING FUNCTION ---
function Process-Post($Url, $BaseDir) {
    $PostStartTime = Get-Date # APPENDED: Track start time for this specific post/chapter

    $CleanUrl = $Url.Trim() -replace "^#RETRY ", ""
    if ($CleanUrl -match "/view\?id=") { $CleanUrl = $CleanUrl -replace "/view\?id=", "/view/?id=" }

    $PostSuccess = 0; $PostFail = 0; $PostSkip = 0; $PostBytes = 0
    $Headers = @{ 
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
        "Referer" = "https://gall.dcinside.com/";
        "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    }
    
    # HTML Fetch
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
        # Added flag logic for fully failed pages
        if (Test-Path $ListFile) {
            $Lines = Get-Content $ListFile -Encoding UTF8
            if ($Lines -notcontains "#RETRY $CleanUrl") {
                $Lines = $Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl"
                $Lines | Set-Content $ListFile -Encoding UTF8
                Write-Host "  [FLAGGED] Post failed to load." -ForegroundColor Magenta
            }
        }
        Write-Log "ERROR" "Failed to load HTML" $CleanUrl
        return 
    }

    # Title & Directory Logic (SMART PARSING)
    $RawTitle = if ($Html -match '<span[^>]*class="title_subject"[^>]*>(.*?)</span>') { $Matches[1].Trim() } else { "Unknown" }
    $CleanTitle = $RawTitle -replace '^번역\)\s*', '' -replace '^\s*\[?번역\]?\s*', '' -replace '\s*\([^)]*\)$', ''
    
    $Manga = $CleanTitle
    $Chapter = "General"
    if ($CleanTitle -match '^(.*?)\s+([0-9\.\-~,&＆]+화|\d+)$') {
        $Manga = $Matches[1].Trim()
        $Chapter = $Matches[2].Trim()
    } elseif ($CleanTitle -match '^(.*?)([0-9\.\-~,&＆]+화)$') {
        $Manga = $Matches[1].Trim()
        $Chapter = $Matches[2].Trim()
    }

    $SafeManga   = Get-SafeName $Manga
    $SafeChapter = Get-SafeName $Chapter
    $TargetDir   = Join-Path (Join-Path $BaseDir $SafeManga) $SafeChapter
    if (-not [System.IO.Directory]::Exists($TargetDir)) { [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null }
    
    $SourceFile = Join-Path $TargetDir "source.txt"
    if (-not (Test-Path -LiteralPath $SourceFile)) { $CleanUrl | Set-Content -LiteralPath $SourceFile -Encoding UTF8 }

    # Extraction
    $RawLinks = @()
    if ($Html -match '(?s)<ul[^>]*class="[^"]*appending_file[^"]*"[^>]*>(.*?)</ul>') {
        $Links = [regex]::Matches($Matches[1], '<a[^>]+href="([^"]*download\.php[^"]*)"[^>]*>(.*?)</a>')
        foreach ($L in $Links) { $RawLinks += ($L.Groups[1].Value -replace '&amp;', '&') }
    }
    if ($Html -match '(?s)<div[^>]*class="writing_view_box"[^>]*>(.*?)</div>') {
        $ImgTags = [regex]::Matches($Matches[1], '<img[^>]+src="([^"]*(?:viewimage\.php|image\.dcinside\.com|dcimg\d\.dcinside\.com)[^"]*)"[^>]*>')
        foreach ($Img in $ImgTags) { $RawLinks += ($Img.Groups[1].Value -replace '&amp;', '&') }
    }

    $UniqueLinks = $RawLinks | Select-Object -Unique
    if ($UniqueLinks.Count -eq 0) { return }

    Write-Host ">>> Processing: $Manga ($Chapter)" -ForegroundColor Cyan
    Write-Log "SESSION" "Starting Post Download" $CleanUrl $SafeManga $SafeChapter

    $RunningJobs = @()
    for ($i=0; $i -lt $UniqueLinks.Count; $i++) {
        $Item = $UniqueLinks[$i]
        $FName = ""; if ($RenameSequential) { $FName = (($i+1).ToString('000') + ".jpg") } else { $FName = "img_$($i+1).jpg" }
        $FPath = Join-Path $TargetDir $FName

        if (-not (Test-Path -LiteralPath $FPath)) {
            while (($RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { Start-Sleep -Milliseconds 100 }
            $RunningJobs += Start-Job -ScriptBlock {
                param($DUrl, $DPath, $Headers, $Idx)
                try {
                    Invoke-WebRequest -Uri $DUrl -Headers $Headers -OutFile $DPath -UseBasicParsing -TimeoutSec 30
                    return @{ Success=$true; Size=(Get-Item -LiteralPath $DPath).Length; Index=$Idx; Name=(Split-Path $DPath -Leaf) }
                } catch { return @{ Success=$false; Index=$Idx } }
            } -ArgumentList $Item, $FPath, $Headers, ($i+1)
        } else { $PostSkip++; $script:SessionSkipCount++ }
    }

    if ($RunningJobs.Count -gt 0) {
        $FinishedData = $RunningJobs | Wait-Job | Receive-Job
        foreach ($Res in $FinishedData) {
            if ($Res.Success) { 
                $PostSuccess++; $script:SessionSuccessCount++; $PostBytes += $Res.Size; $script:SessionTotalBytes += $Res.Size 
                Write-Log "SUCCESS" "Saved: $($Res.Name)" $CleanUrl $SafeManga $SafeChapter $Res.Index "$($Res.Size) B"
            } else { 
                $PostFail++; $script:SessionFailureCount++ 
                Write-Log "ERROR" "Image failed" $CleanUrl $SafeManga $SafeChapter $Res.Index
            }
        }
        $RunningJobs | Remove-Job
    }

    # EXPLICIT FLAG LOGIC
    if ($PostFail -gt 0) {
        if (Test-Path $ListFile) {
            $Lines = Get-Content $ListFile -Encoding UTF8
            if ($Lines -notcontains "#RETRY $CleanUrl") {
                $Lines = $Lines -replace [regex]::Escape($Url), "#RETRY $CleanUrl"
                $Lines | Set-Content $ListFile -Encoding UTF8
                Write-Host "  [FLAGGED] Post has missing images. Marked for retry." -ForegroundColor Magenta
            }
        }
    } elseif ($RunAuto -and $PostFail -eq 0 -and $PostSuccess -gt 0 -and (Test-Path $ListFile)) {
        $Lines = Get-Content $ListFile -Encoding UTF8 | Where-Object { $_.Trim() -ne $Url -and $_.Trim() -ne $CleanUrl -and $_.Trim() -ne "#RETRY $CleanUrl" }
        $Lines | Set-Content $ListFile -Encoding UTF8
        Write-Host "  [CLEANUP] Post complete. Link removed." -ForegroundColor Gray
    }
    
    $PostEndTime = Get-Date # APPENDED: Stop the timer for this post
    $PostElapsed = "{0:hh\:mm\:ss}" -f ($PostEndTime - $PostStartTime)

    # Restored Skips here
    $Summary = "Post Done: Saved: $PostSuccess | Failed: $PostFail | Skipped: $PostSkip | Size: $([Math]::Round($PostBytes/1MB, 2)) MB | Time: $PostElapsed"
    Write-Host "  $Summary`n" -ForegroundColor Gray
    Write-Log "SESSION" "Finished Post Download | $Summary" $CleanUrl $SafeManga $SafeChapter
}

# --- 4. SELECTION UI & EXECUTION ---
Clear-Host
$Urls = @()
$Mode = ""

if ($RunAuto) {
    $Mode = "AUTO"
} else {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   DC Manga Downloader (Definitive Ver.)  " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " 1: Auto-grab URLs from [automatic_urls]"
    Write-Host " 2: Download from single URL manually"
    $Choice = Read-Host "Select Option"
    if ($Choice -eq '1') { $Mode = "AUTO" } else { $Mode = "MANUAL" }
}

if ($Mode -eq "AUTO") {
    if (Test-Path $ListFile) {
        $cap = $false
        foreach($l in Get-Content $ListFile -Encoding UTF8) {
            if($l -match "\[automatic_urls\]") { $cap = $true }
            elseif($l -match "\[") { $cap = $false }
            elseif($cap -and $l.Trim() -match "^http|^#RETRY") { $Urls += $l.Trim() } 
        }
    } else { Write-Host "Error: download_list.txt missing." -ForegroundColor Red; Pause; exit }
} else {
    $pasted = Read-Host "Enter URL"
    if ($pasted -match "http") { $Urls += $pasted.Trim() }
}

# START PROCESSING
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
    $Elapsed = "{0:hh\:mm\:ss}" -f ($SessionEndTime - $SessionStartTime)
    
    $B = $script:SessionTotalBytes; $Sz = if ($B -ge 1GB) { "$([Math]::Round($B/1GB, 2)) GB" } elseif ($B -ge 1MB) { "$([Math]::Round($B/1MB, 2)) MB" } else { "$([Math]::Round($B/1KB, 2)) KB" }
    
    # Restored Skips here
    $Stats = "Success: $($script:SessionSuccessCount) | Failed: $($script:SessionFailureCount) | Skipped: $($script:SessionSkipCount) | Size: $Sz | Time: $Elapsed"
    
    $EndStatus = if ($script:SessionInterrupted) { "INTERRUPTED" } else { "FINISHED" }
    
    Write-Log "SESSION" "--- DOWNLOADER $EndStatus | $Stats ---"
    Write-Host "========================================`nDOWNLOADER $EndStatus`n$Stats`n========================================" -ForegroundColor White
    if (-not $RunAuto) { Pause }
}