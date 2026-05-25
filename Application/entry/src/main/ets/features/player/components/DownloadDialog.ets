import { StreamInfo, SelectOption, StreamCategories, PlayerModel } from 'mediaservice';
import { UIConfig } from '../../../common/AppState';
import { DownloadManager, DownloadTask } from '../../../common/DownloadManager';

export interface DownloadSelection {
  video?: StreamInfo;
  audio?: StreamInfo;
  progressive?: StreamInfo;
}

enum DownloadMode {
  PROGRESSIVE = 'PROGRESSIVE',
  DASH_TRACKS = 'DASH_TRACKS'
}

@CustomDialog
export struct DownloadDialog {
  controller: CustomDialogController;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  // 传入的数据
  streamCategories?: StreamCategories;
  videoId: string = '';
  videoTitle: string = '';
  videoAuthor: string = '';
  thumbnailUrl: string = '';

  // 选中状态
  @State selectedMode: DownloadMode = DownloadMode.PROGRESSIVE;
  @State selectedProgressive: string = '';
  @State selectedDashVideo: string = '';
  @State selectedDashAudio: string = '';
  @State selectedAudioTrack: ResourceStr = '';
  @State estimatedSize: string = '';
  @State showHighResWarning: boolean = false;

  @State audioTrackOptions: SelectOption[] = [];
  @State filteredAudioStreams: StreamInfo[] = [];

  // 视频流去重列表（用于查找）
  private dedupedVideoStreams: StreamInfo[] = [];

  aboutToAppear() {
    // 过滤高分辨率
    let videoStreams = this.streamCategories?.video || [];
    // 仅保留 1080p 及以下
    videoStreams = videoStreams.filter(s => (s.height || 0) <= 1080);

    // 去重视频流
    this.dedupedVideoStreams = this.deduplicateVideoStreams(videoStreams);

    // 默认选择
    if (this.streamCategories?.progressive && this.streamCategories.progressive.length > 0) {
      this.selectedMode = DownloadMode.PROGRESSIVE;
      this.selectedProgressive = PlayerModel.getFriendlyQuality(this.streamCategories.progressive[0]);
      this.updateEstimatedSize();
    } else if (this.dedupedVideoStreams.length > 0) {
      this.selectedMode = DownloadMode.DASH_TRACKS;
      this.selectedDashVideo = this.getVideoDisplayLabel(this.dedupedVideoStreams[0]);
    }

    if (this.streamCategories?.audio && this.streamCategories.audio.length > 0) {
      const tracks = this.getAudioTrackLabels(this.streamCategories.audio);
      if (tracks.length > 0) {
        this.selectedAudioTrack = tracks[0];
        this.updateFilteredAudioStreams();
        if (this.filteredAudioStreams.length > 0) {
          this.selectedDashAudio = PlayerModel.getFriendlyQuality(this.filteredAudioStreams[0]);
        }
      }
      this.audioTrackOptions = tracks.map(t => ({ value: t } as SelectOption));
    }

    this.updateEstimatedSize();
  }

  onConfirm: (selection: DownloadSelection) => void = () => {
  };
  onCancel: () => void = () => {
  };

