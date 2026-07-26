import { AppLog } from '../../common/AppLog';
import common from '@ohos.app.ability.common';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { ActionHub } from '../../common/ActionHub';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { SearchLocaleManager } from '../../common/SearchLocaleManager';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { SearchPlaylistItem } from 'youtube_core';
import { VideoItem } from 'youtube_core';
import { UIConfig } from '../../common/AppState';
import { StoredLocalQueue } from '../../common/PlaylistModel';

import { SubscriptionFeedService } from '../../features/subscription/SubscriptionFeedService';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { MediaThumb } from '../../common/components/MediaThumb';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildTitleMenu, buildYourTubeTitleBar } from '../../common/components/HdsTitleBar';
import { PlayQueueSourceHint } from '../player/PlayQueueManager';
import { getWideListColumnCount } from '../../common/utils/ListLayoutUtils';

const logger = AppLog.getInstance('PlaylistDetailPage');

@Component
export struct PlaylistDetailPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop playlist: SearchPlaylistItem;
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageLink('localQueues') localQueues: StoredLocalQueue[] = [];

  @State videoList: VideoItem[] = [];
  @State nextPageToken: string | null = null;
  @State visitorData: string = '';
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State errorMessage: string = '';
  @State totalCountText: string = '';

  private readonly GRID_SIDE_PADDING: number = 12;

  private rssFallbackService: SubscriptionFeedService = new SubscriptionFeedService();
  private scrollerForScroll: Scroller = new Scroller();
  private scrollerForList: Scroller = new Scroller();
  private readonly SHARE_BUTTON_ID: string = 'playlistShareButtonId';

  aboutToAppear() {
    this.loadPlaylistVideos();
  }

  aboutToDisappear() {
  }

  /** 本地播放列表的 id 带 local_ 前缀，与联机播放列表区分。 */
  private isLocal(): boolean {
    return (this.playlist.playlistId || '').trim().startsWith('local_');
  }

  private openPlaylistVideo(video: VideoItem, index: number): void {
    const playlistId = (this.playlist.playlistId || '').trim();
    const hint: PlayQueueSourceHint = {
      type: this.isLocal() ? 'local' : 'playlist',
      playlistId: playlistId,
      playlistName: this.playlist.name || '',
      loadedItems: this.videoList.slice(),
      startIndex: index,
      nextPageToken: this.nextPageToken,
      visitorData: this.visitorData
    };
    this.actionHub.openVideo(video, hint);
  }

  private getVideoGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    if (contentWidth >= 1440) {
      return 5;
    }
    if (contentWidth >= 1080) {
      return 4;
    }
    if (contentWidth >= 760) {
      return 3;
    }
    if (contentWidth >= 520) {
      return 2;
    }
    return 1;
  }

  /** 条式列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    return getWideListColumnCount(contentWidth);
  }

  private async loadPlaylistVideos(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const playlistId = (this.playlist.playlistId || '').trim();
      if (!playlistId) {
        this.videoList = [];
        this.nextPageToken = null;
        this.visitorData = '';
        return;
      }
      // 本地播放列表：直接从内存快照读取，不走网络、无分页。
      if (this.isLocal()) {
        const queue = this.localQueues.find((q) => q.id === playlistId);
        this.videoList = queue ? queue.videos.slice() : [];
        this.nextPageToken = null;
        this.visitorData = '';
        const ctx = this.getUIContext().getHostContext();
        const suffix = ctx ? ctx.resourceManager.getStringSync($r('app.string.yt_label_videos')) : '';
        this.totalCountText = `${this.videoList.length} ${suffix}`;
        return;
      }
      this.nextPageToken = null;
      this.visitorData = '';
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistInitial(playlistId, 1);
      if (result.items && result.items.length > 0) {
        this.videoList = result.items;
        this.nextPageToken = result.nextPageToken;
        if (result.visitorData) {
          this.visitorData = result.visitorData;
        }
        if (result.totalCountText && result.totalCountText.length > 0) {
          this.totalCountText = result.totalCountText;
        }
      } else {
        // RSS is a best-effort fallback; many playlists (private/Music/new layouts) return 404.
        try {
          const fallback = await this.rssFallbackService.fetchPlaylistVideos(
            playlistId, this.playlist.name || playlistId);
          this.videoList = fallback;
        } catch (rssErr) {
          logger.error('RSS playlist fallback failed:', JSON.stringify(rssErr));
          this.videoList = [];
        }
        this.nextPageToken = null;
        this.visitorData = '';
      }
      if (!this.totalCountText || this.totalCountText.length === 0) {
        if (this.playlist.videoCountText) {
          this.totalCountText = this.playlist.videoCountText;
        } else if (this.videoList.length > 0) {
          const ctx = this.getUIContext().getHostContext();
          const suffix = ctx ? ctx.resourceManager.getStringSync($r('app.string.yt_label_videos_alt')) : '';
          this.totalCountText = `${this.videoList.length} ${suffix}`;
        } else {
          this.totalCountText = '';
        }
      }
    } catch (err) {
      logger.error('loadPlaylistVideos failed:', JSON.stringify(err));
      this.videoList = [];
      this.errorMessage = getContext().resourceManager.getStringSync($r('app.string.yt_error_load_playlists').id);
    } finally {
      this.isLoading = false;
    }
  }

  private async loadMoreVideos(): Promise<void> {
    if (this.isLoading || this.isLoadingMore) {
      return;
    }
    if (!this.nextPageToken) {
      return;
    }
    this.isLoadingMore = true;
    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const startId = this.videoList.length + 1;
      const token = this.nextPageToken ?? '';
      const result = await service.fetchPlaylistNext(token, this.visitorData, startId);
      if (result.items && result.items.length > 0) {
        this.videoList = this.videoList.concat(result.items);
      }
      if ((!result.items || result.items.length === 0) && result.nextPageToken === token) {
        this.nextPageToken = null;
      } else {
        this.nextPageToken = result.nextPageToken;
      }
      if (result.visitorData && result.visitorData.length > 0) {
        this.visitorData = result.visitorData;
      }
    } catch (err) {
      logger.error('loadMorePlaylistVideos failed:', JSON.stringify(err));
    } finally {
      this.isLoadingMore = false;
    }
  }

  private async handleShare(): Promise<void> {
    try {
      const playlistId = (this.playlist.playlistId || '').trim();
      const title = this.playlist.name || getContext().resourceManager.getStringSync($r('app.string.yt_tab_playlists').id);
      const url = playlistId ? `https://www.youtube.com/playlist?list=${playlistId}` : '';
      const content = url ? `${title}\n${url}` : title;
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

  @Builder
  PlaylistInfoSection() {
    Column() {
      Row() {
        MediaThumb({
          imageUrl: this.playlist.coverUrl || '',
          placeholderColor: this.playlist.thumbnailColor || '',
          widthVp: 96,
          heightVp: 96,
          borderRadiusVp: 8
        })

        Column() {
          Text(this.playlist.name || $r('app.string.yt_label_untitled'))
            .fontSize(16)
            .fontColor($r('app.color.yourtube_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(20)

          Row() {
            if (this.playlist.uploaderName && this.playlist.uploaderName.length > 0) {
              Text(this.playlist.uploaderName)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.totalCountText && this.totalCountText.length > 0) {
              Text(this.playlist.uploaderName && this.playlist.uploaderName.length > 0
                ? ` · ${this.totalCountText}`
                : this.totalCountText)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .margin({ top: 6 })

          if (this.playlist.description && this.playlist.description.length > 0) {
            Text(this.playlist.description)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(16)
              .margin({ top: 6 })
          }
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .backgroundColor($r('app.color.yourtube_bg_surface'))
  }

  @Builder
  PlaylistVideos() {
    Column() {
      if (this.isLoading) {
        Row() {
          LoadingProgress()
            .color(this.themePrimary)
            .width(30)
            .height(30)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 20 })
      } else if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(12)
          .fontColor(this.themePrimary)
          .margin({ left: 16, top: 12 })
      } else if (this.videoList.length === 0) {
        Text($r('app.string.yt_empty_no_videos'))
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 20 })
          .width('100%')
          .textAlign(TextAlign.Center)
      } else if (this.uiConfig.homeLayoutMode === 'grid') {
        Scroll() {
          Column() {
            GridRow({
              columns: this.getVideoGridColumnCount(),
              gutter: { x: 8, y: 8 }
            }) {
              ForEach(this.videoList, (item: VideoItem, index: number) => {
                GridCol({ span: 1 }) {
                  VideoCardGrid({
                    video: item,
                    actionLabel: $r('app.string.yt_action_favorite'),
                    actionType: 'favorite',
                    useFavoriteToggle: true,
                    onOpenVideo: () => {
                      this.openPlaylistVideo(item, index);
                    }
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')

            if (this.isLoadingMore) {
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
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .height('100%')
        .align(Alignment.Top)
        .onReachEnd(() => {
          if (!this.isLoading && !this.isLoadingMore && this.nextPageToken) {
            this.loadMoreVideos();
          }
        })
      } else if (this.getWideListColumns() > 1) {
        Scroll() {
          Column() {
            GridRow({
              columns: this.getWideListColumns(),
              gutter: { x: 8, y: 4 }
            }) {
              ForEach(this.videoList, (item: VideoItem, index: number) => {
                GridCol({ span: 1 }) {
                  VideoCard({
                    video: item,
                    actionLabel: $r('app.string.yt_action_favorite'),
                    actionType: 'favorite',
                    useFavoriteToggle: true,
                    onOpenVideo: () => {
                      this.openPlaylistVideo(item, index);
                    }
                  })
                }
                .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
              }, (item: VideoItem) => item.videoId || item.id.toString())
            }
            .width('100%')

            if (this.isLoadingMore) {
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
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .height('100%')
        .onReachEnd(() => {
          this.loadMoreVideos();
        })
      } else {
        List({ space: 4, scroller: this.scrollerForList }) {
          ForEach(this.videoList, (item: VideoItem, index: number) => {
            ListItem() {
              VideoCard({
                video: item,
                actionLabel: $r('app.string.yt_action_favorite'),
                actionType: 'favorite',
                useFavoriteToggle: true,
                onOpenVideo: () => {
                  this.openPlaylistVideo(item, index);
                }
              })
            }
            .transition(customAnimationUtil.isScaleTran(item.videoId || item.id.toString(), this.uiConfig))
          }, (item: VideoItem) => item.videoId || item.id.toString())

          if (this.isLoadingMore) {
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
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .height('100%')
        .onScrollIndex((firstIndex: number, lastIndex: number) => {
          if (this.isLoading || this.isLoadingMore) {
            return;
          }
          if (!this.nextPageToken) {
            return;
          }
          if (lastIndex >= this.videoList.length - 2) {
            this.loadMoreVideos();
          }
        })
        .onReachEnd(() => {
          this.loadMoreVideos();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  build() {
    HdsNavDestination() {
      Column() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll(this.scrollerForScroll) {
          Column() {
            // 顶部内容退避区域：避让状态栏 + 标题栏（与主页一致）
            Row().width('100%').height(this.safeAreaTop + 56)
            this.PlaylistInfoSection()
            this.PlaylistVideos()
          }
        }
        .scrollBar(BarState.Off)
        .clip(false)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
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
      title: this.playlist.name || $r('app.string.yt_tab_playlists'),
      onBack: () => {
        this.actionHub.closePage();
      },
      immersiveShadow: true,
      avoidLayoutSafeArea: true,
      menus: this.isLocal() ? [] : [
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
