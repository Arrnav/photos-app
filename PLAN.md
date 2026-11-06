# Photos – Implementation Plan

Native iOS client for a self-hosted Immich **v3.3.5** server. This plan is the output of Step 0 and needs your approval before Milestone 1 starts.

---

## 1. Step 0 findings

### 1.1 Environment checks

| Check | Result |
|---|---|
| `../immich` checked out at `v3.3.5` | ✅ `git describe --tags --exact-match` → `v3.3.5`, working tree clean |
| `api/immich-openapi-specs.json` matches `../immich/open-api/immich-openapi-specs.json` | ✅ byte-identical (`cmp`) |
| Spec size | 280 operations |

### 1.2 What the spec told me that shapes the design

1. **`/sync/stream` has an untyped response.** It returns JSON Lines (`application/jsonlines+json`), but the spec declares a `200` with no content. A client generated from the spec as-is can't read the body. The event payload types (`SyncAssetV2`, `SyncAssetExifV1`, …) *are* in the spec, so they will be generated.
2. **`PUT /assets` and `PUT /assets/{id}` are deprecated in v3.** Their replacements (`PATCH`) exist on the server but are hidden from the spec (`@ApiExcludeEndpoint`) and call the same service method. The deprecated `PUT` still works on 3.3.5.
3. **Metadata search changed in v3.2.0.** Every flat filter on `MetadataSearchDto` (`city`, `make`, `takenAfter`, …) is deprecated. They are replaced by a structured `filter: SearchFilter` (`StringFilter`, `DateFilter`, `EnumFilter…`, plus `or` branches), `orderBy`, and cursor paging (`cursor` / `nextCursor`). We use the new form.
4. **`/timeline/buckets` and `/timeline/bucket` are marked `Internal`.** They are the web app's private API and may change without notice. We don't depend on them. The timeline comes from the local database, fed by the sync stream.
5. **HLS (`/assets/{id}/video/stream/...`) is `Alpha` and needs transcoding.** It's not used. Video plays from `/assets/{id}/video/playback`, which supports byte ranges.
6. **Bulk upload check:** each `AssetBulkUploadCheckResult` comes back with `action`, `reason`, `assetId` and **`isTrashed`**. That's exactly what Free Up Space needs to check against the live server.
7. **Auth:** the spec allows `Authorization: Bearer <token>`, `x-api-key`, or the `immich_access_token` cookie.

### 1.3 How the official Flutter app works (studied for behaviour only, no code copied)

**Login and tokens**
- It resolves the server URL through `/.well-known/immich`, then appends `/api`, then calls `GET /server/ping` (5 s timeout).
- `POST /auth/login` returns `accessToken`. The token goes into the app's own key-value store (not the Keychain). It's sent as the `immich_access_token` cookie, set on a shared cookie store for **every** configured server URL (local and external). That way switching URLs doesn't need a new login.
- It sends `deviceModel` / `deviceType: iOS` headers on login, and generates a stable device id once.
- On launch it calls `GET /users/me`. A 401 means the token has expired, so it logs out.
- Server switching uses the **Wi-Fi name**: if the SSID matches, use the local URL, otherwise try the external URLs in order. Our ping-probe approach doesn't need location permission.

**Timeline sync**
- One `POST /sync/stream` with `{types: [...]}` and `Accept: application/jsonlines+json`. The response is streamed and split on `\n`. Each line is `{type, data, ack}`.
- Events are processed in runs of the same type, and the **last ack of each run** is sent with `POST /sync/ack`. Batches are 5,000 lines.
- `SyncResetV1`: wipe all remote state locally, then run the stream again. `SyncCompleteV1`: end of stream, clean up stale rows.
- `DELETE /sync/ack {types}` forces the server to resend an entity type. They use this for client-side migrations.
- Request types used, all V2 where available on 3.3.5: `AuthUsersV2, UsersV1, AssetsV2, AssetExifsV1, AssetEditsV1, AssetMetadataV1, PartnersV1, PartnerAssetsV2, PartnerAssetExifsV1, AlbumsV2, AlbumUsersV1, AlbumAssetsV2, AlbumAssetExifsV1, AlbumToAssetsV1, MemoriesV2, MemoryToAssetsV2, StacksV1, PartnerStacksV1, UserMetadataV1`, plus the People/Faces/OCR types. We'll skip those last three because ML is off.
- There's also a WebSocket channel (`AssetUploadReadyV1/V2`) for live updates. It's optional for us; foreground/refresh sync is enough.

**Checksums**
- SHA-1 of a single `PHAssetResource`, streamed with `PHAssetResourceManager.requestData`, encoded as **base64**.
- Choosing the resource: keep only media resources (photo: `.photo/.alternatePhoto/.fullSizePhoto`; video: `.video/.fullSizeVideo/.fullSizePairedVideo`; never `.adjustmentData` or `.photoProxy`). If there's one, use it. Otherwise prefer the "current" one, then the full-size one. **For an edited photo this is the rendered edit, not the original.**
- For a Live Photo only the still is hashed. The paired video isn't hashed or matched up front.
- Network access (iCloud download) during hashing is only allowed for albums the user explicitly selected.
- Hashes are cached per `localIdentifier`. After a reinstall, hashes are rebuilt **without re-hashing**: the local iCloud `cloudIdentifier` plus `creationDate`, adjustment time and location are matched against the `mobile-app` asset metadata the server has stored for each upload.

**Duplicate check and upload**
- The current Flutter app does **not** call `bulk-upload-check`. It removes duplicates locally: any local asset whose checksum matches a synced remote asset owned by the current user doesn't get uploaded.
- Upload is `POST /assets` multipart, file field `assetData`, with fields `filename`, `deviceAssetId`, `deviceId`, `fileCreatedAt`, `fileModifiedAt` (UTC ISO-8601), `isFavorite`, `duration`, and `metadata`. `deviceAssetId`/`deviceId` are only needed by servers ≤ 2.7.5 but are still sent.
- The `metadata` field is JSON: `[{key: "mobile-app", value: {cloudId, createdAt, adjustmentTime, latitude, longitude}}]`. It's only attached to stills and plain videos, never to a Live Photo's motion part.
- Server side: if the `x-immich-checksum` header is set, the server returns `200 {status: "duplicate", id}` **before reading the body**. Otherwise it hashes the uploaded bytes and relies on a unique constraint per user (`(ownerId, checksum)`). So **the bytes we upload must be exactly the bytes we hashed.**
- Edited photos: the hash changes, so the new version is uploaded as a new asset, and then `POST /stacks` stacks it with the earlier server version.

**Live Photos**
1. Upload the **motion video** (from the paired-video resource) with `visibility=hidden`, and no `mobile-app` metadata.
2. The response `id` becomes `livePhotoVideoId` on the **still's** upload, which runs at top priority.
3. The server links the two. Viewing: the still has `livePhotoVideoId`, and the motion part plays from `/assets/{livePhotoVideoId}/video/playback`.

