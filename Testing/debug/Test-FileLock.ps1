# Setup Absolute Paths for testing
$TestDir = $PWD.Path
$TestFile = Join-Path $TestDir "test_queue.txt"
$TmpFile = Join-Path $TestDir "test_queue.txt.tmp"

# Create a fresh dummy file
"initial data" | Set-Content $TestFile -Encoding UTF8

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " TEST 1: The PowerShell Way (Your Current Code)" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
try {
    for ($i = 1; $i -le 100; $i++) {
        # 1. Read (The Lazy Handle)
        $Lines = Get-Content $TestFile -Encoding UTF8
        
        # 2. Filter (Pipeline)
        $Updated = @($Lines | Where-Object { $_ -ne "delete_me" })
        $Updated += "Iteration $i"
        
        # 3. Write Temp
        $Updated | Set-Content $TmpFile -Encoding UTF8
        
        # 4. Atomic Replace (Remove + Rename)
        if (Test-Path $TestFile) { Remove-Item $TestFile -Force -ErrorAction Stop }
        Rename-Item -Path $TmpFile -NewName "test_queue.txt" -ErrorAction Stop
        
        Write-Host " Iteration $i passed..." -ForegroundColor DarkGray
    }
    Write-Host "Test 1 somehow finished without locking!" -ForegroundColor Green
} catch {
    Write-Host "`n[!] TEST 1 CRASHED AT ITERATION $i" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

# ---------------------------------------------------------
# Wait a moment, clean up, and prepare for Test 2
Start-Sleep -Seconds 2
if (Test-Path $TmpFile) { Remove-Item $TmpFile -Force -ErrorAction SilentlyContinue }
"initial data" | Set-Content $TestFile -Encoding UTF8

Write-Host "`n=====================================================" -ForegroundColor Green
Write-Host " TEST 2: The .NET Way (The Proposed Fix)" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
try {
    for ($i = 1; $i -le 100; $i++) {
        # 1. Read (.NET Synchronous Read - Instantly destroys handle)
        $Lines = [System.IO.File]::ReadAllLines($TestFile)
        
        # 2. Filter (Pipeline)
        $Updated = @($Lines | Where-Object { $_ -ne "delete_me" })
        $Updated += "Iteration $i"
        
        # 3. Write Temp
        $Updated | Set-Content $TmpFile -Encoding UTF8
        
        # 4. Atomic Replace (Single OS operation)
        Move-Item -LiteralPath $TmpFile -Destination $TestFile -Force -ErrorAction Stop
        
        Write-Host " Iteration $i passed..." -ForegroundColor DarkGray
    }
    Write-Host "`n[SUCCESS] TEST 2 COMPLETED ALL 100 ITERATIONS WITHOUT A SINGLE LOCK!" -ForegroundColor Green
} catch {
    Write-Host "`n[!] TEST 2 CRASHED AT ITERATION $i" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Final Cleanup
Remove-Item $TestFile -Force -ErrorAction SilentlyContinue
Remove-Item $TmpFile -Force -ErrorAction SilentlyContinue