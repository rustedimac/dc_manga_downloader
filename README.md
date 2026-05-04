# DC Manga Downloader

An enterprise-grade, highly robust downloader and cataloging system designed to archive manga translation posts from DCInside. 

Built with power users in mind but designed for everyone: **no coding or command-line knowledge is required.** Simply double-click `launcher.bat` to access the interactive menu. The suite intelligently parses titles, tracks histories, manages series aliases, crawls for missing chapters, bypasses censorship, and maintains a clean local database of your entire collection.

## ✨ Key Features

* **🎮 Interactive Launcher:** 100% menu-driven. No need to touch a single line of PowerShell or open a terminal manually.
* **🚀 High-Speed Multi-Threading:** Downloads up to 15 images concurrently per post, maximizing bandwidth and minimizing wait times.
* **🧠 Hyper-Intelligent Title Parsing:** Automatically extracts the Series Name and Chapter Number from messy post titles, completely ignoring garbage text, upvote begging, or trailing parentheses.
* **🔗 Daisy-Chain Crawling:** Detects "Previous Chapter" or "Next Chapter" links inside a post and automatically hops through them to bridge gaps in your catalog.
* **📂 Smart Alias Routing:** Map messy or inconsistent series names to a single, clean "Operator Name." All downloads for that series will automatically route to your defined folder.
* **🛡️ Duplicate Shield & Data Safety:** * Prevents downloading the exact same URL twice.
  * Uses **Atomic File Writes** and **Cross-Process Mutex Locks** to prevent database corruption, even if you force-close the app or have Excel open.

## 🚀 Quick Start

1. **Launch:** Double-click `launcher.bat`. (On the first run, it will automatically generate your `config.yaml` file and folder structures).
2. **Configure (Optional):** Open `config.yaml` in any text editor to customize your download directory or thread counts.
3. **Download:** Select the Downloader from the main menu to grab links, or select the Scanner to search the board and build your catalog.

## 📁 Architecture
All core logic is contained in the `\core\` folder, entirely orchestrated by `launcher.bat`. You never need to run these manually:
* `Start-Downloader.ps1`: The multi-threaded download and Telegraph bypass engine.
* `Search-Scanner.ps1`: The database manager and board crawler.
* `Clean-Catalog.ps1`: Database health and deduplication utility.
