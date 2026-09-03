# asrengine/AGENTS.md

> On-device ASR audio-decode HAR (AI subtitle P3). One NAPI function that turns
> a local m4a/AAC file into a 16kHz mono float32 PCM file for sherpa-onnx.
> Retained in the build (entry declares the package dep) but currently has no
> consumer — end-side ASR is [DISABLED]; see the root `AGENTS.md`.
> Durable architecture only — no changelogs.

## 1. Public surface (`Index.ets`)
- `decodeAacToPcm16k(fd, offset, size, outPath): Promise<number>` — NDK
  AVDemuxer + AudioCodec **synchronous-mode** AAC decode, mono downmix +
  streaming linear resample to 16kHz, float32 LE written to `outPath`;
  resolves the output sample count. Rejects with a stable error string
  (`no_aac_track`, `decode_stalled`, …).

## 2. Layout
```
asrengine/
  Index.ets                    — public re-export
  src/main/ets/AsrEngineNative.ets  — ArkTS wrapper over libasr_engine.so
  src/main/cpp/
    CMakeLists.txt             — module `asr_engine`, system NDK libs only
    asr_decode_napi.cpp        — demux + decode + resample (napi async work)
    types/asr_engine/          — NAPI types package (referenced by oh-package.json5)
```

## 3. Conventions
- **System NDK only** (`ace_napi.z`, `hilog_ndk.z`, `native_media_avdemuxer`,
  `native_media_avsource`, `native_media_acodec`, `native_media_codecbase`,
  `native_media_core` per `CMakeLists.txt` `target_link_libraries`) —
  no vendored FFmpeg/mpv linkage, both ABIs (`arm64-v8a`, `x86_64`) build the
  same real code (decoding is a system capability, emulator included).
- Decode scope is **local files via fd** (entry downloads the audio track
  first). Network, proxy, YouTube semantics live in entry — not here.
- The decoder runs in synchronous mode (no registered callbacks); the whole
  pump loop lives on the napi async-work thread.
- Only AAC (`audio/mp4a-latm`, YouTube itag 140 family). Opus/webm is
  deliberately out of scope (system NDK has no opus decoder guarantee).
- No top-level mutable state in `Index.ets`; no `console.log`/`hilog` in ArkTS
  (native uses `hilog_ndk` with tag `asr_engine`).
