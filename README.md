<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="YourPipe" height="96" />

# YourPipe

**YouTube client for OpenHarmony / HarmonyOS**

[![Version](https://img.shields.io/badge/version-0.5.6-blue?style=flat-square)](AppScope/app.json5)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0(23)-black?style=flat-square)](https://developer.huawei.com/consumer/en/harmonyos/)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)

> Unofficial client. **Not affiliated with YouTube or Google.**

</div>

---

## Overview

YourPipe is a YouTube client for **OpenHarmony / HarmonyOS**. It extracts streams in-app and plays them through a native **MPV** pipeline (vendored libmpv + FFmpeg), not a WebView player.

| | |
|---|---|
| **Package** | `com.talon.yourpipe` |
| **Version** | `0.5.8` |
| **Target SDK** | `6.1.0(23)` · HarmonyOS · stage model |
| **Devices** | phone · tablet · 2in1 · tv · car |

Product VOD typically goes through a **SABR** dual-track local proxy into MPV (mweb player client). Playback is **MPV only**: the `libmpv_napi` module is a NAPI bridge over a vendored `libmpv.so`, originally derived from [libmdk-napi](https://github.com/wang-bin/libmdk-napi) (historical `mdk` names exist only in old commits).

---

## Features

- Home feed, search, channels, and playlists
- Subscriptions and favorites
- Native MPV playback (quality / codec options, PiP where supported)
- Background audio via continuous task + AV session
- Offline downloads into the local library
- Cookie (WebView) login and device QR (OAuth) login
- HTTP proxy settings
- Light / dark / system appearance and multiple UI locales
- Local library: downloads, watch history, playlists

Main tabs: **Home · Subscriptions · Favorites · Local**. Search and Options open as separate pages/sheets.

---

## Modules

```text
entry  →  mediaservice  →  youtube_core
  │              └────→  @yourpipe/libmpv-napi  (MPV bridge)
  └──────────→  youtube_core
```

| Module | Role |
|--------|------|
| `entry` | UI, pages, preferences, auth, PoToken WebView |
| `mediaservice` | Playback engine, AV session, local media proxy, offline download |
| `youtube_core` | YouTube extraction, cipher, HLS/SABR session, auth storage |
| `libmpv_napi` | NAPI bridge to MPV (+ vendored FFmpeg / libmpv on arm64) |

`arm64-v8a` is the product playback ABI. `x86_64` builds use a player stub (UI only).

---

## Requirements

- [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) with HarmonyOS SDK **6.1.0(23)**
- Device or emulator (phone / tablet / 2in1 / tv / car)
- Real video playback needs an **arm64-v8a** device

---

## Getting started

1. Clone the repository:

   ```bash
   git clone https://github.com/Ember5843/YourPipe.git
   cd YourPipe
   ```

2. Open the project root in DevEco Studio and sync ohpm dependencies.

3. Configure **signing** under **File → Project Structure → Signing Configs**.  
   Public `build-profile.json5` ships with empty `signingConfigs` — **never commit** keystores, passwords, profiles, or certificates.

4. Optional: if you use AppGallery Connect, put the AGC services config under  
   `entry/src/main/resources/rawfile/` (that file is git-ignored).

5. Select a device and **Run** from DevEco.

---

## Authentication

- **Cookie login** (WebView) and **device QR** (OAuth) are supported for personalization and restricted content.
- Device OAuth constants may mirror publicly documented community client values; treat them as community POC material, not YourPipe-owned credentials.

---

## References

Behavior and naming draw on these open projects (not alternate runtimes inside this app):

| Project | Role |
|---------|------|
| [NewPipe](https://github.com/TeamNewPipe/NewPipe) | Client UX reference |
| [NewPipe Extractor](https://github.com/TeamNewPipe/NewPipeExtractor) | Extraction / stream models |
| [PipePipe](https://github.com/InfinityLoop1308/PipePipe) | Player-client / extractor compatibility |
| [libmdk-napi](https://github.com/wang-bin/libmdk-napi) | Historical origin of the NAPI bridge structure and naming |
| [MPV](https://github.com/mpv-player/mpv) | Playback core (libmpv) |

---

## License

GPL-3.0. See [LICENSE](LICENSE).

Portions and ideas reference NewPipe, NewPipe Extractor, PipePipe, MPV, and related work. Respect their licenses when redistributing.
