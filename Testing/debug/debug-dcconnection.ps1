param(
    # Defaults to a recent post from your catalog if no URL is provided
    [string]$TestUrl = "https://gall.dcinside.com/board/view/?id=comic_new6&no=4171994" 
)

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "     DCInside Connection Debugger         " -ForegroundColor Cyan
Write-Host "==========================================`n" -ForegroundColor Cyan

# 1. DNS Check
Write-Host "1. Testing DNS Resolution (gall.dcinside.com)..." -ForegroundColor White
try {
    $ip = [System.Net.Dns]::GetHostAddresses("gall.dcinside.com") | Select-Object -First 1
    Write-Host "   [OK] Resolved successfully to: $($ip.IPAddressToString)" -ForegroundColor Green
} catch {
    Write-Host "   [FAIL] Could not resolve gall.dcinside.com. This is a DNS or ISP block issue!" -ForegroundColor Red
    exit
}

# 2. Page Connection Check
Write-Host "`n2. Testing Page Connection to DCInside..." -ForegroundColor White
Write-Host "   URL: $TestUrl" -ForegroundColor DarkGray

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    "Referer"    = "https://gall.dcinside.com/"
}

try {
    # Force TLS 1.2 just like the main script
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $response = Invoke-WebRequest -Uri $TestUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15
    Write-Host "   [OK] Connected! HTTP Status: $($response.StatusCode)" -ForegroundColor Green
    $html = $response.Content
} catch {
    Write-Host "   [FAIL] Connection failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   -> If this timed out, your IP might be temporarily blocked by DCInside." -ForegroundColor Yellow
    exit
}

# 3. Image Extraction Check
Write-Host "`n3. Parsing HTML for image links..." -ForegroundColor White
$imgUrl = $null

# Try to find an attachment link first
if ($html -match '(?i)href="([^"]*(?:download\.php|/download/\?)[^"]*)"') {
    $imgUrl = $Matches[1] -replace '&amp;', '&'
    if ($imgUrl -match '^//') { $imgUrl = "https:" + $imgUrl }
    elseif ($imgUrl -notmatch '^http') { $imgUrl = "https://gall.dcinside.com" + $imgUrl }
} 
# Fallback to standard img tag if attachment fails
elseif ($html -match '(?i)<img[^>]+src="([^"]+)"[^>]*>') {
    $imgUrl = $Matches[1] -replace '&amp;', '&'
    if ($imgUrl -match '^//') { $imgUrl = "https:" + $imgUrl }
    elseif ($imgUrl -notmatch '^http') { $imgUrl = "https://gall.dcinside.com" + $imgUrl }
}

if ($imgUrl) {
    Write-Host "   [OK] Successfully extracted an image URL!" -ForegroundColor Green
    Write-Host "   Target: $imgUrl" -ForegroundColor DarkGray
} else {
    Write-Host "   [FAIL] Could not find any valid images on this page." -ForegroundColor Red
    exit
}

# 4. Image Download Check
Write-Host "`n4. Attempting to download the image payload..." -ForegroundColor White
$testFile = Join-Path $PWD "dc_debug_test_image.jpg"

try {
    # Ensure any old test file is gone
    if (Test-Path $testFile) { Remove-Item $testFile -Force }

    $wc = New-Object System.Net.WebClient
    foreach ($k in $Headers.Keys) { $wc.Headers.Add($k, $Headers[$k]) }
    
    # Download the payload
    $wc.DownloadFile($imgUrl, $testFile)
    $wc.Dispose()
    
    $size = (Get-Item $testFile).Length
    Write-Host "   [OK] Image downloaded successfully! Size: $size bytes" -ForegroundColor Green
    
    # Clean up the test image
    Remove-Item $testFile -Force
    Write-Host "   (Test image was automatically deleted)" -ForegroundColor DarkGray

} catch {
    Write-Host "   [FAIL] Failed to download image: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   -> Note: If the error is '403 Forbidden', DCInside image servers are rejecting your 'Referer' header." -ForegroundColor Yellow
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "             DEBUG COMPLETE               " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

pause