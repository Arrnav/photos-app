# Design notes

How Photos is built, and why. The README covers what the app does and how to install it.

Photos is a native iOS client for a self-hosted [Immich](https://immich.app) server (v3.3.5). It is
written so that small servers (a Raspberry Pi 4 with 2 GB is the reference) stay responsive, and so
that it can run side by side with the official Immich app without uploading anything twice.

## 1. What the server API implies

- **`/sync/stream` has an untyped response.** It returns JSON Lines, but the spec declares no body.
  The event payloads (`SyncAssetV2`, `SyncAssetExifV1`, …) are in the spec, so they can be generated.
- **`PUT /assets` is deprecated** in v3; its `PATCH` replacement is hidden from the spec. Both reach the
  same handler on 3.3.5.
- **Metadata search** uses the structured `filter` form and cursor paging (the flat filters are deprecated).
- **`/timeline/*` is internal** (the web app's private API) and isn't used: the timeline comes from a
  local database fed by the sync stream.
- **HLS is alpha** and needs transcoding. Videos play from `/assets/{id}/video/playback`, which supports
  byte ranges.
- **`/assets/bulk-upload-check`** reports `assetId` and `isTrashed` for each checksum, which is what
  duplicate checks and Free Up Space need.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Patch the spec at generation time for `/sync/stream` only** (`Packages/ImmichAPI/Scripts/prepare-spec.py`): its 200 response gets an `application/jsonlines+json` binary body. `api/immich-openapi-specs.json` stays byte-identical to upstream. | The generator then exposes the body as a streaming `HTTPBody`, so lines are parsed as they arrive and decoded into the generated `Sync*` types. Nothing is hand-modelled. |
| D2 | **Uploads bypass the generated client.** The multipart body is written to a file and handed to a background `URLSession` upload task. Field names follow the generated `AssetMediaCreateDto`; the response is decoded with `AssetMediaResponseDto`. | Background sessions own the transfer and only accept file-backed uploads, which the generator's transport can't do. |
| D3 | **Media bytes (thumbnails, originals, video) are fetched by URL** through the app's own `URLSession`s, with the bearer token (or, for `AVURLAsset`, HTTP header fields). | AVPlayer must load the URL itself for range requests; thumbnails need coalescing, priorities, cancellation and a concurrency cap. The spec also declares these responses as `application/octet-stream` while the server sends images. |
| D4 | **Favourite and archive use the deprecated bulk `PUT /assets`**, wrapped in one method. | The `PATCH` replacement isn't in the spec; switching later is a one-line change. |
| D5 | **Checksum = upload bytes = the asset's "current" resource**, chosen exactly like the official app (`ResourceSelection`). An edited photo is uploaded again and stacked over its earlier version. | Identical SHA-1 checksums mean the two apps recognise each other's uploads. Verified on a real library: re-hashing photos uploaded by the official app gave identical checksums for every one. |
| D6 | **Three duplicate checks:** a local join against synced checksums; `bulk-upload-check` (500 per request) before queueing, which also catches uploads by other clients since the last sync; and the `x-immich-checksum` header on every upload, so a late duplicate is rejected before the body is read. | The local join first means the server is only asked about unknown files. |
| D7 | **Free Up Space re-checks online.** The database proposes candidates; right before deleting, `bulk-upload-check` must report each one as present and not trashed, and the phone file must be unchanged since it was hashed. A Live Photo also needs its motion part on the server. | A possibly stale sync state is never trusted for deletion. iOS asks the user to confirm. |
| D8 | **Screenshots:** phone items use PhotoKit's screenshot subtype; server-only items use a heuristic (an image with no camera make whose name or type is typical of a screenshot). | The server has no screenshot flag. |
| D9 | **Partner sharing** arrives through `PartnersV1` / `PartnerAssetsV2` sync and is stored under the partner's own owner id; the Library includes a partner's items only while `inTimeline` is on. Shared albums are the way to share chosen photos. | This is the server's model: partner sharing is whole-library. |
| D10 | **The grid is a custom `UICollectionViewLayout`.** | For tens of thousands of uniform tiles in one section, frames and visible ranges are arithmetic (constant time), and the pinch transition needs exact control over each tile so the one under the fingers stays put. |
| D11 | **Stacks:** `StacksV1` is synced; the Library shows one item per stack: the version on this iPhone, else the stack's primary, else the newest. | After an edit, the new version and the original are both on the server; showing both looks like a duplicate. |
| D12 | **Offline:** grid thumbnails are never evicted once loaded (the cache limit applies to previews); Download All Thumbnails fills in the rest on Wi-Fi at the lowest request priority. Keep Offline stores chosen originals in Application Support (never purged by iOS, excluded from device backups). | The whole Library stays browsable without a connection, and chosen photos open at full quality. |

## 3. Architecture

Local Swift packages, all in Swift 6 language mode (strict concurrency), assembled by XcodeGen
(`project.yml`), so a clean checkout builds with `xcodegen generate && xcodebuild`.

| Package | Role |
|---|---|
| `Core` | Logging (OSLog categories), Keychain, accounts and per-account paths, server settings, network path observer |
| `CloudCore` | Provider-neutral protocols and models (`CloudProvider`, `CloudConnection`, errors, connectivity). The UI only talks to these. |
| `ImmichAPI` | Client generated with swift-openapi-generator (committed; `Scripts/generate-api.sh`), plus hand-written wrappers |
| `ImmichCloud` | The Immich implementation of `CloudCore`, including the backup upload format |
| `Sync` | `/sync/stream` client, JSON Lines parser, event applier and acks |
| `Persistence` | GRDB database: server index, phone index, backup queue, merged timeline, stacks, partners |
| `Library` | PhotoKit index (full scan, then persistent change history), iCloud identities, checksum rule, streamed SHA-1 |
| `Backup` | Upload queue (actor), PhotoKit streaming into upload bodies, background session, background tasks |
| `MediaCache` | Thumbnail/preview pipeline (memory + disk), originals and Keep Offline, request limiter, ThumbHash |
| `GridGeometry` | Grid levels and pinch-zoom maths |
| `PhotosAppUI` | All screens: SwiftUI, with UIKit for the grid, viewer and player |

### Persistence: GRDB rather than SwiftData

- The core queries are joins over tens of thousands of rows (phone checksum against server checksum,
  Free Up Space candidates, backup counts). Each is one indexed SQL statement; the merged timeline of
  25,000 server and 13,000 phone items builds in about 110 ms.
- Sync batches become single transactions of upserts.
- Records are plain `Sendable` structs and `DatabasePool` (WAL) allows concurrent reads, which suits
  Swift 6 concurrency; `ValueObservation` drives UI updates.
- It's plain SQLite, safe to open from background relaunches; migrations are explicit and tested.

### Key flows

- **Launch.** The last Library list is read from a compact binary cache file; the database query
  replaces it when ready. The grid is on screen in roughly 300–400 ms on an iPhone 12 Pro Max; the
  server probe, sync and PhotoKit diffing run afterwards.
- **Merge.** Server items are paired with phone items by checksum. Phone items not yet hashed show as
  phone-only until they are; identities stay stable so tiles don't move.
- **Server selection.** On launch, foreground and every network change, the home address is probed
  (`/server/ping`, 1.5 s); otherwise the away address (e.g. Tailscale) is used. No location or Wi-Fi
  name permission is needed.
- **Backup.** Newest first; a Live Photo's motion part before its still. Each file streams from PhotoKit
  into the upload body and the SHA-1 in one pass, so bytes and checksum always agree. Two uploads at a
  time, exponential backoff (30 s × 2ⁿ, at most 6 h), a temporary-file budget, and a guard that skips a
  file that has crashed the app three times.
- **Live Photos from the server** are built from both originals (`PHLivePhoto` needs the content
  identifier metadata that previews drop).
- **HDR.** Phone photos display with high dynamic range; server photos get HDR from the original's
  gain map when it's downloaded (zoom, or after settling on the home network).
- **Editing.** Edits are parameters (`EditState`) rendered with Core Image in extended range.
  Phone items are saved as PhotoKit edits (original kept, revertible), photos with a fresh gain map
  computed from the edited HDR rendition and the original metadata; trim-only video edits are copied
  without re-encoding (Dolby Vision kept). Server-only items are rendered from the original, uploaded and
  stacked.

## 4. Being gentle with small servers

- Thumbnails and previews: at most four requests at a time, visible first, cancelled when tiles scroll
  away; failures (e.g. a preview still being generated) back off instead of being retried on every scroll.
- Background thumbnail downloads use at most two of those slots, and only when nothing else is waiting.
- Uploads: two at a time, with the checksum header.
- Sync: one stream, acknowledged per run of events; at most once a minute when triggered automatically.
- Originals are fetched only on demand (zoom, share, Live Photo, Keep Offline).

## 5. Security notes

- The access token is kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`, so background uploads work
  while the phone is locked); the Locked Folder PIN is kept behind Face ID / passcode.
- App Transport Security: plain HTTP is allowed only to private-network addresses (iOS's own exemption),
  Tailscale MagicDNS names (`*.ts.net`, encrypted end to end by Tailscale) and short local names. Anything
  else needs HTTPS.
- Files: the database and caches use iOS data protection; Keep Offline originals are excluded from device
  backups.
- Logs never contain tokens or passwords; asset ids and file names may appear in the app's own log,
  which the user shares only on purpose.
- Signing out ends the server session and removes the token, the Hidden PIN and the account's local
  data. Locking Hidden deletes cached thumbnails, previews and originals of hidden items.
- See also [`SECURITY.md`](../SECURITY.md).

## 6. Known limitations

- iOS gives apps no API for clean-up, Portrait lighting or Photographic Styles; those editor tools
  aren't offered.
- iOS doesn't allow another app to be the system photo picker, so other apps keep using the phone's
  own library.
- AirPlay receivers fetch video URLs themselves without the app's sign-in; a short-lived one-asset
  shared link is created for them.
- Resource selection relies on an undocumented PhotoKit property (as the official app does), guarded
  by `responds(to:)` with fallbacks.

## 7. Testing

- `Scripts/test.sh` runs the unit tests of every package that builds on macOS (Swift Testing).
- On-device self-tests are launch arguments; they print to the console and save snapshots in
  `Library/Caches/selftest`:
  `-VerifyChecksums`, `-BackupSelfTest`, `-ConnectivitySelfTest`, `-LaunchTiming`, `-ScrollSelfTest`,
  `-ScreensSelfTest`, `-EditorSelfTest`, `-EditorFilesSelfTest`, `-OfflineSelfTest`.
  `-EditorSaveSelfTest` and `-EditorRevertSelfTest` change the newest photo (iOS asks first).
  `-VideoEditSelfTest` works on a duplicate of a video (`-VideoEditTarget NAME`): every editor tool,
  with the preview player's frames compared against the edit rendered from the source, the files a
  save writes, one real save, then the duplicate is deleted (iOS asks). `-VideoEditPreviewOnly` checks
  the preview on the original without saving anything.
