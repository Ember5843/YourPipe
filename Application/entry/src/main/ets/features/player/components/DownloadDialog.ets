import { StreamInfo, SelectOption, StreamCategories, PlayerModel } from 'mediaservice';
import { UIConfig } from '../../../common/AppState';

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

  streamCategories?: StreamCategories;
  videoId: string = '';
  videoTitle: string = '';
  videoAuthor: string = '';
  thumbnailUrl: string = '';

  @State selectedMode: DownloadMode = DownloadMode.PROGRESSIVE;
  @State selectedProgressive: string = '';
  @State selectedDashVideo: string = '';
  @State selectedDashAudio: string = '';
  @State selectedAudioTrack: ResourceStr = '';
  @State estimatedSize: string = '';

  @State audioTrackOptions: SelectOption[] = [];
  @State filteredAudioStreams: StreamInfo[] = [];

  private videoStreams: StreamInfo[] = [];

  onConfirm: (selection: DownloadSelection) => void = () => {};
  onCancel: () => void = () => {};

  aboutToAppear() {
    this.videoStreams = this.streamCategories?.video || [];

    if (this.streamCategories?.progressive && this.streamCategories.progressive.length > 0) {
      this.selectedMode = DownloadMode.PROGRESSIVE;
      this.selectedProgressive = this.getStreamLabel(this.streamCategories.progressive[0]);
    } else if (this.videoStreams.length > 0) {
      this.selectedMode = DownloadMode.DASH_TRACKS;
      this.selectedDashVideo = this.getStreamLabel(this.videoStreams[0]);
    }

    if (this.streamCategories?.audio && this.streamCategories.audio.length > 0) {
      const tracks = this.getAudioTrackLabels(this.streamCategories.audio);
      this.audioTrackOptions = tracks.map((track: ResourceStr) => ({ value: track } as SelectOption));
      if (tracks.length > 0) {
        this.selectedAudioTrack = tracks[0];
      }
      this.updateFilteredAudioStreams();
      if (this.filteredAudioStreams.length > 0) {
        this.selectedDashAudio = this.getStreamLabel(this.filteredAudioStreams[0]);
      }
    }

    this.updateEstimatedSize();
  }

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
          Column() {
            this.SectionHeader($r('app.string.yt_download_step1_mode'))
            Select(this.getModeOptions())
              .value(this.getModeLabel(this.selectedMode))
              .font({ size: 16 })
              .width('100%')
              .height(44)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .borderRadius(8)
              .onSelect((index: number) => {
                if (index === 0 && this.streamCategories?.progressive?.length) {
                  this.selectedMode = DownloadMode.PROGRESSIVE;
                  this.selectedProgressive = this.getStreamLabel(this.streamCategories.progressive[0]);
                } else {
                  this.selectedMode = DownloadMode.DASH_TRACKS;
                  if (this.videoStreams.length > 0) {
                    this.selectedDashVideo = this.getStreamLabel(this.videoStreams[0]);
                  }
                }
                this.updateEstimatedSize();
              })
          }
          .width('100%')

          Divider().margin({ top: 20, bottom: 10 }).color($r('sys.color.comp_divider'))

          if (this.selectedMode === DownloadMode.PROGRESSIVE && this.streamCategories?.progressive?.length) {
            Column() {
              this.SectionHeader($r('app.string.yt_download_step2_quality'))
              this.StreamSelector(
                $r('app.string.yt_label_progressive'),
                this.streamCategories.progressive,
                this.selectedProgressive,
                (value: string) => {
                  this.selectedProgressive = value;
                  this.updateEstimatedSize();
                }
              )
              Text($r('app.string.yt_download_progressive_hint'))
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
                .width('100%')
                .margin({ top: 4 })
            }
            .width('100%')
          }

          if (this.selectedMode === DownloadMode.DASH_TRACKS) {
            this.SectionHeader($r('app.string.yt_download_step2_tracks'))

            if (this.videoStreams.length > 0) {
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
                  .onSelect((_index: number, value: string) => {
                    this.selectedDashVideo = value;
                    this.updateEstimatedSize();
                  })
              }
              .width('100%')
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
                    .onSelect((_index: number, value: string) => {
                      this.selectedAudioTrack = value;
                      this.filteredAudioStreams = this.getFilteredAudioStreams(this.streamCategories!.audio, value);
                      if (this.filteredAudioStreams.length > 0) {
                        this.selectedDashAudio = this.getStreamLabel(this.filteredAudioStreams[0]);
                      }
                      this.updateEstimatedSize();
                    })
                }
                .width('100%')
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
                  .onSelect((_index: number, value: string) => {
                    this.selectedDashAudio = value;
                    this.updateEstimatedSize();
                  })
              }
              .width('100%')
            }

            Text($r('app.string.yt_download_dash_hint'))
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width('100%')
              .margin({ top: 4 })
          }

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
            const selection = this.getCurrentSelection();
            if (selection) {
              this.onConfirm(selection);
            }
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('85%')
    .constraintSize({ maxWidth: 460 })
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
    onSelect: (value: string) => void
  ) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .width('100%')
        .margin({ bottom: 4, top: 4 })
      Select(streams.map((stream: StreamInfo) => ({ value: this.getStreamLabel(stream) } as SelectOption)))
        .value(selectedValue)
        .font({ size: 15 })
        .width('100%')
        .height(40)
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .borderRadius(8)
        .onSelect((_index: number, value: string) => {
          onSelect(value);
        })
    }
    .width('100%')
  }

  private getModeOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    if (this.streamCategories?.progressive?.length) {
      options.push({ value: $r('app.string.yt_download_mode_progressive') } as SelectOption);
    }
    if (this.videoStreams.length > 0) {
      options.push({ value: $r('app.string.yt_download_mode_dash') } as SelectOption);
    }
    return options;
  }

  private getModeLabel(mode: DownloadMode): ResourceStr {
    return mode === DownloadMode.PROGRESSIVE
      ? $r('app.string.yt_download_mode_progressive')
      : $r('app.string.yt_download_mode_dash');
  }

  private getVideoOptions(): SelectOption[] {
    return this.videoStreams.map((stream: StreamInfo) => ({ value: this.getStreamLabel(stream) } as SelectOption));
  }

  private getAudioOptions(): SelectOption[] {
    return this.filteredAudioStreams.map((stream: StreamInfo) => ({ value: this.getStreamLabel(stream) } as SelectOption));
  }

  private getStreamByLabel(streams: StreamInfo[], label: string): StreamInfo | undefined {
    return streams.find((stream: StreamInfo) => this.getStreamLabel(stream) === label);
  }

  private getStreamLabel(stream: StreamInfo): string {
    const quality = stream.quality || stream.videoQuality || stream.audioQuality || PlayerModel.getFriendlyQuality(stream);
    const parts: string[] = [];
    if (quality) {
      parts.push(quality);
    }
    const codec = this.getCodecShortName(stream.codecs);
    if (codec) {
      parts.push(codec);
    }
    if (stream.fps) {
      parts.push(`${stream.fps}fps`);
    }
    if (stream.itag) {
      parts.push(`itag ${stream.itag}`);
    }
    if (stream.bitrate) {
      parts.push(`${Math.round(stream.bitrate / 1000)}kbps`);
    }
    if (stream.contentLength) {
      parts.push(this.formatSize(stream.contentLength));
    }
    return parts.length > 0 ? parts.join(' / ') : 'Unknown stream';
  }

  private getCodecShortName(codecs?: string): string {
    if (!codecs) return '';
    const codec = codecs.toLowerCase();
    if (codec.startsWith('av01')) return 'AV1';
    if (codec.startsWith('vp9') || codec.startsWith('vp09')) return 'VP9';
    if (codec.startsWith('hvc1') || codec.startsWith('hev1')) return 'H.265';
    if (codec.startsWith('avc1') || codec.startsWith('avc3')) return 'H.264';
    if (codec.startsWith('mp4a')) return 'AAC';
    if (codec.startsWith('opus')) return 'Opus';
    return codecs.split('.')[0].toUpperCase();
  }

  private getAudioTrackLabel(stream: StreamInfo): string {
    return stream.audioTrackName || stream.audioLanguage || 'Default';
  }

  private getAudioTrackLabels(streams: StreamInfo[]): ResourceStr[] {
    const tracks = new Set<string>();
    streams.forEach((stream: StreamInfo) => tracks.add(this.getAudioTrackLabel(stream)));
    return Array.from(tracks);
  }

  private getFilteredAudioStreams(streams: StreamInfo[], trackLabel?: ResourceStr): StreamInfo[] {
    const label = this.resourceToString(trackLabel || this.selectedAudioTrack) || 'Default';
    return streams.filter((stream: StreamInfo) => this.getAudioTrackLabel(stream) === label);
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
    } catch (_error) {
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
    if (selection.progressive) {
      totalBytes = selection.progressive.contentLength || 0;
    } else {
      totalBytes += selection.video?.contentLength || 0;
      totalBytes += selection.audio?.contentLength || 0;
    }
    this.estimatedSize = totalBytes > 0 ? this.formatSize(totalBytes) : 'Unknown';
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
      selection.progressive = this.getStreamByLabel(this.streamCategories?.progressive || [], this.selectedProgressive);
      return selection.progressive ? selection : null;
    }

    selection.video = this.getStreamByLabel(this.videoStreams, this.selectedDashVideo);
    selection.audio = this.getStreamByLabel(this.filteredAudioStreams, this.selectedDashAudio)
      || (this.streamCategories?.audio ? this.getStreamByLabel(this.streamCategories.audio, this.selectedDashAudio) : undefined);
    return selection.video ? selection : null;
  }
}
