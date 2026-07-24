# YourPipe

YouTube client for OpenHarmony / HarmonyOS. Plays YouTube content through a native **MPV** pipeline.

> Unofficial client. Not affiliated with YouTube or Google.

## Modules

| Module | Role |
|--------|------|
| `entry` | UI shell, ArkUI pages, preferences |
| `mediaservice` | Playback engine, AV session, local range-proxy |
| `youtube_core` | YouTube extraction, cipher, HLS, auth |
| `libmdk_napi` | NAPI bridge to MPV (+ vendored FFmpeg / libmpv) |

## Requirements

- DevEco Studio / HarmonyOS SDK (target **6.1.0(23)**)
- Device or emulator (phone / tablet / 2in1 / tv / car)

## Build

1. Clone this repository.
2. Configure **signing** in DevEco (Project Structure → Signing Configs).  
   Public tree ships with empty `signingConfigs` — never commit real keystore paths or passwords.
3. Optional: if you use AppGallery / AGC services, download `agconnect-services.json` from AppGallery Connect and place it at  
   `entry/src/main/resources/rawfile/agconnect-services.json`  
   (this path is git-ignored).
4. Sync ohpm dependencies, then build/run from DevEco or your CLI workflow.

## Auth notes

- Cookie login and device QR (OAuth) are supported for personalization / restricted content.
- Device OAuth POC constants may mirror publicly documented SmartTube-style client values; treat them as community POC, not YourPipe-owned credentials.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Portions and ideas reference open projects including NewPipe, NewPipe Extractor, PipePipe, MPV, and related work. Respect their licenses when redistributing.
