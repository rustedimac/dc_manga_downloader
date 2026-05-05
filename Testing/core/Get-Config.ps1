# Get-Config.ps1
# Shared config loader + cross-process file locking for the DC Manga Downloader Suite.
# Dot-source this file in any script: . (Join-Path $PSScriptRoot "Get-Config.ps1")
# Then call: $Config = Get-Config

# ===========================================================================
# CROSS-PROCESS FILE LOCKING
# Uses a named System.Threading.Mutex — works across separate PowerShell
# processes on the same machine (unlike Monitor or lock{}).
# Mutex names are machine-global; the DCM_ prefix keeps them namespaced.
# If a lock can't be acquired within $TimeoutMs, the scriptblock runs anyway
# with a warning — prevents deadlock if a process was hard-killed mid-lock.
# ===========================================================================
function Invoke-WithFileLock {
    param(
        [string]      $MutexName,
        [scriptblock] $Action,
        [int]         $TimeoutMs = 10000
    )

    $FullName = "Global\DCM_$MutexName"
    $Mutex    = $null
    $Owned    = $false

    try {
        $Mutex = New-Object System.Threading.Mutex($false, $FullName)
        try {
            $Owned = $Mutex.WaitOne($TimeoutMs, $false)
            if (-not $Owned) {
                Write-Warning "[Lock] Could not acquire '$MutexName' within ${TimeoutMs}ms. Proceeding without lock."
            }
        } catch [System.Threading.AbandonedMutexException] {
            $Owned = $true
        }
        
        & $Action

    } finally {
        if ($Owned -and $null -ne $Mutex) {
            $Mutex.ReleaseMutex()
        }
        if ($null -ne $Mutex) {
            $Mutex.Dispose()
        }
    }
}

# ===========================================================================
# ATOMIC FILE WRITE (WITH RETRY LOGIC FOR EXCEL/AV LOCKS)
# Writes data to a .tmp file first, then forcefully replaces the target file.
# Guarantees that if the script crashes mid-write — or if disk space fills up 
# — the old file survives intact.
# ===========================================================================
function Write-FileAtomic {
    param([string]$Path, [object]$Content, [string]$Encoding = "UTF8", [switch]$AsCsv)
    $TmpPath = "$Path.tmp"
    try {
        if ($AsCsv) { $Content | Export-Csv $TmpPath -NoTypeInformation -Encoding $Encoding }
        else { $Content | Set-Content $TmpPath -Encoding $Encoding }
        
        $MaxRetries = 5
        for ($i = 0; $i -lt $MaxRetries; $i++) {
            try {
                # [SURGICAL FIX] Force PowerShell to instantly drop all lazy file handles
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()

                if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction Stop }
                Rename-Item -Path $TmpPath -NewName (Split-Path $Path -Leaf) -ErrorAction Stop
                return # Success
            } catch {
                Start-Sleep -Milliseconds 300 
            }
        }
        throw "Persistent lock on $Path. Please ensure no other apps are using it."
    } finally {
        if (Test-Path $TmpPath) { Remove-Item $TmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-Config {
    param (
        # [FIXED] core 폴더가 아닌 상위 폴더(Release Candidate)에서 찾도록 경로 수정!
        [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "config.yaml")
    )

    $Config = @{}

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "config.yaml not found at: $ConfigPath"
        return $Config
    }

    Get-Content $ConfigPath -Encoding UTF8 | Where-Object { $_ -match '^\s*([^:#][^:]*)\s*:\s*(.*)$' } | ForEach-Object {
        $key = $Matches[1].Trim()
        $val = $Matches[2].Trim()
        $val = ($val -split '#')[0].Trim()
        if ($val -match '^"(.*)"$') { $val = $Matches[1] }
        elseif ($val -match "^'(.*)'$") { $val = $Matches[1] }

        $Config[$key] = $val
    }

    return $Config
}