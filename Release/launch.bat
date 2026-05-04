@echo off
setlocal enabledelayedexpansion
title DC Manga Downloader Suite
color 0B

:: --- 1. CONFIG & DIRECTORY SETTINGS ---
set "ROOT_DIR=%~dp0"
set "CONFIG_FILE=%ROOT_DIR%config.yaml"
set "CORE_DIR=%ROOT_DIR%core\"

:: Ensure core folder exists
if not exist "%CORE_DIR%" (
    echo [ERROR] 'core' folder not found. Please move .ps1 files to \core\
    pause
    exit
)

:: --- 2. CONFIG GUARD (Exact Restore) ---
if exist "%CONFIG_FILE%" goto :DETECTION
echo [WARN] config.yaml missing!
echo Regenerating definitive defaults...

(
echo # ==========================================
echo # DC Manga Downloader
echo # ==========================================
echo.
echo # --- 1. CORE SETTINGS ---
echo # The board URL to scan ^(Recommendation Board^)
echo BoardUrl: "https://gall.dcinside.com/board/lists/?id=comic_new6&exception_mode=recommend"
echo.
echo # Set to False to crawl all posts, ignoring the "번역" ^(Translation^) prefix. 
echo # Useful for boards with dedicated translation categories ^(e.g., search_head=10^).
echo RequireTranslationPrefix: "True"
echo.
echo # Set to True to bypass the download history check.
echo # Smart Update: It will only download new/missing images if the folder exists, 
echo # or redownload entirely if you manually deleted the folder.
echo ForceRedownload: "False"
echo.
echo.
echo # --- 2. CRAWLER ^& SEARCH LIMITS ---
echo # Pages scanned by the Auto-Crawler ^(Run-Crawler.ps1^)
echo # Keep this low ^(1-3^) for regular scheduled background use.
echo AutoCrawlerMaxPages: 1
echo.
echo # Pages scanned by the Board Series Scanner ^(Search-Scanner.ps1, option 3^)
echo # Each page is fully visited to check for [시리즈] blocks.
echo SeriesBrowserMaxPages: 10
echo.
echo # Max time-blocks searched by the Keyword Deep-Search ^(Search-Scanner.ps1, option 1^)
echo # 300 = exhaustive full history search. Lower this ^(e.g. 10^) 
echo # for faster targeted searches.
echo KeywordSearchMaxBlocks: 300
echo.
echo # Crawl Direction: 0 = Oldest First ^(Page 3 -^> 1^), 1 = Newest First ^(Page 1 -^> 3^)
echo CrawlOrder: 0
echo.
echo # If True, the auto-crawler appends to the list instead of wiping it fresh.
echo KeepUnfinishedLinks: False
echo.
echo # Pipe-separated list ^(^|^) of junk series titles to ignore ^(triggers chapter-name parsing fallback^)
echo JunkSeriesTitles: "ㅇㅇ|1|UNKNOWN|.|잽랜드|단편|모음|단편 모음|이전화|다음화|목차|북마크|링크|북마크 찐빠있으면 말해줘 그럼 수정함|갓갓 갓갓갓|(내가 번역한 건 아니지만)|번역 기다리는 동안 볼 만화|유동 번역 백업|없는 화는 그 사이트로|ETC"
echo.
echo # If True, dynamically hunts for older chapters missing from the current series block
echo DaisyChainSeries: True
echo.
echo.
echo # --- 3. DOWNLOADER ENGINE ---
echo # Folder where images will be saved ^(relative .\ or absolute path^)
echo DownloadDir: ".\Downloads"
echo.
echo # Max images to download at the same time.
echo MaxConcurrentDownloads: 15
echo.
echo # Delay between processing each Manga Post ^(in seconds^) to avoid IP blocks
echo RateLimitSeconds: 2.5
echo.
echo # Set to True to rename images sequentially ^(001.jpg, 002.jpg, etc.^)
echo RenameFilesSequential: True
echo.
echo # Extra characters to strip from folder names ^(e.g., "$@"^)
echo CustomStripChars: ""
echo.
echo # Set to False to hide the native PowerShell download bar for a cleaner console
echo ShowProgressBar: False
echo.
echo.
echo # --- 4. NETWORK ^& CONNECTION ---
echo # Set to True to allow the script to flush DNS and wait 10s on "No such host" errors
echo DNSAutoRepair: True
echo.
echo # Set to False to bypass system proxies ^(recommended for direct connection speed^)
echo UseProxy: False
echo.
echo.
echo # --- 5. DATA ^& TRACKING PATHS ---
echo # Custom paths for tracking files ^(relative .\ or absolute path^)
echo DownloadListPath: ".\Data\download_list.txt"
echo CatalogCsvPath: ".\Data\series_catalog.csv"
echo.
echo.
echo # --- 6. LOGGING SYSTEM ---
echo # Logging detail levels: "Verbose", "Info", "Warn", "Error"
echo.
echo # Downloader Logs
echo LogPath: ".\logs\Start-Downloader\download_logs.json"
echo LogLevel: "Verbose"
echo.
echo # Auto-Crawler Logs
echo AutoCrawlerLogPath: ".\logs\Run-Crawler\autocrawl_logs.json"
echo.
echo # Search-Scanner Logs
echo CrawlerLogDir: ".\logs"
echo CrawlerLogLevel: "Verbose"
echo.
echo # Log Rotation Limits ^(Additive^)
echo CrawlerLogMaxMB: 10
echo CrawlerLogMaxFiles: 5
echo.
echo # --- 7. SCHEDULER SETTINGS ---
echo # Intervals ^(in hours^) for the background scheduler ^(Start-Scheduler.ps1^)
echo AutoCrawlerIntervalHours: 1
echo BoardCrawlerIntervalHours: 12
echo.
echo # --- 8. ADVANCED / SYSTEM ---
echo # Set to True to force the use of powershell.exe ^(v5.1^) even if pwsh ^(v7+^) is installed.
echo ForceLegacyMode: False
) > "%CONFIG_FILE%"
echo [OK] config.yaml has been restored.

