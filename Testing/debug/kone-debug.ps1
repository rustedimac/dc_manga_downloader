# ==========================================================
# Kone.gg Regex Comparison Debugger
# ==========================================================
$koneUrl = "https://kone.gg/s/gynerwork/d8Saty84pVRNz1-aUj7j0b"
Write-Host "Target URL: $koneUrl" -ForegroundColor Cyan

$Headers = @{ 
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

Write-Host "`n[1] Fetching Kone.gg HTML..." -ForegroundColor Yellow
$koneHtml = (Invoke-WebRequest -Uri $koneUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content

# ---------------------------------------------------------
# [METHOD A] HtmlDecode + 넓은 범위의 정규식 (이전 실패/롤백 버전)
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Red
Write-Host " [METHOD A] HtmlDecode + Broad Regex (The 43-image version)" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Red

$linksA = @()
$decodedHtml = [System.Net.WebUtility]::HtmlDecode($koneHtml)
[regex]::Matches($decodedHtml, '(?i)https?[:\\/]+[a-zA-Z0-9\-\.]*mittere\.io[^\s"''<>\}]+') | ForEach-Object {
    $src = $_.Value -replace '\\/', '/' -replace '\\$', '' -replace '"$', ''
    $linksA += $src
}

# 중복 제거
$UniqueA = $linksA | Select-Object -Unique
Write-Host "-> Total Extracted (Unique): $($UniqueA.Count) images" -ForegroundColor White

if ($UniqueA.Count -gt 14) {
    Write-Host "`n[!] Look at the extra junk links caught by Method A:" -ForegroundColor Gray
    # 처음 14개(정상 본문)를 제외한 나머지(보통 썸네일/아바타)를 보여줍니다.
    $UniqueA | Select-Object -Skip 14 | Select-Object -First 5 | ForEach-Object {
        Write-Host "    $($_)" -ForegroundColor DarkGray
    }
    Write-Host "    ... (and more thumbnails)" -ForegroundColor DarkGray
}


# ---------------------------------------------------------
# [METHOD B] Raw HTML + 초정밀 <img src=> 타겟팅 (성공/최종 버전)
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " [METHOD B] Raw HTML + Precise <img> Regex (The 14-image version)" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

$linksB = @()
# [핵심] JSON의 \u003cimg 또는 실제 <img 뒤에 오는 src 링크만 낚아챔
[regex]::Matches($koneHtml, '(?i)(?:<img|\\u003cimg)\s+src=["''\\]*(https?://[^\s"''<>\\]+mittere\.io[^\s"''<>\\]+)') | ForEach-Object {
    $src = $_.Groups[1].Value
    $linksB += $src
}

# 중복 제거
$UniqueB = $linksB | Select-Object -Unique
Write-Host "-> Total Extracted (Unique): $($UniqueB.Count) images" -ForegroundColor White

if ($UniqueB.Count -eq 14) {
    Write-Host "`n[SUCCESS] Method B correctly isolated the exactly 14 comic pages!" -ForegroundColor Green
    $UniqueB | Select-Object -First 3 | ForEach-Object { Write-Host "    $($_)" -ForegroundColor Cyan }
    Write-Host "    ... (11 more comic pages)" -ForegroundColor Cyan
}

Write-Host "`nDone." -ForegroundColor White
Pause