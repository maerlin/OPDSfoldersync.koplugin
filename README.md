# OPDS Folder Sync for KOReader

An enhanced OPDS plugin for [KOReader](https://koreader.rocks/) with per-catalog download folders, catalog sync, filtering, search/facet browsing, and safer batch downloads.

This plugin replaces KOReader's bundled `opds.koplugin`. It keeps the normal OPDS browsing/downloading workflow, then adds tools for keeping catalogs organized and synchronized.

## What this plugin does

### OPDS catalog browsing

- Browse OPDS/Atom catalogs from KOReader's file manager **Network → OPDS catalog** menu.
- Add, edit, and delete catalogs.
- Configure catalog URL, optional username/password, and whether to use server-provided filenames.
- Browse sub-catalogs and add a sub-catalog as a saved root catalog.
- Use OPDS/OpenSearch or Calibre-style catalog search when exposed by the server.
- Use OPDS facets/filters when exposed by the server.
- Load paginated feeds incrementally, or use **Load all entries** to fetch all remaining pages.
- Persistently sort a catalog A→Z or Z→A.

### Downloads

- Download supported KOReader document formats from OPDS acquisition links.
- Choose a manual download folder.
- Rename files before downloading.
- Use either generated names (`Author - Title.ext`) or server-provided filenames.
- View book cover and book information when available.
- Maintain a download queue and download all queued items later.
- Show batch download progress as `Downloading X of Y`.
- Safely cancel batch downloads; interrupted `.download` files are cleaned up.
- Download to temporary files first, then rename when complete to reduce partial-file corruption.

### Synchronization

- Mark individual catalogs with **Sync catalog** so they are included in **Sync all catalogs** and auto-sync.
- Sync one catalog manually from the catalog long-press menu.
- Force sync one catalog or all catalogs, ignoring the saved `last_download` marker.
- Set a per-catalog sync folder.
- Set a global sync folder.
- If no per-catalog folder is set, downloads fall back to the global sync folder, then KOReader's default download folder.
- Limit how many new files are queued per sync scan with **Set max number of files to sync**. Default: `50`.
- Restrict synced formats with **Set file types to sync**. Example: `epub, pdf`. Leave empty to accept any supported document format.
- Persist pending sync downloads so failed/interrupted downloads can be retried later.

### Auto-sync

Auto-sync is enabled by default.

When enabled, the plugin can sync marked catalogs:

- periodically, every 24 hours by default;
- after network connection;
- after device resume.

The OPDS menu shows:

- **Auto-sync: On/Off**
- **Last sync: YYYY-MM-DD HH:MM** or `Never`

Only catalogs marked **Sync catalog** participate in automatic sync and **Sync all catalogs**.

### Include/exclude filters

Each catalog can define comma-separated filters:

- Included authors
- Included categories
- Excluded authors
- Excluded categories

Filter behavior:

| Include filters | Exclude filters | Result |
| --- | --- | --- |
| Empty | Empty | Sync all entries. |
| Empty | Set | Sync everything except matching entries. |
| Set | Empty | Sync only matching entries. |
| Set | Set | First keep included entries, then remove excluded entries. |

Filters are case-insensitive substring matches. Blank comma-separated entries are ignored.

Example: include category `Science Fiction` and exclude author `John Doe` to sync science-fiction entries except books by John Doe.

### OPDS Page Streaming / PSE

The plugin keeps OPDS-PSE/page-stream support from the upstream plugin:

- stream image/page-based OPDS items without downloading the whole file;
- jump to a page;
- resume from server-provided last-read page when available;
- attempt Kavita progress lookup for compatible Kavita OPDS stream URLs.

## Installation

> [!IMPORTANT]
> This plugin replaces KOReader's built-in OPDS plugin. Do not keep two `opds.koplugin` folders installed at the same time.

1. Download or clone this repository.
2. Find your KOReader installation directory and open its `plugins` directory.
3. Remove or back up the existing `opds.koplugin` directory.
4. Copy this repository's contents into a folder named `opds.koplugin` inside KOReader's `plugins` directory.
   - If you cloned it, rename the clone folder to `opds.koplugin`.
5. Restart KOReader.

Expected installed layout:

```text
koreader/
└── plugins/
    └── opds.koplugin/
        ├── _meta.lua
        ├── main.lua
        ├── opdsbrowser.lua
        ├── opdsparser.lua
        └── opdspse.lua
```

## Basic usage

### Add a catalog

1. Open KOReader's file manager.
2. Open **Network → OPDS catalog**.
3. Open the OPDS menu and choose **Add catalog**.
4. Enter:
   - catalog name;
   - catalog URL;
   - optional username/password;
   - optional include/exclude filters.
5. Optional toggles:
   - **Use server filenames**;
   - **Sync catalog**;
   - **Set sync folder**.
6. Save.

### Download one book

1. Open a catalog.
2. Select a book entry.
3. Choose a file type to download.
4. Optional: choose folder or change filename first.

Long-pressing a download format adds the book to the download queue instead of downloading immediately.

### Sync catalogs

From the OPDS menu:

- **Sync all catalogs**: syncs catalogs marked **Sync catalog**.
- **Force sync all catalogs**: same, but ignores previous sync markers.
- **Set sync folder**: sets the global fallback sync folder.
- **Set file types to sync**: limits synced document types.
- **Set max number of files to sync**: controls per-scan queue size.

From the root catalog list, long-press a catalog:

- **Sync**: sync only that catalog.
- **Force sync**: force sync only that catalog.
- **Edit** or **Delete**.

## Security and reliability notes

- Catalog and download URLs are limited to `http://` and `https://`.
- HTTPS → HTTP downgrade redirects are blocked and shown as a warning.
- Downloads are written to `*.download` temporary files and renamed only after a successful HTTP 200 response.
- Interrupted temporary downloads are removed during batch/sync cancellation handling.
- Sensitive request data is redacted from debug logs where practical.
- Catalog credentials are stored in KOReader's plugin settings file. Protect your device/settings if you use authenticated catalogs.

## Project status

This repository is maintained as an independent continuation of an earlier OPDS folder-sync fork. The goal is pragmatic compatibility with current KOReader plugin behavior, with a focus on:

- per-catalog organization;
- reliable sync;
- safer downloads;
- OPDS browsing quality-of-life features.

## Credits

This project stands on earlier work by others:

- KOReader's built-in OPDS plugin and the KOReader contributors.
- The original OPDS folder-sync fork by **Alex Koester / koesac**: <https://github.com/koesac/OPDSfoldersync.koplugin>
- Additional OPDS-PSE/page-stream functionality from the upstream plugin lineage.

Thanks to the original developers for building the foundation this maintained fork continues from.
