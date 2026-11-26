<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="YourPipe" height="96" />

# YourPipe

**A Native YouTube Client for OpenHarmony / HarmonyOS**

[![Version](https://img.shields.io/badge/version-0.7.2-blue?style=flat-square)](AppScope/app.json5)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0(23)-black?style=flat-square)](https://developer.huawei.com/consumer/en/harmonyos/)
[![Target SDK](https://img.shields.io/badge/Target%20SDK-26.0.0-teal?style=flat-square)](build-profile.template.json5)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

> Unofficial third-party client. **Not affiliated with YouTube or Google.**

</div>

---

## Overview

**YourPipe** is a native **ArkTS / ArkUI + C++20** YouTube client built for **HarmonyOS (Next / Stage Model)**. Instead of wrapping YouTube in a WebView player, YourPipe extracts streams in-app (`youtube_core`), executes YouTube's player signature/n-parameter cipher on-device via Ark Runtime JSVM (`libyourpipe_cipher.so`), and renders video natively through a vendored **MPV (`libmpv.so.2` + Vulkan `gpu-next` + `ohcodec-copy` hardware decoding + FFmpeg n8.0)** pipeline.

| Property | Value |
|---|---|
| **Bundle Name** | `com.talon.yourpipe` |
| **Version** | `0.7.2` (`versionCode: 1000035`) |
| **SDK / Model** | `compatibleSdkVersion: 6.1.0(23)` · `targetSdkVersion: 26.0.0` · Stage Model |
| **Native Compiler** | `BiSheng` (`arm64-v8a` product ABI; `x86_64` UI/stub only) |
| **Form Factors** | `phone` · `tablet` · `2in1` · `tv` · `car` |
| **UI Locales (13 + System)** | `zh-Hans`, `zh-HK`, `zh-TW`, `en`, `ja`, `ko`, `de`, `fr`, `es`, `pt-BR`, `it`, `ru`, `ar` |

---

## Features

### Extraction, Playback & Streaming Engine
- **Multi-Client Extraction & Switching**:
  - **Guest VOD**: defaults to `visionos` direct DASH streams fed into MPV through C++20 `ypstream://` (`DirectRangeStream` over `librcp_c`, with `LocalMediaProxy` loopback fallback), plus `mweb` SABR option and Android Reel fallback for Shorts.
  - **Signed-in Playback**: defaults to `mweb` dual-track **SABR / UMP** local proxy (`SabrDashProxy` with MP4 `sidx` / WebM EBML Cues indexing), or `tv_downgraded` direct-URL playback.
- **On-Device JSVM Cipher & PoToken**:
  - Runs YouTube's player JS decipher (`n` and `sig`) locally inside HarmonyOS JSVM (`libyourpipe_cipher.so` + embedded EJS bundle + `tv-player-ias.js` fallback), respects HarmonyOS **Secure Shield** mode, and falls back to the PipePipe remote cipher decoder when needed.
  - Hidden ArkWeb runtime (`SabrWebViewPoTokenProvider`) mints BotGuard `PoToken`s with session-pinned `visitorData`.
- **Native MPV Playback (`vo=gpu-next`)**:
  - Vulkan hardware rendering with true HDR (`target-colorspace-hint=yes`), `ohcodec-copy` hardware decode whitelist probing, `lavfi` audio loudness normalization (`acompressor` + `alimiter`), A/V sync delay tuning (`-1000..+1000 ms`), and real-time stream stats chart (`StatsBarGraph`).
  - Playback rate `0.25x–3.0x`, Shorts single-loop, Picture-in-Picture (PiP), continuous background audio + `AVSession` system media controls, sleep timer, and cross-device HarmonyOS **playback handoff** (`PlaybackContinuationService`).

### Subtitles, Translation & Live Chat
- **Dual-Track Bilingual & `json3` Subtitles**:
  - App-side ArkUI subtitle overlay preferring `fmt=json3` (eliminates rolling ASR duplication) with `fmt=vtt` fallback, P0 server `tlang` auto-translated tracks, secondary subtitle track support, timing offset (`-5000..+5000 ms`), customizable scale/margin/colors/outline/background, and live preview.
- **Multi-Provider Comment & Description Translation (9 Engines)**:
  - `gtx` (Google Web), Google Cloud Translation API, Microsoft Translator (`Azure`), MyMemory, Lingva, LibreTranslate, DeepL, OpenAI-compatible LLM, and custom HTTP template with JSON path extraction and clear error reporting on failure.
- **Read-Only Live Chat**:
  - Real-time live chat polling and VOD chat replay synchronized with playback timestamps (supports Super Chat & membership badges).

### Gestures & Player UI
- **Frosted Glass Controls & 4-in-1 Seekbar**:
  - Chapter markers + SponsorBlock segment highlights + YouTube "Most Replayed" heatmap curve + storyboard frame preview.
- **Customizable Gestures**:
  - 3 presets (`Enhanced`, `YouTube`, `Bilibili`), independent left/right vertical swipe for brightness and volume with centered frosted HUD, horizontal swipe seek, double-tap seek/play-pause, and configurable hold-to-speed (`1.25x–3.0x`).

### Dual-Rail Authentication & Privacy Boundaries
- **Independent Data vs Playback Auth Toggles**:
  - **Web Cookie Rail**: Google Sign-In WebView + manual Cookie header / EditThisCookie JSON import for subscriptions, history, playlists, and `SAPISIDHASH`-authenticated `mweb` SABR playback.
  - **TV OAuth Rail (SmartTube-style)**: Scrapes live YouTube TV client credentials & `visitorData`, acquires device-code / QR login (`yt.be/activate`), resolves Brand Account `pageIdToken` (`X-Goog-Pageid`), and isolates `Bearer` auth on `tv_downgraded` to unlock **18+ age-restricted** videos cleanly.
  - **Granular Controls**: Master incognito mode plus separate switches for attaching login credentials to **User Data** vs **Playback**, with in-app boundary guidance and direct settings recovery actions on auth/age errors.

### Offline Downloads & Subtitle Muxing
- **Multi-Mode Downloads**: Progressive, DASH (`video + audio`), SABR/UMP, HLS, and **Subtitle-only (`.srt`)**.
- **Chunked Resumable Transfers**: 10 MiB range chunks with pause/resume/retry from disk partial bytes, concurrency limit (1–4), and stall/timeout watchdogs.
- **Single-File Video + Subtitle Muxing**:
  - Zero-re-encode FFmpeg remuxing (`muxMedia` in `libmpv_napi`) supports losslessly **embedding `.srt` subtitle tracks into a single `.mkv` file** across Progressive, DASH, and SABR downloads—no loose sidecar `.srt` file needed when saved as video.
  - Sandbox download management with orphan recovery, built-in local media queue (`.mp4`, `.mkv`, `.webm`, `.mov`, `.ts`, `.flv`, `.avi`, `.m4v`), and one-tap export to user Downloads.

### Experimental Enhancements & App Utilities
- **Experimental Features (off by default)**:
  - **SponsorBlock** (9 categories, SHA-256 privacy prefix lookup, toast + one-tap undo, background/PiP auto-skip, channel allowlist)
  - **DeArrow** (crowdsourced non-clickbait titles & thumbnail frames)
  - **AiSList** (`Override92/AiSList` channel warning/hide badges)
  - **Replay Heatmap & Jump Ahead**
- **ReturnYouTubeDislike**, **Home Long-form vs Shorts toggle**, **YouTube / YouTube Music search filters**, **1000-entry Watch History** (atomic storage + account sync), **HTTP/Auth & SOCKS5 Proxy**, **9 Theme Colors + Dark/Light/System**, **JSON Backup & Restore**, **In-App Update Checker** (`GitHub releases.atom` + `version.json`), and **Log Viewer / Exporter**.

---

## Architecture & Modules

```text
entry  ──▶  mediaservice  ──▶  youtube_core  (C++ libyourpipe_cipher.so)
  │              └──────────▶  @yourpipe/libmpv-napi  (C++ libmpv_napi.so + libmpv.so.2 + FFmpeg n8.0)
  ├──────▶  youtube_core
  └──────▶  asrengine  (HAR retained; P3 on-device ASR currently disabled in UI/build wiring)
```

| Module | Package / Role | Notes |
|---|---|---|
| `entry` | Main UI, pages, downloads, auth UI, settings, backup, WebView PoToken | Depends on `mediaservice`, `youtube_core`, `asrengine`, and OHPM `sherpa_onnx@1.13.3` |
| `mediaservice` | `AvPlayerController`, `MpvPlaybackEngine`, `AVSession`, SABR offline/proxy, VTT/JSON3 subtitle parser | Pure playback/media service layer |
| `youtube_core` | InnerTube APIs, extractors, `PlayabilityChecker`, SABR protocol, JSVM cipher NAPI, auth session | Platform-agnostic YouTube core |
| `libmpv_napi` | C++20 NAPI bridge (`ypstream://`, `hwdec_probe`, `muxAudioVideo` / `muxMedia`) + vendored `arm64-v8a` `libmpv.so.2` & FFmpeg static libs | `x86_64` compiles `player_napi_stub.cpp` (UI only) |
| `asrengine` | Native ASR audio decode HAR (`libasr_engine.so`) | Present in build profile; on-device ASR is currently disabled (`[DISABLED]`) |

---

## Usage Guide

1. **Network Proxy (if required by your region)**:
   - Open **Settings → Network & Proxy** to configure **HTTP** (optional username/password) or **SOCKS5** proxy. Tap **Test Connection** to verify reachability across Netstack, RCP, ArkWeb, and MPV.
2. **Account & Playback Auth Strategy**:
   - Open **Settings → Data & Account**:
     - **TV QR Login (OAuth)** is recommended if you mainly want **18+ age-restricted playback** without managing browser cookies (routes to `tv_downgraded` + Bearer).
     - **Web Login (Cookie / JSON Import)** enables personalized Home feeds, subscriptions, playlists, Watch History sync, and `mweb` SABR playback.
     - Note: When **signed in** without YouTube Premium, `mweb` SABR enforces ~5s pre-roll ad wait latency (YourPipe displays a live countdown tip); when **guest** (`visionos`), startup is instant though certain IPs may hit risk-control checks. You can toggle **Use Login for User Data** and **Use Login for Playback** independently at any time.
3. **Subtitles & Translation**:
   - Tap the **CC** button on the player overlay to pick primary/secondary subtitles or server-translated tracks; configure styling and timing offset under **Settings → Subtitles**.
   - Configure comment/description translation under **Settings → Language & Region → Translation Service**.
4. **Downloading Videos & Subtitles**:
   - Tap **Download** on the player details panel or long-press any video card:
     - **Step 1 (Mode)**: Choose `Progressive`, `DASH`, `SABR`, `HLS`, or **`Subtitle only (.srt)`**.
     - **Step 2 (Quality/Tracks)**: Select video resolution/codec and audio language/quality.
     - **Step 3 (Subtitles, optional)**: Choose a subtitle track and keep **Embed into video (.mkv)** enabled to mux video, audio, and subtitle losslessly into a **single `.mkv` file**. *(Note: Due to size and without `libavfilter`/`libass`/video encoders in the vendored FFmpeg build, pixel burn-in/hardcoding is not supported; embedded MKV subtitles render directly inside YourPipe's MPV player as well as VLC/PotPlayer/Kodi. Turn off embedding or select "Subtitle only" if you prefer an external `.srt` file.)*
   - Visit **Local → Downloads** to pause/resume, play in-app, or **Export** completed files to system storage.

---

## Building & Packaging from Source

### Excluded Sensitive / Machine-Local Files
The pushed Git repository intentionally **excludes** signing material and machine-local secrets (enforced by [`.gitignore`](.gitignore) and `.githooks/pre-commit`):

| Git-Ignored File / Folder | Purpose |
|---|---|
| `build-profile.json5` | Machine-local root build profile containing `signingConfigs` |
| `signing-backup/`, `keys/`, `*.p12`, `*.p7b`, `*.cer`, `*.jks`, `*.keystore` | HarmonyOS signing certificates, profiles, and keystores |
| `**/AGC services config` (`entry/src/main/resources/rawfile/`) | Optional AppGallery Connect configuration (git-ignored) |
| `**/local.properties` | Local SDK path overrides |

> Prebuilt `arm64-v8a` native libraries (`libmpv.so.2` and `ffmpeg-sdk/lib/arm64-v8a/*.a`) **are tracked in Git**, so no Linux cross-compile is required just to build the HAP.

### Prerequisites
- **[DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/)** with **HarmonyOS SDK `6.1.0(23)` / Target SDK `26.0.0`** (with `ohpm`, `hvigorw`, `hdc`, and bundled `jbr` / JDK).
- If building from CLI on Windows and `PackageHap` fails with `spawn java ENOENT`, set `JAVA_HOME` to DevEco Studio's `jbr` directory and add `%JAVA_HOME%\bin` to `PATH`.
- Real video playback requires an **`arm64-v8a`** HarmonyOS device (the `x86_64` emulator uses a UI-only player stub).

### Step-by-Step Build & Packaging

1. **Clone the repository**:
   ```bash
   git clone https://github.com/Ember5843/YourPipe.git
   cd YourPipe
   ```

2. **Create your local `build-profile.json5` from the committed template**:
   - **macOS / Linux / Git Bash**:
     ```bash
     cp build-profile.template.json5 build-profile.json5
     ```
   - **Windows PowerShell**:
     ```powershell
     Copy-Item build-profile.template.json5 build-profile.json5
     ```

3. **Install OHPM dependencies** (resolves `sherpa_onnx@1.13.3` and local module HARs):
   ```bash
   ohpm install
   ```
   *(Or open the project root in DevEco Studio and let Sync complete.)*

4. **Configure Signing** *(required before packaging a signed HAP or installing to a device)*:
   - Open the project in **DevEco Studio** → **File → Project Structure → Signing Configs**.
   - Sign in with a Huawei Developer account for **Automatically generate signature** (debug), or supply your own `.p12`, `.p7b`, and `.cer` release credentials. DevEco Studio writes those entries into your local git-ignored `build-profile.json5`.
   - *(Optional)* If you use AppGallery Connect services, place your own AGC services config file under `entry/src/main/resources/rawfile/`.

5. **Build & Package HAP**:
   - **In DevEco Studio**: Select target device (`arm64-v8a`), click **Run** (Debug), or **Build → Build Hap(s)/APP(s) → Build Hap(s)** (Debug/Release).
   - **Via DevEco CLI (`devecocli`)**:
     ```bash
     # Full product Debug build (compiles youtube_core, mediaservice, asrengine, libmpv_napi, entry)
     devecocli build

     # Release HAP build
     devecocli build --product default --build-mode release

     # Install and launch on connected HarmonyOS device
     devecocli run --skip-build
     ```
   - **Via `hvigorw` directly**:
     ```bash
     hvigorw assembleHap --mode module -p product=default -p buildMode=debug
     # or -p buildMode=release
     ```
   Output HAPs are generated under `entry/build/default/outputs/default/` (`entry-default-signed.hap` / `entry-default-unsigned.hap`).

6. **Run Regression Tests (Optional)**:
   See [`tools/tests/README.md`](tools/tests/README.md):
   ```bash
   node tools/tests/interaction-regressions.cjs --typescript "<DevEco>/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js"
   ```

---

## Credits & References

YourPipe references design patterns, extractors, and open-source media projects including:

| Project / Service | Role |
|---|---|
| [NewPipe](https://github.com/TeamNewPipe/NewPipe) & [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor) | Client UX & YouTube extraction architecture |
| [PipePipe](https://github.com/InfinityLoop1308/PipePipe) | Player-client behaviors, SABR / PoToken & cipher API compatibility |
| [SmartTube](https://github.com/yuliskov/SmartTube) | TV OAuth authentication & 18+ age-gate compatibility |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Extraction research & EJS player cipher patterns |
| [MPV](https://github.com/mpv-player/mpv) & [FFmpeg](https://ffmpeg.org/) | Native playback core (`libmpv.so.2`) & lossless muxing (`libavformat`) |
| [libmdk-napi](https://github.com/wang-bin/libmdk-napi) | Historical origin of the `libmpv_napi` bridge structure |
| [iPlay](https://github.com/saltpi/iPlay) · [FinVideo](https://github.com/OHPG/FinVideo) · [ClashBox](https://github.com/xiaobaigroup/ClashBox) · [tpc_c_cplusplus](https://gitcode.com/CPF-ApplicationTPC/tpc_c_cplusplus) · [VLC](https://www.videolan.org/) | HarmonyOS native playback, proxy, and C/C++ port references |
| [SponsorBlock](https://sponsor.ajay.app/) · [DeArrow](https://dearrow.ajay.app/) · [ReturnYouTubeDislike](https://returnyoutubedislike.com/) · [AiSList](https://github.com/Override92/AiSList) | Optional community data enhancements |

---

## License

Licensed under **GPL-3.0**. See [LICENSE](LICENSE) for details.  
Portions and architectural ideas derive from NewPipe, NewPipeExtractor, PipePipe, SmartTube, yt-dlp, MPV, and related open-source works—please comply with their respective licenses when redistributing.
