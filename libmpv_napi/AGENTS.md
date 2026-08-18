# libmpv_napi/AGENTS.md

> NAPI bridge HAR between ArkTS and the native MPV player. The module and
> classes are `libmpv_napi` / `MpvPlayer*`; the `mdk` naming inherited from
> the upstream `wang-bin/libmdk-napi` package was removed — the actual
> player is MPV (vendored `libmpv.so.2` + static `libav*`), no MDK Player
> runtime is used.
>
> **ABI split**: `arm64-v8a` is the full product path (libmpv + FFmpeg).
> `x86_64` builds a **stub** (`player_napi_stub.cpp`) for emulator UI only —
> no real playback. Only arm64 binaries are vendored under `mpv-sdk` /
> `ffmpeg-sdk`.
>
> Note: this module's `deviceTypes` is narrower than the app's
> (`default` / `tablet` / `2in1` only) — for HARs the effective device
> set is the `entry` module's, so this is informational, not a constraint.
>
> Durable architecture only — no changelogs.

## 1. Public surface (`oh-package.json5#main` → `src/main/ets/index.ets`)
- `MpvPlayerView` — ArkUI component wrapping `XComponent` (with
  `libraryname: 'mpv_napi'`) for native rendering. **DORMANT standby path**:
  the product player renders through entry's inline XComponent + `surfaceId`
  (see §5); this component is retained for a possible switch back to the
  libraryname-driven path.
- `MpvPlayerController` — TS controller over the native player (load,
  play, pause, seek, set/get properties, register event callback).
- Enums: `MediaStatus`, `MediaType`, `PlaybackState`, `SeekFlag`, `VideoFit`.
- `MediaInfo` + codec parameter / stream info types.
- `muxAudioVideo` — local-file remux (re-exported via `mediaservice`).
- HW probe: `probeVideoHwDecoders` + `VideoHwDecoderCaps` (OHOS decoder
  capability query for upper layers) and `getHwdecCodecsWhitelist` (the
  probe-derived hwdec-codecs whitelist string; native is the single source of
  truth, EnsureMpv applies the same value).

## 2. Layout
```
libmpv_napi/src/main/
  ets/
    index.ets                          — public re-exports
    enums.ets                          — MPV / media enums
    global.ets                         — mux + HW decoder probe
    media-info.ets                     — MediaInfo, codec/stream parameter types
    components/
      MpvPlayerView.ets                — ArkUI component (XComponent + compositor scale); DORMANT standby, see §5
    controller/
      MpvPlayerController.ets          — TS controller
  cpp/
    CMakeLists.txt                     — arm64 product path vs x86_64 stub
    player_napi.cpp                    — MPV C API bridge (arm64 product)
    player_napi_stub.cpp               — x86_64 emulator UI stub (no libmpv)
    media_info_napi.cpp                — MediaInfo marshalling
    mux_napi.cpp                       — FFmpeg mux/remux NAPI
    global_napi.cpp                    — shared NAPI helpers (ToString / Undefined / log handler)
    hwdec_probe.cpp / .h               — OHOS HW decoder capability probe;
                                         also derives the hwdec-codecs whitelist
                                         (probe-filtered, legacy full list on probe failure)
    vpe_probe.cpp / .h                 — VPE (Video Processing Engine) capability probe
    mpv_ohcodec_shim.cpp               — OHOS hardware codec adapter for MPV
    ffmpeg-sdk/                        — vendored static libs (read-only; arm64)
    mpv-sdk/                           — vendored libmpv.so.2 (read-only; arm64)
    types/libmpv_napi/                 — NAPI `.so` types package (oh-package.json5)
```

## 3. Native build (CMake)
- `cmake_minimum_required(VERSION 3.17)`, C++20.
- **x86_64**: early-return stub — `mpv_napi` from `player_napi_stub.cpp` +
  empty-ish `mpv_ohcodec_shim`; no FFmpeg/libmpv link. Emulator UI only.
- **arm64-v8a** product libraries:
  - `mpv_napi` (MODULE) — the NAPI bridge `.so` consumed by ArkTS.
  - `mpv_ohcodec_shim` (SHARED) — the OHOS hardware codec adapter for MPV,
    copied next to `libmpv_napi.so` at install time.
- Product links:
  - `ace_napi.z`, `ace_ndk.z`, `hilog_ndk.z`, `ohfileuri`,
    `native_window` (surface / XComponent correlation)
  - FFmpeg static libs from `ffmpeg-sdk/lib/${OHOS_ARCH}/` (libavformat,
    libavcodec, libavutil, libswresample, libdav1d, libxml2, libmbedtls*;
    FFmpeg n8.0 aligned with the libmpv build).
  - `-Wl,-Bsymbolic` to bind FFmpeg globals locally (avoids PIC reloc
    issues with aarch64 asm).
  - `-Wl,--start-group` / `--end-group` to resolve the avformat/avcodec/
    avutil circular references.
  - `native_media_core`, `native_media_codecbase`, `native_media_vdec`
    (for the ohdec codec shim), `video_processing` (for the VPE probe).
  - `z` for `libxml2`.
