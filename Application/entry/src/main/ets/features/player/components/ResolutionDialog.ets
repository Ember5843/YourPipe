/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { StreamInfo, SelectOption, StreamCategories, CurrentStreams, PlayerModel } from 'mediaservice';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { PlaybackConfig } from '../../../common/PlaybackConfig';

interface StreamSelection {
  progressive?: StreamInfo;
  hlsManifest?: StreamInfo;
  dashManifest?: StreamInfo;
  dashVideo?: StreamInfo;
  dashAudio?: StreamInfo;
}

enum PlaybackType {
  PROGRESSIVE = 'PROGRESSIVE',
  HLS = 'HLS',
  DASH_MANIFEST = 'DASH_MANIFEST',
  DASH_TRACKS = 'DASH_TRACKS'
}

@CustomDialog
export struct ResolutionDialog {
  controller: CustomDialogController;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  
  // 选中的播放类型
  @State selectedType: PlaybackType = PlaybackType.PROGRESSIVE;
  
  // 各类流选中的具体值
  @State selectedProgressive: string = '';
  @State selectedHlsManifest: string = '';
  @State selectedDashManifest: string = '';
  @State selectedDashVideo: string = '';
  @State selectedDashAudio: string = '';
  @State selectedAudioTrack: ResourceStr = '';
  @State showHighResWarning: boolean = false;
  @State selectedDashVideoHeight: number = 0;

  // 辅助变量：存储当前可用的音轨语言列表
  @State audioTrackOptions: SelectOption[] = [];
  @State filteredAudioStreams: StreamInfo[] = [];

  // 传入的数据
  streamCategories?: StreamCategories;
  currentStreams?: CurrentStreams;

  aboutToAppear() {
    if (this.streamCategories && !this.playbackConfig.showHighResolutions) {
      if (this.streamCategories.progressive) {
        this.streamCategories.progressive = this.streamCategories.progressive.filter(s => (s.height || 0) <= 1080);
      }
      if (this.streamCategories.video) {
        this.streamCategories.video = this.streamCategories.video.filter(s => (s.height || 0) <= 1080);
      }
    }

    // 1. 回显当前选项
    if (this.currentStreams) {
      const streams = this.currentStreams;
      if (streams.video) {
        this.selectedProgressive = PlayerModel.getFriendlyQuality(streams.video);
        // 在过滤后的去重列表中找对应 quality 的流，确保和 getStreamByVideoLabel 查找范围一致
        if (this.streamCategories?.video) {
          const deduped = this.getDeduplicatedVideoStreams(this.streamCategories.video);
          const matched = deduped.find(s => s.quality === streams.video!.quality);
          this.selectedDashVideo = matched ? this.getVideoDisplayLabel(matched) : this.getVideoDisplayLabel(streams.video);
        } else {
          this.selectedDashVideo = this.getVideoDisplayLabel(streams.video);
        }
        const h = streams.video.height || 0;
        this.selectedDashVideoHeight = h;
        this.showHighResWarning = h >= 1440;
      }
      if (streams.audio) {
        this.selectedDashAudio = PlayerModel.getFriendlyQuality(streams.audio);
        this.selectedAudioTrack = streams.audio.audioTrackName || streams.audio.audioLanguage || this.getDefaultTrackLabel();
      }
      if (streams.manifest) {
        this.selectedHlsManifest = PlayerModel.getFriendlyQuality(streams.manifest);
        this.selectedDashManifest = PlayerModel.getFriendlyQuality(streams.manifest);
      }
      this.updateFilteredAudioStreams();
    }

    // 2. 确定初始显示的播放类型
    const types = this.getAvailableTypeEnums();
    if (types.length > 0) {
      if (this.currentStreams?.audio || this.currentStreams?.video?.kind === 'video_only') {
        this.selectedType = PlaybackType.DASH_TRACKS;
      } else if (this.currentStreams?.manifest) {
        this.selectedType = PlaybackType.HLS;
      } else {
        this.selectedType = types[0];
      }
    }
  }
  