**iCloud-only assets**
- They check `isLocallyAvailable(isOrigin: true)`. If false, they download from iCloud with progress (photo, plus the motion part for Live Photos) before uploading.
- Separate "use cellular for photos" and "use cellular for videos" settings control whether a task needs Wi-Fi.

**Free Up Space**
- Candidates are local assets with `createdAt ≤ cutoff`, joined on checksum to a remote asset with **`ownerId = me` and `deletedAt IS NULL`** (not in trash).
- Excluded:
  - assets in iOS shared albums
  - assets in "keep" albums (messaging apps — WhatsApp, Telegram, Signal… — are kept by default)
  - favourites, if "keep favourites" is on (checked both locally and remotely)
  - optionally, by media type
- Total size is the sum of the remote EXIF `fileSizeInByte`. Deletion goes through the platform API in batches.

**Background work on iOS**
- One `BGAppRefreshTask` (earliest in 5 min) and one `BGProcessingTask` (earliest in 15 min, `requiresNetworkConnectivity`). `UIBackgroundModes`: `fetch`, `processing`.

---

## 2. Decisions (approved 2026-10-25)

These go against, or add to, the brief. Everything else follows it as written. All of D1–D9 were approved as written.

| # | Decision | Why |
|---|---|---|
| D1 | **Patch the spec at build time for `/sync/stream` only.** A script (`ImmichAPI/Scripts/prepare-spec.py`) copies `api/immich-openapi-specs.json` to `ImmichAPI/Sources/ImmichAPI/openapi.json` and adds `content: {"application/jsonlines+json": {schema: {type: string, format: binary}}}` to that one response. The original in `api/` is untouched. | The generator then exposes the body as a streaming `HTTPBody`, so we parse lines as they arrive. Every line is decoded into the generated `Components.Schemas.Sync*` types, so nothing is hand-modelled. |
| D2 | **Upload (`POST /assets`) bypasses the generated client.** We build the multipart body to a file on disk and hand it to a **background `URLSession`** `uploadTask(with:fromFile:)`. Field names come from the generated `AssetMediaCreateDto`, and the response is decoded with the generated `AssetMediaResponseDto`. | Background sessions need the system to own the transfer and only accept file-backed uploads. The generator's transport can't do that. |
| D3 | **Media bytes (`/thumbnail`, `/original`, `/video/playback`) are fetched by URL**, built from the generated `Servers`/path constants, through our own `URLSession` in `MediaCache`. Auth is the bearer header, or for `AVURLAsset` the public `AVURLAssetHTTPCookiesKey` with the `immich_access_token` cookie. | AVPlayer must load the URL itself for range streaming. Thumbnails need request coalescing, prioritisation, cancellation on scroll and a 4-request cap, which the generated client gets in the way of. The spec also declares these as `application/octet-stream` while the server returns `image/webp`/`image/jpeg`, and the generator may reject that mismatch. I'll confirm the behaviour in M1 and switch thumbnails to the generated client if it's clean. |
| D4 | **Favourite/archive use the deprecated `PUT /assets`** (bulk) from the spec. | The non-deprecated `PATCH` isn't in the spec. `PUT` and `PATCH` hit the same handler on 3.3.5. I'll wrap it in one method so it's a one-line change if a future spec exposes `PATCH`. |
| D5 | **Hash = upload bytes = the "current" resource**, the same rule as the official app. An edited photo gets uploaded again and stacked with the previous version. | This gives the same checksums as the official app, so the two apps can coexist and neither re-uploads the other's assets. **Hard requirement:** the official app is uploading ~250 GB from your phone right now, so our checksums must match its checksums byte for byte. M3 includes a check of this against real data (see M3). |
| D6 | **Two-step duplicate check.** (a) Local join against synced remote checksums, like the official app. (b) `POST /assets/bulk-upload-check` (batches of 500) right before queueing, which also catches assets uploaded by other clients since the last sync. (c) `x-immich-checksum` header on every upload, so a late duplicate costs the Pi nothing. | You asked for the bulk check. Doing (a) first means we only ask the server about assets we don't already know about. |
| D7 | **Free Up Space re-checks online.** The local DB proposes candidates. Then `bulk-upload-check` is called right before deletion, and an asset is only deleted if the result is `reject/duplicate`, `isTrashed == false`, and `assetId` is owned by me. | Doesn't trust a sync state that might be stale. |
| D8 | **"Screenshots" in search.** The server has no screenshot flag. Local assets use `PHAssetMediaSubtype.photoScreenshot`. Server-only assets use a heuristic: image, no camera `make`, file name/extension typical of iOS screenshots (`.PNG`, no EXIF). | Best that's possible without ML. Labelled "Screenshots (approx.)" for server-only results. **Low priority:** done last in M6, and dropped from M6 if time is short. |
| D10 | **Grid uses a custom `UICollectionViewLayout`, not a compositional layout** (decided in M1; accepted with the M1 grid sign-off, 2026-10-25). | The brief suggested compositional. For a uniform square grid with 25k+ items in one continuous section, a custom layout works out every frame and visible range arithmetically (constant time per query). The interactive pinch transition also needs exact control over each tile's frame, so the tile under your fingers stays in place. Compositional layout gives nothing extra here, and very large sections are costly for it. |
| D9 | **Partner sharing**: your partner's assets come in through `PartnerAssetsV2` sync. They're shown in the Albums tab under "Shared Library", and are included in the main timeline only for partners where `inTimeline` is on (`PUT /partners/{id}`). | This is how Immich models partner sharing. |

## 2a. Constraints you added at approval

- **Free provisioning (personal team).** The app is signed with your **free Personal Team**. That's the same ID as the paid individual membership, which lapsed on 28 June 2026 and won't be renewed: the team became the Personal Team when it expired.
  - **Today (checked 2026-10-25):** the Personal Team still receives a **1-year profile** (expires **25 Oct 2027**). It's signed with the old paid-era certificate **`9U64NBH73B`**, which expires on **25 Nov 2026**.
  - **From 25 Nov 2026:** expect the installed app to **stop launching** when that certificate expires. Reinstall with a fresh free certificate (see README › Re-signing; Xcode creates the certificate automatically). From then on, assume **7-day profiles and weekly reinstalls**. Reinstalling keeps the app's data (database, caches, Keychain tokens, upload queue).
  - The bundle ID is now `com.ethwood.photos`. A fresh ID keeps free-provisioning signing separate from the one registered under the earlier paid setup.
  - The team ID lives only in `Config/Local.xcconfig` (not committed; see `Local.xcconfig.template`). `project.yml` names no team.
  - The app has no entitlements file and no capabilities. It's signed with just the three baseline entitlements (`application-identifier`, `team-identifier`, `get-task-allow`). The push entitlement noticed in M1 belonged to an unrelated app's profile, not to this app.
  - Used: Background Modes (`fetch`, `processing`; Info.plist only), Keychain (default access group), Photos, Local Network, `BGTaskScheduler`.
  - Not used: App Groups, extensions, iCloud, Push, Access Wi-Fi Information. Anything that needs a paid account stays optional and off by default.
