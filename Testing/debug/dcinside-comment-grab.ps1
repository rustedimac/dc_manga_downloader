$url = "https://gall.dcinside.com/board/view/?id=comic_new6&no=4163013"
$headers = @{ 
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer" = "https://gall.dcinside.com/board/lists/?id=comic_new6"
}
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

Write-Host "[1] Attempting to fetch HTML..." -ForegroundColor Cyan
try {
    $res = Invoke-WebRequest -Uri $url -Headers $headers -WebSession $session -UseBasicParsing -TimeoutSec 10
    $html = $res.Content
    
    # 디버깅을 위해 받은 HTML을 파일로 저장합니다. (가장 중요)
    $html | Set-Content -Path "debug_html.txt" -Encoding UTF8
    Write-Host "[2] HTML saved to 'debug_html.txt'. Please check this file!" -ForegroundColor Yellow

    if ($html -match 'id="e_s_n_o"\s*value="([^"]+)"') {
        Write-Host "[SUCCESS] Token Found: $($Matches[1])" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Token not found. HTML might be blocked or redirected." -ForegroundColor Red
        
        # 간단한 상태 체크
        if ($html -match "window.location.replace" -or $html -match "location.href") {
            Write-Host " -> Detected Javascript Redirect. (Possibly Bot Protection)" -ForegroundColor Magenta
        }
        if ($html -length -lt 5000) {
            Write-Host " -> HTML is too short ($($html.length) bytes). Definitely blocked." -ForegroundColor Magenta
        }
    }
} catch {
    Write-Host "[ERROR] Request failed: $($_.Exception.Message)" -ForegroundColor Red
}
Pause