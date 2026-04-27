# DC Manga Downloader Suite

An advanced, multi-threaded PowerShell suite designed to automatically crawl, parse, and download translated manga chapters from DCInside. 

한국어 README는 여기에: https://github.com/rustedimac/dc_manga_downloader/blob/d40d2a38097da13cc9e8526fcb4cb5cbaec4ce1d/README_ko.md

## 🚀 Key Features

* **Advanced Anti-Bot Bypass:** Uses modern browser fingerprinting (Chrome UAs, Sec-Fetch headers) to bypass DCInside's "Forbidden" and empty-page bot protections.
* **Smart Title Parsing:** Automatically cleans folder names. It strips tags like `번역)`, ignores trailing flavor text, and cleanly extracts complex chapter numbers (e.g., `2화＆9화`, `1.5화`, or standalone numbers like `29`).
* **Uncapped Concurrent Downloads:** Uses PowerShell Jobs to download multiple images simultaneously for maximum speed. You control the thread limit.
* **Fail-Safe & Auto-Retry System:** If the network drops or a specific image fails, the script flags the URL with a `#RETRY` tag in `download_list.txt` instead of removing it, ensuring you never miss a missing page.
* **Asynchronous Background Logging:** Uses a Named Pipe server (`Background-Logger.ps1`) to prevent file-lock crashes when running high concurrent threads.
* **DNS Auto-Repair:** Automatically flushes the DNS (`ipconfig /flushdns`) and recovers if host resolution fails mid-download.
* **Session Timers & Metrics:** Tracks success/fail rates, total bandwidth used, and elapsed time per chapter and per session.

---

## 🛠️ File Structure

* `launch.bat` - The main entry point. Automatically generates the definitive `config.yaml`, starts the background logger, and opens the main menu.
* `Run-Crawler.ps1` - Scans the target board for translated posts, parses the links, and queues them up in `download_list.txt`.
* `Start-Downloader.ps1` - The core engine. Reads the queue, handles the HTML scraping, bypasses blocks, and securely downloads the images.
* `Background-Logger.ps1` - A lightweight background process that safely catches and writes logs without slowing down the downloader.
* `config.yaml` - Your master settings file.
* `download_list.txt` - The download queue consisting of `[manual_urls]` and `[automatic_urls]`.

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
