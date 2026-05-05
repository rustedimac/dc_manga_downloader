# 1. Define the target details
$url = "https://m.dcinside.com/ajax/response-comment"
$filePath = "$PSScriptRoot\comments.html"

# 2. Set up the headers
$headers = @{
    "User-Agent"       = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    "Referer"          = "https://m.dcinside.com/board/comic_new6/4163013"
    "X-Requested-With" = "XMLHttpRequest"
    "Content-Type"     = "application/x-www-form-urlencoded"
}

# 3. Define the body parameters
$body = @{
    "id"           = "comic_new6"
    "no"           = "4163013"
    "comment_page" = "1"
}

# 4. Execute and Save
try {
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
    
    # Save the output to an HTML file
    $response | Out-File -FilePath "dc_comments.html" -Encoding utf8
    
    Write-Host "Success! Comments saved to: $(Get-Location)\dc_comments.html" -ForegroundColor Cyan
}
catch {
    Write-Host "The request failed: $($_.Exception.Message)" -ForegroundColor Red
}