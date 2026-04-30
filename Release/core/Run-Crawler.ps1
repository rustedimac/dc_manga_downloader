# ==========================================
# DC Manga Auto-Crawler
# ==========================================
# Ensure UTF8 for Korean characters
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
$ListFile = if ($Config.DownloadListPath) { Join-Path $RootDir ($Config.DownloadListPath -replace '^\.\\', '') } else { Join-Path $RootDir "Data\download_list.txt" }
$ListDir = Split-Path $ListFile
if (-not (Test-Path $ListDir)) { New-Item -ItemType Directory -Path $ListDir -Force | Out-Null }
if (-not (Test-Path $ListFile)) {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    @("# DC Manga Downloader List", "", "[manual_urls]", "", "[automatic_urls]") | Set-Content -Path $ListFile -Encoding $Enc
}

$LogFile = if ($Config.AutoCrawlerLogPath) {
    if ([System.IO.Path]::IsPathRooted($Config.AutoCrawlerLogPath)) {
        $Config.AutoCrawlerLogPath
    } else {
        Join-Path $RootDir ($Config.AutoCrawlerLogPath -replace '^\.[\\/]', '')
    }
} else {
    Join-Path $RootDir "logs\Run-Crawler\autocrawl_logs.json"
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

$LogDir = Split-Path $LogFile
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# --- 3. SETTINGS & VARIABLES ---
$BoardUrl            = $Config.BoardUrl
$MaxPages            = if ($Config.AutoCrawlerMaxPages) { [int]$Config.AutoCrawlerMaxPages } else { 10 }
$DoDNSRepair         = $Config.DNSAutoRepair -eq "True"
$CrawlOrder          = if ($null -ne $Config.CrawlOrder) { [int]$Config.CrawlOrder } else { 0 }
$KeepUnfinishedLinks = $Config.KeepUnfinishedLinks -eq "True"

# --- Constants ---
$PageTimeoutSec  = 15
$MaxPageRetries  = 2
$DNSWaitSec      = 10

# --- Logging Engine ---
function Write-Log([string]$Status, [string]$Message, [string]$Url = "N/A") {
    $LogEntry = [ordered]@{
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Status    = $Status
        Message   = $Message
        Url       = $Url
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $Json = $LogEntry | ConvertTo-Json -Compress -EscapeHandling EscapeHtml
    } else {
        $Json = ($LogEntry | ConvertTo-Json -Compress) -replace '\\u0026', '&'
    }
    
    # Use version-aware encoding for log writes
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }
    $Json | Add-Content -Path $LogFile -Encoding $Enc
}

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer"    = "https://gall.dcinside.com/"
}

# --- Determine Crawl Direction & Log Session Start ---
if ($CrawlOrder -eq 0) {
    Write-Host "Starting Crawler (Oldest First Mode)..." -ForegroundColor Cyan
    Write-Log "SESSION" "Crawler Started (Oldest First). Max Pages: $MaxPages" $BoardUrl
    $PageArray = $MaxPages..1
} else {
    Write-Host "Starting Crawler (Latest First Mode)..." -ForegroundColor Cyan
    Write-Log "SESSION" "Crawler Started (Latest First). Max Pages: $MaxPages" $BoardUrl
    $PageArray = 1..$MaxPages
}

# --- Helper: Fetch a single board page with retry ---
function Get-BoardPageHtml([string]$Url) {
    $RetryCount = 0
    while ($RetryCount -le $MaxPageRetries) {
        try {
            $Response = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -TimeoutSec $PageTimeoutSec
            return $Response.Content
        } catch {
            if ($DoDNSRepair -and ($_.Exception.Message -match "could not be resolved|No such host")) {
                Write-Host "  ! DNS Error. Repairing..." -ForegroundColor Yellow
                Write-Log "REPAIR" "DNS Flush triggered on: $Url" $Url
                ipconfig /flushdns | Out-Null
                Start-Sleep -Seconds $DNSWaitSec
            } else {
                Write-Log "ERROR" "Failed page fetch: $($_.Exception.Message)" $Url
            }
            $RetryCount++
        }
    }
    return $null
}

