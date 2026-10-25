# Prompt: "Photos" – a native iOS client for Immich

Paste everything below into Claude Code, from the root of the `photos-app` repository.

---

## Who I am and what I want

I'm an experienced developer (C#/.NET, Unity, embedded, cloud) building a personal native iOS app called **Photos**. It is a client for my self-hosted Immich server, and it should feel as close as possible to Apple's Photos app in look, speed and gestures. It is for personal use by me and my wife only. It will not be published on the App Store.

This is a standalone repository just for the app. It talks to Immich only through Immich's API.

For reference, a read-only clone of the official Immich repository sits next to this one at `../immich`, checked out at tag `v3.3.5` (the version my server runs). Never modify anything in `../immich`. The Immich OpenAPI spec has been copied into this repository at `api/immich-openapi-specs.json`.

## My setup (important constraints)

- Immich server **v3.3.5**, running in Docker on a **Raspberry Pi 4 with 2 GB RAM**.
- Machine learning is **disabled** on the server. Smart search, face recognition, OCR and duplicate detection are not available. Do not build features that depend on them.
- Video transcoding is **disabled**. The app must play original iPhone files (HEVC/H.264, HDR, Dolby Vision) directly.
- Server URLs:
  - Local (home Wi-Fi): `http://192.168.50.61:2283`
  - Remote (over Tailscale): `http://100.65.180.123:2283`
  - Plain HTTP on both. Configure App Transport Security exceptions for these hosts only.
- Two users on the server: me and my wife, each with their own account.
- Library size: roughly 25,000+ assets across both accounts and growing, so performance at scale matters.
- Because the server is a small Pi, the app must be gentle with it: limit concurrent requests (for example, at most 4 thumbnail downloads and 1–2 uploads at a time), use paging, and cache aggressively.

## Step 0: Explore before writing code

1. Confirm `../immich` is checked out at tag `v3.3.5`, and that `api/immich-openapi-specs.json` matches `../immich/open-api/immich-openapi-specs.json`.
2. Read `api/immich-openapi-specs.json`. This is the source of truth for every endpoint and model.
3. Read the official Flutter app in `../immich/mobile/` to learn exactly how it:
   - logs in and stores tokens
   - syncs the timeline and assets (including any newer sync endpoints)
   - calculates asset checksums (SHA-1) and checks for existing uploads before uploading
   - uploads assets, including how **Live Photos** (image + motion video) are paired
   - handles iCloud-only assets
   - implements Free Up Space
4. Write `PLAN.md` at the root of this repository, summarising the endpoints you will use, the architecture and the milestones below. Wait for my approval before starting Milestone 1.

## Tech stack and architecture

- Swift 6 with strict concurrency, SwiftUI as the main UI framework, and UIKit wherever it gives better performance or gesture control (the photo grid and the zoomable viewer especially).
- Minimum iOS version: 18.0. Target iPhone only, portrait and landscape.
- Project generation: XcodeGen (`project.yml`) or a clean Xcode project. Keep it simple to build from the command line.
- API client: generate it from the Immich OpenAPI spec with Apple's `swift-openapi-generator`, in its own Swift package (`ImmichAPI`). Do not hand-write networking for endpoints the spec covers.
- Local storage: SwiftData or GRDB for the asset index, sync state and upload queue. Pick one and justify it in PLAN.md.
- Suggested modules (local Swift packages):
  - `ImmichAPI` – generated client and auth middleware
  - `Library` – unified asset model, merging local (PhotoKit) and remote (Immich) assets
  - `Sync` – server timeline sync and change tracking
  - `Backup` – hashing, upload queue and background tasks
  - `MediaCache` – thumbnail and preview caching (memory and disk)
  - `PhotosUI` – screens and components
- Use a clear architecture (Observation framework with view models, or similar), dependency injection for testability, and no singletons beyond what the system requires.

## Core experience: match Apple Photos

### Instant, local-first launch
- On launch, show the grid immediately from PhotoKit (local library) and the cached remote index. Never wait for the server before showing photos.
- Sync with the server in the background and merge results in without visual jumps.
- Target: the grid is visible and scrollable within about 300 ms of launch on an iPhone 12 Pro Max.