  build() {
    Column() {
      Text($r('app.string.yt_download_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 24, bottom: 12 })

      Scroll() {
        Column() {
          // 播放类型选择
          Column() {
            this.SectionHeader($r('app.string.yt_download_step1_mode'))
            Select(this.getModeOptions())
              .value(this.getModeLabel(this.selectedMode))
              .font({ size: 16 })
              .width('100%')
              .height(44)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .borderRadius(8)
              .onSelect((index: number, value: string) => {
                if (index === 0) {
                  this.selectedMode = DownloadMode.PROGRESSIVE;
                  if (this.streamCategories?.progressive?.length) {
                    this.selectedProgressive = PlayerModel.getFriendlyQuality(
                      this.streamCategories.progressive[0]);
                  }
                } else {
                  this.selectedMode = DownloadMode.DASH_TRACKS;
                  if (this.dedupedVideoStreams.length > 0) {
                    this.selectedDashVideo = this.getVideoDisplayLabel(this.dedupedVideoStreams[0]);
                  }
                }
                this.updateEstimatedSize();
              })
          }

          Divider().margin({ top: 20, bottom: 10 }).color($r('sys.color.comp_divider'))

          // 质量选择
          if (this.selectedMode === DownloadMode.PROGRESSIVE && this.streamCategories?.progressive?.length) {
            Column() {
              this.SectionHeader($r('app.string.yt_download_step2_quality'))
              this.StreamSelector(
                $r('app.string.yt_label_progressive'),
                this.streamCategories.progressive,
                this.selectedProgressive,
                (val) => {
                  this.selectedProgressive = val;
                  this.updateEstimatedSize();
                }
              )
            }.width('100%')
            Text($r('app.string.yt_download_progressive_hint'))
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width('100%')
              .margin({ top: 4 })
          }

          if (this.selectedMode === DownloadMode.DASH_TRACKS) {
            this.SectionHeader($r('app.string.yt_download_step2_tracks'))

            if (this.dedupedVideoStreams.length > 0) {
              Column() {
                Text($r('app.string.yt_label_video_track'))
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .width('100%')
                  .margin({ bottom: 4, top: 4 })
                Select(this.getVideoOptions())
                  .value(this.selectedDashVideo)
                  .font({ size: 15 })
                  .width('100%')
                  .height(40)
                  .backgroundColor($r('app.color.yourtube_bg_page'))
                  .borderRadius(8)
                  .onSelect((index: number, value: string) => {
                    this.selectedDashVideo = value;
                    this.updateEstimatedSize();
                  })
              }.width('100%')
            }

            if (this.streamCategories?.audio && this.streamCategories.audio.length > 0) {
              if (this.audioTrackOptions.length > 1) {
                Column() {
                  Text($r('app.string.yt_player_audio_language_type'))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_secondary'))
                    .width('100%')
                    .margin({ bottom: 4, top: 8 })
                  Select(this.audioTrackOptions)
                    .value(this.selectedAudioTrack)
                    .font({ size: 15 })
                    .width('100%')
                    .height(40)
                    .backgroundColor($r('app.color.yourtube_bg_page'))
                    .borderRadius(8)
                    .onSelect((index: number, value: string) => {
                      this.selectedAudioTrack = value;
                      const freshFiltered = this.getFilteredAudioStreams(
                        this.streamCategories!.audio, value);
                      this.filteredAudioStreams = freshFiltered;
                      if (freshFiltered.length > 0) {
                        this.selectedDashAudio = PlayerModel.getFriendlyQuality(freshFiltered[0]);
                      }
                      this.updateEstimatedSize();
                    })
                }.width('100%')
              }

              Column() {
                Text($r('app.string.yt_label_audio_quality'))
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .width('100%')
                  .margin({ bottom: 4, top: 4 })
                Select(this.getAudioOptions())
                  .value(this.selectedDashAudio)
                  .font({ size: 15 })
                  .width('100%')
                  .height(40)
                  .backgroundColor($r('app.color.yourtube_bg_page'))
                  .borderRadius(8)
                  .onSelect((index: number, value: string) => {
                    this.selectedDashAudio = value;
                    this.updateEstimatedSize();
                  })
              }.width('100%')
            }

            Text($r('app.string.yt_download_dash_hint'))
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width('100%')
              .margin({ top: 4 })
          }

          // 预计大小
          if (this.estimatedSize) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.doc'))
                .fontSize(14)
                .fontColor([$r('app.color.yourtube_text_secondary')])
              Text(`${$r('app.string.yt_download_estimated_size')}: ${this.estimatedSize}`)
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_secondary'))
            }
            .width('100%')
            .padding({ top: 12 })
          }
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: '60%' })
      .padding({ left: 24, right: 24, bottom: 24 })

      // 底部按钮
      Row() {
        Text($r('app.string.yt_action_cancel'))
          .fontSize(16)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(56)
          .onClick(() => {
            this.onCancel();
            this.controller.close();
          })
        Divider().vertical(true).height(24).color($r('sys.color.comp_divider'))
        Text($r('app.string.yt_action_download'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_theme_primary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(56)
          .onClick(() => {
            const selection: DownloadSelection = {};
            if (this.selectedMode === DownloadMode.PROGRESSIVE) {
              selection.progressive = this.getStreamByFriendlyQuality(
                this.streamCategories!.progressive, this.selectedProgressive);
            } else {
              selection.video = this.getStreamByVideoLabel(
                this.dedupedVideoStreams, this.selectedDashVideo);
              selection.audio = this.getStreamByFriendlyQuality(
                this.filteredAudioStreams, this.selectedDashAudio)
                || (this.streamCategories?.audio
                  ? this.getStreamByFriendlyQuality(this.streamCategories.audio, this.selectedDashAudio)
                  : undefined);
            }
            this.onConfirm(selection);
            this.controller.close();
          })
      }.width('100%')
    }
    .width('90%')
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(24)
    .shadow(ShadowStyle.OUTER_DEFAULT_MD)
  }

  @Builder
  SectionHeader(title: ResourceStr) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.yourtube_theme_primary'))
      .width('100%')
      .margin({ top: 12, bottom: 8 })
  }

  @Builder
  StreamSelector(
    label: ResourceStr,
    streams: StreamInfo[],
    selectedValue: string,
    onSelect: (val: string) => void
  ) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .width('100%')
        .margin({ bottom: 4, top: 4 })
      Select(streams.map(s => ({ value: PlayerModel.getFriendlyQuality(s) } as SelectOption)))
        .value(selectedValue)
        .font({ size: 15 })
        .width('100%')
        .height(40)
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(8)
        .onSelect((index: number, value: string) => {
          onSelect(value);
        })
    }.width('100%')
  }

  // ── Helper 方法 ──

  private getModeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    if (this.streamCategories?.progressive?.length) {
      options.push({ value: $r('app.string.yt_download_mode_progressive') } as SelectOption);
    }
    if (this.dedupedVideoStreams.length > 0) {
      options.push({ value: $r('app.string.yt_download_mode_dash') } as SelectOption);
    }
    return options;
  }

  private getModeLabel(mode: DownloadMode): ResourceStr {
    return mode === DownloadMode.PROGRESSIVE
      ? $r('app.string.yt_download_mode_progressive')
      : $r('app.string.yt_download_mode_dash');
  }

  private getCodecShortName(codecs?: string): string {
    if (!codecs) return '';
    const c = codecs.toLowerCase();
    if (c.startsWith('av01')) return 'AV1';
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 'VP9';
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return 'H.265';
    if (c.startsWith('avc1') || c.startsWith('avc3')) return 'H.264';
    return codecs.split('.')[0].toUpperCase();
  }

  private getCodecPriority(stream: StreamInfo): number {
    const c = (stream.codecs || '').toLowerCase();
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return 4;
    if (c.startsWith('avc1') || c.startsWith('avc3')) return 3;
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 2;
    if (c.startsWith('av01')) return 1;
    return 0;
  }

  private getVideoDisplayLabel(stream: StreamInfo): string {
    const resolution = stream.quality || '';
    const codec = this.getCodecShortName(stream.codecs);
    return codec ? `${resolution} (${codec})` : resolution;
  }

  private deduplicateVideoStreams(streams: StreamInfo[]): StreamInfo[] {
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

  private getVideoOptions(): SelectOption[] {
    return this.dedupedVideoStreams.map(s =>
      ({ value: this.getVideoDisplayLabel(s) } as SelectOption));
  }

  private getAudioOptions(): SelectOption[] {
    return this.filteredAudioStreams.map(s =>
      ({ value: PlayerModel.getFriendlyQuality(s) } as SelectOption));
  }

  private getStreamByVideoLabel(streams: StreamInfo[], label: string): StreamInfo | undefined {
    return streams.find(s => this.getVideoDisplayLabel(s) === label);
  }

  private getStreamByFriendlyQuality(streams: StreamInfo[], quality: string): StreamInfo | undefined {
    return streams.find(s => PlayerModel.getFriendlyQuality(s) === quality);
  }

  private getAudioTrackLabel(stream: StreamInfo): string {
    return stream.audioTrackName || stream.audioLanguage || '默认';
  }

  private getAudioTrackLabels(streams: StreamInfo[]): ResourceStr[] {
    const tracks = new Set<string>();
    streams.forEach(s => tracks.add(this.getAudioTrackLabel(s)));
    return Array.from(tracks);
  }

  private getFilteredAudioStreams(streams: StreamInfo[], trackLabel?: ResourceStr): StreamInfo[] {
    const label = this.resourceToString(trackLabel || this.selectedAudioTrack) || '默认';
    return streams.filter(s => this.getAudioTrackLabel(s) === label);
  }

  private updateFilteredAudioStreams(): void {
    if (this.streamCategories?.audio) {
      this.filteredAudioStreams = this.getFilteredAudioStreams(this.streamCategories.audio);
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

  private updateEstimatedSize(): void {
    const selection = this.getCurrentSelection();
    if (!selection) {
      this.estimatedSize = '';
      return;
    }
    let totalBytes = 0;
    if (this.selectedMode === DownloadMode.PROGRESSIVE && selection.progressive) {
      totalBytes = selection.progressive.contentLength || 0;
    } else {
      if (selection.video) totalBytes += selection.video.contentLength || 0;
      if (selection.audio) totalBytes += selection.audio.contentLength || 0;
    }
    this.estimatedSize = totalBytes > 0 ? this.formatSize(totalBytes) : '(未知)';
  }

  private formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
  }

  private getCurrentSelection(): DownloadSelection | null {
    const selection: DownloadSelection = {};
    if (this.selectedMode === DownloadMode.PROGRESSIVE) {
      selection.progressive = this.getStreamByFriendlyQuality(
        this.streamCategories?.progressive || [], this.selectedProgressive);
      return selection.progressive ? selection : null;
    } else {
      selection.video = this.getStreamByVideoLabel(
        this.dedupedVideoStreams, this.selectedDashVideo);
      selection.audio = this.getStreamByFriendlyQuality(
        this.filteredAudioStreams, this.selectedDashAudio)
        || (this.streamCategories?.audio
          ? this.getStreamByFriendlyQuality(this.streamCategories.audio, this.selectedDashAudio)
          : undefined);
      return selection.video ? selection : null;
    }
  }
}