  onConfirm: (selection: StreamSelection) => void = () => {};
  onCancel: () => void = () => {};

  build() {
    Column() {
      Text($r('app.string.yt_dialog_select_quality'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 24, bottom: 12 })

      Scroll() {
        Column() {
          // 第一步：选择播放类型
          Column() {
            this.SectionHeader($r('app.string.yt_player_step1_select_mode'))
            Select(this.getAvailableTypes())
              .value(this.getPlaybackTypeLabel(this.selectedType))
              .font({ size: 16 })
              .width('100%')
              .height(44)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .borderRadius(8)
              .onSelect((index: number, value: string) => {
                const availableEnums = this.getAvailableTypeEnums();
                this.selectedType = availableEnums[index];
                // 切换模式时，自动选中该模式下的默认推荐流，避免显示旧模式的清晰度标签
                if (this.selectedType === PlaybackType.PROGRESSIVE && this.streamCategories?.progressive?.length) {
                  this.selectedProgressive = PlayerModel.getFriendlyQuality(this.streamCategories.progressive[0]);
                } else if (this.selectedType === PlaybackType.HLS && this.streamCategories?.hlsManifest?.length) {
                  this.selectedHlsManifest = PlayerModel.getFriendlyQuality(this.streamCategories.hlsManifest[0]);
                } else if (this.selectedType === PlaybackType.DASH_MANIFEST && this.streamCategories?.dashManifest?.length) {
                  this.selectedDashManifest = PlayerModel.getFriendlyQuality(this.streamCategories.dashManifest[0]);
                } else if (this.selectedType === PlaybackType.DASH_TRACKS) {
                  if (this.streamCategories?.video?.length) {
                    this.selectedDashVideo = this.getVideoDisplayLabel(this.streamCategories.video[0]);
                  }
                  if (this.streamCategories?.audio?.length) {
                    const tracks = this.getAudioTracks(this.streamCategories.audio);
                    const currentTrackStr = this.resourceToString(this.selectedAudioTrack);
                    if (!currentTrackStr || !tracks.some(t => t === currentTrackStr)) {
                      this.selectedAudioTrack = tracks[0];
                    }
                    this.updateFilteredAudioStreams();
                    if (this.filteredAudioStreams.length > 0) {
                      this.selectedDashAudio = PlayerModel.getFriendlyQuality(this.filteredAudioStreams[0]);
                    }
                  }
                }
              })
          }

          Divider().margin({ top: 20, bottom: 10 }).color($r('sys.color.comp_divider'))

          // 第二步：根据类型选择轨道/清晰度
          if (this.selectedType === PlaybackType.PROGRESSIVE && this.streamCategories?.progressive) {
            Column() {
              this.SectionHeader($r('app.string.yt_player_step2_select_quality'))
              this.Selector($r('app.string.yt_player_video_quality'), this.streamCategories.progressive, this.selectedProgressive, (val) => {
                this.selectedProgressive = val;
              })
            }.width('100%')
          }

          if (this.selectedType === PlaybackType.HLS && this.streamCategories?.hlsManifest) {
            Column() {
              this.SectionHeader($r('app.string.yt_player_step2_select_manifest'))
              this.Selector('HLS Manifest', this.streamCategories.hlsManifest, this.selectedHlsManifest, (val) => {
                this.selectedHlsManifest = val;
              })
            }.width('100%')
          }

          if (this.selectedType === PlaybackType.DASH_MANIFEST && this.streamCategories?.dashManifest) {
            Column() {
              this.SectionHeader($r('app.string.yt_player_step2_select_manifest'))
              this.Selector('DASH Manifest', this.streamCategories.dashManifest, this.selectedDashManifest, (val) => {
                this.selectedDashManifest = val;
              })
            }.width('100%')
          }

          if (this.selectedType === PlaybackType.DASH_TRACKS) {
            this.SectionHeader($r('app.string.yt_player_step2_select_track'))
            if (this.streamCategories?.video && this.streamCategories.video.length > 0) {
              Column() {
                Text($r('app.string.yt_label_video_track'))
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .width('100%')
                  .margin({ bottom: 4, top: 4 })
                Select(this.getVideoOptions(this.streamCategories.video))
                  .value(this.selectedDashVideo)
                  .font({ size: 15 })
                  .width('100%')
                  .height(40)
                  .backgroundColor($r('app.color.yourtube_bg_page'))
                  .borderRadius(8)
                  .onSelect((index: number, value: string) => {
                    this.selectedDashVideo = value;
                    const matched = this.getStreamByVideoLabel(this.streamCategories!.video, value);
                    const h = matched?.height || 0;
                    this.selectedDashVideoHeight = h;
                    this.showHighResWarning = h >= 1440;
                  })
                if (this.showHighResWarning) {
                  Row({ space: 8 }) {
                    SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                      .fontSize(14)
                      .fontColor(['#E67E22'])
                    Text($r('app.string.yt_warn_high_resolution'))
                      .fontSize(12)
                      .fontColor('#E67E22')
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ top: 6 })
                }
              }.width('100%')
            }
            if (this.streamCategories?.audio && this.streamCategories.audio.length > 0) {
              if (this.getAudioTracks(this.streamCategories.audio).length > 1) {
                this.SimpleSelector($r('app.string.yt_player_audio_language_type'), this.getAudioTracks(this.streamCategories.audio), this.selectedAudioTrack, (val) => {
                  this.selectedAudioTrack = val;
                  // 先同步计算出新列表，再赋值给 State，两者共用同一份本地变量
                  const freshFiltered = this.getFilteredAudioStreams(this.streamCategories!.audio, val);
                  this.filteredAudioStreams = freshFiltered;
                  if (freshFiltered.length > 0) {
                    this.selectedDashAudio = PlayerModel.getFriendlyQuality(freshFiltered[0]);
                  }
                })
              }

              // 关键修复：直接在 build() 内联引用 this.filteredAudioStreams 和 this.selectedDashAudio，
              // 而不是通过 @Builder 参数传递。ArkTS 只追踪 build() 中直接引用的 @State 变量，
              // 通过参数传递给 @Builder 的数组不会被响应式追踪，导致切换语言后选项不刷新。
              Column() {
                Text($r('app.string.yt_label_audio_quality'))
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .width('100%')
                  .margin({ bottom: 4, top: 4 })
                Select(this.getOptionsFromStreams(this.filteredAudioStreams))
                  .value(this.selectedDashAudio)
                  .font({ size: 15 })
                  .width('100%')
                  .height(40)
                  .backgroundColor($r('app.color.yourtube_bg_page'))
                  .borderRadius(8)
                  .onSelect((index: number, value: string) => {
                    this.selectedDashAudio = value;
                  })
              }.width('100%')
            }
          }
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: '60%' })
      .padding({ left: 24, right: 24, bottom: 24 })

      // 底部按钮
      Row() {
        Text($r('app.string.yt_action_cancel')).fontSize(16).fontColor($r('app.color.yourtube_text_secondary')).textAlign(TextAlign.Center).layoutWeight(1).height(56)
          .onClick(() => { this.onCancel(); this.controller.close(); })
        Divider().vertical(true).height(24).color($r('sys.color.comp_divider'))
        Text($r('app.string.yt_action_confirm')).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.yourtube_theme_primary')).textAlign(TextAlign.Center).layoutWeight(1).height(56)
          .onClick(() => {
            const selection: StreamSelection = {};
            if (this.selectedType === PlaybackType.PROGRESSIVE && this.streamCategories?.progressive) {
              selection.progressive = this.getStreamByFriendlyQuality(this.streamCategories.progressive, this.selectedProgressive);
            } else if (this.selectedType === PlaybackType.HLS && this.streamCategories?.hlsManifest) {
              selection.hlsManifest = this.getStreamByFriendlyQuality(this.streamCategories.hlsManifest, this.selectedHlsManifest);
            } else if (this.selectedType === PlaybackType.DASH_MANIFEST && this.streamCategories?.dashManifest) {
              selection.dashManifest = this.getStreamByFriendlyQuality(this.streamCategories.dashManifest, this.selectedDashManifest);
            } else if (this.selectedType === PlaybackType.DASH_TRACKS) {
              if (this.streamCategories?.video) selection.dashVideo = this.getStreamByVideoLabel(this.streamCategories.video, this.selectedDashVideo);
              selection.dashAudio = this.getStreamByFriendlyQuality(this.filteredAudioStreams, this.selectedDashAudio)
                || (this.streamCategories?.audio ? this.getStreamByFriendlyQuality(this.streamCategories.audio, this.selectedDashAudio) : undefined);
            }
            this.onConfirm(selection);
            this.controller.close();
          })
      }.width('100%')
    }
    .width('90%').backgroundColor($r('app.color.yourtube_bg_surface')).borderRadius(24).shadow(ShadowStyle.OUTER_DEFAULT_MD)
  }

  @Builder SectionHeader(title: ResourceStr) {
    Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.yourtube_theme_primary')).width('100%').margin({ top: 12, bottom: 8 })
  }

  @Builder Selector(label: ResourceStr, streams: StreamInfo[], selectedValue: string, onSelect: (val: string) => void) {
    Column() {
      Text(label).fontSize(12).fontColor($r('app.color.yourtube_text_secondary')).width('100%').margin({ bottom: 4, top: 4 })
      Select(this.getOptionsFromStreams(streams))
        .value(selectedValue)
        .font({ size: 15 })
        .width('100%')
        .height(40)
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(8)
        .onSelect((index: number, value: string) => { onSelect(value); })
    }.width('100%')
  }

  @Builder SimpleSelector(label: ResourceStr, options: ResourceStr[], selectedValue: ResourceStr, onSelect: (val: ResourceStr) => void) {
    Column() {
      Text(label).fontSize(12).fontColor($r('app.color.yourtube_text_secondary')).width('100%').margin({ bottom: 4, top: 4 })
      Select(options.map(o => ({ value: o } as SelectOption)))
        .value(selectedValue)
        .font({ size: 15 })
        .width('100%')
        .height(40)
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(8)
        .onSelect((index: number, value: string) => { onSelect(value); })
    }.width('100%')
  }

  private getPlaybackTypeLabel(type: PlaybackType): ResourceStr {
    switch (type) {
      case PlaybackType.PROGRESSIVE: return $r('app.string.yt_player_mode_progressive');
      case PlaybackType.HLS: return $r('app.string.yt_player_mode_hls');
      case PlaybackType.DASH_MANIFEST: return $r('app.string.yt_player_mode_dash_manifest');
      case PlaybackType.DASH_TRACKS: return $r('app.string.yt_player_mode_dash_track');
      default: return '';
    }
  }

  private resourceToString(res: ResourceStr | null | undefined): string {
    if (res === null || res === undefined) return '';
    if (typeof res === 'string') return res;
    try {
      return getContext().resourceManager.getStringSync((res as Resource).id);
    } catch (e) {
      return '';
    }
  }

  private getDefaultTrackLabel(): string {
    return this.resourceToString($r('app.string.yt_player_default'));
  }

  private getAudioTrackLabel(stream: StreamInfo): string {
    return stream.audioTrackName || stream.audioLanguage || this.getDefaultTrackLabel();
  }

  private getAvailableTypeEnums(): PlaybackType[] {
    const types: PlaybackType[] = [];
    if (this.streamCategories?.progressive?.length) types.push(PlaybackType.PROGRESSIVE);
    if (this.streamCategories?.hlsManifest?.length) types.push(PlaybackType.HLS);
    if (this.streamCategories?.dashManifest?.length) types.push(PlaybackType.DASH_MANIFEST);
    if (this.streamCategories?.video?.length || this.streamCategories?.audio?.length) types.push(PlaybackType.DASH_TRACKS);
    return types;
  }

  private getAvailableTypes(): SelectOption[] {
    return this.getAvailableTypeEnums().map(t => ({ value: this.getPlaybackTypeLabel(t) } as SelectOption));
  }

  private getCodecPriority(stream: StreamInfo): number {
    const c = (stream.codecs || '').toLowerCase();
    // 优先级：H.265 (HEVC) > H.264 (AVC) > VP9 > AV1
    // 麒麟芯片对 H.264 硬解支持最成熟，优先选用
    // VP9 部分设备硬解支持有限，作为备选
    // AV1 目前缺乏硬解，软解发热功耗高，排最后
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return 4;  // H.265
    if (c.startsWith('avc1') || c.startsWith('avc3')) return 3;  // H.264 ← 提升至第2
    if (c.startsWith('vp9')  || c.startsWith('vp09')) return 2;  // VP9  ← 降至第3
    if (c.startsWith('av01'))                          return 1;  // AV1
    return 0;
  }

  private getCodecShortName(codecs?: string): string {
    if (!codecs) return '';
    const c = codecs.toLowerCase();
    if (c.startsWith('av01')) return 'AV1';
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 'VP9';
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return 'H.265';
    if (c.startsWith('avc1') || c.startsWith('avc3')) return 'H.264';
    const parts: string[] = codecs.split('.');
    return parts[0].toUpperCase();
  }

  private getVideoDisplayLabel(stream: StreamInfo): string {
    const resolution = stream.quality || '';
    const codec = this.getCodecShortName(stream.codecs);
    return codec ? `${resolution} (${codec})` : resolution;
  }

  private getDeduplicatedVideoStreams(streams: StreamInfo[]): StreamInfo[] {
    const orderedKeys: string[] = [];
    const bestMap = new Map<string, StreamInfo>();
    for (const stream of streams) {
      const key = stream.quality || '';
      const existing = bestMap.get(key);
      if (!existing) {
        bestMap.set(key, stream);
        orderedKeys.push(key);
      } else {
        const ep = this.getCodecPriority(existing);
        const np = this.getCodecPriority(stream);
        if (np > ep || (np === ep && (stream.bitrate || 0) > (existing.bitrate || 0))) {
          bestMap.set(key, stream);
        }
      }
    }
    return orderedKeys.map(key => bestMap.get(key) as StreamInfo);
  }

  private getVideoOptions(streams: StreamInfo[]): SelectOption[] {
    return this.getDeduplicatedVideoStreams(streams).map(s => ({ value: this.getVideoDisplayLabel(s) } as SelectOption));
  }

  private getStreamByVideoLabel(streams: StreamInfo[], label: string): StreamInfo | undefined {
    return this.getDeduplicatedVideoStreams(streams).find(s => this.getVideoDisplayLabel(s) === label);
  }

  private getOptionsFromStreams(streams: StreamInfo[]): SelectOption[] {
    return streams.map((stream): SelectOption => {
      const val = PlayerModel.getFriendlyQuality(stream);
      return { value: val } as SelectOption;
    });
  }

  private getStreamByFriendlyQuality(streams: StreamInfo[], quality: string): StreamInfo | undefined {
    return streams.find(s => PlayerModel.getFriendlyQuality(s) === quality);
  }

  private getAudioTracks(streams: StreamInfo[]): ResourceStr[] {
    const tracks = new Set<string>();
    streams.forEach(s => tracks.add(this.getAudioTrackLabel(s)));
    return Array.from(tracks);
  }

  private getFilteredAudioStreams(streams: StreamInfo[], overrideTrack?: ResourceStr): StreamInfo[] {
    const trackStr = this.resourceToString(overrideTrack || this.selectedAudioTrack) || this.getDefaultTrackLabel();
    return streams.filter(s => this.getAudioTrackLabel(s) === trackStr);
  }

  private updateFilteredAudioStreams(overrideTrack?: ResourceStr): void {
    if (this.streamCategories?.audio) {
      this.filteredAudioStreams = this.getFilteredAudioStreams(this.streamCategories.audio, overrideTrack);
    }
  }
}
