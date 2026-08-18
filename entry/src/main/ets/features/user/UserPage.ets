import { AppLog } from '../../common/AppLog';
import { TITLE_BAR_HEIGHT } from '../../common/components/MediaCardTokens';
import common from '@ohos.app.ability.common';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { ActionHub } from '../../common/ActionHub';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { SearchChannelItem, SearchPlaylistItem } from 'youtube_core';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { VideoItem } from 'youtube_core';
import { ChannelInfoService, ChannelProfile } from '../../features/user/ChannelInfoService';

import { SubscriptionFeedService } from '../../features/subscription/SubscriptionFeedService';
import { UIConfig } from '../../common/AppState';
import { getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
import { PlaylistCard } from '../../features/playlist/components/PlaylistCard';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildTitleMenu, buildYourTubeTitleBar } from '../../common/components/HdsTitleBar';
import { SubTabBarItem } from '../../common/components/SubTabBar';
import { ChannelVideoTab } from './components/ChannelVideoTab';
import { KioskPageResult } from '../home/ChannelService';

const logger = AppLog.getInstance('UserPage');

/** Kiosk 类 Tab（Shorts/Live）的状态读写通道：泛型加载器经闭包适配各自的 @State 字段 */
interface KioskFeedIO {
  getList: () => VideoItem[];
  setList: (v: VideoItem[]) => void;
  getToken: () => string | null;
  setToken: (v: string | null) => void;
  getVisitor: () => string;
  setVisitor: (v: string) => void;
  isBusy: () => boolean;
  setLoading: (v: boolean) => void;
  setLoadingMore: (v: boolean) => void;
  setError: (v: ResourceStr) => void;
}


