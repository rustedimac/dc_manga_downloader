# DC Manga Downloader - Usage Guide

This entire suite is operated via **`launcher.bat`**. Simply double-click the file to open the interactive main menu. 

Below is a detailed guide to navigating the launcher menus and understanding what each feature does.

---

## 🤖 1. Auto-Crawl & Download (The Background Scheduler)

This is the crown jewel of the suite. Instead of manually checking DCInside for new chapters, you can let the suite do it for you.

* **How it works:** When activated via the launcher, it starts a silent background loop. It periodically scans the board's newest posts, identifies series that belong in your catalog, and automatically downloads the pristine images to your hard drive.
* **Concurrency-Safe:** Because the suite uses Mutex locks, you can safely leave this running in the background while you use the other scanner menus or manually download older chapters. 

---

## 📥 2. Downloader Menu

The core Downloader engine reads URLs, parses their HTML, matches them to your database, and downloads the images cleanly.

* **Auto-grab from Queue:** The suite maintains a text file at `Data\download_list.txt`. If you paste multiple DCInside URLs under the `[manual_urls]` header (or if the scanner queues them up), this option will read them all and download them sequentially.
* **Manual URL:** Prompts you to paste a single DCInside URL directly into the console for an instant, one-off download.
* **Resilience:** If a post is deleted by the author, the downloader safely skips it and marks it as `#DELETED` in your queue. If your internet drops, it flags it as `#RETRY`.
* **Visual Progress:** Displays a live, updating progress bar for every image processed.

---

## 🔎 3. Scanner & Catalog Manager Menu

This menu is your command center for finding new manga, managing your local CSV database, and fixing messy folder names.

* **Keyword Deep-Search:** Enter a keyword (e.g., the name of a manga). The scanner will crawl DCInside board search results. It generates a "Checklist" where you can select specific chapters or press `d` to download them all instantly.
* **Extract Series from Single URL:** Paste a single DCInside post URL. The scanner will read the `[시리즈]` (Series) block inside that post, extract every linked chapter, and dump them into your local Catalog. If it detects missing chapters, it will automatically "Daisy-Chain" to older posts to find them.
* **Series Scanner (Board Crawler):** Silently crawls the front pages of the board looking for any post with a `[시리즈]` block and merges newly translated series into your local catalog automatically.
* **Series CSV Browser:** An interactive interface to browse your locally saved database. It groups posts by Series Name. You can queue up entire series or specific missing chapters and send them straight to the Downloader.
* **Verify Catalog Health & Fetch Metadata:** Scans your entire database for missing metadata. It silently pings the URLs to fetch the exact upload date and automatically marks dead links as `DELETED`.
* **Manage Series Aliases (Operator Names):** Uploaders often change titles randomly (e.g., `방과 후, 우리는 우주에서 헤맨다`, `방과후 우리는 우주에서 헤맨다`, `방과 후 우리들은 우주에서 헤맨다`). This tool lets you select a messy original name and type a new "Operator Name". From then on, all downloads matching those messy names will automatically route to the single, clean folder you defined.
* **Browse External Links:** Filters your database to show only posts that contain external links (Google Drive, Mega, etc.), allowing you to easily track down high-quality raw files or translated ZIPs.

---

## 📁 4. Quick Actions

* **Open Download Directory:** Instantly opens your Windows File Explorer to the exact location where your manga is being saved. No need to dig through folders to find your downloaded images.

---

## 🛠️ 5. Maintenance Tools 

If you navigate to the Maintenance/Utility section of your launcher, you have access to two background cleanup tools:

* **Clean / Canonicalize Catalog:** Removes duplicate entries, strips out mobile formatting from URLs, and safely optimizes your `series_catalog.csv` file without touching your metadata.
* **Auto-Populate Aliases:** If you are migrating an older folder of manga into this suite, this tool scans your `\Downloads\` directory and automatically registers your existing folder names into the Alias Registry so you don't have to type them all manually.
