# DC Manga Downloader



A highly robust, multithreaded, and automated toolchain designed to scrape, extract, and batch-download high-quality images and manga translations from DCInside.



Built to counter modern CDN firewall restrictions, it handles native attachments, inline images, and external host links (like Imgur) gracefully while maintaining perfect local file integrity. It includes an automated crawler, a smart downloading engine, and a background logging daemon.



[🇰🇷 한국어 README는 여기에 있습니다 (Korean Version)](./README_ko.md)



---



## Comprehensive Feature List



### Automated Board Crawler (`Run-Crawler.ps1`)

* **Keyword Filtering:** Scans board pages for posts containing the keyword "번역" (Translation).

* **Configurable Depth & Direction:** Set how many pages to scan (`MaxPages`) and whether to crawl Oldest-to-Newest or Newest-to-Oldest (`CrawlOrder`).

* **Smart List Management:** Automatically appends newly found URLs to `download_list.txt` under `[automatic_urls]`, preserving manual entries and previously failed URLs (`#RETRY`).

* **Auto-Handoff:** Automatically launches the Downloader engine upon completing the crawl.



### Core Downloading Engine (`Start-Downloader.ps1`)

* **Intelligent 403 Forbidden Bypass:** DCInside's image servers dynamically block requests based on regional routing. The script intercepts native files (`data-fileno`) and redirects them through hidden attachment endpoints (`download.php`) to completely bypass hotlink protection.

* **Universal Link Support:** Detects externally hosted images (like Imgur) via `data-tempno` and dynamically strips DC-specific HTTP `Referer` headers to prevent third-party hosts from rejecting the connection.

* **Strict Boundary Slicing:** Prevents "garbage collection" by enforcing strict HTML boundaries (`gallview_contents` to `reply_box` / `updown_area`). It isolates the post body so footer thumbnails and recommended posts are never downloaded.

* **Magic Byte File Verification:** Downloads files as temporary `.tmp` binaries, reads their raw hexadecimal headers (Magic Bytes), and accurately assigns `.jpg`, `.png`, `.gif`, or `.webp` extensions before finalizing the file.

* **Multithreaded Execution:** Uses PowerShell Jobs to download multiple files concurrently. Max concurrent downloads can be adjusted in the config.

* **State Resumption & Cleanup:**

  * **Automatic Purge:** Deletes lingering `.tmp` files from previous aborted runs before starting a new download.

  * **Smart Skipping:** Strictly verifies existing images to skip already downloaded content.

  * **Interrupt Handling:** Catches `Ctrl+C` interrupts securely to save stats for any background jobs that finished before the exit command.



### Background Logger (`Background-Logger.ps1`)

* **Named Pipe IPC:** Runs as a detached daemon listening on `\\.\pipe\DCMangaLogger`.

* **JSON Structured Logs:** Asynchronously writes detailed JSON entries to `activity_log.json` without slowing down the main downloading threads.



---



## Setup & Requirements



### Requirements

* **Operating System:** Windows 10 or Windows 11.

* **Environment:** PowerShell 5.1 (native) or PowerShell 7 (Core).

* **Network:** Active internet connection.



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

```



---



## How to Use



**Launch the Suite:** Double-click `launch.bat`.



**Main Menu Options:**



1. **Run Auto-Crawler & Downloader:** Scans the board for new posts, updates your list, and starts downloading.

2. **Run Manual Downloader:** Prompts you to paste a single URL for an instant download.

3. **Exit:** Safely closes the suite and kills the background logger.



---



## Configuration (`config.yaml`)



| Setting | Description |

| :--- | :--- |

| **BoardUrl** | The base URL of the DCInside board to crawl. |

| **MaxPages** | Number of pages the crawler will scan. |

| **CrawlOrder** | `0` = Oldest First, `1` = Newest First. |

| **KeepUnfinishedLinks** | If `False`, successful links are removed from the list. |

| **DNSAutoRepair** | If `True`, flushes DNS on network errors. |

| **UseProxy** | Set to `False` to bypass system proxies. |

| **RateLimitSeconds** | Delay between posts to avoid IP blocks. |

| **MaxConcurrentDownloads** | Parallel background jobs (Recommended: `10-15`). |

| **DownloadDir** | Absolute or relative path to save images. |

| **LogPath** | Path for the `activity_log.json`. |

| **LogLevel** | `"Verbose"` (all images) or `"Error"` (failures only). |

| **ShowProgressBar** | Toggles the native PowerShell UI progress bar. |

| **RenameFilesSequential** | If `True`, renames images to `001.jpg`, `002.jpg`, etc. |

| **ForceLegacyMode** | Forces PowerShell v5.1 even if v7 is installed. |



---



> **⚠️ Disclaimer:** Please do not use extremely high concurrent threads to DDOS or heavily tax the image servers. Use responsibly.
