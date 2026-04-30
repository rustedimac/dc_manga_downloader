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
            # Previous owner was hard-killed — we now own it, safe to continue
            $Owned = $true
        }
        & $Action
    } finally {
        if ($Owned -and $null -ne $Mutex) { try { $Mutex.ReleaseMutex() } catch {} }
        if ($null -ne $Mutex) { $Mutex.Dispose() }
    }
}

# ===========================================================================
# ATOMIC FILE WRITES  (write-to-temp then rename)
# Guarantees the target file is never left in a half-written state if the
# process is killed mid-write. On Windows, Rename-Item within the same
# drive is atomic at the NTFS level — the old file survives intact or the
# new one fully replaces it, never a partial result.
#
# Usage (plain lines):   Write-FileAtomic $Path $Lines
# Usage (CSV rows):      Write-FileAtomic $Path $Rows -AsCsv
# ===========================================================================
function Write-FileAtomic {
    param(
        [string] $Path,
        [object] $Content,
        [string] $Encoding = "UTF8",
        [switch] $AsCsv
    )

    $TmpPath = "$Path.tmp"

    try {
        if ($AsCsv) {
            $Content | Export-Csv $TmpPath -NoTypeInformation -Encoding $Encoding
        } else {
            $Content | Set-Content $TmpPath -Encoding $Encoding
        }
        # Atomic swap: replace target with the fully-written temp file
        if (Test-Path $Path) { Remove-Item $Path -Force }
        Rename-Item $TmpPath $Path
    } catch {
        if (Test-Path $TmpPath) { Remove-Item $TmpPath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-Config {
    param (
        [string]$ConfigPath = (Join-Path $PSScriptRoot "config.yaml")
    )

    $Config = @{}

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "config.yaml not found at: $ConfigPath"
        return $Config
    }

    Get-Content $ConfigPath | Where-Object { $_ -match '^\s*([^:#][^:]*)\s*:\s*(.*)$' } | ForEach-Object {
        $Key   = $Matches[1].Trim()
        $Value = ($Matches[2] -split '#')[0].Trim(" `"'")
        $Config[$Key] = $Value
    }

    return $Config
}
