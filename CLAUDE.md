# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development

This is a HarmonyOS (ArkTS/ArkUI) application. Build with Hvigor from the `Application/` directory:

```bash
# Build HAP (debug)
cd Application && hvigorw assembleHap --mode module -p module=entry@default -p product=default

# Build HAP (release)
cd Application && hvigorw assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release

# Run linter
cd Application && hvigorw lintHar

# Run tests (Hypium framework)
cd Application && hvigorw testHap --mode module -p module=entry_test@default
```

Target SDK: HarmonyOS 6.1.0(23). Native compiler: BiSheng.

## Architecture

**Module dependency graph:**
```
entry → mediaservice → youtube_core
     → @sj/ffmpeg         → @mediadevkit/libmdk-napi (native NDK)
```

### youtube_core (no dependencies)
YouTube data extraction library. Stateless except for auth sessions.
- `extractor/YouTubeExtractor.ets` — main entry point for video/stream extraction
- `extractor/clients/` — multiple YouTube client impersonations (iOS, Safari, TvHtml5, WebEmbedded, Android) for stream extraction
- `extractor/cipher/` — signature decipher (YoutubeJavaScriptPlayerManager + PipePipeApiDecoder)
- `extractor/StreamInfo.ets` — stream format/URL extraction from player responses
- `auth/` — cookie-based auth, SAPISID hash, session management
- `network/YouTubeHttpClient.ets` — HTTP layer with cookie jar

### mediaservice (depends on youtube_core + libmdk-napi)
Playback engine and media proxy layer.
- `engine/MpvPlaybackEngine.ets` — MPV-based playback via libmdk-napi
- `engine/NativePlaybackEngine.ets` — HarmonyOS native AVPlayer engine
- `controller/AvPlayerController.ets` — unified playback controller abstraction
- `proxy/LocalProxyServer.ets` — local HTTP proxy for DASH streaming
- `proxy/RangeProxy.ets` — range-request chunking proxy (throttling mitigation)
- `proxy/PlaylistBuilder.ets` — EDL/playlist generation for dual-stream DASH
- `proxy/SidxParser.ets` — SIDX box parsing for segment index
- `state/PlayerStateRelay.ets` — state routing layer between engine and UI
- `state/PlayerStateMachine.ets` — playback state transitions
- `common/AvSessionManager.ets` — HarmonyOS AVSession integration (media controls)

### entry (main HAP)
UI layer and feature orchestration.
- `product/Index.ets` — root UI composition (tab navigation, responsive layout)
- `entryability/EntryAbility.ets` — app lifecycle, initialization, background task setup
- `common/PlayerSession.ets` — singleton managing current playback session
- `common/ActionHub.ets` — centralized navigation/action dispatcher with event bus
- `common/AppState.ets` — @Observed global UI config (dark mode, language, etc.)
- `common/PreferencesStore.ets` — key-value persistence
- `common/FeedServiceProvider.ets` — feed data source provider
- `features/player/YouTubePlayService.ets` — orchestrates stream extraction → playback
- `features/player/PlayQueueManager.ets` — play queue and local playlist management
- `features/player/PlaybackContinuationService.ets` — multi-device playback resume
- `features/home/` — feed, search, channel, playlist services + parsers
- `features/auth/` — Google account login via WebView

## Key Patterns

**State management:** AppStorage (global key-value) + @Observed classes (AppState, PlaybackConfig). UI observes state changes via ArkUI's reactive binding.

**Navigation:** ActionHub is injected via AppStorage. Pages call ActionHub methods (openVideo, openChannel, closePage) rather than navigating directly.

**Playback pipeline:** YouTubePlayService extracts streams → LocalMediaProxy builds EDL playlist referencing local proxy URLs → AvPlayerController plays via MpvPlaybackEngine or NativePlaybackEngine.

**DASH streaming:** LocalProxyServer serves DASH segments on-demand. RangeProxy chunks large range requests to avoid YouTube throttling (SABR). PlaylistBuilder generates EDL for MPV dual-stream (video+audio).

**Logging:** Module-level AppLog instances (entry), EnhancedLogger (mediaservice), YTCoreLogger (youtube_core). All sinks are injected from EntryAbility at startup.

## Linting

Config in `Application/code-linter.json5`. Rule sets: `@performance/recommended`, `@typescript-eslint/recommended`. Security rules enforced (no-unsafe-aes/hash/mac/dsa/rsa/3des).

## Language & Localization

ArkTS (TypeScript dialect for HarmonyOS). UI strings in `entry/src/main/resources/` with locale variants (zh_CN base, en_US, ar_SA, de_DE, es_ES, fr_FR, ru_RU, zh_HK, zh_TW). Dark mode resources in `dark/`.
