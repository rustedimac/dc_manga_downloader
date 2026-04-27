readme_content = """# DC Manga Downloader Suite (Definitive Edition)

A highly robust, multithreaded, and automated toolchain designed to scrape, extract, and batch-download high-quality images and manga translations from DCInside.

Built to counter modern CDN firewall restrictions, it handles native attachments, inline images, and external host links (like Imgur) gracefully while maintaining perfect local file integrity. It includes an automated crawler, a smart downloading engine, and a background logging daemon.

[🇰🇷 한국어 README는 여기에 있습니다 (Korean Version)](./README_ko.md)

---

## ✨ Comprehensive Feature List

### 🕸️ Automated Board Crawler (`Run-Crawler.ps1`)
* **Keyword Filtering:** Scans board pages for posts containing the keyword "번역" (Translation).
* **Configurable Depth & Direction:** Set how many pages to scan (`MaxPages`) and whether to crawl Oldest-to-Newest or Newest-to-Oldest (`CrawlOrder`).
* **Smart List Management:** Automatically appends newly found URLs to `download_list.txt` under `[automatic_urls]`, preserving manual entries and previously failed URLs (`#RETRY`).
* **Auto-Handoff:** Automatically launches the Downloader engine upon completing the crawl.

### 📥 Core Downloading Engine (`Start-Downloader.ps1`)
* **Intelligent 403 Forbidden Bypass:** DCInside's image servers dynamically block requests based on regional routing. The script intercepts native files (`data-fileno`) and redirects them through hidden attachment endpoints (`download.php`) to completely bypass hotlink protection.
* **Universal Link Support:** Detects externally hosted images (like Imgur) via `data-tempno` and dynamically strips DC-specific HTTP `Referer` headers to prevent third-party hosts from rejecting the connection.
* **Strict Boundary Slicing:** Prevents "garbage collection" by enforcing strict HTML boundaries (`gallview_contents` to `reply_box` / `updown_area`). It perfectly isolates the post body so thumbnail grids and recommended posts at the bottom of the page are never downloaded.
* **Magic Byte File Verification:** Downloads files as temporary `.tmp` binaries, reads their raw hexadecimal headers (Magic Bytes), and accurately assigns `.jpg`, `.png`, `.gif`, or `.webp` extensions before finalizing the file.
* **Multithreaded Execution:** Uses PowerShell Jobs to download multiple files concurrently. Max concurrent downloads can be adjusted in the config.
* **State Resumption & Cleanup:**
  * Sweeps for and deletes lingering `.tmp` files or ghost files (extensionless) from previous aborted runs before starting.
  * Checks existing files to automatically skip already downloaded images.
  * Catches `Ctrl+C` interrupts securely to save stats for any background jobs that finished before the exit command.

### 📝 Background Logger (`Background-Logger.ps1`)
* **Named Pipe IPC:** Runs as a detached daemon listening on `\\.\\pipe\\DCMangaLogger`.
* **JSON Structured Logs:** Asynchronously writes highly detailed JSON log entries to `activity_log.json` without blocking or slowing down the main downloading threads.

### 🚀 Launcher (`launch.bat`)
* **Auto-Configuration:** Automatically generates a definitive `config.yaml` if one is missing.
* **Environment Detection:** Automatically detects if PowerShell Core (`pwsh.exe`) is installed for better performance, falling back to standard Windows PowerShell (`powershell.exe`).
* **Process Management:** Boots the background logger, provides a clean interactive menu, and safely cleans up background processes upon exit.

---

## 🛠️ Setup & Requirements

### Requirements
* **Operating System:** Windows 10 or Windows 11 (Due to batch scripts and Named Pipes).
* **Environment:** PowerShell 5.1 (native) or PowerShell 7 (Core).
* **Network:** Active internet connection (VPNs or Proxies are supported via config).

### File Structure
Ensure all files are placed in the same directory:
```text
/
├── launch.bat                 # Main entry point - Run this!
├── config.yaml                # Configuration settings
├── download_list.txt          # Stores URLs for auto/manual processing
├── Run-Crawler.ps1            # Scrapes DCInside boards
├── Start-Downloader.ps1       # The multi-threaded downloading engine
└── Background-Logger.ps1      # Daemon for writing activity_log.json

---

## 📖 How to Use

1. **Run `launch.bat`** (Do not run the `.ps1` files directly).
2. The script will automatically generate a definitive `config.yaml` if one doesn't exist.
3. Choose your mode from the menu:
   * **Option 1 (Auto-Crawler):** Scans the board based on your config, updates the list, and automatically begins downloading.
   * **Option 2 (Manual Downloader):** Prompts you to paste a specific DCInside URL to download immediately.
4. Images will be saved in your configured `DownloadDir` (defaults to `.\Downloads`).

---

## ⚙️ Configuration (`config.yaml`)

You can tweak the behavior of the crawler and downloader by editing `config.yaml`. Here are the most important settings:

### Target Settings
* **`BoardUrl`**: The URL of the board to scan (e.g., the comic_new6 recommendation board).
* **`MaxPages`**: How many pages deep the crawler should look.
* **`CrawlOrder`**: `0` for Oldest First (Page 3 -> 1), `1` for Newest First (Page 1 -> 3).

### Network & Performance Settings
* **`MaxConcurrentDownloads`**: Number of simultaneous images to download per chapter. (3-5 is the sweet spot; 15+ may trigger temporary DCInside IP blocks).
* **`RateLimitSeconds`**: Rest period between downloading whole chapters. Prevents temporary bans.
* **`DNSAutoRepair`**: Set to `True` to allow the script to flush your DNS upon network drops.

### File Settings
* **`DownloadDir`**: Where to save the images (e.g., `.\Downloads`).
* **`RenameFilesSequential`**: `True` renames files to `001.jpg`, `002.jpg`, etc., ensuring perfect reading order. `False` keeps original names.
* **`LogLevel`**: `"Verbose"` logs every image; `"Error"` logs only failures and session summaries.

---

## ⚠️ Troubleshooting: The Retry System
If a chapter finishes downloading but an image failed (or the page gave a 403 error), the console will print **`[FLAGGED]`**.
The script will keep the URL in `download_list.txt` and rename it to `#RETRY https://...`.
**Do not delete this link.** Simply run the Downloader again later, and the script will automatically retry only the missing images from that post.

---
*Disclaimer: This tool is meant for personal, educational, and archival use. Please do not use extremely high concurrent threads to DDOS or heavily tax the image servers.*
