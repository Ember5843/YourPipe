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
import { CommonConstants as Const, Logger, StreamInfo, StreamCategories, PlayerModel, PlaybackStats,
  PlayerUiViewModel } from 'mediaservice';
import { formatBytes, formatDurationHms } from '../../../common/utils/FormatUtils';
import { LengthMetrics } from '@kit.ArkUI';
import { ErrorPage } from '../../../common/components/ErrorPage';
import { TabErrorPanel } from '../../../common/components/TabErrorPanel';
import { SearchChannelItem } from 'youtube_core';
import { ChannelInfoService } from '../../user/ChannelInfoService';
import { VideoItem } from 'youtube_core';
import { SubscriptionUser } from '../../../common/SubscriptionModel';
import { ChannelCard } from '../../user/components/ChannelCard';
import { DownloadDialog, DownloadSelection, buildDownloadTaskFromSelection } from './DownloadDialog';
import { SavePlaylistSheet } from './SavePlaylistSheet';
import { StatsBarGraph } from './StatsBarGraph';
import { StreamInfoRow } from './StreamInfoRow';
import { DownloadManager } from '../../../common/DownloadManager';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { LanguageManager } from '../../../common/LanguageManager';
import { ActionHub } from '../../../common/ActionHub';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import common from '@ohos.app.ability.common';
import { PlayerSession, CachedChannelProfile } from '../../../common/PlayerSession';
import { systemShare } from '@kit.ShareKit';
import { AppLog } from '../../../common/AppLog';
import { sharePlainText } from '../../../common/utils/ShareUtil';

const TAG: string = '[VideoDetails]';
const logger = AppLog.getInstance('VideoDetails');

enum DescriptionSegmentKind {
  TEXT = 0,
  LINK = 1,
  TIMESTAMP = 2
}

class DescriptionSegment {
  text: string;
  kind: DescriptionSegmentKind;
  target: string;
  seconds: number;

  constructor(text: string, kind: DescriptionSegmentKind, target: string = '', seconds: number = 0) {
    this.text = text;
    this.kind = kind;
    this.target = target;
    this.seconds = seconds;
  }
}

@Component
export struct VideoDetails {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop @Watch('onItemChanged') item: VideoItem;
  @Prop videoDescription: string = '';
  @Prop videoDescriptionError: string = '';
  @Prop streams: StreamInfo[] = [];
  /** True only for currently live broadcasts (not VOD of past lives). */
  @Prop isLiveNow: boolean = false;
  @Prop viewCount: number = 0;
  @Prop likeCount: string = '0';
  @Prop dislikeCount: string = '';
  @Prop publishDate: string = '';
  @Prop tags: string[] = [];
  @Prop @Watch('onChannelIdentityChanged') channelId: string = '';
  @Prop @Watch('onChannelIdentityChanged') channelAvatarUrl: string = '';
  @State isTitleExpanded: boolean = false;
  @State channelInfo: SearchChannelItem = new SearchChannelItem(
          0,
          this.item.channelId || '',
          this.item.author || '',
          '',
          '',
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
  private statsTimer: number = -1;
  @State statsSpeedSamples: number[] = [];
  @State statsBufferSamples: number[] = [];
  @State statsDropped: number = 0;
  @State statsDecoderDropped: number = 0;
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

  // ── mpv 实时播放流信息（与 AVPlayer 同一范式：ArkUI V1 的 @Track 不会穿透到
  // 嵌套 @Observed，vm 必须由组件自己 @Link，字段变化才能触发 UI 重渲染）──
  @Link vm: PlayerUiViewModel;

  private getEffectiveDesc(): string {
    return (this.videoDescription ?? this.item?.videoDescription) || '';
  }

  private getEffectiveError(): string | undefined {
    if (this.videoDescriptionError.length > 0) {
      return this.videoDescriptionError;
    }
    return this.item?.videoDescriptionError || undefined;
  }

  private parseTimestamp(value: string): number {
    const parts = value.split(':').map((part: string): number => Number(part));
    if ((parts.length !== 2 && parts.length !== 3)
      || parts.some((part: number): boolean => !Number.isInteger(part) || part < 0)) {
      return -1;
    }
    const seconds = parts[parts.length - 1];
    const minutes = parts[parts.length - 2];
    if (seconds >= 60 || minutes >= 60) {
      return -1;
    }
    return parts.length === 3
      ? parts[0] * 3600 + minutes * 60 + seconds
      : minutes * 60 + seconds;
  }

  private buildDescriptionSegments(description: string): DescriptionSegment[] {
    const segments: DescriptionSegment[] = [];
    const matcher = /https?:\/\/[^\s]+|www\.[^\s]+|\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b/gi;
    let cursor = 0;
    let match: RegExpExecArray | null = matcher.exec(description);
    while (match) {
      const start = match.index;
      const value = match[0];
      if (start > cursor) {
        segments.push(new DescriptionSegment(description.substring(cursor, start), DescriptionSegmentKind.TEXT));
      }

      if (/^(?:https?:\/\/|www\.)/i.test(value)) {
        const link = value.replace(/[\]\)}>.,!?;:，。！？；：、》】）]+$/g, '');
        if (link.length > 0) {
          segments.push(new DescriptionSegment(link, DescriptionSegmentKind.LINK, link));
        }
        if (link.length < value.length) {
          segments.push(new DescriptionSegment(value.substring(link.length), DescriptionSegmentKind.TEXT));
        }
      } else {
        const seconds = this.parseTimestamp(value);
        segments.push(new DescriptionSegment(value,
          seconds >= 0 ? DescriptionSegmentKind.TIMESTAMP : DescriptionSegmentKind.TEXT,
          '', Math.max(0, seconds)));
      }

