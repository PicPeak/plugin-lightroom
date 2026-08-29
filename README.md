<div align="center">

# 📸 PicPeak for Lightroom Classic

**Round-trip your client's proofing selections between PicPeak and Lightroom Classic.**

[![Lightroom Classic](https://img.shields.io/badge/Lightroom-Classic-31A8FF?logo=adobelightroomclassic&logoColor=white)](https://www.adobe.com/products/photoshop-lightroom-classic.html)
[![PicPeak](https://img.shields.io/badge/PicPeak-self--hosted-2E7D5B)](https://www.picpeak.app)

[PicPeak](https://www.picpeak.app) · [Documentation](https://docs.picpeak.app) · [Round-trip guide](https://docs.picpeak.app/guides/lightroom-roundtrip) · [Issues](https://github.com/PicPeak/plugin-lightroom/issues)

</div>

---

Upload galleries to a self-hosted [PicPeak](https://github.com/PicPeak/picpeak) server from Lightroom Classic — then pull the colour labels and star ratings your client set while proofing back onto the matching RAW files, edit, and publish the finished renders straight over their proofs.

> [!IMPORTANT]
> **Importing selections needs PicPeak with `GET /api/v1/events/:id/photos`.** Export and publish work against older servers; the importer will not.

## Contents

- [Install](#-install)
- [Connect](#-connect)
- [The round-trip](#-the-round-trip)
- [Sending edits back](#-sending-edits-back)
- [Multi-camera shoots](#-multi-camera-shoots)
- [Multiple servers](#-multiple-servers)
- [Security](#-security)
- [Troubleshooting](#-troubleshooting)
- [Credit](#-credit)

## 🚀 Install

**There is no installer.** A Lightroom plugin is a folder, and there are two ways to add one:

```bash
git clone https://github.com/PicPeak/plugin-lightroom.git
```

**Plug-in Manager** — `File → Plug-in Manager → Add`, point it at the `picpeak-plugin.lrplugin` folder. Keeps the plugin wherever you cloned it.

**Auto-load** — copy `picpeak-plugin.lrplugin` into Lightroom's Modules folder and it loads at every start, no Plug-in Manager step:

| | |
|---|---|
| macOS | `~/Library/Application Support/Adobe/Lightroom/Modules/` |
| Windows | `%APPDATA%\Adobe\Lightroom\Modules\` |

No build step — the plugin runs from source. After changing files, use **Reload Plug-in** in the Plug-in Manager rather than restarting Lightroom.

### Requirements

- Lightroom Classic (Lua SDK 3.0+)
- A PicPeak server with the v1 API enabled
- An account allowed to create API tokens (`settings.integrations`)

## 🔌 Connect

Two entries appear under **Library → Plug-in Extras**:

| | |
|---|---|
| **PicPeak Overview** | which server, which account, and the actions |
| **PicPeak Importer** | straight to the importer |

Open the overview, choose **Config**, enter your server URL and click **Sign in…**. The plugin exchanges your credentials once for an API token scoped to this machine, stores only the token, and never keeps your password. Revoke it any time in PicPeak under **Settings → API Tokens**.

If your server enforces SSO or has reCAPTCHA enabled, password sign-in cannot work from a plugin — open **Advanced** and paste a token created with the `admin` scope.

> [!NOTE]
> **There is no keyboard shortcut, and none is possible.** Lightroom's SDK cannot bind one, and a macOS App Shortcut cannot reach these items either — Lightroom builds the Plug-in Extras entries only when the menu is opened, after macOS has applied key equivalents at launch.

## 🔁 The round-trip

1. Upload the unedited camera JPGs (`IMG_1234.JPG`) to a PicPeak event.
2. Your client marks colour labels and stars while proofing. You can add your own marks in the admin view — they stay separate.
3. **PicPeak Importer** → pick the event and the folder holding your RAWs → choose everything, or only what was marked.
4. Matching RAWs are added to your catalog with the colours and ratings already applied, and collected into a collection.

Step 2 is optional. Importing *all* photos is a first-class choice, not a fallback.

> Colour labels are **off by default** on new events. Turn them on in the event's feedback settings, or globally with `event_default_allow_color_labels`.

### Merging, not overwriting

Re-running an import — or importing onto photos you already triaged in Lightroom — must not silently destroy your work. Choose what happens when a photo already carries a **different** value:

| Mode | Behaviour |
|---|---|
| **Fill empty only** *(default)* | Never touch a photo that already has a value |
| **PicPeak wins** | Overwrite unconditionally |
| **Lightroom wins** | Write only where Lightroom is empty |
| **Highest priority wins** | Green → yellow → red → blue → purple; higher star count wins |

Green ranks first because in proofing it means *first choice* — the pick that has to survive a disagreement. Every run reports its conflict count, so a lossy setting is never silent, and a custom Lightroom label the plugin doesn't recognise is ranked lowest rather than destroyed.

## 📤 Sending edits back

Edit as usual, rename however you like, then **File → Export → PicPeak Exporter** with **Existing event** set to the event the photos came from.

Each render **replaces its proof**: the photo keeps its id, the client's ratings and colour labels, its comments, and its position in the gallery. The share link stays valid.

Renaming is safe because the import stamps the PicPeak photo id onto the catalog photo — it is the id, not the filename, that carries the edit home.

> [!WARNING]
> Replacement only happens when the export target is **the same event** the photos were imported from. Export to a different event and every photo uploads as a new copy there.

## 📷 Multi-camera shoots

Two bodies both produce `IMG_1234.JPG`. Rename on ingest, **before uploading**, so the camera index becomes part of the number:

```
cam11234.jpg      ← camera 1, frame 1234
cam21234.jpg      ← camera 2, frame 1234
```

Matching reads the **longest** trailing run of digits, so `11234` and `21234` stay distinct where a bare `1234` would collide. No separator needed — swallowing the index into the number is what makes the run unique. Keep the index single-digit (`cam1`–`cam9`).

If you use the optional *"Also match by trailing file number"* fallback, your delivery name has to keep the **whole** run — `Smith_Wedding_11234.jpg`, not `Smith_Wedding_1234.jpg`. Files that do share a number are skipped and reported, never guessed at.

## 🖧 Multiple servers

Sign in to a second PicPeak and the overview grows a **Server** picker — a studio server and a client's, or production and a local instance. Each server keeps its own token in the keychain, so switching is just choosing it.

## 🔒 Security

- Your password is used **once**, exchanged for an API token, and never stored.
- The token lives in the **OS keychain**, not Lightroom's preferences file.
- Tokens are minted with a **one-year expiry** by default and are revocable per machine in **Settings → API Tokens**.
- Signing in over plain `http://` warns before you type your password. Loopback is exempt.

The token carries the `admin` scope, because minting and revoking tokens requires it.

## 🩹 Troubleshooting

| Symptom | Cause |
|---|---|
| **Nothing matched** | RAW stems must match the uploaded names — `IMG_1234.CR3` matches a proof uploaded as `IMG_1234.JPG`. If the RAWs were renamed after upload, enable the number fallback. |
| **"N local files share the number"** | Two RAWs have the same trailing digits — use the camera-prefix scheme, or match on full filenames. |
| **Labels didn't change** | The default conflict mode never overwrites. Switch to *PicPeak wins* or *Highest priority wins*. |
| **No colours at all** | Colour labels are probably disabled on that event. |
| **RAW upload fails** | The **server** needs `exiftool` to read RAW files (`apt-get install libimage-exiftool-perl`). Exporting JPEG avoids it entirely. |

Enable logging in **Plug-in Manager → PicPeak → Logging**, reproduce, then use **Show log file**.

## 🙏 Credit

Initial implementation by [@bmachek](https://github.com/bmachek) ([lrc-picpeak](https://github.com/bmachek/lrc-picpeak)).

---

<p align="center">
  <a href="https://www.picpeak.app">PicPeak</a> ·
  <a href="https://docs.picpeak.app">Documentation</a> ·
  <a href="https://github.com/PicPeak/plugin-lightroom/issues">Support</a>
</p>
