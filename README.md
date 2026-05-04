# DC Manga Downloader

An enterprise-grade, highly robust downloader and cataloging system designed to archive manga translation posts from DCInside. 

Built with power users in mind but designed for everyone: **no coding or command-line knowledge is required.** Simply double-click `launcher.bat` to access the interactive menu. The suite intelligently parses titles, tracks histories, manages series aliases, crawls for missing chapters, and maintains a clean local database of your entire collection—all automatically.

## ✨ Key Features

* **🎮 Interactive Launcher:** 100% menu-driven. No need to touch a single line of PowerShell or open a terminal manually.
* **⏰ Background Scheduler (Set It & Forget It):** A fully automated background crawler that silently monitors the board for your favorite series, downloading new chapters as soon as they are uploaded while you work or sleep.
* **🚀 High-Speed Multi-Threading:** Downloads up to 15 images concurrently per post, maximizing bandwidth and minimizing wait times.
* **🧠 Hyper-Intelligent Title Parsing:** Automatically extracts the Series Name and Chapter Number from messy post titles, completely ignoring garbage text, upvote begging, or trailing parentheses.
* **🔗 Daisy-Chain Crawling:** Detects "Previous Chapter" or "Next Chapter" links inside a post and automatically hops through them to bridge gaps in your catalog.
* **📂 Smart Alias Routing:** Map messy or inconsistent series names to a single, clean "Operator Name." All downloads for that series will automatically route to your defined folder.
* **🛡️ Duplicate Shield & Data Safety:** * Prevents downloading the exact same URL twice.
  * Uses **Atomic File Writes** and **Cross-Process Mutex Locks** to prevent database corruption, even if the scheduler is running in the background while you browse the catalog.
* **📁 One-Click Library Access:** Instantly open your organized download directory straight from the launcher menu.

## 🚀 Quick Start

1. **Launch:** Double-click `launcher.bat`. (On the first run, it will automatically generate your `config.yaml` file and create the required folder structures).
2. **Configure (Optional):** Open `config.yaml` in any text editor to customize your download directory, thread counts, or rate limits.
3. **Automate or Manually Download:** Turn on the Background Scheduler to let the suite do the heavy lifting, or use the interactive Scanner menu to hunt for specific manga.

## ⚙️ Architecture
All core logic is contained in the `\core\` folder, entirely orchestrated by `launcher.bat`. You never need to run these scripts manually:
* `Start-Downloader.ps1`: The multi-threaded download engine.
* `Search-Scanner.ps1`: The database manager and board crawler.
* `Clean-Catalog.ps1`: Database health and deduplication utility.
* `Background-Logger.ps1`: Silent event logging system.
