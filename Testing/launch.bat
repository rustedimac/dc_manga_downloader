@echo off
setlocal enabledelayedexpansion
title DC Manga Downloader Suite
color 0B

:: --- 1. CONFIG GUARD (Exact Definitive Restore) ---
set "CONFIG_FILE=%~dp0config.yaml"

if not exist "%CONFIG_FILE%" (
    echo [WARN] config.yaml missing! Regenerating definitive defaults...
    (
        echo # ==========================================
        echo # DC Manga Downloader Suite - Definitive Config
        echo # ==========================================
        echo.
        echo # --- Target Settings ---
        echo # The board URL to scan ^(Recommendation Board^)
        echo BoardUrl: "https://gall.dcinside.com/board/lists/?id=comic_new6&exception_mode=recommend"
        echo.
        echo # Number of pages to look back ^(Crawler scans from Page X down to 1^)
        echo MaxPages: 3
        echo.
        echo # Crawl Direction: 0 = Oldest First ^(Page 3 -^> 1^), 1 = Newest First ^(Page 1 -^> 3^)
        echo CrawlOrder: 0
        echo.
        echo # If True, the crawler appends to the list instead of wiping it fresh.
        echo # Note: Downloader always removes successful links regardless of this setting.
        echo KeepUnfinishedLinks: False
        echo.
        echo # --- Network Settings ---
        echo # Set to True to allow the script to flush DNS and wait 10s on "No such host" errors
        echo DNSAutoRepair: True
        echo.
        echo # Set to False to bypass system proxies ^(recommended for direct connection speed^)
        echo UseProxy: False
        echo.
        echo # Delay between processing each Manga Post ^(in seconds^) to avoid IP blocks
        echo RateLimitSeconds: 2.5
        echo.
        echo # Max images to download at the same time ^(Range: 1 to 5^)
        echo # 3 is the "Sweet Spot" for speed vs stability.
        echo MaxConcurrentDownloads: 3
        echo.
        echo # --- Downloader Settings ---
        echo # Folder where images will be saved ^(relative .\ or absolute path^)
        echo DownloadDir: ".\Downloads"
        echo.
        echo # Path to the activity log ^(JSON format^)
        echo LogPath: ".\activity_log.json"
        echo.
        echo # Logging detail: "Verbose" logs every image, "Error" logs only failures
        echo LogLevel: "Verbose"
        echo.
        echo # Set to False to hide the native PowerShell download bar for a cleaner console
        echo ShowProgressBar: False
        echo.
        echo # Set to True to rename images to 001.jpg, 002.jpg, etc.
        echo RenameFilesSequential: True
        echo.
        echo # Extra characters to strip from folder names ^(e.g., "$@"^)
        echo CustomStripChars: ""
        echo.
        echo # --- Debug ^& Compatibility ---
        echo # Set to True to force the use of powershell.exe ^(v5.1^) even if pwsh ^(v7^) is installed.
        echo # If False, the script will automatically prefer pwsh.exe and fallback to powershell.exe.
        echo ForceLegacyMode: False
    ) > "%CONFIG_FILE%"
    echo [OK] config.yaml has been restored.
)

:: --- 2. DETECTION ---
:: Let PowerShell read its own config rather than parsing YAML in batch.
:: We ask a small inline PS snippet to extract ForceLegacyMode safely.
set "PS_EXE=powershell.exe"
for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command "try { $v = (Get-Content '%CONFIG_FILE%' | Where-Object { $_ -match '^\s*ForceLegacyMode\s*:\s*(.+)' } | Select-Object -First 1); if ($v -match 'True') { 'True' } else { 'False' } } catch { 'False' }"`) do (
    set "FORCE_LEGACY=%%A"
)

if /i "!FORCE_LEGACY!"=="True" (
    set "PS_EXE=powershell.exe"
) else (
    where pwsh >nul 2>nul && set "PS_EXE=pwsh.exe" || set "PS_EXE=powershell.exe"
)

:: --- 3. LOGGER ---
start "DCM_Logger_Process" /min "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Background-Logger.ps1" -LogPath "%~dp0activity_log.json"

:MENU
cls
echo ==========================================
echo         DC Manga Downloader Suite
echo         Target Engine: !PS_EXE!
echo ==========================================
echo  1. Run Auto-Crawler ^& Downloader
echo  2. Run Manual Downloader (Pasted URLs)
echo  3. Search / Series Browser
echo  4. Exit
echo ==========================================
set /p choice="Select an option (1-4): "

if "%choice%"=="1" goto AUTO_FLOW
if "%choice%"=="2" goto DOWNLOADER
if "%choice%"=="3" goto SEARCH
if "%choice%"=="4" goto CLEAN_EXIT
goto MENU

:AUTO_FLOW
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Crawler.ps1"
pause
goto MENU

:DOWNLOADER
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Downloader.ps1"
goto MENU

:SEARCH
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Search-Crawler.ps1"
pause
goto MENU

:CLEAN_EXIT
taskkill /FI "WINDOWTITLE eq DCM_Logger_Process*" /T /F >nul 2>&1
exit