# --- Helper: Extract translation post URLs from page HTML ---
function Get-TranslationUrls([string]$Html, [int]$Order) {
    $Pattern  = '(?s)<td class="gall_tit ub-word">.*?<a\s+href="(/board/view/\?id=[^"]+)"[^>]*>(.*?)</a>'
    $Matches2 = [regex]::Matches($Html, $Pattern)
    $Urls     = @()

    $Indices = if ($Order -eq 0) { ($Matches2.Count - 1)..0 } else { 0..($Matches2.Count - 1) }

    foreach ($i in $Indices) {
        $Match = $Matches2[$i]
        $Title = ($Match.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
        if ($Title -match '번역') {
            $Urls += "https://gall.dcinside.com" + ($Match.Groups[1].Value -replace '&amp;', '&')
        }
    }
    return $Urls
}

# --- Main Crawl Loop ---
$FoundUrls = @()

foreach ($Page in $PageArray) {
    $TargetUrl = "$BoardUrl&page=$Page"
    Write-Host "Scanning Page $Page..." -ForegroundColor Yellow

    $Html = Get-BoardPageHtml $TargetUrl

    if ($null -ne $Html) {
        Write-Log "SUCCESS" "Successfully scanned page $Page" $TargetUrl
        $PageUrls   = Get-TranslationUrls $Html $CrawlOrder
        $FoundUrls += $PageUrls
        Write-Host "  Found $($PageUrls.Count) translations." -ForegroundColor Gray
    } else {
        Write-Host "  ! Skipping page $Page after retries." -ForegroundColor Red
    }
}

# --- Load File Lock Utility ---
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# --- Smart Update: merge new URLs with existing list ---
Invoke-WithFileLock "DownloadList" {
    $Enc = if ($PSVersionTable.PSVersion.Major -ge 6) { "utf8BOM" } else { "UTF8" }

    if (Test-Path $ListFile) {
        $CurrentFile = Get-Content $ListFile -Encoding UTF8

        # Preserve manually added URLs
        $ManualUrls = @()
        $InManual   = $false
        foreach ($Line in $CurrentFile) {
            if      ($Line -match "^\[manual_urls\]") { $InManual = $true }
            elseif ($Line -match "^\[.*\]")          { $InManual = $false }
            elseif ($InManual -and $Line -match "^http") { $ManualUrls += $Line.Trim() }
        }

        # Preserve existing #RETRY flags so failed posts aren't lost
        $SavedRetries = @()
        $InAuto       = $false
        foreach ($Line in $CurrentFile) {
            if      ($Line -match "^\[automatic_urls\]") { $InAuto = $true }
            elseif ($Line -match "^\[.*\]")             { $InAuto = $false }
            elseif ($InAuto -and $Line -match "^#RETRY") { $SavedRetries += $Line.Trim() }
        }

        # Build the new automatic section (retries first, then new URLs)
        $FinalAuto = New-Object System.Collections.Generic.List[string]
        foreach ($Url in $SavedRetries) { $FinalAuto.Add($Url) }
        foreach ($Url in $FoundUrls) {
            if ($SavedRetries -notcontains "#RETRY $Url" -and $SavedRetries -notcontains $Url) {
                $FinalAuto.Add($Url)
            }
        }

        $Timestamp  = "# Last crawled: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $NewContent = @($Timestamp, "", "[manual_urls]") + $ManualUrls + @("", "[automatic_urls]") + $FinalAuto
        
        $NewContent | Set-Content $ListFile -Encoding $Enc
    } else {
        # Create a fresh list file if it doesn't exist yet
        $Timestamp  = "# Last crawled: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $NewContent = @($Timestamp, "", "[manual_urls]", "", "[automatic_urls]") + $FoundUrls
        
        $NewContent | Set-Content $ListFile -Encoding $Enc
    }
}

Write-Host "`nList updated. Launching Downloader..." -ForegroundColor Green
Write-Log "SESSION" "Crawler Finished. Found $($FoundUrls.Count) new URLs."

& (Join-Path $PSScriptRoot "Start-Downloader.ps1") -RunAuto