@Component
export struct UserPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop channel: SearchChannelItem;
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;

  @State activeTabIndex: number = 0;

  // Videos Tab
  @State videoList: VideoItem[] = [];
  @State channelNextPageToken: string | null = null;
  @State channelVisitorData: string = '';
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State errorMessage: ResourceStr = '';

  // Shorts Tab
  @State shortsList: VideoItem[] = [];
  @State shortsNextPageToken: string | null = null;
  @State shortsVisitorData: string = '';
  @State isLoadingShorts: boolean = false;
  @State isLoadingMoreShorts: boolean = false;
  @State errorMessageShorts: ResourceStr = '';

  // Live Tab
  @State liveList: VideoItem[] = [];
  @State liveNextPageToken: string | null = null;
  @State liveVisitorData: string = '';
  @State isLoadingLive: boolean = false;
  @State isLoadingMoreLive: boolean = false;
  @State errorMessageLive: ResourceStr = '';

  // Playlists Tab
  @State playlistList: SearchPlaylistItem[] = [];
  @State playlistNextPageToken: string | null = null;
  @State playlistVisitorData: string = '';
  @State isLoadingPlaylists: boolean = false;
  @State isLoadingMorePlaylists: boolean = false;
  @State errorMessagePlaylists: ResourceStr = '';

  @State bannerUrl: string = '';
  @State fullDescription: string = '';
  @State displayChannel: SearchChannelItem = new SearchChannelItem(0, '', 'Unknown', '', '', '', '', '#CCCCCC');
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];

  private readonly BANNER_HEIGHT: number = 70;
  private readonly GRID_SIDE_PADDING: number = 12;

  private rssFallbackService: SubscriptionFeedService = new SubscriptionFeedService();
  private channelInfoService: ChannelInfoService = new ChannelInfoService();
  private scrollerForScroll: Scroller = new Scroller();
  private scrollerForList: Scroller = new Scroller();
  private readonly SHARE_BUTTON_ID: string = 'shareButtonId';

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    return getWideListColumnCount(contentWidth);
  }

  private getChannelId(): string {
    return (this.channel.channelId || '').trim();
  }

  private fillChannelInfo(video: VideoItem): VideoItem {
    const channelId = this.displayChannel.channelId || this.channel.channelId || '';
    const author = this.displayChannel.name || this.channel.name || video.author || '';
    const channelAvatarUrl = this.displayChannel.avatarUrl || this.channel.avatarUrl || '';
    const channelHandle = this.displayChannel.handle || this.channel.handle || '';
    
    return new VideoItem(
      video.id,
      video.videoId,
      video.title,
      author,
      video.viewCount,
      video.thumbnailUrl,
      video.isLive,
      video.thumbnailColor,
      channelId,
      channelAvatarUrl,
      channelHandle,
      video.videoDescription,
      video.videoDescriptionError,
      video.isPremium,
      video.requiresMembership
    );
  }

  private fillChannelInfoList(videos: VideoItem[]): VideoItem[] {
    return videos.map(video => this.fillChannelInfo(video));
  }

  private isSubscribed(): boolean {
    const channelId = this.getChannelId();
    if (!channelId) {
      return false;
    }
    return this.subscriptions.some((item) => item.channelId === channelId);
  }

  private resolveSubscriberText(stored: string, latest: string): string {
    const trimmed = (latest || '').trim();
    if (trimmed.length > 0 && !trimmed.startsWith('@')) {
      return trimmed;
    }
    return (stored || '').trim();
  }

  private resolveVideoCountText(stored: string, latest: string): string {
    const storedTrim = (stored || '').trim();
    if (storedTrim.startsWith('@')) {
      return storedTrim;
    }
    const latestTrim = (latest || '').trim();
    if (latestTrim.length > 0) {
      return latestTrim;
    }
    return storedTrim;
  }

  private handleSubscription(): void {
    const channelId = this.getChannelId();
    if (!channelId) {
      return;
    }
    if (this.isSubscribed()) {
      this.actionHub.removeSubscription(channelId);
      return;
    }
    this.actionHub.addSubscription(this.displayChannel);
  }

  aboutToAppear() {
    this.displayChannel = this.channel;
    this.loadAllContent();
  }

  private async loadAllContent() {
    // Load everything in parallel
    this.loadChannelInfo();
    this.loadVideos();
    this.loadShorts();
    this.loadLive();
    this.loadPlaylists();
  }


  private async loadChannelInfo(): Promise<void> {
    try {
      const channelId = this.channel.channelId || '';
      const profile = await this.channelInfoService.fetchChannelProfile(channelId);
      if (profile.description && profile.description.length > 0) {
        this.fullDescription = profile.description;
      }
      if (profile.bannerUrl && profile.bannerUrl.length > 0) {
        this.bannerUrl = profile.bannerUrl;
      }
      if (profile.name || profile.avatarUrl || profile.subscriberText || profile.videoCountText || profile.handle) {
        const name = profile.name && profile.name.length > 0
          ? profile.name
          : (this.displayChannel.name || this.channel.name || 'Unknown');
        const subscriberText = this.resolveSubscriberText(
          this.displayChannel.subscriberText || '',
          profile.subscriberText || ''
        );
        const videoCountText = profile.videoCountText || ''

        const handle = profile.handle || this.displayChannel.handle || '';
        const next = new SearchChannelItem(
          this.channel.id,
          channelId,
          name,
          subscriberText,
          videoCountText,
          profile.avatarUrl || this.displayChannel.avatarUrl || '',
          profile.description || this.displayChannel.description || '',
          this.displayChannel.thumbnailColor || this.channel.thumbnailColor || '#CCCCCC',
          handle
        );
        this.displayChannel = next;
      }
    } catch (err) {
      logger.error('loadChannelInfo failed:', JSON.stringify(err));
    }
  }

  private async handleShare(): Promise<void> {
    try {
      const channelId = (this.channel.channelId || '').trim();
      const channelName = this.channel.name || getContext().resourceManager.getStringSync($r('app.string.yt_label_user').id);
      const url = channelId ? `https://www.youtube.com/channel/${channelId}` : '';
      const content = url ? `${channelName}\n${url}` : channelName;
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const uiContext: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      controller.show(context, { anchor: this.SHARE_BUTTON_ID });
    } catch (err) {
      logger.error('share failed:', JSON.stringify(err));
    }
  }

  private async loadVideos(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const channelId = (this.channel.channelId || '').trim();
      if (!channelId) {
        this.videoList = [];
        this.channelNextPageToken = null;
        this.channelVisitorData = '';
        return;
      }
      this.channelNextPageToken = null;
      this.channelVisitorData = '';
      const service = FeedServiceProvider.getInstance().getChannelService();
      const result = await service.fetchChannelVideosInitial(channelId, 1);
      if (result.items && result.items.length > 0) {
        this.videoList = this.fillChannelInfoList(result.items);
        this.channelNextPageToken = result.nextPageToken;
        if (result.visitorData && result.visitorData.length > 0) {
          this.channelVisitorData = result.visitorData;
        }
      } else {
        const fallback = await this.rssFallbackService.fetchChannelVideos(channelId, this.channel.name || channelId);
        this.videoList = this.fillChannelInfoList(fallback);
        this.channelNextPageToken = null;
        this.channelVisitorData = '';
      }
      if (!this.bannerUrl || this.bannerUrl.length === 0) {
        this.bannerUrl = (this.videoList && this.videoList.length > 0 && this.videoList[0].thumbnailUrl)
          ? this.videoList[0].thumbnailUrl
          : (this.channel.avatarUrl || '');
      }
    } catch (err) {
      logger.error('loadChannelVideos failed:', JSON.stringify(err));
      this.videoList = [];
      this.errorMessage = $r('app.string.yt_error_load_user_videos');
    } finally {
      this.isLoading = false;
    }
  }

  private async loadMoreVideos(): Promise<void> {
    if (this.isLoading || this.isLoadingMore) {
      return;
    }
    if (!this.channelNextPageToken) {
      return;
    }
    this.isLoadingMore = true;
    try {
      const service = FeedServiceProvider.getInstance().getChannelService();
      const startId = this.videoList.length + 1;
      const token = this.channelNextPageToken ?? '';
      const result = await service.fetchChannelVideosNext(token, this.channelVisitorData, startId);
      if (result.items && result.items.length > 0) {
        this.videoList = this.videoList.concat(this.fillChannelInfoList(result.items));
      }
      if ((!result.items || result.items.length === 0) && result.nextPageToken === token) {
        this.channelNextPageToken = null;
      } else {
        this.channelNextPageToken = result.nextPageToken;
      }
      if (result.visitorData && result.visitorData.length > 0) {
        this.channelVisitorData = result.visitorData;
      }
    } catch (err) {
      logger.error('loadMoreVideos failed:', JSON.stringify(err));
    } finally {
      this.isLoadingMore = false;
    }
  }

  private shortsFeedIO(): KioskFeedIO {
    return {
      getList: () => this.shortsList,
      setList: (v: VideoItem[]) => { this.shortsList = v; },
      getToken: () => this.shortsNextPageToken,
      setToken: (v: string | null) => { this.shortsNextPageToken = v; },
      getVisitor: () => this.shortsVisitorData,
      setVisitor: (v: string) => { this.shortsVisitorData = v; },
      isBusy: () => this.isLoadingShorts || this.isLoadingMoreShorts,
      setLoading: (v: boolean) => { this.isLoadingShorts = v; },
      setLoadingMore: (v: boolean) => { this.isLoadingMoreShorts = v; },
      setError: (v: ResourceStr) => { this.errorMessageShorts = v; }
    };
  }

  private liveFeedIO(): KioskFeedIO {
    return {
      getList: () => this.liveList,
      setList: (v: VideoItem[]) => { this.liveList = v; },
      getToken: () => this.liveNextPageToken,
      setToken: (v: string | null) => { this.liveNextPageToken = v; },
      getVisitor: () => this.liveVisitorData,
      setVisitor: (v: string) => { this.liveVisitorData = v; },
      isBusy: () => this.isLoadingLive || this.isLoadingMoreLive,
      setLoading: (v: boolean) => { this.isLoadingLive = v; },
      setLoadingMore: (v: boolean) => { this.isLoadingMoreLive = v; },
      setError: (v: ResourceStr) => { this.errorMessageLive = v; }
    };
  }

  /** Shorts/Live 共用的首屏加载（已有内容时跳过；Videos 有 RSS 兜底，走自己的 loadVideos） */
  private async loadKioskFeedInitial(
    tag: string,
    feed: KioskFeedIO,
    fetchInitial: (channelId: string, startId: number) => Promise<KioskPageResult>,
    errorRes: Resource
  ): Promise<void> {
    if (feed.getList().length > 0) {
      return;
    }
    feed.setLoading(true);
    feed.setError('');
    try {
      const channelId = this.getChannelId();
      if (!channelId) {
        feed.setList([]);
        feed.setToken(null);
        return;
      }
      const result = await fetchInitial(channelId, 1);
      if (result.items && result.items.length > 0) {
        feed.setList(this.fillChannelInfoList(result.items));
        feed.setToken(result.nextPageToken);
        if (result.visitorData) {
          feed.setVisitor(result.visitorData);
        }
      } else {
        feed.setList([]);
      }
    } catch (err) {
      logger.error(`${tag} failed:`, JSON.stringify(err));
      feed.setError(errorRes);
    } finally {
      feed.setLoading(false);
    }
  }

  /** Shorts/Live 共用的翻页加载 */
  private async loadKioskFeedMore(
    tag: string,
    feed: KioskFeedIO,
    fetchNext: (token: string, visitorData: string, startId: number) => Promise<KioskPageResult>
  ): Promise<void> {
    if (feed.isBusy() || !feed.getToken()) {
      return;
    }
    feed.setLoadingMore(true);
    try {
      const startId = feed.getList().length + 1;
      const result = await fetchNext(feed.getToken() ?? '', feed.getVisitor(), startId);
      if (result.items && result.items.length > 0) {
        feed.setList(feed.getList().concat(this.fillChannelInfoList(result.items)));
        feed.setToken(result.nextPageToken);
        if (result.visitorData) {
          feed.setVisitor(result.visitorData);
        }
      } else {
        feed.setToken(null);
      }
    } catch (err) {
      logger.error(`${tag} failed:`, JSON.stringify(err));
    } finally {
      feed.setLoadingMore(false);
    }
  }

  // Shorts Loading
  private async loadShorts(): Promise<void> {
    await this.loadKioskFeedInitial('loadShorts', this.shortsFeedIO(),
      (channelId: string, startId: number) =>
        FeedServiceProvider.getInstance().getChannelService().fetchChannelShortsInitial(channelId, startId),
      $r('app.string.yt_error_load_shorts'));
  }

  private async loadMoreShorts(): Promise<void> {
    await this.loadKioskFeedMore('loadMoreShorts', this.shortsFeedIO(),
      (token: string, visitorData: string, startId: number) =>
        FeedServiceProvider.getInstance().getChannelService().fetchChannelShortsNext(token, visitorData, startId));
  }

  // Live Loading
  private async loadLive(): Promise<void> {
    await this.loadKioskFeedInitial('loadLive', this.liveFeedIO(),
      (channelId: string, startId: number) =>
        FeedServiceProvider.getInstance().getChannelService().fetchChannelLiveInitial(channelId, startId),
      $r('app.string.yt_error_load_live'));
  }

  private async loadMoreLive(): Promise<void> {
    await this.loadKioskFeedMore('loadMoreLive', this.liveFeedIO(),
      (token: string, visitorData: string, startId: number) =>
        FeedServiceProvider.getInstance().getChannelService().fetchChannelLiveNext(token, visitorData, startId));
  }


  // Playlists Loading
  private async loadPlaylists(): Promise<void> {
    if (this.playlistList.length > 0) return;
    this.isLoadingPlaylists = true;
    this.errorMessagePlaylists = '';
    try {
      const channelId = (this.channel.channelId || '').trim();
      if (!channelId) {
        this.playlistList = [];
        this.playlistNextPageToken = null;
        return;
      }
      const service = FeedServiceProvider.getInstance().getChannelService();
      const result = await service.fetchChannelPlaylistsInitial(channelId, 1);
      if (result.items && result.items.length > 0) {
        this.playlistList = result.items;
        this.playlistNextPageToken = result.nextPageToken;
        if (result.visitorData) this.playlistVisitorData = result.visitorData;
      } else {
        this.playlistList = [];
      }
    } catch (err) {
      logger.error('loadPlaylists failed:', JSON.stringify(err));
      this.errorMessagePlaylists = $r('app.string.yt_error_load_playlists');
    } finally {
      this.isLoadingPlaylists = false;
    }
  }

  private async loadMorePlaylists(): Promise<void> {
    if (this.isLoadingPlaylists || this.isLoadingMorePlaylists || !this.playlistNextPageToken) return;
    this.isLoadingMorePlaylists = true;
    try {
      const service = FeedServiceProvider.getInstance().getChannelService();
      const startId = this.playlistList.length + 1;
      const result = await service.fetchChannelPlaylistsNext(this.playlistNextPageToken, this.playlistVisitorData, startId);
      if (result.items && result.items.length > 0) {
        this.playlistList = this.playlistList.concat(result.items);
        this.playlistNextPageToken = result.nextPageToken;
        if (result.visitorData) this.playlistVisitorData = result.visitorData;
      } else {
        this.playlistNextPageToken = null;
      }
    } catch (err) {
      logger.error('loadMorePlaylists failed:', JSON.stringify(err));
    } finally {
      this.isLoadingMorePlaylists = false;
    }
  }

  @Builder
  UserInfoSection() {
    Column() {
      if (this.bannerUrl && this.bannerUrl.length > 0) {
        Image(this.bannerUrl)
          .width('100%')
          .height(this.BANNER_HEIGHT)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.displayChannel.thumbnailColor || $r('app.color.yourtube_icon_hint'))
      } else {
        Rect()
          .width('100%')
          .height(this.BANNER_HEIGHT)
          .fill(this.displayChannel.thumbnailColor || $r('app.color.yourtube_icon_hint'))
      }

      Row() {
        if (this.displayChannel.avatarUrl && this.displayChannel.avatarUrl.length > 0) {
          Image(this.displayChannel.avatarUrl)
            .width(72)
            .height(72)
            .objectFit(ImageFit.Cover)
            .borderRadius(36)
            .clip(true)
            .backgroundColor(this.displayChannel.thumbnailColor || $r('app.color.yourtube_icon_hint'))
        } else {
          Circle()
            .width(72)
            .height(72)
            .fill(this.displayChannel.thumbnailColor || $r('app.color.yourtube_icon_hint'))
        }

        Column() {
          Text(this.displayChannel.name || $r('app.string.yt_label_unknown'))
            .fontSize(18)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })



          Row() {
            if (this.displayChannel.subscriberText && this.displayChannel.subscriberText.length > 0) {
              Text(this.displayChannel.subscriberText)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.displayChannel.videoCountText && this.displayChannel.videoCountText.length > 0) {
              Text(this.displayChannel.subscriberText && this.displayChannel.subscriberText.length > 0
                ? ` · ${this.displayChannel.videoCountText}`
                : this.displayChannel.videoCountText)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .margin({ top: 4 })
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)

        Button(this.isSubscribed() ? $r('app.string.yt_action_unsubscribe') : $r('app.string.yt_action_subscribe'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor(this.isSubscribed() ? $r('app.color.yourtube_button_disabled') : this.themePrimary)
          .height(28)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.handleSubscription();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }

  @Builder
  UserTabBarBuilder(label: ResourceStr, index: number) {
    SubTabBarItem({ label: label, selected: this.activeTabIndex === index, themePrimary: this.themePrimary })
  }


  @Builder
  PlaylistsTab() {
    Column() {
      if (this.isLoadingPlaylists) {
        Row() {
          LoadingProgress()
            .color(this.themePrimary)
            .width(30)
            .height(30)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 20 })
      } else if (typeof this.errorMessagePlaylists === 'string' && this.errorMessagePlaylists.length > 0) {
        Text(this.errorMessagePlaylists)
          .fontSize(12)
          .fontColor(this.themePrimary)
          .margin({ left: 16, top: 12 })
      } else if (this.playlistList.length === 0) {
        Text($r('app.string.yt_empty_no_playlists'))
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 20 })
          .width('100%')
          .textAlign(TextAlign.Center)
      } else if (this.getWideListColumns() > 1) {
        Scroll() {
          Column() {
            GridRow({
              columns: this.getWideListColumns(),
              gutter: { x: 8, y: 4 }
            }) {
              ForEach(this.playlistList, (item: SearchPlaylistItem) => {
                GridCol({ span: 1 }) {
                  PlaylistCard({
                    playlist: item
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.playlistId || item.id.toString(), this.uiConfig))
              }, (item: SearchPlaylistItem) => item.playlistId || item.id.toString())
            }
            .width('100%')

            if (this.isLoadingMorePlaylists) {
              Row() {
                LoadingProgress()
                  .color(this.themePrimary)
                  .width(26)
                  .height(26)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 12 })
            }
          }
          .width('100%')
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .layoutWeight(1)
        .onReachEnd(() => {
          this.loadMorePlaylists();
        })
      } else {
        List({ space: 4, scroller: this.scrollerForList }) {
          ForEach(this.playlistList, (item: SearchPlaylistItem) => {
            ListItem() {
              PlaylistCard({
                playlist: item
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.playlistId || item.id.toString(), this.uiConfig))
          }, (item: SearchPlaylistItem) => item.playlistId || item.id.toString())

          if (this.isLoadingMorePlaylists) {
            ListItem() {
              Row() {
                LoadingProgress()
                  .color(this.themePrimary)
                  .width(26)
                  .height(26)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 12 })
            }
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_page'))
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .layoutWeight(1)
        .onReachEnd(() => {
          this.loadMorePlaylists();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  AboutTab() {
    List({ scroller: this.scrollerForList }) {
      ListItem() {
        Column() {
          Text($r('app.string.yt_channel_info'))
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 8 })
          Row() {
            Text($r('app.string.yt_channel_id'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width(80)
            Text(this.displayChannel.channelId || '-')
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_primary'))
              .layoutWeight(1)
          }
          .margin({ bottom: 6 })

          if (this.displayChannel.subscriberText && this.displayChannel.subscriberText.length > 0) {
            Row() {
              Text($r('app.string.yt_channel_subscribers'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .width(80)
              Text(this.displayChannel.subscriberText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_primary'))
                .layoutWeight(1)
            }
            .margin({ bottom: 6 })
          }

          if (this.displayChannel.videoCountText && this.displayChannel.videoCountText.length > 0) {
            Row() {
              Text($r('app.string.yt_channel_video_count'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .width(80)
              Text(this.displayChannel.videoCountText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_primary'))
                .layoutWeight(1)
            }
            .margin({ bottom: 6 })
          }

          if ((this.fullDescription && this.fullDescription.length > 0) ||
            (this.displayChannel.description && this.displayChannel.description.length > 0)) {
            Text($r('app.string.yt_channel_description'))
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_hint'))
              .margin({ top: 10, bottom: 6 })

            Text((this.fullDescription && this.fullDescription.length > 0)
              ? this.fullDescription
              : this.displayChannel.description)
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .lineHeight(18)
              .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.yourtube_bg_surface'))
        .borderRadius(12)
        //.shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
        //.margin({ left: 12, right: 12, top: 0, bottom: 12 })
      }
      .width('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
      .padding({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
    .scrollBar(BarState.Off)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .layoutWeight(1)
  }

  build() {
    HdsNavDestination() {
      Column() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll(this.scrollerForScroll) {
          Column() {
            // 顶部内容退避区域：避让状态栏 + 标题栏（与主页一致）
            Row().width('100%').height(this.safeAreaTop + TITLE_BAR_HEIGHT)
            this.UserInfoSection()
            Tabs({
              barPosition: BarPosition.Start
            }) {
              TabContent() {
                ChannelVideoTab({
                  list: this.videoList,
                  isLoading: this.isLoading,
                  isLoadingMore: this.isLoadingMore,
                  errorMessage: this.errorMessage,
                  emptyText: $r('app.string.yt_empty_no_videos'),
                  scroller: this.scrollerForList,
                  onLoadMore: () => { this.loadMoreVideos(); }
                })
              }
              .tabBar(this.UserTabBarBuilder($r('app.string.yt_tab_videos'), 0))
              TabContent() {
                ChannelVideoTab({
                  list: this.shortsList,
                  isLoading: this.isLoadingShorts,
                  isLoadingMore: this.isLoadingMoreShorts,
                  errorMessage: this.errorMessageShorts,
                  emptyText: $r('app.string.yt_empty_no_shorts'),
                  scroller: this.scrollerForList,
                  onLoadMore: () => { this.loadMoreShorts(); }
                })
              }
              .tabBar(this.UserTabBarBuilder($r('app.string.yt_tab_shorts'), 1))
              TabContent() {
                ChannelVideoTab({
                  list: this.liveList,
                  isLoading: this.isLoadingLive,
                  isLoadingMore: this.isLoadingMoreLive,
                  errorMessage: this.errorMessageLive,
                  emptyText: $r('app.string.yt_empty_no_live'),
                  scroller: this.scrollerForList,
                  onLoadMore: () => { this.loadMoreLive(); }
                })
              }
              .tabBar(this.UserTabBarBuilder($r('app.string.yt_tab_live'), 2))
              TabContent() {
                this.PlaylistsTab()
              }
              .tabBar(this.UserTabBarBuilder($r('app.string.yt_tab_playlists'), 3))
              TabContent() {
                this.AboutTab()
              }
              .tabBar(this.UserTabBarBuilder($r('app.string.yt_tab_about'), 4))
            }
            .vertical(false)
            .barHeight(48)
            .barOverlap(false)
            .barMode(BarMode.Fixed, { nonScrollableLayoutStyle: LayoutStyle.ALWAYS_CENTER })
            .barWidth('100%')
            .barBackgroundColor($r('app.color.yourtube_bg_surface'))
            .onChange((index: number) => {
              this.activeTabIndex = index;
            })
          }
        }
        .scrollBar(BarState.Off)
        .clip(false)
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: this.displayChannel.name || $r('app.string.yt_label_user'),
      onBack: () => {
        this.actionHub.closePage();
      },
      immersiveShadow: true,
      avoidLayoutSafeArea: true,
      menus: [
        buildTitleMenu($r('sys.symbol.share'), $r('app.string.yt_action_share'), () => {
          this.handleShare();
        }, this.SHARE_BUTTON_ID)
      ]
    }))
    .bindToScrollable([this.scrollerForScroll])
    .onBackPressed(() => {
      this.actionHub.closePage();
      return true;
    })
  }
}
