# ==========================================
# DC Manga - External Link Downloader (Telegraph / Arca.live / Kone.gg)
# ==========================================
param (
    [string[]]$TelegraphLinks,
    [string]$TargetDir,
    [int]$MaxThreads,
    [hashtable]$Headers,
    [string]$UseProxy,
    [bool]$RenameSequential,
    [switch]$ProcessDeferred
)

$ExtSuccess = 0; $ExtFail = 0; $ExtBytes = 0
$ResolvedLinksArray = @()


# =====================================================================
# [MODE B] 후순위 처리 모드 (Deferred Run)
# =====================================================================
if ($ProcessDeferred) {
    foreach ($def in $Global:DeferredExternalLinks) {
        Write-Host "`n>>> Processing Deferred Link: $($def.Url)" -ForegroundColor Cyan
        $ExtraDir = Join-Path $def.TargetDir "Extra"
        $ExternalLinks = New-Object System.Collections.Generic.List[PSObject]
        
        $html = $null
        $needsManualAuth = $false
        
        Write-Host "  -> Attempting automated retry first..." -ForegroundColor DarkGray
        try {
            $html = (Invoke-WebRequest -Uri $def.Url -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
            Write-Host "  [SUCCESS] 차단이 해제되어 자동으로 연결되었습니다!" -ForegroundColor Green
        } catch {
            $needsManualAuth = $true
        }
        
        if ($needsManualAuth) {
            Write-Host "  [BLOCKED] Still blocked by Cloudflare." -ForegroundColor Yellow
            Start-Process $def.Url
            Write-Host "`n  [!] 브라우저가 열렸습니다. 사람 인증(CAPTCHA)을 완료하고 본문이 보이면 돌아오세요." -ForegroundColor Yellow
            Write-Host "  >>> 인증을 완료했다면 키보드의 아무 키나 누르세요... <<<" -ForegroundColor Green
            
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            
            try {
                $html = (Invoke-WebRequest -Uri $def.Url -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
            } catch {
                Write-Host "  [FAIL] 여전히 차단되었습니다: $($_.Exception.Message)" -ForegroundColor Red
                continue 
            }
        }
        
        if ($null -ne $html) {
            $orderCounter = 0
            if ($def.Type -eq 'Arca') {
                $cStart = $html.IndexOf('class="fr-view article-content"')
                if ($cStart -ge 0) {
                    $cEnd = $html.IndexOf('class="vote-area"', $cStart)
                    if ($cEnd -lt 0) { $cEnd = $html.Length }
                    $contentBlock = $html.Substring($cStart, $cEnd - $cStart)
                    [regex]::Matches($contentBlock, '(?i)<img[^>]+src="([^"]+)"') | ForEach-Object {
                        $src = $_.Groups[1].Value -replace '&amp;', '&'
                        if ($src -match 'namu\.la') {
                            if ($src -match '^//') { $src = "https:" + $src }
                            $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Order = $orderCounter++; Fallback = $null }))
                        }
                    }
                }
            } elseif ($def.Type -eq 'Kone') {
                [regex]::Matches($html, '(?i)(?:<img|\\u003cimg)\s+src=["''\\]*(https?://[^\s"''<>\\]+mittere\.io[^\s"''<>\\]+)') | ForEach-Object {
                    $src = $_.Groups[1].Value
                    $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Order = $orderCounter++; Fallback = $null }))
                }
            }
            
            $UniqueLinks = @(); $UrlCache = New-Object System.Collections.Generic.HashSet[string]
            foreach ($L in $ExternalLinks) { if ($UrlCache.Add($L.Url)) { $UniqueLinks += $L } }
            $UniqueLinks = $UniqueLinks | Sort-Object Order
            
            $ExtCount = $UniqueLinks.Count
            if ($ExtCount -gt 0) {
                if (-not [System.IO.Directory]::Exists($ExtraDir)) { [System.IO.Directory]::CreateDirectory($ExtraDir) | Out-Null }
                Write-Host "  >>> Downloading $ExtCount Images..." -ForegroundColor Magenta
                Show-VisualProgress 0 $ExtCount "Ext Progress:"
                
                $E_RunningJobs = @()
                $ExtLocalSuccess = 0; $ExtLocalFail = 0; $ExtLocalSkip = 0
                
                for ($i=0; $i -lt $ExtCount; $i++) {
                    $Item = $UniqueLinks[$i]; $BaseName = if ($RenameSequential) { "extra_$(($i+1).ToString('000'))" } else { "extra_$($i+1)" }
                    $ExistingFile = Get-ChildItem -LiteralPath $ExtraDir -Filter "$BaseName.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

                    if ($null -eq $ExistingFile) {
                        # [FIX] 스레드를 채워넣는 과정 중에도 수시로 완료 여부를 검사하여 UI를 부드럽게 갱신합니다.
                        $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                        if ($Completed) {
                            $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                            if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                            Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                            Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                            $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                        }

                        while (($E_RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                            $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                            if ($Completed) {
                                $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                                if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                                Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                                Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                                $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                            } else { Start-Sleep -Milliseconds 20 }
                        }
                        $E_RunningJobs += Start-Job -Name "DCM_DL_E_$i" -ScriptBlock {
                            param($Target, $Dest, $Idx, $BaseName, $Headers, $Proxy)
                            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                            if ($Proxy -eq "False") { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy }
                            $Url = $Target.Url; $H = $Headers.Clone(); if ($Url -notmatch "dcinside\.") { $H.Remove("Referer") }
                            for ($r=0; $r -lt 2; $r++) {
                                try {
                                    $wc = New-Object System.Net.WebClient
                                    foreach ($k in $H.Keys) { $wc.Headers.Add($k, $H[$k]) }
                                    $wc.DownloadFile($Url, $Dest); $wc.Dispose()
                                    $Stream = [System.IO.File]::OpenRead($Dest); $Bytes = New-Object byte[] 12; $Stream.Read($Bytes, 0, 12) | Out-Null; $Stream.Close()
                                    $Hex = [System.BitConverter]::ToString($Bytes); $Ext = ".jpg" 
                                    if ($Hex -match "^89-50-4E-47") { $Ext = ".png" } elseif ($Hex -match "^47-49-46-38") { $Ext = ".gif" } elseif ($Hex -match "^52-49-46-46") { $Ext = ".webp" }
                                    $Final = "$BaseName$Ext"; Rename-Item -LiteralPath $Dest -NewName $Final -Force
                                    return @{ Success=$true; Size=(Get-Item (Join-Path (Split-Path $Dest) $Final)).Length }
                                } catch { if (Test-Path $Dest) { Remove-Item $Dest -Force }; Start-Sleep -Seconds 1 }
                            }
                            return @{ Success=$false }
                        } -ArgumentList $Item, (Join-Path $ExtraDir "$BaseName.tmp"), ($i+1), $BaseName, $Headers, $UseProxy
                    } else {
                        $ExtLocalSkip++
                        Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                    }
                }
                while ($E_RunningJobs.Count -gt 0) {
                    $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                    if ($Completed) {
                        $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                        if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                        Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                        Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                        $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                    } else { Start-Sleep -Milliseconds 20 }
                }
                Write-Host "" 
            }
        }
    }
    $Global:DeferredExternalLinks.Clear()
    return
}

