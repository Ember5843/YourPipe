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
import { ActionHub } from '../../../common/ActionHub';
import common from '@ohos.app.ability.common';
import { PlayerSession, CachedChannelProfile } from '../../../common/PlayerSession';
import { AVCastPickerStyle, avSession } from '@kit.AVSessionKit';
import type { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = '[VideoDetails]';

@Component
export struct VideoDetails {
  @Prop @Watch('onItemChanged') item: VideoItem;
  @Prop videoDescription: string = '';
  @Prop videoDescriptionError: string = '';
  @Prop streams: StreamInfo[] = [];
  @Prop viewCount: number = 0;
  @Prop likeCount: string = '0';
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
  @State descSkeletonOpacity: number = 0.3;
  @State showSavePlaylistSheet: boolean = false;

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
    if (count >= 100000000) return (count / 100000000).toFixed(1) + '亿';
    if (count >= 10000) return (count / 10000).toFixed(1) + '万';
    if (count >= 1000) return (count / 1000).toFixed(1) + 'K';
    return count.toString();
  }

  private formatRelativeDate(dateStr: string): string {
    if (!dateStr) return '';
    const date = new Date(dateStr);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));
    if (diffDays < 1) return '今天';
    if (diffDays < 7) return `${diffDays}天前`;
    if (diffDays < 30) return `${Math.floor(diffDays / 7)}周前`;
    if (diffDays < 365) return `${Math.floor(diffDays / 30)}个月前`;
    return `${Math.floor(diffDays / 365)}年前`;
  }

  aboutToAppear() {
    this.channelInfoService = new ChannelInfoService();
    this.resetForCurrentItem();
    this.classifyStreamsForDownload();

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
      if (!stream.url) {
        return;
      }

      const kind = (stream.kind || '').toLowerCase();
      const delivery = (stream.deliveryMethod || '').toUpperCase();
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
      } else if (kind === 'progressive' || delivery === 'PROGRESSIVE_HTTP' || (hasVideo && hasAudio)) {
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
        this.streamCategories.progressive.length === 0)) {
      this.getUIContext().getPromptAction().showToast({ message: 'No downloadable streams available' });
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
    const channelId = this.channelId || this.item.channelId || '';
    const avatarUrl = this.channelAvatarUrl || this.item.channelAvatarUrl || '';
    Logger.debug(TAG, `[fetchChannelInfo] Starting, channelId=${channelId}`);
    if (!channelId || !this.channelInfoService) {
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

  private buildMetadataText(): string {
    const parts: string[] = [];
    if (this.viewCount > 0) {
      parts.push(`${this.formatViewCount(this.viewCount)}次观看`);
    }
    if (this.likeCount && this.likeCount !== '0') {
      parts.push(`${this.likeCount}点赞`);
    }
    if (this.publishDate) {
      parts.push(this.formatRelativeDate(this.publishDate));
    }
    return parts.join(' · ');
  }

  @Builder
  ActionButtonRow() {
    Scroll() {
      Row({ space: 10 }) {
        this.ActionButton($r('sys.symbol.TV_tv'),
          '投屏', () => { this.openCastPicker(); })
        this.ActionButton($r('sys.symbol.arrowshape_down_to_line_fill'),
          $r('app.string.yt_action_download'), () => { this.openDownloadDialog(); })
        this.ActionButton($r('sys.symbol.bookmark'),
          '保存到播放列表', () => { this.showSavePlaylistSheet = true; })
        this.ActionButton($r('sys.symbol.play_circle'),
          '后台播放', () => { this.moveToBackground(); })
        this.ActionButton($r('sys.symbol.share'),
          '分享', () => { this.shareVideo(); })
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(36)
    .margin({ bottom: 14 })
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
    .backgroundColor($r('app.color.yourtube_bg_surface'))
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
              .fontColor($r('app.color.yourtube_theme_primary'))
              .margin({ top: 4 })
          }
        }
        .onClick(() => { this.isTitleExpanded = !this.isTitleExpanded; })
        .alignItems(HorizontalAlign.Start)

        // ── 元数据行 ──
        if (this.viewCount > 0 || (this.likeCount && this.likeCount !== '0') || this.publishDate) {
          Text(this.buildMetadataText())
            .fontSize(13)
            .fontColor($r('app.color.yourtube_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6, bottom: 12 })
        } else {
          Column().height(12)
        }

        // ── 频道信息行（不修改）──
        if (this.channelInfoError) {
          ErrorPage({
            errorMessage: this.channelInfoError,
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
    .bindSheet($$this.showSavePlaylistSheet, this.SavePlaylistSheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      backgroundColor: $r('app.color.yourtube_bg_page'),
      preferType: SheetType.BOTTOM,
      showClose: false,
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
  DescriptionSection() {
    if (this.getEffectiveError()) {
      ErrorPage({
        errorMessage: this.getEffectiveError(),
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
    } else {
      Column({ space: 8 }) {
        Row().width('100%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .opacity(this.descSkeletonOpacity)
          .animation({ duration: 400, curve: Curve.EaseInOut })
        Row().width('92%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .opacity(this.descSkeletonOpacity)
          .animation({ duration: 400, curve: Curve.EaseInOut })
        Row().width('60%').height(14).borderRadius(2)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }, (tag: string, index: number) => `${tag}_${index}`)
    }
    .width('100%')
  }

  private moveToBackground(): void {
    // 回到桌面保活：不碰 vo，不弹画中画，mpv 持续渲染，音频继续播放。
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.moveAbilityToBackground().catch((e: Error) => {
      Logger.error(TAG, `moveAbilityToBackground failed: ${e.message}`);
      this.getUIContext().getPromptAction().showToast({ message: '回到桌面失败' });
    });
  }

  private openCastPicker(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const pickerHelper = new avSession.AVCastPickerHelper(context);
    pickerHelper.select({
      sessionType: 'video',
      pickerStyle: AVCastPickerStyle.STYLE_PANEL
    }).catch((error: BusinessError) => {
      Logger.error(TAG, `Failed to open cast picker: ${JSON.stringify(error)}`);
    });
  }

  private shareVideo(): void {
    const url = `https://youtu.be/${this.item.videoId}`;
    this.getUIContext().getPromptAction().showToast({ message: `分享: ${url}` });
  }
}
