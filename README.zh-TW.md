<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="YourPipe" height="96" />

# YourPipe

**適用於 OpenHarmony / HarmonyOS 的原生 YouTube 用戶端**

[![Version](https://img.shields.io/badge/version-0.7.2-blue?style=flat-square)](AppScope/app.json5)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0(23)-black?style=flat-square)](https://developer.huawei.com/consumer/en/harmonyos/)
[![Target SDK](https://img.shields.io/badge/Target%20SDK-26.0.0-teal?style=flat-square)](build-profile.template.json5)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md)

> 非官方第三方用戶端。**與 YouTube 或 Google 無任何關聯。**

</div>

---

## 專案簡介

**YourPipe** 是一款專為 **HarmonyOS（Next / Stage 模型）** 打造的原生 **ArkTS / ArkUI + C++20** YouTube 用戶端。應用內直接完成串流提取（`youtube_core`），透過 Ark Runtime JSVM 原生模組（`libyourpipe_cipher.so`）於本機執行 YouTube 播放器簽章與 `n` 參數解密，並基於內建的 **MPV（`libmpv.so.2` + Vulkan `gpu-next` + `ohcodec-copy` 硬體解碼 + FFmpeg n8.0）** 原生渲染播放。

| 專案資訊 | 說明 |
|---|---|
| **套件名稱** | `com.talon.yourpipe` |
| **目前版本** | `0.7.2`（`versionCode: 1000035`） |
| **SDK / 模型** | `compatibleSdkVersion: 6.1.0(23)` · `targetSdkVersion: 26.0.0` · Stage 模型 |
| **原生編譯器** | `BiSheng`（實機播放需 `arm64-v8a`；`x86_64` 僅供介面佔位除錯） |
| **支援裝置** | `phone` · `tablet` · `2in1` · `tv` · `car` |
| **介面語言（13 種 + 跟隨系統）** | 繁體中文（香港/台灣）、簡體中文、English、日本語、한국어、Deutsch、Français、Español、Português (BR)、Italiano、Русский、العربية |

---

## 主要功能

- **多客戶端提取與端側解密**：訪客點播預設走 `visionos` 直連 DASH 經 C++20 `ypstream://` 送入 MPV；Cookie 登入預設走 `mweb` 雙軌 **SABR / UMP** 本機代理；TV OAuth 走 `tv_downgraded` 直連。本機 JSVM（`libyourpipe_cipher.so`）支援安全隱私模式自動偵測與遠端回退，隱藏 ArkWeb 負責簽發 `PoToken`。
- **雙軌登入與權限隔離**：支援 Web Cookie（網頁登入或匯入 Header/JSON）與 SmartTube 風格 TV 掃碼 OAuth（動態抓取 TV 用戶端憑證、`visitorData` 及品牌帳號 `X-Goog-Pageid`），可解鎖 **18+ 年齡限制** 內容，且可分別開關「用於獲取用戶資料」與「用於播放」。
- **MPV 原生播放與字幕**：支援 Vulkan HDR 輸出、`lavfi` 無感響度均衡增強、音畫延遲微調、四合一進度條（章節 + SponsorBlock + 重播熱力圖 + 故事板預覽）、子母畫面（PiP）、背景持續播放與鴻蒙跨裝置接續。字幕支援 `fmt=json3` / `fmt=vtt`、雙語顯示、P0 `tlang` 翻譯及完整樣式與時間軸偏移調整。
- **實驗性功能與多語言翻譯**：內建 SponsorBlock、DeArrow、AiSList、重播熱力圖高能跳轉與 ReturnYouTubeDislike；評論與簡介翻譯支援 9 種引擎（含 `gtx`、Google Cloud、Azure、DeepL、OpenAI 兼容模型與自訂 HTTP 接口）。
- **斷點續傳下載與 `.mkv` 無損內封字幕**：支援 Progressive / DASH / SABR / HLS / **僅下載字幕（`.srt`）**，10MB 分片斷點續傳，並支援透過 FFmpeg `muxMedia` 無損將字幕軌道內封進單一 `.mkv` 影片檔。
- **代理與備份**：支援 HTTP（含帳密）與 SOCKS5 代理、1000 筆觀看紀錄、JSON 選擇性備份還原、GitHub Releases 更新檢查與應用內日誌匯出。

---

## 模組架構

```text
entry  ──▶  mediaservice  ──▶  youtube_core  （C++ libyourpipe_cipher.so）
  │              └──────────▶  @yourpipe/libmpv-napi  （C++ libmpv_napi.so + libmpv.so.2 + FFmpeg n8.0）
  ├──────▶  youtube_core
  └──────▶  asrengine  （保留 HAR；目前預設關閉 P3 端側語音辨識功能）
```

---

## 使用指南

1. **代理設定**：於 **設定 → 網路與代理** 設定 HTTP / SOCKS5 代理並測試連線，所有網路請求與 MPV 皆會套用。
2. **帳號與播放模式**：於 **設定 → 資料與帳號** 選擇 TV 掃碼登入（適合直接解除 18+ 年齡限制）或 Web Cookie 登入（同步訂閱、歷史與 `mweb` SABR）。非會員於 `mweb` 登入播放會有約 5 秒前置等待，播放器提供倒數提示與設定捷徑。
3. **下載與單檔內封字幕**：點擊播放器「下載」或長按卡片「下載」，可單選 **`僅下載字幕 (.srt)`**，或在下載影片時於步驟 3 選擇字幕並開啟 **「內封進影片檔案 (.mkv)」**——無須重新編碼畫面即可將字幕無損打包進單一 `.mkv` 影片，在 YourPipe 與 VLC 等播放器開啟即可顯示字幕。

---

## 編譯與打包說明

推送至 Git 的原始碼庫透過 [`.gitignore`](.gitignore) 與 `.githooks/pre-commit` **不包含**本機簽章設定與機密憑證（`build-profile.json5`、`signing-backup/`、`keys/`、`*.p12`/`*.p7b`/`*.cer`、AGC 服務設定檔、`local.properties`）。預編譯好的 `arm64-v8a` `libmpv.so.2` 與 `ffmpeg-sdk/*.a` **已包含在倉庫內**。

### 步驟
1. 複製本機根組態範本：
   - macOS / Linux / Git Bash：`cp build-profile.template.json5 build-profile.json5`
   - Windows PowerShell：`Copy-Item build-profile.template.json5 build-profile.json5`
2. 安裝 OHPM 相依套件（含 `sherpa_onnx@1.13.3`）：
   ```bash
   ohpm install
   ```
3. 使用 **DevEco Studio**（HarmonyOS SDK `6.1.0(23)` / Target SDK `26.0.0`）開啟專案，前往 **File → Project Structure → Signing Configs** 配置你自己的除錯或正式簽章（自動寫入本地忽略的 `build-profile.json5`；如命令行打包遇 `spawn java ENOENT`，請將 `JAVA_HOME` 指向 DevEco 內建 `jbr`）。
4. 執行完整建置與打包：
   ```bash
   devecocli build
   # 正式發布包
   devecocli build --product default --build-mode release
   # 或使用 hvigorw
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```
   產出 HAP 位於 `entry/build/default/outputs/default/`。回歸測試請見 [`tools/tests/README.md`](tools/tests/README.md)。

---

## 授權條款

依 **GPL-3.0** 授權條款釋出，詳見 [LICENSE](LICENSE)。參考致謝與授權聲明請參閱 [English README](README.md#credits--references) 或應用內「關於」頁面。
