# CLAUDE.md

A Lightroom Classic plugin (Lua) that uploads photos to a self-hosted PicPeak gallery server. It provides three workflows: **Export** (upload selected photos to a PicPeak event/gallery), **Publish** (maintain synced collections mapped to PicPeak events), and **Import selections** (bring a client's proofing colour labels and star ratings back onto the matching RAW files — the round-trip, PicPeak/picpeak#745).

## What is PicPeak?

PicPeak (https://github.com/the-luap/picpeak) is a self-hosted photo sharing platform for photographers and events. It organizes photos into time-limited, optionally password-protected gallery **events** (weddings, birthdays, corporate events, etc.).

## Development & Build

No build step — the plugin runs directly from `picpeak-plugin.lrplugin/` inside Lightroom Classic. Install via Lightroom's Plugin Manager pointing at that directory.

## Architecture

### Entry Points

- **`Info.lua`** — Plugin manifest; declares export/publish providers, metadata provider, SDK version.
- **`Init.lua`** — Runs at load; imports Lightroom SDK globals into `_G` and initializes preferences (`url`, `apiToken`, `logging`).

### Core Modules

- **`PicPeakAPI.lua`** — REST client for PicPeak v1 API (`/api/v1`). Auth: `Authorization: Bearer pp_live_xxx`. Key methods: `getEvents()`, `createEvent(params)`, `uploadPhoto(eventId, filePath, fileName, replacesPhotoId)`, `getEventPhotos(eventId, filters)`, `checkConnectivity()`, `getEventShareUrl(eventId)`. Sign-in helpers (`login`, `submitMfa`, `createApiToken`, `revokeApiToken`) target `/api/auth` and `/api/admin`, NOT `/api/v1` — they deliberately bypass `API_BASE_PATH`.
- **`ExportTask.lua`** — Export workflow: resolve event → iterate renditions → upload each photo → write metadata → show share link.
- **`PublishTask.lua`** — Publish workflow: map collection to event (create if needed) → incremental uploads → collection management callbacks.

### PicPeak API Summary (v1)

Base path: `/api/v1`. Token must have `write` + `admin` scopes.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/events?limit=100` | List events (paginated, max 100) |
| POST | `/events` | Create event (needs event_name, event_type) |
| GET | `/events/:id` | Get event details |
| POST | `/events/:id/photos` | Upload photo (multipart `photo` field; optional `replaces_photo_id`) |
| GET | `/events/:id/photos` | List photos with proofing marks (filters: `marked_only`, `mark_source`, `color_labels`, `my_color_labels`, `min_rating`, `my_min_rating`) |
| GET | `/events/:id/share-link` | Get share URL |

**Limitations of v1 API**: No delete photo, no delete event, no rename event endpoints. The publish plugin warns users when these operations are attempted. Replacing a photo IS supported (`replaces_photo_id`), which is why re-publish updates in place rather than skipping.

### Event types

`wedding`, `birthday`, `corporate`, `other`, `family`

### UI Modules

- **`SharedDialogSections.lua`** — Server connection section (URL + token + test button). Also exports `EVENT_TYPES` list.
- **`ExportDialogSections.lua`** / **`PublishDialogSections.lua`** — Service-specific dialog sections.

### Supporting Modules

- **`MetadataTask.lua`** / **`MetadataProvider.lua`** — Store `picpeakPhotoId`, `picpeakEventId` and `picpeakSourceFilename` on photos via plugin metadata (schemaVersion 2). **`picpeakPhotoId` is load-bearing**: it is what lets a renamed render find its way back to the right PicPeak photo, so never clear it on export.
- **`PicPeakMenuItem.lua`** / **`PicPeakOverview.lua`** — **PicPeak Overview** in Library > Plug-in Extras, and the landing page it opens: connected server, account, last RAW folder, a server picker when more than one is known, and the actions.
- **`PicPeakImportMenuItem.lua`** — **PicPeak Importer**, the second menu entry; opens the importer directly, skipping the overview.
- **`ServerStore.lua`** — the known-server list, JSON-encoded in prefs. The ACTIVE server stays in the scalar `prefs.url` so a corrupt list can never disconnect an install. Tokens are not here — `TokenStore` keys the keychain by server URL, so switching server switches credential.

  **No keyboard shortcut is possible.** Lightroom has no API to bind one, and a macOS App Shortcut cannot reach these items: Lightroom builds the Plug-in Extras entries lazily, after macOS has applied key equivalents at launch, so the binding lands on the plugin-name header (which is disabled) and never on the item. Verified against a real install — do not re-litigate this without testing it in the menu.

  The menu title must therefore also differ from `LrPluginName`, or the submenu shows two identical rows.

  Dispatch between the importer and the connection screen goes through `presentModalDialog`'s return value — **never nest modal dialogs**.
- **`ConnectionDialog.lua`** — the connection controls as a standalone modal, sharing `SharedDialogSections.getConnectionRows` with the Export dialog and Plug-in Manager sections. Reached from the importer's "Connection…" button, which returns rather than opening it inline.
- **`TokenStore.lua`** — the API token lives in the OS keychain (`LrPasswords`), NOT `LrPrefs`. Migrates a legacy plaintext token on first read. Keyed by server URL.
- **`ImportSelectionsDialog.lua`** / **`ImportSelectionsTask.lua`** — the round-trip import. The task resolves PicPeak photos to local files by `source_filename` stem, then optionally by trailing digit run.
- **`ColorLabelMerge.lua`** — merge rules. `COLOR_PRIORITY` mirrors `COLOR_LABEL_PRIORITY` in the picpeak backend (`backend/src/constants/colorLabels.js`) — update both together.
- **`LoginDialog.lua`** — credentials-to-token exchange, including the TOTP step.
- **`util.lua`** — Shared helpers: `validateExportContextAndConnect`, `buildSimpleUploadProgressTitle`, `reportUploadFailures`, `safeDeleteTempFile`, `getPhotoDeviceId`, `getLogfilePath`, `cutToken`.
- **`ErrorHandler.lua`** — Centralized error dialogs.
- **`JSON.lua`** / **`inspect.lua`** — External libraries (copied from lrc-immich-plugin).

### Filename matching invariants

`util.trailingDigitRun` must stay identical to `trailingDigitRun()` in the
picpeak backend (`backend/src/services/photoReplacementService.js`). It takes the
**longest** trailing digit run, never a fixed last-N slice — multi-camera shoots
disambiguate by prefixing the camera index into the number (`cam11234.jpg` /
`cam21234.jpg`), and a last-4 slice reads `1234` from both bodies.

Ambiguity is always refused, never resolved by guessing: a wrong colour label is
worse than a missing one, because nothing about it looks wrong afterwards.

### Lightroom SDK Patterns

- **Async tasks**: All API calls in `LrTasks.startAsyncTask()`.
- **Property tables**: Dialog state two-way bound via `LrBinding`.
- **Progress scopes**: `LrProgressScope` with `functionContext` (not `configureProgress`) for accurate bars.
- **Error handling**: `LrTasks.pcall()` everywhere (not bare `pcall`).
- **Preferences**: Global settings stored in `LrPrefs.prefsForPlugin()`.

### Publish Collection → Event Mapping

A Lightroom publish collection maps to a single PicPeak event by `remoteId`. When creating a new collection, the user can:
- Create a new event from the collection name (with event type)
- Bind to an existing event

Since PicPeak v1 has no delete/rename endpoints, those operations show informational dialogs and mark photos as handled in Lightroom without touching the server.

@.claude/skills/lrc-plugin-dev.md