- **Side by side with the official app.** The official app keeps backing up during development, until M5 is stable. Our uploads use `x-immich-checksum`, so anything the official app uploaded first comes back as a cheap `duplicate`.

---

## 3. Endpoints used

All of these go through the generated client unless noted (D1–D4).

| Area | Operation | Endpoint |
|---|---|---|
| Connectivity | `pingServer` | `GET /server/ping` (local/remote probe, 1.5 s timeout) |
| | `getServerVersion` | `GET /server/version` (warn if > 3.3.5) |
| | `getAboutInfo` | `GET /server/about` (settings screen) |
| Auth | `login` | `POST /auth/login` |
| | `logout` | `POST /auth/logout` |
| | `validateAccessToken` | `POST /auth/validateToken` |
| | `getMyUser` | `GET /users/me` |
| Sync | `getSyncStream` | `POST /sync/stream` (D1) |
| | `sendSyncAck` / `deleteSyncAck` | `POST` / `DELETE /sync/ack` |
| Assets | `getAssetInfo` | `GET /assets/{id}` (info panel: full EXIF, albums) |
| | `getAllAlbums` with `assetId` | `GET /albums?assetId=` ("in albums" on info panel) |
| | `updateAssets` | `PUT /assets` (favourite, archive) (D4) |
| | `deleteAssets` | `DELETE /assets {ids, force:false}` → Immich trash |
| | `restoreAssets` | `POST /trash/restore/assets` (undo) |
| | `createStack` | `POST /stacks` (edited re-uploads) (D5) |
| Media | `viewAsset` | `GET /assets/{id}/thumbnail?size=thumbnail\|preview\|fullsize` (D3) |
| | `downloadAsset` | `GET /assets/{id}/original` (share, save, zoom upgrade, remote Live Photo still) (D3) |
| | `playAssetVideo` | `GET /assets/{id}/video/playback` (range requests, AVPlayer) (D3) |
| Backup | `checkBulkUpload` | `POST /assets/bulk-upload-check` (D6, D7) |
| | `uploadAsset` | `POST /assets` multipart, background session (D2) |
| Albums | `getAllAlbums`, `getAlbumInfo` | `GET /albums[?isShared]`, `GET /albums/{id}` (fallback; primary source is sync) |
| | `createAlbum`, `addAssetsToAlbum`, `removeAssetFromAlbum` | album editing (M6) |
| Partners | `getPartners` | `GET /partners?direction=shared-with\|shared-by` |
| | `updatePartner` | `PUT /partners/{id} {inTimeline}` |
| Memories | `searchMemories` | `GET /memories?for=<today>` (sync `MemoriesV2` is the primary source) |
| Search | `searchAssets` | `POST /search/metadata` with `filter` + `cursor` |
| | `getSearchSuggestions` | `GET /search/suggestions?type=country\|state\|city\|camera-make\|camera-model` |