### Unified library
- One timeline merging local assets and server assets, de-duplicated by checksum, matching how Immich identifies duplicates.
- A small, unobtrusive status indicator on each tile: on this phone only, on the server only, or both. It must be possible to hide this indicator in settings.
- Server-only assets load thumbnails from Immich's thumbnail and preview endpoints.

### Grid
- High-performance grid built on `UICollectionView` with a compositional layout, wrapped for SwiftUI. It must scroll smoothly at 120 Hz with tens of thousands of items.
- Pinch to zoom between column counts (for example 3, 5 and 7 columns), with a smooth animated transition centred on the pinch point, like Apple Photos.
- Years and Months views that summarise the library, with tap-to-drill-down into a day or month.
- Fast scrubber on the right edge showing month and year while dragging.
- Multi-select with drag-to-select across rows.
- Prefetching and cancellation of thumbnail requests as the user scrolls. Local thumbnails via `PHCachingImageManager`; remote thumbnails via a memory and disk cache.

### Full-screen viewer
- Open from the grid with a zoom transition from the tapped tile (iOS 18 zoom navigation transition or a custom matched transition).
- Horizontal paging between assets.
- Pinch to zoom and double-tap to zoom, built on `UIScrollView`, with correct behaviour at the edges when paging. This must be rock solid. The official app currently has touch and zoom bugs in the video player that need an app restart, and this app must not.
- Swipe down to dismiss interactively back to the tile it came from.
- Swipe up (or an info button) for an info panel: date and time, camera and lens, exposure settings, file size and resolution, location with a small map, and which albums it belongs to.
- Show full-resolution originals on demand. Start with the preview size and upgrade to the original when the user zooms in.
- HDR photos must display as HDR where the device supports it.

### Live Photos
- Local Live Photos: play with `PHLivePhotoView`, press-and-hold to play, like Apple Photos.
- Remote Live Photos: download the image and its paired motion video from Immich, build a `PHLivePhoto` from the two files, and play it the same way. Cache both parts.
- A "LIVE" badge in the viewer, with the option to view as still.

### Video
- Native `AVPlayer`-based player with custom controls styled like Apple Photos: play/pause, scrubber with thumbnails if feasible, mute, and time display.
- Pinch to zoom on video, the same as photos, with no gesture conflicts.
- Stream originals from the server using HTTP range requests where supported. Play local videos directly from PhotoKit.
- Correct handling of HEVC, HDR and Dolby Vision iPhone videos, slow-motion and time-lapse.

