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
        echo # --- 1. CORE SETTINGS ---
        echo BoardUrl: "https://gall.dcinside.com/board/lists/?id=comic_new6^&exception_mode=recommend"
        echo.
        echo # --- 2. CRAWLER ^& SEARCH LIMITS ---
        echo AutoCrawlerMaxPages: 1
        echo SeriesBrowserMaxPages: 50
        echo KeywordSearchMaxBlocks: 300
        echo CrawlOrder: 0
        echo KeepUnfinishedLinks: False
        echo.
        echo # --- 3. DOWNLOADER ENGINE ---
        echo DownloadDir: ".\Downloads"
        echo MaxConcurrentDownloads: 15
        echo RateLimitSeconds: 2.5
        echo RenameFilesSequential: True
        echo CustomStripChars: ""
        echo ShowProgressBar: False
        echo.
        echo # --- 4. NETWORK ^& CONNECTION ---
        echo DNSAutoRepair: True
        echo UseProxy: False
        echo.
        echo # --- 5. DATA ^& TRACKING PATHS ---
        echo DownloadListPath: ".\Data\download_list.txt"
        echo CatalogCsvPath: ".\Data\series_catalog.csv"
        echo.
        echo # --- 6. LOGGING SYSTEM ---
        echo LogPath: ".\logs\Start-Downloader\download_logs.json"
        echo LogLevel: "Verbose"
        echo AutoCrawlerLogPath: ".\logs\Run-Crawler\autocrawl_logs.json"
        echo CrawlerLogDir: ".\logs"
        echo CrawlerLogLevel: "Verbose"
        echo CrawlerLogMaxMB: 10
        echo CrawlerLogMaxFiles: 5
        echo.
        echo # --- 7. SCHEDULER SETTINGS ---
        echo AutoCrawlerIntervalHours: 1
        echo BoardCrawlerIntervalHours: 12
        echo.
        echo # --- 8. ADVANCED / SYSTEM ---
        echo ForceLegacyMode: False
    ) > "%CONFIG_FILE%"
    echo [OK] config.yaml has been restored.
)

:: --- 2. ENGINE DETECTION (Restored Sub-Shell Method) ---
:: This is what you had before. It uses a small PS call to check the config.
for /f "tokens=*" %%A in ('powershell -NoProfile -Command "try { $v = (Get-Content '%CONFIG_FILE%' | Where-Object { $_ -match '^\s*ForceLegacyMode\s*:\s*(.+)' } | Select-Object -First 1); if ($v -match 'True') { 'True' } else { 'False' } } catch { 'False' }"') do (
    set "FORCE_LEGACY=%%A"
)

if /i "!FORCE_LEGACY!"=="True" (
    set "PS_EXE=powershell.exe"
) else (
    where pwsh >nul 2>nul && set "PS_EXE=pwsh.exe" || set "PS_EXE=powershell.exe"
)

:: --- 3. LOGGER ---
if exist "%~dp0Background-Logger.ps1" (
    start "DCM_Logger_Process" /min "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Background-Logger.ps1" -LogPath "%~dp0activity_log.json"
)

:MENU
set "SCHED_STATE=OFF"
tasklist /fi "WINDOWTITLE eq DC Manga Scheduler*" 2>nul | find /i ".exe" >nul && set "SCHED_STATE=ON"

cls
echo ==========================================
echo         DC Manga Downloader Suite
echo         Target Engine: !PS_EXE!
echo ==========================================
echo  1. Run Auto-Crawler ^& Downloader (Single Pass)
echo  2. Run Manual Downloader (Pasted URLs)
echo  3. Search / Series Browser
echo  4. Toggle Background Scheduler (Status: !SCHED_STATE!)
echo  0. Exit
echo ==========================================
set /p choice="Select an option: "

if "%choice%"=="1" goto AUTO_FLOW
if "%choice%"=="2" goto DOWNLOADER
if "%choice%"=="3" goto SEARCH
if "%choice%"=="4" goto TOGGLE_SCHEDULER
if "%choice%"=="0" goto CLEAN_EXIT
goto MENU

:AUTO_FLOW
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Crawler.ps1"
pause
goto MENU

:DOWNLOADER
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Downloader.ps1"
pause
goto MENU

:SEARCH
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Search-Crawler.ps1"
pause
goto MENU

:TOGGLE_SCHEDULER
if "!SCHED_STATE!"=="ON" (
    echo [INFO] Stopping Background Scheduler...
    taskkill /FI "WINDOWTITLE eq DC Manga Scheduler*" /T /F >nul 2>&1
    timeout /t 2 >nul
    goto MENU
)

echo.
echo === Start Background Scheduler ===
echo Leave blank to use defaults from config.yaml
set "AUTO_INT="
set /p "AUTO_INT=Auto-Crawler interval (hours): "
set "BOARD_INT="
set /p "BOARD_INT=Board Crawler interval (hours): "

set "ARGS="
if not "!AUTO_INT!"=="" set "ARGS=-AutoInterval !AUTO_INT!"
if not "!BOARD_INT!"=="" set "ARGS=!ARGS! -BoardInterval !BOARD_INT!"

start "DC Manga Scheduler" "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Scheduler.ps1" !ARGS!
timeout /t 2 >nul
goto MENU

:CLEAN_EXIT
taskkill /FI "WINDOWTITLE eq DCM_Logger_Process*" /T /F >nul 2>&1
exit