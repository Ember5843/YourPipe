<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="YourPipe" height="96" />

# YourPipe

**OpenHarmony / HarmonyOS 向けネイティブ YouTube クライアント**

[![Version](https://img.shields.io/badge/version-0.7.2-blue?style=flat-square)](AppScope/app.json5)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0(23)-black?style=flat-square)](https://developer.huawei.com/consumer/en/harmonyos/)
[![Target SDK](https://img.shields.io/badge/Target%20SDK-26.0.0-teal?style=flat-square)](build-profile.template.json5)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · **日本語**

> 非公式サードパーティクライアントです。**YouTube および Google とは一切関係ありません。**

</div>

---

## 概要

**YourPipe** は **HarmonyOS（Next / Stage モデル）** 向けに **ArkTS / ArkUI + C++20** で開発されたネイティブ YouTube クライアントです。WebView プレイヤーのラッパーではなく、アプリ内でストリーム抽出（`youtube_core`）、Ark Runtime JSVM による署名・`n` パラメータのローカル復号（`libyourpipe_cipher.so`）、および組み込み **MPV（`libmpv.so.2` + Vulkan `gpu-next` + `ohcodec-copy` ハードウェアデコード + FFmpeg n8.0）** によるネイティブ再生を実現しています。

| 項目 | 内容 |
|---|---|
| **パッケージ名** | `com.talon.yourpipe` |
| **バージョン** | `0.7.2`（`versionCode: 1000034`） |
| **SDK / モデル** | `compatibleSdkVersion: 6.1.0(23)` · `targetSdkVersion: 26.0.0` · Stage Model |
| **対応 ABI** | `arm64-v8a`（実機再生用） / `x86_64`（UI 確認用スタブ） |
| **対応デバイス** | `phone` · `tablet` · `2in1` · `tv` · `car` |
| **UI 言語（13言語 + システム設定）** | 日本語、简体中文、繁體中文（HK/TW）、English、한국어、Deutsch、Français、Español、Português (BR)、Italiano、Русский、العربية |

---

## 主な機能

- **マルチエンドポイント抽出とローカル復号**：ゲスト VOD は `visionos` ダイレクト DASH（C++20 `ypstream://`）を既定とし、Cookie ログイン時は `mweb` **SABR / UMP** プロキシ、TV OAuth 時は `tv_downgraded` を使用。`libyourpipe_cipher.so`（JSVM）と非表示 ArkWeb による `PoToken` 発行を内蔵。
- **デュアル認証レールとアクセス境界**：Web Cookie（WebView / ヘッダー・JSON インポート）および SmartTube 準拠の TV QR / OAuth（ライブ TV クライアント情報・`visitorData`・ブランドアカウント `pageId` 対応、**18+ 年齢制限**コンテンツ再生に対応）。「ユーザーデータ取得用」と「再生用」の認証適用を個別に切り替え可能。
- **MPV ネイティブ再生 & カスタマイズ**：Vulkan HDR、`lavfi` 音量ノーマライズ、4-in-1 シークバー（チャプター / SponsorBlock / リプレイヒートマップ / ストーリーボード）、ジェスチャープリセット、ピクチャー・イン・ピクチャー、バックグラウンド再生、HarmonyOS デバイス間引き継ぎに対応。
- **字幕・翻訳・ライブチャット**：`fmt=json3` / `vtt` デュアル字幕オーバーレイ、P0 `tlang` 自動翻訳、9 種類のコメント/概要翻訳エンジン（`gtx` / Google Cloud / Azure / DeepL / LLM / カスタム HTTP）、読み取り専用ライブチャットに対応。
- **レジューム対応ダウンロード & `.mkv` 無劣化字幕埋め込み**：Progressive / DASH / SABR / HLS / **字幕のみ（`.srt`）** に対応。動画保存時には再エンコードなしの `muxMedia` で字幕を単一の `.mkv` ファイルへ無劣化格納可能。
- **プロキシ & 実験的機能**：HTTP / SOCKS5 プロキシ、SponsorBlock、DeArrow、AiSList、ReturnYouTubeDislike、JSON バックアップ/復元、GitHub Releases アプリ内更新チェックを搭載。

---

## モジュール構成

```text
entry  ──▶  mediaservice  ──▶  youtube_core  （C++ libyourpipe_cipher.so）
  │              └──────────▶  @yourpipe/libmpv-napi  （C++ libmpv_napi.so + libmpv.so.2 + FFmpeg n8.0）
  ├──────▶  youtube_core
  └──────▶  asrengine  （HAR 保持、オンデバイス P3 ASR は現在 UI/ビルドで無効化）
```

---

## 使い方

1. **プロキシ**：必要に応じて **設定 → ネットワークとプロキシ** から HTTP / SOCKS5 プロキシを設定し、接続テストで確認します。
2. **ログイン切り替え**：**設定 → データとアカウント** で TV QR ログイン（18+ 年齢制限の解除に最適）または Web Cookie ログインを設定し、「ユーザーデータ用」「再生用」のトグルで範囲を調整できます（非 Premium アカウントのログイン `mweb` 再生では約 5 秒の待機時間が発生するためカウントダウン案内を表示します）。
3. **字幕付き動画ダウンロード**：ダウンロード画面のステップ 1 で形式（または **字幕のみ `.srt`**）を選び、ステップ 3 で字幕トラックを選択して **「動画ファイルに埋め込む (.mkv)」** をオンにすると、1 つの `.mkv` ファイルに無劣化で字幕を同梱できます（組み込み FFmpeg には映像エンコーダや `libavfilter`/`libass` が含まれないためハードサブ焼き込みは非対応ですが、YourPipe の MPV プレイヤーや VLC 等でそのまま字幕表示されます）。

---

## ビルドとパッケージング方法

公開リポジトリには機密保護のため署名関連ファイル（`build-profile.json5`、`signing-backup/`、`keys/`、`*.p12`/`*.p7b`/`*.cer`、AGC サービス設定ファイル、`local.properties`）が [`.gitignore`](.gitignore) で除外されています（`arm64-v8a` 用の `libmpv.so.2` と `ffmpeg-sdk/*.a` は同梱済み）。

1. リポジトリをクローンし、テンプレートから `build-profile.json5` を作成します：
   ```bash
   git clone https://github.com/Ember5843/YourPipe.git
   cd YourPipe
   cp build-profile.template.json5 build-profile.json5
   # Windows PowerShell: Copy-Item build-profile.template.json5 build-profile.json5
   ```
2. OHPM 依存関係をインストールします（`sherpa_onnx@1.13.3` およびローカル HAR）：
   ```bash
   ohpm install
   ```
3. **DevEco Studio**（HarmonyOS SDK `6.1.0(23)` / Target SDK `26.0.0`）でプロジェクトを開き、**File → Project Structure → Signing Configs** から自身の署名設定を構成します（ローカルの `build-profile.json5` に保存されます。CLI で `spawn java ENOENT` が出る場合は `JAVA_HOME` に DevEco 同梱の `jbr` を設定してください）。
4. ビルド・HAP パッケージ生成：
   ```bash
   devecocli build
   # Release ビルド:
   devecocli build --product default --build-mode release
   # または hvigorw:
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug
   ```
   出力先は `entry/build/default/outputs/default/` です。単体テスト手順は [`tools/tests/README.md`](tools/tests/README.md) を参照してください。

---

## ライセンス

**GPL-3.0** ライセンスの下で公開されています。詳細は [LICENSE](LICENSE) を、参考文献・謝辞は [English README](README.md#credits--references) をご覧ください。
