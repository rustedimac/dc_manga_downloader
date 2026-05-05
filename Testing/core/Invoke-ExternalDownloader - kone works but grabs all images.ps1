# ==========================================
# DC Manga - External Link Downloader (Telegraph / Arca.live / Kone.gg)
# ==========================================
param (
    [string[]]$TelegraphLinks,
    [string]$TargetDir,
    [int]$MaxThreads,
    [hashtable]$Headers,
    [string]$UseProxy,
    [bool]$RenameSequential
)

$ExtSuccess = 0; $ExtFail = 0; $ExtBytes = 0
$ExtraDir = Join-Path $TargetDir "Extra"
$ExternalLinks = New-Object System.Collections.Generic.List[PSObject]

foreach ($tgLink in $TelegraphLinks) {
    Write-Host "  [EXTERNAL] Intercepted Telegraph link. Resolving: $tgLink" -ForegroundColor Magenta
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tgHtml = (Invoke-WebRequest -Uri $tgLink -UseBasicParsing -TimeoutSec 15).Content
        
        # 1. Arca.live
        if ($tgHtml -match '(?i)href="(https?://arca\.live/b/[^"]+)"') {
            $arcaUrl = $Matches[1]
            Write-Host "  [EXTERNAL] Extracted Arca.live link: $arcaUrl" -ForegroundColor Cyan
            $arcaHtml = (Invoke-WebRequest -Uri $arcaUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
            $cStart = $arcaHtml.IndexOf('class="fr-view article-content"')
            if ($cStart -ge 0) {
                $cEnd = $arcaHtml.IndexOf('class="article-footer"', $cStart)
                if ($cEnd -lt 0) { $cEnd = $arcaHtml.Length }
                $contentBlock = $arcaHtml.Substring($cStart, $cEnd - $cStart)
                [regex]::Matches($contentBlock, '(?i)<img[^>]+src="([^"]+)"') | ForEach-Object {
                    $src = $_.Groups[1].Value -replace '&amp;', '&'
                    if ($src -match 'namu\.la') {
                        if ($src -match '^//') { $src = "https:" + $src }
                        $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Fallback = $null }))
                    }
                }
            }
        } 
        # 2. Kone.gg
        elseif ($tgHtml -match '(?i)href="(https?://kone\.gg/s/[^"]+)"') {
            $koneUrl = $Matches[1]
            Write-Host "  [EXTERNAL] Extracted Kone.gg link: $koneUrl" -ForegroundColor Cyan
            $koneHtml = (Invoke-WebRequest -Uri $koneUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15).Content
            $decodedHtml = [System.Net.WebUtility]::HtmlDecode($koneHtml)
            
            # [FIX] ParserError 해결 및 역슬래시 인코딩 대응 정규식
            [regex]::Matches($decodedHtml, '(?i)https?[:\\/]+[a-zA-Z0-9\-\.]*mittere\.io[^\s"''<>\}]+') | ForEach-Object {
                $src = $_.Value -replace '\\/', '/' -replace '\\$', '' -replace '"$', ''
                $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Fallback = $null }))
            }
        }
        # 3. Direct Telegraph
        else {
            Write-Host "  [EXTERNAL] No external board found. Scanning direct Telegraph images..." -ForegroundColor Cyan
            [regex]::Matches($tgHtml, '(?i)<img[^>]+src="([^"]+)"') | ForEach-Object {
                $src = $_.Groups[1].Value
                if ($src -match '^/file/') { $src = "https://telegra.ph" + $src }
                if ($src -match '^http') { $ExternalLinks.Add((New-Object PSObject -Property @{ Url = $src; Fallback = $null })) }
            }
        }
    } catch { Write-Host "  [WARN] Failed to resolve External link." -ForegroundColor Yellow }
}

# 중복 제거 및 다운로드 로직 (원래 코드 유지)
$UniqueLinks = $ExternalLinks | Group-Object Url | ForEach-Object { $_.Group[0] }
$ExtCount = $UniqueLinks.Count

if ($ExtCount -gt 0) {
    if (-not [System.IO.Directory]::Exists($ExtraDir)) { [System.IO.Directory]::CreateDirectory($ExtraDir) | Out-Null }
    Write-Host "  >>> Downloading $ExtCount External Images into \Extra subfolder..." -ForegroundColor Magenta
    
    $E_RunningJobs = @()
    for ($i=0; $i -lt $ExtCount; $i++) {
        $Item = $UniqueLinks[$i]; $BaseName = if ($RenameSequential) { "extra_$(($i+1).ToString('000'))" } else { "extra_$($i+1)" }
        $ExistingFile = Get-ChildItem -LiteralPath $ExtraDir -Filter "$BaseName.*" -File | Where-Object { $_.Extension -match 'jpg|png|gif|webp' } | Select-Object -First 1

        if ($null -eq $ExistingFile) {
            while (($E_RunningJobs | Where-Object { $_.State -eq 'Running' }).Count -ge $MaxThreads) { 
                $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
                if ($Completed) {
                    $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
                    if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++ } } }
                    Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
                    $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
                }
                Start-Sleep -Milliseconds 50 
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
        }
    }
    while ($E_RunningJobs.Count -gt 0) {
        $Completed = $E_RunningJobs | Where-Object { $_.State -ne 'Running' }
        if ($Completed) {
            $Results = Receive-Job -Job $Completed -ErrorAction SilentlyContinue 2>$null
            if ($null -ne $Results) { foreach ($R in $Results) { if ($R.Success) { $ExtSuccess++; $ExtBytes += $R.Size } elseif ($null -ne $R.Success) { $ExtFail++ } } }
            Remove-Job -Job $Completed -Force -ErrorAction SilentlyContinue 2>$null
            $E_RunningJobs = @($E_RunningJobs | Where-Object { $_.State -eq 'Running' })
        } else { Start-Sleep -Milliseconds 50 }
    }
}
return [PSCustomObject]@{ Success = $ExtSuccess; Fail = $ExtFail; Bytes = $ExtBytes }