      cursor = matcher.lastIndex;
      match = matcher.exec(description);
    }
    if (cursor < description.length) {
      segments.push(new DescriptionSegment(description.substring(cursor), DescriptionSegmentKind.TEXT));
    }
    return segments;
  }

  private openDescriptionLink(target: string): void {
    const url = target.toLowerCase().startsWith('www.') ? `https://${target}` : target;
    try {
      logger.info(`description link requested videoId=${this.item.videoId}`);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.openLink(url, { appLinkingOnly: false }).catch((error: Object) => {
        logger.error(`description link failed videoId=${this.item.videoId}`, error);
      });
    } catch (error) {
      logger.error(`description link failed videoId=${this.item.videoId}`, error as Object);
    }
  }

  private seekToDescriptionTimestamp(seconds: number): void {
    const duration = PlayerSession.getInstance().controller.vm.durationTime;
    const targetSeconds = duration > 0 ? Math.min(seconds, duration) : seconds;
    logger.info(`description timestamp seek videoId=${this.item.videoId} targetSec=${targetSeconds}`);
    PlayerSession.getInstance().controller.syncSeekExact(targetSeconds * 1000);
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
    this.stopStreamStatsPolling();
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

  private startStreamStatsPolling(): void {
    this.stopStreamStatsPolling();
    this.statsSpeedSamples = [];
    this.statsBufferSamples = [];
    this.statsDropped = 0;
    this.statsDecoderDropped = 0;
    logger.debug(`stream stats polling started videoId=${this.item.videoId}`);
    this.pollStreamStats();
    this.statsTimer = setInterval(() => { this.pollStreamStats(); }, 500);
  }

  private stopStreamStatsPolling(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
      logger.debug(`stream stats polling stopped videoId=${this.item.videoId}`);
    }
  }

  private pollStreamStats(): void {
    const stats: PlaybackStats = PlayerSession.getInstance().controller.getPlaybackStats();
    // 连接速度用代理层实测网络吞吐；MPV cache-speed 在 loopback 代理下缓存一满即归零，不具参考性。
    const speedSamples: number[] = [...this.statsSpeedSamples, stats.networkSpeedBps ?? 0];
    if (speedSamples.length > 60) {
      speedSamples.shift();
    }
    this.statsSpeedSamples = speedSamples;
    const bufferSamples: number[] = [...this.statsBufferSamples, stats.demuxerCacheDurationSec];
    if (bufferSamples.length > 60) {
      bufferSamples.shift();
    }
    this.statsBufferSamples = bufferSamples;
    this.statsDropped = stats.droppedFrames;
    this.statsDecoderDropped = stats.decoderDroppedFrames;
  }

  private currentStatsSpeed(): number {
    return this.statsSpeedSamples.length > 0 ? this.statsSpeedSamples[this.statsSpeedSamples.length - 1] : 0;
  }

  private currentStatsBuffer(): number {
    return this.statsBufferSamples.length > 0 ? this.statsBufferSamples[this.statsBufferSamples.length - 1] : 0;
  }

  private formatSpeed(bps: number): string {
    if (bps >= 1024 * 1024) {
      return `${(bps / (1024 * 1024)).toFixed(2)} MB/s`;
    }
    return `${(bps / 1024).toFixed(2)} KB/s`;
  }

  private formatBufferSec(sec: number): string {
    return `${sec.toFixed(1)} s`;
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
    // 自动连播切到下一集时清掉旧视频的统计曲线，避免新旧样本混在同一图表里。
    this.statsSpeedSamples = [];
    this.statsBufferSamples = [];
    this.statsDropped = 0;
    this.statsDecoderDropped = 0;
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
      '',
      '',
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
        cached.subscriberText || '',
        cached.videoCountText || '',
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
    // 分类+排序收口在 PlayerModel.classifyForDownload（下载要求可拉取的媒体
    // URL，SABR 用 sabrInfo 引导），与卡片长按下载入口共用同一份逻辑。
    this.streamCategories = PlayerModel.classifyForDownload(this.streams ?? []);
  }

  private isCurrentlyLive(): boolean {
    // Only isLiveNow from player extraction (liveBroadcastDetails.isLiveNow).
    // Do NOT use list badge item.isLive — post-live / 直播回放 must stay downloadable.
    return this.isLiveNow === true;
  }

  private openDownloadDialog(): void {
    if (this.isCurrentlyLive()) {
      return;
    }
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
          const task = buildDownloadTaskFromSelection(
            this.item.videoId, this.item.title, this.item.author, this.item.thumbnailUrl, selection);
          if (task) {
            task._context = ctx;
            this.downloadManager.addTask(task);
          }
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
          profile.subscriberText || '',
          profile.videoCountText || '',
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
    // PipePipe parity: RYD returned a real count (including 0) → show; only
    // an empty value (RYD failed / no data) hides the item.
    return !!(this.dislikeCount && this.dislikeCount.length > 0);
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
    return formatBytes(bytes);
  }

  private formatChannels(ch: number): string {
    if (ch === 1) return 'Mono (1.0)';
    if (ch === 2) return 'Stereo (2.0)';
    if (ch === 6) return '5.1';
    if (ch === 8) return '7.1';
    return `${ch} channels`;
  }

  @Builder
  StatsMetaRow() {
    // Title-adjacent stats: views / date / like / dislike. Items size to their
    // content; SpaceBetween pins the first/last item to the strip edges with
    // equal gaps in between. The per-item width cap keeps gaps alive when a
    // label runs long.
    Row() {
      if (this.viewCount > 0) {
        this.StatItem($r('sys.symbol.play_round_rectangle'), this.formatViewCount(this.viewCount))
      }
      if (this.publishDate && this.publishDate.length > 0) {
        this.StatItem($r('sys.symbol.calendar'), this.formatRelativeDate(this.publishDate))
      }
      if (this.hasLikeCount()) {
        this.StatItem($r('sys.symbol.hand_thumbsup'), this.formatStatCount(this.likeCount))
      }
      if (this.hasDislikeCount()) {
        this.StatItem($r('sys.symbol.hand_thumbsdown'), this.formatStatCount(this.dislikeCount))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_player_info_bg'))
    .margin({ top: 8, bottom: 12 })
  }

  @Builder
  StatItem(icon: Resource, label: ResourceStr) {
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
    .constraintSize({ maxWidth: '30%' })
  }

  @Builder
  ActionButtonRow() {
    Scroll() {
      Row({ space: 10 }) {
        this.SleepTimerActionButton()
        if (!this.isCurrentlyLive()) {
          this.ActionButton($r('sys.symbol.arrowshape_down_to_line_fill'),
            $r('app.string.yt_action_download'), () => { this.openDownloadDialog(); })
        }
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
      .alignItems(HorizontalAlign.Start)
    }
    .edgeEffect(EdgeEffect.Spring)
    .width(Const.WIDTH_FULL_PERCENT)
    .height(Const.HEIGHT_FULL_PERCENT)
    .align(Alignment.Top)
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
      // CENTER：宽窗（≥600vp，平板/2in1/横屏）下呈居中卡片，避免底部 sheet 拉满
      // 全宽导致信息稀疏；窄窗（<600vp，手机竖屏）系统自动回退为底部样式，与
      // PlayerPage 视频信息 sheet / Index 选项 sheet 同一范式。
      preferType: SheetType.CENTER,
      showClose: false,
      onWillDisappear: () => {
        this.activeSheet = 0;
        this.showSavePlaylistSheet = false;
        this.showStreamInfoSheet = false;
        this.showSleepTimerSheet = false;
        this.stopStreamStatsPolling();
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
      if (this.item.videoId.length > 0) {
        StreamInfoRow({ label: $r('app.string.yt_stats_video_id'), value: this.item.videoId })
      }
      if (this.vm.containerFormat.length > 0) {
        StreamInfoRow({ label: $r('app.string.yt_stream_container'), value: this.vm.containerFormat.toUpperCase() })
      }
      if (this.vm.mediaTitle.length > 0) {
        StreamInfoRow({ label: $r('app.string.yt_stream_media_title'), value: this.vm.mediaTitle })
      }
      if (this.vm.durationTime > 0) {
        StreamInfoRow({ label: $r('app.string.yt_stream_duration'), value: formatDurationHms(this.vm.durationTime) })
      }
      if (this.vm.fileSize > 0) {
        StreamInfoRow({ label: $r('app.string.yt_stream_file_size'), value: this.formatFileSize(this.vm.fileSize) })
      }

      // ── 视频流 ──
      if (this.vm.videoWidth > 0) {
        Divider().color($r('app.color.yourtube_divider')).margin({ top: 8, bottom: 8 })
        Text($r('app.string.yt_stream_video'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .margin({ bottom: 6 })
        StreamInfoRow({ label: $r('app.string.yt_stream_resolution'), value: `${this.vm.videoWidth} × ${this.vm.videoHeight}` })
        if (this.vm.videoCodec.length > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_codec'), value: this.vm.videoCodec })
        }
        if (this.vm.videoBitRate > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_bitrate'), value: this.formatBitrate(this.vm.videoBitRate) })
        }
        if (this.vm.frameRate > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_frame_rate'), value: `${this.vm.frameRate.toFixed(2)} fps` })
        }
      }

      // ── 音频流 ──
      if (this.vm.audioCodec.length > 0 || this.vm.audioSampleRate > 0) {
        Divider().color($r('app.color.yourtube_divider')).margin({ top: 8, bottom: 8 })
        Text($r('app.string.yt_stream_audio'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .margin({ bottom: 6 })
        if (this.vm.audioCodec.length > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_codec'), value: this.vm.audioCodec })
        }
        if (this.vm.audioBitRate > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_bitrate'), value: this.formatBitrate(this.vm.audioBitRate) })
        }
        if (this.vm.audioChannels > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_channels'), value: this.formatChannels(this.vm.audioChannels) })
        }
        if (this.vm.audioSampleRate > 0) {
          StreamInfoRow({ label: $r('app.string.yt_stream_sample_rate'), value: `${(this.vm.audioSampleRate / 1000).toFixed(1)} kHz` })
        }
      }

      // ── 播放统计（Stats for Nerds 风格实时数据）──
      Divider().color($r('app.color.yourtube_divider')).margin({ top: 8, bottom: 8 })
      Text($r('app.string.yt_stream_stats_title'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .margin({ bottom: 6 })
      StreamInfoRow({ label: $r('app.string.yt_stats_conn_speed'), value: this.formatSpeed(this.currentStatsSpeed()) })
      StatsBarGraph({
        samples: this.statsSpeedSamples,
        kind: 'speed',
        referenceBps: this.vm.videoBitRate + this.vm.audioBitRate
      })
        .margin({ top: 4, bottom: 8 })
      StreamInfoRow({ label: $r('app.string.yt_stats_buffer'), value: this.formatBufferSec(this.currentStatsBuffer()) })
      StatsBarGraph({
        samples: this.statsBufferSamples,
        kind: 'buffer'
      })
        .margin({ top: 4, bottom: 8 })
      StreamInfoRow({
        label: $r('app.string.yt_stats_dropped'),
        value: this.statsDropped === 0 && this.statsDecoderDropped === 0
          ? '0'
          : `${this.statsDropped} / ${this.statsDecoderDropped}`
      })

      // ── 无数据占位 ──
      if (this.vm.videoWidth === 0 && this.vm.audioCodec.length === 0 && this.vm.containerFormat.length === 0) {
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
      Text() {
        ForEach(this.buildDescriptionSegments(this.getEffectiveDesc()),
          (segment: DescriptionSegment) => {
            if (segment.kind === DescriptionSegmentKind.LINK) {
              Span(segment.text)
                .fontColor(this.themePrimary)
                .decoration({ type: TextDecorationType.Underline, color: this.themePrimary })
                .onClick(() => { this.openDescriptionLink(segment.target); })
            } else if (segment.kind === DescriptionSegmentKind.TIMESTAMP) {
              Span(segment.text)
                .fontColor(this.themePrimary)
                .fontWeight(FontWeight.Medium)
                .onClick(() => { this.seekToDescriptionTimestamp(segment.seconds); })
            } else {
              Span(segment.text)
                .fontColor($r('app.color.yourtube_text_primary'))
            }
          },
          (segment: DescriptionSegment, index: number) => `${index}_${segment.kind}_${segment.text}`)
      }
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
        Text(this.formatTagLabel(tag))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_secondary'))
          .backgroundColor($r('app.color.yourtube_player_info_bg'))
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => { this.openTagSearch(tag); })
      }, (tag: string, index: number) => `${tag}_${index}`)
    }
    .width('100%')
  }

  private normalizeTag(tag: string): string {
    return tag.trim().replace(/^#+/, '').trim();
  }

  private formatTagLabel(tag: string): string {
    const normalizedTag = this.normalizeTag(tag);
    return normalizedTag.length > 0 ? `#${normalizedTag}` : '#';
  }

  private openTagSearch(tag: string): void {
    const normalizedTag = this.normalizeTag(tag);
    if (normalizedTag.length === 0) {
      logger.warn(`tag search ignored videoId=${this.item.videoId} reason=empty`);
      return;
    }
    logger.info(`tag search requested videoId=${this.item.videoId} query=${normalizedTag}`);
    this.actionHub.openSearch(normalizedTag);
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
    if (id === 2) {
      this.startStreamStatsPolling();
    }
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
    const videoId = (this.item.videoId || '').trim();
    const title = this.item.title || '';
    const url = videoId ? `https://www.youtube.com/watch?v=${videoId}` : '';
    sharePlainText(this.getUIContext(), title, url,
      { selectionMode: systemShare.SelectionMode.SINGLE },
      () => {
        PlayerPresentation.endOverlay('share-error');
      });
  }
}
