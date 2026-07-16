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
import { CommonConstants as Const, Logger, StreamInfo, StreamCategories } from 'mediaservice';
import { LengthMetrics } from '@kit.ArkUI';
import { ErrorPage } from '../../../common/components/ErrorPage';
import { TabErrorPanel } from '../../../common/components/TabErrorPanel';
import { SearchChannelItem } from 'youtube_core';
import { ChannelInfoService } from '../../user/ChannelInfoService';
import { VideoItem } from 'youtube_core';
import { SubscriptionUser } from '../../../common/SubscriptionModel';
import { ChannelCard } from '../../user/components/ChannelCard';
import { DownloadDialog, DownloadSelection } from './DownloadDialog';
import { SavePlaylistSheet } from './SavePlaylistSheet';
import { DownloadManager, DownloadTask } from '../../../common/DownloadManager';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { LanguageManager } from '../../../common/LanguageManager';
import { ActionHub } from '../../../common/ActionHub';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import common from '@ohos.app.ability.common';
import { PlayerSession, CachedChannelProfile } from '../../../common/PlayerSession';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';

const TAG: string = '[VideoDetails]';

@Component
export struct VideoDetails {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop @Watch('onItemChanged') item: VideoItem;
  @Prop videoDescription: string = '';
  @Prop videoDescriptionError: string = '';
  @Prop streams: StreamInfo[] = [];
  @Prop viewCount: number = 0;
  @Prop likeCount: string = '0';
  @Prop dislikeCount: string = '0';
  @Prop publishDate: string = '';
  @Prop tags: string[] = [];
  @Prop @Watch('onChannelIdentityChanged') channelId: string = '';
  @Prop @Watch('onChannelIdentityChanged') channelAvatarUrl: string = '';
  @State isTitleExpanded: boolean = false;
  @State channelInfo: SearchChannelItem = new SearchChannelItem(
          0,
          this.item.channelId || '',
          this.item.author || '',
          '0 subscribers',
          '0 videos',
          this.item.channelAvatarUrl || '',
          '',
          '#CCCCCC'
        )
  @State channelInfoError: ResourceStr | null = null;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  onRetryDescription?: () => void = undefined;
  private channelInfoService: ChannelInfoService | null = null;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  private streamCategories: StreamCategories | null = null;
  private downloadDialogController: CustomDialogController | null = null;
  private descSkeletonTimer: number = -1;
  private sleepTimerUiInterval: number = -1;
  @State descSkeletonOpacity: number = 0.3;
  @State sleepTimerRemainingMinutes: number = 0;
  @State showSavePlaylistSheet: boolean = false;
  @State showStreamInfoSheet: boolean = false;
  @State showSleepTimerSheet: boolean = false;
  /** 0=none, 1=save, 2=streaminfo, 3=sleep. Drives single bindSheet content. */
  @State activeSheet: number = 0;
  /** Single bindSheet visibility. Replaces the 3 separate bindSheet bindings. */
  @State sheetVisible: boolean = false;
  // TimePicker 选择的时间（时/分），仅作为「多久后停止」的时长输入，无系统当前时刻展示。
  @State sleepPickerDate: Date = new Date(0, 0, 0, 0, 30, 0, 0);
  /** 会话级仅音频（封面层 + 关视频轨） */
  @StorageLink('isAudioOnlyMode') isAudioOnlyMode: boolean = false;

  // ── mpv 实时播放流信息（由 PlayerPage 从 vm 传入）──
  @Prop mpvVideoWidth: number = 0;
  @Prop mpvVideoHeight: number = 0;
  @Prop mpvContainerFormat: string = '';
  @Prop mpvMediaTitle: string = '';
  @Prop mpvVideoCodec: string = '';
  @Prop mpvVideoBitRate: number = 0;
  @Prop mpvFrameRate: number = 0;
  @Prop mpvAudioCodec: string = '';
  @Prop mpvAudioBitRate: number = 0;
  @Prop mpvAudioChannels: number = 0;
  @Prop mpvAudioSampleRate: number = 0;
  @Prop mpvFileSize: number = 0;
  @Prop mpvDuration: number = 0;

