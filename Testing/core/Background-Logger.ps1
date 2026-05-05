param($LogPath)
$PipeName = "DCMangaLogger"
$Encoding = [System.Text.Encoding]::UTF8

# Load configuration so the logger knows where to write
$RootDir = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "Get-Config.ps1")

# 안전하게 명시적 경로 전달
$Config = Get-Config -ConfigPath (Join-Path $RootDir "config.yaml")

try {
    $Server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, 'In')
    $Reader = New-Object System.IO.StreamReader($Server, $Encoding)
} catch {
    Write-Host "CRITICAL ERROR: Could not start Pipe Server. Is another logger running?" -ForegroundColor Red
    Start-Sleep -Seconds 5
    exit
}

Write-Host ">>> Logger Background Process Started. Monitoring..." -ForegroundColor Gray

# [NEW] 이중 안전장치: Config가 비어있어도 무조건 파일명(downloader_log.json)을 생성하도록 강제
$TargetLogPath = if (-not [string]::IsNullOrWhiteSpace($Config.LogPath)) { $Config.LogPath } else { "Logs\downloader_log.json" }

while ($true) {
    try {
        if ($null -eq $Server) { break }
        if (-not $Server.IsConnected) { $Server.WaitForConnection() }

        # Safely create directory using the verified TargetLogPath
        $LogFile = if ([System.IO.Path]::IsPathRooted($TargetLogPath)) { 
            $TargetLogPath 
        } else { 
            Join-Path $RootDir ($TargetLogPath -replace '^\.\\', '') 
        }
        
        $LogDir = Split-Path $LogFile
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        
        $Line = $Reader.ReadLine()
        
        if ($null -ne $Line) { 
            $Line | Add-Content -LiteralPath $LogFile -Encoding $Encoding
        } else { 
            $Server.Disconnect() 
        }
    } catch {
        try { $Server.Disconnect() } catch {}
        Start-Sleep -Milliseconds 100
    }
}