# =====================================================================
# [MODE A] 일반 스캔 모드 (Normal Run)
# =====================================================================
$ExtraDir = Join-Path $TargetDir "Extra"
$ExternalLinks = New-Object System.Collections.Generic.List[PSObject]

foreach ($tgLink in $TelegraphLinks) {
    Write-Host "  [EXTERNAL] Intercepted Telegraph link. Resolving: $tgLink" -ForegroundColor Magenta
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tgHtml = (Invoke-WebRequest -Uri $tgLink -UseBasicParsing -TimeoutSec 15).Content
        
        $orderCounter = $ExternalLinks.Count

        if ($tgHtml -match '(?i)href="(https?://arca\.live/b/[^"]+)"') {
            $arcaUrl = $Matches[1]
            Write-Host "  [EXTERNAL] Extracted Arca.live link: $arcaUrl" -ForegroundColor Cyan
            $ResolvedLinksArray += $arcaUrl
            
            try {
                $arcaHtml = (Invoke-WebRequest -Uri $arcaUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
                $cStart = $arcaHtml.IndexOf('class="fr-view article-content"')
                if ($cStart -ge 0) {
                    $cEnd = $arcaHtml.IndexOf('class="vote-area"', $cStart)
                    if ($cEnd -lt 0) { $cEnd = $arcaHtml.Length }
                    $contentBlock = $arcaHtml.Substring($cStart, $cEnd - $cStart)
                    [regex]::Matches($contentBlock, '(?i)<img[^>]+src="([^"]+)"') | ForEach-Object {
                        $src = $_.Groups[1].Value -replace '&amp;', '&'
                        if ($src -match 'namu\.la') {
                            if ($src -match '^//') { $src = "https:" + $src }
                            $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Order = $orderCounter++; Fallback = $null }))
                        }
                    }
                }
            } catch {
                Write-Host "  [DEFERRED] Cloudflare blocked Arca.live. Saved for later." -ForegroundColor Yellow
                $Global:DeferredExternalLinks.Add((New-Object PSObject -Property @{ Type="Arca"; Url=$arcaUrl; TargetDir=$TargetDir }))
            }
        } 
        elseif ($tgHtml -match '(?i)href="(https?://kone\.gg/s/[^"]+)"') {
            $koneUrl = $Matches[1]
            Write-Host "  [EXTERNAL] Extracted Kone.gg link: $koneUrl" -ForegroundColor Cyan
            $ResolvedLinksArray += $koneUrl
            
            try {
                $koneHtml = (Invoke-WebRequest -Uri $koneUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
                [regex]::Matches($koneHtml, '(?i)(?:<img|\\u003cimg)\s+src=["''\\]*(https?://[^\s"''<>\\]+mittere\.io[^\s"''<>\\]+)') | ForEach-Object {
                    $src = $_.Groups[1].Value
                    $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Order = $orderCounter++; Fallback = $null }))
                }
            } catch {
                Write-Host "  [DEFERRED] Cloudflare/Timeout blocked Kone.gg. Saved for later." -ForegroundColor Yellow
                $Global:DeferredExternalLinks.Add((New-Object PSObject -Property @{ Type="Kone"; Url=$koneUrl; TargetDir=$TargetDir }))
            }
        }
        else {
            Write-Host "  [EXTERNAL] No external board found. Scanning direct Telegraph images..." -ForegroundColor Cyan
            $ResolvedLinksArray += $tgLink
            [regex]::Matches($tgHtml, '(?i)<img[^>]+src="([^"]+)"') | ForEach-Object {
                $src = $_.Groups[1].Value
                if ($src -match '^/file/') { $src = "https://telegra.ph" + $src }
                if ($src -match '^http') { $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Order = $orderCounter++; Fallback = $null })) }
            }
        }
    } catch { Write-Host "  [WARN] Failed to resolve Telegraph link." -ForegroundColor Yellow }
}

