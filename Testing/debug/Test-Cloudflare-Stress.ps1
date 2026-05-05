# ==========================================================
# Arca.live / Cloudflare Stress Test & Bypass Debugger
# ==========================================================
$arcaUrl = "https://arca.live/b/hugetong/169526872" # 최근 다운로드 로그에 있던 아카라이브 주소
$Headers = @{ 
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

Write-Host "`n[1] Stress testing Arca.live to trigger Cloudflare block..." -ForegroundColor Yellow

$isBlocked = $false

# 봇으로 인식되도록 클라우드플레어를 자극하기 위해 빠르게 연속 요청을 보냅니다.
for ($i = 1; $i -le 20; $i++) {
    try {
        Write-Host "  -> Attempt $i..." -NoNewline
        $response = Invoke-WebRequest -Uri $arcaUrl -Headers $Headers -UseBasicParsing -TimeoutSec 5
        Write-Host " Success (HTTP 200)" -ForegroundColor Green
        
        # 차단을 유도하기 위해 딜레이를 아주 짧게 줍니다.
        Start-Sleep -Milliseconds 100
    } catch {
        Write-Host " BLOCKED! ($($_.Exception.Message))" -ForegroundColor Red
        $isBlocked = $true
        break
    }
}

if (-not $isBlocked) {
    Write-Host "`n[?] Cloudflare didn't block us after 20 attempts." -ForegroundColor Magenta
    Write-Host "    You might already have a cleared IP, or Arca's security level is currently low." -ForegroundColor Gray
    Pause
    exit
}

Write-Host "`n[2] Cloudflare block successfully triggered." -ForegroundColor Yellow
Write-Host "  -> Opening default browser to the target URL..." -ForegroundColor Cyan
Start-Process $arcaUrl

Write-Host "`n=======================================================" -ForegroundColor Magenta
Write-Host "  ACTION REQUIRED:" -ForegroundColor White
Write-Host "  1. 열린 브라우저 창을 확인하세요."
Write-Host "  2. CAPTCHA를 풀거나 사람 인증 대기 화면이 끝날 때까지 기다립니다."
Write-Host "  3. 정상적으로 게시글 본문이 보이면 파워셸로 돌아오세요."
Write-Host "=======================================================" -ForegroundColor Magenta

Read-Host "브라우저에서 인증을 완료했다면 Enter 키를 누르세요..."

Write-Host "`n[3] Retrying request in PowerShell (Testing IP Clearance vs Strict Cookie)..." -ForegroundColor Yellow
try {
    $testResponse = Invoke-WebRequest -Uri $arcaUrl -Headers $Headers -UseBasicParsing -TimeoutSec 10
    Write-Host "`n[SUCCESS] The request went through!" -ForegroundColor Green
    Write-Host ">> 결론: 클라우드플레어가 IP 주소 전체를 허용해 주었습니다! 제안하신 '후순위 미루기(Deferred) 후 브라우저 팝업' 방식이 완벽하게 통합니다." -ForegroundColor Green
} catch {
    Write-Host "`n[FAIL] Request was blocked again: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ">> 결론: 클라우드플레어가 엄격하게 'cf_clearance' 쿠키를 요구하고 있습니다. 브라우저에서 인증해도 파워셸은 여전히 막힙니다." -ForegroundColor Yellow
}

Pause