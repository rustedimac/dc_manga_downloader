# ⚙️ Configuration Guide (config.yaml)

When you run the launcher for the first time, it automatically creates a `config.yaml` file. This file controls the "brain" of the suite—dictating how fast it runs, where it saves files, and how the background scheduler operates. 

You can open this file using **Notepad** (or any text editor). 

> **⚠️ Golden Rule for editing `.yaml` files:**
> Keep the exact format! Always leave a space after the colon, and keep your text inside the quote marks (if quotes are used) or just type the value directly. 
> *✅ Correct: `MaxConcurrentDownloads: 15`*
> *❌ Wrong: `MaxConcurrentDownloads:15`*

---

## ⚙️ 1. CORE SETTINGS
*The basic rules for how the suite identifies and downloads posts.*

* **`BoardUrl`**
  * **Default:** `"https://gall.dcinside.com/board/lists/?id=comic_new6&exception_mode=recommend"`
  * **What it does:** The specific board the scanner will crawl. The default `exception_mode=recommend` means it will only scan the "Recommended" (Best) posts.
* **`RequireTranslationPrefix`**
  * **Default:** `"True"`
  * **What it does:** If `True`, the scanner will ONLY look at posts that have "번역" (Translation) in the title. Set to `False` if you want it to check every single post.
* **`ForceRedownload`**
  * **Default:** `"False"`
  * **What it does:** If set to `True`, the downloader completely ignores your download history. It features a "Smart Update" though: it will only download new/missing images if the folder already exists, or redownload the entire chapter if you manually deleted the folder.

## 🔎 2. CRAWLER & SEARCH LIMITS
*These settings change how deep the suite searches the website for new manga.*

* **`AutoCrawlerMaxPages`**
  * **Default:** `1`
  * **What it does:** How many pages the silent Background Scheduler will check every time it wakes up. Keep this low (1-3) since it runs frequently in the background.
* **`SeriesBrowserMaxPages`**
  * **Default:** `10`
  * **What it does:** How many pages the interactive "Series Scanner" (Option 3 in the menu) will crawl when you run it manually to find new series.
* **`KeywordSearchMaxBlocks`**
  * **Default:** `300`
  * **What it does:** How deep the "Keyword Deep-Search" goes. 300 is an exhaustive full-history search. Lower this (e.g., `10`) if you want faster, recent searches.
* **`CrawlOrder`**
  * **Default:** `0`
  * **What it does:** The direction the background crawler reads. `0` = Oldest First (Page 3 to 1) meaning chronological order. `1` = Newest First (Page 1 to 3).
* **`KeepUnfinishedLinks`**
  * **Default:** `False`
  * **What it does:** If `True`, the auto-crawler adds new links to the bottom of your download list without wiping the ones you haven't downloaded yet.
* **`JunkSeriesTitles`**
  * **What it does:** A massive list of garbage words (separated by `|`) that the scanner will completely ignore when trying to figure out a manga's real title (e.g., `단편`, `이전화`, `목차`, `다음화`).
* **`DaisyChainSeries`**
  * **Default:** `True`
  * **What it does:** The "Magic Hop" feature. If you scan Chapter 10, and it has a link to Chapter 9 inside the post, the scanner will automatically jump to Chapter 9 and grab it too.

## 📥 3. DOWNLOADER ENGINE
*Controls how aggressively the script downloads images and where they go.*

* **`DownloadDir`**
  * **Default:** `".\Downloads"`
  * **What it does:** The main folder where all your manga images will be saved. By default, it saves inside the suite's folder. You can change this to an absolute path (e.g., `"D:\MyManga"`).
* **`MaxConcurrentDownloads`**
  * **Default:** `15`
  * **What it does:** How many images the suite will download at the *exact same time*. `15` is extremely fast. Lower it if your internet is slow.
* **`RateLimitSeconds`**
  * **Default:** `2.5`
  * **What it does:** How long the suite pauses (in seconds) between finishing one post and starting the next. Prevents IP bans.
* **`RenameFilesSequential`**
  * **Default:** `True`
  * **What it does:** Renames messy image files into clean, ordered numbers (`001.jpg`, `002.jpg`).
* **`CustomStripChars`**
  * **Default:** `""`
  * **What it does:** If there are specific annoying symbols showing up in your folder names, type them here (e.g., `"@#"`) to automatically delete them.
* **`ShowProgressBar`**
  * **Default:** `False`
  * **What it does:** Set to `True` to show the live `[#####-----]` loading bar in the console. `False` keeps the console cleaner and slightly faster.

## 🌐 4. NETWORK & CONNECTION

* **`DNSAutoRepair`**
  * **Default:** `True`
  * **What it does:** If the server temporarily blocks your internet connection ("No such host" errors), the script will automatically flush your DNS and wait 10s to fix the connection itself.
* **`UseProxy`**
  * **Default:** `False`
  * **What it does:** Set to `False` to bypass system proxies for maximum direct connection speed.

## 🗂️ 5. DATA & TRACKING PATHS
*Where the database files live. (You rarely need to change these).*
* **`DownloadListPath`**: `".\Data\download_list.txt"`
* **`CatalogCsvPath`**: `".\Data\series_catalog.csv"`

## 📝 6. LOGGING SYSTEM
*Controls how much data is saved to the log files.*
* **`LogLevel` / `CrawlerLogLevel`**
  * **Default:** `"Verbose"` (Records everything). You can change to `"Info"`, `"Warn"`, or `"Error"` to save space.
* **`CrawlerLogMaxMB` / `CrawlerLogMaxFiles`**
  * **Default:** `10` MB / `5` Files. Automatically rotates and deletes old log files so your hard drive doesn't fill up.

## ⏰ 7. SCHEDULER SETTINGS
*The heart of the Background Crawler.*
* **`AutoCrawlerIntervalHours`**
  * **Default:** `1`
  * **What it does:** How often (in hours) the background scheduler wakes up to check the board for new chapters.
* **`BoardCrawlerIntervalHours`**
  * **Default:** `12`
  * **What it does:** How often the heavier Board Series Scanner runs in the background.

## 🛠️ 8. ADVANCED / SYSTEM
* **`ForceLegacyMode`**
  * **Default:** `False`
  * **What it does:** Set to `True` to force the launcher to use standard Windows PowerShell (v5.1) even if you have the newer PowerShell Core (pwsh 7+) installed.
