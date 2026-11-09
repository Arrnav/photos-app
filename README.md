<div align="center">

<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" alt="Photos app icon" />

# Photos

**A native iOS photo library for your own server: it looks, feels and moves like a first-class iOS app, with your pictures on hardware you own.**

![Version](https://img.shields.io/badge/version-0.7.1-blue?style=for-the-badge)
![Status](https://img.shields.io/badge/status-beta-orange?style=for-the-badge)
![Platform](https://img.shields.io/badge/iOS-18%2B%20·%20iOS%2026%20Liquid%20Glass-black?style=for-the-badge)
![Swift](https://img.shields.io/badge/Swift-6%20strict%20concurrency-F05138?style=for-the-badge&logo=swift&logoColor=white)
![Server](https://img.shields.io/badge/server-Immich%203.3.5-4250AF?style=for-the-badge)
![License](https://img.shields.io/badge/license-GPL--3.0-green?style=for-the-badge)

</div>

---

## ✨ What it is

Photos is a personal iPhone app by **ethwood** that puts a self-hosted photo server behind a
native **iOS 26** interface: a fluid grid, viewer, gestures, menus and Liquid Glass. The phone's own library and the server's library appear as **one timeline**.
Backups use the **same checksums as the official Immich app**, so the two can run side by side
without uploading anything twice.

The app talks to the server through a small, provider-neutral layer (`CloudCore`). Immich is the
first provider (`ImmichCloud`); another server only needs its own provider.

## 📍 Status

| Milestone | | Notes |
|---|---|---|
| M1 Foundations | ✅ | Sign-in, home/away server switching, synced timeline, thumbnail cache |
| M2 Viewer + UI parity | ✅ | Grid, viewer, Library/Collections/Search, select mode, share screen |
| M3 Local-first library | ✅ | iPhone + Cloud merged and de-duplicated by checksum; works offline |
| M4 Live Photos, video, AirPlay | ✅ | Player with zoom, Live Photos, AirPlay, external display |
| M5 Backup | ✅ | Background uploads; tested with a library of over 250 GB |
| Editing, subject lift | ✅ | Photo and video editor (tested on a device), long-press subject lift and Live Text |
| M6 Albums, People, sharing, search | ✅ | Shared albums, partner sharing, People and smart search (remote ML), Sync Albums |
| M7 Free Up Space, polish | ✅ | Free Up Space, offline thumbnails and Keep Offline, log viewer, accessibility pass |

## 🌟 Features

**Library**
- One timeline of iPhone and Cloud photos, de-duplicated by SHA-1, with small badges showing where each lives (phone, Cloud, or both).
- Grid: pinch between 1, 3, 5, 15 and 30 columns; Years / Months / All; scrubber; drag-to-select with auto-scroll.
- Filter menu: Added or Captured, Favourites, Edited, Shared with You, Captured by Me, Not in an Album, media types, aspect-ratio grid.
- Instant, offline launch from the phone's database; changes sync in the background.

**Viewer**
- Zoom transition, paging, pinch and double-tap zoom, swipe down to close, inline info panel with map.
- Full-resolution HDR originals on demand.
- Video player with a scrubber and zoom.
- Live Photos (press and hold), with LIVE / Off.
- Long-press subject lift, Live Text and Look Up.
- AirPlay for photos and videos, plus external displays.
- Share screen: carousel, options (location, format, all photo data) and extra actions.
- Favourite, Hide (PIN-protected Locked Folder behind Face ID), Duplicate, Archive, Delete with Undo (from the iPhone and Cloud), Adjust Date & Location, Save to This iPhone.

**Editing**
- Adjust (Auto, Exposure, Brilliance, Highlights, Shadows, Contrast, Brightness, Black Point, Saturation, Vibrance, Warmth, Tint, Sharpness, Definition, Noise Reduction, Vignette), Filters, Crop (straighten, perspective, aspect ratios, rotate, flip), undo and redo.
- Video: trim, mute, Audio Mix on videos with spatial audio, and the same adjustments and filters.
- Nothing is lost: HDR photos keep a gain map; trimmed videos are copied without re-encoding (Dolby Vision included); dates, places and camera details are kept.
- iPhone photos are edited the iOS way (the original is kept, Revert to Original works); the backup uploads the new version and stacks it with the original in Cloud.

**Collections and Search**
- Memories, Pinned, Albums, Shared Albums, Media Types, Utilities: Hidden and Recently Deleted (Face ID), Captured by Me, Archive.
- Map of geotagged photos.
- Reorder and collapse sections; three layouts.
- Recently Deleted: days left on each item, select to recover or delete for good.
- Albums: select, share, remove from an album (shared albums too).
- Partner Sharing: see a partner's whole library, or share yours (shared albums are the way to share only some photos).
- People from the server's face recognition; name them, or link a contact.
- Search by place, month, year, season, media type, caption and camera (offline), plus by meaning with the server's smart search. Recents remembered.

**Backup**
- Automatic, battery-friendly backup on a background `URLSession` that survives the app being closed.
- Album choice (include or exclude); originals downloaded from iCloud when needed; Wi-Fi-only, charging-only and pause options.
- Live Photos paired exactly like the official app; edited photos uploaded as new versions and stacked.
- Optional: Sync Albums (phone albums mirrored in Cloud).
- Free Up Space: removes photos from the iPhone that are safely in Cloud (each one checked with the server first).
- Never uploads twice: the phone's records, then a server check, then the checksum header on each upload.
- A status screen with plain-language errors.

**Offline**
- Every thumbnail kept on the iPhone once loaded; **Download All Thumbnails** fetches the rest on Wi-Fi, so the whole Library can be browsed without a connection.
- **Keep Offline:** the full-quality originals of your favourites and chosen albums stay on the iPhone.

**Account and settings**
- An account card with the picture taken from your contact card or a photo.
- Cloud Server Settings: server addresses, accounts, sync, offline and storage, Hidden PIN, and troubleshooting with a log viewer.

## 🧱 Architecture

| Package | Role |
|---|---|
| `CloudCore` | Provider-neutral protocols and models (`CloudProvider`, `CloudConnection`, errors, connectivity) |
| `ImmichCloud` | Immich implementation of CloudCore, including the backup upload format |
| `ImmichAPI` | Client generated from Immich's OpenAPI spec (swift-openapi-generator), plus wrappers |
| `Sync` | Immich `/sync/stream` into the local database |
| `Persistence` | GRDB database: server index, phone index, backup queue, merged timeline |
| `Library` | PhotoKit index, iCloud identities, checksum rule and hashing |
| `Backup` | Upload queue, PhotoKit streaming, background session, background tasks |
| `MediaCache` | Thumbnail and original caches (gentle on small servers) |
| `GridGeometry` | Grid levels and pinch-zoom maths |
| `PhotosAppUI` | All screens (SwiftUI + UIKit) |

## 📦 Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift): SQLite database (MIT)
- [swift-openapi-generator / runtime / urlsession](https://github.com/apple/swift-openapi-generator): API client (Apache 2.0)
- [swift-http-types](https://github.com/apple/swift-http-types) (Apache 2.0)
- iOS frameworks: SwiftUI, UIKit, PhotoKit, AVFoundation/AVKit, VisionKit, MapKit, BackgroundTasks, MetricKit, Core Image
- Build tools: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 🖥️ Recommended server setup

- **[Immich](https://immich.app) v3.3.5** in Docker. A **Raspberry Pi 4 with 2 GB** works. The app keeps to 4 thumbnail requests and 2 uploads at a time.
- **Storage:** an SSD over USB 3. Keep the Pi on Ethernet, with a DHCP reservation so its home address never changes.
- **Away from home:** [Tailscale](https://tailscale.com) on the server and the phone. The app tries the home address first (1.5 s), then the Tailscale address.
- **Reliability on small boards:**
  - Make the system journal persistent (`sudo mkdir -p /var/log/journal`).
  - Enable the hardware watchdog (`RuntimeWatchdogSec=15` in `/etc/systemd/system.conf`).
- **Faces and smart search:** optional. Run Immich's machine-learning container on a stronger computer (e.g. a Mac) and point the server at it. See Immich's *Remote Machine Learning* guide.

## 🚀 Installation

### Option A: download a release (no Xcode needed)

1. Download **`Photos.ipa`** from [Releases](https://github.com/arrnav/photos-app/releases/latest).
2. Install it with [Sideloadly](https://sideloadly.io) (Windows or macOS) or [AltStore](https://altstore.io):
   connect the iPhone, drop in the `.ipa`, and sign in with your own developer account (a free one works).
3. On the iPhone:
   - Settings › General › VPN & Device Management › trust your account.
   - Settings › Privacy & Security › **Developer Mode** › on (the phone restarts).
4. Open Photos and sign in to your server.

With a free account the app must be re-signed every **7 days**: install the same `.ipa` again (AltStore can do it automatically). Your data is kept.

**Server address:** plain HTTP works on your home network (e.g. `192.168.1.10:2283`).

**Away from home with Tailscale:** use your server's Tailscale **name**, not its number. In the Tailscale app or admin page, turn on **MagicDNS** and copy the server's full name, which ends in `.ts.net`. Then enter it in the app with the port, for example `http://my-server.tail1234.ts.net:2283`. Plain HTTP is fine here because Tailscale already encrypts everything between your devices. A Tailscale number such as `100.x.y.z` won't work with the release build (iOS blocks plain HTTP to it); a server with HTTPS works anywhere.

### Option B: build it yourself

1. Install **Xcode 26** and XcodeGen (`brew install xcodegen`).
2. Clone the repository and set your signing team and server:
   ```sh
   git clone https://github.com/arrnav/photos-app.git && cd photos-app
   cp Config/Local.xcconfig.template Config/Local.xcconfig   # set DEVELOPMENT_TEAM and your server addresses
   ```
3. Connect the iPhone and find its UDID: `xcrun devicectl list devices`.
4. Build and install a Release build:
   ```sh
   Scripts/reinstall.sh <device-udid>
   ```
5. On the phone, trust the developer in Settings › General › VPN & Device Management, and turn on Developer Mode.

A free developer account (Personal Team) works. Free profiles last 7 days, so run step 4 again weekly; app data is kept.

## 📱 Usage

**First launch**
1. Sign in with your server account.
2. Allow **Full** Photos access, so the iPhone's photos join the Library.

**Back up**
1. Open your account picture (Collections, top right) › **Back Up This iPhone** and turn it on. Optional: choose albums (**Back Up From**), mobile data, charging only.
2. Keep the phone on Wi-Fi and charging for the first backup.

**Everyday**
- **Browse:** pinch the grid to zoom; tap a photo; swipe up for Info; swipe down to close.
- **Select:** tap **Select**, then tap or drag across photos. Share, delete or add to an album from the bottom bar.
- **Delete:** removes the photo from this iPhone and from Cloud (iOS asks first). Recover it from Collections › **Recently Deleted**.
- **Hide:** ··· › Hide. Find it in Collections › Utilities › **Hidden** with Face ID (the first time, set a 6-digit PIN). Select there to share, delete or unhide.
- **Search:** places, dates, people, or what's in the photo ("dog on a beach").
- **People:** Collections › People. Tap a person to rename or link them to a contact.

**Settings** (account picture › Cloud Server Settings)
- **Server:** home and away (Tailscale) addresses. Change these if the server moves.
- **Backup:** Sync Albums.
- **Offline:** Download All Thumbnails; Keep Offline for favourites and albums.
- **Storage:** limits for previews and downloaded originals.

**Edit:** open a photo or video › the sliders button. Done saves; Cancel discards. To undo a saved edit later, open Edit › ··· › Revert to Original › Done.

**Free Up Space:** account picture › Free Up Space. Choose a date and what to keep, review, then remove. iOS asks before anything is deleted.

## 🔁 Re-signing (free Personal Team)

When the app stops launching (an expired profile or certificate), rebuild and reinstall with
`Scripts/reinstall.sh <udid>`. Xcode creates a fresh certificate and profile. If signing fails,
check Xcode › Settings › Accounts.

## 🧪 Development

```sh
Scripts/test.sh            # unit tests for every package that builds on macOS
Scripts/generate-api.sh    # regenerate the Immich client after updating api/immich-openapi-specs.json
swift Scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png   # redraw the icon
```

Developer self-tests (launch arguments, console output):
```sh
xcrun devicectl device process launch --device <udid> --console com.ethwood.photos -- -VerifyChecksums
xcrun devicectl device process launch --device <udid> --console com.ethwood.photos -- -BackupSelfTest
xcrun devicectl device process launch --device <udid> --console com.ethwood.photos -- -EditorSelfTest    # takes over the screen
```
Test snapshots and files go to the app's `Library/Caches/selftest` (copy them with `devicectl device copy from`).
Crash and hang reports (MetricKit) appear under Cloud Server Settings › Diagnostics.

Design notes, decisions and security notes: [`docs/DESIGN.md`](docs/DESIGN.md).

## 🔒 Security

How the app protects your account and photos, how to report a problem, and the automated checks
(CodeQL, gitleaks, OSV-Scanner) that run on every push: [`SECURITY.md`](SECURITY.md).

## 🙏 Credits

- **[Immich](https://github.com/immich-app/immich)**: the self-hosted server this app talks to. Its OpenAPI spec is included in `api/` under Immich's licence (AGPL-3.0). The official app was studied for behaviour only; no Immich code is used.
- This app is independent, uses its own icon, and is not affiliated with any platform vendor.
- Built by **ethwood**, with Claude (Anthropic) as a pair programmer.

## 📄 License

GPL-3.0. See [LICENSE](LICENSE).