:DETECTION
set "PS_EXE=powershell.exe"
for /f "tokens=*" %%A in ('powershell -NoProfile -Command "try { $v = (Get-Content '%CONFIG_FILE%' | Where-Object { $_ -match '^\s*ForceLegacyMode\s*:\s*(.+)' } | Select-Object -First 1); if ($v -match 'True') { 'True' } else { 'False' } } catch { 'False' }"') do (
    set "FORCE_LEGACY=%%A"
)

if /i "!FORCE_LEGACY!"=="True" (
    set "PS_EXE=powershell.exe"
) else (
    where pwsh >nul 2>nul && set "PS_EXE=pwsh.exe" || set "PS_EXE=powershell.exe"
)

:: --- 3. LOGGER ---
if exist "%CORE_DIR%Background-Logger.ps1" (
    start "DCM_Logger_Process" /min "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Background-Logger.ps1" -LogPath "%ROOT_DIR%activity_log.json"
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
echo  3. Search / Series Scanner
echo  4. Toggle Background Scheduler (Status: !SCHED_STATE!)
echo  5. Open Download Directory
echo  0. Exit
echo ==========================================

set "choice="
set /p choice="Select an option: "

if "%choice%"=="" goto MENU

if "%choice%"=="1" goto AUTO_FLOW
if "%choice%"=="2" goto DOWNLOADER
if "%choice%"=="3" goto SEARCH
if "%choice%"=="4" goto TOGGLE_SCHEDULER
if "%choice%"=="5" goto OPEN_DOWNLOADS
if "%choice%"=="0" goto CLEAN_EXIT

goto MENU

:AUTO_FLOW
cls
:: [수정된 부분] 크롤러 실행 후 멈추지 않고 곧바로 다운로더를 실행(-RunAuto)하도록 수정했습니다.
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Run-Crawler.ps1"
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Start-Downloader.ps1" -RunAuto
echo.
pause
goto MENU

:DOWNLOADER
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Start-Downloader.ps1"
pause
goto MENU

:SEARCH
cls
"!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Search-Scanner.ps1"
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
set /p "BOARD_INT=Board Scanner interval (hours): "

set "ARGS="
if not "!AUTO_INT!"=="" set "ARGS=-AutoInterval !AUTO_INT!"
if not "!BOARD_INT!"=="" set "ARGS=!ARGS! -BoardInterval !BOARD_INT!"

start "DC Manga Scheduler" "!PS_EXE!" -NoProfile -ExecutionPolicy Bypass -File "%CORE_DIR%Start-Scheduler.ps1" !ARGS!
timeout /t 2 >nul
goto MENU

:OPEN_DOWNLOADS
cls
echo [INFO] Opening Download Directory...
"!PS_EXE!" -NoProfile -Command "$line = ((Get-Content '%CONFIG_FILE%') -match '^\s*DownloadDir:') | Select-Object -First 1; if ($line) { $p = ($line -split ':', 2)[1].Split('#')[0] -replace [char]34,'' -replace [char]39,''; $p = $p.Trim(); if ($p) { $fullPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Split-Path '%CONFIG_FILE%'), $p)); if (-not (Test-Path $fullPath)) { Write-Host '[INFO] Creating directory:' $fullPath; New-Item -ItemType Directory -Force -Path $fullPath | Out-Null }; Invoke-Item $fullPath } } else { Write-Host '[WARN] DownloadDir not found in config.'; Start-Sleep -Seconds 4 }"
goto MENU

:CLEAN_EXIT
taskkill /FI "WINDOWTITLE eq DCM_Logger_Process*" /T /F >nul 2>&1
exit