$UniqueLinks = @()
$UrlCache = New-Object System.Collections.Generic.HashSet[string]

foreach ($L in $ExternalLinks) {
    if ($UrlCache.Add($L.Url)) { 
        $UniqueLinks += $L
    }
}

$UniqueLinks = $UniqueLinks | Sort-Object Order
$ExtCount = $UniqueLinks.Count

if ($ExtCount -gt 0) {
                if (-not [System.IO.Directory]::Exists($ExtraDir)) { [System.IO.Directory]::CreateDirectory($ExtraDir) | Out-Null }
                Write-Host "  >>> Downloading $ExtCount Images..." -ForegroundColor Magenta
                Show-VisualProgress 0 $ExtCount "Ext Progress:"
                
                $E_RunningJobs = @()
                $ExtLocalSuccess = 0; $ExtLocalFail = 0; $ExtLocalSkip = 0
                
                for ($i=0; $i -lt $ExtCount; $i++) {
                    $Item = $UniqueLinks[$i]; $BaseName = if ($RenameSequential) { "extra_$(($i+1).ToString('000'))" } else { "extra_$($i+1)" }
                    $ExistingFile = Get-ChildItem -LiteralPath $ExtraDir -Filter "$BaseName.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

                    if ($null -eq $ExistingFile) {
                        # [FIX] 일반 스캔 모드에서도 매 턴 수시로 검사합니다.
                        $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                        if ($Completed) {
                            $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                            if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                            Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                            Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                            $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                        }

                        while (($E_RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                            $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                            if ($Completed) {
                                $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                                if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                                Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                                Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                                $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                            } else { Start-Sleep -Milliseconds 20 }
                        }
                        $E_RunningJobs += Start-Job -Name "DCM_DL_E_$i" -ScriptBlock {
                            param($Target, $Dest, $Idx, $BaseName, $Headers, $Proxy)
                            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                            if ($Proxy -eq "False") { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy }
                            $Url = $Target.Url; $H = $Headers.Clone(); if ($Url -notmatch "dcinside\.") { $H.Remove("Referer") }
                            for ($r=0; $r -lt 2; $r++) {
                                try {
                                    $wc = New-Object System.Net.WebClient
                                    foreach ($k in $H.Keys) { $wc.Headers.Add($k, $H[$k]) }
                                    $wc.DownloadFile($Url, $Dest); $wc.Dispose()
                                    $Stream = [System.IO.File]::OpenRead($Dest); $Bytes = New-Object byte[] 12; $Stream.Read($Bytes, 0, 12) | Out-Null; $Stream.Close()
                                    $Hex = [System.BitConverter]::ToString($Bytes); $Ext = ".jpg" 
                                    if ($Hex -match "^89-50-4E-47") { $Ext = ".png" } elseif ($Hex -match "^47-49-46-38") { $Ext = ".gif" } elseif ($Hex -match "^52-49-46-46") { $Ext = ".webp" }
                                    $Final = "$BaseName$Ext"; Rename-Item -LiteralPath $Dest -NewName $Final -Force
                                    return @{ Success=$true; Size=(Get-Item (Join-Path (Split-Path $Dest) $Final)).Length }
                                } catch { if (Test-Path $Dest) { Remove-Item $Dest -Force }; Start-Sleep -Seconds 1 }
                            }
                            return @{ Success=$false }
                        } -ArgumentList $Item, (Join-Path $ExtraDir "$BaseName.tmp"), ($i+1), $BaseName, $Headers, $UseProxy
                    } else {
                        $ExtLocalSkip++
                        Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                    }
                }
                while ($E_RunningJobs.Count -gt 0) {
                    $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                    if ($Completed) {
                        $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                        if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtLocalSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++; $ExtLocalFail++ } } }
                        Show-VisualProgress ($ExtLocalSuccess + $ExtLocalFail + $ExtLocalSkip) $ExtCount "Ext Progress:"
                        Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                        $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                    } else { Start-Sleep -Milliseconds 20 }
                }
                Write-Host "" 
            }
return [PSCustomObject]@{ Success = $ExtSuccess; Fail = $ExtFail; Bytes = $ExtBytes; ResolvedLinks = $ResolvedLinksArray }