  private getEffectiveDesc(): string {
    return (this.videoDescription ?? this.item?.videoDescription) || '';
  }

  private getEffectiveError(): string | undefined {
    if (this.videoDescriptionError.length > 0) {
      return this.videoDescriptionError;
    }
    return this.item?.videoDescriptionError || undefined;
  }

  private formatViewCount(count: number): string {
    if (!count) return '';
    const language = LanguageManager.normalizeLanguageCode(
      LanguageManager.resolveAppliedLanguage(this.uiConfig));
    if (language === LanguageManager.LANGUAGE_ZH_HANS) {
      if (count >= 100000000) return `${(count / 100000000).toFixed(1)}亿`;
      if (count >= 10000) return `${(count / 10000).toFixed(1)}万`;
      if (count >= 1000) return `${(count / 1000).toFixed(1)}千`;
      return count.toLocaleString();
    }
    if (language === LanguageManager.LANGUAGE_ZH_HK
      || language === LanguageManager.LANGUAGE_ZH_TW) {
      if (count >= 100000000) return `${(count / 100000000).toFixed(1)}億`;
      if (count >= 10000) return `${(count / 10000).toFixed(1)}萬`;
      if (count >= 1000) return `${(count / 1000).toFixed(1)}千`;
      return count.toLocaleString();
    }
    if (count >= 1000000000) return `${(count / 1000000000).toFixed(1)}B`;
    if (count >= 1000000) return `${(count / 1000000).toFixed(1)}M`;
    if (count >= 1000) return `${(count / 1000).toFixed(1)}K`;
    return count.toLocaleString();
  }

  private formatStatCount(value: string): string {
    const normalized = (value || '').trim();
    // Preserve already-localized values such as "1.2K" or text returned by YouTube.
    if (!/^[0-9,.\s]+$/.test(normalized)) {
      return normalized;
    }
    const parsed = Number(normalized.replace(/[,\s]/g, ''));
    if (!Number.isFinite(parsed) || parsed <= 0) {
      return normalized;
    }
    return this.formatViewCount(parsed);
  }

  private formatRelativeDate(dateStr: string): string {
    if (!dateStr) return '';
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    const rm = getContext().resourceManager;
    if (diffDays < 1) return rm.getStringSync($r('app.string.yt_date_today').id);
    if (diffDays < 7) return rm.getStringSync($r('app.string.yt_date_days_ago').id, diffDays);
    if (diffDays < 30) return rm.getStringSync($r('app.string.yt_date_weeks_ago').id, Math.floor(diffDays / 7));
    if (diffDays < 365) return rm.getStringSync($r('app.string.yt_date_months_ago').id, Math.floor(diffDays / 30));
    return rm.getStringSync($r('app.string.yt_date_years_ago').id, Math.floor(diffDays / 365));
  }

  aboutToAppear() {
    this.channelInfoService = new ChannelInfoService();
    this.resetForCurrentItem();
    this.classifyStreamsForDownload();
    this.startSleepTimerUiUpdates();

    if (this.getEffectiveDesc().length === 0) {
      this.descSkeletonTimer = setInterval(() => {
        this.descSkeletonOpacity = this.descSkeletonOpacity === 0.3 ? 0.7 : 0.3;
      }, 800);
    }
  }

  aboutToDisappear() {
    if (this.descSkeletonTimer >= 0) {
      clearInterval(this.descSkeletonTimer);
    }
    if (this.sleepTimerUiInterval >= 0) {
      clearInterval(this.sleepTimerUiInterval);
      this.sleepTimerUiInterval = -1;
    }
  }

  private startSleepTimerUiUpdates(): void {
    if (this.sleepTimerUiInterval >= 0) {
      clearInterval(this.sleepTimerUiInterval);
    }
    this.syncSleepTimerUi();
    this.sleepTimerUiInterval = setInterval(() => this.syncSleepTimerUi(), 1000);
  }

  private syncSleepTimerUi(): void {
    this.sleepTimerRemainingMinutes = PlayerSession.getInstance().sleepTimerRemainingMinutes;
  }

