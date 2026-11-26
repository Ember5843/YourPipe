<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="YourPipe" height="96" />

# YourPipe

**面向 OpenHarmony / HarmonyOS 的原生 YouTube 客户端**

[![Version](https://img.shields.io/badge/version-0.7.2-blue?style=flat-square)](AppScope/app.json5)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0(23)-black?style=flat-square)](https://developer.huawei.com/consumer/en/harmonyos/)
[![Target SDK](https://img.shields.io/badge/Target%20SDK-26.0.0-teal?style=flat-square)](build-profile.template.json5)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

> 非官方第三方客户端。**与 YouTube 或 Google 无任何关联。**

</div>

---

## 项目简介

**YourPipe** 是一款专为 **HarmonyOS（Next / Stage 模型）** 打造的原生 **ArkTS / ArkUI + C++20** YouTube 客户端。应用内直接完成流媒体提取（`youtube_core`），通过 Ark Runtime JSVM 原生模块（`libyourpipe_cipher.so`）在端侧执行 YouTube 播放器签名与 `n` 参数解密，并基于内置的 **MPV（`libmpv.so.2` + Vulkan `gpu-next` + `ohcodec-copy` 硬解 + FFmpeg n8.0）** 进行原生渲染播放，而非套壳 WebView 播放器。

| 项目信息 | 说明 |
|---|---|
| **应用包名** | `com.talon.yourpipe` |
| **当前版本** | `0.7.2`（`versionCode: 1000035`） |
| **SDK / 模型** | `compatibleSdkVersion: 6.1.0(23)` · `targetSdkVersion: 26.0.0` · Stage 模型 |
| **原生编译器** | `BiSheng`（真机播放需 `arm64-v8a`；`x86_64` 仅作界面占位桩） |
| **适配设备** | `phone` · `tablet` · `2in1` · `tv` · `car` |
| **界面语言（13 种 + 跟随系统）** | 简体中文、繁體中文（香港/台灣）、English、日本語、한국어、Deutsch、Français、Español、Português (BR)、Italiano、Русский、العربية |

---

## 核心功能

### 音视频提取与原生播放引擎
- **多端提取路由与自适应流**：
  - **访客点播**：默认通过 `visionos` 直链 DASH + C++20 `ypstream://`（`DirectRangeStream` / `librcp_c`，保留 `LocalMediaProxy` 回环兜底）喂入 MPV，支持切换 `mweb` SABR，Shorts 自动回退 Android Reel 获取混流。
  - **登录态播放**：Cookie 登录默认走 `mweb` 双轨 **SABR / UMP** 本地代理（`SabrDashProxy`，支持 MP4 `sidx` 与 WebM EBML Cues 索引）；TV OAuth 走 `tv_downgraded` 直链。
- **端侧 JSVM 解密与 PoToken**：
  - 使用鸿蒙 JSVM（`libyourpipe_cipher.so` + 内嵌 EJS 脚本包 + `tv-player-ias.js` 回退）在本地解密 `n` 与 `sig` 参数，自动兼容鸿蒙「安全隐私防护模式（Secure Shield）」并按需回退 PipePipe 远程解密接口。
  - 隐藏 ArkWeb 运行时（`SabrWebViewPoTokenProvider`）按会话 `visitorData` 自动签发 BotGuard `PoToken`。
- **原生 MPV 管线（`vo=gpu-next`）**：
  - Vulkan 渲染支持真 HDR（`target-colorspace-hint=yes`）、硬件解码能力探测白名单（`ohcodec-copy`）、`lavfi` 零音画不同步响度均衡增强（`acompressor` + `alimiter`）、音画同步微调（`-1000..+1000 ms`）以及实时码率/缓冲/掉帧图表（`StatsBarGraph`）。
  - 支持 `0.25x–3.0x` 倍速、Shorts 单条循环、画中画（PiP）、后台连续播放与系统播控中心（`AVSession`）、睡眠定时以及跨设备**播放接续流转**（`PlaybackContinuationService`）。

### 字幕、翻译与直播聊天
- **双语字幕与 `json3` 解析**：
  - ArkUI 叠层字幕优先解析 `fmt=json3`（消除自动字幕滚动重复行）并支持 `fmt=vtt` 回退、P0 YouTube 服务端 `tlang` 机翻轨、双语副字幕、时间轴偏移（`-5000..+5000 ms`）及字号/边距/颜色/描边/背景实时预览。
- **9 种评论与简介翻译引擎**：
  - `gtx`（Google Web 免费版）、Google Cloud 翻译、Microsoft Translator（`Azure`）、MyMemory、Lingva、LibreTranslate、DeepL、OpenAI 兼容大模型，以及自定义 HTTP 模板，并在失败时直接透传具体报错信息。
- **只读直播聊天室**：
  - 支持直播实时聊天与直播回放时间轴同步聊天（展示 Super Chat 与会员徽章）。

### 播放器手势与交互界面
- **四合一进度条与毛玻璃 HUD**：
  - 进度条集成了 **章节刻度 + SponsorBlock 片段标记 + 重播热力图曲线 + 故事板缩略图预览**，配备居中音量/亮度毛玻璃 HUD 与流畅的临界阻尼弹簧全屏动效。
- **手势控制**：
  - 内置 3 套手势预设（增强 / YouTube / Bilibili），支持左右侧独立开关亮度与音量滑动、横向滑动快进预览、双击快进/暂停、长按临时倍速（`1.25x–3.0x`）。

### 双轨账号体系与隐私边界
- **数据获取与播放鉴权独立开关**：
  - **Web Cookie 轨**：支持网页扫码/登录提取 Cookie 与 `SAPISIDHASH`，亦支持在设置中直接导入 Cookie Header 或 EditThisCookie JSON，用于同步订阅/历史/播放列表及 `mweb` SABR 登录态播放。
  - **TV 扫码登录轨（对齐 SmartTube）**：动态抓取 YouTube TV 最新客户端凭证与 `visitorData`，支持电视设备码/二维码授权（`yt.be/activate`）、品牌账号 `pageIdToken`（`X-Goog-Pageid`），并将 TV `Bearer` 严密隔离在 `tv_downgraded` 通道，稳定解锁 **18+ 年龄限制**视频。
  - **自由权限控制**：支持全局「无痕模式」，并可分别开关「登录态用于获取用户数据」与「登录态用于播放」，在需要授权或遇到 5 秒非会员 SABR 前置广告等待时提供引导气泡与直达设置入口。

### 离线下载与单文件字幕内封
- **多模式下载**：支持 `Progressive`、`DASH`（分离音视频）、`SABR / UMP`、`HLS` 以及 **仅下载字幕（`.srt`）**。
- **10MB 分片断点续传**：DASH 直链支持分片级断点保存、暂停/恢复与失败重提流重试；可调并发数（1–4）及卡死看门狗超时。
- **无损内封字幕进 `.mkv` 视频**：
  - 通过 `libmpv_napi` 的 `muxMedia` 无损封装接口，可将选定字幕无损快速地与音视频**合并进单个 `.mkv` 文件**（支持 Progressive / DASH / SABR，无需单独保存外挂 `.srt`），在本应用 MPV 及 VLC/PotPlayer 等播放器中打开即直接渲染字幕。
  - 内置沙箱下载库支持孤儿目录回收、本地导入视频统一连播列表（`.mp4/.mkv/.webm/.mov/.ts/.flv/.avi/.m4v`）及一键导出到系统「下载」目录。

### 实验性增强与实用工具
- **实验性功能中心（默认关闭）**：
  - **SponsorBlock**（9 类跳过规则、SHA-256 隐私前缀查询、提示条与一键撤销、后台/PiP 自动跳过、频道白名单）
  - **DeArrow**（众包去标题党标题与实景缩略图）
  - **AiSList**（接入 `Override92/AiSList` 过滤或警告 AI 批量生成频道）
  - **重播热力图与「高能跳转」**
- **ReturnYouTubeDislike 点踩数**、**首页长视频 / Shorts 维度切换**、**YouTube / YouTube Music 搜索筛选**、**1000 条原子化观看历史**、**HTTP（含鉴权）/ SOCKS5 代理**、**9 套主题色 + 深浅色模式**、**JSON 备份恢复**、**GitHub Releases 应用内更新检查**与**应用内日志查看/导出**。

---

## 模块架构

```text
entry  ──▶  mediaservice  ──▶  youtube_core  （C++ libyourpipe_cipher.so）
  │              └──────────▶  @yourpipe/libmpv-napi  （C++ libmpv_napi.so + libmpv.so.2 + FFmpeg n8.0）
  ├──────▶  youtube_core
  └──────▶  asrengine  （保留 HAR；当前版本 UI/构建默认已注释关闭 P3 端侧语音识别）
```

| 模块 | 职责说明 | 备注 |
|---|---|---|
| `entry` | 应用 UI 页面、账号认证界面、离线下载管理、设置项、数据备份、PoToken ArkWeb | 依赖 `mediaservice`、`youtube_core`、`asrengine` 及 OHPM 包 `sherpa_onnx@1.13.3` |
| `mediaservice` | 播放控制器 `AvPlayerController`、`MpvPlaybackEngine`、`AVSession`、SABR 代理与离线下载、字幕解析器 | 媒体与播放能力收口层 |
| `youtube_core` | InnerTube API、视频/评论/频道/直播聊天提取、SABR 协议栈、JSVM 解密 NAPI、账号管理 | 独立提取与鉴权核心层 |
| `libmpv_napi` | C++20 NAPI 桥接（`ypstream://`、硬件解码探测、`muxAudioVideo` / `muxMedia`）及 `arm64-v8a` 预编译原生库 | `x86_64` 编译 `player_napi_stub.cpp`（仅 UI 调试） |
| `asrengine` | 端侧语音识别音频解码原生 HAR（`libasr_engine.so`） | 构建工程保留，端侧 ASR 功能当前处于 `[DISABLED]` 状态 |

---

## 使用说明

1. **配置网络代理（若网络环境需要）**：
   - 进入 **设置 → 网络与代理**，配置 **HTTP**（可选账号密码）或 **SOCKS5** 代理，可点击「测试连接」验证连通性（代理自动覆盖 Netstack、RCP、ArkWeb 与 MPV）。
2. **账号登录与策略选择**：
   - 进入 **设置 → 数据与账号**：
     - **TV 扫码登录（OAuth）**：推荐仅需解锁 **18+ 年龄限制内容** 时使用，无需管理浏览器 Cookie（播放走 `tv_downgraded + Bearer`）。
     - **Web 登录（网页登录 / 导入 Cookie）**：用于获取个人首页推荐、订阅列表、播放列表、同步历史以及启用 `mweb` SABR 登录态播放。
     - **体验权衡提示**：非 YouTube Premium 账号在登录态 `mweb` SABR 播放时会有约 5 秒前置等待（播放器会给出倒计时提示）；匿名状态（`visionos`）起播更快但部分网络出口可能触发风控。你可随时独立开关「用于获取用户数据」与「用于播放」。
3. **字幕与翻译**：
   - 播放页点击 **CC** 图标选择主/副字幕或自动翻译轨；在 **设置 → 字幕** 自定义字号、边距、颜色与延迟微调。
   - 在 **设置 → 语言与地区 → 翻译服务** 中配置评论与简介翻译源。
4. **下载视频与字幕**：
   - 在视频详情页点击 **下载**，或首页/搜索卡片长按选择 **下载**：
     - **步骤 1（模式）**：可选 `Progressive`、`DASH`、`SABR`、`HLS`，或直接选 **`仅下载字幕 (.srt)`**；
     - **步骤 2（清晰度与音轨）**：挑选视频规格与多语言音轨；
     - **步骤 3（字幕选项，可选）**：选择需要随视频保存的字幕轨，默认开启 **「内封进视频文件 (.mkv)」**，无损封装成**单个 `.mkv` 视频文件**（*说明：应用内预编译 FFmpeg 精简库不含 `libavfilter`/`libass` 与视频重编码器，暂不支持将字幕硬烧录进画面像素；通过 `.mkv` 无损内封同样只需保存一个文件，且在本应用 MPV、VLC、PotPlayer 等播放器中会自动显示字幕，无需硬压损耗画质。若只需纯文本字幕，关闭开关或在步骤 1 选「仅下载字幕」即可保存 `.srt`。*）
   - 在 **本地 → 下载** 管理队列、断网续传、应用内播放或 **导出到系统下载目录**。

---

## 如何编译与打包

### 关于 Git 仓库中被排除的敏感与本机文件
为保护个人隐私与证书安全，已推送的代码库通过 [`.gitignore`](.gitignore) 与 `.githooks/pre-commit` **故意排除了**以下敏感或机器本地文件：

| 被忽略的文件 / 目录 | 用途说明 |
|---|---|
| `build-profile.json5` | 本机根构建配置，内部会写入你的 `signingConfigs` 密码/证书路径 |
| `signing-backup/`、`keys/`、`*.p12`、`*.p7b`、`*.cer`、`*.jks`、`*.keystore` | HarmonyOS 签名密钥库、调试/发布证书与 Profile 文件 |
| `entry/src/main/resources/rawfile/` 下的 AGC 服务配置文件 | 可选的华为 AppGallery Connect 配置文件（已加入忽略规则） |
| `**/local.properties` | 本机 SDK 路径覆盖配置 |

> **说明**：`libmpv_napi` 所需的 `arm64-v8a` 预编译二进制库（`libmpv.so.2` 与 `ffmpeg-sdk/lib/arm64-v8a/*.a`）**已经包含在 Git 仓库中**，拉取代码后无需额外去 Linux 环境交叉编译 C/C++ 库即可直接编译 HAP 安装包。

### 环境要求
- **[DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/)**（包含 **HarmonyOS SDK `6.1.0(23)` / Target SDK `26.0.0`**、`ohpm`、`hvigorw`、`hdc` 及内置 `jbr`）。
- 命令行打包若在 `PackageHap` 阶段遇到 `spawn java ENOENT`，请将环境变量 `JAVA_HOME` 指向 DevEco Studio 安装目录下的 `jbr`，并将 `%JAVA_HOME%\bin`（或 `$JAVA_HOME/bin`）加入 `PATH`。
- 真机视频播放需要 **`arm64-v8a`** 鸿蒙设备（`x86_64` 模拟器仅编译占位桩，可浏览界面但无法实际解码播放）。

### 编译与打包步骤

1. **克隆仓库**：
   ```bash
   git clone https://github.com/Ember5843/YourPipe.git
   cd YourPipe
   ```

2. **从模板生成本机 `build-profile.json5`**：
   - **macOS / Linux / Git Bash**：
     ```bash
     cp build-profile.template.json5 build-profile.json5
     ```
   - **Windows PowerShell**：
     ```powershell
     Copy-Item build-profile.template.json5 build-profile.json5
     ```

3. **同步 OHPM 依赖**（拉取 `sherpa_onnx@1.13.3` 并链接本地 HAR 模块）：
   ```bash
   ohpm install
   ```
   *（也可直接在 DevEco Studio 中打开项目根目录并点击 **Sync Now**。）*

4. **配置签名信息** *(打包签名 HAP 与安装到真机的必要步骤)*：
   - 用 **DevEco Studio** 打开项目，进入 **File → Project Structure → Signing Configs**。
   - 登录华为开发者账号点击 **Automatically generate signature** 自动生成调试签名，或填入你自己的 `.p12` / `.p7b` / `.cer` 发布签名材料（签名配置会自动写入你本地被 `.gitignore` 忽略的 `build-profile.json5` 中）。
   - *（可选）* 如需接入 AGC 服务，可将自己的 AGC 服务配置文件放入 `entry/src/main/resources/rawfile/`。

5. **编译与导出 HAP 安装包**：
   - **DevEco Studio 图形化操作**：连接 `arm64-v8a` 真机后直接点击 **Run**，或通过菜单 **Build → Build Hap(s)/APP(s) → Build Hap(s)**（可选 `debug` 或 `release`）。
   - **使用 `devecocli` 命令行**：
     ```bash
     # 完整 Debug 构建（涵盖全部 5 个模块）
     devecocli build

     # Release 模式打包
     devecocli build --product default --build-mode release

     # 安装并启动到已连接的真机
     devecocli run --skip-build
     ```
   - **直接使用 `hvigorw`**：
     ```bash
     hvigorw assembleHap --mode module -p product=default -p buildMode=debug
     # 发布包将 debug 改为 release
     ```
   构建产物输出在 `entry/build/default/outputs/default/`（含 `entry-default-signed.hap` 与 `entry-default-unsigned.hap`）。

6. **运行交互回归单元测试（可选）**：
   详见 [`tools/tests/README.md`](tools/tests/README.md)：
   ```bash
   node tools/tests/interaction-regressions.cjs --typescript "<DevEco>/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js"
   ```

---

## 致谢与参考项目

| 项目 / 服务 | 参考与用途 |
|---|---|
| [NewPipe](https://github.com/TeamNewPipe/NewPipe) & [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor) | 客户端交互范式与 YouTube 提取模型架构 |
| [PipePipe](https://github.com/InfinityLoop1308/PipePipe) | 客户端提取兼容策略、SABR / PoToken 与远程解密兼容 |
| [SmartTube](https://github.com/yuliskov/SmartTube) | TV 设备 OAuth 登录流程与 18+ 年龄限制内容兼容思路 |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 流媒体提取调研与 EJS 播放器解密脚本方案 |
| [MPV](https://github.com/mpv-player/mpv) & [FFmpeg](https://ffmpeg.org/) | 原生播放核心（`libmpv.so.2`）与无损混流封装（`libavformat`） |
| [libmdk-napi](https://github.com/wang-bin/libmdk-napi) | `libmpv_napi` 桥接模块的历史结构来源 |
| [iPlay](https://github.com/saltpi/iPlay) · [FinVideo](https://github.com/OHPG/FinVideo) · [ClashBox](https://github.com/xiaobaigroup/ClashBox) · [tpc_c_cplusplus](https://gitcode.com/CPF-ApplicationTPC/tpc_c_cplusplus) · [VLC](https://www.videolan.org/) | 鸿蒙原生播放器、代理桥接与 C/C++ 三方库移植参考 |
| [SponsorBlock](https://sponsor.ajay.app/) · [DeArrow](https://dearrow.ajay.app/) · [ReturnYouTubeDislike](https://returnyoutubedislike.com/) · [AiSList](https://github.com/Override92/AiSList) | 可选社区数据增强服务 |

---

## 开源协议

本项目采用 **GPL-3.0** 协议开源，详情请参阅 [LICENSE](LICENSE)。  
项目部分逻辑与设计思路参考自 NewPipe、NewPipeExtractor、PipePipe、SmartTube、yt-dlp、MPV 等开源项目，二次分发时请一并遵守对应上游项目的开源许可协议。