### Albums, memories and sharing
- Albums tab: my albums, albums shared with me, and partner sharing (my wife's library), using Immich's album and partner APIs.
- Memories ("On this day") using Immich's memories API, presented as a simple card list. No ML-based features.
- Share sheet (`UIActivityViewController`) for any asset, including server-only ones. Download the original first, so sharing to WhatsApp or anywhere else sends the full-quality file.
- "Save to this iPhone" for server-only assets, saving into the Photos library with metadata preserved.
- Favourite, archive and delete (moving to Immich trash), kept in sync with the server.

### Search
- Search using Immich's metadata search only: date ranges, places (city, state, country), camera make and model, file name, and media type (photos, videos, Live Photos, screenshots). No smart or CLIP search.

## Backup engine

The goal is reliable, automatic, battery-friendly backup of both iPhones to the Pi.

- Watch the Photos library with `PHPhotoLibraryChangeObserver` and keep a persistent upload queue.
- Let the user pick which albums to back up, with Recents (everything) as the default.
- Compute checksums the same way the official app does, streaming the original resource through `PHAssetResourceManager` so large videos never load fully into memory.
- Before uploading, ask the server which checksums it already has (bulk upload check), and skip those.
- iCloud-only assets ("Optimize iPhone Storage"): allow network access to download originals, with a setting to skip them and a setting to only do this on Wi-Fi.
- Upload using a **background `URLSession`** with file-based uploads (export each asset to a temporary file first). This must keep uploading when the app is in the background or suspended, and must survive the app being terminated by the system.
- Use `BGProcessingTask` (preferring charging and Wi-Fi) for hashing and queue processing, and `BGAppRefreshTask` for light, periodic checks for new photos.
- Upload Live Photos so the server pairs the image and motion video exactly as the official app does.
- Settings: backup on/off, allow mobile data (on/off), only while charging (on/off), and pause/resume.
- A clear backup status screen: total, backed up, remaining, current item, last successful backup time, and any errors with a readable message. Never show a vague "sync failed" without details.
- Retry with exponential backoff. Never upload the same asset twice.

## Free Up Space

- Remove assets from the iPhone that are safely backed up to the server.
- Options: a cutoff date (only assets on or before it), keep favourites, and albums to always keep (for example WhatsApp).
- Before deleting, verify each asset's checksum exists on the server and is not in the Immich trash.
- Show a review screen with the count and total size before deleting. Use `PHAssetChangeRequest.deleteAssets`, which shows iOS's own confirmation dialog.
- Warn clearly that with iCloud Photos on, deleting from the phone also deletes from iCloud and all other Apple devices.

## Networking and server switching

- Settings hold two URLs: a local one and a remote one.
- On launch, when returning to the foreground and when the network changes (`NWPathMonitor`), probe the local URL's ping endpoint with a short timeout (about 1–2 seconds). Use it if it answers; otherwise use the remote URL. This approach does not need the Wi-Fi name, location permission or special entitlements.
- Optionally, if location permission is granted, also use the current Wi-Fi name (`NEHotspotNetwork`) to choose faster. Treat this as an enhancement, not a requirement.
- Tailscale handles the remote connection at the OS level, through VPN On Demand. The app does not need to manage Tailscale.
- Show the active server and connection state in settings.

## Authentication and accounts

- Log in with email and password. Store the access token in the Keychain.
- Support switching between accounts (me and my wife) without reinstalling.
- On launch, check the server version and warn if it is newer than the version the API client was generated from.

## Look and feel

- Follow Apple's Human Interface Guidelines closely: system fonts, Dynamic Type, SF Symbols, standard materials and blurs, dark mode, and haptics in the same places Apple Photos uses them.
- Tab structure similar to Apple Photos: Library, For You (memories), Albums, Search.
- App name shown on the home screen: **Photos**. Bundle identifier: `com.arnav.photos` (I'll change it if needed).
- **Create an original app icon.** Do not copy or recreate Apple's Photos icon or any Apple artwork.
- Accessibility: VoiceOver labels on all controls and tiles, Reduce Motion support, and sufficient contrast.

## Quality bar

- Unit tests for checksum calculation, de-duplication, the upload queue, URL switching and timeline merging.
- Clear logging (OSLog) with categories for sync, backup and networking, plus an in-app log viewer in settings that I can share as a text file.
- No crashes on bad network or server errors. Every network failure shows a readable message and retries sensibly.
- Profile memory and scrolling with Instruments on a large library before calling a milestone done.

## Milestones

Work through these in order. Each one should build, run on a real device and be usable before moving on. After each milestone, summarise what was done, what was tested and anything I need to check by hand.

1. **Foundations:** project setup, generated API client, login, server switching, and a remote-only timeline grid with thumbnails and caching.
2. **Viewer:** full-screen viewer with zoom transition, paging, pinch/double-tap zoom, swipe-to-dismiss, info panel and share sheet.
3. **Local-first library:** PhotoKit integration, instant launch, the merged and de-duplicated timeline, and status indicators.
4. **Live Photos and video:** local and remote Live Photo playback and the native video player with zoom.
5. **Backup engine:** hashing, upload queue, background `URLSession`, background tasks, Live Photo pairing, and the status screen.
6. **Albums, memories, partner sharing and search.**
7. **Free Up Space, settings polish, the log viewer and final performance tuning.**

## Out of scope

- Photo or video editing.
- Any machine-learning feature (faces, smart search, OCR).
- Android, iPad-specific layouts, macOS.
- Changes to the Immich server, web app or Flutter app.

## Licensing note

Immich is licensed under AGPL-3.0. Use `../immich` only as a reference for how the API behaves. Do not copy code from it into this repository, so this app stays my own independent code. Keep the copied OpenAPI spec in `api/` with a short README noting where it came from and that it is Immich's. The app is for private personal use only.
