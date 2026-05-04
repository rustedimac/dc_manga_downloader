# ⚙️ Configuration Guide (config.yaml)

When you run the launcher for the first time, it automatically creates a `config.yaml` file. This file controls the "brain" of the downloader—dictating how fast it runs, where it saves files, and how it searches the board. 

You can open this file using **Notepad** (or any text editor). 

> **⚠️ Golden Rule for editing `.yaml` files:**
> Keep the exact format! Always leave a space after the colon, and keep your text inside the quote marks. 
> *✅ Correct: `MaxConcurrentDownloads: "15"`*
> *❌ Wrong: `MaxConcurrentDownloads:"15"`*

---

## 📁 1. File & Folder Locations
*These settings tell the suite where to save your manga and where to look for its databases.*

* **`DownloadDir: ".\Downloads"`**
  * **What it does:** The main folder where all your manga images will be saved. You can change this to an external hard drive (e.g., `"D:\MyManga"`).
* **`CatalogCsvPath: "Data\series_catalog.csv"`**
  * **What it does:** Where your main manga database is stored. 
* **`DownloadHistoryPath: "Data\download_history.csv"`**
  * **What it does:** The suite's memory. It checks this file so it never downloads the same post twice.

## 🚀 2. Downloader & Speed Settings
*These settings control how aggressively the script downloads images.*

* **`MaxConcurrentDownloads: "15"`**
  * **What it does:** How many images the suite will download at the *exact same time*. `15` is extremely fast. If your internet is slow or you are getting blocked, lower this to `5` or `10`.
* **`RateLimitSeconds: "2.5"`**
  * **What it does:** How long the suite pauses (in seconds) between finishing one post and starting the next. A short pause prevents the server from blocking your IP.
* **`RenameFilesSequential: "True"`**
  * **What it does:** If `"True"`, it renames messy image files into clean, ordered numbers (`001.jpg`, `002.jpg`). If `"False"`, it keeps the original gibberish filenames.
* **`ShowProgressBar: "True"`**
  * **What it does:** Shows the live `[#####-----] 50%` loading bar in the console.

## 🔎 3. Scanner & Crawler Settings
*These settings change how the suite searches the website for new manga.*

* **`BoardUrl: "https://gall.dcinside.com/board/lists/?id=comic_new6"`**
  * **What it does:** The specific board the scanner will crawl. 
* **`DaisyChainSeries: "True"`**
  * **What it does:** The "Magic Hop" feature. If you scan Chapter 10, and it has a link to Chapter 9 inside the post, the scanner will automatically jump to Chapter 9 and grab it too.
* **`RequireTranslationPrefix: "False"`**
  * **What it does:** If `"True"`, the scanner will ONLY look at posts that have "번역" (Translation) in the title.
* **`SeriesBrowserMaxPages: "10"`**
  * **What it does:** How many pages deep the silent Background Crawler will look when searching for new uploads.
* **`JunkSeriesTitles: "ㅇㅇ | 1 | UNKNOWN"`**
  * **What it does:** A list of garbage words (separated by `|`) that the scanner should completely ignore when trying to figure out a manga's real title.

## 🛡️ 4. Safety & Advanced Settings

* **`ForceRedownload: "False"`**
  * **What it does:** If set to `"True"`, the downloader completely ignores your download history and will re-download everything from scratch. 
* **`DNSAutoRepair: "True"`**
  * **What it does:** If the server temporarily blocks your internet connection, setting this to `"True"` allows the script to automatically flush your DNS and fix the connection itself so the download doesn't crash.
* **`CustomStripChars: ""`**
  * **What it does:** If there are specific annoying symbols showing up in your folder names, type them here and the suite will automatically delete them during folder creation.