**Sync request types:** `AuthUsersV2, UsersV1, AssetsV2, AssetExifsV1, AssetMetadataV1, PartnersV1, PartnerAssetsV2, PartnerAssetExifsV1, AlbumsV2, AlbumUsersV1, AlbumAssetsV2, AlbumAssetExifsV1, AlbumToAssetsV1, MemoriesV2, MemoryToAssetsV2, StacksV1, PartnerStacksV1`.
Not requested: People, AssetFaces, AssetOcr (ML is off), AssetEdits (we don't edit), UserMetadata.

**Not used on purpose:** `/search/smart`, `/search/explore`, `/search/person`, faces, OCR, duplicates (ML); `/timeline/*` (Internal); HLS (Alpha, needs transcoding); `/download/archive` (we download originals one at a time).

---

## 4. Architecture

### 4.1 Project layout

```
photos-app/
├─ project.yml                     XcodeGen. App target "Photos", com.ethwood.photos, iOS 18, iPhone
├─ App/                            @main, AppEnvironment (composition root), Info.plist, entitlements, assets, icon
├─ Packages/
│  ├─ ImmichAPI/                   generated client (committed; Scripts/generate-api.sh) + middleware, server selection
│  ├─ Core/                        Shared: Logging (OSLog categories), Keychain, Settings, Clock, ConnectivityMonitor
│  ├─ Persistence/                 GRDB database, migrations, record types, observation queries
│  ├─ Library/                     UnifiedAsset model, merge/dedup, PhotoKit adapter
│  ├─ Sync/                        Sync stream client, JSONL parser, event applier, ack handling
│  ├─ Backup/                      Hasher, candidate selection, queue, multipart writer, background session, BGTasks
│  ├─ MediaCache/                  Thumbnail/preview/original pipeline, memory + disk cache, request limiter
│  ├─ CloudCore/                   provider-neutral Cloud protocols and models (added 2026-10-28)
│  ├─ ImmichCloud/                 Immich implementation of CloudCore (added 2026-10-28)
│  └─ PhotosAppUI/                 SwiftUI screens + UIKit grid/viewer/player (renamed from PhotosUI: the system PhotosUI framework is needed for Live Photos)
├─ Tests/                          (each package also has its own test target)
└─ api/                            Immich's spec + README noting origin/licence
```

I picked XcodeGen so the `.xcodeproj` isn't committed and `xcodegen && xcodebuild` builds from a clean checkout. Packages are local SwiftPM packages referenced from `project.yml`. All of them use `swiftLanguageModes: [.v6]` (strict concurrency).

### 4.2 Persistence: **GRDB** (not SwiftData)

- **Scale and SQL.** The core queries are joins over 25k–50k+ rows: local hash against remote checksum per owner, the Free Up Space candidates, the backup counts. In GRDB they're one indexed SQL statement each. SwiftData can't do an arbitrary join, and its `#Predicate` gets slow across relationships at this size.
- **Bulk writes.** Sync batches of up to 5,000 events become a single transaction of `INSERT … ON CONFLICT DO UPDATE`. SwiftData inserts objects one at a time through change tracking, which is much slower and uses more memory.
- **Swift 6 concurrency.** GRDB records are plain `Sendable` structs, and `DatabasePool` (WAL) allows concurrent reads while one writer works. SwiftData `@Model` objects aren't `Sendable` and are tied to a `ModelContext`, which pushes awkward actor-hopping into every module.
- **Observation.** `ValueObservation` gives the grid section snapshots that update without UI jumps when a sync batch lands.
- **Background and termination.** It's plain SQLite in the app container, safe to open from background-session relaunches and BG tasks. Migrations are explicit and testable.
- **Cost:** one dependency (GRDB.swift, MIT) and SQL written by hand. Acceptable.

**Main tables** (simplified):
- `remote_asset`: id, ownerId, checksum (indexed), type, fileCreatedAt, localDateTime, width, height, duration, isFavorite, visibility, deletedAt, livePhotoVideoId, stackId, thumbhash, originalFileName
- `remote_exif`: assetId → make, model, lens, exposure, fNumber, iso, focalLength, fileSizeInByte, lat/lon, city/state/country, timeZone, profileDescription
- `remote_asset_cloud_id`: assetId → cloudId, createdAt, adjustmentTime, lat/lon (from `AssetMetadataV1` key `mobile-app`)
- `remote_album`, `remote_album_user`, `remote_album_asset`, `memory`, `memory_asset`, `partner`, `user`, `stack`
- `local_asset`: localIdentifier, cloudIdentifier, creationDate, modificationDate, adjustmentTimestamp, mediaType/subtypes, playbackStyle, isFavorite, pixel size, duration, **checksum** (nullable), hashedAtModificationDate
- `local_album`, `local_album_asset`, `backup_album_selection` (selected / excluded)
- `upload_task`: localIdentifier, part (`still` / `motion` / `single`), state, attempt, nextAttemptAt, urlSessionTaskId, tempFile, remoteId, lastError, checksum. Unique on `(localIdentifier, part, checksum)`.
- `sync_state`, `settings`, `log_entry` (ring buffer for the in-app viewer)

### 4.3 Module responsibilities

- **ImmichAPI**
  - Generated `Client` and `Types` (D1 patch applied).
  - `AuthMiddleware`: adds `Authorization: Bearer`, `deviceModel`/`deviceType`, and logs request id/status/duration under the `networking` category.
  - `ServerURLProvider` (actor): the currently active base URL. The client is rebuilt cheaply when it changes.
- **Core**
  - `Log` with categories `sync`, `backup`, `networking`, `library`, `ui`, `media`.
  - `KeychainStore`: tokens per account, `kSecAttrAccessibleAfterFirstUnlock` so background uploads work while the phone is locked.
  - `AccountStore`: multiple accounts, each with its own DB file, so the two accounts never mix.
  - `ServerSelector`: on launch, foreground and every `NWPathMonitor` change, probes `local /server/ping` (1.5 s). If it answers, use local; otherwise remote. Optional SSID shortcut through `NEHotspotNetwork.fetchCurrent`. It needs the Access Wi-Fi Information entitlement, which a paid account requires (see §2a), so it is **off by default** and compiled behind a build flag. The result is published as `@Observable` state.
- **Library**
  - `PhotoKitSource`: fetch results, change observer, `PHCachingImageManager`.
  - `UnifiedAsset` is an enum-backed struct: `.local`, `.remote`, or `.both(local, remote)`, keyed by checksum.
  - `TimelineBuilder` produces day/month/year sections from a SQL query: `local_asset FULL OUTER JOIN remote_asset ON checksum` (written as a UNION in SQLite). Unhashed local assets appear as local-only until they're hashed. When a hash lands, the item's identity stays the same, so no tile moves.
- **Sync**
  - `SyncStreamClient` streams `HTTPBody` and splits lines with an `AsyncSequence` line splitter.
  - `SyncEventDecoder` decodes into generated types.
  - `SyncApplier` writes each same-type run in one transaction, then acks the last id. Handles `SyncResetV1` and `SyncCompleteV1`.
  - Triggered on launch (after the UI is up), on foreground, after an upload batch finishes, and on `BGAppRefreshTask`.
- **Backup**
  - `Hasher`: streams `PHAssetResourceManager` into `Insecure.SHA1`, at most 2 concurrent.
  - `CandidateSelector`: SQL plus `bulk-upload-check`.
  - `UploadQueue` (actor): persistent state machine, exponential backoff (30 s × 2ⁿ, max 6 h, jitter).
  - `MultipartWriter`: streams resource → temp file with a multipart envelope.
  - `BackgroundUploader`: `URLSessionConfiguration.background(withIdentifier:)`, `httpMaximumConnectionsPerHost = 2`, `isDiscretionary = false` in the foreground, and `allowsCellularAccess`/`allowsExpensiveNetworkAccess` from settings.
  - `BackgroundTasks`: registers the BG refresh and processing tasks.
- **MediaCache**
  - `ImagePipeline` (actor): request coalescing by `(id, size)`, priority (visible > prefetch), cancellation, and a `RequestLimiter` (max 4 concurrent thumbnail/preview loads).
  - Memory: `NSCache` of decoded, downsampled `CGImage`s, with a byte limit.
  - Disk: a file per `(assetId, size)` in Caches, with LRU eviction in the background up to a size cap set in settings.
  - Thumbhash decoder for instant placeholders.
  - `OriginalStore` for downloaded originals and Live Photo parts.
- **PhotosAppUI**: all screens; talks only to CloudCore protocols, never to Immich directly. View models are `@Observable @MainActor` classes that get their dependencies from `AppEnvironment` through initialisers (no singletons, no global service locator).

### 4.4 Key flows

**Instant launch (target: grid within 300 ms)**
1. `App.init` opens the GRDB pool (WAL). This is already fast.
2. The first frame shows the grid from the **cached `remote_asset` and `local_asset` tables**. The section index is a single grouped `COUNT` query by day, and cells read from paged SQL.
3. If `PHPhotoLibrary` access is authorised, `PHFetchResult` (lazy) fills in local items not yet in `local_asset`.
4. After the first frame: the server probe, `/server/version`, the sync stream, and PhotoKit diffing, all in the background. Updates come in through diffable data source snapshots.

**Timeline merge and de-duplication**
- The identity key is the **checksum** if known, otherwise `local:<localIdentifier>`, or `remote:<id>`. When a local asset gets hashed, the merged item keeps its local id as its diffable identifier and gains its remote half. Its position doesn't change, because the local `creationDate` takes priority as the sort date.
- Sort date: the local `creationDate` when there's a local copy, otherwise the remote `fileCreatedAt`. Day grouping uses the remote `localDateTime` (wall-clock time where the photo was taken) so it matches the Immich web app.

**Remote Live Photo**
1. Download the still's **original** (HEIC) and the motion part's original (MOV) into `OriginalStore`.
2. Build it with `PHLivePhoto.request(withResourceFileURLs:)`. This only works with the originals, because both carry the system's content identifier metadata, which the server's JPEG previews drop.
3. While that downloads, the viewer shows the preview still.

**HDR**
- Local photos: `PHImageManager` plus `UIImageView.preferredImageDynamicRange = .high`.
- Remote photos: HDR needs the original HEIC with its gain map, since the server preview is SDR JPEG. So the HDR upgrade happens together with the full-resolution upgrade, either on zoom or once the image has been open for about 1 s on Wi-Fi.
- Video: AVPlayer handles HDR10/Dolby Vision natively from the original.

---

## 5. Milestones

Each milestone ends with: it builds from the command line, runs on your iPhone 12 Pro Max, tests are green, there's an Instruments pass for the relevant parts, and I write a summary plus a list of things to check by hand.

### M1 – Foundations
**Status (2026-10-25): accepted.** Grid, pinch-zoom, sync, server switching and caching were checked on device. Still open, not blocking M2:
- manual check 6 (a second account, switching, signing out one of two)
- the Instruments pass on the full library: Time Profiler and Animation Hitches while scrolling at 5/15/30 columns, plus Allocations
- XcodeGen project, packages, Swift 6 strict concurrency, OSLog categories.
- `api/README.md` stating the spec's origin (Immich, AGPL-3.0) and that it's used only as an interface description.
- `ImmichAPI` generated through the build plugin with the D1 patch script. Confirm the D3 content-type behaviour.
- ATS exceptions for `192.168.1.10` and `100.64.0.10` only (`NSExceptionDomains` with `NSExceptionAllowsInsecureHTTPLoads`), plus the Local Network usage string.
- **Early device check of plain HTTP** to both `192.168.1.10:2283` and `100.64.0.10:2283` with the narrow exceptions, using the connection test on the login screen. If iOS doesn't honour exceptions for IP addresses, fall back to `NSAllowsArbitraryLoads`. Recorded here:
  - **ATS result:** the narrow exceptions work and `NSAllowsArbitraryLoads` is **not** needed (verified on device, see §9).
- Login screen with a local and remote URL. Token in Keychain. Account switcher scaffold (one DB per account).
- `ServerSelector` with ping probe and `NWPathMonitor`. Server version check and warning.
- GRDB schema plus the sync stream for assets, EXIF, metadata and users.
- **Remote-only** timeline grid: `UICollectionView` compositional layout, day sections, thumbhash placeholders, then thumbnails through `MediaCache` (4 concurrent max, prefetch and cancel).
- Pinch-to-zoom between columns, and the scrubber (basic).
- Tests: URL switching, JSONL line splitting and decoding, sync applier (including reset), cache eviction.

### M2 – Viewer
**Status (2026-10-25): first device build installed, awaiting manual checks.** Decisions made while building it:
- the zoom transition is custom UIKit, not the iOS 18 zoom transition
- the info panel is a sheet (medium/large), not an inline panel
- originals load when zooming in, or about 0.8 s after a page settles on the home network; the same check on the away network would be too heavy
- the actions are optimistic: the grid updates at once and reverts if the server refuses
- video pages show the preview and a play button; playback comes in M4
- **Viewer redesign (2026-10-26):** an iOS 26 viewer:
  - Liquid Glass controls and a thumbnail strip
  - an inline info panel
  - the full ··· menu: Copy, Duplicate, Hide, Start Slideshow, Add To ▸, Adjust Info ▸
  - a share screen with multi-select and Options
- **Duplicate:** a lossless copy with one added metadata marker, so the checksum differs and Immich accepts it as a new asset. Live Photos are duplicated as a pair.
- **Hidden = Immich Locked Folder** (your decision), called "Hidden" throughout the app.
  - The Immich PIN is kept in the Keychain behind Face ID (or the passcode). It's generated if the account has none, and asked for once if one exists.
  - Hidden locks when leaving the album or the app.
  - Settings shows the PIN after Face ID, for use in the Immich web app.
- **Album items brought forward from M6:** Add To ▸ Album and New Album; also the Albums tab › Utilities › Hidden.
- Zoom transition from the tile (iOS 18 `.navigationTransition(.zoom)` if it lets us return to the source tile reliably; otherwise a custom UIKit interactive transition).
- `UIPageViewController`-style paging built on a horizontal `UICollectionView` with paging cells. Each cell is a `UIScrollView`-based zoomable view.
- Double-tap and pinch zoom. Paging is disabled while zoomed past fit, and panning at the edge hands off to paging. Swipe down to dismiss interactively.
- Preview size first, then the original on zoom. HDR display.
- Info panel (swipe up): date/time, camera/lens/exposure, size/resolution, `MapKit` snapshot, albums.
- Share sheet (download the original into a temp file, then `UIActivityViewController`). Favourite, archive, delete to trash with undo.

### M2b – UI parity with the reference screenshots (requested 2026-10-28, before more functionality)
You asked for the UI, animations and behaviour to match the reference screenshots (iOS 26) before going deeper. Phases, in order:
1. **Viewer polish:** open/close 1.2× faster, swipe deceleration 1.2× faster, release-to-nearest snap 1.8× faster (display-link animation, so neither photo is dropped mid-slide). **Hidden PIN:** use your own 6-digit Immich PIN (set or entered once, then behind Face ID), never a generated one.
2. **App structure:**
   - **Library** and **Collections** in one floating glass capsule, with a separate round **Search** button. This replaces the 4-tab bar; For You and Albums move into Collections.
   - After scrolling, the bar morphs into a Library icon plus **Years | Months | All** and a smaller Search button.
3. **Library header:**
   - large white "Library" over a dark blurred band
   - the subtitle shows:
     - the date range of the visible rows ("16–24 Oct 2026") while scrolling or whenever the server is reachable
     - "Syncing Paused ›" after 5 s idle when the server is unreachable; tapping it shows the "Syncing with Cloud Paused" alert
     - "N Items" at the very end, as in your screenshot
   - top right: filter menu and Select
4. **Select mode:**
   - tap or drag across rows to select, auto-scrolling near the edges
   - footer: Share, "Select Items" / "Show Selected (N)", Delete
   - a Show Selected sheet with Deselect All and ✓
   - a ··· menu with multi-item actions
5. **Filter menu:**
   - sort by Added or Captured
   - All Items, Favourites, Edited, Shared with You, Captured by Me, Not in an Album
   - Media Types ▸ (Photos, Videos, Screenshots)
   - View Options ▸ (Zoom In, Zoom Out, Aspect Ratio Grid, Show Screenshots, Show Shared with You)
6. **Share screen rebuilt:**
   - the photo shrinks up into a carousel of fixed-height rounded cards, with neighbours sliding in from both sides
   - the share panel slides up at the same time (about 0.7 s)
   - header with Options and ✕
   - extra actions in the share panel: Add to Album, Add to Shared Album, Export Unmodified Original, Create Shared Album Link (Immich shared link), Copy
7. **Collections:**
   - sections: Memories, Pinned, Albums, People, Featured Photos, Trips, Media Types, Utilities (Hidden 🔒, Recently Deleted 🔒, Captured by Me, …)
   - collapse chevrons, and a ··· menu with layout choices, Show All, Collapse All and Reorder
   - an account button opening a settings card, labelled "Cloud" instead of iCloud; our own server settings go at the bottom
8. **Search screen:**
   - title, Recents (Recently Viewed, Recently Shared, recent searches) with Clear, suggestion chips, and a bottom search field with ✕
   - searching runs on the phone's own copy of the library first; server search comes in M6

**Can't match the reference exactly (flagged):**
- **The share panel** (people, apps, actions, Edit Actions) is the system's own component. It can't be embedded or restyled, and it shows its own small title. Edit Actions and favourite actions are therefore iOS's own and work as-is. Our carousel and header sit above it.
- **The system account photo** isn't available to apps. The account button uses the Immich profile picture.
- **ML-based sections** (People, Featured Photos, Trips, Receipts, Illustrations, QR Codes, Selfies and Portrait detection, Memories content) depend on Immich machine learning, which is off. They show empty states, or use metadata approximations where noted.
- **Duplicate and Hidden:** as decided on 2026-10-26.

**Status (2026-10-28, build on the phone):** phases 1–8 are in place for review. Data behind them:
- Albums, shared albums and memories load from the server (`getAllAlbums`; album contents via metadata search with `albumIds`; `searchMemories`). Recently Deleted (behind Face ID) and Archive come from the synced database. Map groups geotagged photos into thumbnail pins.
- Collections settings (layout, order, hidden sections, collapsed sections, pinned items) stay on the phone. The account card's Photos options are stored too: View Full HDR works now; the rest take effect with the features they belong to (video in M4, ratings and keywords later).
- Search parses years, months, seasons, "videos", "favourites", "screenshots" and "live photos". Remaining words match place, caption, file name and camera on this phone. Recents record viewed and shared photos.

**Not matched yet, or approximated:**
- Wallpaper Suggestions is iPhone-only (the wallpaper API isn't public), so it's left out.
- The account card's storage tile reports the server connection instead of storage.
- Shared Library maps to Immich partner sharing; it lists users only, and switching it on comes later.
- Selecting inside collection grids (albums, Map groups) comes with the functionality pass.

### M3 – Local-first library
- PhotoKit authorisation (full and limited), `local_asset` indexing with a change observer, and hashing (initially foreground only, low priority).
- Cloud-id reconciliation so hashes don't need recomputing after a reinstall.
- Merged and de-duplicated timeline, status badges (phone / server / both) with a setting to hide them.
- Instant launch path measured against the 300 ms target. "Save to this iPhone" for server-only assets (`PHAssetCreationRequest` with the original file, so metadata is preserved).
- Years/Months views with drill-down, multi-select with drag-to-select.
- **Offline indicator:** when neither server address answers, a small, unobtrusive "Offline" badge (toolbar, not a banner). Everything cached keeps working: grid, cached thumbnails and originals, local photos. Uncached server-only tiles keep their thumbhash placeholder. No error spam. It clears itself when a probe succeeds.
- **Checksum check against the official app (D5):** a debug action hashes up to 200 local assets that the official app has already uploaded (found by matching `cloudId` and date). It reports how many match the server's checksum, and lists any mismatches with their resource types. This must be 100 % before M5 starts.
- Tests: timeline merging, de-duplication, resource selection for hashing (protocol-faked `PHAssetResource`), checksum against known vectors.

### M4 – Live Photos and video
- Local `PHLivePhotoView` with press-and-hold and a LIVE badge, plus a "view as still" toggle.
- Remote Live Photo assembly as in §4.4, with both parts cached.
- AVPlayer-based video page: custom controls (play/pause, scrubber with `AVAssetImageGenerator` thumbnails, mute, time). Pinch-zoom shares the zoom container with photos so the two gestures can't clash. Player lifecycle tied to the page so it can't get stuck. Range streaming of remote originals. HEVC/HDR/Dolby Vision, slow-mo (`AVComposition` via PhotoKit for local; remote plays the original at its native frame rate), time-lapse.
- **AirPlay**, with an `AVRoutePickerView` route button in both places:
  - **Video player:** the button sits in the player controls; `allowsExternalPlayback` is on.
  - **Viewer toolbar:** the same button.
- **Server-only video over AirPlay.** To check at home with a real TV: an AirPlay receiver may fetch the URL itself, and then it won't send our `Authorization` header or cookie.
  - If direct playback fails, the candidates are, in order:
    1. Play a locally downloaded copy. It's cached in `OriginalStore`, and AVPlayer then sends the media to the TV itself.
    2. A short-lived Immich shared link, using the `key` parameter `playAssetVideo` accepts. **Approved 2026-10-25**, on these conditions:
       - A link covers one asset and expires after **1 hour** (`expiresAt`).
       - The link is tagged in its description as created by this app.
       - The app deletes the link as soon as playback ends or the route changes.
       - Each link's id is stored in the database, so a link left behind by a crash or termination is deleted on the next launch. The 1-hour expiry is the backstop.
       - Needs `createSharedLink`/`removeSharedLink` added to the generator config.
    3. A small local HTTP proxy on the phone.
  - The choice made and the reason will be recorded here.
- **External display (Screen Mirroring):** when an external display is connected, a separate window scene shows the current photo or video full-screen on the TV, with no UI. It follows swipes in the phone's viewer, and a Live Photo plays its motion on the TV while it's pressed on the phone.
- **One-tap AirPlay mode: confirmed 2026-10-25, and the main goal for AirPlay** (the reference experience). Public APIs can't send a still photo over AirPlay, so this is experimental. With an AirPlay route active, each photo is rendered on the device into a short H.264/HEVC clip at the TV's resolution (cached), played through AVPlayer external playback, and swapped on each swipe. Videos play directly.
  - The delay per swipe (from swipe to new image on the TV) will be measured on your TV and reported with a verdict on whether it's acceptable.
  - Clips for neighbouring photos are rendered ahead of time to hide the delay.
  - Screen Mirroring (above) stays as the fallback if this doesn't work on your TV.
- **Real-TV test on your phone.** If an approach doesn't work on your TV, I'll say so and record it here.

### M5 – Backup engine
- Album selection (Recents by default), persistent queue, D6 duplicate check, multipart temp files, background `URLSession` (survives suspension and termination: `handleEventsForBackgroundURLSession` → reconcile queue state from `URLSessionTask.taskDescription`).
- `BGProcessingTask` (requires power when "only while charging" is on, requires network) for hashing and queueing; `BGAppRefreshTask` for spotting new photos and a light sync.
- iCloud originals (allow network, skip setting, Wi-Fi-only setting). Live Photo pairing (motion first with `visibility=hidden`, then the still with `livePhotoVideoId`), `mobile-app` metadata, and stacking edited re-uploads (D5).
- **Temp file budget:** each upload is a multipart temp file on disk.
  - Only a few uploads are prepared ahead of the background session (lookahead of about 4 items).
  - Total temp usage is capped at **2 GB** by default, adjustable in settings. If one item is bigger than the whole cap, it's prepared alone.
  - Each temp file is deleted as soon as its upload succeeds or fails permanently. A retry rebuilds the file.
  - On launch, any temp file not referenced by a live `upload_task` (an orphan) is deleted.
- Backup status screen: total / backed up / remaining / current item with progress / last success / errors with readable messages. Settings: on/off, cellular, charging only, pause/resume.
- Tests: upload queue state machine (crash and relaunch at every state), backoff, the never-upload-twice invariant, multipart encoding.

### M3–M5 status (2026-10-28)
Built, unit-tested and installed on the phone. On the phone so far: the merge (122 phone items, 114 paired with Cloud, 8 phone-only) and the D5 check (96/96 identical).

**To check by hand:**
1. **Library:** phone-only photos show the iPhone badge, Cloud-only ones a cloud, and both a cloud with a tick. Settings › This iPhone › Show Status on Tiles hides them.
2. **Viewer on phone photos:** photos open instantly and offline. Favourite and Delete work: iOS asks before deleting; delete everywhere or from the iPhone only. **Save to This iPhone** works on a Cloud-only photo.
3. **Video:** plays on its own when opened, if Auto-Play is on. Check pinch-zoom while playing, the frame scrubber, mute and looping. Test a phone video, a Cloud video, a slow-motion video and an HDR video.
4. **Live Photos:** press and hold plays the motion. LIVE › Off keeps it a still. Test a phone Live Photo and a Cloud one.
5. **AirPlay at home with the TV:**
   - **Video:** the receiver gets a 1-hour link, which is deleted afterwards. Report whether it plays.
   - **Photos (experimental):** each photo shows on the TV. Note the delay per swipe.
   - **Screen Mirroring:** the TV shows the current photo or video full screen, without controls.
6. **Backup:**
   - First tap **Settings › This iPhone › Test Upload (Creates Nothing)**. It must say PASS.
   - Then turn on **Back Up This iPhone** (Account card › Cloud). It should upload the 8 phone-only items.
   - Check on the Immich web app that each appears once, with correct dates, and that Live Photos are paired.
   - Lock the phone mid-upload and confirm the upload continues.

### M6 – Albums, memories, partner sharing and search
- Albums tab (mine, shared with me, shared library from partner), album detail grid reusing the timeline grid, create/add/remove.
- For You: "On this day" memory cards from synced `MemoriesV2`.
- Partner `inTimeline` toggle.
- Search: date range, places (suggestions), camera make/model, file name, media type including Live Photos (`isMotion`). Screenshots (D8) are done last, if time allows. Results come from the server with cursor paging, merged with matching local-only assets.

### M7 – Free Up Space, polish and performance
- Free Up Space with the D7 online check, review screen (count and size), `PHAssetChangeRequest.deleteAssets`, and a clear iCloud warning.
- Settings polish, log viewer with export as `.txt`, haptics, VoiceOver, Reduce Motion, Dynamic Type audit.
- Original app icon.
- **Download all thumbnails** (optional, off by default, in Settings): fetches every thumbnail in the background so the whole grid works offline.
  - Runs only on Wi-Fi and while charging, using `BGProcessingTask` (from M5) with `requiresExternalPower`, plus foreground progress.
  - Stays within the 4-request limit and the disk cache cap. If the library doesn't fit, the cap is shown so it can be raised.
  - Can be paused and resumed; progress shows done / total.
- **Keep offline** (optional) for favourites and/or selected albums: downloads and pins their originals, including Live Photo motion parts.
  - Pinned files are kept out of LRU trimming and counted separately in Storage.
  - Same Wi-Fi and charging rules. Un-pinning frees the space.
- Instruments passes (Time Profiler, Allocations, Animation Hitches) with a 25k+ asset library, and fixes.

---

## 6. Being gentle with the Pi

- Thumbnails/previews: **4 concurrent max**, visible requests first, cancelled when cells scroll away. Disk-cached indefinitely (same id and size never fetched twice).
- Uploads: **2 concurrent max** (`httpMaximumConnectionsPerHost = 2`) and the `x-immich-checksum` header so duplicates are rejected before the body is read.
- Sync: a single stream, acks per type run. Refreshed on foreground and on BG refresh, debounced to at most once every 60 s. The one exception to "no polling": while timeline items are still waiting for server previews, a delta sync every 2 minutes in the foreground. That's one small request when nothing has changed, and it stops once previews are done.
- Thumbnail failures (e.g. 404 while the server is still processing) are remembered with backoff, so scrolling doesn't re-ask the Pi for missing previews.
- Bulk check: 500 per request, sequential.
- No `size=fullsize` requests by default (that may make the server generate files). Originals only on demand.
- `URLSession` request timeout 30 s, resource timeout scaled to file size for originals.

## 7. Risks and unknowns

| Risk | Mitigation |
|---|---|
| AirPlay receiver fetches server video URLs itself, without our auth | Test in M4 on your TV. Fall back to a local copy, a shared-link `key`, or a proxy (see M4) |
| Narrow ATS exceptions don't apply to IP-address hosts | Device check in M1. Fall back to `NSAllowsArbitraryLoads` (approved) |
| Generated client rejects `image/*` for octet-stream responses | D3: fetch by URL. Verify in M1. |
| Live Photo motion upload with `visibility=hidden` returns a duplicate (motion part already on the server from another client) | Use the returned duplicate `id` as `livePhotoVideoId`, as the server intends |
| Background session relaunch while the DB is mid-migration | Migrations run before any session is reattached. Upload state is rebuilt from `taskDescription` |
| Resource ordering for hashing relies on the private KVC key `isCurrent` (the official app uses it) | Use it behind `responds(to:)`, falling back to `fullSizePhoto`/`fullSizeVideo` and then the first media resource. Covered by unit tests. Fine for a personal, non-App-Store app |
| 120 Hz scrolling with remote decode | Downsampled decode off the main thread, `prepareForDisplay` / `byPreparingThumbnail`, decoded images cached at cell pixel size |
| iOS zoom transition doesn't land on the right tile after paging | Custom UIKit transition fallback (M2) |

## 8. Approval notes (2026-10-25)

1. D1–D9 approved as written. D5 is critical (the checksums must match the official app). D8 is low priority.
2. M5: temp file budget added (lookahead, 2 GB cap as a setting, delete on success or permanent failure, orphan cleanup on launch).
3. M1: device check of plain HTTP to both IPs. Fall back to `NSAllowsArbitraryLoads` if needed, and record the result in §9.
4. Free developer account (personal team): everything works with free provisioning. Anything that needs a paid account is optional and off.
5. The official app is running its first full backup and will run side by side until M5 is stable.

## 9. Verification log

| Date | Item | Result |
|---|---|---|
| 2026-10-25 | ATS: plain HTTP to `192.168.1.10:2283` | ✅ `/server/ping` OK on iPhone 12 Pro Max (iOS, Debug build), once Local Network access was allowed. iOS exempts private-network addresses from ATS by default (control: `192.168.1.1` without an exception was not blocked), so this address doesn't actually depend on the exception. |
| 2026-10-25 | ATS: plain HTTP to `100.64.0.10:2283` (Tailscale) | ✅ for ATS: the request left the phone and only timed out because Tailscale was off at the time. Control: `100.64.0.11` (no exception) **was blocked** by ATS, and so was `1.1.1.1`. So the per-IP exception is what allows this address. End-to-end with Tailscale on: **still to check by hand.** |
| 2026-10-25 | Result | Narrow `NSExceptionDomains` entries for both IPs are enough. `NSAllowsArbitraryLoads` is not used. |
| 2026-10-25 | Generated client vs `image/*` (D3) | Confirmed: the generated `viewAsset` only accepts `application/octet-stream` and would throw on the server's `image/webp`. Media is fetched by URL. |
| 2026-10-25 | Timeline query, 30,000 assets | 63 ms on the dev Mac (test `loadsThirtyThousandItemsQuickly`). Device timing comes with the Instruments pass. |
| 2026-10-25 | Signing with the free Personal Team | ✅ signed build; `codesign --verify --deep --strict` passes; baseline entitlements only. The profile still lasts 1 year (to 25 Oct 2027), signed with paid-era certificate `9U64NBH73B` (expires 25 Nov 2026). **Check again after 25 Nov 2026.** |
| 2026-10-25 | M1 manual check: pinch to zoom | ❌ crashed on every pinch. The crash log showed a failed cast in `gridLayout` once the transition layout was installed. Fixed: the getter copes with transition layouts, and timeline updates wait until the pinch ends. **To re-check by hand.** |
| 2026-10-25 | M1 manual check: black tiles in older years | Cause found in the phone's database: 5,643 of 12,501 timeline items have no thumbhash. All were uploaded after 12:56 UTC, so the Pi is still generating thumbnails (the official app uploaded newest first) and the server returns 404. App fixes: grey placeholder; failures remembered with backoff (60 s → 10 min) so the Pi isn't asked again on every scroll; immediate retry when a thumbhash arrives; a follow-up sync every 2 min (foreground only) while previews are pending. |
| 2026-10-25 | M1 manual check: count 12,501 vs Immich 12,651 | The phone's DB holds exactly what was synced as timeline (11,356 photos + 1,145 videos), plus 3,020 hidden Live Photo motion videos and 4 trashed. Found and fixed a sync bug: a batch was applied based on its first event, so one unreadable line could silently drop a whole batch. Unreadable events are now counted, logged and shown. Added Settings › Diagnostics (phone vs server `getAssetStatistics` counts) and "Resync from Scratch". **Open:** which number Immich showed, and whether a full resync closes the gap. |
| 2026-10-25 | M1 manual check: fast-flick stutter | The phone ran Debug builds, where a thumbhash decode takes about 1.9 ms on the Mac (30–60× slower than optimised). Device installs are now Release builds (`Scripts/reinstall.sh`). The decoder is also about 2× faster (output identical across 869 decodes), and disk reads and decodes now run in parallel off the pipeline actor. **To re-check by hand.** |
| 2026-10-25 | M1 re-check: count | ✅ phone timeline 12,501 = server timeline 12,501 (Diagnostics). The 12,651 seen in the phone's own library and the official app is the **iPhone's library** count; why 150 aren't on the server becomes visible in M3 (per-item phone/server status). |
| 2026-10-25 | M1 re-check: server preview backlog | 5,643 → 5,182 waiting in 24 min, so the Pi generates about 1,100 previews/hour, oldest uploads first. The app picks them up on its own (follow-up syncs). Expected to clear in about 4½ hours. |
| 2026-10-25 | M1 re-check: pinch feel | Working, but the grid went black, shook and jumped. Cause: UIKit's interactive layout transition rebuilds cells, and the scroll view's two-finger pan kept scrolling during the pinch. Replaced with in-layout interpolation (`GridGeometry.GridZoom`, unit-tested: finger point fixed, tile size = pinch scale, end state identical to the target). Scrolling is held during the pinch, one pinch can pass several levels, and there's a new 1-column level. 3- and 1-column tiles switch to server previews once the grid is at rest. **To re-check by hand.** |
| 2026-10-25 | M1 re-check: scrolling | ✅ fast flicks are smooth (Release build). |
| 2026-10-25 | M1 re-check 2: pinch | You confirmed it's smooth, but tiles reflowed mid-pinch, one pinch moved one level, and levels didn't match the reference. Redone: the whole grid scales around the fingers; underneath, the densest level that still covers the screen is shown scaled up (soft tiles) and cross-fades as the scale passes each level; on release the pinch speed is projected forward and the grid settles (0.5 s spring) on the nearest level, possibly several away. Levels **1 (uncropped, aspect ratio kept), 3, 5, 15, 30**. At 15 columns: cached thumbnails, fetched at rest; at 30: placeholders and memory cache only, so the Pi isn't flooded. Maths unit-tested in `GridGeometry`. **To re-check by hand.** |
| 2026-10-25 | M1 re-check 3: pinch | Multi-level works. Fixed: too sensitive, and black borders when the grid slid sideways to follow the anchor tile. Now the grid scales about the screen's horizontal centre and follows the fingers only vertically, clamped so content always covers the screen. Centred odd column counts line up, so tiles swap in place, and the old level blurs out (low-res snapshot fade). Sensitivity: 6 % dead zone, one-sided level hysteresis (5 %), and release projection only above 1.5 scale/s. Hard stops at 1 and 30 columns with a light haptic. Settling on bigger tiles grows the dense grid first, then swaps, so the grid never shrinks below the screen. **To re-check by hand.** |
| 2026-10-28 | Cloud provider layer | The app (PhotosAppUI, MediaCache) depends only on `CloudCore` protocols; Immich is `ImmichCloud`, chosen in the app target. Another server needs a new provider only. |
| 2026-10-28 | Sync bug: iCloud identities | The official app stores `mobile-app` metadata under `iCloudId`; we read `cloudId`, so all were empty. Fixed, and the server was asked once to resend `AssetMetadataV1`: 12,512 of 12,512 now have an iCloud identity. |
| 2026-10-28 | **D5 checksum check on the phone** | ✅ 122 phone items, all identified (114 from the official app's upload records by iCloud identity + capture/edit time, 8 hashed). Re-hashing 96 of the 114 gave **96/96 identical checksums** (18 skipped: originals only in iCloud). Run with Settings › This iPhone › Check Checksums, or launch argument `-VerifyChecksums`. |
| 2026-10-28 | Merged timeline, 25,000 server + 13,000 phone | 109 ms on the dev Mac (`mergesALargeLibraryQuickly`). |
| 2026-10-28 | M5 upload format against the real server | ✅ Test Upload (Creates Nothing): PASS (the server parsed the full upload and recognised the duplicate). |
| 2026-10-28 | M5 first real backup | ✅ You turned backup on: the 8 phone-only items uploaded and appear in the Immich app. |
| 2026-10-29 | Second phone | ✅ The second iPhone (iPhone17,2) paired, registered in the Personal Team profile (both phones; expires 25 Oct 2027) and running the Release build. Reinstall with `Scripts/reinstall.sh 00008140-001A7D4921D2801C`. Her library will be backed up by this app only, without the official app. |
| 2026-10-29 | Backup crash on a 3.7 GB video (the second phone) | ❌→✅ The app was killed (signal 9, no report) about 10 s after every launch. Cause: reading the exported file in a loop kept every 1 MB chunk alive until the end, so memory grew to the size of the video. Fixed: chunks are released one by one; uploads are built in one pass (PhotoKit stream → upload body + SHA-1, no separate export copy, so half the disk space); and a crash marker means a file that stops the app three times is skipped with a message instead of crash-looping. After the fix the app stays up and the 3.7 GB video uploads. |

