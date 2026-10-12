# DupeLocatR

> Fast, menu-driven duplicate file finder for Windows — type `dlr` from anywhere to scan.

---

## Install

**⬇️ Quick download:** [DupeLocatR-1.0.0.zip](https://github.com/Geektoberfest/Geektoberfest-DupeLocatR/releases/download/v1.0.0/DupeLocatR-1.0.0.zip) · [All releases](https://github.com/Geektoberfest/Geektoberfest-DupeLocatR/releases)

### Download from GitHub Releases *(available now)*

1. Download `DupeLocatR-<version>.zip` from the [latest release](https://github.com/Geektoberfest/Geektoberfest-DupeLocatR/releases/latest).
2. Extract it anywhere and add that folder to your `PATH`.
3. Open any terminal and type `dlr`.

### via Scoop *(available now, one command)*

```powershell
scoop install https://raw.githubusercontent.com/varadisthedev/DupeLocatR/main/scoop/dupelocatr.json
dlr
```

Requires [Scoop](https://scoop.sh). Don't have it? Install it first:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex
```

### via winget *(pending review — not yet available)*

The manifest has been submitted to `microsoft/winget-pkgs` and is awaiting approval. Once merged:

```powershell
winget install varadisthedev.DupeLocatR
```

---

## Usage

```text
dlr                 Scan the current directory
dlr <folder>        Scan a specific folder, e.g. dlr D:\Photos
dlr help            Show the command list (also: -h, --help, /?)
dlr -DryRun         Preview duplicate files that would be deleted
dlr --version       Show the installed version
dlr -v              Show the installed version
```

The same help is available in the app via menu option **[4] About / help**.

---

## Manual install (no package manager)

```powershell
# Clone or download the repo, then:
powershell -ExecutionPolicy Bypass -File DupeLocatr.ps1

# Or scan a specific folder:
powershell -ExecutionPolicy Bypass -File DupeLocatr.ps1 -Path "D:\Photos"

# Preview duplicate files without deleting or moving anything:
powershell -ExecutionPolicy Bypass -File DupeLocatr.ps1 -Path "D:\Photos" -DryRun

# Show the version:
powershell -ExecutionPolicy Bypass -File DupeLocatr.ps1 -Version

# Or double-click:
Run_DupeLocatr.bat
```

## How it works

DupeLocatR uses a **3-stage tiered hashing pipeline** to avoid wasting I/O on large files:

| Stage | What happens | Cost |
| ------- | ------------- | ------ |
| **1 — Size grouping** | Files with unique sizes are eliminated instantly | Zero disk reads |
| **2 — Tiered sampling** | Files are fingerprinted based on their size tier (see below) | Minimal reads |
| **3 — Full hash** | Only confirmed candidates are fully hashed (MD5 or SHA256) | Targeted |

### Sampling tiers (Stage 2)

| File size | Sample strategy |
| ----------- | ---------------- |
| **< 10 MB** | Skip sampling → direct full hash |
| **10 MB – 500 MB** | First 64 KB + Last 64 KB |
| **> 500 MB** | First + Middle + Last + 2 deterministic-random 64 KB windows |

This means a folder full of large videos is scanned **fast** — most never get fully read.

Excluded folders (`.git`, `node_modules`, `.vs`, etc.) are skipped **during** the folder walk itself, so they're never enumerated in the first place — not scanned then thrown away. Stages 2 and 3 run across multiple threads in parallel for large scans (configurable in Settings, default auto-detected from CPU core count).

---

## Features

- Finds duplicates across **all file types**: images, videos, music, documents, archives, etc.
- Category filter: scan only Images, Videos, Music, etc.
- **Keep strategy**: keep the alphabetically first / oldest / newest / shortest-path copy
- **Parallel hashing**: sampling and full-hash confirmation run across multiple threads (auto-tuned to CPU cores, configurable)
- **Safe actions**: Move duplicates to a staging folder (undoable) or send to Recycle Bin (recoverable)
- Exports a CSV report
- Colored console + progress bars
- Never modifies anything without explicit confirmation

---

## Uninstall

```powershell
scoop uninstall dupelocatr                   # if installed via Scoop
winget uninstall varadisthedev.DupeLocatR   # once available via winget
```

If you installed from the release ZIP, delete the extracted folder and remove it from `PATH`.

---

## License

This project is licensed under the [MIT License](LICENSE).
