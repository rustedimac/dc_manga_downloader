# Ensure UTF8 for Korean Characters
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   DC Manga Deep-Search Crawler (Title Only)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
$Keyword = Read-Host "Enter Manga Title/Keyword to search"
if ([string]::IsNullOrWhiteSpace($Keyword)) { exit }

# Safely encode the keyword for web requests
$EncodedKeyword = [uri]::EscapeDataString($Keyword)

$BaseId = "comic_new6"
$MaxBlocks = 300
$MaxPagesPerBlock = 10

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Referer"    = "https://gall.dcinside.com/"
}

$FoundResults = @() 
$CurrentSearchPos = ""

for ($Block = 1; $Block -le $MaxBlocks; $Block++) {
    Write-Host "`n>>> Scanning Time Block $Block/$MaxBlocks..." -ForegroundColor Yellow
    $BlockHasNextSearch = $false
    $NextSearchPos = ""

    for ($Page = 1; $Page -le $MaxPagesPerBlock; $Page++) {
        # MODIFIED: Changed s_type to search_subject for Title-Only search
        $TargetUrl = "https://gall.dcinside.com/board/lists/?id=$BaseId&page=$Page&s_type=search_subject&s_keyword=$EncodedKeyword"
        if ($CurrentSearchPos) { $TargetUrl += "&search_pos=$CurrentSearchPos" }

        Write-Host "  Scanning Page $Page..." -ForegroundColor Gray

        $RetryCount = 0; $Html = $null
        while ($RetryCount -le 2 -and $null -eq $Html) {
            try {
                $Resp = Invoke-WebRequest -Uri $TargetUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15
                $Html = $Resp.Content
            } catch {
                Start-Sleep -Seconds 3
                $RetryCount++
            }
        }

        if ($null -eq $Html) { continue }

        # Extract Post Links
        $Pattern = '(?s)class="[^"]*gall_tit[^"]*".*?<a[^>]+href="([^"]*(?:/board/view/)?\?id=[^"]+)"[^>]*>(.*?)</a>'
        $MatchesList = [regex]::Matches($Html, $Pattern)

        foreach ($Match in $MatchesList) {
            $Title = ($Match.Groups[2].Value -replace '<[^>]+>', '').Replace('&amp;', '&').Trim()
            
            # --- THE STRICT FILTER ---
            $IncludePattern = '번역\)|\[번역\]'
            $ExcludePattern = '모음|추천|번역추|요청|질문|념글'
            
            if (($Title -match $IncludePattern) -and ($Title -notmatch $ExcludePattern)) {
                $RawPath = $Match.Groups[1].Value -replace '&amp;', '&'
                $FullUrl = if ($RawPath -match "^http") { $RawPath } else { "https://gall.dcinside.com" + $RawPath }
                
                # Clean the URL
                $CleanUrl = $FullUrl -replace '&page=[^&]*', '' -replace '&s_type=[^&]*', '' -replace '&s_keyword=[^&]*', '' -replace '&search_pos=[^&]*', ''
                
                # Only add if unique
                if ($null -eq ($FoundResults | Where-Object { $_.Url -eq $CleanUrl })) {
                    $FoundResults += [PSCustomObject]@{
                        Title = $Title
                        Url   = $CleanUrl
                    }
                }
            }
        }

        # Check for "Next Search"
        if ($Html -match 'search_pos=(-\d+)[^>]*>(?:<[^>]+>)*다음 검색') {
            $NextSearchPos = $Matches[1]
            $BlockHasNextSearch = $true
        }

        # Early break if no more pages in this block
        $NextPage = $Page + 1
        if ($Html -notmatch "page=$NextPage") { break }
    }

    if ($BlockHasNextSearch -and $NextSearchPos -ne $CurrentSearchPos) {
        $CurrentSearchPos = $NextSearchPos
    } else {
        Write-Host ">>> Reached the end of DCInside search history." -ForegroundColor Cyan
        break
    }
}

# --- FINAL DISPLAY ---
if ($FoundResults.Count -gt 0) {
    Write-Host "`n[SEARCH RESULTS - TITLE ONLY]" -ForegroundColor Green
    $FoundResults | Format-Table -AutoSize
    Write-Host "`nTotal valid chapters found: $($FoundResults.Count)" -ForegroundColor Green
} else {
    Write-Host "`nNo valid chapters matching the filters were found in post titles." -ForegroundColor Red
}

Write-Host "`nPress any key to exit..."
$null = [Console]::ReadKey($true)