- POST_BUILD copies `libmpv.so.2` from `mpv-sdk/lib/${OHOS_ARCH}/` next to
  `libmpv_napi.so` (arm64 only).

## 4. Native binary pipeline (out-of-tree, in WSL)
`libmpv.so.2` and the FFmpeg static libs are **NOT built by Hvigor**. They
are built in WSL and then vendored here:
- Upstream MPV source: `mpv` checkout in your WSL home
  (e.g. `\\wsl.localhost\<distro>\home\<user>\mpv`)
- Cross-compile recipe: `libmpv-ohos-build` in your WSL home
  (e.g. `\\wsl.localhost\<distro>\home\<user>\libmpv-ohos-build`)
- Outputs land in:
  - `libmpv_napi/src/main/cpp/mpv-sdk/lib/${OHOS_ARCH}/libmpv.so.2` (+ headers in `include/mpv/`)
  - `libmpv_napi/src/main/cpp/ffmpeg-sdk/lib/${OHOS_ARCH}/libav*.a` (+ headers in `include/`)
- Run the WSL build, then copy the new outputs into this repo. Hvigor picks
  them up at the next build. Today only **arm64-v8a** is vendored.

## 5. Render surface: product path vs dormant standby
- **Product path**: entry `AVPlayer.ets` lays out an **inline XComponent**
  (`id: 'PlayerXComponent'`, **no `libraryname`**) sized by `.aspectRatio()`.
  On `onLoad`, entry reads `getXComponentSurfaceId()` and routes it through
  `AvPlayerController` → `MpvPlaybackEngine` → `controller.setVideoSurfaceId()`
  / `setVideoSurfaceSize()`. The bridge pushes that size to mpv via the
  `ohos-surface-size` property (`ApplySurfaceSize`) so the VO reconfigures on
  fullscreen/rotation without native XComponent callbacks.
- **DORMANT standby path**: `MpvPlayerView` uses an XComponent **with
  `libraryname: 'mpv_napi'`**, which activates the native surface callback
  chain (`OnSurfaceCreated/Changed/Destroyed` in `player_napi.cpp`) and the
  `native-window-ptr` branch of `ApplyWindowOption`. On the product path none
  of that fires — `ctx.window` stays null and `wid` is always the surfaceId.
  Enable condition: entry switches its player UI to `MpvPlayerView` /
  libraryname. The component also implements the render-area decoupling
  strategy (fixed native-resolution surface + compositor `.scale()` fit
  transform; `videoFit` controls `Contain` / `Cover` / `Fill`).
- **`wid` protocol** (vendored mpv fork, `vo_ohos`): `wid < 2^40` is an
  `OHNativeWindow*` used directly; `wid >= 2^40` is an XComponent
  `surfaceId`. The bridge prefers the native-window pointer when the
  XComponent provides a window and falls back to the `surfaceId` (product:
  always the surfaceId).

## 6. Conventions
- **Single product path**: this bridge exists to drive MPV. Do not grow a
  parallel custom surface-decoder stack in this module.
- **Policy stays above NAPI**: audio focus, presentation mode, and
  background video-off delay belong in entry / mediaservice. Native code
  exposes player controls and probes, not app lifecycle policy.
- **NAPI boundary**: keep `extern "C"` thin. No STL types cross the
  boundary. Errors propagate via `napi_throw_error` with stable string
  codes.
- **Vendored binaries are read-only.** Do not modify files under
  `mpv-sdk/` or `ffmpeg-sdk/` in place — to upgrade product binaries,
  rebuild in WSL and copy the new outputs.
- **NAPI module name** is `mpv_napi` (the `.so` file). Do not rename —
  `mediaservice` imports it as `@yourpipe/libmpv-napi`.

## 7. Do not
- Edit files under `src/main/cpp/{mpv-sdk,ffmpeg-sdk}` — vendored
  artifacts built externally in WSL. To upgrade, rebuild in the WSL
  paths listed in §4 and copy the new outputs here.
- Expect real playback on x86_64 emulator builds (stub only).
- Reintroduce `mdk` / `MdkPlayer*` / MDK SDK naming or references; the
  player is MPV and the naming is MPV (`mpv_napi`, `MpvPlayer*`).
- Pass STL types across the NAPI boundary.
- Embed app audio-focus or presentation policy in native code.
- Add top-level mutable state in `src/main/ets/index.ets`; export
  factories or `getInstance()` accessors instead.
- Commit `Crash_*.dmp`, `.cxx/`, `build/`, `.hvigor/` artifacts or any
  `AGENTS.md`.
- Put changelogs or commit-specific notes into this file.
