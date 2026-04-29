param($LogPath)
$PipeName = "DCMangaLogger"
$Encoding = [System.Text.Encoding]::UTF8

# Try to create the server. If it fails, exit instead of looping on nulls.
try {
    $Server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, 'In')
    $Reader = New-Object System.IO.StreamReader($Server, $Encoding)
} catch {
    Write-Host "CRITICAL ERROR: Could not start Pipe Server. Is another logger running?" -ForegroundColor Red
    Start-Sleep -Seconds 5
    exit
}

Write-Host ">>> Logger Background Process Started. Monitoring..." -ForegroundColor Gray

while ($true) {
    try {
        # Check if Server exists before calling methods
        if ($null -eq $Server) { break }

        if (-not $Server.IsConnected) { 
            $Server.WaitForConnection() 
        }
        if (-not $GlobalConfig) { return }

		# Safely create directory if it doesn't exist yet
		$LogFile = Join-Path $PSScriptRoot $GlobalConfig.LogPath
		$LogDir = Split-Path $LogFile
		if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        
		$Line = $Reader.ReadLine()
        
        if ($null -ne $Line) { 
            $Line | Add-Content -LiteralPath $LogPath 
        } else { 
            # Client disconnected
            $Server.Disconnect() 
        }
    } catch {
        # If an error happens, wait a moment to prevent non-stop error spam
        Write-Host "Logger Loop Warning: $($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 500
    }
}