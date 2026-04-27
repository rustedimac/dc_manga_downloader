# Ensure UTF8 for Korean Characters
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ConfigFile = Join-Path $PSScriptRoot "config.yaml"
$ListFile   = Join-Path $PSScriptRoot "download_list.txt"

# --- Hybrid YAML Parser ---
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | Where-Object { $_ -match '^\s*([^:]+)\s*:\s*(.*)$' } | ForEach-Object {
        $Config[$Matches[1].Trim()] = ($Matches[2] -split '#')[0].Trim(" `"'")
    }
}

$BoardUrl    = $Config.BoardUrl
$MaxPages    = [int]$Config.MaxPages
$DoDNSRepair = $Config.DNSAutoRepair -eq "True"
$LogFile     = Join-Path $PSScriptRoot $Config.LogPath
$CrawlOrder  = if ($null -ne $Config.CrawlOrder) { [int]$Config.CrawlOrder } else { 0 }

# --- LOGGING ENGINE ---
function Write-Log([string]$Status, [string]$Message, [string]$Url = "N/A") {
    $LogEntry = [ordered]@{ 
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); 
        Status    = $Status; 
        Message   = $Message; 
        Url       = $Url 
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $Json = $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml
    } else {
        $Json = ($LogEntry | ConvertTo-Json -Compress) -replace '\\u0026', '&'
    }
    $Json | Add-Content -Path $LogFile
}

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer"    = "https://gall.dcinside.com/"
}

# --- Determine Crawl Direction & LOG SESSION START ---
if ($CrawlOrder -eq 0) {
    Write-Host "Starting Crawler (Oldest First Mode)..." -ForegroundColor Cyan
    Write-Log "SESSION" "Crawler Started (Oldest First). Max Pages: $($MaxPages)" $BoardUrl
    $PageArray = $MaxPages..1
} else {
    Write-Host "Starting Crawler (Latest First Mode)..." -ForegroundColor Cyan
    Write-Log "SESSION" "Crawler Started (Latest First). Max Pages: $($MaxPages)" $BoardUrl
    $PageArray = 1..$MaxPages
}

$FoundUrls = @()

foreach ($Page in $PageArray) {
    $TargetUrl = "$BoardUrl&page=$Page"
    Write-Host "Scanning Page $Page..." -ForegroundColor Yellow
    
    $RetryCount = 0; $PageSuccess = $false; $Html = $null

    while ($RetryCount -le 2 -and -not $PageSuccess) {
        try {
            $Response = Invoke-WebRequest -Uri $TargetUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15
            $Html = $Response.Content
            $PageSuccess = $true
            Write-Log "SUCCESS" "Successfully scanned page $($Page)" $TargetUrl
        } catch {
            if ($DoDNSRepair -and ($_.Exception.Message -match "could not be resolved" -or $_.Exception.Message -match "No such host")) {
                Write-Host "  ! DNS Error. Repairing..." -ForegroundColor Yellow
                Write-Log "REPAIR" "DNS Flush triggered on page $($Page)" $TargetUrl
                ipconfig /flushdns | Out-Null
                Start-Sleep -Seconds 10
            } else {
                # FIXED: Added $() to variables to prevent ParserErrors with colons
                Write-Log "ERROR" "Failed page $($Page): $($_.Exception.Message)" $TargetUrl
            }
            $RetryCount++
        }
    }

    if ($PageSuccess) {
        $Pattern = '(?s)<td class="gall_tit ub-word">.*?<a\s+href="(/board/view/\?id=[^"]+)"[^>]*>(.*?)</a>'
        $MatchesList = [regex]::Matches($Html, $Pattern)
        
        $PageUrls = @()
        if ($CrawlOrder -eq 0) {
            for ($i = $MatchesList.Count - 1; $i -ge 0; $i--) {
                $Match = $MatchesList[$i]
                $Title = ($Match.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if ($Title -match '번역') {
                    $PageUrls += "https://gall.dcinside.com" + ($Match.Groups[1].Value -replace '&amp;', '&')
                }
            }
        } else {
            foreach ($Match in $MatchesList) {
                $Title = ($Match.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
                if ($Title -match '번역') {
                    $PageUrls += "https://gall.dcinside.com" + ($Match.Groups[1].Value -replace '&amp;', '&')
                }
            }
        }
        $FoundUrls += $PageUrls
        Write-Host "  Found $($PageUrls.Count) translations." -ForegroundColor Gray
    }
}

# --- SMART UPDATE ---
if (Test-Path $ListFile) {
    $CurrentFile = Get-Content $ListFile -Encoding UTF8
    
    $ManualUrls = @()
    $InManual = $false
    foreach ($Line in $CurrentFile) {
        if ($Line -match "^\[manual_urls\]") { $InManual = $true }
        elseif ($Line -match "^\[.*\]") { $InManual = $false }
        elseif ($InManual -and $Line -match "^http") { $ManualUrls += $Line.Trim() }
    }

    $SavedRetries = @()
    $InAuto = $false
    foreach ($Line in $CurrentFile) {
        if ($Line -match "^\[automatic_urls\]") { $InAuto = $true }
        elseif ($Line -match "^\[.*\]") { $InAuto = $false }
        elseif ($InAuto -and $Line -match "^#RETRY") { $SavedRetries += $Line.Trim() }
    }

    $FinalAuto = New-Object System.Collections.Generic.List[string]
    foreach ($Url in $SavedRetries) { $FinalAuto.Add($Url) }
    foreach ($Url in $FoundUrls) {
        if ($SavedRetries -notcontains "#RETRY $Url" -and $SavedRetries -notcontains $Url) {
            $FinalAuto.Add($Url)
        }
    }

    $NewContent = @("[manual_urls]") + $ManualUrls + @("") + @("[automatic_urls]") + $FinalAuto
    $NewContent | Set-Content $ListFile -Encoding UTF8
}

Write-Host "`nList updated. Launching Downloader..." -ForegroundColor Green
Write-Log "SESSION" "Crawler Finished. Found $($FoundUrls.Count) new URLs."

& (Join-Path $PSScriptRoot "Start-Downloader.ps1") -RunAuto