  private formatSleepTimerRemaining(): string {
    const hours = Math.floor(this.sleepTimerRemainingMinutes / 60);
    const minutes = this.sleepTimerRemainingMinutes % 60;
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}`;
  }

  private onItemChanged(): void {
    this.isTitleExpanded = false;
    this.resetForCurrentItem();
    this.classifyStreamsForDownload();
  }

  private onChannelIdentityChanged(): void {
    this.resetForCurrentItem();
  }

  private resetForCurrentItem(): void {
    this.channelInfoError = null;
    const effectiveChannelId = this.channelId || this.item?.channelId || '';
    const effectiveAvatarUrl = this.channelAvatarUrl || this.item?.channelAvatarUrl || '';
    this.channelInfo = new SearchChannelItem(
      0,
      effectiveChannelId,
      this.item?.author || '',
      '0 subscribers',
      '0 videos',
      effectiveAvatarUrl,
      '',
      '#CCCCCC'
    );

    if (!effectiveChannelId) {
      return;
    }

    const channelId = effectiveChannelId;
    const cached = PlayerSession.getInstance().getCachedChannelProfile(channelId);
    if (cached) {
      this.channelInfo = new SearchChannelItem(
        0,
        channelId,
        cached.name || this.item.author || '',
        cached.subscriberText || '0 subscribers',
        cached.videoCountText || '0 videos',
        cached.avatarUrl || effectiveAvatarUrl,
        cached.description || '',
        '#CCCCCC'
      );
      return;
    }

    setTimeout(() => {
      const currentChannelId = this.channelId || this.item?.channelId || '';
      if (currentChannelId === channelId) {
        this.fetchChannelInfo();
      }
    }, 1500);
  }

  private classifyStreamsForDownload(): void {
    const categories: StreamCategories = {
      audio: [],
      video: [],
      dashManifest: [],
      hlsManifest: [],
      progressive: []
    };

    if (!this.streams || this.streams.length === 0) {
      this.streamCategories = categories;
      return;
    }

    this.streams.forEach((stream: StreamInfo) => {
      const kind = (stream.kind || '').toLowerCase();
      const delivery = (stream.deliveryMethod || '').toUpperCase();
      const isSabr = delivery === 'SABR' || kind === 'sabr' || !!stream.sabrInfo?.serverAbrStreamingUrl;
      // Progressive/HLS need a media URL; SABR uses sabrInfo bootstrap (isUrl=false).
      if (!isSabr && !stream.url) {
        return;
      }
      if (isSabr && (!stream.sabrInfo || !stream.sabrInfo.serverAbrStreamingUrl)) {
        return;
      }

      const mimeType = (stream.mimeType || '').toLowerCase();
      const codecs = (stream.codecs || '').toLowerCase();
      const hasVideo = stream.hasVideo === true
        || !!stream.width
        || !!stream.height
        || !!stream.videoQuality
        || mimeType.startsWith('video/');
      const hasAudio = stream.hasAudio === true
        || !!stream.audioQuality
        || !!stream.audioLanguage
        || !!stream.audioTrackName
        || mimeType.startsWith('audio/')
        || codecs.includes('mp4a')
        || codecs.includes('opus');

      if (kind === 'manifest_hls' || delivery === 'HLS') {
        categories.hlsManifest.push(stream);
      } else if (kind === 'manifest_dash') {
        categories.dashManifest.push(stream);
      } else if (!isSabr && (kind === 'progressive' || delivery === 'PROGRESSIVE_HTTP' || (hasVideo && hasAudio))) {
        categories.progressive.push(stream);
      } else if (kind === 'video_only' || hasVideo) {
        categories.video.push(stream);
      } else if (kind === 'audio_only' || hasAudio) {
        categories.audio.push(stream);
      }
    });

    categories.video.sort((a: StreamInfo, b: StreamInfo): number => (b.height || 0) - (a.height || 0));
    categories.audio.sort((a: StreamInfo, b: StreamInfo): number => (b.bitrate || 0) - (a.bitrate || 0));
    categories.progressive.sort((a: StreamInfo, b: StreamInfo): number => (b.height || 0) - (a.height || 0));
    this.streamCategories = categories;
  }

  private openDownloadDialog(): void {
    this.classifyStreamsForDownload();
    if (!this.streamCategories ||
      (this.streamCategories.video.length === 0 &&
        this.streamCategories.progressive.length === 0 &&
        this.streamCategories.hlsManifest.length === 0)) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.yt_error_no_downloadable_stream') });
      return;
    }

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.downloadManager.setContext(ctx);

    const categories = this.streamCategories;

    this.downloadDialogController = new CustomDialogController({
      builder: DownloadDialog({
        streamCategories: categories,
        videoId: this.item.videoId,
        videoTitle: this.item.title,
        videoAuthor: this.item.author,
        thumbnailUrl: this.item.thumbnailUrl,
        onConfirm: (selection: DownloadSelection) => {
          const taskId = `dl_${Date.now()}_${this.item.videoId}`;
          let videoStream: StreamInfo;
          let audioStream: StreamInfo | null = null;

          if (selection.progressive) {
            videoStream = selection.progressive;
          } else if (selection.hls) {
            videoStream = selection.hls;
          } else if (selection.sabr && selection.video && selection.audio) {
            videoStream = selection.video;
            audioStream = selection.audio;
          } else if (selection.video) {
            videoStream = selection.video;
            audioStream = selection.audio || null;
          } else {
            return;
          }

          const task = new DownloadTask(
            taskId,
            this.item.videoId,
            this.item.title,
            this.item.author,
            this.item.thumbnailUrl,
            videoStream,
            audioStream
          );
          task._context = ctx;
          this.downloadManager.addTask(task);
        },
        onCancel: () => {}
      }),
      alignment: DialogAlignment.Center,
      customStyle: true,
      autoCancel: true,
    });
    this.downloadDialogController?.open();
  }

  private async fetchChannelInfo() {
    const channelId = (this.channelId || this.item.channelId || '').trim();
    const avatarUrl = this.channelAvatarUrl || this.item.channelAvatarUrl || '';
    Logger.debug(TAG, `[fetchChannelInfo] Starting, channelId=${channelId}`);
    // Channel browse requires UC… ids; empty / non-channel ids only produce 400 noise.
    if (!channelId || !channelId.startsWith('UC') || !this.channelInfoService) {
      if (channelId && !channelId.startsWith('UC')) {
        Logger.warn(TAG, `[fetchChannelInfo] skip non-channel id: ${channelId}`);
      }
      return;
    }

    try {
      const profile = await this.channelInfoService.fetchChannelProfile(channelId);
      if (profile) {
        this.channelInfo = new SearchChannelItem(
          0,
          channelId,
          profile.name || this.item.author || '',
          profile.subscriberText || '0 subscribers',
          profile.videoCountText || '0 videos',
          profile.avatarUrl || avatarUrl,
          profile.description || '',
          '#CCCCCC'
        );
        this.channelInfoError = null;
        const cacheEntry: CachedChannelProfile = {
          name: profile.name || '',
          subscriberText: profile.subscriberText || '',
          videoCountText: profile.videoCountText || '',
          avatarUrl: profile.avatarUrl || '',
          description: profile.description || ''
        };
        PlayerSession.getInstance().setCachedChannelProfile(channelId, cacheEntry);
      } else {
        this.channelInfoError = $r('app.string.yt_error_load_channel_info');
      }
    } catch (error) {
      Logger.error(TAG, `[fetchChannelInfo] Failed: ${error}`);
      this.channelInfoError = (error as Error).message || $r('app.string.yt_error_load_channel_info');
    }
  }

  private hasLikeCount(): boolean {
    return !!(this.likeCount && this.likeCount !== '0' && this.likeCount.length > 0);
  }

  private hasDislikeCount(): boolean {
    return !!(this.dislikeCount && this.dislikeCount !== '0' && this.dislikeCount.length > 0);
  }

  private hasStatsRow(): boolean {
    return this.viewCount > 0
      || !!(this.publishDate && this.publishDate.length > 0)
      || this.hasLikeCount()
      || this.hasDislikeCount();
  }

  private formatBitrate(bps: number): string {
    if (bps >= 1000000) return `${(bps / 1000000).toFixed(2)} Mbps`;
    if (bps >= 1000) return `${(bps / 1000).toFixed(0)} kbps`;
    return `${bps} bps`;
  }

  private formatFileSize(bytes: number): string {
    if (bytes >= 1073741824) return `${(bytes / 1073741824).toFixed(2)} GB`;
    if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MB`;
    if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
    return `${bytes} B`;
  }

  private formatChannels(ch: number): string {
    if (ch === 1) return 'Mono (1.0)';
    if (ch === 2) return 'Stereo (2.0)';
    if (ch === 6) return '5.1';
    if (ch === 8) return '7.1';
    return `${ch} channels`;
  }

  private formatDuration(sec: number): string {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = Math.floor(sec % 60);
    const mm = m.toString().padStart(2, '0');
    const ss = s.toString().padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
  }

  @Builder
  StatsMetaRow() {
    // Title-adjacent stats: views / date / like / dislike as one compact strip.
    Row({ space: 0 }) {
      if (this.viewCount > 0) {
        this.StatItem($r('sys.symbol.play_round_rectangle'),
          $r('app.string.yt_views_count_format', this.formatViewCount(this.viewCount)), false)
      }
      if (this.publishDate && this.publishDate.length > 0) {
        this.StatItem($r('sys.symbol.calendar'), this.formatRelativeDate(this.publishDate), this.viewCount > 0)
      }
      if (this.hasLikeCount()) {
        this.StatItem(
          $r('sys.symbol.hand_thumbsup'),
          this.formatStatCount(this.likeCount),
          this.viewCount > 0 || !!(this.publishDate && this.publishDate.length > 0)
        )
      }
      if (this.hasDislikeCount()) {
        this.StatItem(
          $r('sys.symbol.hand_thumbsdown'),
          this.formatStatCount(this.dislikeCount),
          this.viewCount > 0
            || !!(this.publishDate && this.publishDate.length > 0)
            || this.hasLikeCount()
        )
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_player_info_bg'))
    .margin({ top: 8, bottom: 12 })
  }

  @Builder
  StatItem(icon: Resource, label: ResourceStr, showDivider: boolean) {
    if (showDivider) {
      Text('·')
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_hint'))
        .margin({ left: 8, right: 8 })
    }
    Row({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(13)
        .fontColor([$r('app.color.yourtube_text_secondary')])
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(VerticalAlign.Center)
    .constraintSize({ maxWidth: '42%' })
  }

  @Builder
  ActionButtonRow() {
    Scroll() {
      Row({ space: 10 }) {
        this.SleepTimerActionButton()
        this.ActionButton($r('sys.symbol.arrowshape_down_to_line_fill'),
          $r('app.string.yt_action_download'), () => { this.openDownloadDialog(); })
        this.ActionButton($r('sys.symbol.info_circle'),
          $r('app.string.yt_stream_info_title'), () => { this.openSheet(2); })
        this.ActionButton($r('sys.symbol.bookmark'),
          $r('app.string.yt_action_save_to_playlist'), () => { this.openSheet(1); })
        this.AudioOnlyActionButton()
        this.ActionButton($r('sys.symbol.share'),
          $r('app.string.yt_action_share'), () => { this.shareVideo(); })
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(36)
    .margin({ bottom: 14 })
  }

  @Builder
  AudioOnlyActionButton() {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.earphone'))
          .fontSize(14)
          .fontColor([this.isAudioOnlyMode
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary')])
          .fontWeight(this.isAudioOnlyMode ? FontWeight.Bold : FontWeight.Normal)
        Text($r('app.string.yt_action_audio_only'))
          .fontSize(13)
          .fontColor(this.isAudioOnlyMode
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
      }
    }
    .height(36)
    .backgroundColor(this.isAudioOnlyMode
      ? $r('app.color.yourtube_player_info_bg')
      : $r('app.color.yourtube_player_control_bg'))
    .borderRadius(18)
    .padding({ left: 14, right: 14 })
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => { this.toggleAudioOnlyMode(); })
  }

  @Builder
  SleepTimerActionButton() {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.timer'))
          .fontSize(14)
          .fontColor([this.sleepTimerRemainingMinutes > 0
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary')])
          .fontWeight(this.sleepTimerRemainingMinutes > 0 ? FontWeight.Bold : FontWeight.Normal)
        Text(this.sleepTimerRemainingMinutes > 0
          ? this.formatSleepTimerRemaining()
          : $r('app.string.yt_action_sleep_timer'))
          .fontSize(13)
          .fontColor(this.sleepTimerRemainingMinutes > 0
            ? this.themePrimary
            : $r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
      }
    }
    .height(36)
    .backgroundColor(this.sleepTimerRemainingMinutes > 0
      ? $r('app.color.yourtube_player_info_bg')
      : $r('app.color.yourtube_player_control_bg'))
    .borderRadius(18)
    .padding({ left: 14, right: 14 })
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => { this.openSleepTimerPicker(); })
  }

  @Builder
  ActionButton(icon: Resource, label: ResourceStr, action: () => void) {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(14)
          .fontColor([$r('app.color.yourtube_text_primary')])
        Text(label)
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
      }
    }
    .height(36)
    .backgroundColor($r('app.color.yourtube_player_control_bg'))
    .borderRadius(18)
    .padding({ left: 14, right: 14 })
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => { action(); })
  }

  build() {
    Scroll() {
      Column() {
        // ── 标题 ──
        Column() {
          Text(this.item.title)
            .fontSize($r('app.float.font_size_18'))
            .fontColor($r('app.color.yourtube_text_primary'))
            .maxLines(this.isTitleExpanded ? undefined : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(26)
            .fontWeight(FontWeight.Bold)

          if (!this.isTitleExpanded && this.item.title.length > 60) {
            Text($r('app.string.yt_action_show_more'))
              .fontSize($r('app.float.font_size_12'))
              .fontColor(this.themePrimary)
              .margin({ top: 4 })
          }
        }
        .onClick(() => { this.isTitleExpanded = !this.isTitleExpanded; })
        .alignItems(HorizontalAlign.Start)

        // ── 统计信息：观看 / 发布时间 / 点赞 / 点踩 ──
        if (this.hasStatsRow()) {
          this.StatsMetaRow()
        } else {
          Column().height(12)
        }

        // ── 频道信息行（不修改）──
        if (this.channelInfoError) {
          TabErrorPanel({
            errorMessage: this.channelInfoError,
            showRetry: true,
            onRetry: () => { this.fetchChannelInfo(); }
          })
        } else {
          ChannelCard({
            channel: this.channelInfo,
            typeLabel: '',
            showDescription: false
          })
            .margin({ bottom: 12 })
        }

        // ── 功能按钮行（横向滚动 + 渐变遮罩）──
        this.ActionButtonRow()

        // ── 视频描述（完整显示）──
        this.DescriptionSection()

        // ── 视频标签 ──
        if (this.tags && this.tags.length > 0) {
          this.TagsSection()
        }
      }
      .width('100%')
    }
    .edgeEffect(EdgeEffect.Spring)
    .width(Const.WIDTH_FULL_PERCENT)
    .padding({
      top: $r('app.float.padding_12'),
      bottom: 24,
      left: $r('app.float.padding_16'),
      right: $r('app.float.padding_16'),
    })
    .bindSheet($$this.sheetVisible, this.ActiveSheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      backgroundColor: $r('app.color.yourtube_bg_page'),
      preferType: SheetType.BOTTOM,
      showClose: false,
      onWillDisappear: () => {
        this.activeSheet = 0;
        this.showSavePlaylistSheet = false;
        this.showStreamInfoSheet = false;
        this.showSleepTimerSheet = false;
      }
    })
  }

  @Builder
  ActiveSheetBuilder() {
    if (this.activeSheet === 1) {
      this.SavePlaylistSheetBuilder()
    } else if (this.activeSheet === 2) {
      this.StreamInfoSheetBuilder()
    } else if (this.activeSheet === 3) {
      this.SleepTimerSheetBuilder()
    } else {
      Column().width('100%').height('100%')
    }
  }

  @Builder
  SleepTimerSheetBuilder() {
    Column({ space: 0 }) {
      Row() {
        Text($r('app.string.yt_action_sleep_timer'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_primary'))
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })

      TimePicker({
        selected: this.sleepPickerDate,
        format: TimePickerFormat.HOUR_MINUTE
      })
        .useMilitaryTime(true)
        .loop(false)
        .dateTimeOptions({ hour: '2-digit', minute: '2-digit' })
        .selectedTextStyle({
          color: this.themePrimary,
          font: { size: '20fp', weight: FontWeight.Medium }
        })
        .onChange((value: TimePickerResult) => {
          this.sleepPickerDate = new Date(0, 0, 0, value.hour, value.minute, 0, 0);
        })

      Row({ space: 12 }) {
        Button($r('app.string.yt_action_cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.yourtube_player_control_bg'))
          .fontColor($r('app.color.yourtube_text_primary'))
          .onClick(() => {
            this.closeSheet();
            Logger.debug(TAG, 'Sleep timer sheet cancelled');
          })
        Button($r('app.string.yt_action_confirm'))
          .layoutWeight(1)
          .backgroundColor(this.themePrimary)
          .fontColor(Color.White)
          .onClick(() => { this.confirmSleepTimerPicker(); })
      }
      .width('100%')
      .margin({ top: 16, bottom: 8 })
    }
    .width('100%')
    .padding({
      top: $r('app.float.padding_12'),
      bottom: 24,
      left: $r('app.float.padding_16'),
      right: $r('app.float.padding_16'),
    })
  }

  @Builder
  SavePlaylistSheetBuilder() {
    SavePlaylistSheet({
      video: this.item,
      isShow: $showSavePlaylistSheet
    })
  }

  @Builder
  StreamInfoSheetBuilder() {
    this.StreamInfoContent()
  }

  /** 流信息内容（弹窗） */
  @Builder
  StreamInfoContent() {
    Column({ space: 0 }) {
      // ── 标题行 ──
      Row() {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(16)
          .fontColor([$r('app.color.yourtube_text_secondary')])
        Text($r('app.string.yt_stream_info_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.yourtube_text_primary'))
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ bottom: 10 })

      // ── 容器信息 ──
      if (this.mpvContainerFormat.length > 0) {
        this.StreamInfoRow($r('app.string.yt_stream_container'), this.mpvContainerFormat.toUpperCase())
      }
      if (this.mpvMediaTitle.length > 0) {
        this.StreamInfoRow($r('app.string.yt_stream_media_title'), this.mpvMediaTitle)
      }
      if (this.mpvDuration > 0) {
        this.StreamInfoRow($r('app.string.yt_stream_duration'), this.formatDuration(this.mpvDuration))
      }
      if (this.mpvFileSize > 0) {
        this.StreamInfoRow($r('app.string.yt_stream_file_size'), this.formatFileSize(this.mpvFileSize))
      }

      // ── 视频流 ──
      if (this.mpvVideoWidth > 0) {
        Divider().color($r('app.color.yourtube_divider')).margin({ top: 8, bottom: 8 })
        Text($r('app.string.yt_stream_video'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .margin({ bottom: 6 })
        this.StreamInfoRow($r('app.string.yt_stream_resolution'), `${this.mpvVideoWidth} × ${this.mpvVideoHeight}`)
        if (this.mpvVideoCodec.length > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_codec'), this.mpvVideoCodec)
        }
        if (this.mpvVideoBitRate > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_bitrate'), this.formatBitrate(this.mpvVideoBitRate))
        }
        if (this.mpvFrameRate > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_frame_rate'), `${this.mpvFrameRate.toFixed(2)} fps`)
        }
      }

      // ── 音频流 ──
      if (this.mpvAudioCodec.length > 0 || this.mpvAudioSampleRate > 0) {
        Divider().color($r('app.color.yourtube_divider')).margin({ top: 8, bottom: 8 })
        Text($r('app.string.yt_stream_audio'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .margin({ bottom: 6 })
        if (this.mpvAudioCodec.length > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_codec'), this.mpvAudioCodec)
        }
        if (this.mpvAudioBitRate > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_bitrate'), this.formatBitrate(this.mpvAudioBitRate))
        }
        if (this.mpvAudioChannels > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_channels'), this.formatChannels(this.mpvAudioChannels))
        }
        if (this.mpvAudioSampleRate > 0) {
          this.StreamInfoRow($r('app.string.yt_stream_sample_rate'), `${(this.mpvAudioSampleRate / 1000).toFixed(1)} kHz`)
        }
      }

      // ── 无数据占位 ──
      if (this.mpvVideoWidth === 0 && this.mpvAudioCodec.length === 0 && this.mpvContainerFormat.length === 0) {
        Text($r('app.string.yt_stream_loading'))
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_hint'))
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 12 })
  }

  @Builder
  StreamInfoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .width(80)
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  @Builder
  DescriptionSection() {
    if (this.getEffectiveError()) {
      TabErrorPanel({
        errorMessage: this.getEffectiveError()!,
        showRetry: true,
        onRetry: () => {
          if (this.onRetryDescription) this.onRetryDescription();
        }
      })
    } else if (this.getEffectiveDesc().length > 0) {
      Text(this.getEffectiveDesc())
        .fontSize($r('app.float.font_size_14'))
        .fontColor($r('app.color.yourtube_text_primary'))
        .lineHeight(22)
        .width('100%')
        .margin({ bottom: 14 })
    } else if (!this.streams || this.streams.length === 0) {
      Column({ space: 8 }) {
        Row().width('100%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_player_info_bg'))
          .opacity(this.descSkeletonOpacity)
          .animation({ duration: 400, curve: Curve.EaseInOut })
        Row().width('92%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_player_info_bg'))
          .opacity(this.descSkeletonOpacity)
          .animation({ duration: 400, curve: Curve.EaseInOut })
        Row().width('60%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_player_info_bg'))
          .opacity(this.descSkeletonOpacity)
          .animation({ duration: 400, curve: Curve.EaseInOut })
      }.width('100%').margin({ top: 8, bottom: 14 })
    }
  }

  @Builder
  TagsSection() {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
      ForEach(this.tags, (tag: string) => {
        Text(`#${tag}`)
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .backgroundColor($r('app.color.yourtube_player_info_bg'))
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }, (tag: string, index: number) => `${tag}_${index}`)
    }
    .width('100%')
  }

  private toggleAudioOnlyMode(): void {
    const session = PlayerSession.getInstance();
    const next = !session.isAudioOnlyMode;
    session.setAudioOnlyMode(next);
    // Presentation owns delayed BACKGROUND off-timer + FG re-sync policy.
    PlayerPresentation.onAudioOnlyModeChanged(next);
  }

  private openSheet(id: number): void {
    this.activeSheet = id;
    this.sheetVisible = true;
  }

  private closeSheet(): void {
    this.sheetVisible = false;
    this.activeSheet = 0;
  }

  private openSleepTimerPicker(): void {
    const session = PlayerSession.getInstance();
    const remaining = session.sleepTimerRemainingMinutes;
    const initialMinutes = remaining > 0 ? remaining : 30;
    this.sleepPickerDate = new Date(0, 0, 0,
      Math.floor(initialMinutes / 60), initialMinutes % 60, 0, 0);
    this.openSheet(3);
  }

  private confirmSleepTimerPicker(): void {
    const d = this.sleepPickerDate;
    const minutes = d.getHours() * 60 + d.getMinutes();
    PlayerSession.getInstance().setSleepTimer(minutes);
    this.syncSleepTimerUi();
    this.closeSheet();
    Logger.info(TAG, `Sleep timer sheet accepted minutes=${minutes}`);
  }

  private shareVideo(): void {
    // OVERLAY: share sheet may fire ability onBackground; keep video ON.
    PlayerPresentation.beginOverlay('share');
    try {
      const videoId = (this.item.videoId || '').trim();
      const title = this.item.title || '';
      const url = videoId ? `https://www.youtube.com/watch?v=${videoId}` : '';
      const content = url ? `${title}\n${url}` : title;
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE
      }).catch((err: Object) => {
        PlayerPresentation.endOverlay('share-error');
        Logger.error(TAG, `share video failed: ${JSON.stringify(err)}`);
      });
    } catch (err) {
      PlayerPresentation.endOverlay('share-throw');
      Logger.error(TAG, `share video failed: ${JSON.stringify(err)}`);
    }
  }
}
